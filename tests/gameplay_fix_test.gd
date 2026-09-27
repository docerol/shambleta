extends SceneTree

# SOM-GAMEPLAY: harness autônomo dos fixes de core gameplay / game design
# (AUDITORIA_2026-09-27, itens G1/G2/G3). Uso:
#	godot --headless --path . -s tests/gameplay_fix_test.gd
# Exit code = nº de falhas; a régua do gate é a última linha
#	== RESULT: N checks, 0 failures ==
#
# Mesmo contrato do run_idle_tests.gd: um script `-s` é compilado ANTES dos
# autoloads serem registrados, então este arquivo é duck-typed — nenhum
# class_name nem identificador de autoload em tempo de parse; as classes do
# projeto entram por load() depois do boot e os enums por get_script_constant_map().
#
# O que é afirmado aqui (nada é "olha o texto do arquivo" exceto onde está
# marcado como wiring guard, e nesses casos o motivo é declarado):
#   G1  SkillPriority (modelo puro) + IdlePolicy com policy real (fallback e
#       skill primária) + round-trip REAL de formation.skill_loadout no SQLite,
#       que é o que dispensa migração nova.
#   G2  ElementCommons.Affinity* sobre BaseStats reais + o AlterationLabel real
#       instanciado headless (o número do DoT precisa EXISTIR na tela).
#   G3  BossLadder.AttackNeeded contra o BossService.Resolve real (o número
#       exibido tem que ser o número que decide a luta) + a string da escada +
#       a janela de interrupt DO BOSS sendo a que o toque AO VIVO é pontuado
#       (IdlePolicy._consumeBossInterrupt com bossIndex real).

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _dbScript : GDScript = null
var _network : Node = null

var _skillPriority : GDScript = null
var _bossLadder : GDScript = null
var _bossService : GDScript = null
var _elementCommons : GDScript = null
var _idlePolicy : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _networkCommons : GDScript = null
var _baseStats : GDScript = null
var _baseAgent : GDScript = null
var _alterationLabelScene : PackedScene = null

var ALTERATION : Dictionary = {}
var AFFINITY : Dictionary = {}

# Id de skill que NÃO existe no SkillsDB: com ela na carga, IdlePolicy._getSkill
# devolve null e o toque é pontuado SEM aplicar dano — a régua da janela não
# precisa de instância, física nem RNG, e ainda assim passa pela função real.
var _bogusSkillID : int = 0

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

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (±%f)" % [label, value, expected, tolerance])
		return false
	return true

func _checkHas(text : String, needle : String, label : String) -> bool:
	checks += 1
	if not text.contains(needle):
		failures += 1
		print("  [FAIL] %s: '%s' não achei em '%s'" % [label, needle, text])
		return false
	return true

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# Carga de skill é `Array[int]` na produção (SkillPriority, IdlePolicy.skillLoadout,
# SQL.SaveFormation). Passar literal solto por `Callable.call()` — o bind dinâmico
# deste harness, que não tem o class_name registrado em tempo de parse — é recusado
# com "array of argument N does not have the same element type", e o erro aborta a
# suíte inteira antes do primeiro check. Todo array daqui passa por aqui.
func _ints(values : Array) -> Array[int]:
	var out : Array[int] = []
	for value in values:
		out.append(int(value))
	return out

# ------------------------------------------------------------------ boot

func _run():
	print("== SOM-GAMEPLAY fix harness (G1 prioridade / G2 elemental / G3 escada) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		_finish()
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.SQL
		if _sql != null and _sql.isInitialized and _launcher.World != null and _launcher.World.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)

	_network = root.get_node_or_null(^"Network")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_baseStats = load("res://sources/actor/stat/BaseStats.gd")
	_baseAgent = load("res://sources/actor/agent/BaseAgent.gd")
	_elementCommons = load("res://sources/combat/ElementCommons.gd")
	_skillPriority = load("res://sources/combat/SkillPriority.gd")
	_bossLadder = load("res://sources/combat/BossLadder.gd")
	_bossService = load("res://sources/idle/BossService.gd")
	_idlePolicy = load("res://sources/idle/IdlePolicy.gd")
	_alterationLabelScene = load("res://presets/gui/AlterationLabel.tscn")
	_bogusSkillID = "SgNopeRulerSkill".hash()

	# `DB` é classe estática (class_name), não autoload: `root.get_node("DB")`
	# devolvia null e o gate deste harness era vermelho estrutural. O probe é o
	# mesmo do run_idle_tests — load() do script pós-boot e o static var.
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
	if not _check(_actorCommons != null and not _actorCommons.get_script_constant_map().is_empty(), "ActorCommons constants available"):
		_finish()
		return

	ALTERATION = _enumOf(_actorCommons, "Alteration")
	AFFINITY = _enumOf(_elementCommons, "Affinity")
	_check(ALTERATION.has("POISON") and ALTERATION.has("BLEED") and ALTERATION.has("BURN"), "Alteration.POISON/BLEED/BURN existem no enum")
	_check(AFFINITY.has("WEAK") and AFFINITY.has("RESISTED") and AFFINITY.has("UNKNOWN"), "ElementCommons.Affinity exposto")

	_suitePriorityModel()
	_suitePriorityPolicy()
	_suitePriorityPersistence()
	_suiteElementalFeedback()
	_suiteBossLadder()
	_suiteInterruptWindowLive()
	_suiteWiringGuards()

	_finish()

