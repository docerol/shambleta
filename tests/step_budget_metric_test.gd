extends SceneTree

# step_budget_metric_test.gd — o orçamento de passo do server tem que existir como
# GRANDEZA EXPORTADA, e a régua que o pagina tem que apontar para o nome que o
# processo realmente serve. As duas pontas, com controle negativo nas duas:
#
#   1) O INSTRUMENTO (sources/launcher/Launcher.gd): `StepBudgetRecord` é pura — o
#      estado entra, o estado sai — então ela é conferível por mesa com passos
#      sintéticos, sem depender da máquina estar lenta no minuto do run. É aqui que
#      mora o controle negativo da cauda: uma sequência toda dentro do orçamento tem
#      que devolver `overBudget == 0`, e um passo de 34.333 ms (orçamento + folga
#      exatos) tem que devolver "não estourou", porque o predícado é `> orçamento + folga`.
#      Um predícado que virou `>=`, que perdeu a folga, ou que incrementa sempre,
#      vermelha aqui — não no dia em que um juiz olhar o dashboard.
#   2) O EXPORTADOR (sources/system/MetricsServer.gd): `StepBudgetLines` também é
#      pura (estado entra, texto Prometheus sai). Conferido: baldes CUMULATIVOS e
#      monótonos, `+Inf == count`, `_sum`/`_count` batendo com as amostras, `max`
#      confesso, e — a régua da casa sobre indisponível — um estado sem passo algum
#      renderiza AUSENCIA, não zero.
#   3) O ALERTA (deploy/alerts.rules.yml): todo nome `shambleta_*` citado por uma
#      regra, inclusive em comentário, tem que ser emitido pelo servidor no mesmo
#      predícado que o portão da casa usa (`body += "<nome> `). É a régua que impede
#      o alerta que nunca dispara porque aponta para uma série que ninguém serve. O
#      predícado é conferido contra um nome plantado, para provar que morde.
#   4) A EMENDA DE PAREDE: passos REAIS deste processo, com um `Burn` de 40 ms/passo
#      ligado no laço. O contador de estouro e o bucket têm de se mover com a queima
#      injetada — é a mesma perna "detector de período" do `multi_instance_tick_test`,
#      agora aplicada ao número que sai por /metrics. Sem esta perna, as três acima
#      provam que a função está certa e não provam que alguém a chama.
#
# Uso: ./scripts/test.sh one step_budget_metric_test 300
# Saída: uma linha por perna + "== RESULT: <n> checks, <m> failures =="
#
# Como todo harness `-s`: nada de identificador de autoload em anotação de tipo nem
# `class_name` de projeto — tudo via `load()`/`call()`/`get_node_or_null()`.
# Não abre rede, não escreve banco de usuário: roda no sandbox do gate.

const LauncherPath : String = "res://sources/launcher/Launcher.gd"
const MetricsPath : String = "res://sources/system/MetricsServer.gd"
const AlertsPath : String = "res://deploy/alerts.rules.yml"
const CommonsPath : String = "res://sources/launcher/LauncherCommons.gd"
const EmitNameRegex : String = "body \\+= \"(shambleta_[a-z0-9_]+) "
const RefNameRegex : String = "(shambleta_[a-z0-9_]+)"
const PlantedMissingName : String = "shambleta_passo_que_ninguem_emite"
const ServerFps : int = 30
const BudgetUs : int = 33333			# 1e6 / 30, a bounda do orçamento
const ToleranceUs : int = 1000		# folga do throttle, mesma do laço de produção
const BurnUs : int = 40000			# 40 ms/passo > orçamento + folga
const BurnSteps : int = 40
const WarmupFrames : int = 20
const ReadBytes : int = 262144
const BootWaitMs : int = 30000		# teto de espera pelo `_ready` do autoload, não é régua

var checks : int = 0
var failures : int = 0
var launcher : Node = null
var launcherScript : GDScript = null
var metricsScript : GDScript = null
var emittedNames : Dictionary = {}

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
	# Tipos diferentes não comparam (a check abortada não contava como falha; mesma
	# armadilha registrada em tests/doc_facts_test.gd).
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] %s (esperado %s, atual %s)" % [label, str(expected), str(actual)])
		return false
	print("  [ok] " + label)
	return true

