extends SceneTree

# SOM-HUD (auditoria 2026-09-27): harness que fixa a CORRENTE do HUD — o botão
# nasce, o `pressed.connect` aponta para o handler do `Gui`, e o handler instancia
# o PAINEL na árvore viva. Cada elo é um check separado de propósito: apagar um
# `connect()` em `ManualHudBar.gd`/`Gui._AddArenaHudButton`, ou apagar um
# `Ensure*()` do handler, deixa de passar aqui — e era exatamente assim que o
# painel de guilda ficou escrito e inalcançável (o botão abria outra janela).
#
# Também amarra as duas consequências da ligação:
#   * o `GuildPanel.tscn` é quem fornece o "Layout"/TitleBar que o script afirma
#     (GuildPanel.gd:24 e :284) — provado no nó real, não no texto do arquivo;
#   * os dois gastos de guilda (level-up 2x e slot do vault) ARMAM uma prévia em vez
#     de gastar no clique, no painel novo e no espelho legado (`Social.gd`).
#
# Uso: godot --headless --path . -s tests/hud_wiring_test.gd
# Exit code: nº de checks falhos. Última linha: `== RESULT: N checks, M failures ==`.
#
# Como todo harness `-s`: o main-loop é compilado ANTES dos autoloads e dos
# class_names existirem, então nada de identificador de autoload (Launcher/Network/
# Peers/...) nem class_name de projeto em anotação de tipo neste arquivo — as
# instâncias vêm por root.get_node_or_null()/get()/call().

var _checks : int = 0
var _fails : int = 0
var _dbScript : GDScript = null
var _launcher : Node = null
var _gui : Node = null
var _windows : Node = null

func Check(condition : bool, label : String) -> bool:
	_checks += 1
	if not condition:
		_fails += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

