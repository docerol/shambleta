extends WindowPanel
class_name GuildPanel

# SOM-IDLE social (auditoria 2026-09-27 §SOCIAL "o que eleva a nota é o jogador
# fazer as coisas sociais sem digitar comando"). Painel de guild: criar/procurar/
# entrar, ver membros com presença, mexer no vault, level-up e canal de chat da
# guild — tudo por botão. Os painéis daqui (Leaderboard, Social) são read-only;
# este é o primeiro que AGE.
#
# Arquitetura de chamada. O game é server-authoritative e a GUI só conversa com o
# servidor pelo facade `Network` (@rpc). Para guild o facade expõe leitura
# (`GetGuildState`), o gasto de gems (`BuyVaultSlots`) e
# as cinco ESCRITAS deste painel — `CreateGuild`, `JoinGuild`, `LeaveGuild`,
# `DepositToVault`, `WithdrawFromVault` (`sources/network/Network.gd`), cada uma com
# seu handler autoritativo em `sources/network/server/Server.gd`, onde conta e
# personagem SAEM DO PEER, nunca do pacote.
# O boot de dev/teste tem client+server no mesmo processo (`Launcher.Economy` existe
# na GUI — é o que Gui.gd:SimulateCheckout e as suítes de guild usam), então a
# perna primária continua chamando o service direto, que é o caminho autoritativo
# nesse modo. Quando `Launcher.Economy` é null (cliente puro, o caso do export web)
# ou a conta local não resolve (`LocalPlayerIDs()` depende de `Peers`, o registro do
# SERVIDOR), a escrita sai pelo facade e o veredito volta por
# `GuildFeedback` → `ShowNetworkFeedback`, com o estado fresco por `GuildState` →
# `RenderState`. O que ainda NÃO tem @rpc é a busca por nome: no cliente puro ela diz
# que não está disponível, em vez de fingir.
#
# A UI é montada em código no _ready (mesmo padrão de Activities/Checkout, que o
# comentário de Gui.gd descreve como "runtime, sem .tscn"). Assim o painel funciona
# instanciado tanto pela cena (presets/gui/GuildPanel.tscn — é por ela que o botão
# "Guilda" do HUD o abre, `Gui.EnsureGuildPanel`, porque o TitleBar da cena é o
# botão de fechar da janela) quanto por `.new()` direto em teste headless — nada
# aqui depende de nós da cena para agir.
#
# Composição (gate anti-god-node, `scripts/check_god_nodes.sh`): este arquivo é a
# junção, não a peça. O que já tinha frase própria no mapa do painel saiu para
# `sources/gui/`, cada um testável sozinho:
#   `GuildWithdrawGate`  — o portão anti-dreno de §14 (aritmética de janela),
#   `GuildSlotShop`      — a loja dos gastos de gems (preço, prévia, cobrança),
#   `GuildMemberRoster`  — as linhas de membro com presença e os cliques de roster,
#   `GuildVaultShelves`  — as prateleiras do vault com o botão de saque,
#   `GuildListings`      — resultado de busca e placa de ranking,
#   `GuildVaultTrail`    — o rastro do vault,
#   `GuildPanelRows`     — os construtores de fileira (campo+botão, seções roláveis).
# O que fica aqui é estado e decisão: quem é o jogador local, o que o servidor
# respondeu, e o que ainda não foi confirmado.

const GuildChannelPrefix : String = "guild:"		# espelha o prefixo usado pelo servidor no roteamento de canal de guild

var infoLabel : Label = null
var noGuildLabel : Label = null
var createEdit : LineEdit = null
var createButton : Button = null
var searchEdit : LineEdit = null
var searchButton : Button = null
var resultsList : VBoxContainer = null
var membersList : VBoxContainer = null
var vaultList : VBoxContainer = null
var vaultLogList : VBoxContainer = null
var boardList : VBoxContainer = null
var depositEdit : LineEdit = null
var depositCountEdit : LineEdit = null
var depositButton : Button = null
var actionRow : HBoxContainer = null
var leaveButton : Button = null
var slotButton : Button = null
var chatEdit : LineEdit = null
var chatButton : Button = null
var feedbackLabel : Label = null
var _confirmRow : HBoxContainer = null
var _confirmLabel : Label = null

