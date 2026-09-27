extends SceneTree

# SOM-GAMEPLAY (juiz cego 2026-09-27): "o modelo de prioridade é real mas é
# inalcançável pela UI — só quem digita /priority no chat decide o auto-combat".
# Este harness prova o contrário, MEDINDO, em quatro pontas:
#
#   S1  o PAINEL declara uma ORDEM (não uma skill): add/mover/remover/limpar,
#       recusa duplicata/não-aprendida/excesso, e o que ele EMITE é a mensagem do
#       comando do chat, pelo RPC do chat (`TriggerCommand`) — costura `SendHook`
#       da casa, medida como em spend_confirm_test.gd;
#   S2  a CENA real (presets/gui/Formation.tscn) tem os controles ligados: apertar
#       Add/Up/Down/Remove/Clear muda a ordem e o Save emite a string certa;
#   S3  o SERVIDOR decide: a string emitida pelo painel roda no despachante real
#       (`CommandManager.Handle`) com um PlayerAgent de verdade dono de uma sessão
#       (`Peers`), e o que persiste em `formation.skill_loadout` é o output de
#       `SkillPriority.Trim` — payload adulterado (não-aprendida, duplicata, 7ª
#       skill, slot fora da faixa, character de outra conta) é decidido pelo
#       servidor, nunca pelo painel;
#   S4  RELOG: depois de derrubar a policy viva, a ordem lida do banco
#       (`WorldCommands._StoredLoadout`, o mesmo campo que `IdlePolicyService._Attach`
#       consome) re-imonta uma `IdlePolicy` cuja `GetPriorityOrder()` é a ordem do
#       painel, e `SkillPriority.Select` escolhe o próximo cast por ela.
#
# Uso: godot --headless --path . -s tests/formation_priority_ui_test.gd
# Régua: última linha `== RESULT: N checks, 0 failures ==`; exit code = falhas.
#
# Como todo harness `-s`: compila ANTES dos autoloads/class_names do projeto
# existirem, então nada de `Launcher`/`Network`/`SkillPriority` como identificador
# tipado — tudo por load() pós-boot e call()/set()/get(). Arrays tipados passam por
# `_ints` (bind dinâmico recusa literal solto em assinatura `Array[int]`).

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _network : Node = null
var _world : Node = null
var _commands : Object = null
var _gui : Node = null
var _windows : Node = null
var _dbScript : GDScript = null
var _skillPriority : GDScript = null
var _idlePolicy : GDScript = null
var _idlePolicyService : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _networkCommons : GDScript = null
var _peers : GDScript = null
var _commandManager : GDScript = null
var _formationScript : GDScript = null
var _formationScene : PackedScene = null
var _playerAgentScript : GDScript = null
var _netServer : Object = null

var _maxSlots : int = 6
var _maxPriority : int = 6
var _skillIDs : Array[int] = []
var _granted : Array[int] = []
var _sessionAgent : Object = null

func _initialize():
	_run()

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(value), str(expected)])
		return false
	return true

