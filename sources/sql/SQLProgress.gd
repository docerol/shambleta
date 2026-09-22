extends RefCounted
class_name SQLProgress

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func SetSkill(charID : int, skillID : int, level : int) -> bool:
	pass

func GetSkills(charID : int) -> Array[Dictionary]:
	pass

func SetBestiary(charID : int, entryID : int, count : int) -> bool:
	pass

func GetBestiaries(charID : int) -> Array[Dictionary]:
	pass

func SetQuest(charID : int, questID : int, status : int) -> bool:
	pass

func GetQuests(charID : int) -> Array[Dictionary]:
	pass

func UpdateProgress(charID : int, data : Dictionary) -> bool:
	pass