var _built : bool = false
var _overrideAccount : int = 0
var _overrideChar : int = 0
var _lastState : Dictionary = {}
var _lastSearch : Array = []
var _pending : Dictionary = {}
var _withdrawGate : GuildWithdrawGate = GuildWithdrawGate.new()

# ------------------------------------------------------------------ ciclo de vida

func _ready() -> void:
	BuildUI()
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		Refresh()

func _on_visibility_changed() -> void:
	if is_visible():
		Refresh()

# Permite dirigir o painel num processo sem um peer logado (teste headless, e
# qualquer código que já saiba quem é o jogador local). accountID/charID <= 0
# limpam o override e voltam à resolução automática.
func SetLocalIDs(accountID : int, charID : int) -> void:
	_overrideAccount = accountID
	_overrideChar = charID

# ------------------------------------------------------------------ identidade local

func LocalPlayerIDs() -> Dictionary:
	if _overrideAccount > 0:
		return {"account": _overrideAccount, "char": _overrideChar}
	var accountID : int = 0
	var charID : int = 0
	# Offline/dev: o peer da autoridade é o jogador local (client+server no mesmo
	# processo). Peers é o registro do servidor.
	var rawAccount : int = Peers.GetAccount(NetworkCommons.PeerAuthorityID)
	var rawChar : int = Peers.GetCharacter(NetworkCommons.PeerAuthorityID)
	if rawAccount > 0:
		accountID = rawAccount
	if rawChar > 0:
		charID = rawChar
	if accountID <= 0 and Launcher != null:
		var peer : Variant = Launcher.get("Peer")
		if peer != null:
			accountID = int(peer.get("accountID", 0))
			charID = int(peer.get("characterID", 0))
	return {"account": accountID, "char": charID}

func _ResolveEconomy() -> EconomyService:
	if Launcher == null:
		return null
	var eco : EconomyService = Launcher.Economy
	return eco

# ------------------------------------------------------------------ leitura / render

func Refresh() -> void:
	_lastState = FetchState()
	_lastSearch = []
	RenderState(_lastState)

# Fonte do estado. No dev/single-process lê o service (sempre fresco). No cliente
# puro pede o push pelo facade e renderiza o último snapshot (mesma política
# otimista de cache do Leaderboard).
func FetchState() -> Dictionary:
	var eco : EconomyService = _ResolveEconomy()
	if eco != null:
		var ids : Dictionary = LocalPlayerIDs()
		var accountID : int = int(ids.get("account", 0))
		if accountID > 0:
			return eco.GetGuildState(accountID)
	if Network != null and Network.has_method("GetGuildState"):
		Network.GetGuildState()
	return NetClient.LastGuildState

# ------------------------------------------------------------------ ações (escrevem)

# Segunda perna de escrita: sem service neste processo, ou sem conta local, o painel
# é cliente puro e manda pelo facade. O que pinta agora é "enviado", nunca "feito" —
# o veredito real chega por `GuildFeedback` → `ShowNetworkFeedback` e o estado por
# `GuildState` → `RenderState`. O painel não manda conta nem personagem: quem é o
# jogador é decisão do peer no servidor.
func _WriteOverNetwork(label : String, send : Callable) -> void:
	if Network == null:
		SetFeedback("%s: no local session and no network facade" % label)
		return
	send.call()
	SetFeedback("%s: sent to the server" % label)

# Veredito assíncrono da segunda perna. O motivo cru do servidor não vai à tela sem
# passar pelo catálogo de toasts (§13).
func ShowNetworkFeedback(ok : bool, reason : String) -> void:
	SetFeedback("Guild: done." if ok else PlayerReasons.ToToast("Guild rejected: " + reason))

