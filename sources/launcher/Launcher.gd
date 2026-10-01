extends Node

# Common singletons
var Root : Node						= null
var Scene : Node2D					= null

# Client services
var Action : ServiceBase			= null
var Audio : AudioStreamPlayer		= null
var GUI : ServiceBase				= null
var Debug : ServiceBase				= null
var Camera : ServiceBase			= null
var Map : ServiceBase				= null

# Server services
var World : ServiceBase				= null
var SQL : ServiceBase				= null
var Email : EmailService			= null
# SOM-IDLE: F2 — economy/settle service (settle-path ledger writes)
var Economy : EconomyService		= null
var Telemetry : TelemetryService	= null
# SOM-IDLE L1: /healthz + /metrics do server (loopback 9400). O healthcheck do
# compose e o `depends_on: service_healthy` do `web` dependem deste processo
# escutar — sem ele a stack do beta nunca fica healthy.
var Metrics : MetricsServer			= null

# Accessors
var Player : Entity					= null

# O modo como o processo nasceu, registrado em `_ready`. É o estado para o qual se
# volta quando a conexão com o servidor remoto cai: hardcodar `Mode(true, true)` no
# teardown do cliente ligava um servidor que o boot nunca ligou — no browser isso
# tentava bind TCP em 127.0.0.1:9400 (`ERR_CANT_CREATE`, medido 2026-09-25) e
# re-entrava `DB.Init`; num desktop de release criava World/SQL/Email/
# Economy/Telemetry que ninguém pediu. Em dev o boot já é client+server, então o
# comportamento medido até aqui não muda.
var BootClient : bool				= false
var BootServer : bool				= false

# Signals
signal launchModeUpdated
signal dbInitialized

# ------------------------------------------------------------------ orçamento de passo
#
# O processo do server é um laço de física a `LauncherCommons.ServerMaxFPS` Hz e até
# aqui nada nele confessava o custo do passo: `/metrics` media espera de mutex
# (sources/sql/SQL.gd) e o único lugar que lia `Performance.TIME_PHYSICS_PROCESS`
# era o painel humano de `sources/gui/ServerDisplay.gd`. Um servidor que perde o
# tick de 30 Hz em TODOS os passos não tem para onde apontar o alerta porque a
# grandeza não existe fora do processo. Estas linhas medem no próprio laço, com
# `Time.get_ticks_usec()`, e `sources/system/MetricsServer.gd` exporta.
#
# Duas grandezas, porque a casa não aceita média sozinha (uma média de 8 ms esconde
# um passo de 120 ms que congelou o jogador):
#   * HISTOGRAMA (buckets cumulativos nas faixas do orçamento) — a forma da cauda;
#   * CONTADORES de estouro e de passo perdido — o que a regra de alerta lê.
#
# Cobertura declarada (a casa trata "indisponível" diferente de zero):
#   * `period*` é o tempo de PAREDE entre duas fronteiras do laço de física deste
#     processo — orçamento + sono do throttle. É a grandeza que responde "o tick de
#     30 Hz foi cumprido": vale sempre, inclusive com zero players.
#   * `work*` é o DESPACHO do passo: `Time.get_ticks_usec()` na fronteira de física e
#     no primeiro callback ocioso da mesma iteração. Diferente do período, não cresce
#     com o sono do throttle — é a grandeza que o predícado de estouro lê. Cobre o
#     despacho inteiro do processo, não o pump das instâncias: `BaseAgent`,
#     PhysicsServer2D, navegação e o resto do `_ready` de node estão dentro; a
#     contagem era por instância e veria só uma fração do passo.
#   * Ponto cego do despacho, declarado: num passo engolido por catch-up (duas
#     fronteiras de física numa iteração) o callback ocioso nunca corre para ele e ele
#     registra 0 µs — trabalho NÃO MEDIDO, não trabalho zero. Por isso o contador de
#     estouro subestima a fração sob catch-up, no máximo pela razão de catch-up (o
#     segundo flush tem custo de um flush inteiro, não é dividido). O déficit em si é
#     confessado por `lost`, que lê `Engine.get_physics_frames()` contra a parede.
#   * Janela: do boot do processo até agora, sem reset. O processo reiniciando os
#     contadores voltam a zero, que é a semântica de counter do Prometheus.

