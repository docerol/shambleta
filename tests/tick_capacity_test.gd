extends SceneTree

# tick_capacity_test.gd — P1 de escalabilidade: quantos players por ZONA o tick
# deste processo aguenta, MEDIDO, e não estimado. O número que falta no judge de
# escalabilidade não era "temos MAX_PLAYERS_PER_INSTANCE = 20", era a pergunta
# "20 é grande ou pequeno?" — sem custo de tick por player ninguém pode responder,
# e sem isso o cap de instância é decoração.
#
# Uso:    ./scripts/test.sh tick_capacity
#           (cru: env XDG_DATA_HOME=... godot --headless --path . -s tests/tick_capacity_test.gd)
# Saída:  uma linha por nível + "== RESULT: <n> checks, <m> failures =="
#         e a tabela `== TICK .. ==` que vai transcrita em deploy/SCALING.md.
#
# Método (e por que é este):
#   * Cada nível vive numa ZONA DIFERENTE (1,2,3,4 → instâncias dedicadas
#     #1001..#1004, `IdlePolicyService.ZoneInstanceBase + zoneID`). Zona diferente
#     é isolamento de estado: o que sobra do nível anterior não entra na mediana do
#     próximo, e a shape medida é a de produção — farm zone com sessão idle, onde
#     100+ por zona é o formato real.
#   * O cap de 20 players/instância NÃO sharda id dedicado (contrato da ZonePolicy,
#     ver tests/shard_capacity_test.gd), então aqui os 100/200 ficam de fato numa
#     instância só — que é exatamente o caso que o tick precisa responder.
#   * O TICK RATE medido é o de produção: o harness aplica `Engine.set_max_fps()` +
#     `Engine.set_physics_ticks_per_second()` com `LauncherCommons.ServerMaxFPS`
#     (as duas linhas que o `--server` roda, sources/launcher/Launcher.gd:205-206).
#     Sem isso a régua mediria 60 Hz (o default do Godot, que é o que um harness
#     sem `--server` herda) contra um orçamento de 30 Hz — números que não se
#     comparariam com nada. É checado, não assumido (`physics ticks == 30`).
#   * O custo por passo é a soma dos DOIS monitores de tempo que o próprio engine
#     acumula (`Performance.TIME_PHYSICS_PROCESS` + `Performance.TIME_PROCESS`, ambos
#     em segundos, ambos média móvel de 1 s). Já foi medido por SANDUÍCHE de
#     `process_priority` — dois Nodes marcando `Time.get_ticks_usec()` nos extremos
#     de prioridade — e o sanduíche era MEDIÇÃO ZERO: em sonda isolada (2 Nodes
#     queimando 3 ms cada, um deles dentro de uma `SubViewport`, entre Marks de
#     prioridade ±10^6) a janela dava 0,001 ms enquanto os dois Nodes rodavam 10
#     passos cada. Ordem de prioridade não separa o trabalho das `SubViewport`s (onde
#     moram as `WorldInstance`) dos Marks, então a régua antiga media ruído — e a
#     monotonia exigida abaixo é justamente o que denunciou: 0.00 ms nos quatro
#     níveis. A semântica dos monitores também foi medida e não assumida: 4 ms
#     queimados em `_physics_process` movem `TIME_PHYSICS_PROCESS` (0,38 -> 4,18 ms)
#     e não movem `TIME_PROCESS`; 4 ms em `_process` fazem o contrário. Só falta o
#     render, que em `--headless` não existe — ou seja, a soma é o custo de um passo
#     de servidor, que é exatamente o que se quer limitar.
#   * Além do trabalho por passo sai o PERÍODO REAL do passo (parede / passos): é o
#     que estoura quando o trabalho passa do orçamento, porque o sleep deixa de
#     existir. E o detector é provado: no nível de 200 players o harness queima
#     40 ms/passo (acima dos 33,3 ms) e exige que o período saia do orçamento — sem
#     essa perna, "nenhum nível estourou" poderia significar "o detector não vê nada".
#   * A régua auto-validadora tem três pernas:
#       (a) CALIBRAÇÃO: um Node queima `CalibrationBurnUs` por passo no nível 1 e a
#           mediana do monitor de física TEM de subir o montante pedido (>= 70%).
#       (b) DETECTOR: a sobrecarga de 40 ms/passo tem de estourar o período.
#       (c) CARGA: `1 -> 20 -> 100 -> 200` tem de ser não-decrescente e o custo
#           marginal por player tem de sair > 0 da regressão entre os dois pontos.
#   * Junto com o ms/tick sai o resto do laudo: objetos vivos na instância (players,
#     mobs, agentes globais, nós e recursos), round trips de SQL e esperas na
#     `queryMutex` POR TICK — porque a conclusão de capacidade deste servidor é
#     "um processo, uma mutex de SQL" (deploy/SCALING.md), não "a CPU não aguenta".
#
# Orçamento: `LauncherCommons.ServerMaxFPS` = 30 → 33,3 ms por tick de física
# (sources/launcher/LauncherCommons.gd:19). É o número que o servidor persegue em
# produção; o que estoura não é o frame do cliente, é o passo de simulação.