func CreateGuildNamed(guildName : String) -> int:
	var eco : EconomyService = _ResolveEconomy()
	var ids : Dictionary = LocalPlayerIDs()
	var accountID : int = int(ids.get("account", 0))
	var charID : int = int(ids.get("char", 0))
	if eco == null or accountID <= 0 or charID <= 0:
		_WriteOverNetwork("Create", func() -> void: Network.CreateGuild(guildName))
		return 0
	var guildID : int = eco.CreateGuild(accountID, charID, guildName)
	if guildID > 0:
		SetFeedback("Guild '%s' founded." % guildName.strip_edges())
		Refresh()
	else:
		SetFeedback("Create rejected (name taken, too short, or need %d gold)." % EconomyCatalog.GuildCreateCostGold)
	return guildID

func JoinGuildByID(guildID : int) -> bool:
	var eco : EconomyService = _ResolveEconomy()
	var accountID : int = int(LocalPlayerIDs().get("account", 0))
	if guildID <= 0:
		SetFeedback("Join: bad guild id")
		return false
	if eco == null or accountID <= 0:
		_WriteOverNetwork("Join", func() -> void: Network.JoinGuild(guildID))
		return false
	var ok : bool = eco.JoinGuild(accountID, guildID)
	SetFeedback("Joined." if ok else "Join rejected (already in a guild, or guild gone).")
	if ok:
		Refresh()
	return ok

func LeaveCurrentGuild() -> bool:
	var eco : EconomyService = _ResolveEconomy()
	var accountID : int = int(LocalPlayerIDs().get("account", 0))
	if eco == null or accountID <= 0:
		_WriteOverNetwork("Leave", func() -> void: Network.LeaveGuild())
		return false
	var ok : bool = eco.LeaveGuild(accountID)
	SetFeedback("Left the guild." if ok else "Leave rejected (dissolve needs an empty vault?).")
	Refresh()
	return ok

# Deposita `count` unidades de `itemID` do inventário do personagem no vault.
func DepositItem(itemID : int, count : int) -> bool:
	if itemID <= 0 or count <= 0:
		SetFeedback("Deposit: bad amount")
		return false
	var eco : EconomyService = _ResolveEconomy()
	var ids : Dictionary = LocalPlayerIDs()
	var accountID : int = int(ids.get("account", 0))
	var charID : int = int(ids.get("char", 0))
	if eco == null or accountID <= 0 or charID <= 0:
		_WriteOverNetwork("Deposit", func() -> void: Network.DepositToVault(itemID, count))
		return false
	var ok : bool = eco.DepositToVault(accountID, charID, itemID, count)
	SetFeedback("Deposited %d." % count if ok else "Deposit failed (not enough in inventory, or vault full).")
	if ok:
		Refresh()
	return ok

# Retira `count` de `itemID` do vault para o inventário. Só officer/líder (regra do
# service) — e agora limitado pelo portão anti-dreno de §14 (`GuildWithdrawGate`).
# O botão da UI passa por `RequestWithdraw`, que arma; este método é o único choke
# point e vale também para chamada direta de teste. O portão vem ANTES das duas
# pernas: é a antecedência de cliente, e a recusa do servidor (§14, metade durável)
# continua valendo para quem não passa por aqui.
func WithdrawItem(itemID : int, count : int) -> bool:
	if itemID <= 0 or count <= 0:
		SetFeedback("Withdraw: bad amount")
		return false
	var gate : String = WithdrawGateReason(count)
	if not gate.is_empty():
		SetFeedback(gate)
		return false
	var eco : EconomyService = _ResolveEconomy()
	var ids : Dictionary = LocalPlayerIDs()
	var accountID : int = int(ids.get("account", 0))
	var charID : int = int(ids.get("char", 0))
	if eco == null or accountID <= 0 or charID <= 0:
		_WriteOverNetwork("Withdraw", func() -> void: Network.WithdrawFromVault(itemID, count))
		return false
	var ok : bool = eco.WithdrawFromVault(accountID, charID, itemID, count)
	if ok:
		# O carimbo só conta no saque que passou do portão — portão e registro no
		# mesmo `if` para a contadora nunca divergir do ledger.
		_withdrawGate.Record()
	SetFeedback("Withdrew %d." % count if ok else "Withdraw failed (need officer+, or not enough).")
	if ok:
		Refresh()
	return ok

