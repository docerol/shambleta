extends SceneTree

# gate-marker: == GUILD ROSTER ACTIONS:
#
# AUDITORIA 2026-10-04 — escopo #193 "SOCIAL: promover/chutar só existe como barra
# digitada e nenhuma régua sentiria um botão aparecer". Antes deste arquivo a fileira de
# membro era `Label` pura: zero `Button`, zero `pressed`, e a única porta para
# promote/demote/kick era o jogador digitar `/guild kick <nick>`. As 56 checks de
# `tests/guild_governance_test.gd` cobriam a AUTORIDADE (posto lido do banco, rastro,
# teto) e nenhuma delas mudava se aparecesse um botão — porque botão nenhum aparecia.
#
# Este harness amarra três coisas que antes não tinham dono:
#   1. o desenho — quem pode vê os cliques, quem não pode, e que o clique chega ao
#      handler com (verb, alvo, conta do alvo);
#   2. a política ↔ o desenho, nos dois sentidos, medidos e não copiados: todo verbo
#      desenhado tem que ser aceito por `Run` (probe de runtime com contas reais) e todo
#      verbo que as bocas de `Run` aceitam tem que estar desenhado, exceto o único que a
#      fileira NÃO pode oferecer (`invite` — o alvo ainda não tem fileira);
#   3. o texto do clique e o texto do chat são os MESMOS bytes, e esses bytes passam de
#      verdade pelo despachante (`CommandManager.Handle`) e mexem em `guild_member`.
#
# Blocos:
#   B1 render puro (sem banco): botões por verbo, auto-linha sem botão, `canAct` falso
#      sem botão, e o `pressed` levando a tripla certa;
#   B2 régua anti-cópia: as bocas de `Run` lidas do arquivo, os verbos desenhados lidos
#      do const map, e os controles plantados das duas direções;
#   B3 painel real (cena `.tscn`) + banco real: clique de líder chuta/promove/devolve no
#      SERVIDOR, rastro em `guild_governance_log`, fileira re-desenhada sem o chutado,
#      oficial NÃO-líder não vê nenhum botão, e a perna de cliente puro não escreve;
#   B4 o mesmo texto pelo chat: `GetAccountID` do alvo, `Handle` despachando, a barra
#      inicial sendo o controle que tem que morder, e a recusa do verbo inexistente.
#
# Uso: bash scripts/test.sh one guild_roster_actions_test
# Exit code = checks falhos. Última linha: `== GUILD ROSTER ACTIONS: N checks, M failures ==`.
#
# Regra dos harnesses `-s` (mesma de `tests/guild_governance_test.gd`): o main-loop
# compila ANTES dos autoloads e dos class_names existirem — nada de identificador de
# autoload (Launcher/Network/Peers) nem `class_name` de projeto em anotação de tipo aqui;
# tudo por `load()` + `get()`/`set()`/`call()`.

var _checks : int = 0
var _fails : int = 0
var _dbScript : GDScript = null
var _launcher : Node = null
var _peers : GDScript = null
var _agentScript : GDScript = null
var _agent : Object = null
var _panel : Control = null
var _sessionAccounts : Array[int] = []

func Check(condition : bool, label : String) -> bool:
	_checks += 1
	if not condition:
		_fails += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

