extends RefCounted
class_name DB

#
static var isInitialized : bool								= false
static var preloadPaths : PackedStringArray					= []

static var MapsDB : Dictionary[int, MapData]				= {}
static var MusicDB : Dictionary[int, FileData]				= {}
static var RacesDB : Dictionary[int, RaceData]				= {}
static var HairstylesDB : Dictionary[int, HairstyleData]	= {}
static var PalettesDB : Array[Dictionary]					= []
static var EntitiesDB : Dictionary[int, EntityData]			= {}
static var EmotesDB : Dictionary[int, BaseCell]				= {}
static var ItemsDB : Dictionary[int, ItemCell]				= {}
static var SkillsDB : Dictionary[int, SkillCell]			= {}
static var QuestsDB : Dictionary[int, QuestData]			= {}

static var hashDB : Dictionary								= {}
const UnknownHash : int										= -1
static var PlayerHash : int									= "Player".hash()
static var ShipHash : int									= "Ship".hash()

enum Palette
{
	HAIR = 0,
	SKIN,
	EQUIPMENT,
	COUNT
}

#
static func ParseFileDB(db : Dictionary, path : String):
	for resourcePath in FileSystem.ParseResources(path):
		var data : FileData = FileSystem.LoadResource(resourcePath, false)
		data._id = SetCellHash(data._name, data._id)
		if data._id != UnknownHash:
			db[data._id] = data

static func ParseRacesDB():
	for resourcePath in FileSystem.ParseResources(Path.RacesPst):
		var data : RaceData = FileSystem.LoadResource(resourcePath, false)
		var id : int = SetCellHash(data.name)
		if id != UnknownHash:
			RacesDB[id] = data

static func ParseEntitiesDB():
	for resourcePath in FileSystem.ParseResources(Path.EntityPst):
		var resource = FileSystem.LoadResource(resourcePath, false)
		if resource is EntityData:
			var entity : EntityData = resource as EntityData
			if entity._id != entity._name.hash():
				push_error("ID for entity %s is not set, add: %d" % [entity._name, entity._name.hash()])
				return
			if entity._parent:
				entity = entity.GetMergedEntity()

			entity._questID = entity._quest.id if entity._quest else UnknownHash

			for statStr in EntityData.hashedStats:
				if entity._stats.has(statStr):
					var value = entity._stats[statStr]
					if value is String:
						entity._stats[statStr] = value.hash()

			if entity._stats.has("gender") and entity._stats["gender"] is String:
				entity._stats["gender"] = ActorCommons.GetGenderID(entity._stats["gender"])

			if entity._id != UnknownHash:
				if EntitiesDB.has(entity._id):
					push_error("Duplicated entity in EntitiesDB: " + entity._name)
					return
				EntitiesDB[entity._id] = entity

static func ParseCellDB(db : Dictionary, path : String):
	for resourcePath in FileSystem.ParseResources(path):
		var cell : BaseCell = FileSystem.LoadResource(resourcePath, false)
		cell.id = SetCellHash(cell.name)
		if cell.id != UnknownHash:
			db[cell.id] = cell

static func ParseQuestsDB():
	for resourcePath in FileSystem.ParseResources(Path.QuestPst):
		var quest : QuestData = FileSystem.LoadResource(resourcePath, false)
		quest.id = SetCellHash(quest.name)
		if quest.id != UnknownHash:
			QuestsDB[quest.id] = quest

#
static func HasCellHash(cellname : StringName) -> bool:
	return hashDB.has(cellname)

static func SetCellHash(cellname : StringName, cellID : int = UnknownHash) -> int:
	var hasHash : bool = HasCellHash(cellname)
	var cellHash : int = UnknownHash
	if hasHash:
		push_error("Cell hash already exists for %s" % cellname)
		return UnknownHash
	if not hasHash:
		var cellNameHash : int = cellname.hash()
		cellHash = cellNameHash if cellID == UnknownHash else cellID
		hashDB[cellname] = cellHash
	return cellHash

static func GetCellHash(cellname : StringName) -> int:
	var hasHash : bool = HasCellHash(cellname)
	if not hasHash:
		push_error("Cell hash doesn't exist for " + cellname)
		return UnknownHash
	return hashDB[cellname] if hasHash else UnknownHash