func Note(text : String) -> void:
	print("  . " + text)

# Mesma sonda de `tests/multi_instance_tick_test.gd`: queima tempo de parede dentro
# do laço de física, no mesmo lugar onde o produto cronometra.
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

func _read(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes : PackedByteArray = file.get_buffer(ReadBytes)
	file.close()
	return bytes.get_string_from_utf8()

func _frames(count : int) -> void:
	for i in range(count):
		await process_frame

func _snapshot() -> Dictionary:
	return launcher.call("StepBudgetSnapshot")

func _state(budgetUs : int) -> Dictionary:
	return launcherScript.call("StepBudgetNew", budgetUs)

func _record(state : Dictionary, workUs : int, periodUs : int, drift : int) -> void:
	launcherScript.call("StepBudgetRecord", state, workUs, periodUs, drift)

func _lines(state : Dictionary) -> String:
	return String(metricsScript.call("StepBudgetLines", state))

# ------------------------------------------------------------------ 1. o instrumento

func _checkRecorder() -> void:
	print("-- perna 1: mesa sobre StepBudgetRecord (buckets, estouro, atraso) --")
	var bounds : Array = launcherScript.get_script_constant_map().get("StepBucketUs", [])
	CheckEq(bounds, [16667, 33333, 50000, 100000],
			"as boundas de bucket são as faixas do orçamento (16,67/33,33/50/100 ms), lidas do fonte")
	CheckEq(int(launcherScript.get_script_constant_map().get("StepBudgetToleranceUs", -1)), ToleranceUs,
			"a folga do predícado é a medida do throttle (%d us), não um número digitado aqui" % ToleranceUs)

	# Seis passos sintéticos, escolhidos para morder nas três costuras: um na bounda
	# exata de bucket, um acima do orçamento mas DENTRO da folga, e um acima da folga.
	var state : Dictionary = _state(BudgetUs)
	var samples : Array = [[5000, 5000], [8000, 20000], [30000, 34000], [4000, 34333], [70000, 60000], [130000, 120000]]
	var sumUs : int = 0
	for sample in samples:
		var workUs : int = int(sample[0])
		var periodUs : int = int(sample[1])
		sumUs += periodUs
		_record(state, workUs, periodUs, 0)
	var stepCount : int = samples.size()
	CheckEq(int(state["steps"]), stepCount, "%d passos registrados" % stepCount)
	CheckEq(int(state["periodSumUs"]), sumUs, "a soma dos períodos é a soma das amostras (%d us)" % sumUs)
	CheckEq(int(state["periodMaxUs"]), 120000, "o máximo do período é confessado, não escondido na agregação")
	CheckEq(state["periodBuckets"], [1, 2, 4, 5],
			"os baldes do período são CUMULATIVOS (%s) — um passo entra em todo balde cuja bounda o cobre" % str(state["periodBuckets"]))
	CheckEq(state["workBuckets"], [3, 4, 4, 5],
			"os baldes do trabalho valem %s para a mesma sequência (%s)" % [str(state["workBuckets"]), str(samples)])
	CheckEq(int(state["overBudget"]), 2,
			"estouro é 2 de %d: 60.000 e 120.000 µs passam de %d µs; 34.000 e 34.333 NÃO passam (34.333 é o predícado estrito `>`, não `>=`)" % [
				stepCount, BudgetUs + ToleranceUs])

	# CONTROLE NEGATIVO da cauda. É esta a perna que morde se a correção regredir:
	# predícado sem folga conta 34.000 (e o servidor ocioso, medindo 33,61 ms de
	# período no piso, contaria TODOS os passos); predícado sempre-verdadeiro conta
	# os cinco; bucket não-cumulativo desmonta a assertiva de cima.
	var quiet : Dictionary = _state(BudgetUs)
	for periodUs in [1000, 8000, 16000, 33000, 34333]:
		_record(quiet, int(periodUs), int(periodUs), 0)
	CheckEq(int(quiet["overBudget"]), 0,
			"CONTROLE NEGATIVO: uma sequência toda dentro de orçamento+folga devolve overBudget == 0 (com o predícado estrito `>` do orçamento, 34.000 µs já vermelharia esta perna)")
	CheckEq(quiet["periodBuckets"], [3, 4, 5, 5],
			"CONTROLE NEGATIVO: os baldes desta sequência são %s — balde não-cumulativo não passa daqui" % str(quiet["periodBuckets"]))

	# Atraso acumulado: `lost` é o PIOR déficit visto, não a soma. Uma correção que
	# somasse o drift por passo (3+5+2 = 10) quebraria a semântica de counter que o
	# `increase()` do alerta lê.
	var driftState : Dictionary = _state(BudgetUs)
	for drift in [3, 5, 2, 5]:
		_record(driftState, 1000, 1000, int(drift))
	CheckEq(int(driftState["lost"]), 5,
			"passos perdidos é o déficit acumulado máximo (3,5,2,5 -> 5), não a soma dos incrementos (que daria 15 e mentiria num increase)")

# ------------------------------------------------------------------ 2. o exportador

func _checkRenderer() -> void:
	print("-- perna 2: StepBudgetLines (Prometheus honesto, e ausência != zero) --")
	# CONTROLE NEGATIVO de cobertura: sem passo amostrado não há linha. Emitir zeros
	# aqui seria um verde fabricado por quem scrapeia.
	CheckEq(_lines(_state(BudgetUs)), "",
			"estado sem nenhum passo renderiza VAZIO (indisponível não é `0 passos, 0 ms` — é ausência visível no scrape)")

	var state : Dictionary = _state(BudgetUs)
	for sample in [[5000, 5000], [8000, 20000], [30000, 34000], [4000, 34333], [70000, 60000], [130000, 120000]]:
		_record(state, int(sample[0]), int(sample[1]), 0)
	var body : String = _lines(state)
	Check(body.contains("# TYPE shambleta_step_period_seconds histogram"),
			"o período do passo sai como histograma (com TYPE declarado, senão o Prometheus recorta a série)")
	Check(body.contains("# TYPE shambleta_step_work_seconds histogram"),
			"o trabalho do passo sai como histograma")
	for required in ["shambleta_step_over_budget_total 2", "shambleta_steps_measured_total 6",
			"shambleta_step_lost_total 0", "shambleta_step_budget_seconds 0.033333",
			"shambleta_step_budget_tolerance_seconds 0.001000",
			"shambleta_step_period_seconds_sum 0.273333", "shambleta_step_period_seconds_count 6",
			"shambleta_step_period_seconds_max 0.120000",
			"shambleta_step_work_seconds_count 6"]:
		Check(body.contains(required), "a linha `%s` está no corpo" % required)
	# Um histograma só é histograma se os baldes forem crescentes e o `+Inf` for a
	# contagem. É a classe de defeito que faz a cauda sumir sem ninguém perceber.
	for prefix in ["shambleta_step_period_seconds", "shambleta_step_work_seconds"]:
		var previous : int = -1
		var monotone : bool = true
		var infCount : int = -1
		var bucketCount : int = 0
		for line in body.split("\n"):
			var text : String = String(line)
			if not text.begins_with(prefix + "_bucket{le=\""):
				continue
			var value : int = int(text.get_slice(" ", 1))
			bucketCount += 1
			if text.contains("le=\"+Inf\""):
				infCount = value
			elif value < previous:
				monotone = false
			previous = value
		Check(monotone, "%s: baldes monótonos crescentes (%d lidos)" % [prefix, bucketCount])
		CheckEq(infCount, 6, "%s: o balde +Inf é a contagem de passos" % prefix)
		Check(bucketCount >= 5, "%s: há bucket nas faixas do orçamento, não só +Inf" % prefix)

# ------------------------------------------------------------------ 3. o alerta

func _checkAlertNames() -> void:
	print("-- perna 3: toda métrica citada por alerta é métrica que o servidor serve --")
	var alerts : String = _read(AlertsPath)
	var metrics : String = _read(MetricsPath)
	if not Check(not alerts.is_empty() and not metrics.is_empty(),
			"deploy/alerts.rules.yml e sources/system/MetricsServer.gd foram lidos"):
		return
	var emitRe : RegEx = RegEx.create_from_string(EmitNameRegex)
	var refRe : RegEx = RegEx.create_from_string(RefNameRegex)
	for m in emitRe.search_all(metrics):
		emittedNames[String(m.get_string(1))] = true
	Check(emittedNames.size() >= 8, "o /metrics emite %d séries nomeadas no predícado da casa" % emittedNames.size())
	var referenced : Dictionary = {}
	for r in refRe.search_all(alerts):
		referenced[String(r.get_string(1))] = true
	Check(referenced.has("shambleta_step_over_budget_total"),
			"existe regra de passo acima do orçamento (a grandeza virou alerta, não só número)")
	Check(referenced.has("shambleta_step_lost_total"),
			"existe regra de passo perdido (o déficit de tick também virou alerta)")
	Check(referenced.has("shambleta_steps_measured_total"),
			"a regra de fração cita o denominador medido, em vez de contar estouro absoluto")
	var missing : Array = []
	for name in referenced:
		if not emittedNames.has(name):
			missing.append(name)
	CheckEq(missing, [], "nenhum nome citado em alerta é nome que o servidor não serve (a regex de nome da casa é literal, então balde rotulado por formato não pode ser citado)")
	# O controle negativo desta perna: o predícado acima tem que morder um nome que
	# ninguém emite. Sem isto, `missing == []` poderia ser verde porque o extrator
	# não extrai nada.
	var planted : Dictionary = {}
	for m in refRe.search_all("expr: " + PlantedMissingName + "[5m] > 0"):
		planted[String(m.get_string(1))] = true
	CheckEq(planted.size(), 1, "o extrator de nomes vê um nome plantado numa regra sintética")
	Check(not emittedNames.has(PlantedMissingName),
			"e o predícado morde: o nome plantado %s não está entre os emitidos, ou seja seria reprovado acima" % PlantedMissingName)
	# E a ponta forte: o corpo RENDERIZADO contém os nomes que a regra cita. A regex
	# de fonte confere o literal; isto confere o que sai do processo.
	var state : Dictionary = _state(BudgetUs)
	for sample in [[5000, 5000], [70000, 60000]]:
		_record(state, int(sample[0]), int(sample[1]), 1)
	var body : String = _lines(state)
	for name in ["shambleta_step_over_budget_total", "shambleta_steps_measured_total",
			"shambleta_step_lost_total", "shambleta_step_budget_seconds",
			"shambleta_step_budget_tolerance_seconds"]:
		Check(body.contains(name + " "), "o corpo servido contém a série `%s` que o alerta lê" % name)

# ------------------------------------------------------------------ 4. parede

func _checkLiveSteps() -> void:
	print("-- perna 4: passos reais deste processo alimentam o acumulador --")
	if not Check(launcher != null, "Launcher autoload presente (é ele o laço que cronometra)"):
		return
	# O `_ready` do autoload roda depois do `_initialize` deste harness (o boot do
	# Launcher leva ~1,4 s carregando cena): sem esperar aqui, o primeiro snapshot lê
	# um dicionário vazio. Foi o que esta perna apanhou na primeira versão do arquivo
	# — `Invalid access to property or key 'steps'`, com o RESULT já impresso.
	var waited : int = 0
	var installed : Dictionary = launcher.get("stepBudget")
	while installed.is_empty() and waited < BootWaitMs:
		await create_timer(0.2).timeout
		waited += 200
		installed = launcher.get("stepBudget")
	if not Check(not installed.is_empty(),
			"Launcher._ready instalou o acumulador de passo (%d ms de espera pelo boot)" % waited):
		return
	var before : Dictionary = _snapshot()
	var burn : Node = Burn.new()
	burn.name = "StepBudgetBurn"
	root.add_child(burn)
	await _frames(WarmupFrames)
	var idleBefore : Dictionary = _snapshot()
	var idleSteps : int = int(idleBefore["steps"]) - int(before["steps"])
	Check(idleSteps >= WarmupFrames - 4,
			"%d passos reais amostrados em %d fronteiras de física — o acumulador está LIGADO no laço, não é função órfã" % [
				idleSteps, WarmupFrames])
	# O número do piso é impresso, não cobrado: "nenhum passo ocioso estourou" é uma
	# régua de máquina, e num host com outros agentes correndo o vizinho infla o
	# período de parede. O predícado de estouro em si é conferido sem máquina nenhuma
	# na perna 1 (sequência toda dentro de orçamento devolve `overBudget == 0`), que é
	# onde ele morde se regredir.
	Note("passos acima de orçamento+folga na janela de piso (sem queima): %d em %d" % [
			int(idleBefore["overBudget"]) - int(before["overBudget"]), idleSteps])
	burn.set("us", BurnUs)
	await _frames(BurnSteps + WarmupFrames)
	var burned : Dictionary = _snapshot()
	var burnSteps : int = int(burned["steps"]) - int(idleBefore["steps"])
	var overDelta : int = int(burned["overBudget"]) - int(idleBefore["overBudget"])
	var maxDeltaUs : int = int(burned["periodMaxUs"])
	Check(burn.get("steps") >= BurnSteps / 2, "a queima rodou de verdade (%d passos com %d ms/passo)" % [
			int(burn.get("steps")), BurnUs / 1000])
	# 0,5 é piso conservador pelo motivo declarado no HELP do exportador: quando o
	# engine recupera atraso rodando dois passos seguidos, a fronteira entre eles lê
	# curta e não conta como estouro — a fração real medida deste processo no burn é
	# impressa abaixo. Ruído de vizinho só pode AUMENTAR o período lido, nunca
	# diminuir, então um piso desta conta sobrevive à máquina ocupada na direção certa.
	Check(float(overDelta) >= float(burnSteps) * 0.5,
			"%d ms/passo queimados levaram %d dos %d passos seguintes acima de orçamento+folga (piso %d) — o detector de estouro exportado enxerga a queima" % [
				BurnUs / 1000, overDelta, burnSteps, int(float(burnSteps) * 0.5)])
	Check(maxDeltaUs >= BurnUs * 9 / 10,
			"e o pior passo amostrado (%.1f ms) reconhece a queima de %d ms" % [
				float(maxDeltaUs) / 1000.0, BurnUs / 1000])
	var buckets : Array = burned.get("periodBuckets", [])
	Check(buckets.size() == 4 and int(buckets[3]) >= burnSteps / 2,
			"os baldes se moveram com a queima: le=0.1 acumulou %s passos (era %s)" % [
				str(buckets[3] if buckets.size() == 4 else -1), str(int(idleBefore.get("periodBuckets", [0, 0, 0, 0])[3]))])
	burn.set("us", 0)
	root.remove_child(burn)
	burn.free()

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _initialize() -> void:
	_run()

func _run() -> void:
	print("== orçamento de passo: instrumento, exportador e alerta na mesma ponta ==")
	launcherScript = load(LauncherPath)
	metricsScript = load(MetricsPath)
	var commonsScript : GDScript = load(CommonsPath)
	launcher = root.get_node_or_null(NodePath("Launcher"))
	if not Check(launcherScript != null and metricsScript != null and commonsScript != null,
			"%s, %s e %s carregados" % [LauncherPath, MetricsPath, CommonsPath]):
		_finish()
		return
	var fps : int = int(commonsScript.get("ServerMaxFPS"))
	CheckEq(fps, ServerFps, "ServerMaxFPS = %d (o orçamento que a régua exporta é 1000/%d = %s ms)" % [
			fps, fps, "%.2f" % (1000.0 / float(fps))])
	Engine.set_max_fps(fps)
	Engine.set_physics_ticks_per_second(fps)
	CheckEq(int(Engine.get_physics_ticks_per_second()), ServerFps,
			"tick deste harness == tick de produção (%d Hz), então os passos reais abaixo são da mesma grandeza que o /metrics serve" % ServerFps)
	_checkRecorder()
	_checkRenderer()
	_checkAlertNames()
	# É corrotina (tem `await` dentro): chamar sem `await` entregaria o controle de
	# volta ao `_run` no primeiro frame, o RESULT seria impresso e o processo quitaria
	# antes de qualquer passo real ser contado — a perna mais importante do arquivo
	# virando silêncio verde.
	await _checkLiveSteps()
	await _finish()