# Enums de script outro: o map de constants do GDScript traz os membros achatados
# e o dict do próprio enum; normalizo p/ nome -> valor.
func _enumOf(script : GDScript, enumName : String) -> Dictionary:
	var out : Dictionary = {}
	if script == null:
		return out
	var constants : Dictionary = script.get_script_constant_map()
	var raw : Variant = constants.get(enumName, {})
	if raw is Dictionary:
		for key : String in (raw as Dictionary).keys():
			out[key] = (raw as Dictionary)[key]
	for key : Variant in constants.keys():
		if not out.has(str(key)) and constants[key] is int and _isEnumMemberName(str(key)):
			out[str(key)] = constants[key]
	return out

func _isEnumMemberName(name : String) -> bool:
	for i in range(name.length()):
		var c : int = name.unicode_at(i)
		var isUpper : bool = c >= 65 and c <= 90
		var isDigit : bool = c >= 48 and c <= 57
		if not (isUpper or isDigit or c == 95):
			return false
	return name.length() > 1

# ------------------------------------------------------------------ G1: modelo de prioridade

func _suitePriorityModel():
	print("[suite] G1: SkillPriority (modelo puro da decisão do auto-combat)")
	var melee : int = _skillCommons.SkillMeleeName.hash()
	var run : int = _skillCommons.SkillRunName.hash()
	var fireball : int = "Fireball".hash()

	# ordem declarada é a lei; duplicata e não-aprendido caem fora
	var normalized : Array = _skillPriority.call("Normalize", _ints([run, melee, run, 4001]), _ints([run, melee]))
	_checkEq(normalized, [run, melee], "Normalize: preserva ordem declarada, remove duplicata/desconhecido")
	_checkEq(_skillPriority.call("Normalize", _ints([4001, 4002]), _ints([])), [], "Normalize: nada aprendido -> nada candidato")

	# fallback = comportamento antigo (nunca lista vazia)
	_checkEq(_skillPriority.call("ResolveOrder", _ints([]), _ints([]), melee), [melee], "ResolveOrder: carga vazia -> melee (como hoje)")
	_checkEq(_skillPriority.call("ResolveOrder", _ints([4001]), _ints([]), melee), [4001], "ResolveOrder: declarado não-aprendido -> 1º declarado (como hoje)")
	_checkEq(_skillPriority.call("ResolveOrder", _ints([run, melee]), _ints([melee, run]), 0), [run, melee], "ResolveOrder: ordem do jogador manda")

	# A SELEÇÃO: mesma função que IdlePolicy chama no tick de combate.
	var bothFree : Dictionary = {}
	var reach : Dictionary = {run: true, melee: true}
	_checkEq(_skillPriority.call("Select", _ints([run, melee]), bothFree, reach), run, "Select: 1ª livre e ao alcance vence a ordem")
	_checkEq(_skillPriority.call("Select", _ints([run, melee]), {run: true}, reach), melee, "Select: prioridade em cooldown -> passa a vez p/ a próxima")
	_checkEq(_skillPriority.call("Select", _ints([run, melee]), {}, {run: false, melee: true}), melee, "Select: prioridade FORA do alcance -> usa a que alcança (não anda em círculo)")
	_checkEq(_skillPriority.call("Select", _ints([run, melee]), {}, {run: true, melee: false}), run, "Select: nenhuma ao alcance -> anda com a prioritária")
	_checkEq(_skillPriority.call("Select", _ints([run, melee]), {run: true, melee: true}, reach), _skillPriority.get("NoSkill"), "Select: tudo travado -> NoSkill")
	# inverter a carga INVERTE o golpe dado o mesmo estado do mundo: é o instrumento
	# de decisão que faltava (root cause (a) da auditoria).
	_checkEq(_skillPriority.call("Select", _ints([melee, run]), {run: true}, {melee: true, run: true}), melee, "Select: trocar a ordem troca o cast (run travado)")
	_checkEq(_skillPriority.call("Select", _ints([melee, run]), {melee: true}, {melee: true, run: true}), run, "Select: mesma situação, outra ordem -> outro golpe")

	var trimmed : Dictionary = _skillPriority.call("Trim", _ints([run, run, melee]), _ints([run, melee]))
	# Contrato real de Trim (SkillPriority.gd:57): cada skill aprendida entra uma vez
	# na ordem pedida, e o que sobra (duplicata, não-aprendida, excesso) sai em
	# `rejected` — é o que o jogador lê de volta em vez de um "ok" mudo. Exigir
	# `[run]` aqui era régua própria: descartava junto uma skill legítima.
	_checkEq(trimmed["order"], [run, melee], "Trim: carga final tem cada aprendida uma vez, na ordem pedida")
	_checkEq(trimmed["rejected"], [run], "Trim: a duplicata é rejeitada nominalmente")
	var many : Array[int] = []
	for i in range(10):
		many.append(melee + i)
	_checkEq((_skillPriority.call("Trim", many, many) as Dictionary)["order"].size(), int(_skillPriority.get("MaxPrioritySkills")), "Trim: teto da carga aplicado")

	var names : Dictionary = {run: "Run", melee: "Melee"}
	_checkEq(_skillPriority.call("FormatOrder", _ints([run, melee]), names), "1. Run  ->  2. Melee", "FormatOrder: ordem legível no /priority")
	_checkEq(_skillPriority.call("FormatOrder", _ints([]), names), "(none)", "FormatOrder: carga vazia")

