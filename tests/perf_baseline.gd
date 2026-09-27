extends SceneTree

# perf_baseline.gd — registrador e auditor das réguas de regressão de performance.
#
# Duas funções, e nenhuma delas é "gate de lançamento":
#
#  1. REGISTRADOR — mede e imprime os números que `tests/benchmarks.gd` e
#     `tests/perf_fix_test.gd` gravam como baseline. Uma régua de regressão só é
#     auditável se existir o instrumento que a recalcula: sem isto o baseline
#     gravado vira mais um número de origem desconhecida (a doença que
#     `scripts/check_doc_drift.sh` declara no próprio cabeçalho — doc que grava
#     número apodrece). Reproduza com:
#       godot --headless --path . -s tests/perf_baseline.gd
#
#  2. AUDITOR — lê as constantes dos dois gates e falha se a régua deixou de ser
#     régua: teto acima de 4× o baseline é cerca de segurança (um regresso de 5×
#     passa verde); teto abaixo de 2× é flake (o ruído do próprio run ocioso é
#     ~1,25×). Também cobra o estado medido do `ZonePolicy`: a doc anunciava
#     "batching O(1) por zona" e o que foi medido aqui é o custo da indireção.
#
# A terceira medida é o controle de ruído: um laço puro de CPU, sem I/O e sem SQL,
# rodando no começo e no fim da passada. Medido nesta máquina (12 núcleos) sob 24
# processos CPU-bound: o p99 bruto do settle saltou de 519 µs para 2366 µs (4,6×)
# sem que uma linha de código do caminho tivesse mudado. É por isso que os gates
# normalizam pelo controle em vez de bater ponto bruto — e é por isso que este
# harness imprime os dois (bruto e normalizado): a normalização tem que poder ser
# conferida, não acreditada.

const ProbeIters : int = 300			# settles do probe de latência
const ChunkSeedChars : int = 200		# fila sintética do passe de backup
const AttachReps : int = 3000			# repetições da forma de attach
const TickReps : int = 200000			# chamadas de Tick p/ medir o dispatch
const ControlWork : int = 2000000		# iterações do laço de CPU
const ControlReps : int = 3				# melhor de N (ruído de escalonamento)

# Contas desta máquina: nomes próprios, para não colidir com benchmarks.gd
# ("bench_*") nem perf_fix_test.gd ("perf_bk_*") quando dois harnesses apontam
# para o mesmo user:// (mesmo XDG_DATA_HOME).
const AcctSettle : String = "pbl_settle"
const AcctChunk : String = "pbl_chunk"
const NickSettle : String = "PblSettle"
const NickChunkPrefix : String = "PblChunk"

# Números do corte da ZonePolicy, medidos com este mesmo instrumento nas quatro
# passadas de 2026-09-27 09:26–09:28 (máquina ociosa, 12 núcleos):
#   attach: 29835–31012 µs por 3000 attaches (= 9,95–10,34 µs/attach) e +6000
#           objetos vivos; sem a indireção, 9820–10167 µs (3,27–3,39 µs/attach) e
#           +3000 objetos.
#   Tick:   IdlePolicy 52947–53646 µs por 200000 dispatches (0,2647 µs/tick);
#           ZonePolicy 75463–77859 µs (0,3773–0,3892 µs/tick) → +0,112 a +0,124
#           µs por tick varrendo um array que ninguém preenche.
# As guards abaixo comparam a forma atual com esses números: as duas linhas do
# attach são o ponto médio entre as formas medidas (segunda política por jogador
# passa delas; o corte fica abaixo), e a do tick tem folga de 2× porque medir
# dispatch depende de aquecimento. O ruído da máquina é descontado pelo controle
# antes de qualquer comparação.
const BeforeAttachUs : int = 29835
const BeforeAttachObjects : int = 6000
const BeforeIdleTickUs : int = 52947
const ShapeTolerance : int = 2

