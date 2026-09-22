extends RefCounted
class_name SQLInventory

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func GrantItemLotRaw(charID : int, itemID : int, count : int, reason : String, bound : int = 0, customfield : String = "", parentUID : int = 0, creatorAccountID : int = 0) -> int:
	pass

func GetLotBalanceRaw(charID : int, itemID : int, bound : int = 0) -> int:
	pass

func ConsumeItemLotsRaw(charID : int, itemID : int, count : int, bound : int = 0) -> Array:
	pass

func GetItem(charID : int, itemID : int, customfield : String, storageType : int = 0) -> Dictionary:
	pass

func AddItem(charID : int, itemID : int, count : int, storage : int = 0, customfield : String = "") -> bool:
	pass

func RemoveItem(charID : int, itemID : int, count : int, storage : int = 0, customfield : String = "") -> bool:
	pass

func GetStorage(charID : int, storageType : int) -> Array[Dictionary]:
	pass

func AddItemToCharacter(charID : int, itemID : int, count : int, reason : String = "settle") -> bool:
	pass

func GetItemLot(uid : int) -> Dictionary:
	pass

func LotHistory(uid : int, maxHops : int = 20) -> Array[Dictionary]:
	pass
