extends RefCounted
class_name SQLMigration

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func HasVersion() -> bool:
	var result = Query("SELECT name FROM sqlite_master WHERE type=\"table\" AND name=\"migration\"")
	return not result.is_empty()

func GetVersion() -> int:
	if HasVersion():
		var result = Query("SELECT version FROM migration LIMIT 1;")
		if not result.is_empty():
			return result[0].get("version", 0)
	return 0

func SetVersion(version : int):
	Query("UPDATE migration SET version = %d;" % version)

func ApplyMigrations():
	var currentVersion : int = GetVersion()
	var patches : PackedStringArray = FileSystem.ParseSQL(Path.MigrationRsc)
	if currentVersion >= patches.size():
		return
	for i in range(currentVersion, patches.size()):
		ApplyMigration(patches[i])

func ApplyMigration(migrationFile : String):
	var migration : String = FileAccess.get_file_as_string(migrationFile)
	Query(migration)

func Query(query : String) -> Array:
	_queryMutex.lock()
	var result : Array = []
	if _db.query(query):
		result = _db.query_result
	_queryMutex.unlock()
	return result