# "" quando o saque cabe no portão; senão, a mensagem legível do motivo.
func WithdrawGateReason(count : int) -> String:
	return _withdrawGate.Reason(count)

# Prévia de saque (botão "Withdraw" do vault): arma em vez de gastar — mesmo
# portão dos gastos de gems. Limita a pilha inteira ao teto do portão.
func RequestWithdraw(itemID : int, count : int) -> bool:
	if itemID <= 0 or count <= 0:
		SetFeedback("Withdraw: bad amount")
		return false
	var mine : Dictionary = _lastState.get("my_guild", {})
	var rank : String = str(mine.get("my_rank", ""))
	if rank != "leader" and rank != "officer":
		SetFeedback("Withdraw: need officer+")
		return false
	var wanted : int = mini(count, GuildVaultLimits.MaxWithdrawPerAction)
	var gate : String = WithdrawGateReason(wanted)
	if not gate.is_empty():
		SetFeedback(gate)
		return false
	_Arm({"action": "withdraw", "item": itemID, "count": wanted,
		"line": "Withdraw %d x item %d from the vault? Officer moves are logged in the vault trail. Confirm?" % [wanted, itemID]})
	return true

# Busca guilds por nome (substring, case-insensitive). Via guildService público do
# EconomyService — sem este caminho eu teria que editar EconomyService (outro dono).
func SearchGuildsByName(query : String) -> Array:
	var eco : EconomyService = _ResolveEconomy()
	if eco == null or eco.guildService == null:
		SetFeedback("Search: not available over network yet")
		return []
	_lastSearch = eco.guildService.SearchGuilds(query, 20)
	_RenderResults(_lastSearch)
	SetFeedback("%d guild(s) match '%s'." % [_lastSearch.size(), query.strip_edges()])
	return _lastSearch

# ------------------------------------------------------------------ a loja de gems

# Os gastos do painel (slot do vault, criação) têm preço, prévia e
# caminho de cobrança em `GuildSlotShop`; aqui sobra só o portão de confirmação e o
# feedback, que são estado do painel.

func BuyVaultSlot() -> Dictionary:
	return _Charge(GuildSlotShop.KindSlot)

func _Charge(kind : int) -> Dictionary:
	var eco : EconomyService = _ResolveEconomy()
	var ids : Dictionary = LocalPlayerIDs()
	var accountID : int = int(ids.get("account", 0))
	var charID : int = int(ids.get("char", 0))
	var result : Dictionary = GuildSlotShop.Charge(eco, Network, accountID, charID, kind)
	SetFeedback(_FeedbackFor(result, GuildSlotShop.Label(kind)))
	# O `Refresh()` é do caminho autoritativo: paga pelo service (dev/single-process)
	# o estado é nosso e vale reler agora; pago pelo RPC do facade, o push chega
	# sozinho e reler aqui só pintaria o snapshot velho.
	if eco != null and accountID > 0 and charID > 0:
		Refresh()
	return result

func _FeedbackFor(result : Dictionary, what : String) -> String:
	if bool(result.get("ok", false)):
		return "%s done." % what
	# O motivo cru do servidor passa pelo catálogo (§13): o jogador lê texto, o
	# operador lê o token no log quando ele não tem linha.
	return PlayerReasons.ToToast("%s rejected: %s" % [what, str(result.get("reason", "?"))])

# ------------------------------------------------------------------ gasto com confirmação

# Os gastos de guilda (slot do vault) saem do bolso do
# jogador, então seguem o MESMO portão do leilão (`AuctionHousePanel._Arm`) e da
# arena (`ArenaPanel.RequestAttack`): o clique arma a prévia e não fala com
# ninguém; `ConfirmPending()` é o único caminho que gasta gems. Sem isto o botão
# do painel recém-ligado ao HUD seria um clique = cobrança.