#
static func GetItem(cellHash : int, customfield : String = "") -> ItemCell:
	var cell : ItemCell = ItemsDB.get(cellHash, null)
	if cell == null:
		push_error("Could not find the identifier %s in ItemsDB" % [cellHash])
		return null
	if cell and customfield != cell.customfield:
		var customCell = cell.duplicate()
		customCell.customfield = customfield

		if HasCellHash(customfield):
			var paletteHash : int = GetCellHash(customfield)
			if paletteHash in PalettesDB[Palette.EQUIPMENT]:
				var paletteData : FileData = DB.GetPalette(DB.Palette.EQUIPMENT, paletteHash)
				if paletteData:
					customCell.shader = paletteData._resource as Material
		return customCell
	else:
		return cell

static func GetEntity(entityHash : int) -> EntityData:
	var data : EntityData = EntitiesDB.get(entityHash, null)
	if data == null:
		push_error("Could not find the identifier %s in EntitiesDB" % [entityHash])
		return null
	return data

static func GetEmote(cellHash : int) -> BaseCell:
	var data : BaseCell = EmotesDB.get(cellHash, null)
	if data == null:
		push_error("Could not find the identifier %s in EmotesDB" % [cellHash])
		return null
	return data

static func GetSkill(cellHash : int) -> SkillCell:
	var data : SkillCell = SkillsDB.get(cellHash, null)
	if data == null:
		push_error("Could not find the identifier %s in SkillsDB" % [cellHash])
		return null
	return data

static func GetRace(cellHash : int) -> RaceData:
	var data : RaceData = RacesDB.get(cellHash, null)
	if data == null:
		push_error("Could not find the identifier %s in RacesDB" % [cellHash])
		return null
	return data

static func GetHairstyle(cellHash : int) -> HairstyleData:
	var data : HairstyleData = HairstylesDB.get(cellHash, null)
	if data == null:
		push_error("Could not find the identifier %s in HairstylesDB" % [cellHash])
		return null
	return data

static func GetPalette(type : Palette, cellHash : int) -> FileData:
	var data : FileData = PalettesDB[type].get(cellHash, null)
	if data == null:
		push_error("Could not find the identifier %s in PalettesDB" % [cellHash])
		return null
	return data

static func GetQuest(questID : int) -> QuestData:
	var data : QuestData = QuestsDB.get(questID, null)
	if data == null:
		push_error("Could not find the identifier %s in QuestsDB" % [questID])
		return null
	return data

static func WarmShaders():
	var tree : SceneTree = Launcher.get_tree()
	for resourcePath in FileSystem.ParseExtension(Path.ParticlePst, Path.SceneExt):
		var preset : PackedScene = FileSystem.LoadResource(resourcePath, false)
		if preset:
			var node : Node = preset.instantiate()
			if node is GPUParticles2D:
				node.emitting = true
				node.one_shot = true

			Launcher.GUI.shaders.add_child(node)
			await tree.process_frame
			node.queue_free()

#
static func Preload():
	preloadPaths.append_array(FileSystem.ParseResources(Path.PaletteHairPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.PaletteSkinPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.PaletteEquipPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.RacesPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.HairstylePst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.MapDataPst))
	# Conteúdo opcional de pacote: o preset Web exclui `presets/music/*` e
	# `data/music/*` pelo filtro de export (corte de peso medido em
	# deploy/WEB_SLIM.md) e o cliente tem caminho próprio para trilha ausente
	# (`Audio._StreamMusicFromWeb`). `.pck` não guarda diretório vazio, então
	# escanear mesmo assim empilhava `push_error` em todo boot web — medido no
	# navegador em 2026-09-25. No desktop a pasta existe, e o erro de
	# `ParseExtension` continua de pé se ela sumir lá.
	if FileSystem.DirExists(Path.MusicPst):
		preloadPaths.append_array(FileSystem.ParseResources(Path.MusicPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.EmotePst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.ItemPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.SkillPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.QuestPst))
	preloadPaths.append_array(FileSystem.ParseResources(Path.EntityPst))

	for path in preloadPaths:
		ResourceLoader.load_threaded_request(path)

	Launcher.get_tree().process_frame.connect(PreloadUpdate, CONNECT_ONE_SHOT)

