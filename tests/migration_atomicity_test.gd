extends SceneTree

# P0-STAMP — o carimbo de migration é fail-closed?
#
# Uso:    godot --headless --path . -s tests/migration_atomicity_test.gd
#         (`scripts/test.sh` auto-inscreve todo `tests/*_test.gd` como gate próprio.)
# Saída:  "== RESULT: <n> checks, <m> failures =="   (exit code = nº de falhas)
#
# O defeito que este harness fecha (dois juízes cegos apontaram o mesmo, e foi o
# motivo de DevOps e Segurança não passarem de 9): `SQL.ApplyMigrations()` rodava
# `ApplyMigration(patches[i])` com o retorno de `Query()` JOGADO FORA e
# `SetVersion(currentVersion)` no fim do laço, incondicional. Um patch que
# estourasse no SQLite — `ALTER TABLE` em tabela que ainda não existe, lock
# timeout, coluna duplicada — era estampado como aplicado, e no boot seguinte não
# rodava de novo: o objeto de schema nunca existiu (as tabelas do dinheiro vivem
# nesses patches), a versão dizia o contrário, e a única pista era um `push_error`
# no log do container que ninguém pagina.
#
# As três réguas, na ordem do pedido:
#   1. patch que SUCEDE anda com a versão;
#   2. patch que FALHA NÃO anda com a versão (para ali) e é observável — contador,
#      índice do patch travado e `stalled` expostos em runtime, não só no log;
#   3. consertada a causa, o MESMO patch roda de novo (não foi pulado). É esta que
#      separa conserto de cosmético: sem carimbar patch a patch, "parar" significaria
#      reaplicar os vizinhos que já passaram, e o boot seguinte empurraria o erro.
#   4. atomicidade de verdade: o patch que falha no meio não deixa metade dos
#      objetos criados (ROLLBACK), porque "parar na versão anterior" só é verdade
#      se o schema também parou.
#   5. os três guards do plano (`empty`/`stale`/`uptodate`) seguem vivos e param de
#      ser silêncio: viram estado lido pelo `/metrics`.
#
# Bancos e patches: NUNCA o `live.db`/`testing.db` nem o `data/conf/migrations/`
# real. Tudo vive em `/tmp/migq-atomicity/`, um diretório próprio deste harness, e
# o caminho entra pelo seam `SQL.migrationDir` (mesma ideia do seam
# `MetricsServer.telemetryService`), alimentado por `SHAMBLETA_MIGRATIONS_DIR` na
# produção. A base é cópia do template de bootstrap.
#
# Nada de `load()` em cascata nem de `class_name` do projeto como identificador
# global: com `-s` eles ainda não estão registrados quando este arquivo compila,
# e Parse Error de arquivo alheio é exatamente o que `scripts/ci_gate_log.sh`
# rejeita. `SQLite` é classe nativa da extensão, essa sim disponível.

const Scratch : String			= "/tmp/migq-atomicity"
const MigDir : String			= Scratch + "/migrations"
const MigUrl : String			= MigDir + "/"
const EmptyDir : String			= Scratch + "/empty"
const EmptyUrl : String			= EmptyDir + "/"
const VazioDir : String			= Scratch + "/unreadable"
const VazioUrl : String			= VazioDir + "/"
const DbMain : String			= Scratch + "/migq.db"
const DbVazio : String			= Scratch + "/vazio.db"
const DbReal : String			= Scratch + "/real.db"
const TemplateDb : String		= "res://data/conf/templates/sqlite.template.db"
const RealMigrations : String	= "res://data/conf/migrations/"

# As versões são a régua, não "o que estiver lá": 001 passa, 002 explode no meio,
# 003 e 004 não chegam a rodar.
const GoodPatches : int			= 1
const AllPatches : int			= 4