func RequestVaultSlot() -> bool:
	var mine : Dictionary = _lastState.get("my_guild", {})
	if mine.is_empty():
		SetFeedback("Buy slot: join a guild first")
		return false
	_Arm({"action": "slot", "line": GuildSlotShop.SlotLine()})
	return true

# Único ponto que arma. Não envia nada.
func _Arm(pending : Dictionary) -> void:
	_pending = pending
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	# Dois botões "Confirm" simultâneos seriam uma UI mentirosa: a linha própria só
	# aparece quando o modal da casa não está disponível.
	if _confirmRow:
		_confirmRow.visible = not modal
	if _confirmLabel:
		_confirmLabel.text = str(pending.get("line", ""))
	SetFeedback(str(pending.get("line", "")))
	if modal:
		UICommons.MessageBox(str(pending.get("line", "")), Callable(self, "ConfirmPending"), "Confirm")

func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var action : String = str(_pending.get("action", ""))
	var itemID : int = int(_pending.get("item", 0))
	var count : int = int(_pending.get("count", 0))
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	match action:
		"slot":
			BuyVaultSlot()
		"withdraw":
			WithdrawItem(itemID, count)
		_:
			SetFeedback("Nothing to confirm.")

func CancelPending() -> void:
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if _confirmLabel:
		_confirmLabel.text = ""

# Estado observável (jogador e harness): o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

# ------------------------------------------------------------------ chat de guild

# Nome do canal de chat da minha guild (prefixo + nome). Vazio sem guild.
func GuildChannelName() -> String:
	var mine : Dictionary = _lastState.get("my_guild", {})
	var name : String = str(mine.get("name", ""))
	if name.is_empty():
		return ""
	return GuildChannelPrefix + name

# Quantas sessões da guild estão vivas para receber o canal. É a MESMA regra do
# roteador do servidor (conta membro → peer vivo, falante incluído), relida do
# estado que o painel já tem (`members[].account_id` vem de GetGuildState). O
# painel não pode consultar a camada de moderação — no cliente isso seria mute no
# recebimento, que é cosmético (IdleTests prende essa fronteira) —, então a conta
# sai daqui e o servidor entrega a linha por peer. -1 = este processo não é a
# autoridade (cliente puro): não tenho a tabela de sessões e não invento número.
func OnlineMemberSessions() -> int:
	if _ResolveEconomy() == null:
		return -1
	var mine : Dictionary = _lastState.get("my_guild", {})
	if mine.is_empty():
		return 0
	var count : int = 0
	for entry in mine.get("members", []):
		var member : Dictionary = entry
		var accID : int = int(member.get("account_id", 0))
		if accID <= 0:
			continue
		var peerID : int = int(Peers.accounts.get(accID, NetworkCommons.PeerUnknownID))
		if peerID != NetworkCommons.PeerUnknownID and Peers.peers.has(peerID):
			count += 1
	return count

# Envia `text` no canal da guild. É o "sem comando": o jogador aperta o botão (ou
# Enter na caixa) e o painel roteia para o canal certo. A difusão é do servidor
# (Server.TriggerChat → ramo de guild → fan-out por peer).
func SendGuildChat(text : String) -> void:
	var trimmed : String = text.strip_edges()
	if trimmed.is_empty():
		return
	var channel : String = GuildChannelName()
	if channel.is_empty():
		SetFeedback("Guild chat: join a guild first")
		return
	if chatEdit != null:
		chatEdit.clear()
	# Rate/limite de tamanho são do servidor (ChatMaxSize); o facade corta/clipa.
	if Network == null or not Network.has_method("TriggerChat"):
		SetFeedback("Guild chat: no network channel available")
		return
	Network.TriggerChat(channel, trimmed)
	# Feedback honesto (§SOCIAL): "Sent to guild channel." era dito antes de existir
	# qualquer destinatário. Aqui o número é o de sessões que o roteador vai tocar.
	var sessions : int = OnlineMemberSessions()
	if sessions < 0:
		SetFeedback("Guild chat: sent to the server (%s)" % channel)
	elif sessions == 0:
		SetFeedback("Guild chat: no online member session to deliver to")
	else:
		SetFeedback("Guild chat: delivering to %d online member session(s)" % sessions)

