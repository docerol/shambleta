extends RefCounted
class_name SQLStats

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func GetAttribute(charID : int, attribute : String) -> int:
	pass

func UpdateAttribute(charID : int, attribute : String, value : int) -> bool:
	pass

func GetTrait(charID : int, trait : String) -> int:
	pass

func UpdateTrait(charID : int, trait : String, value : int) -> bool:
	pass

func GetStat(charID : int) -> Dictionary:
	pass

func UpdateStat(charID : int, stats : ActorStats) -> bool:
	pass

func UpdateStatDirect(charID : int, newLevel : int, newExperience : int, newGold : int) -> bool:
	pass