const PatchAlpha : String		= """CREATE TABLE migq_alpha (id INTEGER PRIMARY KEY, note TEXT);
INSERT INTO migq_alpha (id, note) VALUES (1, 'alpha');
"""
# Válido, válido, INVÁLIDO: as duas primeiras statements precisariam virar schema
# antes do erro para este patch distinguir "parou" de "parou com metade".
const PatchBoom : String		= """CREATE TABLE migq_partial (id INTEGER PRIMARY KEY);
INSERT INTO migq_partial (id) VALUES (1);
ALTER TABLE migq_missing_table ADD COLUMN broken INTEGER;
"""
const PatchFixed : String		= """CREATE TABLE migq_partial (id INTEGER PRIMARY KEY);
INSERT INTO migq_partial (id) VALUES (1);
"""
const PatchGamma : String		= "CREATE TABLE migq_gamma (id INTEGER PRIMARY KEY);\n"
# Os patches reais 001/002/003/008 trazem o próprio `BEGIN TRANSACTION`. Envelopar
# um deles seria "cannot start a transaction within a transaction" — este arquivo
# é a contraprova de que a detecção não envelopa o que já é transação.
const PatchOwnTxn : String		= """BEGIN TRANSACTION;
CREATE TABLE migq_own (id INTEGER PRIMARY KEY);
COMMIT;
"""

var checks : int = 0
var failures : int = 0
var sqlScript : GDScript = null
# Serviços criados por este harness, para o teardown alcançar todos.
var _services : Array[Node] = []
var _files : PackedStringArray = []

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if condition:
		print("  [ok] " + label)
	else:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func Note(text : String) -> void:
	print("  . " + text)

func _Int(source : Dictionary, key : String) -> int:
	return int(source.get(key, 0))

func _Str(source : Dictionary, key : String) -> String:
	return String(source.get(key, ""))

# ------------------------------------------------------------------ disco
func _Write(path : String, text : String) -> bool:
	var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	_files.append(path)
	return true

