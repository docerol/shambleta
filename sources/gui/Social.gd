extends WindowPanel
class_name Social

#
@onready var playerList : VBoxContainer			= $Layout/Margin/TabBar/Online/Scroll/PlayerList
@onready var onlineCount : Label				= $Layout/Margin/TabBar/Online/OnlineCount
@onready var guildList : VBoxContainer			= $Layout/Margin/TabBar/Guild/GuildList

#
# Gasto de guilda com portão: os dois botões da aba (level-up a 2x e slot do vault)
# saem do bolso do jogador e antes bastavam UM clique. Agora o clique arma a prévia
# e `ConfirmPending()` é o único caminho que emite o @rpc — mesma régua de
# `AuctionHousePanel._Arm`/`ArenaPanel.RequestAttack`. A gestão de guilda em si
# (criar, buscar, entrar, vault, chat) mora no `GuildPanel.gd`, que é o que o botão
# "Guilda" do HUD abre; esta aba é o espelho do push (`Client.GuildState`) e o
# acesso de quem está com a janela de Social aberta por `ui_social`.
var _pending : Dictionary = {}

#
func UpdateCount() -> void:
	var count : int = playerList.get_child_count()
	onlineCount.text = str(count) + " player" + ("s" if count != 1 else "") + " online"

func RefreshOnline(players : PackedStringArray) -> void:
	for child in playerList.get_children():
		child.free()
	for playerName in players:
		playerList.add_child(PlayerLine.new(playerName))
	UpdateCount()

func AddOnlinePlayer(playerName : String) -> void:
	if not playerList.has_node(playerName):
		playerList.add_child(PlayerLine.new(playerName))
		UpdateCount()

func RemoveOnlinePlayer(playerName : String) -> void:
	var line : Node = playerList.get_node_or_null(playerName)
	if line:
		line.free()
		UpdateCount()

#
func _ready():
	if Network and Network.has_method("RequestOnlineList"):
		FSM.enter_game.connect(Network.RequestOnlineList)
	FSM.enter_game.connect(RefreshGuild)

# Fase F (guild premium): espelho do push — a minha guild, top por pontos e as duas
# ações de líder/oficial (fast level-up, vault slot). Quem GERENCIA a guilda (criar,
# buscar, entrar, vault, chat) é o `GuildPanel.gd`, aberto pelo botão "Guilda".
func RefreshGuild():
	ShowGuildState(NetClient.LastGuildState)
	Network.GetGuildState()

func ShowGuildState(state : Dictionary):
	for child in guildList.get_children():
		child.queue_free()
	if state.is_empty() or not bool(state.get("ok", false)):
		return
	var mine : Dictionary = state.get("my_guild", {})
	if mine.is_empty():
		var none := Label.new()
		none.text = "No guild joined — /guild create <name> (5000 gold)"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		guildList.add_child(none)
	else:
		var header := Label.new()
		var vault : Dictionary = mine.get("vault", {})
		var gtag : String = str(mine.get("tag", ""))
		var gname : String = str(mine.get("name", "?"))
		if not gtag.is_empty():
			gname = "[%s] %s" % [gtag, gname]
		header.text = "%s — L%d · %d pts · vault %d/%d · you: %s" % [
			gname, int(mine.get("level", 1)),
			int(mine.get("points", 0)), int(vault.get("used", 0)),
			int(vault.get("cap", 0)), str(mine.get("my_rank", "?"))]
		header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		guildList.add_child(header)
		var rank : String = str(mine.get("my_rank", ""))
		if rank == "leader" or rank == "officer":
			var fast := Button.new()
			fast.text = "Fast level-up (2× gems, no gold)"
			fast.pressed.connect(RequestLevelUpFast)
			guildList.add_child(fast)
			var slots := Button.new()
			slots.text = "Buy vault slot — %d gems" % int(state.get("vault_slot_cost", EconomyCatalog.GUILD_VAULT_SLOT_COST))
			slots.pressed.connect(RequestVaultSlot)
			guildList.add_child(slots)
		for m in mine.get("members", []):
			var line := Label.new()
			line.text = "  %s (%s)" % [str((m as Dictionary).get("name", "?")), str((m as Dictionary).get("rank", "?"))]
			guildList.add_child(line)
	var btitle := Label.new()
	btitle.text = "Top guilds (season points race)"
	guildList.add_child(btitle)
	var pos : int = 1
	for g in state.get("board", []):
		var btag : String = str((g as Dictionary).get("tag", ""))
		var bname : String = str((g as Dictionary).get("name", "?"))
		if not btag.is_empty():
			bname = "[%s] %s" % [btag, bname]
		var row := Label.new()
		row.text = "  #%d %s — L%d · %d pts" % [pos, bname, int((g as Dictionary).get("level", 1)), int((g as Dictionary).get("points", 0))]
		guildList.add_child(row)
		pos += 1
	_RenderPending()

# ------------------------------------------------------------------ gasto com portão
# `Request*` só arma; nada aqui fala com o servidor antes do confirm. O modal da
# casa é o caminho normal — a linha própria dentro da aba só aparece quando ele não
# está disponível, porque dois botões "Confirm" simultâneos seriam uma UI mentirosa.

func RequestLevelUpFast() -> bool:
	_Arm({"action": "levelup", "line": "Fast level-up costs 2× the gold price in gems and is not refunded. Spend now?"})
	return true

func RequestVaultSlot() -> bool:
	_Arm({"action": "slot", "line": "Buy one guild vault slot for %d gems? The slot is permanent. Spend now?" % int(NetClient.LastGuildState.get("vault_slot_cost", EconomyCatalog.GUILD_VAULT_SLOT_COST))})
	return true

func _Arm(pending : Dictionary) -> void:
	_pending = pending
	_RenderPending()
	if Launcher.GUI != null and Launcher.GUI.messageBox != null:
		UICommons.MessageBox(str(pending.get("line", "")), Callable(self, "ConfirmPending"), "Confirm")

func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var action : String = str(_pending.get("action", ""))
	_pending = {}
	match action:
		"levelup":
			Network.LevelUpGuildFast()
		"slot":
			Network.BuyVaultSlots()
		_:
			pass

func CancelPending() -> void:
	_pending = {}
	_RenderPending()

func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func _RenderPending() -> void:
	if guildList == null or not is_instance_valid(guildList):
		return
	# A aba é redesenhada inteira a cada push, então o portão velho sai junto.
	for child in guildList.get_children():
		if child is HBoxContainer and str(child.name) == "GuildSpendConfirm":
			child.queue_free()
	if _pending.is_empty() or (Launcher.GUI != null and Launcher.GUI.messageBox != null):
		return
	var row := HBoxContainer.new()
	row.name = "GuildSpendConfirm"
	var label := Label.new()
	label.text = str(_pending.get("line", ""))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var confirm := Button.new()
	confirm.text = "Confirm"
	confirm.pressed.connect(ConfirmPending)
	row.add_child(confirm)
	var abort := Button.new()
	abort.text = "Cancel"
	abort.pressed.connect(CancelPending)
	row.add_child(abort)
	guildList.add_child(row)