# ------------------------------------------------------------------ render da cena (build UI)

func BuildUI() -> void:
	if _built or not is_inside_tree():
		return
	# Reusa o "Layout" da cena quando existe (GuildPanel.tscn o traz com um TitleBar,
	# no padrão Leaderboard/Social); instanciado por `.new()` (teste, uso runtime) não
	# há cena, então criamos o container e um cabeçalho simples. Um único caminho de
	# construção mantém os `@onready`-por-código válidos nas duas situações.
	var layout : VBoxContainer = get_node_or_null("Layout") as VBoxContainer
	if layout == null:
		layout = VBoxContainer.new()
		layout.name = "Layout"
		add_child(layout)
	var hasTitleBar : bool = layout.get_node_or_null("TitleBar") != null

	if not hasTitleBar:
		GuildPanelRows.Header(layout, "Header", "Guild", 18)

	# SOM-IDLE UX (juiz 2026-09-27 §UX/UI "botão fora da tela"): esta UI é montada em
	# código e o mínimo medido do corpo era 511x1061 contra uma janela de 420x560 e um
	# viewport de projeto de 1280x720 — Confirm/Cancel, a linha de chat e o Feedback
	# nasciam abaixo da borda, ou seja, inexistentes para o jogador. O corpo inteiro
	# entra agora num ScrollContainer. Na vertical a rolagem está LIGADA: um
	# ScrollContainer não impõe a altura do filho quando rola, então o mínimo do
	# painel colapsa e o que não cabe vira alcançável. Na horizontal ela fica
	# DESLIGADA de propósito — é exatamente isso que força o filho a caber na largura
	# da janela, e é o que impede uma linha larga de novo de empurrar botão para fora
	# da tela (a régua em tests/panel_fit_test.gd mede os dois eixos).
	var scroll := ScrollContainer.new()
	scroll.name = "BodyScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	infoLabel = GuildPanelRows.LabelOf(body, "Info", "Not in a guild.")
	infoLabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	noGuildLabel = GuildPanelRows.LabelOf(body, "Hint", "Create one or search below (%d gold to found)." % EconomyCatalog.GuildCreateCostGold)
	noGuildLabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# linha criar / linha buscar
	var created : Dictionary = GuildPanelRows.EditRow(body, "CreateRow", "GuildNameEdit",
		"new guild name", "CreateButton", "Create", Callable(), _OnCreatePressed)
	createEdit = created["edit"] as LineEdit
	createButton = created["button"] as Button
	var searched : Dictionary = GuildPanelRows.EditRow(body, "SearchRow", "SearchEdit",
		"search by name", "SearchButton", "Search",
		func(_text : String) -> void: _OnSearchPressed(), _OnSearchPressed)
	searchEdit = searched["edit"] as LineEdit
	searchButton = searched["button"] as Button

	resultsList = GuildPanelRows.ScrollSection(body, "Results", 110)
	membersList = GuildPanelRows.ScrollSection(body, "Members", 150)
	vaultList = GuildPanelRows.ScrollSection(body, "Vault", 150)
	# §14: o rastro do vault (guild_vault_log) tinha que existir no banco e não
	# existia na tela — sem prova visível, "confiança" é adjetivo. A lista vem de
	# `vault_log` no estado do servidor (`GuildService.GetGuildState`), nunca do
	# banco: o painel não tem caminho de SQL.
	vaultLogList = GuildPanelRows.ScrollSection(body, "Vault log", 110)
	boardList = GuildPanelRows.ScrollSection(body, "Top guilds", 120)

	# depositar
	var deposited : Dictionary = GuildPanelRows.DepositRow(body, _OnDepositPressed)
	depositEdit = deposited["item"] as LineEdit
	depositCountEdit = deposited["count"] as LineEdit
	depositButton = deposited["button"] as Button

	# ações rápidas (aparecem só pra quem pode). Os dois gastos de gems ARMAM uma
	# prévia em vez de gastar — ver a seção "gasto com confirmação" acima.
	# Os rótulos curtos são do tamanho, não da preguiça: o preço exato (2x o custo
	# em ouro; N gems pelo slot) sai na prévia de confirmação antes de qualquer
	# clique gastar, e um botão com o preço embutido era justamente a linha que
	# estourava a largura da janela.
	var actions : Dictionary = GuildPanelRows.ButtonRow(body, "ActionRow", [
		["BuySlotButton", "Buy vault slot", RequestVaultSlot]])
	actionRow = actions["row"] as HBoxContainer
	var actionButtons : Dictionary = actions["buttons"] as Dictionary
	slotButton = actionButtons.get("BuySlotButton") as Button
	# Sair da guild é a ação destrutiva da fileira; um botão sozinho na linha não
	# briga por largura com os dois de cima.
	var left : Dictionary = GuildPanelRows.ButtonRow(body, "LeaveRow", [["LeaveButton", "Leave", _OnLeavePressed]])
	leaveButton = (left["buttons"] as Dictionary).get("LeaveButton") as Button

	var confirmed : Dictionary = GuildPanelRows.ConfirmRow(body, ConfirmPending, CancelPending)
	_confirmRow = confirmed["row"] as HBoxContainer
	_confirmLabel = confirmed["label"] as Label

	# chat da guild
	var chatted : Dictionary = GuildPanelRows.EditRow(body, "ChatRow", "GuildChatEdit",
		"message your guild…", "GuildChatSend", "Guild chat", SendGuildChat, _OnChatPressed,
		NetworkCommons.ChatMaxSize)
	chatEdit = chatted["edit"] as LineEdit
	chatButton = chatted["button"] as Button

	feedbackLabel = GuildPanelRows.LabelOf(body, "Feedback", "")
	_built = true