# Assinaturas separadas de propósito: `CheckEq(int, int, String)` recebe String e o
# harness morre em Parse Error no preflight (`preflight_parse()`, `scripts/test.sh:@preflight_parse`).
func CheckI(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func CheckS(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _initialize():
	_run()

func _finish():
	# Mesma última linha de defesa dos harnesses que saem limpos: se o teto do wait
	# estourar, os threaded loads do DB são juntados AQUI, com a árvore viva, em vez
	# de deixar o join cair dentro de `Launcher._exit_tree()` (SIGSEGV em máquina
	# carregada com os checks todos verdes).
	if _dbScript != null and (_dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [_checks, _fails])
	quit(_fails)

func _run() -> void:
	print("== SOM-HUD wiring test ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	# Espera o boot dos serviços (SQL+World), e depois o marcador do preload threadado
	# do DB: SQL+World inicializados NÃO implicam isso, e sem esperar os load()/quit()
	# caem no meio dos parses em thread de trabalho (sources/db/DB.gd:232).
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = _launcher.get("SQL")
		var worldNode : Node = _launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	print("== boot wait done (%d ms) ==" % waited)

	_dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if _dbScript != null and bool(_dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()/quit()"):
		_finish()
		return

	_gui = _launcher.get("GUI")
	if not Check(_gui != null, "Launcher.GUI vive no client headless (a cena do jogo)"):
		_finish()
		return
	_windows = _gui.get("windows")
	if not Check(_windows != null and bool(_windows.is_inside_tree()), "Gui.windows é o contêiner vivo das janelas flutuantes"):
		_finish()
		return

	# O boot do client não chega em IN_GAME num harness, então a barra do HUD ainda
	# não foi montada: este é o mesmo `AddManualSkillButtons()` que o `EnterGame` chama.
	_gui.call("AddManualSkillButtons")
	var hud : HBoxContainer = _gui.get("manualSkillBar")
	if not Check(hud != null, "ManualHudBar.Build monta a barra sob o Gui"):
		_finish()
		return

	# ---------------------------------------------------------------- 1) botão → handler → painel
	# Ordem importa: GuildButton primeiro, porque o bloco de guilda embaixo assume o
	# painel já aberto por aqui.
	var rows : Array = [
		["GuildButton", "_on_guild_pressed", "guildWindow", "Guild"],
		["AuctionHouseAccess", "_on_ah_pressed", "auctionHouseWindow", "AuctionHouse"],
		["ArenaAccess", "_on_arena_pressed", "arenaWindow", "Arena"],
	]
	for row in rows:
		var buttonName : String = String(row[0])
		var handlerName : String = String(row[1])
		var fieldName : String = String(row[2])
		var nodeName : String = String(row[3])
		var btn : Button = hud.get_node_or_null(NodePath(buttonName)) as Button
		if not Check(btn != null, "HUD cria o botão %s" % buttonName):
			continue
		CheckI(_ConnectionsTarget(btn, _gui, handlerName), 1, "%s ligado exatamente no handler %s do Gui" % [buttonName, handlerName])
		Check(bool(_gui.has_method(handlerName)), "Gui expõe o handler %s" % handlerName)
		btn.pressed.emit()
		var win : Node = _gui.get(fieldName)
		if Check(win != null, "%s: o handler instanciou a janela (%s)" % [buttonName, fieldName]):
			CheckS(str(win.name), nodeName, "%s: a janela montada é a '%s'" % [buttonName, nodeName])
			Check(bool(win.is_inside_tree()), "%s: a janela está na árvore viva" % buttonName)
			Check(win.get_parent() == _windows, "%s: a janela está sob Gui.windows" % buttonName)
			Check(bool(win.is_visible()), "%s: abrir o botão mostra a janela" % buttonName)

	# Um botão por ação. A barra chegou a ter "AH" e "Leilão" ligados no MESMO
	# `_on_ah_pressed`, e nada acima reclama: os dois checks de corrente passam
	# sozinhos em cada botão, então a duplicata era invisível. Os binds entram na
	# assinatura de propósito — `ManualSkill_Melee` e `ManualSkill_Run` partilham
	# `_on_manual_skill_pressed` com argumentos diferentes, e isso não é duplicata.
	var alvoDeBotao : Dictionary = {}
	var duplicatas : Array[String] = []
	for child in hud.get_children():
		if not (child is Button):
			continue
		var btnName : String = String((child as Button).name)
		for conn in (child as Button).pressed.get_connections():
			var callable : Callable = conn.get("callable", Callable())
			if not callable.is_valid() or callable.get_object() != _gui:
				continue
			var signature : String = callable.get_method() + "|" + str(callable.get_bound_arguments())
			if alvoDeBotao.has(signature):
				duplicatas.append("%s e %s → %s" % [String(alvoDeBotao[signature]), btnName, callable.get_method()])
				continue
			alvoDeBotao[signature] = btnName
	Check(duplicatas.is_empty(), "HUD: nenhum handler do Gui é alvo de dois botões da barra (%s)" % ", ".join(duplicatas))
	Check(hud.get_node_or_null(NodePath("AHButton")) == null, "HUD: a sigla duplicada 'AH' saiu da barra (sobrou o 'Leilão')")

	# ---------------------------------------------------------------- 2) o painel de guilda é a CENA
	var guild : Control = _gui.get("guildWindow") as Control
	if Check(guild != null, "o botão Guilda abriu o GuildPanel (e não a janela Social)"):
		CheckS(str(guild.get_script().resource_path), "res://sources/gui/GuildPanel.gd", "GuildPanel: é o script do painel órfão, agora vivo")
		# O que GuildPanel.gd:24/:284 afirmam do .tscn, medido na instância real.
		var layout : Node = guild.get_node_or_null(NodePath("Layout"))
		Check(layout is VBoxContainer, "GuildPanel.tscn traz o nó 'Layout' (VBoxContainer)")
		var titleBar : Node = guild.get_node_or_null(NodePath("Layout/TitleBar"))
		Check(titleBar != null, "GuildPanel.tscn traz o TitleBar dentro do Layout")
		Check(guild.get_node_or_null(NodePath("Layout/Header")) == null, "BuildUI reusa o TitleBar da cena em vez do cabeçalho próprio")
		# O corpo do painel foi enrolado num ScrollContainer (freio do juiz "botão fora
		# da tela"), então `Info` não mora mais direto em `Layout`: procurar por nome, e
		# conferir que o caminho até ele passa pela rolagem — é exatamente isso que
		# mantém o rótulo alcançável. Procurar caminho fixo aqui acusaria o conserto.
		var infoNode : Node = guild.find_child("Info", true, false)
		if Check(infoNode != null, "BuildUI montou a UI do painel dentro da árvore viva"):
			var walk : Node = infoNode
			var underScroll : bool = false
			while walk != null and walk != guild:
				if walk is ScrollContainer:
					underScroll = true
				walk = walk.get_parent()
			Check(underScroll, "BuildUI pendurou 'Info' dentro do corpo rolável do painel")
		# Um botão, um painel: o segundo clique não pode nascer uma segunda guilda.
		var guildBtn : Button = hud.get_node_or_null(NodePath("GuildButton")) as Button
		if guildBtn != null:
			guildBtn.pressed.emit()
			Check(_gui.get("guildWindow") == guild, "segundo clique reusa a MESMA instância (EnsureGuildPanel)")
		CheckI(_CountByScript(_windows, "res://sources/gui/GuildPanel.gd"), 1, "existe exatamente um painel de guilda na árvore")

	# ---------------------------------------------------------------- 3) os dois gastos ARMAM
	var fake : Dictionary = {
		"ok": true,
		"my_guild": {"name": "HUD Wire Guild", "tag": "HWG", "level": 3, "points": 12,
			"my_rank": "leader", "vault": {"used": 0, "cap": 6}, "members": [], "vault_stacks": [],
			"vault_log": [{"account_id": 4242, "char_id": 77, "item_id": 5, "count": 2,
				"kind": "withdraw", "created_at": 1700000000}]},
		"board": [],
		"vault_slot_cost": 200,
	}
	var network : Node = root.get_node_or_null(NodePath("Network"))
	var client : Object = network.get("Client") if network != null else null
	if Check(client != null, "o NetClient do Network vive no boot (porta do push de guilda)"):
		# O mesmo push que o servidor manda: tem que chegar nos DOIS espelhos, senão
		# ligar o botão só troca uma UI meio viva por outra. O `_peerID` do método é
		# ignorado (é o cache do client + o roteamento para as janelas).
		client.call("GuildState", fake, 0)
		var seen : Dictionary = guild.call("FetchState") if guild != null else {}
		Check(str(_MyGuildName(seen)) == "HUD Wire Guild", "Client.GuildState → GuildPanel.FetchState (painel não fica preso ao snapshot da abertura)")
		Check(_LabelText(_gui.get("socialWindow"), "HUD Wire Guild"), "Client.GuildState → Social.gd: a aba legado continua espelhando o push")

	# §14: o rastro do vault na tela. `vault_log` no estado é a ÚNICA fonte — o
	# painel não tem caminho de SQL, e foi por isso que a linha abaixo desenha do
	# push: um rastro que só aparece quando o cliente lê a tabela ele é escrito no
	# banco e invisível no produto que roda com cliente e servidor separados.
	if guild != null:
		# Locale TRAVADO no do beta, e não no da máquina: a CI sobe com `C`/`en` e o
		# dev com `pt_BR`, e uma asserção sobre idioma que depende disso é o tipo de
		# régua que passa num lugar e quebra no outro sem ninguém ter mudado nada.
		var localeAntes : String = TranslationServer.get_locale()
		TranslationServer.set_locale("pt_BR")
		guild.call("RenderState", fake)
		var trailBox : VBoxContainer = guild.get("vaultLogList") as VBoxContainer
		if Check(trailBox != null, "GuildPanel: a seção do rastro existe no painel construído"):
			var first : Label = trailBox.get_node_or_null(NodePath("Log1")) as Label
			if Check(first != null, "GuildPanel: o movimento do estado vira linha própria no rastro (Log1)"):
				# A palavra do movimento é a do catálogo do jogador, não o token da
				# tabela: antes a linha crua dizia "withdraw" no meio de uma tela em
				# português. Chumbar "saque" aqui é de propósito — amarra a asserção à
				# linha do CSV além de ao `translate()` do produto.
				var kindWord : String = TranslationServer.translate("withdraw")
				CheckS(kindWord, "saque", "rastro: o catálogo pt_BR traduz o token do movimento")
				Check(str(first.text).contains(kindWord) and str(first.text).contains("2 x item 5") and str(first.text).contains("4242"),
					"GuildPanel: a linha do rastro cita saque (%s), quantidade, item e a conta (%s)" % [kindWord, str(first.text)])
			Check(trailBox.get_node_or_null(NodePath("None")) == null,
				"GuildPanel: com movimento no estado o rastro não diz \"nenhum movimento\"")
		TranslationServer.set_locale(localeAntes)

	if guild != null:
		CheckI(int(guild.call("PendingCount")), 0, "GuildPanel: nada armado antes do clique")
		var fastBtn : Button = guild.get("fastButton") as Button
		if Check(fastBtn != null, "GuildPanel: o botão de fast level-up existe"):
			fastBtn.pressed.emit()
			CheckI(int(guild.call("PendingCount")), 1, "GuildPanel: fast level-up ARM_a prévia no clique (não gasta gems)")
			Check(_ModalOpen(), "GuildPanel: quem pede o confirm é o modal da casa (UICommons.MessageBox)")
			var slotBtn : Button = guild.get("slotButton") as Button
			if Check(slotBtn != null, "GuildPanel: o botão de vault slot existe"):
				slotBtn.pressed.emit()
				CheckI(int(guild.call("PendingCount")), 1, "GuildPanel: vault slot também passa pelo portão")
				Check(str(guild.call("PendingLine")).contains("200"), "GuildPanel: a prévia diz o preço em gems (%s)" % str(guild.call("PendingLine")))
			guild.call("CancelPending")
			_CloseModal()
			CheckI(int(guild.call("PendingCount")), 0, "GuildPanel: CancelPending desarma sem emitir nada")

	var social : Control = _gui.get("socialWindow") as Control
	if Check(social != null, "a janela Social legacy continua viva (lista de online + espelho)"):
		Check(bool(social.has_method("ConfirmPending")), "Social.gd: o caminho de gasto tem confirm")
		CheckI(int(social.call("PendingCount")), 0, "Social: nada armado antes do clique")
		social.call("RequestLevelUpFast")
		CheckI(int(social.call("PendingCount")), 1, "Social: fast level-up ARM_a prévia no clique (era um clique = 2x gems)")
		social.call("RequestVaultSlot")
		CheckI(int(social.call("PendingCount")), 1, "Social: vault slot também passa pelo portão (era um clique = 200 gems)")
		social.call("CancelPending")
		_CloseModal()
		CheckI(int(social.call("PendingCount")), 0, "Social: CancelPending desarma")

	_finish()

# ------------------------------------------------------------------ helpers de exame

# Quantos `pressed` do botão apontam exatamente para `target.<methodName>`. É o elo
# botão→handler medido na instância: sem o `connect()` na origem, devolve 0.
func _ConnectionsTarget(btn : Button, target : Object, methodName : String) -> int:
	var hits : int = 0
	for conn in btn.pressed.get_connections():
		var callable : Callable = conn.get("callable", Callable())
		if not callable.is_valid() or callable.get_method() != methodName:
			continue
		if callable.get_object() == target:
			hits += 1
	return hits

func _CountByScript(parent : Node, scriptPath : String) -> int:
	var total : int = 0
	for child in parent.get_children():
		var childScript : Script = child.get_script()
		if childScript != null and str(childScript.resource_path) == scriptPath:
			total += 1
	return total

func _MyGuildName(state : Dictionary) -> String:
	var mine : Dictionary = state.get("my_guild", {})
	return str(mine.get("name", ""))

func _ModalOpen() -> bool:
	var box : Control = _gui.get("messageBox") as Control
	return box != null and bool(box.is_visible())

func _CloseModal() -> void:
	var box : Control = _gui.get("messageBox") as Control
	if box != null and bool(box.is_visible()):
		box.call("Clear")

# A aba de guilda da janela legado é redesenhada inteira a cada push; a prova de que
# ela continua alimentada é o cabeçalho com o nome da guilda no `guildList`.
func _LabelText(social : Control, needle : String) -> bool:
	if social == null:
		return false
	var list : VBoxContainer = social.get("guildList") as VBoxContainer
	if list == null:
		return false
	for child in list.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is Label and str((child as Label).text).contains(needle):
			return true
	return false
