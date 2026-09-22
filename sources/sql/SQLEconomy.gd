extends RefCounted
class_name SQLEconomy

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func LastTradeTimestampRaw(charID : int) -> int:
	pass

func TradeCountTodayRaw(accountID : int, nowSec : int = 0) -> int:
	pass

func SearchLedger(accountID : int, limit : int = 20) -> Array[Dictionary]:
	pass

func GetGems(accountID : int) -> int:
	pass

func SetGems(accountID : int, gems : int) -> bool:
	pass

func GetGemsRaw(accountID : int) -> int:
	pass

func SetGemsRaw(accountID : int, gems : int) -> bool:
	pass
