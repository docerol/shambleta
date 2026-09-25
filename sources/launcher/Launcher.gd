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
var Discord : DiscordService		= null
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
# re-entrava `DB.Init`; num desktop de release criava World/SQL/Discord/Email/
# Economy/Telemetry que ninguém pediu. Em dev o boot já é client+server, então o
# comportamento medido até aqui não muda.
var BootClient : bool				= false
var BootServer : bool				= false

# Signals
signal launchModeUpdated
signal dbInitialized

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
	Discord			= DiscordService.new()
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
	add_child.call_deferred(Discord)
	add_child.call_deferred(Email)
	add_child.call_deferred(Economy)
	add_child.call_deferred(Telemetry)
	add_child.call_deferred(Metrics)
	Metrics.Launch()

func Reset(clientStarted : bool, serverStarted : bool):
	if not clientStarted:
		if Debug:
			Debug.Destroy()
			Debug.queue_free()
			Debug = null
		if Action:
			Action.set_name("ActionDestroyed")
			Action.Destroy()
			Action.queue_free()
			Action = null
		if Camera:
			Camera.Destroy()
			Camera.queue_free()
			Camera = null
		if Map:
			Map.Destroy()
			Map.queue_free()
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
		if Discord:
			Discord.set_name("DiscordDestroyed")
			Discord.Destroy()
			Discord.queue_free()
			Discord = null
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
	if Discord and not Discord.isInitialized:	Discord._post_launch()
	if Audio:									Audio._post_launch()
	# SOM-IDLE: F2 — economy service after SQL (it only wraps SQL calls)
	if Economy and not Economy.isInitialized:	Economy._post_launch()
	# SOM-IDLE: D2 — telemetry after SQL
	if Telemetry and not Telemetry.isInitialized:	Telemetry._post_launch()
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