# Boundas dos buckets em µs: 16,67 (meio orçamento — o passo de um render a 60 Hz),
# 33,33 (o orçamento de 30 Hz), 50 e 100. São faixas do orçamento, não uma escala
# logarítmica: quem olha a cauda quer saber "quantos passos não couberam no tick",
# e o degrau depois dele é "quanto tempo o jogador ficou sem passo".
const StepBucketUs : Array[int] = [16667, 33333, 50000, 100000]
# Folga do predícado de estouro, em µs. O que ela compra mudou de nome em 2026-10-01,
# quando o predícado passou a ler o DESPACHO (ver `StepBudgetRecord`) e não mais o
# período: antes, esta constante era o pedágio do throttle — medido, o piso de um
# processo sem nenhum player entrega 33,61 ms de período contra 33,33 ms de orçamento,
# então um predícado estrito `>` sobre o período denunciava 100% dos passos de um
# servidor ocioso e o alerta deixava de significar nada. O sleep não entra mais na
# janela medida, e o que a folga cobre é o que sobra dentro dela e não é trabalho deste
# processo: preempção do scheduler e GC. O valor continua 1000 µs porque é a mesma
# `PeriodToleranceMs` do `tests/multi_instance_tick_test.gd`, cuja folga foi medida no
# `tests/tick_capacity_test.gd`, e a perna de mesa de `tests/step_budget_metric_test.gd`
# confere as duas pontas: com o predícado sobre o período, uma sequência ociosa estoura;
# sobre o despacho, não.
const StepBudgetToleranceUs : int = 1000

var stepBudget : Dictionary = {}

# Estado do acumulador. Puro e de uma página só de propósito: é o mesmo dicionário
# que `tests/step_budget_metric_test.gd` alimenta com passos sintéticos para
# conferir o balde, o predícado de estouro e o atraso, sem depender de máquina.
static func StepBudgetNew(budgetUs : int) -> Dictionary:
	return {
		"budgetUs": budgetUs,
		"bucketUs": StepBucketUs.duplicate(),
		"toleranceUs": StepBudgetToleranceUs,
		"steps": 0,
		"workSumUs": 0, "workMaxUs": 0, "workBuckets": [0, 0, 0, 0],
		"periodSumUs": 0, "periodMaxUs": 0, "periodBuckets": [0, 0, 0, 0],
		"overBudget": 0,
		"lost": 0,
		# O despacho do passo em curso: aberto na fronteira de física, fechado no primeiro
		# callback ocioso da MESMA iteração. `braceFrame` vai a -1 quando o passo já foi
		# fechado, e é isso que impede um `_process` de iteração sem passo de física (o
		# cliente a 60 Hz) de medir o sleep da iteração anterior como trabalho.
		"braceOpenUs": 0, "braceFrame": -1, "braceWorkUs": 0,
		"lastUs": 0, "lastFrame": 0, "startUs": 0, "startFrame": 0,
		"started": false,
	}

# Registra um passo. Bucket cumulativo (`le`): um passo entra em TODOS os baldes
# cuja bounda é >= ele — é o que faz `histogram_quantile` funcionar e é exatamente
# onde um histograma mal escrito vira "a cauda sumiu". `driftSteps` é o atraso
# acumulado em passos que o engine não entregou (contado por `Engine.get_physics_frames()`
# contra o tempo de parede), e entra como MÁXIMO: um counter que desce é uma
# grandeza que ninguém consegue interpretar numa janela `rate()`.
#
# O predícado de estouro lê `workUs`, e `workUs` é a janela do DESPACHO — não o período.
# Medido com sonda isolada nesta máquina: com o processo ocioso o período entre
# fronteiras é 33,3–33,6 ms enquanto a janela física→ocioso é 1,4–1,8 ms; com 20 ms
# queimados num node dentro de um `SubViewport` a janela vai a 20,16 ms e o período
# continua 33,3 ms. Ou seja: o período é orçamento + sono, e cobrar estouro por ele é
# paginação pela latência de wake do kernel — 8,3% dos passos de um degrau com 9 ms de
# trabalho estouravam `orçamento + folga` no runner da CI sem que nenhum jogador perdesse
# um passo. O trabalho do despacho é a grandeza que sobe quando o mundo não cabe, e a
# mesma em qualquer máquina.
static func StepBudgetRecord(state : Dictionary, workUs : int, periodUs : int, driftSteps : int) -> void:
	state["steps"] = int(state["steps"]) + 1
	state["workSumUs"] = int(state["workSumUs"]) + workUs
	state["periodSumUs"] = int(state["periodSumUs"]) + periodUs
	state["workMaxUs"] = maxi(int(state["workMaxUs"]), workUs)
	state["periodMaxUs"] = maxi(int(state["periodMaxUs"]), periodUs)
	for bucket in StepBucketUs.size():
		if workUs <= StepBucketUs[bucket]:
			state["workBuckets"][bucket] = int(state["workBuckets"][bucket]) + 1
		if periodUs <= StepBucketUs[bucket]:
			state["periodBuckets"][bucket] = int(state["periodBuckets"][bucket]) + 1
	if workUs > int(state["budgetUs"]) + int(state["toleranceUs"]):
		state["overBudget"] = int(state["overBudget"]) + 1
	state["lost"] = maxi(int(state["lost"]), driftSteps)

