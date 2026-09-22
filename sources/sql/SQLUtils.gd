extends RefCounted
class_name SQLUtils

# DB utilities: queries, transactions, Wipe, lifecycle

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func Query(query : String) -> Array:
	_queryMutex.lock()
	var result : Array = []
	if _db.query(query):
		result = _db.query_result
	_queryMutex.unlock()
	return result

func QueryBindings(query : String, params : Array) -> Array[Dictionary]:
	_queryMutex.lock()
	var data : Array[Dictionary] = []
	if _db.query_with_bindings(query, params):
		data = _db.query_result
	_queryMutex.unlock()
	return data

func ExecuteBindings(query : String, params : Array) -> bool:
	_queryMutex.lock()
	var ret : bool = _db.query_with_bindings(query, params)
	_queryMutex.unlock()
	return ret

func Transaction(callable : Callable) -> bool:
	var committed : bool = false
	_queryMutex.lock()
	if _db.query("BEGIN TRANSACTION;"):
		var result : bool = callable.call()
		if result and _db.query("COMMIT;"):
			committed = true
		else:
			_db.query("ROLLBACK;")
	_queryMutex.unlock()
	return committed

func UpdateRowsRaw(table : String, conditions : String, data : Dictionary) -> bool:
	var keys : PackedStringArray = PackedStringArray()
	var bindings : Array = []
	for key in data:
		keys.append("%s=?" % key)
		bindings.append(data[key])
	var query : String = "UPDATE %s SET %s WHERE %s;" % [table, ", ".join(keys), conditions]
	return ExecuteBindings(query, bindings)

func DeleteRowsRaw(table : String, conditions : String) -> bool:
	var query : String = "DELETE FROM %s WHERE %s;" % [table, conditions]
	return ExecuteBindings(query, [])

func LastInsertRowIDRaw() -> int:
	_queryMutex.lock()
	var rowID : int = 0
	if _db.query("SELECT last_insert_rowid();"):
		rowID = int(_db.query_result[0].get("last_insert_rowid()", 0))
	_queryMutex.unlock()
	return rowID

func Wipe():
	assert(OS.is_debug_build(), "Wipe() só pode ser chamada em debug build")
	if not OS.is_debug_build():
		push_error("SQL.Wipe(): recusado em produção")
		return
	DeleteRowsRaw("account", "")
	DeleteRowsRaw("attribute", "")
	DeleteRowsRaw("cell", "")
	DeleteRowsRaw("character", "")
	DeleteRowsRaw("item_instance", "")
	DeleteRowsRaw("quest", "")
	DeleteRowsRaw("skill", "")

func Destroy():
	_db = null

func _post_launch(dbPath : String):
	if not FileSystem.FileExists(dbPath) and not SQLCommons.CopyDatabase(dbPath):
		return
	ApplyMigrations()