# ------------------------------------------------------------------ G1: IdlePolicy real

# Sem mundo: as duas chamadas que não precisam de alvo rodam de verdade aqui.
# A seleção por alcance/cooldown exige agent+instância; cobrimos o modelo acima e
# o wiring abaixo (wiring guard) — registrado como pendência a sim ao vivo.
func _suitePriorityPolicy():
	print("[suite] G1: IdlePolicy (fallback e skill primária, código real)")
	var melee : int = _skillCommons.SkillMeleeName.hash()
	var run : int = _skillCommons.SkillRunName.hash()

	var policy : RefCounted = _idlePolicy.new()
	policy.skillLoadout = _ints([run, melee])
	_checkEq(policy.GetPriorityOrder(), [run], "IdlePolicy: sem agent nada está aprendido -> 1º declarado (comportamento antigo, sem crash)")
	var primary : RefCounted = policy._getSkill()
	_check(primary != null and int(primary.id) == run, "IdlePolicy: skill primária == 1º da carga declarada")

	var empty : RefCounted = _idlePolicy.new()
	empty.skillLoadout = _ints([])
	var meleeCell : RefCounted = empty._getSkill()
	_check(meleeCell != null and int(meleeCell.id) == melee, "IdlePolicy: carga vazia -> melee (nenhum farmer perde o ataque)")
	_checkEq(empty.GetPriorityOrder(), [melee], "IdlePolicy: ordem efetiva nunca vazia")

# ------------------------------------------------------------------ G1: persistência (round-trip real)

# formation.skill_loadout JÁ era Array[int] ordenado serializado em var_to_str:
# foi isso que permitiu dar prioridade ao jogador sem coluna nem migração nova
# (e sem encostar em SQL.gd, que tem outro dono).
func _suitePriorityPersistence():
	print("[suite] G1: round-trip da ordem em formation.skill_loadout (SQLite real)")
	if _sql == null or not _sql.isInitialized:
		print("  [SKIP] sem DB — round-trip de persistência não aferível")
		return
	var accountName : String = "gpri_account"
	var nickname : String = "GpFixChar"
	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)
	if not _check(_sql.AddAccount(accountName, "testpass", accountName + "@test.local", _networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"), "fixture account created"):
		return
	var accountID : int = _sql.GetAccountID(accountName)
	var charID : int = _sql.GetCharacterID(accountID, nickname) if _sql.AddCharacter(accountID, nickname, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes) else -1
	if not _check(charID > 0, "fixture character created"):
		return

	var melee : int = _skillCommons.SkillMeleeName.hash()
	var run : int = _skillCommons.SkillRunName.hash()
	var ordered : Array[int] = [run, melee]
	var slot : int = 3
	_check(_sql.SaveFormation(accountID, slot, charID, ordered, 41.5), "SaveFormation gravou a ordem")
	var row : Dictionary = _sql.GetFormationForSlot(accountID, slot)
	var parsed : Variant = str_to_var(str(row.get("skill_loadout", "")))
	_check(parsed is Array, "skill_loadout voltou serializado como Array")
	_checkEq(parsed as Array, ordered, "round-trip: ORDEM preservada (não é um set)")
	_checkEq(int(row.get("char_id", -1)), charID, "formação ligada ao char")
	_checkNear(float(row.get("auto_potion_pct", 0.0)), 41.5, 0.001, "auto_potion_pct intacto ao gravar prioridade")

	# regrava com a ordem invertida: é isso que /priority set faz
	_check(_sql.SaveFormation(accountID, slot, charID, _ints([melee, run]), 41.5), "SaveFormation aceita reordenação")
	var again : Variant = str_to_var(str(_sql.GetFormationForSlot(accountID, slot).get("skill_loadout", "")))
	_checkEq(again as Array, [melee, run], "reordenação persistiu")

	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)

# ------------------------------------------------------------------ G2: feedback elemental no cliente

func _suiteElementalFeedback():
	print("[suite] G2: afinidade elemental + rótulo de dano na tela")
	var target : RefCounted = _baseStats.new()
	var attacker : RefCounted = _baseStats.new()

	# limiares lidos da curva de mitigação, não inventados
	_checkEq(_elementCommons.call("AffinityFromResist", 0.0), AFFINITY.WEAK, "resist 0.0 -> WEAK")
	_checkEq(_elementCommons.call("AffinityFromResist", float(_elementCommons.get("WeakResistMax"))), AFFINITY.WEAK, "no limiar ainda é WEAK")
	_checkEq(_elementCommons.call("AffinityFromResist", 0.4), AFFINITY.NEUTRAL, "0.4 -> NEUTRAL")
	_checkEq(_elementCommons.call("AffinityFromResist", float(_elementCommons.get("ResistedResistMin"))), AFFINITY.RESISTED, "0.5 -> RESISTED")
	_checkEq(_elementCommons.call("AffinityFromResist", 0.75), AFFINITY.RESISTED, "teto do motor (ResistCap) -> RESISTED")

	# DoTs: cada um na resistência que o SERVIDOR usa de verdade
	target.poisonResist = 0.0
	target.bleedResist = 0.7
	target.fireResist = 0.6
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.POISON), AFFINITY.WEAK, "POISON lê poisonResist (weaker)")
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.BLEED), AFFINITY.RESISTED, "BLEED lê bleedResist (resisted)")
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.BURN), AFFINITY.RESISTED, "BURN lê fireResist (não existe BurnResist)")

	# golpe físico puro NÃO ganha selo (badge mentiroso ensina errado)
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.HIT), AFFINITY.UNKNOWN, "HIT sem elemento em jogo -> UNKNOWN")
	attacker.fireDamage = 30
	attacker.iceDamage = 5
	target.fireResist = 0.0
	_checkEq(_elementCommons.call("DominantElement", attacker), int(_enumOf(_elementCommons, "Element").get("Fire", -99)), "elemento dominante = maior dano elemental")
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.CRIT), AFFINITY.WEAK, "CRIT com fogo vs alvo fraco a fogo -> WEAK")
	target.fireResist = 0.7
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, target, ALTERATION.CRIT), AFFINITY.RESISTED, "mesmo golpe vs alvo que resiste -> RESISTED")
	_checkEq(_elementCommons.call("AffinityForAlteration", attacker, null, ALTERATION.POISON), AFFINITY.UNKNOWN, "sem stats do alvo -> UNKNOWN (sem crash)")

	# O RÓTULO DE VERDADE: antes, POISON/BLEED/BURN caíam no "_" -> push_error e
	# nenhum número na tela. Instancio a cena real headless e leio o texto.
	var weakLabel : Control = _makeLabel(7, ALTERATION.POISON, AFFINITY.WEAK)
	if weakLabel != null:
		_checkEq(weakLabel.get_text(), "7 poison WEAK", "label: tick de veneno em alvo fraco mostra o número + selo")
		_check(weakLabel.scale.x > 1.0, "label: fraqueza também muda o TAMANHO (não só a cor)")
	var resistLabel : Control = _makeLabel(3, ALTERATION.BURN, AFFINITY.RESISTED)
	if resistLabel != null:
		_checkEq(resistLabel.get_text(), "3 burn res", "label: burn resistido marcado")
	_checkEq(_statusText(5, "bleed", AFFINITY.NEUTRAL), "5 bleed", "label: neutro = número limpo, sem selo")
	if weakLabel != null:
		weakLabel.free()
	if resistLabel != null:
		resistLabel.free()

