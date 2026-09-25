class_name WorldMap
extends RefCounted

#
enum Flags
{
	NONE = 0,
	NO_DROP = 1 << 0,
	NO_SPELL = 1 << 1,
	NO_REJOIN = 1 << 2,
	ONLY_SPIRIT = 1 << 3,
}

#
var id : int							= DB.UnknownHash
var name : String						= ""
var instances : Dictionary[int, WorldInstance]	= {}
var spawns : Array[SpawnObject]			= []
var flags : int							= Flags.NONE
var navPoly : NavigationPolygon			= null
var mapRID : RID						= RID()
var regionRID : RID						= RID()

#
static func Create(mapID : int) -> WorldMap:
	var map : WorldMap = null
	var mapData : FileData = DB.MapsDB.get(mapID, null)
	if mapData:
		map = WorldMap.new()
		map.id = mapID
		map.name = mapData._name
		map.LoadMapData()
		WorldNavigation.LoadData(map)
		map.CreateInstance(0)

	return map

func CreateInstance(instanceID : int) -> WorldInstance:
	var inst : WorldInstance = WorldInstance.Create(self, instanceID)
	instances[instanceID] = inst
	return inst

func DestroyInstance(instanceID : int):
	var inst : WorldInstance = instances.get(instanceID, null)
	if inst:
		inst.Destroy()
		instances.erase(instanceID)

# PopAgent adia o fechamento da instância vazia para o fim do frame, e na mesma
# chamada precisa conferir duas coisas. Identidade: outro pedido pode ter assumido
# o id (reconexão, retomada de sessão idle) — matar por id destrói a instância
# nova. Vazio: o pop que enfileirou isto pode ser um warp para a PRÓPRIA
# instância (a lista esvazia no pop e o PushAgent do mesmo frame enche de novo),
# e Destroy() faz RemoveAgent em quem está dentro — ou seja, mataria o jogador.
func DestroyEmptyInstanceIfUnchanged(instanceID : int, expected : WorldInstance) -> bool:
	var inst : WorldInstance = instances.get(instanceID, null)
	if inst != expected or not inst.players.is_empty():
		return false
	DestroyInstance(instanceID)
	return true

func Destroy():
	for instanceID in instances.keys():
		DestroyInstance(instanceID)
	if regionRID.is_valid():
		NavigationServer2D.free_rid(regionRID)
		regionRID = RID()

func LoadMapData():
	var resource : MapServerData = Instantiate.LoadMapData(id)
	if resource:
		flags = resource.flags
		for spawn in resource.spawns:
			if spawn == null:
				push_error("Spawn format is not supported")
				return
			if spawn:
				spawn.map = self
				spawns.append(spawn)

func HasFlags(checkedFlags : Flags) -> bool: return !!(flags & checkedFlags)
