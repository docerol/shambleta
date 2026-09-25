extends SceneTree

# SOM-IDLE A2: backup restore probe — CI gate.
# Cria um backup, relê, e confere a integridade do schema.
# Usage: godot --headless --path . -s tests/test_backup_restore.gd
# Exit code: nº de checks falhos (0 = verde). A última linha é a contagem — é ela
# que `scripts/ci_gate_log.sh` lê; crash antes dela não imprime nada e o job
# rejeita. Antes o probe terminava em `quit(0)` com "PASSED" sem contagem, e um
# segfault de shutdown saía 0: o job verde escondia exatamente a falha que ele
# media (ROADMAP §"Radar").

var checks: int = 0
var failures: int = 0

func _initialize():
    _run_probe()

func Check(condition, message: String) -> bool:
    checks += 1
    if condition:
        print("  [PASS] %s" % message)
        return true
    failures += 1
    print("  [FAIL] %s" % message)
    return false

func _Finish() -> void:
    print("== Backup Restore Probe: %d checks, %d failures ==" % [checks, failures])
    quit(failures if failures > 0 else 0)

func _getAutoload(nodeName: String) -> Node:
    return root.get_node_or_null(NodePath(nodeName))

func _run_probe():
    print("== Backup Restore Probe ==")

    var launcher: Node = _getAutoload("Launcher")
    if not Check(launcher != null, "Launcher autoload presente"):
        _Finish()
        return

    var waited: int = 0
    var sqlNode: Node = null
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        sqlNode = launcher.SQL
        if sqlNode != null and sqlNode.isInitialized:
            break

    if not Check(sqlNode != null and sqlNode.isInitialized, "SQL inicializa dentro do timeout (%d ms)" % waited):
        _Finish()
        return

    # Beta fechado: script -s deve ser duck-typed (ver run_idle_tests.gd) —
    # refs estáticas a classes do projeto forçam compile antes dos autoloads.
    var sql: Node = sqlNode
    var backupsScript: GDScript = load("res://sources/sql/SQLBackups.gd")
    if not Check(backupsScript != null, "SQLBackups carrega"):
        _Finish()
        return

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

    var created: bool = Check(not backupPath.is_empty(), "backup diário criado (%s)" % backupPath)
    var restorable: bool = created and backupsScript.VerifyBackupRestorable(backupPath)
    Check(restorable, "backup é relível pelo verificador de restore")

    var version: int = -1
    if restorable:
        var probe: SQLite = SQLite.new()
        probe.path = backupPath
        probe.verbosity_level = SQLite.QUIET
        if probe.open_db():
            if probe.query("SELECT version FROM migration LIMIT 1;") and not probe.query_result.is_empty():
                version = int(probe.query_result[0].get("version", -1))
            probe.close_db()

    Check(version >= 0, "backup carrega a versão de migration (%d)" % version)
    var liveVersion: int = sql.GetVersion()
    # Divergir não é aviso: backup com schema diferente do vivo não é o schema do
    # beta. No probe é determinístico (mesma conexão, worker já recolhido).
    Check(version == liveVersion, "schema do backup bate com o vivo (%d vs %d)" % [version, liveVersion])
    Check(liveVersion > 0, "versão viva é positiva (%d)" % liveVersion)

    _Finish()