func _makeLabel(value : int, alteration : int, affinity : int) -> Control:
	if _alterationLabelScene == null:
		_check(false, "AlterationLabel.tscn carregável (cena do feedback)")
		return null
	var label : Control = _alterationLabelScene.instantiate()
	if label == null or not label.has_method("SetValue"):
		_check(false, "AlterationLabel instanciado com SetValue")
		return null
	label.SetValue(null, value, alteration, affinity)
	return label

func _statusText(value : int, statusName : String, affinity : int) -> String:
	# `get_script()` é método de Node, não de PackedScene: na cena devolvia null e
	# o `call` estourava o resto da suíte. `_StatusText` é estática no script da
	# cena, então pego o script pela instância (o mesmo caminho de `_makeLabel`) e
	# libero na hora — o harness não tem árvore.
	if _alterationLabelScene == null:
		_check(false, "AlterationLabel.tscn carregável (cena do feedback)")
		return ""
	var label : Node = _alterationLabelScene.instantiate()
	var script : GDScript = label.get_script()
	var text : String = ""
	if script != null:
		text = str(script.call("_StatusText", value, statusName, affinity))
	label.free()
	return text

# ------------------------------------------------------------------ G3: escada de bosses

func _state(beaten : int, count : int = 4, level : int = 12) -> Dictionary:
	var bosses : Array = []
	for i in count:
		var bossLevel : int = int(_bossService.call("GetBossLevel", level, i))
		var window : Dictionary = _bossService.call("GetInterruptWindow", i)
		bosses.append({
			"index" = i,
			"name" = str(_bossService.call("GetBossName", i)),
			"level" = bossLevel,
			"hp" = int(_bossService.call("GetBossMaxHealth", bossLevel)),
			"beaten" = i < beaten,
			"next" = i == beaten,
			# MESMAS chaves que BossProgressionService.GetBossState emite hoje
			# (arena, custo de chave e a janela daquele boss). O fixture precisa
			# casar o payload real ou o BossLadder estaria sendo testado contra um
			# dicionário que ninguém produz.
			"arena" = str(_bossService.call("GetBossArena", i)),
			"keyCost" = int(_bossService.call("GetBossKeyCost", i)),
			"interruptPerfect" = float(window.get("perfect", 0.1)),
			"interruptGood" = float(window.get("good", 0.25)),
		})
	return {"keys" = 1, "beaten" = beaten, "count" = count, "level" = level, "bosses" = bosses}