const Levels : Array[int] = [1, 20, 100, 200]
const Zones : Array[int] = [1, 2, 3, 4]
const SampleFrames : int = 120
const WarmupFrames : int = 45			# 1,5 s a 30 Hz: os monitores são média móvel de 1 s
const SkipFrames : int = 30				# descarta o transitório do início da janela
const CalibrationBurnUs : int = 4000	# 4 ms por passo, queimados de propósito
const CalibrationFloorPct : float = 0.70	# a régua tem de ver >= 70% do que foi queimado
const OverloadBurnUs : int = 40000		# 40 ms/passo > orçamento: tem de estourar de verdade
const NickPrefix : String = "TickCap"
const AcctPrefix : String = "tickcap"

var checks : int = 0
var failures : int = 0
var launcher : Node = null
var sql : Node = null
var world : Node = null
var dbScript : GDScript = null
var worldAgentScript : GDScript = null
var policyScript : GDScript = null
var actorCommonsScript : GDScript = null
var spawnScript : GDScript = null
var farmScript : GDScript = null
var commonsScript : GDScript = null
var suites : RefCounted = null

var budgetMs : float = 33.3
var calib : Node = null
var agents : Array = []
var charIDs : Array = []
var rows : Array = []

# Calibre: queima `us` de tempo real por passo de física dentro da MESMA árvore de
# processamento que as WorldInstance (um Node filho de `root`, sem prioridade
# especial). Serve para uma única pergunta: a régua abaixo vê trabalho que ela não
# deveria ver? Se a mediana não sobe com este Node ligado, o número do harness é
# ruído e os checks de monotonia não significam nada.
class Burn extends Node:
	var us : int = 0
	var steps : int = 0
	func _physics_process(_delta : float) -> void:
		if us <= 0:
			return
		var started : int = Time.get_ticks_usec()
		steps += 1
		while Time.get_ticks_usec() - started < us:
			pass

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(actual : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] %s (esperado %s, atual %s)" % [label, str(expected), str(actual)])
		return false
	print("  [ok] " + label)
	return true

func Note(text : String) -> void:
	print("  . " + text)

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_run()