# ------------------------------------------------------------------ callbacks dos botões

func _OnCreatePressed() -> void:
	if createEdit != null:
		CreateGuildNamed(createEdit.text)

func _OnSearchPressed() -> void:
	if searchEdit != null:
		SearchGuildsByName(searchEdit.text)

func _OnDepositPressed() -> void:
	if depositEdit == null or depositCountEdit == null:
		return
	var itemID : int = int(depositEdit.text.strip_edges())
	var count : int = int(depositCountEdit.text.strip_edges())
	DepositItem(itemID, count)

func _OnLeavePressed() -> void:
	LeaveCurrentGuild()

func _OnChatPressed() -> void:
	if chatEdit != null:
		SendGuildChat(chatEdit.text)

# Linha de prateleira (GuildVaultShelves) e botão "Join" da busca (GuildListings)
# batem de volta aqui: o portão de confirmação e o choke point de escrita continuam
# sendo do painel, não da fileira.
func _OnWithdrawStack(itemID : int, count : int) -> void:
	WithdrawItem(itemID, count)

func _OnRosterAction(verb : String, target : String, targetAccount : int) -> void:
	RosterAction(verb, target, targetAccount)

# O clique da fileira e o que o jogador digitava no chat chegam à MESMA boca. Com o
# serviço neste processo, a linha é chamada direto; sem ele, o texto composto por
# `GuildRoster.ActionText` entra pelo mesmo RPC do chat (`TriggerCommand`) e cai no
# mesmo ramo de `CommandGuild` (`sources/world/WorldCommands.gd:@CommandGuild`) — um terceiro caminho
# para a mesma política seria a segunda autoridade que a casa proíbe. O alvo vem do
# ESTADO que o servidor mandou, nunca de pacote, e a política re-confere filiação e
# posto de qualquer jeito (`Kick` de `sources/economy/GuildRoster.gd:@Kick`). A frase da
# tela é a do próprio catálogo de motivos (`Feedback`), não o token cru.
func RosterAction(verb : String, target : String, targetAccount : int) -> bool:
	var eco : EconomyService = _ResolveEconomy()
	var accountID : int = int(LocalPlayerIDs().get("account", 0))
	if eco == null or accountID <= 0:
		_WriteOverNetwork("Guild " + verb,
			func() -> void: Network.TriggerCommand(GuildRoster.ActionText(verb, target)))
		return false
	var admin : Dictionary = GuildRoster.Command(verb, accountID, targetAccount, target)
	SetFeedback(str(admin.get("text", "")))
	Refresh()
	return bool(admin.get("ok", false))

