extends SceneTree

# SOM-IDLE beta fechado: teste REAL de restore local (não só "arquivo criado").
# 1. tira snapshot da base de teste via o próprio mecanismo de backup;
# 2. registra baseline (integridade + tabelas críticas + ledger + jogadores);
# 3. simula perda/corrupção do original;
# 4. restaura o backup em base SEPARADA (nunca por cima de banco real);
# 5. valida integridade + dados + abertura pelo gate da aplicação.
# Só opera em diretório temporário; o live.db de teste nunca é escrito aqui.
# Usage: godot --headless --path . -s tests/test_backup_full_restore.gd
# Exit code: 0 = green, 1 = failure.

var _fails : int = 0

func _note(ok : bool, label : String) -> void:
    print(("  PASS" if ok else "  FAIL") + " · " + label)
    if not ok:
        _fails += 1

func _getAutoload(nodeName: String) -> Node:
    return root.get_node_or_null(NodePath(nodeName))

func _open(path : String) -> SQLite:
    var db : SQLite = SQLite.new()
    db.path = path
    db.verbosity_level = SQLite.QUIET
    if not db.open_db():
        return null
    return db

func _one_int(db : SQLite, q : String) -> int:
    if not db.query(q) or db.query_result.is_empty():
        return -999999
    var row : Dictionary = db.query_result[0]
    return int(row.values()[0])

func _one_str(db : SQLite, q : String) -> String:
    if not db.query(q) or db.query_result.is_empty():
        return ""
    var row : Dictionary = db.query_result[0]
    return str(row.values()[0])

func _file_size(path : String) -> int:
    if not FileAccess.file_exists(path):
        return -1
    var fh : FileAccess = FileAccess.open(path, FileAccess.READ)
    if fh == null:
        return -1
    var n : int = int(fh.get_length())
    fh.close()
    return n

