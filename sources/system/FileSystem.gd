extends Node
class_name FileSystem

# Generic
static func FileExists(path : String) -> bool:
	return FileAccess.file_exists(path)

# Pasta dentro do pacote exportado. `.pck` não guarda diretório vazio, então uma
# pasta cujo conteúdo foi excluído pelo filtro do preset simplesmente não existe
# em `res://` — e é preciso distinguir isso de caminho errado antes de reclamar.
static func DirExists(path : String) -> bool:
	return DirAccess.dir_exists_absolute(path)

static func ResourceExists(path : String) -> bool:
	return ResourceLoader.exists(path)

static func CanInstantiateResource(res : Object) -> bool:
	return res.has_method("can_instantiate") && res.can_instantiate()

static func ResourceInstance(path : String) -> Object:
	var resourceLoaded : Object		= ResourceLoader.load(path)
	var resourceInstance : Object	= null
	if resourceLoaded != null && CanInstantiateResource(resourceLoaded):
		resourceInstance = resourceLoaded.instantiate()
	return resourceInstance

static func ResourceInstanceOrLoad(path : String) -> Object:
	var resourceLoaded : Object		= ResourceLoader.load(path)
	var resource : Object			= null
	if resourceLoaded != null:
		if CanInstantiateResource(resourceLoaded):
			resource = resourceLoaded.instantiate()
		else:
			resource = resourceLoaded
	return resource

# File
static func LoadFile(path : String) -> String:
	var fullPath : String		= Path.DataRsc + path
	var content : String		= ""

	var pathExists : bool		= FileExists(fullPath)
	if not pathExists:
		push_error("Content file not found " + path + " should be located at " + fullPath)
		return ""

	if pathExists:
		var file : FileAccess = FileAccess.open(fullPath, FileAccess.READ)
		if file == null:
			push_error("File parsing issue on file " + fullPath)
			return ""
		content = file.get_as_text()
		Util.PrintLog("File", "Loading file: " + fullPath)
		file.close()
	return content

static func SaveFile(fullPath : String, content : String):
	var file : FileAccess		= FileAccess.open(fullPath, FileAccess.WRITE)
	if file == null:
		push_error("File parsing issue on file " + fullPath)
		return
	if file:
		file.store_string(content)
		file.close()
		Util.PrintInfo("FileSystem", "Saving file %s" % fullPath)

# DB
static func LoadDB(path : String) -> Dictionary:
	var fullPath : String		= Path.DBRsc + path
	var result : Dictionary		= {}

	var pathExists : bool		= FileExists(fullPath)
	if not pathExists:
		push_error("DB file not found " + path + " should be located at " + fullPath)
		return {}

	if pathExists:
		var DBFile : FileAccess = FileAccess.open(fullPath, FileAccess.READ)

		var jsonInstance : JSON = JSON.new()
		var err : int = jsonInstance.parse(DBFile.get_as_text())

		if err != OK:
			push_error("DB parsing issue on file " + fullPath \
				+ " Line: " + str(jsonInstance.get_error_line()) \
				+ " Error: " + jsonInstance.get_error_message() \
			)
			return {}

		result = jsonInstance.get_data()
		Util.PrintLog("DB", "Loading file: " + fullPath)

	return result

static func LoadScript(path : String) -> GDScript:
	return ResourceLoader.load(Path.ScriptSrc + path) as GDScript

# Config
static func LoadConfig(path : String, userDir : bool = false) -> ConfigFile:
	var fullPath : String		= (Path.Local if userDir else Path.ConfRsc) + path + Path.ConfExt
	var cfgFile : ConfigFile	= null

	var pathExists : bool = FileExists(fullPath)
	if pathExists or userDir:
		cfgFile = ConfigFile.new()
		if pathExists:
			var err : Error = cfgFile.load(fullPath)
			if err != OK:
				push_error("Error loading the config file " + path + " located at " + fullPath)
				cfgFile.free()
				cfgFile = null
			else:
				Util.PrintLog("Config", "Loading file: " + fullPath)
	else:
		if not pathExists:
			push_error("Config file not found " + path + " should be located at " + fullPath)

	return cfgFile

static func SaveConfig(path : String, cfgFile : ConfigFile):
	if cfgFile == null:
		push_error("Config file " + path + " not initialized")
		return

	if cfgFile:
		var fullPath : String = Path.Local + path + Path.ConfExt
		var err : Error = cfgFile.save(fullPath)
		if err != OK:
			push_error("Error saving the config file " + path + " located at " + fullPath)
			return
		Util.PrintLog("Config", "Saving file: " + fullPath)