func _player(attack : int = 100, defense : int = 40, maxHealth : int = 600, cycle : float = 1.4) -> Dictionary:
	return {"attack" = attack, "defense" = defense, "maxHealth" = maxHealth, "cycle" = cycle}

func _suiteBossLadder():
	print("[suite] G3: requisito real da escada (BossLadder invertendo BossService.Resolve)")
	var build : Dictionary = _player()
	var level : int = 12

	# A propriedade que importa: o número exibido É o número que decide a luta.
	var needed : int = int(_bossLadder.call("AttackNeeded", level, build))
	_check(needed > 1, "AttackNeeded devolve um ataque plausível (%d)" % needed)
	_check(bool(_bossLadder.call("WillWin", level, _player(needed))), "AttackNeeded SUFFICIENTE no simulador real")
	_check(not bool(_bossLadder.call("WillWin", level, _player(needed - 1))), "AttackNeeded-1 PERDE no simulador real (não é chute arredondado p/ cima)")

	# dificuldade monotônica: boss mais alto exige mais
	var higher : int = int(_bossLadder.call("AttackNeeded", level + 5, build))
	_check(higher > needed, "escada real: Lv %d exige mais ataque que Lv %d (%d > %d)" % [level + 5, level, higher, needed])
	var withPerfect : int = int(_bossLadder.call("AttackNeeded", level, build, float(_bossLadder.get("PerfectInterruptMult"))))
	_check(withPerfect < needed, "interrupt perfeito abaixa a exigência (%d < %d) — a mecânica ativa é comunicada" % [withPerfect, needed])

	var req : Dictionary = _bossLadder.call("Requirement", _state(2), build)
	_checkEq(str(req.get("name", "")), str(_bossService.call("GetBossName", 2)), "Requirement aponta o próximo boss não-vencido")
	_checkEq(int(req.get("attackHave", -1)), int(build["attack"]), "Requirement reporta o ataque do char")
	# `gap` é FALTA, não diferença: `maxi(0, needed - have)` em Requirement. Com a
	# build de ataque 100 o modelo diz que ela cobre o Lv 12, então gap 0 e ready
	# true são a resposta CERTA — era o assert que rotulava essa build de "fraca"
	# (medido: needed 79 < have 100). A falta exata e a frase de aviso passam a ser
	# conferidas numa build posta 5 abaixo do número que o próprio modelo calculou;
	# AttackNeeded não depende do ataque do char, só de defesa/vida/ciclo, então
	# aqui needed é exatamente o de `req` e gap não tem como dar outro valor.
	_checkEq(int(req.get("gap", -1)), 0, "quem cobre o exigido tem falta zero (nunca negativa)")
	_check(bool(req.get("ready", false)), "quem cobre o exigido é declarado pronto (mesma régua do duelo)")
	var weak : Dictionary = _player(maxi(1, int(req.get("attackNeeded", 6)) - 5))
	var weakReq : Dictionary = _bossLadder.call("Requirement", _state(2), weak)
	_checkEq(int(weakReq.get("gap", -1)), 5, "gap = falta exata quando falta")
	_check(not bool(weakReq.get("ready", true)), "build abaixo do exigido não é declarada pronta")
	var text : String = str(_bossLadder.call("RequirementText", weakReq))
	_checkHas(text, str(weakReq.get("attackNeeded", -1)), "texto cita o MESMO número do modelo")
	var line : String = str(_bossLadder.call("RequirementLine", _state(2), build))
	_checkHas(line, "2/4", "linha: progresso real da escada")
	_checkHas(line, "NEXT", "linha: próximo boss destacado")
	_checkHas(line, str(_bossService.call("GetBossName", 3)), "linha: lista a escada toda (ritmo visível)")

	# caso pedido pela auditoria: beaten == count -> o próximo requisito é OUTRO
	# eixo (tormento), e a string tem que dizer isso.
	var complete : String = str(_bossLadder.call("RequirementLine", _state(4), build))
	_checkHas(complete, "Ladder complete (4/4)", "beaten=4: escada zerada declarada")
	_checkHas(complete, "Torment", "beaten=4: o próximo degrau (tormento) é comunicado")
	_check(not complete.contains("NEXT"), "beaten=4: não há mais 'próximo boss' da escada")
	_checkEq(str(_bossLadder.call("RequirementLine", {}, build)), "Boss ladder: no data yet", "estado vazio não inventa requisito")

	# ---- perna nova (juiz 2026-09-27: "4 bosses na escada"). O fixture acima
	# mantém count=4 de propósito: é o estado histórico truncado que a UI mostrava
	# e as réguas de cima não podem perdê-lo. Aqui entra o comprimento REAL da
	# escada: cada boss novo tem de ser decidido pelo MESMO simulador, com a
	# própria arena e a própria janela de interrupt comunicadas.
	var realCount : int = int(_bossService.call("GetBossCount"))
	_check(realCount >= 10, "a escada tem >= 10 bosses (eram 4; medido %d)" % realCount)
	var fullState : Dictionary = _state(0, realCount, 12)
	var fullLine : String = str(_bossLadder.call("RequirementLine", fullState, build))
	_checkHas(fullLine, "0/%d" % realCount, "linha do estado real: progresso sobre a escada inteira (%d)" % realCount)
	var arenas : Dictionary = {}
	var prevNeed : int = 0
	var prevLevel : int = 0
	var prevWindow : float = 1.0
	for i in realCount:
		var st : Dictionary = _state(i, realCount, 12)
		var bd : Dictionary = st["bosses"][i]
		var q : Dictionary = _bossLadder.call("Requirement", st, build)
		var bossName : String = str(bd["name"])
		_check(not bossName.is_empty(), "boss %d tem nome" % i)
		_checkEq(str(q.get("name", "")), bossName, "boss %d (%s): Requirement aponta o próximo da escada inteira" % [i, bossName])
		_checkEq(float(q.get("interruptPerfect", -1.0)), float(bd["interruptPerfect"]), "boss %d: o requisito comunica a janela DAQUELE boss (±%.2f)" % [i, float(bd["interruptPerfect"])])
		_checkEq(int(q.get("keyCost", 0)), 1, "boss %d: custo de chave comunicado == 1 (a perna nova não infla o sink)" % i)
		var arena : String = str(q.get("arena", ""))
		_check(not arena.is_empty(), "boss %d: o requisito comunica a arena ('%s')" % [i, arena])
		_check(not arenas.has(arena), "boss %d: arena '%s' é própria (não é a mesma sala de outro boss)" % [i, arena])
		arenas[arena] = true
		_checkHas(fullLine, arena, "linha: a arena do boss %d aparece no /boss" % i)
		var need : int = int(q.get("attackNeeded", 0))
		_check(need > 1, "boss %d: AttackNeeded do duelo real é plausível (%d)" % [i, need])
		_check(bool(_bossLadder.call("WillWin", int(bd["level"]), _player(need))), "boss %d: o attack comunicado basta no simulador" % i)
		_check(not bool(_bossLadder.call("WillWin", int(bd["level"]), _player(need - 1))), "boss %d: attack-1 perde (número exato, não arredondado p/ cima)" % i)
		if i >= 5:
			_check(int(bd["level"]) > prevLevel, "boss %d: a perna nova sobe o piso de nível (%d > %d)" % [i, int(bd["level"]), prevLevel])
			_check(need > prevNeed, "boss %d: a perna nova exige mais ataque (%d > %d) — não é o mesmo duelo repetido" % [i, need, prevNeed])
			_check(float(bd["interruptPerfect"]) <= prevWindow, "boss %d: a janela não alarga com a escada (±%.2f <= ±%.2f)" % [i, float(bd["interruptPerfect"]), prevWindow])
		prevNeed = need
		prevLevel = int(bd["level"])
		prevWindow = float(bd["interruptPerfect"])
	var lastWindow : float = float((_state(realCount - 1, realCount, 12)["bosses"][realCount - 1])["interruptPerfect"])
	_check(lastWindow < float(_bossService.InterruptPerfectMax) - 0.5, "chefe final: janela mais estreita que a legacy (±%.2f < ±%.2f)" % [lastWindow, float(_bossService.InterruptPerfectMax) - 0.5])
	var tightText : String = str(_bossLadder.call("RequirementText", _bossLadder.call("Requirement", _state(realCount - 1, realCount, 12), _player(1))))
	_checkHas(tightText, "janela ±%.2f" % lastWindow, "chefe final: o texto comunica a janela apertada que a sim aplica")