# Uma fronteira do laço de física. O trabalho da janela anterior já está fechado no
# acumulador quando este corre: é `braceWorkUs`, medido entre a fronteira passada e o
# primeiro callback ocioso daquela iteração.
func _physics_process(_delta : float) -> void:
	var now : int = Time.get_ticks_usec()
	var frame : int = int(Engine.get_physics_frames())
	if not bool(stepBudget["started"]):
		stepBudget["started"] = true
		stepBudget["lastUs"] = now
		stepBudget["lastFrame"] = frame
		stepBudget["startUs"] = now
		stepBudget["startFrame"] = frame
		stepBudget["braceOpenUs"] = now
		stepBudget["braceFrame"] = frame
		return
	var periodUs : int = now - int(stepBudget["lastUs"])
	var budgetUs : int = int(stepBudget["budgetUs"])
	var expectedSteps : int = int(now - int(stepBudget["startUs"])) / maxi(budgetUs, 1)
	var deliveredSteps : int = frame - int(stepBudget["startFrame"])
	# `braceFrame < 0` é o atestado de que o passo que está fechando agora foi de fato
	# fechado por um `_process`. Num passo engolido por catch-up (dois despachos de física
	# numa iteração) o closer nunca corre para ele, e o que ele registra é 0 µs — trabalho
	# NÃO MEDIDO, não trabalho emprestado do passo anterior.
	var braceUs : int = int(stepBudget["braceWorkUs"]) if int(stepBudget["braceFrame"]) < 0 else 0
	StepBudgetRecord(stepBudget, braceUs, periodUs, maxi(0, expectedSteps - deliveredSteps))
	stepBudget["braceOpenUs"] = now
	stepBudget["braceFrame"] = frame
	stepBudget["braceWorkUs"] = 0
	stepBudget["lastUs"] = now
	stepBudget["lastFrame"] = frame

# Fecha a janela do despacho. O `_process` do mesmo node roda depois de TODOS os
# `_physics_process` da iteração, então `agora - braceOpenUs` é o trabalho do passo sem
# o sono do throttle dentro — que é justamente a grandeza que o predícado de estouro
# precisa. A hipótese de que o bracket contém o trabalho de um `SubViewport` (é onde
# mora a `WorldInstance`) foi conferida por sonda isolada nesta máquina em 2026-10-01:
# 20 ms queimados num node filho de um `SubViewport` apareceram no bracket (20,16 ms,
# contido em 59 de 59 pares) sem mexer no período (33,3 ms). A régua que confere isto
# hoje é a perna de contenção de `tests/multi_instance_tick_test.gd`.
func _process(_delta : float) -> void:
	if int(stepBudget["braceFrame"]) != int(Engine.get_physics_frames()):
		return
	stepBudget["braceFrame"] = -1
	stepBudget["braceWorkUs"] = Time.get_ticks_usec() - int(stepBudget["braceOpenUs"])

func StepBudgetSnapshot() -> Dictionary:
	return stepBudget.duplicate(true)

