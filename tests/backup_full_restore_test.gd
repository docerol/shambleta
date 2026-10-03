extends SceneTree

# SOM-IDLE beta fechado: teste REAL de restore local (não só "arquivo criado").
# 1. semea a PRÓPRIA fixture pela API de produção (conta + personagem + stat +
#    gems/gold pelo single-writer da economia);
# 2. tira snapshot da base de teste via o próprio mecanismo de backup;
# 3. registra baseline (integridade + tabelas críticas + ledger + jogador) — GLOBAL
#    e POR FIXTURE — e confere a fixture contra os números que ela ESCOLHEU;
# 4. simula perda/corrupção do original;
# 5. restaura o backup em base SEPARADA (nunca por cima de banco real);
# 6. valida integridade + dados + abertura pelo gate da aplicação e expurga a
#    fixture, para o re-run partir limpo.
# Só opera em diretório temporário; o live.db de teste nunca é escrito aqui (a
# fixture vive no banco de TESTE do sandbox e sai dele no fim, expurgada).
# Usage: godot --headless --path . -s tests/backup_full_restore_test.gd
# Exit code = nº de checks falhos: é o contrato de `scripts/ci_gate_log.sh`, que lê a
# contagem DA LINHA DE RESULTADO e confere o exit code à parte. Nome do arquivo importa:
# `scripts/test.sh` auto-inscreve todo `tests/*_test.gd` como gate próprio (gates_extra),
# e era exatamente o que este harness de 184 linhas não era — régua sem efeito.
#
# Por que a fixture existe (o defeito que ela fechou): sem semear dados, o harness
# provava o restore de um banco VAZIO. Num XDG_DATA_HOME limpo a base sobe sem
# personagem nenhum, `player[0]` estourava em :198 e, quando não estourava, cada
# "conferem" comparava zero com zero. Restauração de nada não é restauração.

# ------------------------------------------------------------------ fixture
# Tudo pendura do prefixo `bfr_` e nada mais, então o expurgo no fim alcança o
# que o harness criou (e um ghost de run abortado). Os valores abaixo SÃO a
# régua: as asserções comparam contra eles, não contra "o que estiver lá".
const FixUser : String = "bfr_restore"
const FixEmail : String = "bfr_restore@backup.test.local"
const FixPass : String = "bfr-senha-de-teste-1"
const FixIp : String = "203.0.113.77"
const FixNick : String = "BfrRestore"
const FixLevel : int = 7
const FixXp : int = 4321
const FixGp : int = 12345
# Gems: crédito do faucet E um débito, para a soma por kind e a contagem de linhas
# valerem alguma coisa — um restore que perdesse uma linha muda as duas juntas.
const FixGemsFaucet : int = 600
const FixGemsSpend : int = -100
const FixGemsNet : int = 500
const FixGoldFaucet : int = FixGp
const FixLedgerRows : int = 3
const FixReasonFaucet : String = "faucet:ad"
const FixReasonSpend : String = "spend:pagas"
const FixReasonGold : String = "faucet:bfr_fixture"

var _fails : int = 0
var _checks : int = 0
var _dbScript : GDScript = null
# {"ok": bool, "account_id": int, "char_id": int, "why": String}
var _fixture : Dictionary = {}

func _note(ok : bool, label : String) -> void:
    _checks += 1
    print(("  [ok] " if ok else "  [FAIL] ") + label)
    if not ok:
        _fails += 1