func _run():
    print("== Backup Full Restore (beta fechado) ==")
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
    # Beta fechado: script -s duck-typed (ver run_idle_tests.gd) — sem refs
    # estáticas a classes do projeto (compile antes dos autoloads quebra).
    var sql : Node = launcher.SQL
    if sql == null or not sql.isInitialized:
        print("FATAL: SQL not initialized within timeout")
        quit(1)
        return

    var work : String = OS.get_temp_dir().rstrip("/") + "/shambleta_restore_test/"
    if DirAccess.make_dir_recursive_absolute(work) != OK:
        print("FATAL: cannot create work dir " + work)
        quit(1)
        return
    var original : String = work + "original.db"
    var backup : String = work + "backup.db"
    var restored : String = work + "restored.db"
    for f in [original, backup, restored]:
        if FileAccess.file_exists(f):
            DirAccess.remove_absolute(f)

    # 1. snapshot da base via o mecanismo real (backup_to, como CreateDailyBackup)
    var snap : SQLite = _open(sql.db.path)
    _note(snap != null, "live test db abre para snapshot")
    if snap == null:
        quit(1)
        return
    _note(snap.backup_to(original), "snapshot consistente via backup_to")
    snap.close_db()
    # trava a base de trabalho contra escritas do server durante o teste:
    # (o teste só lê/escreve cópias em work/, nunca o live)
    var src : SQLite = _open(original)
    _note(src != null, "cópia de trabalho abre")
    if src == null:
        quit(1)
        return

    # 2. baseline: integridade + registros críticos + ledger + jogadores
    _note(_one_str(src, "PRAGMA integrity_check;") == "ok", "integridade do original ok")
    var base : Dictionary = {
        "migration": _one_int(src, "SELECT version FROM migration LIMIT 1;"),
        "accounts": _one_int(src, "SELECT COUNT(*) FROM account;"),
        "characters": _one_int(src, "SELECT COUNT(*) FROM character;"),
        "ledger_rows": _one_int(src, "SELECT COUNT(*) FROM ledger_transaction;"),
        "ledger_gems": _one_int(src, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gems';"),
        "ledger_gold": _one_int(src, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gold';"),
        "wallet_gems": _one_int(src, "SELECT COALESCE(SUM(gems),0) FROM wallet;"),
    }
    _note(int(base["migration"]) >= 0, "migration version legível (%d)" % int(base["migration"]))
    _note(int(base["accounts"]) > 0, "há contas na base (%d)" % int(base["accounts"]))
    var player : Array = []
    if src.query("SELECT char_id, nickname, account_id FROM character ORDER BY char_id LIMIT 1;"):
        player = src.query_result
    _note(not player.is_empty(), "linha de jogador legível")
    var player_stat : Array = []
    if not player.is_empty() and src.query("SELECT level, experience, gp FROM stat WHERE char_id = %d;" % int(player[0]["char_id"])):
        player_stat = src.query_result
    _note(not player_stat.is_empty(), "stat do jogador legível")
    print("baseline: migration=%d accounts=%d chars=%d ledger_rows=%d gems_sum=%d gold_sum=%d wallet_gems=%d" % [
        int(base["migration"]), int(base["accounts"]), int(base["characters"]),
        int(base["ledger_rows"]), int(base["ledger_gems"]), int(base["ledger_gold"]),
        int(base["wallet_gems"])])

    # 3. backup da cópia de trabalho pelo mecanismo real
    _note(src.backup_to(backup), "backup executado via backup_to")
    src.close_db()
    var backup_size : int = _file_size(backup)
    _note(backup_size > 0, "backup criado com tamanho > 0 (%d bytes)" % backup_size)
    print("backup: %s (%d bytes)" % [backup, backup_size])

    # 4. simula perda/corrupção do original
    _note(DirAccess.remove_absolute(original) == OK, "original removido (perda simulada)")
    var garbage : FileAccess = FileAccess.open(original, FileAccess.WRITE)
    garbage.store_string("GARBAGE-NOT-A-DATABASE")
    garbage.close()
    var dead : SQLite = _open(original)
    var dead_ok : bool = dead != null and _one_str(dead, "PRAGMA integrity_check;") == "ok"
    if dead != null:
        dead.close_db()
    _note(not dead_ok, "original corrompido é rejeitado (não abre íntegro)")

    # 5. restore em base SEPARADA (nunca por cima do original/live)
    _note(DirAccess.copy_absolute(backup, restored) == OK, "restore p/ base separada")
    var backupsScript : GDScript = load("res://sources/sql/SQLBackups.gd")
    _note(backupsScript.VerifyBackupRestorable(restored), "gate da aplicação aceita a base restaurada")
    var dst : SQLite = _open(restored)
    _note(dst != null, "base restaurada abre (app consegue abrir)")
    if dst == null:
        quit(1)
        return
    _note(_one_str(dst, "PRAGMA integrity_check;") == "ok", "integridade da restaurada ok")
    _note(_one_int(dst, "SELECT version FROM migration LIMIT 1;") == int(base["migration"]), "migration version confere")
    _note(_one_int(dst, "SELECT COUNT(*) FROM account;") == int(base["accounts"]), "contas conferem (%d)" % int(base["accounts"]))
    _note(_one_int(dst, "SELECT COUNT(*) FROM character;") == int(base["characters"]), "personagens conferem")
    _note(_one_int(dst, "SELECT COUNT(*) FROM ledger_transaction;") == int(base["ledger_rows"]), "ledger: linhas conferem")
    _note(_one_int(dst, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gems';") == int(base["ledger_gems"]), "ledger: soma gems confere")
    _note(_one_int(dst, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gold';") == int(base["ledger_gold"]), "ledger: soma gold confere")
    _note(_one_int(dst, "SELECT COALESCE(SUM(gems),0) FROM wallet;") == int(base["wallet_gems"]), "wallet: estoque gems confere")
    var rst : Array = []
    if dst.query("SELECT level, experience, gp FROM stat WHERE char_id = %d;" % int(player[0]["char_id"])):
        rst = dst.query_result
    _note(not rst.is_empty() and int(rst[0]["level"]) == int(player_stat[0]["level"]) and int(rst[0]["gp"]) == int(player_stat[0]["gp"]), "dados do jogador conferem (level/gp)")
    dst.close_db()

    for f in [original, backup, restored]:
        DirAccess.remove_absolute(f)
    print("work dir limpo; live.db de teste intocado (só leitura p/ snapshot)")

    if _fails > 0:
        print("== FULL RESTORE: %d failures ==" % _fails)
        quit(1)
        return
    print("== FULL RESTORE: PASSED (backup %d bytes, %d contas, %d chars, %d linhas ledger verificadas) ==" % [
        backup_size, int(base["accounts"]), int(base["characters"]), int(base["ledger_rows"])])
    quit(0)

func _initialize():
    _run()