static func PreloadUpdate():
	for path in preloadPaths:
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			Launcher.get_tree().process_frame.connect(PreloadUpdate, CONNECT_ONE_SHOT)
			return
	_FinishPreload()
	isInitialized = true
	Load()

# An unjoined threaded load is not a benign leak: the engine destroys the worker
# while it is still parsing, under a script cache that teardown is already
# freeing. That is why any quit() landing mid-preload printed failed
# `script = ExtResource(...)` parses and then segfaulted on exit.
static func DrainPendingPreloads():
	for path in preloadPaths:
		ResourceLoader.load_threaded_get(path)
	_FinishPreload()

static func _FinishPreload():
	preloadPaths = []
	if Launcher == null or Launcher.get_tree() == null:
		return
	if Launcher.get_tree().process_frame.is_connected(PreloadUpdate):
		Launcher.get_tree().process_frame.disconnect(PreloadUpdate)

static func Load():
	Populate()
	StripUnused()
	# SOM-IDLE D1: resolve farm-zone map hashes the moment the DB is up,
	# BEFORE any dbInitialized consumer. Production had no SyncWithDB caller
	# (only the test suites called it), so zone.mapID stayed UnknownHash
	# forever, IdlePolicyService.StartIdleSession always bailed at its zone
	# guard and the live game silently never went idle-first. load() keeps
	# this a runtime reference — no static parse cycle with FarmZoneData->DB.
	var farmZones : GDScript = load("res://sources/idle/FarmZoneData.gd")
	farmZones.call("SyncWithDB")
	Launcher.dbInitialized.emit()

static func Populate():
	PalettesDB.resize(Palette.COUNT)

	ParseFileDB(PalettesDB[Palette.HAIR], Path.PaletteHairPst)
	ParseFileDB(PalettesDB[Palette.SKIN], Path.PaletteSkinPst)
	ParseFileDB(PalettesDB[Palette.EQUIPMENT], Path.PaletteEquipPst)

	ParseRacesDB()
	ParseFileDB(HairstylesDB, Path.HairstylePst)

	ParseFileDB(MapsDB, Path.MapDataPst)
	# Mesmo conteúdo opcional do filtro web: ver o guard em `Preload()`.
	if FileSystem.DirExists(Path.MusicPst):
		ParseFileDB(MusicDB, Path.MusicPst)

	ParseCellDB(EmotesDB, Path.EmotePst)
	ParseCellDB(ItemsDB, Path.ItemPst)
	ParseCellDB(SkillsDB, Path.SkillPst)

	ParseQuestsDB()
	ParseEntitiesDB()

static func Clear():
	MapsDB.clear()
	MusicDB.clear()
	RacesDB.clear()
	HairstylesDB.clear()
	for paletteDict in PalettesDB:
		paletteDict.clear()
	PalettesDB.clear()
	EntitiesDB.clear()
	EmotesDB.clear()
	ItemsDB.clear()
	SkillsDB.clear()
	QuestsDB.clear()
	hashDB.clear()

	DrainPendingPreloads()
	isInitialized = false

static func Init():
	Clear()
	if isInitialized:
		Load()
	else:
		Preload()

static func StripDB(db : Dictionary, hasClient : bool, hasServer : bool):
	for id in db:
		var copy = db[id].duplicate()
		if not hasClient:	copy.StripClient()
		if not hasServer:	copy.StripServer()
		db[id] = copy

static func StripUnused():
	var hasClient : bool = Network.Client != null
	var hasServer : bool = Network.ENetServer != null or Network.WebSocketServer != null
	if hasClient and hasServer:
		return

	StripDB(MapsDB, hasClient, hasServer)
	StripDB(MusicDB, hasClient, hasServer)
	StripDB(RacesDB, hasClient, hasServer)
	StripDB(HairstylesDB, hasClient, hasServer)
	for paletteDict in PalettesDB:
		StripDB(paletteDict, hasClient, hasServer)
	StripDB(EntitiesDB, hasClient, hasServer)
	StripDB(EmotesDB, hasClient, hasServer)
	StripDB(ItemsDB, hasClient, hasServer)
	StripDB(SkillsDB, hasClient, hasServer)