# Resource
static func LoadResource(fullPath : String, instantiate : bool = true) -> Object:
	var rscInstance : Object	= null
	var pathExists : bool		= ResourceExists(fullPath)

	if not pathExists:
		push_error("Resource file not found at: " + fullPath)
	if pathExists:
		rscInstance = ResourceInstance(fullPath) if instantiate else ResourceLoader.load(fullPath)

	return rscInstance

# Effect
static func LoadEffect(path : String, instantiate : bool = true) -> Node:
	var fullPath : String = Path.EffectsPst + path + Path.SceneExt
	return LoadResource(fullPath, instantiate)

# Material
static func LoadMaterial(path : String, instantiate : bool = false) -> Object:
	var fullPath : String = Path.MaterialPst + path + Path.RscExt
	return LoadResource(fullPath, instantiate)

static func GetFiles(path : String) -> PackedStringArray:
	return DirAccess.get_files_at(path)

# Utils
static func SaveScreenshot():
	var dirPath : String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if dirPath == "":
		return

	var image : Image = Util.GetScreenCapture()
	if image == null:
		push_error("Could not get a viewport screenshot")
		return
	if not image:
		return

	var dir : DirAccess = DirAccess.open(dirPath)
	if not dir.dir_exists("Screenshots"):
		dir.make_dir("Screenshots")
	dir.change_dir("Screenshots")

	var date : Dictionary = Time.get_datetime_dict_from_system()
	var savePath : String = dir.get_current_dir(true)
	savePath += "/Screenshot-%d-%02d-%02d_%02d-%02d-%02d" % [date.year, date.month, date.day, date.hour, date.minute, date.second]
	savePath += Path.GfxExt

	if not dir.dir_exists(savePath):
		var ret : Error = image.save_png(savePath)
		if ret != OK:
			push_error("Could not save the screenshot, error code: " + str(ret))
		if ret == OK:
			Util.PrintInfo("FileSystem", "Saving capture: " + savePath)

static func CopyFile(sourcePath : String, targetPath : String) -> bool:
	if not FileSystem.FileExists(sourcePath):
		return false

	var sourceFile = FileAccess.open(sourcePath, FileAccess.READ)
	if not sourceFile:
		push_error("Failed to open source file: " + sourcePath)
		return false

	var targetFile = FileAccess.open(targetPath, FileAccess.WRITE)
	if not targetFile:
		push_error("Failed to open target file: " + targetPath)
		return false

	var buffer = sourceFile.get_buffer(sourceFile.get_length())
	targetFile.store_buffer(buffer)

	sourceFile.close()
	targetFile.close()

	return true

static func CreateRecursiveDirectory(path : String) -> bool:
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		dir = DirAccess.open("res://")
		if dir == null:
			push_error("Could not access root resource path (\"res://\")")
			return false
		var err : Error = dir.make_dir_recursive(path.trim_prefix("res://"))
		if err != OK:
			push_error("Failed to create directory: %s" % path)
			return false
	return true

# Parse
static func ParseExtension(path : String, extension : String) -> PackedStringArray:
	var resources : PackedStringArray = []
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		push_error("File path \"%s\" is not accessible" % path)
		return resources

	for directory in dir.get_directories():
		var directoryPath : String = path.path_join(directory)
		resources.append_array(ParseExtension(directoryPath, extension))

	for file in dir.get_files():
		var rawFileName = file.get_slice(Path.RemapExt, 0)
		if rawFileName.ends_with(extension):
			var filePath : String = path.path_join(rawFileName)
			resources.append(filePath)

	return resources

static func ParseResources(path : String) -> PackedStringArray:
	return ParseExtension(path, Path.RscExt)

static func ParseSQL(path : String) -> PackedStringArray:
	var patches : PackedStringArray = ParseExtension(path, Path.SQLExt)
	# Ordem de listagem não é contrato de `DirAccess`, e `SQL.ApplyMigrations()` usa o
	# índice do array como número de versão (`patches[currentVersion]`): desordem ou
	# buraco aplica patches fora de sequência sem que nada reclame alto. No source
	# tree medido em 2026-09-24 a listagem veio ordenada (001..046, 0 pares fora de
	# ordem) e o CI roda assim; o servidor de produção roda de .pck exportado, e a
	# ordem dentro do pacote não foi medida nesta máquina (sem templates de export) —
	# o teste de contrato em `IdleTests` enxerga só o caminho do source. Ordenar aqui
	# fecha a questão nos dois caminhos sem mudar nada do que roda hoje.
	patches.sort()
	return patches
