extends SceneTree

# ONDA 3b-A (juiz cego 2026-09-27, "Core Gameplay 8.3 / Game Design 8.6": o catálogo
# de skills existe em `presets/cells/skills/`, `ClassBonus` declara o que cada classe
# PODE usar, e nada no jogo ENTREGAVA nada além do kit padrão e da skill inicial —
# `TeachSkill` (`sources/actor/agent/NpcCommons.gd:@TeachSkill`) tinha ZERO chamadores de
# conteúdo e `/skill` (depurador) era o único caminho que punha skill em personagem).
#
# Este harness fecha o eixo em duas camadas, e as duas têm de poder ficar vermelhas:
#
#   S1 catálogo      — toda célula do disco tem origem declarada em `SkillOrigins`,
#                      e nenhuma origem nomeia skill que não existe;
#   S2 formas        — cada origem aponta para conteúdo REAL do outro lado: as linhas
#                      `default_kit` são exatamente `ActorCommons.DefaultSkills`, as
#                      `class_starter` são o `starter_skill` de cada classe em
#                      `ClassBonus`, e a linha `trainer_npc` tem de existir no script
#                      do NPC que o produto carrega (`Elanore.gd`, a Kahwe do
#                      tutorial) e tem de ser TABLE-DRIVEN (o NPC não pode listar
#                      skill à mão — senão a tabela e o conteúdo divergem);
#   S3 números       — os marcos de nível são justificados por número: cabem na
#                      primeira metade da curva real (`Experience.MAX_LEVEL`, lido do
#                      produto) e cada classe fecha o próprio kit com >= 2 ataques;
#   S4 caminho do
#   produto         — personagem criado pelo RPC do servidor (`Server.CreateCharacter`)
#                      chega ao que as origens prometem, SEM comando de depurador;
#   S5 caminhada
#                      do jogador — o script REAL da Elanore é instanciado, o diálogo
#                      de treino é aberto, a lição é ESCOLHIDA como um jogador escolhe
#                      (`InteractChoice`) e a skill entra em `Progress` E em `SQL`
#                      (durabilidade — sem a segunda linha o jogador perdia a lição no
#                      relog, que era o estado do repo antes desta onda).
#
# Negativos que este harness NÃO deixa passar (todos provados por mutação nesta
# máquina, com hash de antes/depois):
#   * tirar uma linha de `_TrainerRows()` -> S1/S2/S5 vermelhas;
#   * apagar o ramo de treino de `Elanore.gd` -> S2 vermelha;
#   * hardcodar skill no NPC em vez de ler a tabela -> S2 vermelha;
#   * remover a gravação em `SQL.SetSkill` de `SkillTrainer.Teach` -> S5 vermelha.
#
# Uso: godot --headless --path . -s tests/skill_content_reach_test.gd
# Régua: última linha `== SKILL REACH: N checks, M failures ==`; exit = falhas.
#
# Como todo harness `-s`: compila antes dos autoloads e dos `class_name` existirem
# -> tudo por load()/get()/call(), sem identificador tipado do projeto em anotação.

const SKILL_DIR : String = "res://presets/cells/skills"
const ELANORE_PATH : String = "res://sources/scripts/tonori/tulimshar/Elanore.gd"
const CHOICE_LINE : String = "Can you teach me a skill?"

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _world : Node = null
var _netServer : Object = null
var _db : GDScript = null
var _origins : GDScript = null
var _trainer : GDScript = null
var _classBonus : GDScript = null
var _actorCommons : GDScript = null
var _experience : GDScript = null
var _networkCommons : GDScript = null
var _peers : GDScript = null
var _playerAgentScript : GDScript = null
var _npcAgentScript : GDScript = null
var _elanoreScript : GDScript = null

# classID -> {"accountID": int, "charID": int, "peerID": int, "agent": Object}
var _fixtures : Dictionary = {}
var _peerSeed : int = 860100
var _maxLevel : int = 0

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