# Assinaturas separadas de propósito (mesma razão de `tests/hud_wiring_test.gd`): um
# `CheckEq(int, int, String)` recebendo String morre em Parse Error no preflight.
func CheckI(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func CheckS(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func CheckHas(haystack : String, needle : String, label : String) -> bool:
	return Check(haystack.contains(needle), "%s — esperado conter '%s', linha: '%s'" % [label, needle, haystack])

func _initialize():
	_run()

func _finish() -> void:
	if _dbScript != null and (_dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		_dbScript.call("DrainPendingPreloads")
	print("== GUILD ROSTER ACTIONS: %d checks, %d failures ==" % [_checks, _fails])
	quit(_fails)

# ------------------------------------------------------------------ B1: o desenho

func _testRender(rosterScript : GDScript, rowVerbs : Array) -> void:
	print("== B1: render puro da fileira ==")
	var drawScript : GDScript = load("res://sources/gui/GuildMemberRoster.gd")
	if not Check(drawScript != null, "GuildMemberRoster carrega"):
		return
	var box := VBoxContainer.new()
	var members : Array = [
		{"name": "alice", "rank": "leader", "account_id": 1001, "nicks": []},
		{"name": "bob", "rank": "member", "account_id": 1002, "nicks": ["Bobby"]},
	]
	var offline := func(_nick : String) -> bool: return false
	var clicks : Array = []
	var recorder := func(verb : String, target : String, targetAccount : int) -> void:
		clicks.append([verb, target, targetAccount])

	# A direção que NÃO pode morder primeiro: sem `canAct`, o roster é exatamente o que
	# era antes do #193 — duas linhas de texto e nenhum botão. Um render que desenha por
	# conta própria passaria em tudo abaixo e não haveria o que acusar.
	drawScript.call("Render", box, members, offline, false, recorder, 1001)
	CheckI(_countButtons(box), 0, "canAct falso: nenhum botão nasce (a régua não pode morder quem não pode mandar)")
	drawScript.call("Render", box, members, offline, true, Callable(), 1001)
	CheckI(_countButtons(box), 0, "sem `onAction` válido: nenhum botão nasce (botão morto seria pior que botão ausente)")

	drawScript.call("Render", box, members, offline, true, recorder, 1001)
	CheckI(box.get_child_count(), 2, "duas fileiras desenhadas")
	CheckI(_countButtons(box), rowVerbs.size(), "a fileira de fora recebe exatamente os verbos da política (%d)" % rowVerbs.size())
	CheckI(_countButtonsInRow(box, 0), 0, "a própria linha de quem olha não ganha botão (auto-kick seria um botão que se recusa)")
	var bobRow : int = _indexOfRow(box, "bob")
	Check(bobRow >= 0, "a fileira de bob existe para ser examinada")
	for verb in rowVerbs:
		var wanted : String = "%sButton" % String(verb).capitalize().replace(" ", "")
		Check(_buttonInRow(box, bobRow, wanted) != null, "verbo desenhado '%s' virou o nó %s" % [String(verb), wanted])
	var kick : Button = _buttonInRow(box, bobRow, "KickButton")
	if Check(kick != null, "KickButton presente para o clique"):
		kick.pressed.emit()
		CheckI(clicks.size(), 1, "um clique, uma emissão (sem dois `connect` no mesmo botão)")
		CheckS(_clickField(clicks, 0), "kick", "o clique nomeia o verbo")
		CheckS(_clickField(clicks, 1), "bob", "e o alvo pelo nome que a fileira mostra")
		CheckI(int(_clickField(clicks, 2)), 1002, "e a conta do alvo, que é o que o funil autoritativo pergunta")
	var promote : Button = _buttonInRow(box, bobRow, "PromoteButton")
	if promote != null:
		promote.pressed.emit()
		CheckS(_clickField(clicks, 0), "promote", "PromoteButton emite promote, não o último verbo do loop")
	Check(_labelInRow(box, bobRow).length() > 0, "a linha continua dizendo quem é o membro e o posto dele")
	box.free()

# O campo do último clique, vazio quando não houve clique nenhum: cortar o `connect`
# da fileira tem que render acusação lida, não índice fora da faixa.
func _clickField(clicks : Array, field : int) -> String:
	if clicks.is_empty():
		return ""
	var last : Array = clicks[clicks.size() - 1]
	return str(last[field]) if last.size() > field else ""

func _countButtons(box : VBoxContainer) -> int:
	var total : int = 0
	for row in box.get_children():
		total += _countButtonsInRow(box, box.get_children().find(row))
	return total

func _countButtonsInRow(box : VBoxContainer, rowIdx : int) -> int:
	if rowIdx < 0:
		return 0
	var row : Node = box.get_child(rowIdx)
	var hits : int = 0
	for child in row.get_children():
		if child is Button:
			hits += 1
	return hits

func _indexOfRow(box : VBoxContainer, needle : String) -> int:
	var idx : int = 0
	for row in box.get_children():
		for child in row.get_children():
			if child is Label and str((child as Label).text).contains(needle):
				return idx
		idx += 1
	return -1

func _labelInRow(box : VBoxContainer, rowIdx : int) -> String:
	if rowIdx < 0:
		return ""
	var out : String = ""
	for child in box.get_child(rowIdx).get_children():
		if child is Label:
			out += str((child as Label).text)
	return out

func _buttonInRow(box : VBoxContainer, rowIdx : int, buttonName : String) -> Button:
	if rowIdx < 0:
		return null
	for child in box.get_child(rowIdx).get_children():
		if child is Button and String((child as Button).name) == buttonName:
			return child as Button
	return null

# ------------------------------------------------------------------ B2: política ↔ desenho

# As bocas de `Run` lidas DO arquivo: um verbo novo na política sem botão na fileira
# acende aqui, e um botão desenhado para um verbo que `Run` não conhece acende na sonda
# de runtime do B4. Nenhuma das duas pontas é uma lista escrita à mão.
func _bocasDeRun(src : String) -> Array[String]:
	var out : Array[String] = []
	var inside : bool = false
	for line in src.split("\n"):
		var s : String = String(line).strip_edges()
		if s.begins_with("static func Run"):
			inside = true
			continue
		if inside and (s.begins_with("static func") or s.begins_with("func ")):
			break
		if inside and s.begins_with("\""):
			var close : int = s.find("\"", 1)
			if close > 1:
				out.append(s.substr(1, close - 1))
	return out

func _desenhadosSemPolitica(drawn : Array, arms : Array) -> Array[String]:
	var out : Array[String] = []
	for verb in drawn:
		if not arms.has(String(verb)):
			out.append(String(verb))
	return out

func _politicaSemDesenho(arms : Array, drawn : Array, exempt : Array) -> Array[String]:
	var out : Array[String] = []
	for verb in arms:
		if not drawn.has(String(verb)) and not exempt.has(String(verb)):
			out.append(String(verb))
	return out

func _testPolicyTie(rosterScript : GDScript, rowVerbs : Array) -> void:
	print("== B2: a fileira e a política, medidas nos dois sentidos ==")
	var src : String = FileAccess.get_file_as_string("res://sources/economy/GuildRoster.gd")
	var arms : Array[String] = _bocasDeRun(src)
	Check(arms.size() >= 4, "as bocas de `Run` foram lidas do arquivo (%s)" % ", ".join(arms))
	Check(rowVerbs.size() > 0, "os verbos desenhados vêm do const map, não de uma lista daqui (%s)" % str(rowVerbs))
	Check(_desenhadosSemPolitica(rowVerbs, arms).is_empty(),
		"todo verbo desenhado é aceito por `Run` (órfãos: %s)" % ", ".join(_desenhadosSemPolitica(rowVerbs, arms)))
	Check(_politicaSemDesenho(arms, rowVerbs, ["invite"]).is_empty(),
		"todo verbo que `Run` aceita está desenhado, exceto o declarado (%s)" % ", ".join(_politicaSemDesenho(arms, rowVerbs, ["invite"])))
	Check(not rowVerbs.has("invite"), "invite fica FORA de propósito: quem ainda não tem fileira não tem onde pendurar o botão")

	# Controles plantados — a régua tem que morder nos dois sentidos e absolvidos não
	# podem ser absolvidos. Nada aqui toca o produto; é a prova de que as duas funções de
	# cima medem e não ecoam.
	var plantedArms : Array[String] = ["kick", "promote", "demote", "invite"]
	Check(_desenhadosSemPolitica(["kick", "promote", "demote"], plantedArms).is_empty(), "controle: fileira honesta é absolvida")
	CheckS(", ".join(_desenhadosSemPolitica(["kick", "teleport"], plantedArms)), "teleport", "controle plantado: verbo desenhado que a política não aceita tem que aparecer")
	CheckS(", ".join(_politicaSemDesenho(plantedArms, ["kick", "promote"], ["invite"])), "demote", "controle plantado: verbo aceito e não desenhado tem que aparecer")
	Check(_politicaSemDesenho(plantedArms, ["kick", "promote", "demote"], ["invite"]).is_empty(), "controle: `invite` isento não acende (a isenção é a única, declarada)")

	# O parser, medido num corpo plantado: se ele só soubesse achar aspas ele diria
	# "gamma"; se ele não soubesse o fim de `Run`, diria "gamma" também.
	var plantedSrc : String = "static func Run(verb : String) -> Dictionary:\n\tmatch verb:\n\t\t\"alpha\": return 1\n\t\t\"beta\": return 2\n\t\t_:\n\t\t\tvar junk : Dictionary = {\"ok\": false}\nstatic func Feedback(verb : String) -> String:\n\t\t\"gamma\": return \"\"\n"
	CheckS(", ".join(_bocasDeRun(plantedSrc)), "alpha, beta", "controle plantado: o parser lê as bocas de `Run` e para em `Run`")

	# O formato do fio: sem a barra inicial o texto é o que o despachante procura, e ele
	# é composto num lugar só — os dois caminhos caem no mesmo `Command` por construção.
	var text : String = String(rosterScript.call("ActionText", "kick", "alice"))
	CheckS(text, "guild kick alice", "`ActionText` compõe o wire format do comando de chat")
	Check(not text.begins_with("/"), "e sem a barra: `Chat` a corta antes de enviar e o despachante procura o nome sem ela")
	Check(rowVerbs.has(text.split(" ")[1]), "o verbo que o texto carrega é um verbo desenhado (a string e a fileira não são duas listas)")

	# Anti-cópia no painel: se `GuildPanel` voltasse a compor "guild ..." na mão, os dois
	# caminhos concordariam só por sorte.
	var panelSrc : String = FileAccess.get_file_as_string("res://sources/gui/GuildPanel.gd")
	Check(panelSrc.contains("GuildRoster.ActionText"), "o painel compõe o texto por `GuildRoster.ActionText`, e não por conta")
	Check(not panelSrc.contains("\"guild \""), "e nenhum literal \"guild \" sobrou no painel (literal é cópia que envelhece)")
	Check(panelSrc.contains("GuildRoster.Command"), "a perna local cai no MESMO funil do chat: `GuildRoster.Command`")
	var worldSrc : String = FileAccess.get_file_as_string("res://sources/world/WorldCommands.gd")
	Check(worldSrc.contains("GuildRoster.Command"), "o ramo de chat também cai em `GuildRoster.Command` — uma boca para os dois caminhos")

# ------------------------------------------------------------------ B3/B4: banco real

func _run() -> void:
	print("== roster actions: o clique que virou o comando ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

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
	if not Check(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit()"):
		_finish()
		return

	var sql : Node = _launcher.get("SQL")
	var eco : Node = _launcher.get("Economy")
	if not Check(sql != null and eco != null, "SQL + Economy booteds"):
		_finish()
		return
	if eco.get("guildService") == null:
		eco.call("_post_launch")

	var rosterScript : GDScript = load("res://sources/economy/GuildRoster.gd")
	if not Check(rosterScript != null, "GuildRoster carrega"):
		_finish()
		return
	var rowVerbs : Array = (rosterScript.get_script_constant_map() as Dictionary).get("RowVerbs", [])

	_testRender(rosterScript, rowVerbs)
	_testPolicyTie(rosterScript, rowVerbs)

	# ------------------------------------------------------------------ fixtures reais
	var guildName : String = "Roster Actions Guild"
	_janitor(sql, guildName)
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'GldAct%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'gldact\\_%';", [])
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var charA : int = int(suites.call("CreateFixture", sql, "gldact_a", "GldActA"))
	var charB : int = int(suites.call("CreateFixture", sql, "gldact_b", "GldActB"))
	var charC : int = int(suites.call("CreateFixture", sql, "gldact_c", "GldActC"))
	if not Check(charA != 0 and charB != 0 and charC != 0, "fixtures criados (%d/%d/%d)" % [charA, charB, charC]):
		_finish()
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", charA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", charB))
	var acctC : int = int(sql.call("GetAccountIDForCharacter", charC))
	var userA : String = _username(sql, acctA)
	var userB : String = _username(sql, acctB)
	var userC : String = _username(sql, acctC)
	var guildID : int = int(eco.call("CreateGuild", acctA, charA, guildName))
	if not Check(guildID > 0, "A fundou %s (#%d)" % [guildName, guildID]):
		_finish()
		return
	Check(bool(eco.call("JoinGuild", acctB, guildID)), "B entrou")
	Check(bool(eco.call("JoinGuild", acctC, guildID)), "C entrou")

	print("== B3: o painel real e o banco ==")
	var packed : PackedScene = load("res://presets/gui/GuildPanel.tscn")
	if not Check(packed != null, "a cena do GuildPanel carrega"):
		_cleanup(sql, guildName)
		_finish()
		return
	_panel = packed.instantiate() as Control
	var gui : Node = _launcher.get("GUI")
	var windows : Node = gui.get("windows") if gui != null else null
	if windows != null:
		windows.add_child(_panel)
	else:
		root.add_child(_panel)
	_panel.visible = true
	await process_frame
	await process_frame
	_panel.call("SetLocalIDs", acctA, charA)
	_panel.call("Refresh")
	var membersList : VBoxContainer = _panel.get("membersList") as VBoxContainer
	if not Check(membersList != null, "o painel construído tem a lista de membros"):
		_cleanup(sql, guildName)
		_finish()
		return
	# O estado é o do servidor (`GetGuildState`), não um dicionário escrito aqui: os
	# `account_id` desenhados são os que a guilda tem no banco.
	CheckI(membersList.get_child_count(), 3, "três fileiras desenhadas do estado real")
	var rowB : int = _indexOfRow(membersList, userB)
	var rowC : int = _indexOfRow(membersList, userC)
	Check(rowB >= 0 and rowC >= 0, "as fileiras de B e C existem para ser clicadas")
	CheckI(_countButtonsInRow(membersList, _indexOfRow(membersList, userA)), 0, "o líder não vê botão na própria linha")
	CheckI(_countButtonsInRow(membersList, rowB), rowVerbs.size(), "o líder vê em B exatamente os verbos da política")
	var kickB : Button = _buttonInRow(membersList, rowB, "KickButton")
	if not Check(kickB != null, "o KickButton de B está na árvore real (não só no render puro)"):
		_cleanup(sql, guildName)
		_finish()
		return
	kickB.pressed.emit()
	await process_frame
	CheckEq(_memberOf(sql, acctB), 0, "o clique removeu B do SERVIDOR — o banco mudou, não só a tela")
	CheckEq(_govCount(sql, guildID, "kick"), 1, "e o kick do clique deixou o mesmo rastro que o comando digitado deixaria")
	var feedback : Label = _panel.get("feedbackLabel") as Label
	CheckHas(str(feedback.text), "removed from the guild", "a resposta na tela é a frase do servidor, não 'enviado'")
	CheckHas(str(feedback.text), userB, "e nomeia quem foi removido")
	CheckI(membersList.get_child_count(), 2, "a fileira re-desenhada do estado fresco não tem mais B")

	var promoteC : Button = _buttonInRow(membersList, _indexOfRow(membersList, userC), "PromoteButton")
	if Check(promoteC != null, "PromoteButton de C na árvore real"):
		promoteC.pressed.emit()
		await process_frame
		CheckS(_rankOf(sql, acctC), "officer", "o clique promoveu C no banco")
		CheckHas(str(feedback.text), "officer", "e a tela diz o posto novo")
		CheckEq(_govCount(sql, guildID, "promote"), 1, "promote do clique também rasteia")

	# A direção que NÃO pode morder: oficial não é líder, e os três verbos exigem líder.
	_panel.call("SetLocalIDs", acctC, charC)
	_panel.call("Refresh")
	CheckI(_countButtons(membersList), 0, "oficial (não-líder) não vê nenhum botão de fileira — ver três recusas por clique não é uma porta")

	# A perna de cliente puro: sem service neste processo, o clique não escreve nada
	# localmente; ele compõe o texto e sai pelo facade.
	_panel.call("SetLocalIDs", acctA, charA)
	_panel.call("Refresh")
	_launcher.set("Economy", null)
	var sent : bool = bool(_panel.call("RosterAction", "kick", userC, acctC))
	_launcher.set("Economy", eco)
	Check(not sent, "cliente puro: o clique não afirma ter feito (a perna local não existe)")
	CheckEq(_memberOf(sql, acctC), guildID, "e nada foi escrito no banco por essa perna")
	CheckHas(str(feedback.text), "sent to the server", "a tela diz 'enviado', que é o que de fato aconteceu")

	print("== B4: o MESMO texto pelo despachante do chat ==")
	var cmdScript : GDScript = load("res://sources/debug/CommandManager.gd")
	var registered : Dictionary = cmdScript.get("commands")
	Check(registered.has(StringName("guild")), "'guild' está registrado no CommandManager (é para lá que o texto vai)")
	var guildCmd : Object = registered.get(StringName("guild"), null)
	Check(guildCmd != null and int(guildCmd.get("_permission")) == 0, "e é permissão NONE — instrumento do jogador comum, não de GM")

	var worldCommands : GDScript = load("res://sources/world/WorldCommands.gd")
	CheckI(int(worldCommands.call("GetAccountID", userC)), acctC, "o alvo que a fileira mostra resolve para a mesma conta que o clique carregava")

	_agent = _makeAgent(charA, "GldActCharA")
	var pid : int = _openSession(acctA, charA)
	if Check(_agent != null and pid > 0, "líder com agente vivo e sessão (o despachante fala com a rede)"):
		_agent.set("peerID", pid)
		_agent.set("characterID", charA)
		# Sonda de runtime do sentido "todo verbo desenhado é aceito": com um alvo que NÃO
		# é da guilda, nenhum dos três cai em `bad_args` — que é exatamente o que um verbo
		# inventado faria. Alvo de fora é de propósito: a sonda mede o `match` sem escrever
		# nada, e é a ponta que o parser de texto não pode fingir.
		for verb in rowVerbs:
			var probed : Dictionary = rosterScript.call("Run", String(verb), acctA, 987654)
			Check(str(probed.get("reason", "")) != "bad_args", "run('%s') existe: o veredito não é bad_args (foi '%s')" % [String(verb), str(probed.get("reason", ""))])
		CheckEq(_memberCount(sql, guildID), 2, "e a sonda não escreveu nada — a fileira continua com dois")
		var typed : String = String(rosterScript.call("ActionText", "demote", userC))
		cmdScript.call("Handle", _agent, typed)
		await process_frame
		CheckS(_rankOf(sql, acctC), "member", "'%s' pelo chat desfez a promoção — o texto do clique é o texto do chat" % typed)
		CheckEq(_govCount(sql, guildID, "demote"), 1, "e deixou o rastro do mesmo verbo")
		# O controle que tem que morder: com a barra, o despachante não conhece o comando
		# e o banco não se move. É por isso que `ActionText` não a emite.
		cmdScript.call("Handle", _agent, "/" + typed)
		await process_frame
		CheckS(_rankOf(sql, acctC), "member", "'/...' com barra não faz nada (o wire format não leva barra)")
		CheckEq(_govCount(sql, guildID, "demote"), 1, "e não deixa segundo rastro — a recusa não escreve")
		var ghost : String = String(rosterScript.call("ActionText", "teleport", userC))
		cmdScript.call("Handle", _agent, ghost)
		await process_frame
		CheckEq(_govCount(sql, guildID, "teleport"), 0, "e um verbo que a política não tem não deixa rastro nenhum")

	_cleanup(sql, guildName)
	_closeSessions()
	if _panel != null and is_instance_valid(_panel):
		_panel.free()
	if _agent != null and is_instance_valid(_agent):
		_agent.free()
	_finish()

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

# ------------------------------------------------------------------ helpers de sessão

func _makeAgent(charID : int, nick : String) -> Object:
	var entities : Dictionary = _dbScript.get("EntitiesDB")
	var data : Object = entities.get(int(_dbScript.get("PlayerHash")), null)
	if data == null:
		return null
	var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var typeMap : Variant = (actorCommons.get_script_constant_map() as Dictionary).get("Type", {})
	var typePlayer : Variant = typeMap.get("PLAYER", -1)
	_agentScript = load("res://sources/actor/agent/variants/PlayerAgent.gd")
	return _agentScript.new(int(typePlayer), data, nick, true)

func _openSession(accountID : int, charID : int) -> int:
	_peers = load("res://sources/network/server/Peers.gd")
	var candidate : int = 840000 + accountID
	while bool(_peers.HasPeer(candidate)):
		candidate += 1
	_peers.AddPeer(candidate, 0)
	var peer : Object = _peers.GetPeer(candidate)
	if peer == null:
		return 0
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(_peers.accounts as Dictionary)[accountID] = candidate
	_sessionAccounts.append(accountID)
	return candidate

func _closeSessions() -> void:
	if _peers == null:
		return
	var accounts : Dictionary = _peers.accounts as Dictionary
	for pid in (_peers.peers as Dictionary).keys():
		if int(pid) >= 840000:
			_peers.RemovePeer(int(pid))
	for acct in _sessionAccounts:
		accounts.erase(int(acct))

# ------------------------------------------------------------------ leituras de banco

# O alvo que a fileira mostra É o username da conta (`GetGuildState` responde `name` com
# username), e é esse token que `ActionText` compõe e que `GetAccountID` resolve. Ler a
# string direto da tabela é o que impede a régua de acreditar no próprio fixture.
func _username(sql : Node, accountID : int) -> String:
	var rows : Array = sql.call("QueryBindings", "SELECT username FROM account WHERE account_id = ?;", [accountID])
	return str((rows[0] as Dictionary).get("username", "")) if not rows.is_empty() else ""

func _rankOf(sql : Node, accountID : int) -> String:
	var rows : Array = sql.call("QueryBindings", "SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str((rows[0] as Dictionary).get("rank", "")) if not rows.is_empty() else ""

func _memberOf(sql : Node, accountID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int((rows[0] as Dictionary).get("guild_id", 0)) if not rows.is_empty() else 0

func _memberCount(sql : Node, guildID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID])
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _govCount(sql : Node, guildID : int, action : String) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM guild_governance_log WHERE guild_id = ? AND action = ?;", [guildID, action])
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _janitor(sql : Node, guildName : String) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_governance_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])

func _cleanup(sql : Node, guildName : String) -> void:
	_janitor(sql, guildName)
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'GldAct%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'gldact\\_%';", [])