func _OnJoinFound(guildID : int) -> void:
	JoinGuildByID(guildID)

# Consulta de presença O(1) no índice do servidor, exposta como Callable para o
# roster. OnlineList é estado do servidor — no dev/single-process está acessível
# aqui; num cliente puro sem esse estado a presença fica desconhecida (ponto).
func _IsNickOnline(nick : String) -> bool:
	return OnlineList.IsPlayerOnline(nick)

# ------------------------------------------------------------------ pintura do estado

func RenderState(state : Dictionary) -> void:
	_lastState = state
	if not _built:
		return
	if infoLabel == null:
		return
	if state.is_empty() or not bool(state.get("ok", false)):
		infoLabel.text = "Guild: (offline)"
		_SetVisible(noGuildLabel, true)
		_Clear(membersList)
		_Clear(vaultList)
		_Clear(vaultLogList)
		_Clear(resultsList)
		_Clear(boardList)
		return

	var mine : Dictionary = state.get("my_guild", {})
	if mine.is_empty():
		infoLabel.text = "Not in a guild."
		_SetVisible(noGuildLabel, true)
		_SetVisible(createEdit, true)
		_SetVisible(createButton, true)
		_SetVisible(depositButton, false)
		_SetVisible(actionRow, false)
		_Clear(membersList)
		_Clear(vaultList)
		_Clear(vaultLogList)
	else:
		var vault : Dictionary = mine.get("vault", {})
		infoLabel.text = "%s — L%d · %d pts · vault %d/%d · you: %s" % [
			GuildListings.DisplayName(mine), int(mine.get("level", 1)), int(mine.get("points", 0)),
			int(vault.get("used", 0)), int(vault.get("cap", 0)), str(mine.get("my_rank", "?"))]
		_SetVisible(noGuildLabel, false)
		_SetVisible(createEdit, false)
		_SetVisible(createButton, false)
		var rank : String = str(mine.get("my_rank", ""))
		var canManage : bool = rank == "leader" or rank == "officer"
		# O roster NÃO segue `canManage`: os três verbos de fileira exigem o posto de
		# líder e nada mais, decidido em `Kick` de `sources/economy/GuildRoster.gd:@Kick`.
		# Um oficial que visse os botões veria três recusas por clique, então o posto
		# comparado aqui é a constante da política, não a string repetida.
		var isLeader : bool = rank == GuildRoster.RankLeader
		_SetVisible(depositButton, true)
		_SetVisible(actionRow, true)
		_SetVisible(leaveButton, true)
		_SetVisible(slotButton, canManage)
		GuildMemberRoster.Render(membersList, mine.get("members", []), _IsNickOnline,
			isLeader, _OnRosterAction, int(LocalPlayerIDs().get("account", 0)))
		GuildVaultShelves.Render(vaultList, mine.get("vault_stacks", []), canManage, _OnWithdrawStack)
		# §14: o rastro sai do MESMO estado que encheu o vault — nada aqui toca o
		# banco, então a lista que o oficial vê é a lista que o serviço autorizou.
		GuildVaultTrail.Render(vaultLogList, mine)

	GuildListings.RenderBoard(boardList, state.get("board", []))
	# resultados de busca ficam como estavam (a busca é uma ação explícita do usuário)

func _RenderResults(results : Array) -> void:
	GuildListings.RenderResults(resultsList, results, _OnJoinFound)

# ------------------------------------------------------------------ utilitários de UI

func SetFeedback(text : String) -> void:
	if feedbackLabel != null:
		feedbackLabel.text = text

func _Clear(box : Node) -> void:
	GuildPanelRows.Clear(box)

func _SetVisible(node : Node, visibleState : bool) -> void:
	if node is Control:
		(node as Control).visible = visibleState
