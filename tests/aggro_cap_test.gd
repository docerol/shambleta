extends SceneTree

# AUDITORIA 2026-09-28 — a cerca de `attackers` existia no papel e não no runtime.
# `AIAgent.RemoveOldestAttacker()` fechava com `attackers.erase(0)`, e `Array.erase()`
# recebe VALOR, não índice: num `Array[Dictionary]` aquilo não removia nada, devolvia
# erro por chamada, e o erro era impresso DENTRO do passo físico — milhares de linhas
# por run, dentro do custo que o harness de escala mede. Conseqüência de produto: o teto
# `AICommons.MaxAttackerCount` nunca foi cobrado, e a lista de quem bate num mob cresce
# sem limite enquanto o mob vive.
#
# Blocos:
#   A. comportamento: adicionar mais atacantes que o teto cobra o teto (era o bug);
#   B. ordem: quem sai é o MAIS VELHO pelo `time` declarado, e sai exatamente um;
#   C. repetição: um entry repetido soma dano no lugar de inflar a lista;
#   D. classe: nenhum arquivo do projeto chama `Array.erase(<literal inteiro>)`,
#      e o `RemoveOldestAttacker` versionado usa o caminho que tira de fato.
#
# Uso: godot --headless --path . -s tests/aggro_cap_test.gd
# Exit code = checks falhos. Última linha: `== AGGRO CAP: N checks, M failures ==`.
#
# Regra dos harnesses `-s`: o main-loop compila antes de autoloads e `class_name`
# existirem — nada de anotação de tipo desses identificadores; tudo via load().

var checks : int = 0
var failures : int = 0
var made : Array = []

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (esperado %d, medido %d)" % [label, expected, value])

func Spawn(scriptRef : GDScript) -> Object:
	var node = scriptRef.new()
	made.append(node)
	return node

func _initialize():
	_runTests()

func _runTests():
	print("== aggro cap: RemoveOldestAttacker tira mesmo ==")
	var baseScript : GDScript = load("res://sources/actor/agent/BaseAgent.gd")
	var aiScript : GDScript = load("res://sources/actor/agent/variants/AIAgent.gd")
	var commons : GDScript = load("res://sources/ai/AICommons.gd")
	if baseScript == null or aiScript == null or commons == null:
		Check(false, "scripts de agente carregam")
		_finish()
		return
	var consts : Dictionary = commons.get_script_constant_map()
	var cap : int = int(consts.get("MaxAttackerCount", 0))
	Check(cap > 0, "o teto de atacantes é declarado num só lugar (`AICommons.MaxAttackerCount`) — medido %d" % cap)

	var target = Spawn(aiScript)

	# A. o teto é cobrado: cap + 6 adições não estouram cap.
	var extra : int = cap + 6
	var i : int = 0
	while i < extra:
		target.AddAttacker(Spawn(baseScript), 10 + i)
		i += 1
	CheckEq(target.attackers.size(), cap, "A1 cap + %d ataques viram exatamente o teto na lista" % extra)
	Check(target.attackers.size() <= cap, "A2 a lista nunca passa do teto")
	var summed : int = 0
	for entry in target.attackers:
		summed += int(entry.damage)
	Check(summed > 0, "A3 os ataques que ficaram somam dano (medido %d)" % summed)
	Check(target.GetMostValuableAttacker() != null, "A4 com a lista cobrada ainda há alvo a retaliar")

	# B. quem sai é o mais velho, e sai um só.
	var aged = Spawn(aiScript)
	var j : int = 0
	while j < cap:
		aged.attackers.append({"attacker": Spawn(baseScript), "damage": 1, "time": 1000 + j * 100})
		j += 1
	var before : int = aged.attackers.size()
	aged.RemoveOldestAttacker()
	CheckEq(aged.attackers.size(), before - 1, "B1 RemoveOldestAttacker tira exatamente um (antes %d)" % before)
	var oldestStill : bool = false
	for entry in aged.attackers:
		if int(entry.time) == 1000:
			oldestStill = true
	Check(not oldestStill, "B2 quem saiu foi o MAIS VELHO (time 1000)")
	var minLeft : int = -1
	for entry in aged.attackers:
		var t : int = int(entry.time)
		if minLeft < 0 or t < minLeft:
			minLeft = t
	CheckEq(minLeft, 1100, "B3 o novo piso da lista é o segundo mais velho")
	var emptyOne = Spawn(aiScript)
	emptyOne.RemoveOldestAttacker()
	CheckEq(emptyOne.attackers.size(), 0, "B4 lista vazia não vira erro nem elemento fantasma")

	# C. entrada repetida soma no lugar, não infla.
	var repeat = Spawn(aiScript)
	var one = Spawn(baseScript)
	repeat.AddAttacker(one, 5)
	repeat.AddAttacker(one, 7)
	repeat.AddAttacker(one, 9)
	CheckEq(repeat.attackers.size(), 1, "C1 três golpes do mesmo atacante ocupam uma linha")
	CheckEq(int(repeat.attackers[0].damage), 21, "C2 e os três golpes somam na linha")

	# D. a classe do bug some do repo inteiro.
	var hits : PackedStringArray = _grepTree()
	CheckEq(hits.size(), 0, "D1 nenhum `.erase(<literal inteiro>)` sob sources/, tests/ ou companion/ (achados: %s)" % ", ".join(hits))
	var aiText : String = FileAccess.get_file_as_string("res://sources/actor/agent/variants/AIAgent.gd")
	Check(aiText.contains("attackers.pop_front()"), "D2 o RemoveOldestAttacker versionado usa o caminho que tira de fato")
	Check(not aiText.contains("attackers.erase("), "D3 e não existe mais o `attackers.erase(` que não tirava nada")
	Check(aiText.contains("if attackers.size() > AICommons.MaxAttackerCount:"), "D4 a cerca continua lendo o teto único do `AICommons`, não um número local")

	_finish()

func _grepTree() -> PackedStringArray:
	var rx : RegEx = RegEx.create_from_string(r"\.erase\(\s*[0-9]+\s*\)")
	var found : PackedStringArray = []
	# Este arquivo carrega o padrão como STRING de RegEx; a varredura acusa CHAMADA,
	# então o autor da régua fica fora do próprio domínio varrido.
	var selfName : String = "res://tests/aggro_cap_test.gd"
	for base in ["res://sources", "res://tests", "res://companion"]:
		var stack : Array[String] = [base]
		while not stack.is_empty():
			var dir : String = stack.pop_back()
			var entries := DirAccess.open(dir)
			if entries == null:
				continue
			entries.list_dir_begin()
			var name : String = entries.get_next()
			while name != "":
				if name != "." and name != "..":
					var full : String = dir + "/" + name
					if entries.current_is_dir():
						stack.append(full)
					elif (name.ends_with(".gd") or name.ends_with(".py")) and full != selfName:
						if rx.search(FileAccess.get_file_as_string(full)) != null:
							found.append(full)
				name = entries.get_next()
			entries.list_dir_end()
	return found

func _finish():
	for node in made:
		if node != null and not node.is_queued_for_deletion():
			node.free()
	made.clear()
	print("== AGGRO CAP: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)