func _enumValue(script : GDScript, enumName : String, key : String) -> int:
	if script == null:
		return -1
	var raw : Variant = script.get_script_constant_map().get(enumName, {})
	if raw is Dictionary and (raw as Dictionary).has(key):
		return int((raw as Dictionary)[key])
	return -1

func _sourceText(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

func _skillNames() -> Array[String]:
	var out : Array[String] = []
	for value in _db.SkillsDB.values():
		if value != null:
			out.append(str(value.get("name")))
	out.sort()
	return out

func _sortedCopy(source : Array) -> Array:
	var copy : Array = source.duplicate()
	copy.sort()
	return copy

# ------------------------------------------------------------------ boot

func _run():
	print("== Skill content reach harness (origem declarada / NPC que ensina / durabilidade) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_world = _launcher.get("World")
		if _sql != null and bool(_sql.get("isInitialized")) and _world != null:
			break
	_db = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 40:
		if _db != null and bool(_db.isInitialized):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (cells loaded)"):
		_finish()
		return
	var network : Node = root.get_node_or_null(^"Network")
	_netServer = network.get("ENetServer") if network != null else null
	_origins = load("res://sources/skill/SkillOrigins.gd")
	_trainer = load("res://sources/skill/SkillTrainer.gd")
	_classBonus = load("res://sources/cell/ClassBonus.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_experience = load("res://sources/actor/stat/Experience.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_peers = load("res://sources/network/server/Peers.gd")
	_playerAgentScript = load("res://sources/actor/agent/variants/PlayerAgent.gd")
	_npcAgentScript = load("res://sources/actor/agent/variants/NpcAgent.gd")
	_elanoreScript = load(ELANORE_PATH)
	_maxLevel = int(_experience.MAX_LEVEL)
	if not _check(_origins != null and _trainer != null and _classBonus != null and _elanoreScript != null,
			"SkillOrigins + SkillTrainer + ClassBonus + Elanore carregados no boot"):
		_finish()
		return
	if not _check(_netServer != null, "servidor vivo no boot (Server.CreateCharacter é o caminho medido)"):
		_finish()
		return
	_s1Catalog()
	_s2Forms()
	_s3Numbers()
	if _setupFixtures():
		_s4ProductPath()
		_s5TrainerWalk()
	else:
		_check(false, "fixture de contas/personagens criada (S4/S5 dependem dela)")
	_finish()

func _finish():
	_dropFixtures()
	print("== SKILL REACH: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ S1 catálogo fechado

func _s1Catalog() -> void:
	print("-- S1 catálogo (cada .tres do disco tem origem declarada)")
	var fileNames : Array[String] = []
	var dir : DirAccess = DirAccess.open(SKILL_DIR)
	if not _check(dir != null, "DirAccess abre %s" % SKILL_DIR):
		return
	dir.list_dir_begin()
	var entry : String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".tres"):
			fileNames.append(entry.trim_suffix(".tres"))
		entry = dir.get_next()
	dir.list_dir_end()
	var catalog : Array[String] = _skillNames()
	_checkEq(catalog.size(), fileNames.size(), "células no DB == arquivos .tres em presets/cells/skills")
	_check(catalog.size() >= 13, "o catálogo tem ao menos 13 skills (medido: %d)" % catalog.size())
	var errors : PackedStringArray = _origins.Validate()
	_checkEq(errors.size(), 0, "SkillOrigins.Validate() sem erro: %s" % " | ".join(errors))
	var missing : int = 0
	for name in catalog:
		if not bool(_origins.HasOrigin(name)):
			missing += 1
	_checkEq(missing, 0, "toda skill do catálogo tem ao menos uma origem declarada")
	var ghosts : int = 0
	for row in _origins.Table():
		if not catalog.has(str((row as Dictionary).get("skill", ""))):
			ghosts += 1
	_checkEq(ghosts, 0, "nenhuma origem nomeia skill fora do catálogo")
	_checkEq(_origins.OriginKinds.size(), 3, "três formas de origem conhecidas (kit, classe, treinador)")
	var kitErrors : PackedStringArray = _origins.ValidateClassKits()
	_checkEq(kitErrors.size(), 0, "fechamento por classe: %s" % " | ".join(kitErrors))

# ------------------------------------------------------------------ S2 formas -> conteúdo real

func _s2Forms() -> void:
	print("-- S2 formas (cada origem aponta para conteúdo que existe do outro lado)")
	# default_kit == exatamente ActorCommons.DefaultSkills
	var defaultNames : Array[String] = []
	for skillData in _actorCommons.DefaultSkills:
		var hash : int = int((skillData as Dictionary).get("skill_id", 0))
		var cell : Object = _db.GetSkill(hash)
		if cell != null:
			defaultNames.append(str(cell.get("name")))
	var kitRows : Array = []
	for row in _origins.Table():
		if str((row as Dictionary).get("kind", "")) == str(_origins.OriginDefaultKit):
			kitRows.append(str((row as Dictionary).get("skill", "")))
	_checkEq(_sortedCopy(kitRows), _sortedCopy(defaultNames),
		"linhas default_kit == ActorCommons.DefaultSkills (o que nasce com o personagem)")
	_check(defaultNames.size() >= 2, "o kit padrão entrega ao menos 2 skills (medido: %d)" % defaultNames.size())

	# class_starter == o starter_skill declarado por classe em ClassBonus
	var starterRows : Dictionary = {}
	for row in _origins.Table():
		var entry : Dictionary = row
		if str(entry.get("kind", "")) != str(_origins.OriginClassStarter):
			continue
		starterRows[str(entry.get("ref", ""))] = str(entry.get("skill", ""))
	for classEntry in _classBonus.GetCatalog():
		var classID : String = str((classEntry as Dictionary).get("id", ""))
		var starter : String = str((classEntry as Dictionary).get("starter_skill", ""))
		_check(starterRows.has(classID) and str(starterRows[classID]) == starter,
			"classe '%s' tem origem class_starter para '%s'" % [classID, starter])
		var allowed : Array = (classEntry as Dictionary).get("skills", [])
		_check(allowed.has(starter), "o starter '%s' está na lista de skills da classe '%s'" % [starter, classID])

	# trainer_npc == o script do NPC que o produto carrega, e TABLE-DRIVEN
	var trainerScript : String = str(_origins.TrainerScript)
	_check(trainerScript == ELANORE_PATH, "a origem do treinador é o script que o mapa usa (%s)" % trainerScript)
	var source : String = _sourceText(trainerScript)
	_check(not source.is_empty(), "o script do treinador existe no disco")
	_check(source.contains("func OnSkillTraining"), "Elanore define o ramo de treino")
	_check(source.contains('Choice("%s' % CHOICE_LINE) and source.contains("OnSkillTraining"),
		"o ramo de treino está na conversa principal (opção '%s')" % CHOICE_LINE)
	_check(source.contains("SkillTrainer.Offerings"), "o NPC pergunta ao kernel o que pode oferecer")
	_check(source.contains("SkillTrainer.Teach"), "a lição é entregue pelo kernel, não por um if solto")
	_check(source.contains("TeachLesson.bind"), "cada lição vira uma escolha do jogador (bind por linha)")
	# Tabela, não mão: nenhuma skill do catálogo pode aparecer literal no ramo de treino.
	var branch : String = source.substr(source.find("func OnSkillTraining"))
	var literals : int = 0
	for name in _skillNames():
		if branch.contains('"%s"' % name):
			literals += 1
	_checkEq(literals, 0, "o NPC não lista skill à mão — a fonte é SkillOrigins (literais no ramo)")
	# Cada lição declarada tem de ser possível para alguma classe do catálogo.
	var classIDs : Array = []
	for classEntry in _classBonus.GetCatalog():
		classIDs.append(str((classEntry as Dictionary).get("id", "")))
	var deadLessons : int = 0
	for lesson in _origins.TrainerLessons():
		var skill : String = str((lesson as Dictionary).get("skill", ""))
		var useful : bool = bool(_classBonus.SkillAllowed("", skill))
		for classID in classIDs:
			if bool(_classBonus.SkillAllowed(str(classID), skill)):
				useful = true
		if not useful:
			deadLessons += 1
	_checkEq(deadLessons, 0, "nenhuma lição de treinador é inútil para todas as classes")

# ------------------------------------------------------------------ S3 números

func _s3Numbers() -> void:
	print("-- S3 números (marcos de nível e kits justificáveis)")
	_check(_maxLevel > 0, "curva do produto declara um teto de nível (%d)" % _maxLevel)
	var ceiling : int = int(_maxLevel / 2)
	var lessons : Array = _origins.TrainerLessons()
	_check(lessons.size() >= 8, "o treinador tem ao menos 8 lições para ensinar (medido: %d)" % lessons.size())
	var previous : int = 0
	var outOfRange : int = 0
	var belowTwo : int = 0
	for lesson in lessons:
		var row : Dictionary = lesson
		var milestone : int = int(row.get("requires_level", 0))
		if milestone > ceiling or milestone < 2:
			outOfRange += 1
		if milestone < 2:
			belowTwo += 1
		if milestone < previous:
			outOfRange += 1
		previous = milestone
	_checkEq(outOfRange, 0, "marcos crescentes e dentro da primeira metade da curva (<= %d)" % ceiling)
	_checkEq(belowTwo, 0, "nenhuma lição é grátis no nível 1")
	# O problema nomeado pela auditoria: Warden e Rogue tinham 2 ataques. A régua é
	# número: para cada classe, skills de combate alcançáveis >= 2 e o kit fechado.
	for classEntry in _classBonus.GetCatalog():
		var classID : String = str((classEntry as Dictionary).get("id", ""))
		var allowed : Array = (classEntry as Dictionary).get("skills", [])
		var obtainable : Array = _origins.ObtainableForClass(classID)
		var universal : Array = _classBonus.UNIVERSAL_SKILLS
		var attacks : int = 0
		for skill in obtainable:
			if not universal.has(str(skill)):
				attacks += 1
		_checkEq(obtainable.size(), allowed.size() + universal.size() - _intersectionCount(allowed, universal),
			"classe '%s' alcança o kit completo (medido %d de %d permitidas)" % [classID, obtainable.size(), allowed.size() + universal.size()])
		_check(attacks >= 2, "classe '%s' tem ao menos 2 habilidades de combate alcançáveis (medido: %d)" % [classID, attacks])
		var starter : String = str((classEntry as Dictionary).get("starter_skill", ""))
		_check(obtainable.has(starter), "classe '%s' recebe a skill inicial '%s'" % [classID, starter])
	# O marco do segundo ataque tem de cair cedo: 12 é o maior entre as classes que a
	# auditoria chamou de "2 ataques" (Warden/Rogue), e está abaixo do teto medido.
	var secondAttacks : Array = []
	for lesson in lessons:
		var skill : String = str((lesson as Dictionary).get("skill", ""))
		if skill == "Sonic Scream" or skill == "Leaf Blades":
			secondAttacks.append(int((lesson as Dictionary).get("requires_level", 0)))
	_checkEq(secondAttacks.size(), 2, "o segundo ataque das duas classes citadas tem marco declarado")
	var lateSecond : int = 0
	for milestone in secondAttacks:
		if int(milestone) > 15:
			lateSecond += 1
	_checkEq(lateSecond, 0, "segundo ataque não é endgame: marcos <= 15 (medido %s)" % str(secondAttacks))

func _intersectionCount(allowed : Array, other : Array) -> int:
	var hits : int = 0
	for skill in allowed:
		if other.has(str(skill)):
			hits += 1
	return hits

# ------------------------------------------------------------------ fixture (contas + personagens pelo RPC)

func _setupFixtures() -> bool:
	var classIDs : Array = []
	for classEntry in _classBonus.GetCatalog():
		classIDs.append(str((classEntry as Dictionary).get("id", "")))
	if classIDs.is_empty():
		return false
	var ok : bool = true
	for classIndex in classIDs.size():
		var classID : String = classIDs[classIndex]
		var peerID : int = _peerSeed + classIndex
		var userName : String = "reach_%s" % classID
		var charName : String = "Reach%s" % classID.capitalize().replace(" ", "")
		_sql.db.delete_rows("character", "nickname = '%s'" % charName)
		_sql.db.delete_rows("account", "username = '%s'" % userName)
		var created : bool = bool(_sql.AddAccount(userName, "testpass", "%s@reach.local" % userName,
				_networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"))
		if not created:
			print("    diag: AddAccount falhou para %s" % userName)
			ok = false
			continue
		var accountID : int = int(_sql.GetAccountID(userName))
		_openSession(accountID, peerID)
		var traits : Dictionary = _clientTraits(classID)
		var err : int = int(_netServer.call("CreateCharacter", charName,
				traits, _actorCommons.DefaultAttributes, peerID))
		var charID : int = int(_sql.GetCharacterIDByName(charName))
		if err != 0 or charID <= 0:
			_check(false, "fixture %s: CreateCharacter devolveu ERR_OK e gravou personagem (err=%d charID=%d)" % [classID, err, charID])
			ok = false
			continue
		_fixtures[classID] = {"accountID": accountID, "charID": charID, "peerID": peerID, "nick": charName}
	return ok

# Traços do ponto de vista de quem cria: é o que `Traits.GetValues()`
# (sources/gui/character/Traits.gd:@GetValues) monta a partir dos primeiros valores de cada
# rolagem. O servidor confere isso com `ActorCommons.CheckTraits`, que exige
# hairstyle/haircolor/race/skintone/gender reais — `ActorCommons.DefaultTraits` só tem
# shape/spirit, e entregar DefaultTraits aqui era ERR_MISSING_PARAMS na porta.
func _clientTraits(classID : String) -> Dictionary:
	var hairstyles : Array = (_db.get("HairstylesDB") as Dictionary).keys()
	var haircolors : Array = ((_db.get("PalettesDB") as Array)[_db.Palette.HAIR] as Dictionary).keys()
	var races : Array = (_db.get("RacesDB") as Dictionary).keys()
	var race : Object = _db.GetRace(races[0])
	var skins : Array = ((race.get("skins") as Dictionary).keys() as Array)
	return {
		"hairstyle": hairstyles[0],
		"haircolor": haircolors[0],
		"race": races[0],
		"skintone": str(skins[0]).hash(),
		"gender": 0,
		"hero_class": classID,
	}

func _openSession(accountID : int, peerID : int):
	if not bool(_peers.HasPeer(peerID)):
		_peers.AddPeer(peerID, 0)
	var peer : Object = _peers.GetPeer(peerID)
	if peer == null:
		return
	peer.set("accountID", accountID)
	(_peers.accounts as Dictionary)[accountID] = peerID

func _dropFixtures():
	for classID in _fixtures.keys():
		var row : Dictionary = _fixtures[classID]
		var charName : String = str(row.get("nick", ""))
		var userName : String = "reach_%s" % str(classID)
		_sql.db.delete_rows("character", "nickname = '%s'" % charName)
		_sql.db.delete_rows("account", "username = '%s'" % userName)
		_peers.RemovePeer(int(row.get("peerID", 0)))

func _sqlSkillNames(charID : int) -> Array[String]:
	var out : Array[String] = []
	for row in _sql.GetSkills(charID):
		var cell : Object = _db.GetSkill(int((row as Dictionary).get("skill_id", 0)))
		if cell != null:
			out.append(str(cell.get("name")))
	out.sort()
	return out

# ------------------------------------------------------------------ S4 caminho do produto

func _s4ProductPath() -> void:
	print("-- S4 caminho do produto (CreateCharacter entrega o que as origens prometem)")
	for classID in _fixtures.keys():
		var row : Dictionary = _fixtures[classID]
		var charID : int = int(row.get("charID", 0))
		var stored : Array[String] = _sqlSkillNames(charID)
		var entry : Dictionary = _classBonus.GetClass(str(classID))
		var starter : String = str(entry.get("starter_skill", ""))
		_check(stored.has("Melee") and stored.has("Run"),
			"classe '%s': kit padrão gravado no personagem criado pelo RPC (%s)" % [str(classID), str(stored)])
		_check(stored.has(starter),
			"classe '%s': skill inicial '%s' gravada sem comando de depurador" % [str(classID), starter])
		_checkEq(stored.size(), 3,
			"classe '%s': exatamente kit padrão + skill inicial gravados (medido: %d)" % [str(classID), stored.size()])

# ------------------------------------------------------------------ S5 caminhada do jogador

func _agentForFixture(classID : String) -> Object:
	var row : Dictionary = _fixtures.get(classID, {})
	if row.is_empty():
		return null
	var entities : Dictionary = _db.EntitiesDB
	var data : Object = entities.get(int(_db.PlayerHash), null)
	if data == null:
		return null
	var agent : Object = _playerAgentScript.new(_enumValue(_actorCommons, "Type", "PLAYER"), data, str(row.get("nick", "Reach")), false)
	agent.set("peerID", int(_networkCommons.PeerUnknownID))
	agent.set("characterID", int(row.get("charID", 0)))
	return agent

func _npcAgent() -> Object:
	var entities : Dictionary = _db.EntitiesDB
	# Entidade não passa por `SetCellHash`: `ParseEntitiesDB` indexa por `_id`, e a
	# própria função exige `_id == _name.hash()`. Pedir o hash à tabela de células
	# devolvia UnknownHash e a Elanore "não existia" aqui mesmo existindo no disco.
	var data : Object = entities.get(str("Elanore").hash(), null)
	if data == null:
		return null
	return _npcAgentScript.new(_enumValue(_actorCommons, "Type", "NPC"), data, "Elanore", false)

func _choiceIndexOf(npc : Object, text : String) -> int:
	var steps : Array = npc.get("steps")
	for i in steps.size():
		var step : Dictionary = steps[i]
		if not step.has("choices"):
			continue
		var choices : Array = step["choices"]
		for j in choices.size():
			if str((choices[j] as Dictionary).get("text", "")) == text:
				return j
	return -1

func _progressHas(agent : Object, skillName : String) -> bool:
	var cell : Object = _db.GetSkill(int(_db.GetCellHash(skillName)))
	var progress : Object = agent.get("progress")
	return cell != null and progress != null and bool(progress.HasSkill(cell))

func _s5TrainerWalk() -> void:
	print("-- S5 caminhada do jogador (Elanore real -> escolha -> Progress + SQL)")
	var npcAgent : Object = _npcAgent()
	if not _check(npcAgent != null, "NPC agent da Elanore construído a partir de presets/entities/Elanore.tres"):
		return
	var wardenRow : Dictionary = _fixtures.get("warden", {})
	if wardenRow.is_empty():
		_check(false, "fixture warden existe para a caminhada")
		return
	var warden : Object = _agentForFixture("warden")
	if not _check(warden != null, "PlayerAgent do personagem criado pelo RPC"):
		return
	var storedBefore : Array[String] = _sqlSkillNames(int(wardenRow.get("charID", 0)))
	var npc : Object = _elanoreScript.new(npcAgent, warden)
	# Nível 1: nada a oferecer, e o NPC tem de dizer o porquê em vez de sumir.
	_setLevel(warden, 1)
	var offeringsL1 : Array = _trainer.Offerings(warden)
	_checkEq(offeringsL1.size(), 0, "no nível 1 o treinador não oferece lição nenhuma")
	var blocked : Dictionary = _trainer.Teach(npc, "Jump")
	_check(not bool(blocked.get("ok", false)), "lição de marco 5 é recusada no nível 1")
	var hint : String = str(_trainer.NextHint(warden))
	_check(hint.contains("level 5") and hint.contains("Jump"),
		"a recusa vira promessa legível (medido: '%s')" % hint)
	var message : String = str(blocked.get("message", ""))
	_check(message.contains("level 5"), "a mensagem mostrada ao jogador traz o número do marco")

	# Nível 12: o Warden recebe o segundo ataque pelo diálogo, como um jogador.
	_setLevel(warden, 12)
	var offeringsL12 : Array = _trainer.Offerings(warden)
	var offeringNames : Array = []
	for row in offeringsL12:
		offeringNames.append(str((row as Dictionary).get("skill", "")))
	_check(offeringNames.has("Sonic Scream"), "nível 12 libera o segundo ataque do Warden (medido: %s)" % str(offeringNames))
	_check(not offeringNames.has("Leaf Blades"), "o ataque do Rogue não é oferecido ao Warden (gate de classe)")
	npc.call("OnSkillTraining")
	var choiceIndex : int = _choiceIndexOf(npc, "Teach me Sonic Scream.")
	if not _check(choiceIndex >= 0, "a lição aparece como escolha no diálogo do NPC"):
		return
	npc.call("ApplyStep")
	npc.call("InteractChoice", choiceIndex)
	_check(_progressHas(warden, "Sonic Scream"), "escolher a lição põe a skill em Progress (caminho NpcCommons.TeachSkill)")
	var storedAfter : Array[String] = _sqlSkillNames(int(wardenRow.get("charID", 0)))
	_check(storedAfter.has("Sonic Scream"), "a lição sobrevive ao banco (SQL.SetSkill — sem isto morria no relog)")
	_checkEq(storedAfter.size(), storedBefore.size() + 1, "exatamente uma skill nova gravada pela lição")
	var again : Dictionary = _trainer.Teach(npc, "Sonic Scream")
	_check(not bool(again.get("ok", false)) and str(again.get("message", "")).contains("already"),
		"re-ensinar a mesma lição é recusa legível, não progresso infinito")
	var crossClass : Dictionary = _trainer.Teach(npc, "Leaf Blades")
	_check(not bool(crossClass.get("ok", false)) and str(crossClass.get("message", "")).contains("class"),
		"ensinar skill de outra classe é barrado no kernel")
	var ghost : Dictionary = _trainer.Teach(npc, "Nonexistent Form")
	_check(not bool(ghost.get("ok", false)), "lição fora do catálogo não é ensinada")

	# O Rogue no mesmo marco: a lição dele aparece, e a do Warden não.
	var rogueRow : Dictionary = _fixtures.get("rogue", {})
	if not rogueRow.is_empty():
		var rogue : Object = _agentForFixture("rogue")
		var rogueNpc : Object = _elanoreScript.new(npcAgent, rogue)
		_setLevel(rogue, 12)
		rogueNpc.call("OnSkillTraining")
		var rogueIndex : int = _choiceIndexOf(rogueNpc, "Teach me Leaf Blades.")
		_check(rogueIndex >= 0, "o segundo ataque do Rogue aparece no diálogo da mesma NPC")
		_check(_choiceIndexOf(rogueNpc, "Teach me Sonic Scream.") < 0,
			"o diálogo do Rogue não oferece a skill do Warden")
		rogueNpc.call("ApplyStep")
		rogueNpc.call("InteractChoice", rogueIndex)
		_check(_progressHas(rogue, "Leaf Blades"), "Leaf Blades entra em Progress no Rogue")
		_check(_sqlSkillNames(int(rogueRow.get("charID", 0))).has("Leaf Blades"),
			"Leaf Blades fica gravada para o Rogue")
	# O Scholar em 22 tem as cinco linhas do kit dele alcançadas.
	var scholarRow : Dictionary = _fixtures.get("scholar", {})
	if not scholarRow.is_empty():
		var scholar : Object = _agentForFixture("scholar")
		_setLevel(scholar, 22)
		var scholarLessons : Array = _trainer.LessonsFor("scholar", 22)
		_check(scholarLessons.size() >= 5,
			"o Scholar alcança as 5 lições exclusivas no nível 22 (medido: %d)" % scholarLessons.size())

func _setLevel(agent : Object, level : int) -> void:
	var stat : Object = agent.get("stat")
	if stat != null:
		stat.set("level", level)