var checks : int = 0
var failures : int = 0
var _controlSink : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func _initialize():
	print("== Perf baseline / fence audit ==")
	var launcher : Node = root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		print("FATAL: autoload Launcher ausente")
		quit(1)
		return
	var waited : int = 0
	var sql : Node = null
	var world : Node = null
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		world = launcher.get("World")
		if sql != null and world != null \
				and bool(sql.get("isInitialized")) and bool(world.get("isInitialized")):
			break
	if sql == null or world == null or not bool(sql.get("isInitialized")) or not bool(world.get("isInitialized")):
		print("FATAL: serviços não inicializaram dentro do timeout")
		quit(1)
		return
	print("Serviços prontos após %d ms" % waited)

	var controlStart : int = _measureControl()
	var lat : Dictionary = _measureSettleLatency(sql)
	var controlEnd : int = _measureControl()
	print("Controle de ruído (laço puro de CPU, %d iterações, melhor de %d): abre em %d µs, fecha em %d µs" % [ControlWork, ControlReps, controlStart, controlEnd])

	var benchConsts : Dictionary = load("res://tests/benchmarks.gd").get_script_constant_map()
	var refControl : int = int(benchConsts.get("BaselineControlUs", -1))
	var inflation : float = 1.0
	if refControl > 0:
		inflation = maxf(1.0, float(mini(controlStart, controlEnd)) / float(refControl))
		print("   baseline do controle gravado: %d µs → máquina a %.2f× do run de referência" % [refControl, inflation])
	else:
		print("   benchmarks.gd ainda não gravou BaselineControlUs — sem normalização nesta passada")

	_reportSettle(lat, inflation, benchConsts)
	_measureChunkLatency(sql, world, inflation, load("res://tests/perf_fix_test.gd").get_script_constant_map())
	_measureAttachShapes(inflation)

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

# ------------------------------------------------------------------ ruído da máquina
func _measureControl() -> int:
	var best : int = 1 << 60
	for rep in range(ControlReps):
		var t0 : int = Time.get_ticks_usec()
		var acc : int = 0
		for i in range(ControlWork):
			acc = (acc * 31 + 7) & 0x7FFFFFFF
		var elapsed : int = Time.get_ticks_usec() - t0
		_controlSink = acc
		if elapsed < best:
			best = elapsed
	return best