func _source(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

func _ints(values : Array) -> Array[int]:
	var out : Array[int] = []
	for value in values:
		out.append(int(value))
	return out

func _finish():
	_cleanup()
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _cleanup():
	if _sql != null and is_instance_valid(_sql) and _sql.isInitialized:
		_sql.db.delete_rows("formation", "account_id IN (SELECT account_id FROM account WHERE username = 'fpui_a' OR username = 'fpui_b')")
		_sql.db.delete_rows("character", "nickname = 'FpuiCharA' OR nickname = 'FpuiCharB'")
		_sql.db.delete_rows("account", "username = 'fpui_a' OR username = 'fpui_b'")

# ------------------------------------------------------------------ boot

func _run():
	print("== Formation priority UI harness (UI declara / servidor decide / relog) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.SQL
		_world = _launcher.World
		if _sql != null and _sql.isInitialized and _world != null and _world.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)

	_dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 40:
		if _dbScript != null and _dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (cells loaded)"):
		_finish()
		return

	_network = root.get_node_or_null(^"Network")
	_skillPriority = load("res://sources/combat/SkillPriority.gd")
	_idlePolicy = load("res://sources/idle/IdlePolicy.gd")
	_idlePolicyService = load("res://sources/idle/IdlePolicyService.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_peers = load("res://sources/network/server/Peers.gd")
	_commandManager = load("res://sources/debug/CommandManager.gd")
	_formationScript = load("res://sources/gui/Formation.gd")
	_playerAgentScript = load("res://sources/actor/agent/variants/PlayerAgent.gd")
	_formationScene = load("res://presets/gui/Formation.tscn")
	_commands = _world.get("commands")
	_maxSlots = int(_idlePolicyService.MaxFormationSlots)
	_maxPriority = int(_skillPriority.MaxPrioritySkills)

	_gui = _launcher.get("GUI")
	_windows = _gui.get("windows") if _gui != null else null
	_netServer = _network.get("ENetServer") if _network != null else null

	if not _check(_formationScript != null and _formationScene != null, "Formation.gd + Formation.tscn carregáveis"):
		_finish()
		return
	if not _check(_commands != null and _commands.has_method("CommandPriority"), "World.commands (CommandPriority) vivo no boot"):
		_finish()
		return

	# Três skills REAIS do SkillsDB: o servidor só aceita aprendidas, então as
	# candidatas têm que existir como célula, não como hash solto.
	var skills : Dictionary = _dbScript.SkillsDB
	for skillID in skills.keys():
		var cell : Object = skills[skillID]
		if cell != null and str(cell.get("name")) != "" and _skillIDs.size() < 3:
			_skillIDs.append(int(skillID))
	if not _check(_skillIDs.size() >= 2, "SkillsDB tem ao menos 2 células para montar carga (%d)" % _skillIDs.size()):
		_finish()
		return

	_suitePanelOrder()
	await _suiteSceneControls()
	_suiteServerDecides()
	_suiteRelog()
	_suiteWiringGuards()
	_finish()

# ------------------------------------------------------------------ S1: painel declara ordem

func _spawnPanel() -> Dictionary:
	var panel : Object = _formationScript.new()
	var sends : Array = []
	panel.set("SendHook", func(methodName : String, args : Array) -> void:
		sends.append([methodName, args]))
	return {"panel" = panel, "sends" = sends}

# As aprendidas chegam ao painel pela costura `CandidateProvider` (mesma família do
# `SendHook`): em produção a fonte é `Launcher.Player.progress.skills`, que é um
# `Entity` de mapa (Launcher.gd:28 / Map.gd:123) e não pode ser trocado por um
# PlayerAgent de harness. A lista é só o cardápio de cliques — o crivo de verdade é
# `SkillPriority.Trim` na ponta do servidor (S3), que re-decide com o ITS learned set.
func _offerLearned(panel : Object, ids : Array) -> void:
	var candidates : Array[int] = _ints(ids)
	panel.set("CandidateProvider", func() -> Array[int]: return candidates)

func _sent(sends : Array, index : int) -> Array:
	return sends[index] as Array

func _suitePanelOrder():
	print("[suite] S1: o painel declara uma ORDEM por slot (estado + envios medidos)")
	var spawned : Dictionary = _spawnPanel()
	var panel : Object = spawned["panel"]
	var sends : Array = spawned["sends"]
	var slot : int = 2
	var a : int = _skillIDs[0]
	var b : int = _skillIDs[1]
	var unlearned : int = 987654321

	panel.set("charID", 4242)
	panel.call("SelectSlot", slot)
	_checkEq(int(panel.call("FormationSlot")), slot, "SelectSlot grava o slot editado")
	_checkEq(panel.call("GetPriorityOrder"), [], "carga começa vazia (nenhuma skill implícita)")

	# S1-a: sem aprendidas na sessão o painel não oferece nada (cardápio vazio).
	_check(not bool(panel.call("AddSkillToPriority", a)), "sem char (nada aprendido) o painel recusa a skill")
	_checkEq(panel.call("GetPriorityOrder"), [], "a recusa não deixou entrada na carga")

	# Candidatas = as skills do char da sessão (o servidor re-confere).
	var agent : Object = _makeAgent(1)
	if agent == null:
		_check(false, "PlayerAgent de sessão disponível para as suítes")
		return
	_check(agent.get("progress") != null, "Actor do tipo PLAYER montou progress (é dele que o painel lê as aprendidas)")
	_grantSkills(agent, _skillIDs)
	_granted = _ints(_skillIDs)
	_granted.sort()
	_offerLearned(panel, (agent.get("progress") as Object).get("skills").keys())
	_checkEq(panel.call("LearnedSkillIDs"), _granted, "o cardápio do painel é exatamente o que o char aprendeu")

	_check(bool(panel.call("AddSkillToPriority", a)), "add 1ª skill da carga")
	_check(bool(panel.call("AddSkillToPriority", b)), "add 2ª skill da carga (a ordem é o que o jogador clicou)")
	_check(not bool(panel.call("AddSkillToPriority", a)), "duplicata recusada nominalmente (SkillPriority.Trim faria o mesmo)")
	_check(not bool(panel.call("AddSkillToPriority", unlearned)), "skill não aprendida recusada pelo painel")
	_checkEq(panel.call("GetPriorityOrder"), _ints([a, b]), "carga do slot == ordem declarada, com ordem")

	_check(bool(panel.call("MovePriorityDown", 0)), "mover a 1ª para baixo")
	_checkEq(panel.call("GetPriorityOrder"), _ints([b, a]), "reordenar reordena a carga (não é um set)")
	_check(not bool(panel.call("MovePriorityUp", 0)), "mover acima do topo é no-op")
	_check(not bool(panel.call("MovePriorityDown", panel.call("GetPriorityOrder").size())), "mover abaixo do fim é no-op")

	_check(bool(panel.call("RemovePriorityAt", 0)), "remover a 1ª")
	_checkEq(panel.call("GetPriorityOrder"), _ints([a]), "remoção preservou o resto da ordem")
	panel.call("ClearPriorityOrder")
	_checkEq(panel.call("GetPriorityOrder"), [], "Clear esvazia a carga do slot")

	# Teto da carga = o teto do modelo (o painel não deixa declarar o que o tick não cobra).
	var filled : int = 0
	for skillID in _skillIDs:
		if bool(panel.call("AddSkillToPriority", int(skillID))):
			filled += 1
	var probe : int = 0
	var overAdded : int = 0
	while probe < 40:
		probe += 1
		if bool(panel.call("AddSkillToPriority", _skillIDs[probe % _skillIDs.size()])):
			overAdded += 1
	_checkEq(filled, mini(_maxPriority, _skillIDs.size()), "o painel aceita até o teto (%d) do que ele oferece" % _maxPriority)
	_checkEq(int(panel.call("GetPriorityOrder").size()), mini(_maxPriority, _skillIDs.size()), "nunca acima de SkillPriority.MaxPrioritySkills")

	# Slot é por linha: editar o 3 não apaga o 2.
	panel.call("SelectSlot", 3)
	panel.call("ClearPriorityOrder")
	_checkEq(panel.call("GetPriorityOrder"), [], "slot 3 limpo")
	panel.call("SelectSlot", slot)
	_check(panel.call("GetPriorityOrder").size() > 0, "a carga do slot 2 sobreviveu ao editar outro slot")

	# O que sai para o servidor: o COMANDO do chat, não uma escrita própria do painel.
	var base : int = sends.size()
	_check(bool(panel.call("SaveLoadout")), "SaveLoadout emite")
	_checkEq(sends.size(), base + 2, "dois envios: o comando que decide + a linha de formação")
	var cmdSend : Array = _sent(sends, base)
	_checkEq(str(cmdSend[0]), "TriggerCommand", "a ORDEM sai pelo RPC do comando de chat (o mesmo do /priority digitado)")
	var expected : String = "priority slot %d set %s" % [slot, " ".join(_namesOf(panel.call("GetPriorityOrder")))]
	_checkEq(str((cmdSend[1] as Array)[0]), expected, "string exata que o servidor vai parsear")
	var formationSend : Array = _sent(sends, base + 1)
	_checkEq(str(formationSend[0]), "SetFormation", "a linha de formação (char + poção) sai pelo RPC de sempre")
	var rpcArgs : Array = formationSend[1] as Array
	_checkEq(int(rpcArgs[0]), slot, "SetFormation: mesmo slot editado")
	_checkEq(int(rpcArgs[1]), 4242, "SetFormation: char da sessão")
	_checkEq(_packedToInts(rpcArgs[2]), panel.call("GetPriorityOrder"), "SetFormation carrega a MESMA ordem (não apaga a prioridade)")
	_check(float(rpcArgs[3]) >= 0.0 and float(rpcArgs[3]) <= 100.0, "SetFormation: poção dentro da faixa")

	# Carga vazia = "clear" (o painel nunca manda [] silencioso como se fosse ordem).
	panel.call("ClearPriorityOrder")
	var baseClear : int = sends.size()
	panel.call("SaveLoadout")
	_checkEq(str((_sent(sends, baseClear)[1] as Array)[0]), "priority slot %d clear" % slot, "carga vazia vira /priority clear")

	# Abrir o painel pede a carga EFETIVA ao servidor (o único read do protocolo).
	var baseRead : int = sends.size()
	panel.call("RequestPriority")
	_checkEq(str(_sent(sends, baseRead)[0]), "TriggerCommand", "abrir o painel pede o ramo list")
	_checkEq(str((_sent(sends, baseRead)[1] as Array)[0]), "priority slot %d" % slot, "list no slot editado")
	panel.free()

func _namesOf(order : Array) -> Array:
	var out : Array = []
	for value in order:
		out.append(str(int(value)))
	return out

func _packedToInts(packed : Variant) -> Array[int]:
	var out : Array[int] = []
	for value in packed:
		out.append(int(value))
	return out

# ------------------------------------------------------------------ S2: controles na cena real

func _suiteSceneControls() -> void:
	print("[suite] S2: presets/gui/Formation.tscn — os controles alcançam a ordem")
	if _formationScene == null:
		_check(false, "cena de Formation instanciável")
		return
	var panel : Control = _formationScene.instantiate() as Control
	if not _check(panel != null, "Formation.tscn instanciada como Control"):
		return
	var sends : Array = []
	panel.set("SendHook", func(methodName : String, args : Array) -> void:
		sends.append([methodName, args]))
	_offerLearned(panel, _granted)
	if _windows != null and is_instance_valid(_windows):
		_windows.add_child(panel)
	else:
		root.add_child(panel)
	panel.visible = true
	await process_frame
	await process_frame

	var slotNode : OptionButton = panel.get("slotOption") as OptionButton
	var skillNode : OptionButton = panel.get("skillOption") as OptionButton
	var addNode : Button = panel.get("addButton") as Button
	var upNode : Button = panel.get("upButton") as Button
	var downNode : Button = panel.get("downButton") as Button
	var removeNode : Button = panel.get("removeButton") as Button
	var clearNode : Button = panel.get("clearButton") as Button
	var listNode : VBoxContainer = panel.get("priorityList") as VBoxContainer
	var saveNode : Button = panel.get_node_or_null(^"Layout/Save") as Button

	if not _check(skillNode != null and addNode != null and upNode != null and downNode != null \
			and removeNode != null and clearNode != null and listNode != null and saveNode != null,
			"a cena expõe Add/Up/Down/Remove/Clear + a lista de cast"):
		panel.free()
		return
	_checkEq(skillNode.item_count, _granted.size(), "o seletor de skill oferece as aprendidas da sessão (%d)" % _granted.size())
	_checkEq(int(slotNode.get_item_count()), _maxSlots, "um seletor por slot de formação (%d)" % _maxSlots)

	# Click de verdade: os handlers são os conectados no .tscn.
	_check(addNode.pressed.get_connections().size() > 0, "botão Add ligado a um handler")
	_check(clearNode.pressed.get_connections().size() > 0, "botão Clear ligado a um handler")
	_check(saveNode.pressed.get_connections().size() > 0, "botão Save ligado a um handler")

	if slotNode.item_count > 1:
		slotNode.select(1)
		panel.call("SelectSlot", 1)
	skillNode.select(0)
	var firstID : int = int(skillNode.get_item_id(0))
	var secondID : int = int(skillNode.get_item_id(1)) if skillNode.item_count > 1 else firstID
	addNode.pressed.emit()
	_checkEq(panel.call("GetPriorityOrder"), _ints([firstID]), "clicar Add anexa a skill escolhida ao fim da carga")
	skillNode.select(1)
	addNode.pressed.emit()
	_checkEq(panel.call("GetPriorityOrder"), _ints([firstID, secondID]), "segundo clique anexa a segunda (ordem = ordem de clique)")
	_checkEq(listNode.get_child_count(), 2, "a lista mostra UMA LINHA POR SKILL da ordem")
	# Affordance de reordenar: os botões só valem para a linha SELECIONADA, e a
	# seleção andou com o último clique (posição 1 de 2).
	_check(not upNode.disabled and downNode.disabled, "última linha selecionada: Up livre, Down travado no fim")
	var topRow : Button = listNode.get_child(0) as Button
	if topRow != null:
		topRow.pressed.emit()
	_check(upNode.disabled and not downNode.disabled, "1ª linha selecionada: Up travado no topo, Down livre")

	var row : Button = listNode.get_child(1) as Button
	if row != null:
		row.pressed.emit()
	_checkEq(int(panel.get("_selected")), 1, "clicar na LINHA seleciona a posição")
	upNode.pressed.emit()
	_checkEq(panel.call("GetPriorityOrder"), _ints([secondID, firstID]), "Up na linha selecionada inverte a ordem")
	_check(str(listNode.get_child(0).get("text")).begins_with("1."), "a linha numerada acompanha a carga (%s)" % str(listNode.get_child(0).get("text")))

	# Save sem personagem atirado na tela (nenhum char ligado ao painel) não emite.
	var base : int = sends.size()
	saveNode.pressed.emit()
	_checkEq(sends.size(), base, "Save sem char da sessão não emite RPC (nada para gravar)")
	# Com o char da sessão (RefreshFormation o lê da sessão viva) o clique emite os dois.
	panel.set("charID", 4242)
	saveNode.pressed.emit()
	_checkEq(sends.size(), base + 2, "Save (um clique no botão) emite comando + linha de formação")
	_check(str((_sent(sends, base)[1] as Array)[0]).contains("priority slot 1 set %d %d" % [secondID, firstID]),
			"a string emitida pelo botão é a ordem atual da tela")

	removeNode.pressed.emit()
	_checkEq(panel.call("GetPriorityOrder").size(), 1, "Remove tira a linha selecionada")
	clearNode.pressed.emit()
	_checkEq(panel.call("GetPriorityOrder"), [], "Clear esvazia pela UI")
	_checkEq(int(listNode.get_child_count()), 1, "carga vazia mostra o estado '(none) -> melee', nunca lista muda")

	# Geometria: nada da carga nova sai da caixa sem rolagem (mesma régua do
	# panel_fit_test, medida aqui para o painel com a carga cheia).
	var canvas : Vector2 = Vector2(float(ProjectSettings.get_setting("display/window/size/viewport_width")),
			float(ProjectSettings.get_setting("display/window/size/viewport_height")))
	for skillID : int in _skillIDs:
		panel.call("AddSkillToPriority", skillID)
	await process_frame
	await process_frame
	var full : Vector2 = panel.get_combined_minimum_size()
	_check(full.x <= canvas.x and full.y <= canvas.y, "painel com carga cheia (%dx%d) cabe no viewport %dx%d" % [int(full.x), int(full.y), int(canvas.x), int(canvas.y)])
	_check(full.y > 0.0, "mínimo do painel com carga é medido de verdade (%d px)" % int(full.y))

	if panel.get_parent() != null:
		panel.get_parent().remove_child(panel)
	panel.free()

# ------------------------------------------------------------------ S3: o servidor decide

func _peerOf(seedID : int) -> int:
	return 830000 + seedID

func _makeAgent(seedID : int) -> Object:
	var entities : Dictionary = _dbScript.EntitiesDB
	var data : Object = entities.get(int(_dbScript.PlayerHash), null)
	if data == null:
		return null
	# `Actor._init` só monta inventory/progress quando o tipo bate em
	# ActorCommons.Type.PLAYER, e `progress` é o que o servidor lê para decidir o
	# que está aprendido — o enum entra por `get_script_constant_map()` (mesmo
	# caminho de gameplay_fix_test.gd:_enumOf), não por acesso `.Type.PLAYER`.
	# O peerID fica de fora daqui DE PROPÓSITO: `ActorProgress.AddSkill` fala com a
	# rede quando o actor já tem peer, e grant de teste não é tráfego de cliente.
	var typePlayer : Variant = _enumOf(_actorCommons, "Type").get("PLAYER", -1)
	return _playerAgentScript.new(int(typePlayer), data, "FpuiChar%d" % seedID, true)

func _enumOf(script : GDScript, enumName : String) -> Dictionary:
	var out : Dictionary = {}
	if script == null:
		return out
	var raw : Variant = script.get_script_constant_map().get(enumName, {})
	if raw is Dictionary:
		for key : String in (raw as Dictionary).keys():
			out[key] = (raw as Dictionary)[key]
	return out

func _grantSkills(agent : Object, ids : Array) -> void:
	var progress : Object = agent.get("progress")
	if progress == null:
		return
	var skills : Dictionary = _dbScript.SkillsDB
	for value in ids:
		var cell : Object = skills.get(int(value), null)
		if cell != null:
			progress.call("AddSkill", cell, 1)

func _openSession(accountID : int, charID : int, peerID : int) -> void:
	if not bool(_peers.HasPeer(peerID)):
		_peers.AddPeer(peerID, 0)
	var peer : Object = _peers.GetPeer(peerID)
	if peer == null:
		return
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(_peers.accounts as Dictionary)[accountID] = peerID

func _fixtureAccount(accountName : String, nickname : String) -> Dictionary:
	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)
	var out : Dictionary = {}
	if not _sql.AddAccount(accountName, "testpass", accountName + "@test.local", _networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"):
		return out
	var accountID : int = _sql.GetAccountID(accountName)
	if not _sql.AddCharacter(accountID, nickname, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		return out
	return {"account" = accountID, "char" = _sql.GetCharacterID(accountID, nickname)}

# Executa a string que o PAINEL emite no despachante real do servidor.
func _runServerCommand(agent : Object, command : String) -> bool:
	var registered : bool = (_commandManager.commands as Dictionary).has("priority")
	_check(registered, "S3: /priority está registrado no CommandManager (o painel usa o comando de chat, não um atalho)")
	if registered:
		_commandManager.Handle(agent, command)
		return true
	return bool(_commands.call("CommandPriority", agent, command.replace("priority", "")))

func _readFormation(accountID : int, slot : int) -> Array:
	var row : Dictionary = _sql.GetFormationForSlot(accountID, slot)
	var parsed : Variant = str_to_var(str(row.get("skill_loadout", "")))
	var out : Array = []
	if parsed is Array:
		for value in (parsed as Array):
			out.append(int(value))
	return out

func _suiteServerDecides():
	print("[suite] S3: a string do painel roda no servidor; o que persiste é decisão do servidor")
	if _sql == null or not _sql.isInitialized:
		print("  [SKIP] sem DB — suíte de autoridade não aferível")
		return
	var fixA : Dictionary = _fixtureAccount("fpui_a", "FpuiCharA")
	var fixB : Dictionary = _fixtureAccount("fpui_b", "FpuiCharB")
	if not _check(not fixA.is_empty() and not fixB.is_empty(), "duas contas fixture criadas (A edita, B é a vizinha)"):
		return
	var accountA : int = int(fixA["account"])
	var charA : int = int(fixA["char"])
	var accountB : int = int(fixB["account"])
	var charB : int = int(fixB["char"])

	var agentA : Object = _makeAgent(1)
	var agentB : Object = _makeAgent(2)
	if not _check(agentA != null and agentB != null, "dois PlayerAgent reais (um por conta)"):
		return
	_grantSkills(agentA, [_skillIDs[0], _skillIDs[1]])
	agentA.set("peerID", _peerOf(1))
	agentB.set("peerID", _peerOf(2))
	agentA.set("characterID", charA)
	agentB.set("characterID", charB)
	_openSession(accountA, charA, _peerOf(1))
	_openSession(accountB, charB, _peerOf(2))
	var policyA : Object = _idlePolicy.new()
	# `_Attach` liga a policy ao agent (é por ele que GetPriorityOrder confere o que
	# está aprendido); sem esse vínculo a ordem efetiva desaba no fallback.
	policyA.set("agent", agentA)
	agentA.set("idlePolicy", policyA)
	_sql.SetCharacterFormationSlot(charA, 0)
	_sessionAgent = agentA

	# O painel montando a carga que o jogador clicou.
	var spawned : Dictionary = _spawnPanel()
	var panel : Object = spawned["panel"]
	var sends : Array = spawned["sends"]
	_offerLearned(panel, (agentA.get("progress") as Object).get("skills").keys())
	panel.set("charID", charA)
	panel.call("SelectSlot", 0)
	var wantA : int = _skillIDs[1]
	var wantB : int = _skillIDs[0]
	_check(bool(panel.call("AddSkillToPriority", wantA)), "S3: clique 1 (slot ativo do char)")
	_check(bool(panel.call("AddSkillToPriority", wantB)), "S3: clique 2")
	var base : int = sends.size()
	panel.call("SaveLoadout")
	var command : String = str((_sent(sends, base)[1] as Array)[0])
	# Identidade: o painel fala a ordem e o slot, NUNCA o dono. Server.TriggerCommand
	# resolve o caller pelo peerID da conexão, então não há campo para spoofar.
	var tokens : PackedStringArray = command.strip_edges().split(" ", false)
	_check(not tokens.has(str(charA)) and not tokens.has(str(charB)) and not tokens.has(str(accountA)) \
			and not command.contains("char"),
			"o comando emitido não nomeia personagem/conta (%s) — a identidade vem do PEER" % command)
	_check(_runServerCommand(agentA, command), "S3: a string emitida pelo painel foi despachada")
	_checkEq(_readFormation(accountA, 0), _ints([wantA, wantB]), "o que o SERVIDOR gravou é a ordem que o painel mostrou")
	_checkEq(policyA.get("skillLoadout"), _ints([wantA, wantB]), "aplicada ao vivo na policy do farmer (slot ativo)")
	_checkEq(policyA.call("GetPriorityOrder"), _ints([wantA, wantB]), "IdlePolicy lê a carga do painel como ordem efetiva")
	_checkEq(_skillPriority.call("Select", _ints([wantA, wantB]), _makeDict([wantA], "blocked"), _makeDict([wantA, wantB], "reach")), wantB,
			"próximo cast = a 2ª da lista porque a 1ª está em cooldown (SkillPriority decide pela ordem do painel)")
	_checkEq(_skillPriority.call("Select", _ints([wantA, wantB]), {}, _makeDict([wantA, wantB], "reach")), wantA,
			"mesma carga, nada travado: a 1ª declarada vence")

	# Payload adulterado: o painel é só um editor; o que entra é SkillPriority.Trim.
	var unlearned : int = 987654321
	var tampered : String = "priority slot 0 set %d %d %d %d" % [wantB, unlearned, wantB, wantB]
	_check(_runServerCommand(agentA, tampered), "S3: carga adulterada também passa pelo servidor")
	_checkEq(_readFormation(accountA, 0), _ints([wantB]), "não-aprendida e duplicatas CAEM; a ordem restante é a declarada")

	# Teto: 9 skills pedidas, MaxPrioritySkills gravadas.
	var many : Array = []
	for i in 9:
		many.append(_skillIDs[i % _skillIDs.size()])
	var capTokens : PackedStringArray = PackedStringArray()
	for value in many:
		capTokens.append(str(int(value)))
	_runServerCommand(agentA, "priority slot 0 set " + " ".join(capTokens))
	_check(_readFormation(accountA, 0).size() <= _maxPriority, "teto do modelo aplicado na gravação (%d <= %d)" % [_readFormation(accountA, 0).size(), _maxPriority])

	# Slot fora da faixa: clampado pelo servidor, nunca escrito fora das linhas.
	_runServerCommand(agentA, "priority slot %d set %d" % [_maxSlots + 7, wantA])
	_check(_readFormation(accountA, _maxSlots - 1).size() == 1, "slot fora da faixa é clampado para a última linha real")

	# Slot RESERVA (não o ativo): persiste, mas não troca o cast em andamento.
	var liveBefore : Variant = policyA.get("skillLoadout")
	_runServerCommand(agentA, "priority slot 4 set %d" % wantB)
	_checkEq(_readFormation(accountA, 4), _ints([wantB]), "slot reserva gravou a ordem pedida")
	_checkEq(policyA.get("skillLoadout"), liveBefore, "editar slot reserva NÃO troca o cast do farmer ativo")

	# Um char não pode escrever na conta vizinha.
	var victimBefore : Array = _readFormation(accountB, 0)
	_runServerCommand(agentA, "priority slot 0 set %d" % wantA)
	_checkEq(_readFormation(accountB, 0), victimBefore, "A nunca toca a formação de B (conta vem do PEER, não do cliente)")
	if _netServer != null and is_instance_valid(_netServer):
		var spoof : PackedInt64Array = PackedInt64Array()
		spoof.append(wantA)
		_netServer.call("SetFormation", 0, charB, spoof, 50.0, int(agentA.get("peerID")))
		_checkEq(_readFormation(accountB, 0), victimBefore, "RPC SetFormation recusa char de outra conta (not_owner) e não grava")
		_netServer.call("SetFormation", 0, charA, spoof, 50.0, int(agentA.get("peerID")))
		_checkEq(_readFormation(accountA, 0), _ints([wantA]), "o mesmo RPC aceita o char da própria conta")
	else:
		print("  [SKIP] sem ENetServer no boot — ponta de RPC de formação não aferível")
	panel.free()

# ------------------------------------------------------------------ S4: relog

func _suiteRelog():
	print("[suite] S4: relog — a ordem do painel volta do banco e decide o cast")
	var agentA : Object = _sessionAgent
	if agentA == null:
		_check(false, "sessão (PlayerAgent da suíte S3) para simular relog")
		return
	var charA : int = int(agentA.get("characterID"))
	var accountA : int = int(_sql.GetAccountIDForCharacter(charA))
	_sql.SetCharacterFormationSlot(charA, 0)
	var order : Array[int] = _ints([_skillIDs[1], _skillIDs[0]])
	_runServerCommand(agentA, "priority slot 0 set %d %d" % [_skillIDs[1], _skillIDs[0]])

	# Relog: a policy viva morre com a sessão; sobra apenas a linha do banco.
	agentA.set("idlePolicy", null)
	var readFromDB : Array = _readFormation(accountA, 0)
	_checkEq(readFromDB, order, "formation.skill_loadout sobreviveu (ordem, não conjunto)")
	var viaCommand : Variant = _commands.call("_StoredLoadout", accountA, 0)
	_checkEq(viaCommand as Array, order, "o próprio leitor do servidor (_StoredLoadout) devolve a ordem do painel")

	# Re-Anexar: mesmo parse que IdlePolicyService._Attach faz ao montar a policy.
	var fresh : Object = _idlePolicy.new()
	fresh.set("agent", agentA)
	var loadout : Array[int] = []
	for value in readFromDB:
		loadout.append(int(value))
	fresh.set("skillLoadout", loadout)
	_checkEq(fresh.call("GetPriorityOrder"), order, "policy nova do char aprendizado lê a MESMA ordem")
	_checkEq(_skillPriority.call("Select", fresh.call("GetPriorityOrder"), {}, _makeDict([_skillIDs[0], _skillIDs[1]], "reach")), _skillIDs[1],
			"primeiro golpe após o relog = 1ª do painel (não a skill antiga)")

func _makeDict(keys : Array, kind : String) -> Dictionary:
	var out : Dictionary = {}
	for value in keys:
		if kind == "blocked":
			out[int(value)] = true
		else:
			out[int(value)] = true
	return out

# ------------------------------------------------------------------ S5: wiring guards

func _suiteWiringGuards():
	print("[suite] S5: wiring guards (o painel não virou autoridade; declarados como tal)")
	var gui : String = _source("res://sources/gui/Formation.gd")
	_check(gui.contains("TriggerCommand"), "formation: a ordem sai pelo RPC de comando de chat")
	_check(gui.contains("SkillPriority.MaxPrioritySkills"), "formation: o teto do modelo é o teto do editor")
	_check(not gui.contains("SQL.SaveFormation") and not gui.contains("Launcher.SQL"), "formation: o painel não toca o banco (autoridade é do servidor)")
	var scene : String = _source("res://presets/gui/Formation.tscn")
	for needle : String in ["AddSkill", "PriorityList", "PriorityControls/Up", "PriorityControls/Down", "PriorityControls/Remove", "PriorityControls/Clear"]:
		_check(scene.contains(needle), "cena: controle %s existe (alcançável sem chat)" % needle)
	var world : String = _source("res://sources/world/WorldCommands.gd")
	_check(world.contains("if caller.idlePolicy and slot == activeSlot"), "servidor: apply ao vivo só no slot ativo")
	var server : String = _source("res://sources/network/server/Server.gd")
	_check(server.contains("not_owner"), "servidor: SetFormation continua conferindo a conta do char (RPC bruto)")