# ------------------------------------------------------------------ G3: a janela do boss no toque AO VIVO

# Pontua UM toque exatamente pelo caminho de produção: IdlePolicy._consumeBossInterrupt
# (a mesma função que _tickCombat chama no servidor), com bossIndex e fase controlados.
# O veredito devolvido é o que o servidor aplicou — qualidade + multiplicador.
# Sem mundo e sem dano: a carga leva um id de skill que não existe no SkillsDB, então
# `_getSkill` devolve null e nenhum Skill.Damaged é chamado; o que se mede é a JANELA.
func _tapVerdict(index : int, phase : float) -> Dictionary:
	var policy : RefCounted = _idlePolicy.new()
	policy.bossIndex = index
	policy.skillLoadout = _ints([_bogusSkillID])
	var target : Object = _baseAgent.new()
	policy._interruptWindow = true
	policy._interruptRequest = true
	policy._interruptTimer = phase * float(_idlePolicy.InterruptWindowSec)
	var verdict : Dictionary = policy._consumeBossInterrupt(target)
	target.free()
	return verdict

func _suiteInterruptWindowLive():
	print("[suite] G3: o toque ao vivo é pontuado na janela DO BOSS (não na legacy)")
	if _baseAgent == null:
		_check(false, "BaseAgent carregável (alvo vivo do toque)")
		return
	# sanidade da armação: a skill inventada não pode existir no DB, senão o toque
	# passaria a aplicar dano sem mundo (e a régua deixaria de medir só a janela).
	_check(_dbScript.SkillsDB.get(_bogusSkillID, null) == null, "a skill-inventada da régua não resolve no SkillsDB (toque sem dano)")
	var realCount : int = int(_bossService.call("GetBossCount"))
	var perfect : Array = _bossService.BossInterruptPerfectHalfWindow
	var good : Array = _bossService.BossInterruptGoodHalfWindow

	# O centro do ciclo É perfect para qualquer boss — régua de sanidade do caminho.
	var center : Dictionary = _tapVerdict(realCount - 1, 0.5)
	_checkEq(str(center.get("quality", "")), "perfect", "chefe final: tocar no centro é perfect ao vivo")
	_checkNear(float(center.get("mult", 0.0)), float(_bossService.InterruptPerfectMult), 0.0001, "chefe final: o multiplicador do perfect chega no toque")
	_checkEq(int(center.get("index", -1)), realCount - 1, "o veredito diz qual boss foi pontuado (a identidade entrou no caminho)")

	# ---- A RÉGUA QUE FALTAVA: dois bosses com janelas DECLARADAS diferentes
	# pontuam o MESMO offset de toque de forma diferente. Antes do fix o IdlePolicy
	# chamava InterruptQuality/Bonus sem índice, então boss 0 e boss 9 davam o mesmo
	# veredito e o aperto da escada nunca chegava à arena (conteúdo decorativo).
	var wide : int = 0
	var tight : int = -1
	for i in realCount:
		if float(perfect[i]) < float(perfect[wide]):
			tight = i
	if not _check(tight > 0, "a escada tem um boss com janela perfect mais estreita que a do primeiro (índice %d)" % tight):
		return	# offset entre as duas meias-janelas: dentro da larga, fora da estreita.
	var offset : float = (float(perfect[wide]) + float(perfect[tight])) * 0.5
	var offW : Dictionary = _tapVerdict(wide, 0.5 + offset)
	var offT : Dictionary = _tapVerdict(tight, 0.5 + offset)
	_checkEq(str(offW.get("quality", "")), "perfect", "boss %d (±%.2f): offset %.3f ainda é perfect ao vivo" % [wide, float(perfect[wide]), offset])
	_check(str(offT.get("quality", "")) != "perfect", "boss %d (±%.2f): o MESMO offset %.3f NÃO é perfect ao vivo" % [tight, float(perfect[tight]), offset])
	_check(str(offW.get("quality", "")) != str(offT.get("quality", "")), "mesmo toque, janelas diferentes -> vereditos diferentes (a janela do boss chega à luta)")
	_check(float(offT.get("mult", 0.0)) < float(offW.get("mult", 0.0)), "e o dano aplicado acompanha: x%.2f (boss %d) < x%.2f (boss %d)" % [float(offT.get("mult", 0.0)), tight, float(offW.get("mult", 0.0)), wide])

	# O caso concreto pedido: o 7º boss da arena (índice 6).
	if realCount >= 7:
		var seventh : int = 6
		var off7 : float = (float(perfect[0]) + float(perfect[seventh])) * 0.5
		var v7 : Dictionary = _tapVerdict(seventh, 0.5 + off7)
		var v1 : Dictionary = _tapVerdict(0, 0.5 + off7)
		_check(str(v7.get("quality", "")) != str(v1.get("quality", "")), "7º boss (%s): offset %.3f pontua diferente do 1º boss ao vivo" % [str(_bossService.call("GetBossName", seventh)), off7])

	# Toda fronteira declarada da escada é a fronteira efetiva no toque: varre as
	# meias-janelas e confere dentro/fora pelo CAMINHO LIVE, não pela função pura.
	# As três sondas são, por construção: dentro do perfect do próprio boss, entre
	# as duas janelas dele, e além da good dele.
	for i in realCount:
		var p : float = float(perfect[i])
		var g : float = float(good[i])
		var inPerfect : Dictionary = _tapVerdict(i, 0.5 + p * 0.5)
		var between : Dictionary = _tapVerdict(i, 0.5 + (p + g) * 0.5)
		var outGood : Dictionary = _tapVerdict(i, 0.5 + g + 0.02)
		_checkEq(str(inPerfect.get("quality", "")), "perfect", "boss %d: dentro da própria janela perfect pontua perfect ao vivo" % i)
		_checkEq(str(between.get("quality", "")), "good", "boss %d: entre as duas janelas pontua good (fora do perfect dele já NÃO é perfect)" % i)
		_checkEq(str(outGood.get("quality", "")), "miss", "boss %d: fora da janela good é miss ao vivo (nenhum hit grátis)" % i)
		_checkNear(float(outGood.get("mult", 0.0)), 1.0, 0.0001, "boss %d: miss devolve multiplicador neutro" % i)
		_checkNear(float(inPerfect.get("mult", 0.0)), float(_bossService.InterruptPerfectMult), 0.0001, "boss %d: perfect leva o x%.2f real no toque" % [i, float(_bossService.InterruptPerfectMult)])
		# fonte única: o que o toque aplicou == o que BossService/BossLadder comunicam
		_checkEq(str(between.get("quality", "")), str(_bossService.call("InterruptQuality", 0.5 + (p + g) * 0.5, i)), "boss %d: o veredito ao vivo é o mesmo da função declarada" % i)

	# Legado preservado: os quatro primeiros têm a janela histórica, e o índice -1
	# (sem duelo / contrato antigo) continua pontuando na legacy.
	var legacyOffset : float = 0.08
	var leg : Dictionary = _tapVerdict(-1, 0.5 + legacyOffset)
	_checkEq(str(leg.get("quality", "")), "perfect", "sem índice (-1) a janela LEGACY continua valendo (contrato antigo intacto)")
	for i in mini(4, realCount):
		var lv : Dictionary = _tapVerdict(i, 0.5 + legacyOffset)
		_checkEq(str(lv.get("quality", "")), "perfect", "boss %d (perna antiga): offset ±%.2f segue perfect (nenhum duelo antigo mudou)" % [i, legacyOffset])
	_checkEq(str(_tapVerdict(0, 0.5 + 0.20).get("quality", "")), "good", "chefe da perna nova vs antigo: 0.20 good no boss 0")
	_checkEq(str(_tapVerdict(realCount - 1, 0.5 + 0.20).get("quality", "")), "miss", "e o MESMO 0.20 já é miss no chefe (janela ±%.2f)" % float(good[realCount - 1]))

	# Toque com a janela FECHADA continua no-op: a identidade do boss não abre
	# caminho de pontuação fora da janela (o anti-spam da janela legada intacto).
	var idle : RefCounted = _idlePolicy.new()
	idle.bossIndex = realCount - 1
	idle.skillLoadout = _ints([_bogusSkillID])
	var tgt : Object = _baseAgent.new()
	idle._interruptWindow = false
	idle._interruptRequest = true
	_checkEq(int(idle.GetPriorityOrder().size()), 1, "sanidade: a carga inventada resolve p/ 1 candidato (o hit fica fora da régua)")
	_check(idle._consumeBossInterrupt(tgt).is_empty(), "janela fechada: nenhum veredito, toque ignorado (anti-spam intacto)")
	idle._interruptRequest = true
	idle._interruptWindow = true
	idle._interruptTimer = 0.0
	idle._interruptRequest = false
	_check(idle._consumeBossInterrupt(tgt).is_empty(), "sem toque pendente: nada é pontuado")
	tgt.free()