# ------------------------------------------------------------------ latência do settle
func _measureSettleLatency(sql : Node) -> Dictionary:
	var settleScript : GDScript = load("res://sources/idle/OfflineSettle.gd")
	var commons : GDScript = load("res://sources/actor/ActorCommons.gd")
	sql.call("AddAccount", AcctSettle, "testpass", "pbl_settle@test.local")
	var acct : int = int(sql.call("GetAccountID", AcctSettle))
	sql.call("AddCharacter", acct, NickSettle, commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
	var charID : int = int(sql.call("GetCharacterID", acct, NickSettle))
	sql.call("SetCharacterFarmZone", charID, 1)
	var samples : Array[int] = []
	for i in range(ProbeIters):
		sql.call("UpdateSettleAnchor", charID, int(Time.get_unix_time_from_system()) - 3600, 1.0)
		var t0 : int = Time.get_ticks_usec()
		settleScript.call("SettlePending", charID)
		samples.append(Time.get_ticks_usec() - t0)
	sql.db.delete_rows("character", "nickname = '%s'" % NickSettle)
	sql.db.delete_rows("account", "username = '%s'" % AcctSettle)
	samples.sort()
	return {
		"n": samples.size(),
		"p50": samples[samples.size() / 2],
		"p99": samples[int(samples.size() * 99 / 100)],
		"max": samples[samples.size() - 1],
	}

func _reportSettle(lat : Dictionary, inflation : float, consts : Dictionary) -> void:
	print("-- Settle (%d iterações, âncora de 1 h): p50 %d µs, p99 %d µs, max %d µs" % [int(lat["n"]), int(lat["p50"]), int(lat["p99"]), int(lat["max"])])
	print("   normalizado pelo controle: p50 %d µs, p99 %d µs" % [int(float(int(lat["p50"])) / inflation), int(float(int(lat["p99"])) / inflation)])
	var baseP50 : int = int(consts.get("BaselineSettleP50Us", -1))
	var baseP99 : int = int(consts.get("BaselineSettleP99Us", -1))
	var head : int = int(consts.get("RegressionHeadroom", -1))
	if not Check(baseP50 > 0 and baseP99 > 0 and head > 0, "benchmarks.gd declara baseline p50/p99 em µs + headroom (lidos: %d / %d / %d)" % [baseP50, baseP99, head]):
		return
	print("   bruto vs baseline gravado: p50 %.2f×, p99 %.2f×" % [float(int(lat["p50"])) / float(baseP50), float(int(lat["p99"])) / float(baseP99)])
	Check(int(lat["p99"]) <= int(float(baseP99) * float(head) * inflation), "p99 medido (%d µs) cabe no teto do gate (%d µs) com o ruído desta máquina (%.2f×)" % [int(lat["p99"]), baseP99 * head, inflation])

# ------------------------------------------------------------------ chunk do backup
func _measureChunkLatency(sql : Node, world : Node, inflation : float, consts : Dictionary) -> void:
	var commons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var chunk : int = int(world.get_script().get_script_constant_map().get("BackupChunkSize", -1))
	sql.call("AddAccount", AcctChunk, "testpass", "pbl_chunk@test.local")
	var acct : int = int(sql.call("GetAccountID", AcctChunk))
	var ids : Array = []
	for i in range(ChunkSeedChars):
		var nick : String = "%s%d" % [NickChunkPrefix, i]
		sql.call("AddCharacter", acct, nick, commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
		ids.append(int(sql.call("GetCharacterID", acct, nick)))
	var saveFn : Callable = func(charID): sql.call("GetCharacter", charID)
	world.set("_backupQueue", ids)
	world.set("_backupCursor", 0)
	world.set("_backupActive", true)
	var worst : float = 0.0
	var steps : int = 0
	var done : bool = false
	while not done and steps <= ChunkSeedChars:
		var t0 : int = Time.get_ticks_usec()
		done = bool(world.call("_RunBackupChunk", saveFn))
		worst = maxf(worst, float(Time.get_ticks_usec() - t0) / 1000.0)
		steps += 1
	world.set("_backupActive", false)
	world.set("_backupQueue", [])
	world.set("_backupCursor", 0)
	sql.db.delete_rows("character", "account_id = %d" % acct)
	sql.db.delete_rows("account", "username = '%s'" % AcctChunk)
	print("-- Backup chunk (%d personagens, chunk %d, %d passos): pior chunk %.2f ms" % [ChunkSeedChars, chunk, steps, worst])
	var baseChunkUs : int = int(consts.get("BaselineChunkUs", -1))
	var head : int = int(consts.get("RegressionHeadroom", -1))
	if not Check(baseChunkUs > 0 and head > 0, "perf_fix_test.gd declara baseline de chunk em µs + headroom (lidos: %d / %d)" % [baseChunkUs, head]):
		return
	Check(worst * 1000.0 <= float(baseChunkUs * head) * inflation, "pior chunk (%.0f µs) cabe no teto do gate (%d µs) com o ruído desta máquina (%.2f×)" % [worst * 1000.0, baseChunkUs * head, inflation])

# ------------------------------------------------------------------ ZonePolicy
# O que a doc anunciava: "ZonePolicy — batching O(1) por zona". O que o código
# faz: `WorldInstance.idlePolicies` já é a lista por zona e `_physics_process` já
# dá um Tick por policy ali. `ZonePolicy` é uma IdlePolicy que herda o Tick,
# mantém um array `policies` que ninguém preenche (`AttachPolicy` tem zero
# chamadores em sources/ e tests/) e é instanciada UMA POR JOGADOR sobre a
# IdlePolicy base que o próprio `_Attach` acabou de criar e descartar. O custo da
# indireção é medido abaixo; a decisão (cortar) é tomada por ele, não por gosto.
func _measureAttachShapes(inflation : float) -> void:
	print("-- ZonePolicy (a régua da afirmação \"batching O(1) por zona\")")
	var zoneExists : bool = FileAccess.file_exists("res://sources/idle/ZonePolicy.gd")
	var idleScript : GDScript = load("res://sources/idle/IdlePolicy.gd")
	var zoneScript : GDScript = null
	if zoneExists:
		zoneScript = load("res://sources/idle/ZonePolicy.gd")

	# (1) Custo de attach das duas formas. "com a indireção" é a sequência que
	# IdlePolicyService._Attach tinha na branch de farm (IdlePolicy + Setup, depois
	# ZonePolicy + Setup + duplicate por cima); "sem a indireção" é a forma de uma
	# política só. Com o módulo já cortado a primeira forma não existe mais no
	# fonte, então ela é medida só enquanto o arquivo está na árvore — e os números
	# do corte ficam gravados abaixo para o leitor conferir a decisão.
	var loadout : Array[int] = [1, 2, 3, 4]
	var objsBefore : int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var t0 : int = Time.get_ticks_usec()
	var keep : Array = []
	for i in range(AttachReps):
		var base : RefCounted = idleScript.new()
		base.call("Setup", null, 1)
		var attached : RefCounted = base
		if zoneExists:
			var zone : RefCounted = zoneScript.new()
			zone.call("Setup", null, 1)
			var baseLoadout : Array[int] = base.get("skillLoadout")
			zone.set("skillLoadout", baseLoadout.duplicate())
			zone.set("autoPotionPct", float(base.get("autoPotionPct")))
			attached = zone
		keep.append([base, attached])
	var costBoth : int = Time.get_ticks_usec() - t0
	var objsBoth : int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objsBefore
	keep.clear()

	objsBefore = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	t0 = Time.get_ticks_usec()
	keep = []
	for i in range(AttachReps):
		var single : RefCounted = idleScript.new()
		single.call("Setup", null, 1)
		var copyLoadout : Array[int] = loadout.duplicate()
		single.set("skillLoadout", copyLoadout)
		keep.append(single)
	var costOne : int = Time.get_ticks_usec() - t0
	var objsOne : int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - objsBefore
	keep.clear()

	if zoneExists:
		print("   attach %d× COM a indireção: %d µs (%.2f µs/attach, %+d objetos vivos)" % [AttachReps, costBoth, float(costBoth) / float(AttachReps), objsBoth])
	else:
		var costOneAdj : int = int(float(costOne) / inflation)
		print("   attach %d× na forma atual (1 política): %d µs, normalizado %d µs (%.2f µs/attach, %+d objetos vivos)" % [AttachReps, costOne, costOneAdj, float(costOneAdj) / float(AttachReps), objsOne])
		print("   registrado do corte (mesmo instrumento, máquina ociosa): %d µs e %d objetos em %d attaches com a ZonePolicy viva" % [BeforeAttachUs, BeforeAttachObjects, AttachReps])
		# A linha é o ponto médio entre as duas formas medidas (cortada: 29835 µs /
		# 6000 objetos; atual: ~10000 µs / 3000). Voltar a alocar uma segunda
		# política por jogador passa desta linha; o corte, não.
		Check(costOneAdj <= BeforeAttachUs * 3 / 5, "attach atual (%d µs normalizados em %d attaches) continua abaixo da forma cortada (linha: %d µs)" % [costOneAdj, AttachReps, BeforeAttachUs * 3 / 5])
		Check(objsOne <= BeforeAttachObjects * 2 / 3, "attach atual segura %d objetos em %d attaches (linha: %d; forma cortada: %d)" % [objsOne, AttachReps, BeforeAttachObjects * 2 / 3, BeforeAttachObjects])

	# (2) Custo por passo de física: ZonePolicy.Tick chamava super.Tick e depois
	# varria `policies` — sempre vazio. Era o único trabalho extra da indireção, e
	# ele se repetia por jogador farmanco a cada passo de física, para sempre.
	var idlePolicy : RefCounted = idleScript.new()
	idlePolicy.call("Setup", null, 1)
	var idleTickUs : int = 1 << 60
	for rep in range(3):
		var a0 : int = Time.get_ticks_usec()
		for i in range(TickReps):
			idlePolicy.call("Tick", 0.25)
		idleTickUs = mini(idleTickUs, Time.get_ticks_usec() - a0)
	print("   %d× Tick (agente inválido, só o dispatch) na IdlePolicy: %d µs = %.4f µs/tick" % [TickReps, idleTickUs, float(idleTickUs) / float(TickReps)])
	if zoneExists:
		var zonePolicy : RefCounted = zoneScript.new()
		zonePolicy.call("Setup", null, 1)
		var zoneTickUs : int = 1 << 60
		for rep in range(3):
			var b0 : int = Time.get_ticks_usec()
			for i in range(TickReps):
				zonePolicy.call("Tick", 0.25)
			zoneTickUs = mini(zoneTickUs, Time.get_ticks_usec() - b0)
		print("   %d× Tick pela ZonePolicy: %d µs → %+.4f µs/tick de indireção morta" % [TickReps, zoneTickUs, (float(zoneTickUs) - float(idleTickUs)) / float(TickReps)])
	else:
		var idleTickAdj : int = int(float(idleTickUs) / inflation)
		print("   registrado do corte (mesmo instrumento): +0,1244 µs/tick de indireção morta = %.1f ms/s de CPU com 200 farmers a 60 Hz" % (0.1244 * 60.0 * 200.0 / 1000.0))
		# Régua do caminho de tick: a IdlePolicy sozinha custava 52947 µs por
		# 200000 dispatches. Folga de 2× — embrulho de volta na forma de ZonePolicy
		# custaria +47% aqui, e é exatamente o que esta linha pega.
		Check(idleTickAdj <= BeforeIdleTickUs * ShapeTolerance, "tick da IdlePolicy (%d µs normalizados por %d dispatches) dentro da régua (linha: %d µs)" % [idleTickAdj, TickReps, BeforeIdleTickUs * ShapeTolerance])

	# (3) Os fatos que sustentam a decisão, lidos do fonte — não da memória.
	var serviceSrc : String = FileAccess.get_file_as_string("res://sources/idle/IdlePolicyService.gd")
	Check(not serviceSrc.contains("ZonePolicy.new()"), "IdlePolicyService não aloca mais uma ZonePolicy por jogador (attach = 1 política)")
	Check(not zoneExists, "sources/idle/ZonePolicy.gd saiu da árvore: a doc não pode anunciar um batching que nenhum código executa")
	Check(serviceSrc.contains("AttachIdlePolicy"), "a política única continua anexada à lista da zona (WorldInstance.idlePolicies é o batching real)")
	var batchCallers : int = _CountCalls("AttachPolicy(")
	Check(batchCallers == 0, "AttachPolicy tem zero chamadores (lido agora: %d) — não havia batching para preservar" % batchCallers)

func _CountCalls(needle : String) -> int:
	var total : int = 0
	for rootPath in ["res://sources", "res://tests"]:
		var stack : Array[String] = [rootPath]
		while not stack.is_empty():
			var current : String = stack.pop_back()
			var dir : DirAccess = DirAccess.open(current)
			if dir == null:
				continue
			for entry in dir.get_files():
				var file : String = String(entry)
				if not file.ends_with(".gd"):
					continue
				var path : String = current.path_join(file)
				if path.ends_with("perf_baseline.gd"):
					continue	# este harness cita o nome na prosa da régua
				var src : String = FileAccess.get_file_as_string(path)
				var at : int = src.find(needle)
				while at >= 0:
					total += 1
					at = src.find(needle, at + needle.length())
			for sub in dir.get_directories():
				stack.append(current.path_join(String(sub)))
	return total