#
func Mode(launchClient : bool = false, launchServer : bool = false) -> bool:
	var isClientConnected : bool = Network.Client != null
	var isServerConnected : bool = Network.ENetServer != null or Network.WebSocketServer != null
	if isClientConnected == launchClient and isServerConnected == launchServer:
		return false

	Launcher.Reset(false, false)
	Network.Destroy()
	if launchClient:	Client()
	if launchServer:	Server()
	Network.Mode(launchClient, launchServer)

	DB.Init()
	_post_launch()
	launchModeUpdated.emit(launchClient, launchServer)
	return true

func Client():
	if OS.is_debug_build():
		Debug		= DebugService.new()

	# Load then low-prio services on which the order is not important
	Action			= ActionService.new()
	Camera			= CameraService.new()
	Map				= MapService.new()

	add_child.call_deferred(Action)

func Server():
	World			= WorldService.new()
	SQL				= SQLService.new()
	Email			= EmailService.new()
	# SOM-IDLE: F2 — economy service lives with the other server services
	Economy			= EconomyService.new()
	Telemetry		= TelemetryService.new()
	# SOM-IDLE L1: bind imediato, antes das migrations. É isso que permite ao
	# healthcheck distinguir "booting" (503) de "processo morto" (conexão
	# recusada); IsServing() é avaliado por requisição, não por aqui.
	Metrics			= MetricsServer.new()

	add_child.call_deferred(World)
	add_child.call_deferred(SQL)
	add_child.call_deferred(Email)
	add_child.call_deferred(Economy)
	add_child.call_deferred(Telemetry)
	add_child.call_deferred(Metrics)
	Metrics.Launch()

func Reset(clientStarted : bool, serverStarted : bool):
	if not clientStarted:
		# Debug/Camera/Map nunca entram na árvore (só `Action` é add_child'ado em
		# Client()), e queue_free() em nó fora da árvore é no-op silencioso — a
		# instância ficava viva para sempre. free() é o que libera um Node órfão.
		# Action fica com queue_free() porque ESTÁ na árvore (free() ali seria
		# freeing during notification).
		if Debug:
			Debug.Destroy()
			Debug.free()
			Debug = null
		if Action:
			Action.set_name("ActionDestroyed")
			Action.Destroy()
			Action.queue_free()
			Action = null
		if Camera:
			Camera.Destroy()
			Camera.free()
			Camera = null
		if Map:
			Map.Destroy()
			Map.free()
			Map = null
		if GUI:
			GUI.Destroy()
			# GUI is not cleared, but all signals should be re-connected
		if Network.Client:
			Network.Client.Destroy()
			Network.Client = null
		if Player:
			Player.queue_free()
			Player = null

	if not serverStarted:
		if Network.ENetServer:
			Network.ENetServer.Destroy()
			Network.ENetServer = null
		if Network.WebSocketServer:
			Network.WebSocketServer.Destroy()
			Network.WebSocketServer = null
		if World:
			World.set_name("WorldDestroyed")
			World.Destroy()
			World.queue_free()
			World = null
		if SQL:
			SQL.set_name("SQLDestroyed")
			SQL.Destroy()
			SQL.queue_free()
			SQL = null
		if Email:
			Email.queue_free()
			Email = null
		# SOM-IDLE: F2
		if Economy:
			Economy.set_name("EconomyDestroyed")
			Economy.Destroy()
			Economy.queue_free()
			Economy = null
		if Telemetry:
			Telemetry.set_name("TelemetryDestroyed")
			Telemetry.Destroy()
			Telemetry.queue_free()
			Telemetry = null
		# SOM-IDLE L1: Destroy() faz listener.stop() na hora, então um Mode() que
		# recria o server re-binda a 9400 sem esperar o free adiado.
		if Metrics:
			Metrics.set_name("MetricsDestroyed")
			Metrics.Destroy()
			Metrics.queue_free()
			Metrics = null

func Quit():
	Reset(false, false)
	Network.Destroy()
	Root.remove_child(Scene)
	Scene.free()
	Network.queue_free()
	get_tree().quit()