# Toda saída passa daqui, inclusive as que desistem no meio: um `quit(1)` sem linha de
# resultado faz o gate reclamar "run não terminou" e não dizer qual check faltou. Um
# FATAL é contabílizado como check falho por quem chama (o `_note(false, ...)` antes).
func _finish() -> void:
    if _dbScript != null and (_dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
        print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
        _dbScript.call("DrainPendingPreloads")
    print("== RESULT: %d checks, %d failures ==" % [_checks, _fails])
    quit(_fails)

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

# ------------------------------------------------------------------ fixture
# Leitura escopada na conta da fixture: é isso que dá conteúdo ao "conferem" —
# o `char_id`/`account_id` são AUTOINCREMENT e nunca são reusados, então as
# linhas de ledger de um ghost expurgado não poluem a soma da fixture nova.
func _fxRows(db : SQLite, accountID : int) -> int:
    return _one_int(db, "SELECT COUNT(*) FROM ledger_transaction WHERE account_id = %d;" % accountID)

func _fxSum(db : SQLite, accountID : int, kind : String) -> int:
    return _one_int(db, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE account_id = %d AND kind='%s';" % [accountID, kind])

func _fxWalletGems(db : SQLite, accountID : int) -> int:
    return _one_int(db, "SELECT COALESCE(gems,0) FROM wallet WHERE account_id = %d;" % accountID)

func _fxStat(db : SQLite, charID : int) -> Array:
    var rows : Array = []
    if db.query("SELECT level, experience, gp FROM stat WHERE char_id = %d;" % charID):
        rows = db.query_result
    return rows

func _fxChar(db : SQLite, charID : int) -> Array:
    var rows : Array = []
    if db.query("SELECT char_id, nickname, account_id FROM character WHERE char_id = %d;" % charID):
        rows = db.query_result
    return rows

# Expurga o que o harness criou, pelas APIs de produção: `RemoveCharacter` dispara
# o trg_character_delete, que desde a migration 066 leva junto o que pendura no
# `char_id` (ficha, inventário, baús, habilidades, quests, bestiário e anúncios) e
# `RemoveAccount` o trg_account_delete. O ledger NÃO sai — append-only por trigger
# (`ledger_transaction_no_delete`, migration 009) — e é por isso que a asserção de
# ledger é por conta recém-nascida, nunca global.
func _purgeFixture(sql : Node) -> void:
    if sql == null or not sql.isInitialized:
        return
    var accountID : int = int(sql.GetAccountID(FixUser))
    if accountID <= 0:
        return
    for charID in sql.GetCharacterIDsForAccount(accountID):
        sql.RemoveCharacter(int(charID))
    sql.DeleteRowsRaw("wallet", "account_id = %d" % accountID)
    sql.RemoveAccount(accountID)

func _fixtureGone(sql : Node) -> bool:
    if sql == null or not sql.isInitialized:
        return false
    return int(sql.GetAccountID(FixUser)) <= 0 and int(sql.GetCharacterIDByName(FixNick)) <= 0

# Semeia pelo caminho legítimo — nada de INSERT escrito à mão contra um schema
# triggerado (a linha de `stat`/`trait`/`attribute` nasce do trg_character_new,
# quem insere na mão está adivinhando). Reuso só quando a fixture do sandbox
# anterior já está ÍNTEGRA (mesmo level/xp/gp e mesmo par de ledger); qualquer
# ghost parcial sai e dá lugar a uma fixture nova.
# Retorna {"ok", "account_id", "char_id", "why"}.
func _seedFixture(sql : Node, eco : Node, netCommons : GDScript, actorCommons : GDScript) -> Dictionary:
    _purgeFixture(sql)
    if not bool(sql.AddAccount(FixUser, FixPass, FixEmail, String(netCommons.AgreementTosVersion), String(netCommons.AgreementPrivacyVersion), FixIp)):
        return {"ok": false, "account_id": -1, "char_id": -1, "why": "AddAccount recusa"}
    var accountID : int = int(sql.GetAccountID(FixUser))
    if accountID <= 0:
        return {"ok": false, "account_id": -1, "char_id": -1, "why": "GetAccountID não achou a conta criada"}
    if not bool(sql.AddCharacter(accountID, FixNick, actorCommons.DefaultStats, actorCommons.DefaultTraits, actorCommons.DefaultAttributes)):
        return {"ok": false, "account_id": accountID, "char_id": -1, "why": "AddCharacter recusa"}
    var charID : int = int(sql.GetCharacterID(accountID, FixNick))
    if charID <= 0:
        return {"ok": false, "account_id": accountID, "char_id": -1, "why": "GetCharacterID não achou o personagem"}
    # Carteira/ledger pelo single-writer da economia (invariante 1: wallet.gems é
    # a fonte de verdade e o ledger espelha cada movimento).
    if not bool(eco.AddGems(accountID, FixGemsFaucet, FixReasonFaucet)):
        return {"ok": false, "account_id": accountID, "char_id": charID, "why": "AddGems faucet recusou"}
    if not bool(eco.AddGems(accountID, FixGemsSpend, FixReasonSpend)):
        return {"ok": false, "account_id": accountID, "char_id": charID, "why": "AddGems spend recusou"}
    # Gold mora em stat.gp e só tem UM writer: MoveGold grava o stat e espelha no
    # ledger kind='gold' na mesma transação.
    if not bool(eco.MoveGold(charID, FixGoldFaucet, FixReasonGold)):
        return {"ok": false, "account_id": accountID, "char_id": charID, "why": "MoveGold recusou"}
    if not bool(sql.UpdateStatDirect(charID, FixLevel, FixXp, FixGp)):
        return {"ok": false, "account_id": accountID, "char_id": charID, "why": "UpdateStatDirect falhou"}
    return {"ok": true, "account_id": accountID, "char_id": charID, "why": ""}

func _run():
    print("== Backup Full Restore (beta fechado) ==")
    var launcher: Node = _getAutoload("Launcher")
    if launcher == null:
        _note(false, "FATAL: Launcher autoload missing")
        _finish()
        return
    var waited: int = 0
    var sqlNode: Node = null
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        sqlNode = launcher.SQL
        if sqlNode != null and sqlNode.isInitialized:
            break
    # `DB.isInitialized` é o marcador dos ~330 presets que `DB.Preload()` pede a
    # `ResourceLoader.load_threaded_request()` (sources/db/DB.gd:218). SQL inicializado
    # NÃO implica dreno: sem esperar aqui, o `load("res://sources/sql/SQLBackups.gd")`
    # abaixo e o `quit()` caem no meio de parses que rodam em thread de trabalho — a
    # corrida que já deixou gate vermelho com checks verdes em máquina carregada, escrita
    # duas vezes no produto (DB.gd:232 e Launcher.gd:254). Mesmo probe dos irmãos
    # (tests/social_fix_test.gd:87, tests/run_idle_tests.gd:85).
    _dbScript = load("res://sources/db/DB.gd")
    var dbReady : bool = false
    for dbTick in 40:
        if _dbScript != null and bool(_dbScript.get("isInitialized")):
            dbReady = true
            break
        await create_timer(0.25).timeout
    _note(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit")

    # Beta fechado: script -s duck-typed (ver run_idle_tests.gd) — sem refs
    # estáticas a classes do projeto (compile antes dos autoloads quebra).
    var sql : Node = launcher.SQL
    if sql == null or not sql.isInitialized:
        _note(false, "FATAL: SQL not initialized within timeout")
        _finish()
        return

    # A fixture passa pela economia real, então o serviço tem de estar de pé.
    var eco : Node = launcher.Economy
    var ecoWaited : int = 0
    while (eco == null or not bool(eco.isInitialized)) and ecoWaited < 20000:
        await create_timer(0.25).timeout
        ecoWaited += 250
        eco = launcher.Economy
    _note(eco != null and bool(eco.isInitialized), "Economy pronto p/ semear ledger (waited %d ms)" % ecoWaited)
    if eco == null or not bool(eco.isInitialized):
        _note(false, "FATAL: Economy not initialized within timeout")
        _finish()
        return

    var netCommons : GDScript = load("res://sources/network/NetworkCommons.gd")
    var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
    if netCommons == null or actorCommons == null:
        _note(false, "FATAL: commons da fixture (NetworkCommons/ActorCommons) não compilam")
        _finish()
        return

    _fixture = _seedFixture(sql, eco, netCommons, actorCommons)
    _note(bool(_fixture.get("ok", false)), "fixture bfr_ semeada pela API de produção (%s)" % str(_fixture.get("why", "?")))
    if not bool(_fixture.get("ok", false)):
        _purgeFixture(sql)
        _note(false, "FATAL: sem fixture não há restore aferível")
        _finish()
        return
    var fixAccount : int = int(_fixture["account_id"])
    var fixChar : int = int(_fixture["char_id"])
    print("fixture: account=%d char=%d level=%d xp=%d gp=%d gems=%d ledger_rows=%d" % [
        fixAccount, fixChar, FixLevel, FixXp, FixGp, FixGemsNet, FixLedgerRows])

    var work : String = OS.get_temp_dir().rstrip("/") + "/shambleta_restore_test/"
    if DirAccess.make_dir_recursive_absolute(work) != OK:
        _note(false, "FATAL: cannot create work dir " + work)
        _purgeFixture(sql)
        _finish()
        return
    var original : String = work + "original.db"
    var backup : String = work + "backup.db"
    var restored : String = work + "restored.db"
    for f in [original, backup, restored]:
        if FileAccess.file_exists(f):
            DirAccess.remove_absolute(f)

    # 1. snapshot da base via o próprio mecanismo (backup_to, como CreateDailyBackup)
    var snap : SQLite = _open(sql.db.path)
    _note(snap != null, "live test db abre para snapshot")
    if snap == null:
        _purgeFixture(sql)
        _finish()
        return
    _note(snap.backup_to(original), "snapshot consistente via backup_to")
    snap.close_db()
    # trava a base de trabalho contra escritas do server durante o teste:
    # (o teste só lê/escreve cópias em work/, nunca o live)
    var src : SQLite = _open(original)
    _note(src != null, "cópia de trabalho abre")
    if src == null:
        _purgeFixture(sql)
        _finish()
        return

    # 2. baseline: integridade + registros críticos + ledger + jogador
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
    # Zero não é versão: o snapshot tem de carregar o número que o próprio
    # serviço lê do live, senão "confere" com uma base sem schema aplicado.
    _note(int(base["migration"]) > 0 and int(base["migration"]) == int(sql.GetVersion()),
        "migration do snapshot é a vigente do live (%d)" % int(base["migration"]))
    _note(int(base["accounts"]) > 0, "há contas na base (%d)" % int(base["accounts"]))
    _note(int(base["characters"]) > 0, "há personagens na base (%d)" % int(base["characters"]))

    # Baseline DA FIXTURE no instantâneo — os números que o fixture escolheu,
    # medidos na cópia de trabalho (é contra ela que a restaurada confere).
    var baseFix : Dictionary = {
        "rows": _fxRows(src, fixAccount),
        "gems": _fxSum(src, fixAccount, "gems"),
        "gold": _fxSum(src, fixAccount, "gold"),
        "wallet": _fxWalletGems(src, fixAccount),
    }
    _note(int(baseFix["rows"]) == FixLedgerRows, "fixture: ledger tem as %d linhas escolhidas (%d)" % [FixLedgerRows, int(baseFix["rows"])])
    _note(int(baseFix["gems"]) == FixGemsNet, "fixture: soma gems = %d líquido (crédito %d + débito %d) e não zero (%d)" % [FixGemsNet, FixGemsFaucet, FixGemsSpend, int(baseFix["gems"])])
    _note(int(baseFix["gold"]) == FixGp, "fixture: soma gold = %d escolhido (%d)" % [FixGp, int(baseFix["gold"])])
    _note(int(baseFix["wallet"]) == FixGemsNet, "fixture: wallet.gems = %d escolhido (%d)" % [FixGemsNet, int(baseFix["wallet"])])

    var player : Array = _fxChar(src, fixChar)
    _note(not player.is_empty() and str(player[0]["nickname"]) == FixNick and int(player[0]["account_id"]) == fixAccount,
        "linha de jogador legível (%s / conta %d)" % [FixNick, fixAccount])
    var player_stat : Array = _fxStat(src, fixChar)
    _note(not player_stat.is_empty() and int(player_stat[0]["level"]) == FixLevel \
        and int(player_stat[0]["experience"]) == FixXp and int(player_stat[0]["gp"]) == FixGp,
        "stat legível bate com o que a fixture escolheu (level=%d xp=%d gp=%d)" % [FixLevel, FixXp, FixGp])
    print("baseline: migration=%d accounts=%d chars=%d ledger_rows=%d gems_sum=%d gold_sum=%d wallet_gems=%d | fixture rows=%d gems=%d gold=%d wallet=%d" % [
        int(base["migration"]), int(base["accounts"]), int(base["characters"]),
        int(base["ledger_rows"]), int(base["ledger_gems"]), int(base["ledger_gold"]),
        int(base["wallet_gems"]), int(baseFix["rows"]), int(baseFix["gems"]),
        int(baseFix["gold"]), int(baseFix["wallet"])])

    # 3. backup da cópia de trabalho pelo mecanismo real
    _note(src.backup_to(backup), "backup executado via backup_to")
    src.close_db()
    var backup_size : int = _file_size(backup)
    _note(backup_size > 0, "backup criado com tamanho > 0 (%d bytes)" % backup_size)
    print("backup: %s (%d bytes)" % [backup, backup_size])

    # 4. simula perda/corrupção do original
    _note(DirAccess.remove_absolute(original) == OK, "original removido (perda simulada)")
    var garbage : FileAccess = FileAccess.open(original, FileAccess.WRITE)
    if garbage == null:
        _note(false, "FATAL: não deu para corromper o original em " + original)
        _purgeFixture(sql)
        _finish()
        return
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
        _purgeFixture(sql)
        _finish()
        return
    _note(_one_str(dst, "PRAGMA integrity_check;") == "ok", "integridade da restaurada ok")
    _note(_one_int(dst, "SELECT version FROM migration LIMIT 1;") == int(base["migration"]), "migration version confere")
    _note(_one_int(dst, "SELECT COUNT(*) FROM account;") == int(base["accounts"]), "contas conferem (%d)" % int(base["accounts"]))
    _note(_one_int(dst, "SELECT COUNT(*) FROM character;") == int(base["characters"]), "personagens conferem")
    _note(_one_int(dst, "SELECT COUNT(*) FROM ledger_transaction;") == int(base["ledger_rows"]), "ledger: linhas conferem")
    _note(_one_int(dst, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gems';") == int(base["ledger_gems"]), "ledger: soma gems confere")
    _note(_one_int(dst, "SELECT COALESCE(SUM(amount),0) FROM ledger_transaction WHERE kind='gold';") == int(base["ledger_gold"]), "ledger: soma gold confere")
    _note(_one_int(dst, "SELECT COALESCE(SUM(gems),0) FROM wallet;") == int(base["wallet_gems"]), "wallet: estoque gems confere")

    # 5b. as MESMAS leituras, agora escopadas na fixture: confere contra o instantâneo
    # E contra o número escolhido, de modo que uma restauração de banco vazio não passa
    # nem aqui nem no bloco global acima.
    _note(_one_int(dst, "SELECT COUNT(*) FROM account WHERE account_id = %d;" % fixAccount) == 1, "restaurada tem a conta da fixture (%d)" % fixAccount)
    _note(_one_int(dst, "SELECT COUNT(*) FROM character WHERE char_id = %d;" % fixChar) == 1, "restaurada tem o personagem da fixture (%d)" % fixChar)
    _note(_fxRows(dst, fixAccount) == int(baseFix["rows"]) and _fxRows(dst, fixAccount) == FixLedgerRows, "restaurada: %d linhas de ledger da fixture conferem" % FixLedgerRows)
    _note(_fxSum(dst, fixAccount, "gems") == int(baseFix["gems"]) and _fxSum(dst, fixAccount, "gems") == FixGemsNet, "restaurada: soma gems da fixture confere com %d" % FixGemsNet)
    _note(_fxSum(dst, fixAccount, "gold") == int(baseFix["gold"]) and _fxSum(dst, fixAccount, "gold") == FixGp, "restaurada: soma gold da fixture confere com %d" % FixGp)
    _note(_fxWalletGems(dst, fixAccount) == int(baseFix["wallet"]) and _fxWalletGems(dst, fixAccount) == FixGemsNet, "restaurada: wallet.gems da fixture confere com %d" % FixGemsNet)

    var rst : Array = _fxStat(dst, fixChar)
    _note(not rst.is_empty() and not player_stat.is_empty() \
        and int(rst[0]["level"]) == int(player_stat[0]["level"]) \
        and int(rst[0]["experience"]) == int(player_stat[0]["experience"]) \
        and int(rst[0]["gp"]) == int(player_stat[0]["gp"]) \
        and int(rst[0]["level"]) == FixLevel and int(rst[0]["gp"]) == FixGp \
        and int(rst[0]["experience"]) == FixXp,
        "dados do jogador conferem com a fixture (level=%d xp=%d gp=%d)" % [FixLevel, FixXp, FixGp])
    dst.close_db()

    for f in [original, backup, restored]:
        DirAccess.remove_absolute(f)
    print("work dir limpo; live.db de teste intocado (só leitura p/ snapshot)")

    # 6. expurgo: a fixture é do harness, não fica no caminho do próximo run.
    _purgeFixture(sql)
    _note(_fixtureGone(sql), "fixture expurgada do live (re-run parte limpo)")

    print("  [info] backup %d bytes, %d contas, %d chars, %d linhas ledger verificadas (fixture: %d linhas / %d gems / %d gold)" % [
        backup_size, int(base["accounts"]), int(base["characters"]), int(base["ledger_rows"]),
        FixLedgerRows, FixGemsNet, FixGp])
    _finish()

func _initialize():
    _run()
