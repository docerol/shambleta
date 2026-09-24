extends SceneTree

# SOM-IDLE A2: backup restore probe — CI gate.
# Creates a backup, verifies it can be read back, and checks migration integrity.
# Usage: godot --headless --path . -s tests/test_backup_restore.gd
# Exit code: 0 = green, 1 = failure.

func _initialize():
    _run_probe()

func _getAutoload(nodeName: String) -> Node:
    return root.get_node_or_null(NodePath(nodeName))

func _run_probe():
    print("== Backup Restore Probe ==")

    var launcher: Node = _getAutoload("Launcher")
    if launcher == null:
        print("FATAL: Launcher autoload missing")
        quit(1)
        return

    var waited: int = 0
    var sqlNode: Node = null
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        sqlNode = launcher.SQL
        if sqlNode != null and sqlNode.isInitialized:
            break

    if sqlNode == null or not sqlNode.isInitialized:
        print("FATAL: SQL not initialized within timeout")
        quit(1)
        return

    print("SQL initialized after %d ms" % waited)

    # Beta fechado: script -s deve ser duck-typed (ver run_idle_tests.gd) —
    # refs estáticas a classes do projeto forçam compile antes dos autoloads.
    var sql: Node = sqlNode
    var backupsScript: GDScript = load("res://sources/sql/SQLBackups.gd")
    # O serviço sql.backups só sobe sem client-debug; no probe instanciamos
    # SQLBackups diretamente (mesmo code path de produção).
    var backupsService: Node = backupsScript.new()
    root.add_child(backupsService)
    var backupPath: String = backupsService.CreateDailyBackup()

    # SQLBackups._init() dispara um worker; se ele sobreviver ao quit() é
    # destruído sem join e passa a racar contra a árvore que ele mesmo acessa.
    # Reapós aqui (mesmo fora do caminho de produção, que passa por SQL.Destroy()).
    backupsService.Stop()
    backupsService.free()

    if backupPath.is_empty():
        print("FATAL: Backup creation failed")
        quit(1)
        return

    print("Backup created: %s" % backupPath)

    if not backupsScript.VerifyBackupRestorable(backupPath):
        print("FATAL: Backup restore probe failed — backup is not readable")
        quit(1)
        return

    print("Backup restore probe passed: migration version readable")

    var probe: SQLite = SQLite.new()
    probe.path = backupPath
    probe.verbosity_level = SQLite.QUIET
    if not probe.open_db():
        print("FATAL: Cannot open backup database")
        quit(1)
        return

    var versionResult: Array = []
    if probe.query("SELECT version FROM migration LIMIT 1;"):
        versionResult = probe.query_result
    probe.close_db()

    if versionResult.is_empty():
        print("FATAL: Backup database has no migration version")
        quit(1)
        return

    var version: int = int(versionResult[0].get("version", -1))
    print("Backup migration version: %d" % version)

    if version < 0:
        print("FATAL: Invalid migration version in backup")
        quit(1)
        return

    var liveVersion: int = sql.GetVersion()
    print("Live migration version: %d" % liveVersion)

    if version != liveVersion:
        print("WARNING: Backup version (%d) differs from live (%d)" % [version, liveVersion])

    print("== Backup Restore Probe: PASSED ==")
    quit(0)
