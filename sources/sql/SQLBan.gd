extends RefCounted
class_name SQLBan

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func BanAccount(accountID : int, reason : String, until : int = 0) -> bool:
	pass

func UnbanAccount(accountID : int) -> bool:
	pass

func LoadBans() -> Array[Dictionary]:
	pass

func GetBanList() -> Array[Dictionary]:
	pass

func BanIPRange(ipRange : String, reason : String, until : int = 0) -> bool:
	pass

func UnbanIPRange(ipRange : String) -> bool:
	pass

func LoadIPBans() -> Array[Dictionary]:
	pass

func GetIPBanList() -> Array[Dictionary]:
	pass