#
func _ready():
	var startClient : bool = false
	var startServer : bool = false

	Root = get_tree().get_root()

	# O orçamento de passo é o do processo, lido da mesma constante que o `--server`
	# aplica no tick logo abaixo — se `ServerMaxFPS` mudar, o histograma e a régua
	# mudam junto, sem ninguém re-digitar 33,33.
	stepBudget = StepBudgetNew(1000000 / maxi(LauncherCommons.ServerMaxFPS, 1))

	Conf.Init()

	# SOM-IDLE beta deploy: endpoint público vindo do conf [Network] (baked no
	# build web — settings.cfg embarca no pck; deploy Coolify grava via ARG).
	var confAddress : String = Conf.GetString("Network", "Server-Address", Conf.Type.SETTINGS)
	if not confAddress.is_empty():
		NetworkCommons.ServerAddress = confAddress
	var confPort : int = Conf.GetInt("Network", "Server-Port", Conf.Type.SETTINGS)
	if confPort > 0:
		NetworkCommons.WebSocketPort = confPort
	# Base do companion (webhook/checkout). No web a resposta é a origem da própria
	# página: o nginx do serviço `web` faz proxy de /checkout/ e /webhooks/ para o
	# companion na rede interna, então o client nunca precisa conhecer outro
	# hostname (e não há CORS nem mixed content no caminho do dinheiro).
	var pageOrigin : String = ""
	if LauncherCommons.isWeb:
		pageOrigin = str(JavaScriptBridge.eval("window.location.origin", true))
	NetworkCommons.CompanionURL = NetworkCommons.ResolveCompanionURL(
		OS.get_environment("SHAMBLETA_COMPANION_URL"),
		Conf.GetString("Network", "Companion-Base", Conf.Type.SETTINGS), pageOrigin)

	if "--server" in OS.get_cmdline_args():
		Scene = FileSystem.LoadResource(Path.Pst + "Server" + Path.SceneExt)
		Root.add_child.call_deferred(Scene)
		Engine.set_max_fps(LauncherCommons.ServerMaxFPS)
		Engine.set_physics_ticks_per_second(LauncherCommons.ServerMaxFPS)
		startServer = true
	else:
		Scene = FileSystem.LoadResource(Path.Pst + "Client" + Path.SceneExt)
		Root.add_child.call_deferred(Scene)
		GUI = Scene.get_node("Canvas")
		Audio = Scene.get_node("Audio")
		startClient = true
		startServer = not LauncherCommons.isWeb and OS.is_debug_build() and not NetworkCommons.IsLocal

	if not Root or not Scene:
		printerr("Could not initialize source's base services")
		Quit()

	BootClient = startClient
	BootServer = startServer
	Mode(startClient, startServer)
	await Scene.ready

	_post_launch()

# Call _post_launch functions for service depending on other services
func _post_launch():
	if Camera and not Camera.isInitialized:		Camera._post_launch()
	if Map and not Map.isInitialized:			Map._post_launch()
	if GUI and not GUI.isInitialized:			GUI._post_launch()
	if Debug and not Debug.isInitialized:		Debug._post_launch()
	if World and not World.isInitialized:		World._post_launch()
	if SQL and not SQL.isInitialized:			SQL._post_launch()
	if Audio:									Audio._post_launch()
	# SOM-IDLE: F2 — economy service after SQL (it only wraps SQL calls)
	if Economy and not Economy.isInitialized:	Economy._post_launch()
	# SOM-IDLE: D2 — telemetry after SQL
	if Telemetry and not Telemetry.isInitialized:	Telemetry._post_launch()
	# OPS-1/OPS-2 (AUDITORIA_2026-09-27 §15): flags de runtime e a superfície
	# admin `/flags`, depois de SQL (lê a tabela da migration 053) e de Telemetria
	# (o comando grava auditoria em `telemetry_event`). É chamada estático, sem
	# serviço novo na árvore: `FeatureFlags` é estado por processo e o gate precisa
	# rodar no mesmo processo que serve a feature. Idempotente — `Mode()` re-entra
	# aqui a cada troca de client/server.
	FlagsBootstrap.Install()
	# SOM-IDLE F3: web push after GUI
	if LauncherCommons.isWeb:
		WebPushService.Initialize()

func _quit():
	Quit()

func _exit_tree():
	# SOM-IDLE A2: quit() landing during the DB preload used to segfault the
	# engine — the threaded loads were still parsing while teardown freed the
	# script cache under them. Last hook that still runs on a live tree.
	DB.DrainPendingPreloads()