func _median(values : Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted : Array = values.duplicate()
	sorted.sort()
	return float(sorted[int(sorted.size() / 2)])

func _p(value : float, values : Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted : Array = values.duplicate()
	sorted.sort()
	var idx : int = clampi(int(ceil(float(sorted.size()) * value)) - 1, 0, sorted.size() - 1)
	return float(sorted[idx])

func _frames(count : int) -> void:
	for i in range(count):
		await process_frame

# --------------------------------------------------------------------------- setup de nível

func _fixture(index : int) -> int:
	var charID : int = int(suites.call("CreateFixture", sql, "%s%03d" % [AcctPrefix, index], "%s%03d" % [NickPrefix, index]))
	if charID != 0:
		charIDs.append(charID)
	return charID

func _playerSpawn(mapObj : Object) -> Object:
	var types : Dictionary = actorCommonsScript.get_script_constant_map().get("Type", {})
	var spawnPoint : Object = spawnScript.new()
	spawnPoint.set("map", mapObj)
	spawnPoint.set("type", int(types.get("PLAYER", 0)))
	spawnPoint.set("id", int(dbScript.get("PlayerHash")))
	spawnPoint.set("is_global", false)
	spawnPoint.set("spawn_offset", Vector2i(32, 32))
	var monsterType : int = int(types.get("MONSTER", 2))
	for spawn in (mapObj.get("spawns") as Array):
		if spawn != null and int(spawn.get("type")) == monsterType:
			spawnPoint.set("spawn_position", spawn.get("spawn_position"))
			break
	return spawnPoint

# N players reais numa instância dedicada de zona, cada um com sessão idle de verdade
# (é a shape de produção: quem faz o zone policy tickar é a policy, não o agente vazio).
func _seedZone(zoneID : int, count : int) -> Dictionary:
	var zone : Object = farmScript.call("GetZone", zoneID)
	var out : Dictionary = {"inst": null, "players": 0, "sessions": 0}
	if zone == null:
		return out
	var mapObj : Object = world.call("GetMap", int(zone.get("mapID")))
	if mapObj == null:
		return out
	var instID : int = int(policyScript.call("GetFarmInstanceID", zoneID))
	var instances : Dictionary = mapObj.get("instances")
	var stale : Object = instances.get(instID, null)
	if stale != null:
		stale.call("Destroy")
		instances.erase(instID)
	mapObj.call("CreateInstance", instID)
	var inst : Object = null
	for i in range(400):
		inst = instances.get(instID, null)
		if inst != null and bool(inst.is_node_ready()) and int(NavigationServer2D.map_get_iteration_id(mapObj.get("mapRID"))) > 0:
			break
		await process_frame
		inst = null
	if inst == null:
		return out
	out["inst"] = inst
	for i in range(count):
		var charID : int = _fixture(charIDs.size() + 1)
		if charID == 0:
			break
		var agent : Node = worldAgentScript.call("CreateAgent", _playerSpawn(mapObj), instID, "%s%03d" % [NickPrefix, charID]) as Node
		if agent == null:
			break
		agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
		agents.append(agent)
		out["players"] = int(out["players"]) + 1
		if bool(policyScript.call("StartIdleSession", agent, zoneID)):
			out["sessions"] = int(out["sessions"]) + 1
	await _frames(WarmupFrames)
	return out

# ------------------------------------------------------------------------------ medição

# Amostra `SampleFrames` passos de física. O trabalho por passo é a soma dos dois
# monitores que o PRÓPRIO engine acumula em janelas de 1 s, ambos devolvidos em
# segundos (calibrados em sonda isolada, fases de 3 s com queima conhecida:
# 4 ms injetados em `_physics_process` movem `TIME_PHYSICS_PROCESS` 0,38 -> 4,18 ms
# e NÃO movem `TIME_PROCESS`; 4 ms em `_process` movem `TIME_PROCESS` -> 4,36 ms e
# deixam `TIME_PHYSICS_PROCESS` em 4,17 ms — ou seja, um cobre a física, o outro o
# resto da iteração, e o custo de um passo de servidor é a soma):
#   * `Performance.TIME_PHYSICS_PROCESS` — callbacks de `_physics_process` de toda a
#     árvore, inclusive as `SubViewport`s onde moram as `WorldInstance`;
#   * `Performance.TIME_PROCESS` — `_process`/deferred/rede da mesma iteração.
# Junto sai o PERÍODO real do passo (parede / passos): enquanto o trabalho couber no
# orçamento o sleep preenche o resto e o período é o próprio orçamento; quando não
# cabe, o sleep acaba e o período cresce. É essa a assinatura de "estourou", e o
# harness a PROVA ligando 40 ms de queima por passo no nível mais carregado.
func _measure(inst : Object, label : String) -> Dictionary:
	var work : Array = []
	var physSamples : Array = []
	var idleSamples : Array = []
	var sqlStart : int = int(sql.call("QueryCount"))
	var mutexStart : Dictionary = sql.call("QueryMutexWaitStats")
	var framesStart : int = int(Engine.get_physics_frames())
	var wallStart : int = Time.get_ticks_usec()
	var wallEnd : int = wallStart
	var previousSampledFrame : int = framesStart
	var awaited : int = 0
	await physics_frame
	for i in range(SampleFrames):
		await physics_frame
		awaited += 1
		wallEnd = Time.get_ticks_usec()
		var frameID : int = int(Engine.get_physics_frames())
		if frameID <= previousSampledFrame:
			continue
		previousSampledFrame = frameID
		var phys : float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var idle : float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physSamples.append(phys)
		idleSamples.append(idle)
		work.append(phys + idle)
	var sqlEnd : int = int(sql.call("QueryCount"))
	var mutexEnd : Dictionary = sql.call("QueryMutexWaitStats")
	# `Engine.get_physics_frames()` conta ITERAÇÕES com física; o `physics_frame` que
	# se deu await conta PASSOS de física reais. Os dois denominadores saem juntos
	# justamente para quem reler o número poder ver se a máquina rodou mais de um
	# passo por iteração (`Engine.max_physics_steps_per_frame`).
	var iterations : int = maxi(int(Engine.get_physics_frames()) - framesStart, 1)
	awaited = maxi(awaited, 1)
	var periodMs : float = float(wallEnd - wallStart) / 1000.0 / float(awaited)
	var iterMs : float = float(wallEnd - wallStart) / 1000.0 / float(iterations)
	# descarta o transitório da entrada da janela: os monitores são média móvel de 1 s
	# e o primeiro amostrado ainda carrega o setup do nível (spawn de 200 agentes,
	# políticas, navegação)
	for cut in range(mini(SkipFrames, work.size())):
		work.pop_front()
		physSamples.pop_front()
		idleSamples.pop_front()
	var median : float = _median(work)
	var globalAgents : Variant = worldAgentScript.get("agents")
	var row : Dictionary = {
		"label": label,
		"players": (inst.get("players") as Array).size(),
		"mobs": (inst.get("mobs") as Array).size(),
		"policies": (inst.get("idlePolicies") as Array).size(),
		"agents": (globalAgents as Dictionary).size() if typeof(globalAgents) == TYPE_DICTIONARY else 0,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"staticMb": int(Performance.get_monitor(Performance.MEMORY_STATIC) / (1024 * 1024)),
		"samples": work.size(),
		"steps": awaited,
		"iterations": iterations,
		"iterMs": iterMs,
		"medianMs": median,
		"physMs": _median(physSamples),
		"idleMs": _median(idleSamples),
		"p95Ms": _p(0.95, work),
		"maxMs": float(work.max()) if not work.is_empty() else 0.0,
		"periodMs": periodMs,
		# Dois detectores independentes, OU entre eles: (a) o PERÍODO atingido — o
		# sleep do tick some quando o trabalho passa do orçamento; (b) o TRABALHO
		# medido pelos monitores da engine. (b) é o conservador e o que publicamos:
		# um passo que gasta 40 ms em `_physics_process` não cumpre 33 ms de orçamento
		# mesmo quando o relógio disfarça (média móvel de 1 s, passos encaixados,
		# boost de clock). Os dois números saem juntos na linha == TICK == para quem
		# reler poder conferir qual dos dois disparou.
		"missedBudget": periodMs > budgetMs + 1.0 or median > budgetMs,
		"overWork": median > budgetMs,
		"overPeriod": periodMs > budgetMs + 1.0,
		"queriesPerTick": float(sqlEnd - sqlStart) / float(awaited),
		"mutexWaitsPerTick": float(int(mutexEnd.get("waits", 0)) - int(mutexStart.get("waits", 0))) / float(awaited),
		"mutexUsPerTick": float(int(mutexEnd.get("microseconds", 0)) - int(mutexStart.get("microseconds", 0))) / float(awaited),
	}
	rows.append(row)
	print("== TICK %s: %d players, %d mobs, %d policies | trabalho mediana %.2f ms/passo (fisica %.2f + idle %.2f; p95 %.2f, max %.2f) | periodo %.2f ms vs budget %.2f ms%s | %d passos em %d iteracoes (%.2f ms/iteracao) | SQL %.1f rt/tick, mutex %.2f us/tick | %d agentes, %d nos, %d recursos, %d MB | amostras %d ==" % [
		label, int(row["players"]), int(row["mobs"]), int(row["policies"]), median, float(row["physMs"]), float(row["idleMs"]),
		float(row["p95Ms"]), float(row["maxMs"]),
		periodMs, budgetMs, " (ESTOURADO)" if bool(row["missedBudget"]) else "",
		awaited, iterations, iterMs,
		float(row["queriesPerTick"]), float(row["mutexUsPerTick"]),
		int(row["agents"]), int(row["nodes"]), int(row["resources"]), int(row["staticMb"]), int(row["samples"])])
	return row

# ------------------------------------------------------------------------------------- main
func _run() -> void:
	print("== P1 escalabilidade: custo de tick por player (1 / 20 / 100 / 200 por zona) ==")
	launcher = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 40000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		world = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")):
			break
	if not Check(sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")),
			"SQL + World booteds (%d ms de espera)" % waited):
		await _finish()
		return

	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()"):
		await _finish()
		return

	worldAgentScript = load("res://sources/world/WorldAgent.gd")
	policyScript = load("res://sources/idle/IdlePolicyService.gd")
	actorCommonsScript = load("res://sources/actor/ActorCommons.gd")
	spawnScript = load("res://addons/tiled_importer/SpawnObject.gd")
	farmScript = load("res://sources/idle/FarmZoneData.gd")
	commonsScript = load("res://sources/launcher/LauncherCommons.gd")
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	suites = suitesScript.new()
	if not Check(worldAgentScript != null and policyScript != null and actorCommonsScript != null and spawnScript != null
			and farmScript != null and commonsScript != null and suites != null,
			"WorldAgent + IdlePolicyService + ActorCommons + SpawnObject + FarmZoneData + LauncherCommons + IdleTests carregados"):
		await _finish()
		return

	var serverFps : int = int(commonsScript.get("ServerMaxFPS"))
	Check(serverFps > 0, "LauncherCommons.ServerMaxFPS = %d" % serverFps)
	budgetMs = 1000.0 / float(maxi(serverFps, 1))
	# Mesma dupla que o `--server` aplica (sources/launcher/Launcher.gd:205-206): sem
	# isto o harness mediria a 60 Hz (default do Godot, que é o que um SceneTree sem
	# `--server` herda) contra um orçamento de 30 Hz.
	Engine.set_max_fps(serverFps)
	Engine.set_physics_ticks_per_second(serverFps)
	CheckEq(int(Engine.get_physics_ticks_per_second()), serverFps,
			"tick do harness = tick de produção (%d Hz, budget %.2f ms/passo)" % [serverFps, budgetMs])
	Note("orçamento de tick = %.2f ms (1000/%d). Trabalho por passo abaixo disso = o processo acompanha o relógio." % [budgetMs, serverFps])
	Note("teto de instância pública (WorldInstance.MAX_PLAYERS_PER_INSTANCE) = %d; zona dedicada NÃO é shardada por contrato" % int(
			load("res://sources/world/WorldInstance.gd").get_script_constant_map().get("MAX_PLAYERS_PER_INSTANCE", 0)))

	calib = Burn.new()
	calib.name = "TickCalibre"
	root.add_child(calib)
	await _frames(4)
	Check(bool(calib.is_node_ready()) and calib.get_parent() == root,
			"calibre ligado na mesma árvore das WorldInstances (us=%d desligado)" % int(calib.get("us")))

	var previous : Dictionary = {}
	for i in range(Levels.size()):
		var level : int = int(Levels[i])
		var zoneID : int = int(Zones[i])
		var setup : Dictionary = await _seedZone(zoneID, level)
		var inst : Object = setup.get("inst")
		if not Check(inst != null, "nível %d: instância dedicada da zona %d pronta" % [level, zoneID]):
			continue
		var players : int = int(setup.get("players"))
		if not CheckEq(players, level, "nível %d: %d players reais na zona %d" % [level, players, zoneID]):
			continue
		Check(int(setup.get("sessions")) > 0, "nível %d: %d sessão(ões) idle de verdade anexada(s)" % [level, int(setup.get("sessions"))])
		var row : Dictionary = await _measure(inst, "%d players / zona %d" % [level, zoneID])
		Check(int(row["samples"]) >= SampleFrames - SkipFrames - 5, "nível %d: %d amostras de tick (janela não foi truncada)" % [level, int(row["samples"])])

		# (a) CALIBRAÇÃO — só no nível 1, com a carga mínima, para que o delta seja
		# atribuível à queima e não ao resto. Se a régua não enxerga 4 ms por passo
		# que ela mesma manda queimar, nada mais nesta saída é medição.
		if i == 0:
			var physBefore : int = int(calib.get("steps"))
			calib.set("us", CalibrationBurnUs)
			await _frames(WarmupFrames)
			var calibrated : Dictionary = await _measure(inst, "%d players + calibre %d us/passo" % [level, CalibrationBurnUs])
			var expectedBurn : float = float(CalibrationBurnUs) / 1000.0
			calib.set("us", 0)
			await _frames(WarmupFrames)
			Check(int(calib.get("steps")) - physBefore >= int(calibrated["steps"]) / 2,
					"o calibre queimou de verdade (%d passos de física com ele ligado)" % (int(calib.get("steps")) - physBefore))
			Check(float(calibrated["physMs"]) >= float(row["physMs"]) + expectedBurn * CalibrationFloorPct,
					"calibre: +%.2f ms de física por passo foram vistos pelo monitor (%.2f -> %.2f ms; piso %.2f ms)" % [
						expectedBurn, float(row["physMs"]), float(calibrated["physMs"]), expectedBurn * CalibrationFloorPct])
			rows.pop_back()	# a linha do calibre não é um nível de capacidade

		# (b) PROVA DO DETECTOR DE ESTOURO — no nível mais carregado, 40 ms/passo
		# (acima dos 33,3 ms de orçamento) TEM de empurrar o período real para fora do
		# orçamento. Sem esta perna, "nenhum nível estourou" poderia significar
		# simplesmente "o detector não vê nada".
		if i == Levels.size() - 1:
			calib.set("us", OverloadBurnUs)
			await _frames(WarmupFrames)
			var overloaded : Dictionary = await _measure(inst, "%d players + sobrecarga %d us/passo" % [level, OverloadBurnUs])
			calib.set("us", 0)
			await _frames(WarmupFrames)
			Check(bool(overloaded["missedBudget"]),
					"detector de estouro responde: %d ms/passo queimados levaram o periodo a %.2f ms (> budget %.2f ms)" % [
						OverloadBurnUs / 1000, float(overloaded["periodMs"]), budgetMs])
			Check(float(overloaded["periodMs"]) >= float(OverloadBurnUs) / 1000.0 * 0.6,
					"o periodo medido sobe com a queima injetada (%.2f ms com %d ms/passo)" % [
						float(overloaded["periodMs"]), OverloadBurnUs / 1000])
			rows.pop_back()	# idem: sobrecarga artificial não é nível de capacidade

		# (c) CARGA — monotonia entre níveis.
		if previous.has("medianMs"):
			Check(float(row["medianMs"]) >= float(previous["medianMs"]) - 0.5,
					"nível %d: mediana %.2f ms não caiu contra o nível anterior (%.2f ms)" % [
						level, float(row["medianMs"]), float(previous["medianMs"])])
		previous = row

	# Réguas que este harness deixa como contrato de regressão.
	var byLevel : Dictionary = {}
	for row in rows:
		byLevel[int(str(row["label"]).split(" ")[0])] = row
	if byLevel.has(1) and byLevel.has(20):
		var floorMs : float = float(byLevel[1]["medianMs"])
		var full : float = float(byLevel[20]["medianMs"])
		Check(full <= maxf(budgetMs, floorMs * 4.0),
				"instância CHEIA (%d players) cabe no tick: %.2f ms <= max(%.2f budget, 4x piso de %.2f ms)" % [20, full, budgetMs, floorMs])
		Check(floorMs <= budgetMs, "processo quase vazio (%d player) acompanha o relógio: %.2f ms <= %.2f ms" % [1, floorMs, budgetMs])
	if byLevel.has(1) and byLevel.has(200):
		var slopeMs : float = (float(byLevel[200]["medianMs"]) - float(byLevel[1]["medianMs"])) / 199.0
		Check(slopeMs > 0.0, "carga real: 199 players a mais custaram %.3f ms/passos (mediana %.2f -> %.2f ms)" % [
				slopeMs, float(byLevel[1]["medianMs"]), float(byLevel[200]["medianMs"])])
		# Extrapolação DECLARADA do custo medido: onde o trabalho do passo encosta no
		# orçamento. Não é medida, é a reta que passa pelos dois pontos medidos — e é
		# por isso que vai para deploy/SCALING.md rotulada como extrapolação.
		if slopeMs > 0.0001:
			var ceiling : int = int((budgetMs - float(byLevel[1]["medianMs"])) / slopeMs)
			Note("extrapolação do custo medido: ~%d players por zona encostam nos %.2f ms de orçamento (piso %.2f ms + %.4f ms/player)" % [
					maxi(ceiling, 0), budgetMs, float(byLevel[1]["medianMs"]), slopeMs])
	# O que estoura o orçamento: o TRABALHO do passo (monitores da engine) e/ou o
	# PERÍODO atingido. Registramos qual dos dois disparou — a mediana de trabalho é
	# a régua conservadora que vai para deploy/SCALING.md.
	var broken : int = 0
	for row in rows:
		if bool(row["missedBudget"]) and broken == 0:
			broken = int(str(row["label"]).split(" ")[0])
	if broken > 0:
		var brow : Dictionary = byLevel[broken]
		var fired : Array[String] = []
		if bool(brow["overWork"]):
			fired.append("trabalho %.2f ms/passo" % float(brow["medianMs"]))
		if bool(brow["overPeriod"]):
			fired.append("período %.2f ms" % float(brow["periodMs"]))
		Note("primeiro nível MEDIDO estourando o orçamento: %d players/zona disparou (%s) contra %.2f ms de orçamento" % [
				broken, ", ".join(fired), budgetMs])
		Note("leitura: com o cap de 20 players/instância (%s), UMA instância usa %.2f ms dos %.2f ms; o que encosta no orçamento é o TOTAL de players no processo (~1 único thread de tick), não o cap de instância." % [
				str(Levels), float(byLevel[20]["medianMs"]) if byLevel.has(20) else 0.0, budgetMs])
	else:
		Note("nenhum nível medido (%s) estourou o orçamento de %.2f ms nesta máquina" % [str(Levels), budgetMs])


	await _finish()

func _finish() -> void:
	print("-- limpeza --")
	for agent in agents.duplicate():
		var node : Node = agent as Node
		if node != null and is_instance_valid(node):
			policyScript.call("StopIdleSession", node)
			worldAgentScript.call("RemoveAgent", node)
	agents.clear()
	await _frames(8)
	if sql != null and not charIDs.is_empty():
		sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE ?;", ["%s%%" % NickPrefix])
		sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE ?;", ["%s%%" % AcctPrefix])
		Note("fixtures %s* removidos (%d chars)" % [NickPrefix, charIDs.size()])
	print("== TABELA (deploy/SCALING.md) ==")
	for row in rows:
		print("  %s | trabalho %.2f ms/passo (fis %.2f + idle %.2f) | p95 %.2f | max %.2f | periodo %.2f ms | budget %.2f ms%s | SQL %.1f rt/tick | mutex %.2f us/tick | %d agentes | %d nos | %d MB" % [
			str(row["label"]), float(row["medianMs"]), float(row["physMs"]), float(row["idleMs"]),
			float(row["p95Ms"]), float(row["maxMs"]), float(row["periodMs"]),
			budgetMs, " ESTOURADO" if bool(row["missedBudget"]) else "",
			float(row["queriesPerTick"]), float(row["mutexUsPerTick"]), int(row["agents"]), int(row["nodes"]), int(row["staticMb"])])


	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
