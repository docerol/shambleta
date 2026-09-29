extends RefCounted
class_name LauncherCommons

# Project
const ProjectName : String				= "Shambleta"

# Map
static var DefaultStartMapID : int		= "Tulimshar".hash()
const DefaultStartPos : Vector2i		= Vector2i(2176, 2560) # Tile (68, 80)
const DefaultStartOffset : Vector2i		= Vector2i(64, 32)

static func GetRandomStartPos() -> Vector2i:
	return DefaultStartPos + Vector2i(randi_range(-DefaultStartOffset.x, DefaultStartOffset.x), randi_range(-DefaultStartOffset.y, DefaultStartOffset.y))

# MapPool
const EnableMapPool : bool				= false
const MapPoolMaxSize : int				= 10

const ServerMaxFPS : int				= 30

# Common accessors
# Modo de lançamento. TESTING é o default (editor, debug, testes, QA).
# PRODUÇÃO só quando o build declara explicitamente: feature tag "production"
# no preset de export (Web e Headless Server) e/ou SHAMBLETA_PRODUCTION=1 no
# ambiente. Isso decide DB (live.db vs testing.db), porta de bind e endpoint do
# client — ver SQLCommons.GetDBPath e NetworkCommons. A env só LIGA produção;
# nunca desliga (esquecer a tag cai no modo seguro, não no perigoso).
static func ResolveIsTesting(hasProductionFeature : bool, productionEnv : String) -> bool:
	return not (hasProductionFeature or productionEnv.strip_edges() == "1")

static var IsTesting : bool				= ResolveIsTesting(OS.has_feature("production"), OS.get_environment("SHAMBLETA_PRODUCTION"))
static var isMobile : bool				= OS.has_feature("android") or OS.has_feature("ios") or Util.IsMobile()
static var isWeb : bool					= OS.has_feature("web")

# O serviço de debug está vivo? É a mesma pergunta que `if Launcher.Debug:` fazia,
# respondida sem escrever o identificador `Launcher` no fonte de um utilitário.
#
# Por que isso importa e não é preciosismo: `Launcher` é autoload, e o identificador
# de autoload só existe para o compilador depois que ele se registra. `Util` é
# chamado da cadeia `Conf` → `FileSystem`, que num `godot -s` pode ser compilada
# ANTES disso — e aí o que se recebe não é um null defensável, é
# `SCRIPT ERROR: Compile Error: Identifier not found: Launcher`, que derruba a
# classe inteira e leva `PrintLog`/`PrintInfo` junto. Medido: foi exatamente isso
# que fez `FileSystem.LoadConfig("settings")` devolver null num harness e o
# `Conf.Type.SETTINGS` ficar inutilizável para o processo inteiro.
#
# A fonte da verdade continua sendo o nó (Launcher.Reset() liberta o serviço e zera
# o field, e é isso que esta função lê), então não há flag paralelo para manter em
# dia — e a resposta é a mesma com ou sem autoload registrado.
static func DebugServiceLive() -> bool:
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var launcher : Node = tree.root.get_node_or_null(NodePath("Launcher"))
	return launcher != null and launcher.get("Debug") != null

# SOM-IDLE idle-first: o beta é um idle auto battler — diálogos/quests de NPC
# ficam desligados (tudo o que dispara script de NPC passa por PlayerAgent.
# AddScript). O mundo de aventura segue no build como hub visual; ligar isto
# devolve o MMORPG clássico para modo dev.
static var IdleMode : bool				= true