func _Read(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

func _DbHandle(path : String) -> SQLite:
	var handle : SQLite = SQLite.new()
	handle.path = path
	handle.verbosity_level = SQLite.QUIET
	if not handle.open_db():
		return null
	return handle

func _Scalar(handle : SQLite, statement : String) -> Variant:
	if handle == null or not handle.query(statement):
		return null
	var rows : Array = handle.query_result
	if rows.is_empty():
		return null
	return (rows[0] as Dictionary).values()[0]

func _Count(handle : SQLite, statement : String) -> int:
	var value : Variant = _Scalar(handle, statement)
	return int(value) if value != null else 0

func _HasTable(handle : SQLite, table : String) -> bool:
	return _Count(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='%s';" % table) > 0

# ------------------------------------------------------------------ serviço
# Um `SQLService` por boot simulado: estado novo, como o processo que reinicia.
# Cada handle de conexão vive no serviço e é fechado junto dele no teardown.
func _Service(dbPath : String, migrationsDir : String) -> Node:
	var handle : SQLite = _DbHandle(dbPath)
	if handle == null:
		return null
	var svc : Node = sqlScript.new()
	svc.set("db", handle)
	svc.set("isInitialized", true)
	svc.set("migrationDir", migrationsDir)
	_services.append(svc)
	return svc

func _Stats(svc : Node) -> Dictionary:
	var raw : Variant = svc.call("MigrationStats")
	var out : Dictionary = {}
	if raw is Dictionary:
		out = raw
	return out

func _StampedVersion(dbPath : String) -> int:
	# Leitura por UMA NOVA conexão: prova que o número está no arquivo e vale para
	# o próximo processo, não apenas na memória de quem aplicou.
	var handle : SQLite = _DbHandle(dbPath)
	if handle == null:
		return -1
	var value : Variant = _Scalar(handle, "SELECT version FROM migration LIMIT 1;")
	handle.close_db()
	return int(value) if value != null else -1

# ------------------------------------------------------------------ suite
func _run() -> void:
	print("== Migration atomicity (carimbo fail-closed) ==")
	sqlScript = load("res://sources/sql/SQL.gd")
	if not Check(sqlScript != null, "sources/sql/SQL.gd compila e carrega"):
		_finish()
		return
	if not Check(DirAccess.make_dir_recursive_absolute(MigDir) == OK \
			and DirAccess.make_dir_recursive_absolute(EmptyDir) == OK \
			and DirAccess.make_dir_recursive_absolute(VazioDir) == OK,
			"scratch criado em %s (nada toca no live.db nem em data/conf/migrations)" % Scratch):
		_finish()
		return

	if not Check(_Write(MigDir + "/001_alpha.sql", PatchAlpha) \
			and _Write(MigDir + "/002_boom.sql", PatchBoom) \
			and _Write(MigDir + "/003_gamma.sql", PatchGamma) \
			and _Write(MigDir + "/004_own.sql", PatchOwnTxn) \
			and _Write(VazioDir + "/001_vazio.sql", ""),
			"patches escritos: 001 válido, 002 inválido no meio, 003/004 atrás dele, 001 vazio na outra árvore"):
		_finish()
		return

	var tpl : String = ProjectSettings.globalize_path(TemplateDb)
	if not Check(DirAccess.copy_absolute(tpl, DbMain) == OK and DirAccess.copy_absolute(tpl, DbVazio) == OK \
			and DirAccess.copy_absolute(tpl, DbReal) == OK,
			"base de trabalho = cópia do template de bootstrap (nunca a base real)"):
		_finish()
		return

	# O template vem com `migration.version = 1` e o patch 001 JÁ está nele; zerar
	# a versão é o que faz o índice 0 deste diretório também ser aplicado, e deixa
	# a régua em números que o harness escreve (GoodPatches/AllPatches).
	var seed : SQLite = _DbHandle(DbMain)
	var seedVazio : SQLite = _DbHandle(DbVazio)
	var stamped : bool = seed != null and seed.query("UPDATE migration SET version = 0;")
	stamped = stamped and seedVazio != null and seedVazio.query("UPDATE migration SET version = 0;")
	if seed != null:
		seed.close_db()
	if seedVazio != null:
		seedVazio.close_db()
	if not Check(stamped, "versão da base zerada nas duas mesas de trabalho (índice 0 passa a contar)"):
		_finish()
		return

	_suiteStopsAndObserves()
	_suiteRerunAppliesTheFailedPatch()
	_suiteUnreadablePatch()
	_suitePlanGuards()
	_suiteRealTree()
	_suiteRealBoot()
	_suiteObservability()
	_finish()

# 1 + 2 + 4: o patch que passa anda; o que falha para a sequência, não carimba,
# não deixa metade do schema e é observado.
func _suiteStopsAndObserves() -> void:
	print("-- A) patch válido anda; patch inválido PARA e não é estampado")
	var svc : Node = _Service(DbMain, MigUrl)
	if not Check(svc != null, "SQLService de trabalho sobe sobre a base copiada"):
		return
	var handle : SQLite = svc.get("db")
	svc.call("ApplyMigrations")
	var stats : Dictionary = _Stats(svc)

	Check(_Int(stats, "version") == GoodPatches,
		"1a) a versão ANDOU com o patch que succeeded (%d esperado, %d medido)" % [GoodPatches, _Int(stats, "version")])
	Check(_StampedVersion(DbMain) == GoodPatches,
		"1b) o carimbo está no ARQUIVO e é lido por outra conexão (%d)" % _StampedVersion(DbMain))
	Check(_HasTable(handle, "migq_alpha"), "1c) o objeto do patch que passou existe no schema")

	Check(_Int(stats, "version") != AllPatches and _StampedVersion(DbMain) != AllPatches,
		"2a) a versão NÃO pulou por cima da falha (base em %d, diretorio com %d patches)" % [_StampedVersion(DbMain), AllPatches])
	Check(_Int(stats, "failures") == 1, "2b) a falha é CONTADA (migrationFailures=%d)" % _Int(stats, "failures"))
	Check(_Int(stats, "failedPatch") == 1, "2c) o ÍNDICE do patch travado é exposto (%d)" % _Int(stats, "failedPatch"))
	Check(_Str(stats, "failedFile").ends_with("002_boom.sql"),
		"2d) o arquivo travado é nomeado (%s)" % _Str(stats, "failedFile"))
	Check(_Str(stats, "error").to_lower().contains("migq_missing_table"),
		"2e) a causa crua do SQLite fica exposta (%s)" % _Str(stats, "error"))
	Check(_Str(stats, "plan") == "failed", "2f) o plano do boot diz \"failed\", não \"apply\"")
	Check(bool(stats.get("stalled", false)), "2g) `stalled` = 1: há patch visível sem carimbo")
	Check(bool(svc.call("MigrationBlocked")),
		"2g2) o MESMO serviço que diz stalled devolve MigrationBlocked() = true (a porta lê este objeto)")
	Check(not _HasTable(handle, "migq_gamma") and not _HasTable(handle, "migq_own"),
		"2h) os patches depois da falha não foram tentados (parar, nao pular)")
	Check(not _HasTable(handle, "migq_partial"),
		"4) o patch que falhou no meio nao deixou metade do schema (ROLLBACK): migq_partial nao existe")
	Check(_StampedVersion(DbMain) == GoodPatches,
		"4b) e a versao continua no ultimo patch que REALMENTE virou schema")

# 3: consertada a causa, o mesmo patch roda — o que torna o conserto real.
func _suiteRerunAppliesTheFailedPatch() -> void:
	print("-- B) causa consertada: o boot seguinte aplica o que tinha falhado")
	if not Check(_Write(MigDir + "/002_boom.sql", PatchFixed), "002_boom.sql reescrito sem a statement inválida"):
		return
	var svc : Node = _Service(DbMain, MigUrl)
	if not Check(svc != null, "novo processo sobre a MESMA base (boot seguinte)"):
		return
	var handle : SQLite = svc.get("db")
	svc.call("ApplyMigrations")
	var stats : Dictionary = _Stats(svc)

	Check(_Int(stats, "failures") == 0, "B1) o retry não herdou falha nova (failures=%d)" % _Int(stats, "failures"))
	Check(_Int(stats, "failedPatch") == -1, "B2) nenhum patch travado agora (-1 esperado)")
	Check(not bool(stats.get("stalled", true)), "B3) `stalled` = 0: diretório e base batem")
	Check(_StampedVersion(DbMain) == AllPatches,
		"B4) a versão chegou a %d: o 002 que falhou RODOU, não foi pulado" % AllPatches)
	Check(_HasTable(handle, "migq_partial"), "B5) o objeto do antigo patch falho existe agora")
	Check(_HasTable(handle, "migq_gamma"), "B6) o 003 que estava atrás dele também rodou")
	Check(_HasTable(handle, "migq_own"),
		"B7) patch com o próprio BEGIN TRANSACTION aplica sem dupla transação (detecção não envelopou)")
	svc.call("ApplyMigrations")
	Check(_StampedVersion(DbMain) == AllPatches and String(_Stats(svc).get("plan", "")) == "uptodate",
		"B8) rerun idempotente: plano `uptodate` não reescreve nada (base em %d)" % _StampedVersion(DbMain))

# Um arquivo que não leu não é "patch vazio": é patch que não virou schema.
func _suiteUnreadablePatch() -> void:
	print("-- C) patch ilegível/vazio não é estampado")
	var svc : Node = _Service(DbVazio, VazioUrl)
	if not Check(svc != null, "SQLService sobre a segunda base com um patch vazio"):
		return
	svc.call("ApplyMigrations")
	var stats : Dictionary = _Stats(svc)
	Check(_Int(stats, "version") == 0, "C1) a versão não andou (%d)" % _Int(stats, "version"))
	Check(_StampedVersion(DbVazio) == 0, "C2) e o arquivo também não (lido por outra conexão)")
	Check(_Int(stats, "failures") == 1 and _Int(stats, "failedPatch") == 0,
		"C3) falha contada no índice 0 (failures=%d, patch=%d)" % [_Int(stats, "failures"), _Int(stats, "failedPatch")])
	Check(_Str(stats, "error").contains("vazio"), "C4) o motivo diz que o arquivo não leu nada")

# Os três guards do plano continuam decidindo o boot — e agora falam.
func _suitePlanGuards() -> void:
	print("-- D) empty / stale / uptodate preservados e observáveis")
	Check(String(sqlScript.call("MigrationPlan", 0, 0)) == "empty", "D1) MigrationPlan(0,0) = empty")
	Check(String(sqlScript.call("MigrationPlan", 2, 5)) == "stale", "D2) MigrationPlan(2,5) = stale")
	Check(String(sqlScript.call("MigrationPlan", 4, 4)) == "uptodate", "D3) MigrationPlan(4,4) = uptodate")
	Check(String(sqlScript.call("MigrationPlan", 5, 4)) == "apply", "D4) MigrationPlan(5,4) = apply")

	var svc : Node = _Service(DbMain, EmptyUrl)
	if not Check(svc != null, "serviço com diretório de patches VAZIO"):
		return
	var before : int = _StampedVersion(DbMain)
	svc.call("ApplyMigrations")
	var stats : Dictionary = _Stats(svc)
	Check(_Str(stats, "plan") == "empty" and bool(stats.get("stalled", false)),
		"D5) `empty` não é mais silêncio: plano vazio + stalled=1 (%s)" % _Str(stats, "plan"))
	Check(_StampedVersion(DbMain) == before, "D6) `empty` não reescreve a versão da base (%d)" % before)

	var staleSvc : Node = _Service(DbMain, MigUrl)
	if not Check(staleSvc != null, "serviço para o caso stale"):
		return
	# Binário mais velho que o schema (rollback de deploy): apago os patches 003 e
	# 004 do diretório de trabalho, a base fica em 4 e só restam 2.
	_files.erase(MigDir + "/003_gamma.sql")
	_files.erase(MigDir + "/004_own.sql")
	if not Check(DirAccess.remove_absolute(MigDir + "/003_gamma.sql") == OK \
			and DirAccess.remove_absolute(MigDir + "/004_own.sql") == OK,
			"diretório reduzido a 2 patches contra uma base na versão 4"):
		return
	var kept : int = _StampedVersion(DbMain)
	staleSvc.call("ApplyMigrations")
	var staleStats : Dictionary = _Stats(staleSvc)
	Check(_Str(staleStats, "plan") == "stale" and bool(staleStats.get("stalled", false)),
		"D7) `stale` (binário velho que o schema) virou sinal: plan=%s stalled=%s" % [_Str(staleStats, "plan"), str(bool(staleStats.get("stalled", false)))])
	Check(_StampedVersion(DbMain) == kept,
		"D8) e a versão da base não desceu nem subiu por esse caminho (%d)" % _StampedVersion(DbMain))
	_Write(MigDir + "/003_gamma.sql", PatchGamma)
	_Write(MigDir + "/004_own.sql", PatchOwnTxn)

# A premissa do envelopamento em transação, conferida nos patches REAIS: nada do
# que roda em produção pode correr fora de transação. Um `VACUUM`/`PRAGMA` num
# patch futuro tem que ser pego aqui, não num boot de produção.
func _suiteRealTree() -> void:
	print("-- E) contrato com data/conf/migrations de verdade")
	var dir : DirAccess = DirAccess.open(RealMigrations)
	if not Check(dir != null, "%s é legível" % RealMigrations):
		return
	var count : int = 0
	var broken : String = ""
	var risky : String = ""
	var unbalanced : String = ""
	for file in dir.get_files():
		var stem : String = String(file).get_slice(".remap", 0)
		if not stem.ends_with(".sql"):
			continue
		count += 1
		var body : String = _Read(RealMigrations.path_join(stem))
		if body.is_empty():
			broken = stem
			break
		var upper : String = body.to_upper()
		if upper.contains("VACUUM") or upper.contains("PRAGMA"):
			risky += stem + " "
		var opens : int = upper.count("BEGIN TRANSACTION")
		var closes : int = upper.count("COMMIT")
		if opens != closes:
			unbalanced += stem + " "
	Check(count >= 40, "E1) %d patches reais no tree (contagem, não número de comentário)" % count)
	Check(broken.is_empty(), "E2) nenhum patch real está vazio/ilegível (%s)" % (broken if not broken.is_empty() else "ok"))
	Check(risky.is_empty(),
		"E3) nenhum patch real usa VACUUM/PRAGMA — a premissa de envelopar em transação (%s)" % (risky if not risky.is_empty() else "ok"))
	Check(unbalanced.is_empty(),
		"E4) todo BEGIN TRANSACTION real tem COMMIT (%s)" % (unbalanced if not unbalanced.is_empty() else "ok"))
	var src : String = _Read("res://sources/sql/SQL.gd")
	var body : String = _FnBody(src, "func ApplyMigrations(")
	Check(body.contains("MigrationPlan("), "E5) ApplyMigrations continua consultando MigrationPlan (guards ligados)")
	Check(body.contains("nenhum patch vis") or src.contains("nenhum patch visível"),
		"E6) a mensagem do `empty` sobreviveu à reescrita")
	Check(src.contains("binário mais velho que o schema"), "E7) a mensagem do `stale` sobreviveu à reescrita")
	Check(body.contains("ApplyMigration(patchFile)") and body.contains("return"),
		"E8) o laço decide por retorno de ApplyMigration, e PARA na falha (fail-closed)")
	Check(not body.contains("SetVersion(currentVersion)\n\t_tableColumns.clear()"),
		"E9) não existe mais o carimbo único no fim do laço (o defeito original)")
	var apply : String = _FnBody(src, "func ApplyMigration(")
	Check(apply.contains("-> bool") and apply.contains("TryExec("),
		"E10) ApplyMigration devolve bool e usa o caminho que preserva o status")
	Check(src.contains("func TryExec(query : String) -> bool:") and src.contains("db.query(query)"),
		"E11) TryExec é a primitive que lê o bit do handle (Query() descartava)")
	var commons : String = _Read("res://sources/sql/SQLCommons.gd")
	Check(commons.contains("MigrationsDirEnv") and commons.contains("SHAMBLETA_MIGRATIONS_DIR"),
		"E12) o seam do diretório tem nome de env declarado em SQLCommons")
	Check(src.contains("OS.get_environment(SQLCommons.MigrationsDirEnv)"),
		"E13) e é lido no serviço, então o caminho de produção também é ensaiável")

# O boot REAL, reproduzido numa base descartável: template na versão 1 e os 61
# patches de `data/conf/migrations/` por cima. É a contraprova do envelopamento em
# transação — se um patch de produção não sobrevivesse ao `BEGIN TRANSACTION` que
# agora o cerca, ou se o novo fail-closed travasse o boot, é AQUI que isso aparece,
# e não no primeiro deploy de staging.
func _suiteRealBoot() -> void:
	print("-- G) boot real: template + data/conf/migrations por cima")
	var dir : DirAccess = DirAccess.open(RealMigrations)
	if not Check(dir != null, "diretório real de patches legível"):
		return
	var realCount : int = 0
	for file in dir.get_files():
		if String(file).ends_with(".sql") or String(file).ends_with(".sql.remap"):
			realCount += 1
	var svc : Node = _Service(DbReal, RealMigrations)
	if not Check(svc != null, "SQLService sobre a cópia do template, caminho de produção"):
		return
	svc.call("ApplyMigrations")
	var stats : Dictionary = _Stats(svc)
	Check(_Int(stats, "failures") == 0,
		"G1) nenhum dos %d patches reais falhou (failures=%d, patch=%d, erro=%s)" % [realCount, _Int(stats, "failures"), _Int(stats, "failedPatch"), _Str(stats, "error")])
	Check(_Int(stats, "failedPatch") == -1, "G2) nenhum patch travado no boot real")
	Check(not bool(stats.get("stalled", false)), "G3) o boot real não fica parado: diretório e base batem")
	Check(not bool(svc.call("MigrationBlocked")),
		"G3b) e sobre o boot real dos %d patches MigrationBlocked() = false: a porta continua aberta" % realCount)
	Check(_StampedVersion(DbReal) == realCount,
		"G4) a versão carimbada (%d) é o número de patches visíveis (%d)" % [_StampedVersion(DbReal), realCount])
	var handle : SQLite = _DbHandle(DbReal)
	if not Check(handle != null, "a base do boot real reabre por outra conexão"):
		return
	var integrity : Variant = _Scalar(handle, "PRAGMA integrity_check;")
	Check(String(integrity) == "ok", "G5) integrity_check da base montada pelo boot real: %s" % String(integrity))
	# As tabelas do dinheiro: existem porque os patches existem, não por acaso.
	var missing : String = ""
	for table in ["account", "ledger_transaction", "wallet", "grant_queue", "reconcile_run", "fraud_flag"]:
		if _Count(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='%s';" % table) == 0:
			missing += table + " "
	_handleClose(handle)
	Check(missing.is_empty(), "G6) as tabelas que vivem nas migrations existem (%s)" % (missing.strip_edges() if not missing.is_empty() else "ok"))

func _handleClose(handle : SQLite) -> void:
	if handle != null:
		handle.close_db()


# que se confere é a outra ponta: a série nova existe no corpo, é citada com
# `severity: page` e o valor que ela carrega vem do mesmo `MigrationStats()`.
# O que o alerta lê. `tests/deploy_ops_test.gd` é quem amarra regra↔série; aqui o
# que se confere é a outra ponta: a série nova existe no corpo, é citada com
# `severity: page` e o valor que ela carrega vem do mesmo `MigrationStats()`.
func _suiteObservability() -> void:
	print("-- F) exposição: MigrationStats -> /metrics -> alerta de página")
	var metrics : String = _Read("res://sources/system/MetricsServer.gd")
	var alerts : String = _Read("res://deploy/alerts.rules.yml")
	var emitted : Dictionary = {}
	var rx : RegEx = RegEx.create_from_string(r"body \+= \"(shambleta_[a-z0-9_]+) ")
	for matchResult in rx.search_all(metrics):
		emitted[matchResult.get_string(1)] = true
	var needed : PackedStringArray = PackedStringArray([
		"shambleta_schema_version",
		"shambleta_migration_patches_visible",
		"shambleta_migration_stalled",
		"shambleta_migration_failures_total",
		"shambleta_migration_last_failed_patch",
	])
	var missing : String = ""
	for name in needed:
		if not emitted.has(name):
			missing += name + " "
	Check(missing.is_empty(), "F1) as %d séries de migration são emitidas no corpo do /metrics (%s)" % [needed.size(), missing.strip_edges()])
	var uncited : String = ""
	for name in needed:
		if not alerts.contains(name):
			uncited += name + " "
	Check(uncited.is_empty(), "F2) cada série nova é citada por alguma regra de alerta (%s)" % (uncited.strip_edges() if not uncited.is_empty() else "ok"))
	Check(alerts.contains("expr: shambleta_migration_stalled == 1") and alerts.contains("expr: shambleta_migration_failures_total > 0"),
		"F3) existem as duas regras: binário mais novo que o schema E migration falhou")
	var pageRules : int = 0
	var arx : RegEx = RegEx.create_from_string(r"(?s)- alert: (Migration\w+|Schema\w+).*?severity: (\w+)")
	for matchResult in arx.search_all(alerts):
		if matchResult.get_string(2) == "page":
			pageRules += 1
	Check(pageRules >= 3, "F4) as regras de schema são `severity: page`, não ticket (%d de página)" % pageRules)
	Check(metrics.contains("Launcher.SQL.MigrationStats()"),
		"F5) o /metrics lê do mesmo `MigrationStats()` que o harness conferiu (não de um número copiado)")
	Check(metrics.contains("shambleta_migration_stalled %d"), "F6) o gauge já vem resolvido para quem pagina")

func _FnBody(source : String, signature : String) -> String:
	var start : int = source.find(signature)
	if start < 0:
		return ""
	var rest : String = source.substr(start)
	var next : int = rest.find("\nfunc ", 1)
	return rest if next < 0 else rest.substr(0, next)

# ------------------------------------------------------------------ teardown
func _finish() -> void:
	# Cada `SQLService` é um Node criado à mão (não entra na árvore), e cada handle
	# é uma conexão aberta sobre o arquivo: sem fechar os dois, o leak aparece no
	# gate de teardown de `scripts/ci_gate_log.sh`.
	for svc in _services:
		if svc == null or not is_instance_valid(svc):
			continue
		var handle : SQLite = svc.get("db")
		if handle != null:
			handle.close_db()
		svc.free()
	_services.clear()
	for path in _files:
		DirAccess.remove_absolute(path)
	for path in [DbMain, DbMain + "-wal", DbMain + "-shm", DbMain + "-journal",
			DbVazio, DbVazio + "-wal", DbVazio + "-shm", DbVazio + "-journal",
			DbReal, DbReal + "-wal", DbReal + "-shm", DbReal + "-journal"]:
		DirAccess.remove_absolute(path)
	for dir in [MigDir, EmptyDir, VazioDir, Scratch]:
		DirAccess.remove_absolute(dir)
	print("teardown: serviços e conexões fechados; %s removida" % Scratch)
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _initialize() -> void:
	_run()
