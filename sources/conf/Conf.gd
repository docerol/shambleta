extends ServiceBase
class_name Conf

#
enum Type
{
	NONE = -1,
	SETTINGS = 0,
	USERSETTINGS,
	CREDENTIAL,
	AUTH_TOKEN,
	COUNT
}

static var confFiles : Array[ConfigFile]		= []
static var cache : Dictionary					= {}

#
static func GetCacheID(section : String, key : String, type : Type) -> String:
	return "%s%s%d" % [section, key, type]

static func GetVariant(section : String, key : String, type : Type, default = null):
	if type >= Type.COUNT or not confFiles[type]:
		push_error("Config type is not valid, returning default value")
		return default

	var value = default
	var cacheID = GetCacheID(section, key, type)

	if cacheID in cache:
		value = cache[cacheID]
	elif confFiles[type].has_section_key(section, key):
		value = confFiles[type].get_value(section, key, default)
		cache[cacheID] = value 

	return value

static func GetBool(section : String, key : String, type : Type = Type.NONE) -> bool:
	return GetVariant(section, key, type, false)

static func GetInt(section : String, key : String, type : Type = Type.NONE) -> int:
	return GetVariant(section, key, type, 0)

static func GetFloat(section : String, key : String, type : Type = Type.NONE) -> float:
	return GetVariant(section, key, type, 0.0)

static func GetVector2(section : String, key : String, type : Type = Type.NONE) -> Vector2:
	return GetVariant(section, key, type, Vector2.ZERO)

static func GetVector2i(section : String, key : String, type : Type = Type.NONE) -> Vector2i:
	return GetVariant(section, key, type, Vector2i.ZERO)

static func GetString(section : String, key : String, type : Type = Type.NONE) -> String:
	return GetVariant(section, key, type, "")

static func SetValue(section : String, key : String, type : Type, value):
	if type >= Type.COUNT or not confFiles[type]:
		push_error("Can't find %s within our loaded conf files" % type)
		return

	confFiles[type].set_value(section, key, value)
	var cacheID = GetCacheID(section, key, type)
	if cacheID in cache:
		cache[cacheID] = value

static func HasSection(section : String, type : Type) -> bool:
	if type >= Type.COUNT:
		push_error("Can't find %s within our loaded conf files" % type)
		return false

	return confFiles[type].has_section(section)

static func HasSectionKey(section : String, key : String, type : Type) -> bool:
	if type >= Type.COUNT:
		push_error("Can't find %s within our loaded conf files" % type)
		return false

	return confFiles[type].has_section_key(section, key)

static func SaveType(fileName : String, type : Type):
	if type >= Type.COUNT:
		push_error("Can't find %s within our loaded conf files" % type)
		return

	FileSystem.SaveConfig(fileName, confFiles[type])

#
static func Init():
	confFiles.resize(Type.COUNT)
	confFiles[Type.SETTINGS] = FileSystem.LoadConfig("settings")
	confFiles[Type.USERSETTINGS] = FileSystem.LoadConfig("settings", true)
	confFiles[Type.CREDENTIAL] = FileSystem.LoadConfig("credential", true)
	confFiles[Type.AUTH_TOKEN] = FileSystem.LoadConfig("auth_token", true)
	if confFiles.size() != Type.COUNT:
		push_error("Config files count mismatch")
		return
