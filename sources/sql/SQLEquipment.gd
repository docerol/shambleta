extends RefCounted
class_name SQLEquipment

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func GetEquipment(charID : int) -> Dictionary:
	pass

func UpdateEquipment(charID : int, equipment : Dictionary) -> bool:
	pass