# ------------------------------------------------------------------ wiring guards
# Motivo de existir: as três pontas que ligam o modelo ao mundo real (tick do
# auto-combat, comando de set, HUD do boss) exigem sessão de farm / janela /
# protocolo para serem exercitadas de verdade, e nada disso roda headless com
# confiança. Então afirmo o MÍNIMO verificável: o gancho está chamado e registrado
# (registro sem Unregister é o bug de leak de comando que a auditoria já achou).

func _source(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

func _suiteWiringGuards():
	print("[suite] wiring guards (chamada real do modelo + registro de comando)")
	var policy : String = _source("res://sources/idle/IdlePolicy.gd")
	_checkHas(policy, "SkillPriority.Select", "IdlePolicy: o tick DELEGAR a escolha ao modelo de prioridade")
	_checkHas(policy, "func _getSkill(target : BaseAgent = null)", "IdlePolicy: seleção conhece o alvo (alcance decide)")
	_checkHas(policy, "_getSkill(target)", "IdlePolicy: _tickCombat/interrupt passam o alvo")
	# O seam que a content-agent reportou (2026-09-27): o toque pontuava sem índice,
	# então a janela apertada da escada nova nunca chegava à arena. A suíte
	# `_suiteInterruptWindowLive` afer isso EXECUTANDO o caminho; estes dois guards
	# são o mínimo que sobrevive mesmo onde a arena não roda (a chamada precisa
	# continuar levando a identidade do boss).
	_checkHas(policy, "BossService.InterruptQuality(phase, bossIndex)", "IdlePolicy: o toque ao vivo pontua na janela DO BOSS (quality)")
	_checkHas(policy, "BossService.InterruptBonus(phase, bossIndex)", "IdlePolicy: o toque ao vivo pontua na janela DO BOSS (multiplicador)")

	var commands : String = _source("res://sources/world/WorldCommands.gd")
	for cmd : String in ["priority", "boss"]:
		_checkHas(commands, "CommandManager.Register(\"%s\"" % cmd, "comando /%s registrado" % cmd)
		_checkHas(commands, "CommandManager.Unregister(\"%s\")" % cmd, "comando /%s desregistrado (sem leak)" % cmd)
	_checkHas(commands, "Launcher.SQL.SaveFormation", "/priority persiste pela gravação de formação já existente (nenhum handler novo em Server.gd)")

	var label : String = _source("res://sources/gui/AlterationLabel.gd")
	_checkHas(label, "ActorCommons.Alteration.POISON", "label: DoT poison tem ramo próprio")
	_checkHas(label, "ActorCommons.Alteration.BURN", "label: DoT burn tem ramo próprio")
	var interactive : String = _source("res://sources/actor/entity/components/Interactive.gd")
	_checkHas(interactive, "ElementCommons.AffinityForAlteration", "cliente: afinidade derivada das stats do alvo (sem byte novo de protocolo)")
	_checkHas(interactive, "Alteration.POISON", "cliente: tick de DoT desce a vida local do mob (barra não fica presa)")
	var bossWindow : String = _source("res://sources/gui/Boss.gd")
	_checkHas(bossWindow, "BossLadder.RequirementText", "HUD do boss: o hint mostra o requisito, não 'gear decides'")
