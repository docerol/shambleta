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

# Todo acesso passa por estas duas réguas, e cada uma caça um defeito diferente.
#
# `Ensure()`: `Init()` é chamado do `Launcher._ready`, mas `Conf` é estático — o
# primeiro acesso pode vir de qualquer caminho que não passou por ali (SceneTree de
# teste `-s`, serviço web, o que for). Antes desta linha o estado "não inicializado"
# era um `Array` VAZIO, e `confFiles[Type.USERSETTINGS]` não é um null defensável:
# é out-of-bounds, que derrama SCRIPT ERROR em cada chamada (medido: `WebPush._Save`
# sozinho produziu 20 num harness). Escrever preferência sem `Init` era, na prática,
# um pedido de gravação que caía no chão.
#
# `Usable()`: `Type.NONE = -1` é o default de todo getter, e `Array` do Godot aceita
# índice negativo — `confFiles[-1]` devolve o ÚLTIMO arquivo da lista, que é
# `AUTH_TOKEN` (a régua `SuiteDeployMode` (`tests/IdleTests.gd:@SuiteDeployMode`) é sobre o token
# morear ali). Sem o piso em `Type.SETTINGS`, um `GetString(section, key)` que esqueceu o tipo
# lia a credencial e devolvia como se fosse preferência do usuário, sem um pio.
static func Ensure():
	if confFiles.is_empty():
		Init()

static func Usable(type : Type) -> bool:
	return type >= Type.SETTINGS and type < Type.COUNT and type < confFiles.size() and confFiles[type] != null

#
static func GetCacheID(section : String, key : String, type : Type) -> String:
	return "%s%s%d" % [section, key, type]

static func GetVariant(section : String, key : String, type : Type, default = null):
	Ensure()
	if not Usable(type):
		push_error("Conf.GetVariant([%s]%s, type %s): not usable, returning default" % [section, key, type])
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
	Ensure()
	if not Usable(type):
		push_error("Conf.SetValue([%s]%s, type %s): not usable, NOTHING was written" % [section, key, type])
		return

	confFiles[type].set_value(section, key, value)
	var cacheID = GetCacheID(section, key, type)
	if cacheID in cache:
		cache[cacheID] = value

static func HasSection(section : String, type : Type) -> bool:
	Ensure()
	if not Usable(type):
		push_error("Can't find %s within our loaded conf files" % type)
		return false

	return confFiles[type].has_section(section)

static func HasSectionKey(section : String, key : String, type : Type) -> bool:
	Ensure()
	if not Usable(type):
		push_error("Can't find %s within our loaded conf files" % type)
		return false

	return confFiles[type].has_section_key(section, key)

static func SaveType(fileName : String, type : Type):
	Ensure()
	if not Usable(type):
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
	# O cache é indexado por (seção, chave, tipo) e não por "de qual arquivo este
	# valor veio". Recarregar os ConfigFile sem esvaziá-lo faria a segunda leitura de
	# qualquer chave devolver o valor da primeira — que é exatamente o tipo de
	# mentira que `Init` existe para desfazer ao reler o disco.
	cache.clear()
	if confFiles.size() != Type.COUNT:
		push_error("Config files count mismatch")
		return
