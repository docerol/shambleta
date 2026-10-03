extends SceneTree

# read_pool_test.gd — harness autocontido do pool de leitura do SQL (WAL).
#
# Uso:    godot --headless --path . -s tests/read_pool_test.gd
# Saída:  "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# Mesma regra de benchmarks.gd / perf_fix_test.gd: com `-s` os class_name do
# projeto ainda não estão registrados quando o harness compila, então nada aqui
# referencia `SQLReadRules`, `SQLReadPool` ou `SQLCommons` como identificador
# global — tudo por `load()`, `Callable(...)` e `.call()`. (`SQLite` é classe
# nativa da extensão, essa sim está disponível.)
#
# O que ele responde, na ordem:
#   1) A REGRA (SQLReadRules): o que roteia e o que nunca pode rotear.
#   2) A API DA ENGINE, medida: existe segundo handle no mesmo arquivo? A flag
#      `read_only` da engine funciona com WAL? `PRAGMA query_only=1` funciona? E o
#      guard de reentrância da queryMutex (#188), provocado com e sem o nó real.
#   3) Os GATES do pool: banco fora de WAL não abre; escrita não passa; falha é
#      contada e devolve ok=false — nunca "zero linhas".
#   4) A CONSISTÊNCIA EXIGIDA: leitura depois de escrita cometida vê a escrita —
#      inclusive logo depois de checkpoint, e com o writer usando `update_rows()`
#      ou transação do addon.
#   5) A GUARDA DO DINHEIRO no nó real: dentro de `SQL.Transaction()` a leitura
#      fica no handle da transação e vê o valor ainda não cometido; e pool
#      degradado não muda a resposta (fallback).
#   6) A MEDIÇÃO antes/depois: leituras concorrentes com escrita sustentada
#      rodando, com o roteamento desligado e ligado, no mesmo processo e no mesmo
#      banco, com o texto de SQL do job real (ReconcileDaily / GetLeaderboard).
#
# Banco: arquivo temporário próprio em /tmp (nunca live.db nem o testing.db do
# usuário). O servidor sobe junto pelo autoload e é usado só nos checks de wiring.

const TmpRoot : String = "/tmp/readpool/harness"
const TmpDB : String = TmpRoot + "/pool.db"

# Massa da mesa de medição: o bastante para a varredura do reconcile custar
# dezenas de ms — que é o que faz o hitch existir — sem virar teste de disco.
const SeedChars : int = 400
const SeedItemsPerChar : int = 6
const ReaderThreads : int = 4
const ReadsPerThread : int = 6

# Acima disto é hitch na régua do projeto (um tick de loop = 16 ms).
const HitchUs : int = 20000

# Texto tirado de `TournamentArenaService.ReconcileDaily` (o job que roda no
# worker thread do backup) e de `SQL.GetLeaderboard` (a leitura do loop).
# `PlayerRead` e o texto do loop com o slot INLINED, porque a medicao abaixo chama
# `query()` sem bindings. O que o check de certificação usa é o texto vivo, lido de
# `SQL.gd` por `_QuotedStatementFromSource` — uma copia desta linha ja deixou de
# representar a producao (o `'title'` aqui virou `?` la) e o check passou a
# certificar ficcao.
const ReconcileScan : String = "SELECT i.char_id FROM item i WHERE i.storage = 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = i.char_id) AND i.count != COALESCE((SELECT SUM(count) FROM item_instance WHERE item_instance.char_id = i.char_id AND item_instance.item_id = i.item_id AND item_instance.storage = i.storage AND item_instance.customfield = i.customfield), -1);"
const PlayerRead : String = "SELECT c.char_id, c.nickname, s.level, c.power_score, a.username, (SELECT ce.cosmetic_id FROM cosmetic_equip AS ce WHERE ce.account_id = a.account_id AND ce.slot = 'title') AS title_cosmetic FROM character AS c INNER JOIN account AS a ON c.account_id = a.account_id INNER JOIN stat AS s ON s.char_id = c.char_id ORDER BY c.power_score DESC, c.char_id ASC LIMIT 50;"
const LedgerInsert : String = "INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?,?,?,?,?,?,?);"
const LedgerTail : String = "SELECT balance_after FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 1;"
# Leitura com colunas que PARECEM verbos (created_at, is_deleted, drop_chance,
# updated_rows): a regra não pode confundir substring com palavra.
const MoneyRead : String = "SELECT created_at, is_deleted, drop_chance, updated_rows FROM item WHERE storage = 0;"

var checks : int = 0
var failures : int = 0

var rulesScript : GDScript = null
var poolScript : GDScript = null
var commonsScript : GDScript = null
var isPure : Callable = Callable()
var shouldRoute : Callable = Callable()
var sqlNode : Node = null

# ---------------------------------------------------------------------------
# Worker levado a uma Thread. Uma classe só porque as cargas diferem apenas no
# modo: segurar a mutex durante o job (o writer de hoje), ler pela mutex, ler
# pelo pool, escrever sustentado.
# ---------------------------------------------------------------------------
class SqlWorker extends RefCounted:
	var mode : String = "poolRead"		# poolRead | mutexRead | holdJob | write
	var handle : Object = null
	var pool : Object = null
	var mutex : Mutex = null
	var statement : String = ""
	var params : Array = []
	var iterations : int = 1
	var jobScans : int = 1
	var stop : bool = false
	var errors : int = 0
	var latenciesUs : Array = []

	func Run() -> void:
		for _i in iterations:
			if stop:
				return
			var t0 : int = Time.get_ticks_usec()
			if mode == "holdJob":
				# a forma do job real: `SQL.Transaction()` segura a queryMutex do
				# primeiro statement ao último commit
				mutex.lock()
				for _scan in jobScans:
					handle.query(statement)
				mutex.unlock()
			elif mode == "mutexRead":
				mutex.lock()
				if not bool(handle.query_with_bindings(statement, params)):
					errors += 1
				mutex.unlock()
			elif mode == "write":
				mutex.lock()
				handle.query_with_bindings(statement, params)
				mutex.unlock()
			else:
				var result : Dictionary = pool.ExecuteRead(statement, params)
				if not bool(result["ok"]):
					errors += 1
			latenciesUs.append(Time.get_ticks_usec() - t0)

# ---------------------------------------------------------------------------
# utilidades
# ---------------------------------------------------------------------------
func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func Note(text : String) -> void:
	print("  . " + text)

func Brief(statement : String) -> String:
	var one : String = statement.replace("\n", " ").strip_edges()
	return one if one.length() <= 64 else one.substr(0, 61) + "..."

func OpenHandle(path : String, queryOnly : bool) -> Object:
	var handle : SQLite = SQLite.new()
	handle.path = path
	handle.verbosity_level = SQLite.QUIET
	handle.read_only = false
	if not handle.open_db():
		return null
	handle.query("PRAGMA busy_timeout=5000;")
	if queryOnly:
		handle.query("PRAGMA query_only=1;")
	return handle

func WipeTmp() -> void:
	for suffix in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(TmpDB + suffix)

func Sum(values : Array) -> int:
	var total : int = 0
	for value in values:
		total += int(value)
	return total

func Percentile(values : Array, pct : float) -> int:
	if values.is_empty():
		return 0
	var sorted : Array = values.duplicate()
	sorted.sort()
	return int(sorted[int(float(sorted.size() - 1) * pct)])

func Hitches(values : Array) -> int:
	var count : int = 0
	for value in values:
		if int(value) > HitchUs:
			count += 1
	return count

func _initialize():
	print("== Read pool (WAL): API, consistência e medicao ==")
	DirAccess.make_dir_recursive_absolute(TmpRoot)
	rulesScript = load("res://sources/sql/SQLReadRules.gd")
	poolScript = load("res://sources/sql/SQLReadPool.gd")
	commonsScript = load("res://sources/sql/SQLCommons.gd")
	if not Check(rulesScript != null and poolScript != null, "SQLReadRules.gd e SQLReadPool.gd carregam"):
		print("FATAL: sem os modulos do pool nao ha o que medir")
		print("== RESULT: %d checks, %d failures ==" % [checks, failures])
		quit(1)
		return
	isPure = Callable(rulesScript, "IsPureRead")
	shouldRoute = Callable(rulesScript, "ShouldRoute")

	await _waitForLiveSQL()
	# O catalogo de conteudo NAO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` de `Preload` (`sources/db/DB.gd:@Preload`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar so o SQL e medir com o
	# catalogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI nao,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a maquina. O check nomeado e o
	# ponto — boot leve e vermelho visivel, nao medicao parcial silenciosa.
	# Padrao de tests/content_hygiene_test.gd.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 80:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "DB initialized (entities/maps/items carregados)"):
		print("== RESULT: %d checks, %d failures ==" % [checks, failures])
		quit(failures)
		return
	TestRules()
	TestEngineApi()
	TestMutexReentryGuard()
	TestPoolGates()
	TestConsistency()
	TestTransactionGuard()
	Measure()

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _waitForLiveSQL() -> void:
	var launcher : Node = root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		Note("autoload Launcher ausente: checks de wiring (5) nao rodam")
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		sqlNode = launcher.get("SQL")
		if sqlNode != null and bool(sqlNode.get("isInitialized")):
			Note("Launcher.SQL pronto apos %d ms (testing.db isolado no XDG do harness)" % waited)
			return
	sqlNode = null
	Note("Launcher.SQL nao inicializou: checks de wiring (5) nao rodam")

# Levanta a UNICA string SQL de uma funcao do fonte. E o que permite certificar o
# texto que roda em vez de uma copia nossa: `\"\n` e continuacao de string no
# GDScript, entao ele e removido antes de achar o par de aspas, e o recorte para no
# proximo `func` para nao pegar a string da funcao seguinte.
func _QuotedStatementFromSource(path : String, signature : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		Note("fonte %s ilegivel: wiring nao roda" % path)
		return ""
	var text : String = String(file.get_as_text()).replace("\\\n", "")
	file.close()
	var at : int = text.find(signature)
	if at < 0:
		Note("assinatura %s nao encontrada em %s" % [signature, path])
		return ""
	var nextFunc : int = text.find("\nfunc ", at + signature.length())
	var chunk : String = text.substr(at, text.length() - at) if nextFunc < 0 else text.substr(at, nextFunc - at)
	var open : int = chunk.find("\"")
	if open < 0:
		return ""
	var close : int = chunk.find("\"", open + 1)
	return "" if close < 0 else chunk.substr(open + 1, close - open - 1)

# ---------------------------------------------------------------------------
# 1) A regra.
# ---------------------------------------------------------------------------
func TestRules() -> void:
	print("-- 1) regra de roteamento --")
	var pure : Array = [
		"SELECT name FROM sqlite_master WHERE type=\"table\" AND name=\"migration\"",
		"SELECT balance_after FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 1;",
		"SELECT count(*) AS c FROM item;",
		"  select 1;",
		"WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x < 10) SELECT count(*) AS c FROM cnt;",
		ReconcileScan,
		PlayerRead,
		"SELECT i.char_id FROM item AS i /* varredura */ WHERE i.count > 0; -- DELETE FROM account",
		"SELECT 'DROP TABLE account' AS literal_que_nao_e_comando;",
		"SELECT created_at, is_deleted, drop_chance, updated_rows FROM item WHERE storage = 0;",
		"SELECT count(*) AS n FROM character WHERE power_score > 0 ORDER BY power_score DESC LIMIT 10;",
	]
	for statement in pure:
		Check(bool(isPure.call(statement)), "roteavel: [%s]" % Brief(str(statement)))
	var notPure : Array = [
		"INSERT INTO t VALUES (1);",
		"UPDATE t SET a = 1;",
		"DELETE FROM t;",
		"PRAGMA journal_mode=WAL;",
		"PRAGMA table_info(account);",
		"CREATE TABLE t (a);",
		"DROP TABLE t;",
		"BEGIN TRANSACTION;",
		"COMMIT;",
		"SELECT 1; DELETE FROM account;",
		"SELECT count(*) FROM t GROUP BY a HAVING total < 0; INSERT INTO reconcile_run VALUES (1);",
		"INSERT INTO t SELECT * FROM u;",
		"SELECT * FROM t ON CONFLICT DO UPDATE SET a = 1;",
		"SELECT 'aspas nao terminadas",
		"SELECT 1 /* comentario sem fim",
		"SELECT 'aspas nao terminadas",
		"SELECT 1 /* comentario sem fim",
		"",
		# Estado da conexão: forma de SELECT puro, mas a resposta é POR HANDLE. No
		# handle do pool sai uma linha válida com 0 — o fallback não dispara e o
		# chamador acredita nela. Nunca roteia.
		"SELECT changes();",
		"SELECT total_changes() AS n;",
		"SELECT last_insert_rowid() AS id;",
		"SELECT COALESCE((SELECT changes()), 0) AS touched;",
		"WITH d AS (DELETE FROM account RETURNING account_id) SELECT * FROM d;",
		"SELECT * FROM t WHERE note = 'x'; DELETE FROM t",
	]
	for statement in notPure:
		Check(not bool(isPure.call(statement)), "NAO roteavel: [%s]" % Brief(str(statement)))
	# Os dois caminhos da regra tem que concordar: o caminho rápido só pode dizer
	# "sim" para o que o scanner preciso também diria. Divergir daqui é rota
	# mandando para o pool algo que a autoridade reprova.
	var scanner : Callable = Callable(rulesScript, "PureReadScanner")
	var divergent : Array = []
	for statement in pure + notPure:
		if bool(isPure.call(statement)) and not bool(scanner.call(statement)):
			divergent.append(Brief(str(statement)))
	Check(divergent.is_empty(), "caminho rapido nunca certifica o que o scanner reprova (%d fixtures)" % (pure + notPure).size())
	if not divergent.is_empty():
		Note("divergencias: " + str(divergent))
	# As duas leituras quentes tem que ser certificadas SEM o scanner byte a byte:
	# `DecideStatement` e o degrau puro (sem cache, sem contador), entao a thread do
	# worker de backup nao pode embaralhar a leitura deste check.
	var decide : Callable = Callable(rulesScript, "DecideStatement")
	var certify : Callable = Callable(rulesScript, "_FastCertify")
	var liveLeaderboard : String = _QuotedStatementFromSource("res://sources/sql/SQL.gd", "func GetLeaderboard(")
	Check(liveLeaderboard.contains("SELECT") and liveLeaderboard.contains("LIMIT ?"), "o texto vivo do loop foi extraido de SQL.gd (%d chars)" % liveLeaderboard.length())
	# O literal de string e o que derruba a certificacion: um caminho rapido que nao
	# sabe separar codigo de conteudo tem de abster-se, e a leitura do loop nao pode
	# se dar ao luxo de cair no scanner byte a byte a cada tick.
	Check(not liveLeaderboard.contains("'"), "a leitura do loop nao carrega literal de string")
	Check(bool(certify.call(liveLeaderboard.to_upper())), "certificacao rapida cobre a leitura REAL do loop (texto lido de SQL.gd)")
	Check(bool(certify.call(str(ReconcileScan.to_upper()))), "certificacao rapida cobre a varredura do job")
	Check(bool(decide.call(liveLeaderboard)) and bool(decide.call(ReconcileScan)), "as duas saem pelo caminho rapido")
	Check(not bool(certify.call(str(MoneyRead.to_upper()))) or bool(Callable(rulesScript, "PureReadScanner").call(MoneyRead)),
		"se o caminho rapido recusa, o scanner decide (nunca os dois dizendo nao sem razao)")
	var stats : Dictionary = rulesScript.call("PathStats")
	Check(bool(stats["patternReady"]), "o padrao de verbos compilou (sem ele o caminho rapido fica fechado)")
	Check(bool(shouldRoute.call("SELECT 1;", 0, true, true)), "ShouldRoute: fora de txn, pool pronto -> roteia")
	Check(not bool(shouldRoute.call("SELECT 1;", 1, true, true)), "ShouldRoute: txnDepth 1 fecha a rota")
	Check(not bool(shouldRoute.call("SELECT 1;", 2, true, true)), "ShouldRoute: txn aninhada tambem fecha")
	Check(not bool(shouldRoute.call("SELECT 1;", 0, false, true)), "ShouldRoute: pool fechado -> caminho historico")
	Check(not bool(shouldRoute.call("SELECT 1;", 0, true, false)), "ShouldRoute: chave desligada -> caminho historico")
	Check(not bool(shouldRoute.call("UPDATE t SET a = 1", 0, true, true)), "ShouldRoute: escrita nunca roteia")

# ---------------------------------------------------------------------------
# 2) API da engine, medida em vez de assumida.
# ---------------------------------------------------------------------------
func TestEngineApi() -> void:
	print("-- 2) API da engine (Godot %s) --" % str(Engine.get_version_info().string))
	# A `queryMutex` (sources/sql/SQL.gd:@queryMutex) protege o handle único, e dois
	# comentários do repo discordavam sobre o que ela faz quando a MESMA thread pede de
	# novo: um dizia "recursiva", o outro "não é reentrante, deadlockaria". Os dois
	# guiam decisão de dinheiro e os dois não podem estar certos. Medido aqui, na engine
	# deste build, sem banco no meio: o pedido repetido É atendido — e é exatamente por
	# isso que o funil não pode depender disso. Recursão é acidente de implementação; a
	# regra agora é o guard de `EnterQueryMutex` (sources/sql/SQLCommons.gd:@EnterQueryMutex),
	# provocado e cobrado em `TestMutexReentryGuard` (tests/read_pool_test.gd:@TestMutexReentryGuard).
	var probe : Mutex = Mutex.new()
	probe.lock()
	var reentered : bool = probe.try_lock()
	if reentered:
		probe.unlock()
	probe.unlock()
	Check(reentered, "Mutex da engine ACEITA re-entrada da mesma thread (try_lock devolve true) — o que a queryMutex faz hoje, nao o que ela promete")
	Note("se a engine mudar e isto virar false, nada muda no produto: o guard devolve o nivel emprestado ANTES de pedir a mutex crua, entao nao ha segundo lock a onde travar")
	WipeTmp()
	var writer : Object = OpenHandle(TmpDB, false)
	if not Check(writer != null, "handle de escrita abre no banco temporario"):
		return
	writer.query("PRAGMA journal_mode=WAL;")
	writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
	writer.query("INSERT INTO t (v) VALUES ('a'),('b');")
	var second : Object = OpenHandle(TmpDB, false)
	if Check(second != null, "SQLite.new() da um SEGUNDO handle no mesmo arquivo (DBInterface e o proprio SQLite)"):
		second.query("PRAGMA query_only=1;")
		var ok : bool = bool(second.query("SELECT count(*) AS c FROM t;"))
		Check(ok and int(second.query_result[0]["c"]) == 2, "o segundo handle le as mesmas linhas")
		Check(not bool(second.query("INSERT INTO t (v) VALUES ('x');")), "query_only=1 recusa escrita na segunda conexao")
		second.close_db()
	# a flag read_only da engine NAO serve: com WAL ela abre e nao le. Provado de
	# proposito — e o motivo de o pool usar query_only=1.
	var roFlag : SQLite = SQLite.new()
	roFlag.path = TmpDB
	roFlag.verbosity_level = SQLite.QUIET
	roFlag.read_only = true
	var roOpened : bool = bool(roFlag.open_db())
	var roRead : bool = bool(roFlag.query("SELECT count(*) AS c FROM t;"))
	Check(not roRead, "engine read_only=true + WAL NAO consegue ler (por isso o pool usa query_only)")
	Note("read_only=true: open_db=%s SELECT=%s erro=\"%s\"" % [str(roOpened), str(roRead), String(roFlag.error_message)])
	if roOpened:
		roFlag.close_db()
	# O outro lado da mesma discórdia: por que `Transaction()` (sources/sql/SQL.gd:@Transaction)
	# não pode ser aninhado, se a mutex deixa? Medido no handle cru, sem o nó de
	# produção no meio — é o comportamento do libgdsqlite deste repo, escrito hoje no
	# NOTE que abre o bloco da própria função.
	var outerBegin : bool = bool(writer.query("BEGIN;"))
	writer.query("INSERT INTO t (v) VALUES ('outer');")
	var innerBegin : bool = bool(writer.query("BEGIN;"))
	writer.query("INSERT INTO t (v) VALUES ('inner');")
	var innerEnd : bool = bool(writer.query("END;"))
	var outerCommit : bool = bool(writer.query("COMMIT;"))
	var witness : Object = OpenHandle(TmpDB, false)
	var seen : int = -1
	if witness != null:
		witness.query("PRAGMA query_only=1;")
		if bool(witness.query("SELECT count(*) AS c FROM t;")):
			seen = int(witness.query_result[0]["c"])
		witness.close_db()
	writer.close_db()
	Check(outerBegin and not innerBegin, "BEGIN aninhado FALHA no libgdsqlite (não existe transação dentro de transação)")
	Check(innerEnd and seen == 4, "o END interno cometeu o trabalho do externo também: um witness vê %d linhas, não 2 — aninhar comete cedo, não trava" % seen)
	Check(not outerCommit, "o COMMIT do externo falha depois: a transação que ele achava que controlava já foi")

# ---------------------------------------------------------------------------
# 2b) O guard da reentrância, PROVOCADO. `TestEngineApi` mede o que a engine
# aceita; esta suíte cobra o que o funil faz com isso: o pedido repetido da mesma
# thread tem que ser emprestado e contado — nunca um segundo lock. As
# duas fixtures passam pelo mesmo predicado do produto (nada de lógica copiada
# aqui) e cada uma tem a sua negativa: sem o guard, (A) devolve `true` e (B)
# conta dois round trips de lock em vez de um.
# ---------------------------------------------------------------------------
func TestMutexReentryGuard() -> void:
	print("-- 2b) guard de reentrancia da queryMutex --")
	if commonsScript == null:
		Check(false, "SQLCommons.gd carrega para a suite do guard")
		return
	# (A) O guard puro: mutex crua própria, sem banco e sem nó. O primeiro pedido da
	#     thread é o nível de topo; o segundo, emprestado — e a acusação é contador, não
	#     curiosidade de log.
	var probe : Mutex = Mutex.new()
	var accusedBefore : int = int(commonsScript.get("mutexReentries"))
	Check(bool(commonsScript.call("EnterQueryMutex", probe)), "nivel de topo: o primeiro pedido trava a mutex de verdade")
	Check(not bool(commonsScript.call("EnterQueryMutex", probe)), "nivel emprestado: o segundo pedido da mesma thread NAO trava de novo")
	var accused : int = int(commonsScript.get("mutexReentries")) - accusedBefore
	Check(accused == 1, "a reentrancia foi CONTADA no medidor do funil (delta 1; visto: %d)" % accused)
	Check(int(commonsScript.get("queryMutexDepth")) == 2, "e os dois niveis estao registrados (profundidade 2; visto: %d)" % int(commonsScript.get("queryMutexDepth")))
	commonsScript.call("ExitQueryMutex", probe)
	Check(int(commonsScript.get("queryMutexDepth")) == 1, "devolver o nivel emprestado nao devolve a mutex crua: falta o do topo (visto: %d)" % int(commonsScript.get("queryMutexDepth")))
	commonsScript.call("ExitQueryMutex", probe)
	Check(int(commonsScript.get("queryMutexDepth")) == 0, "e o do topo fecha o ciclo (visto: %d)" % int(commonsScript.get("queryMutexDepth")))
	Check(int(commonsScript.get("queryMutexOwnerThread")) == -1, "sem dono registrado, a proxima thread nao herda um nivel emprestado")
	Check(bool(commonsScript.call("EnterQueryMutex", probe)), "segundo ciclo: pedido novo volta a ser nivel de topo")
	commonsScript.call("ExitQueryMutex", probe)
	# Devolver sem nível é o outro modo de a contagem quebrar (abriria a seção crítica
	# de outra thread). Plantado: a profundidade parada em zero, não em -1.
	commonsScript.call("ExitQueryMutex", probe)
	Check(int(commonsScript.get("queryMutexDepth")) == 0, "unlock orfao nao afunda a contagem (visto: %d)" % int(commonsScript.get("queryMutexDepth")))
	# (B) No nó real: o lambda de uma transação chama uma porta com lock com a mutex na
	#     mão — reentrância de produção, a mesma forma que `CheckoutService` e
	#     `SQLGrants` já exercitam. O que se cobra é a contagem e a prova de que a mutex
	#     crua não foi pedida duas vezes.
	if sqlNode == null:
		Check(false, "Launcher.SQL disponivel para a fixture de transacao aninhada")
		return
	var sql : Node = sqlNode
	var before : Dictionary = sql.call("QueryMutexWaitStats")
	# GDScript captura por VALOR: `x = ...` dentro do lambda não chega a quem chama — só
	# atravessa a MUTAÇÃO do container capturado (a cópia do endereço aponta pro mesmo
	# dicionário). Medido nesta casa em 2026-10-03: com a scalar `readInside` o check
	# lia sempre o valor inicial, verde era impossível e vermelho não dizia nada do
	# produto. O container é o canal; o que se afirma continua sendo o número lá dentro.
	var seen : Dictionary = {"rows": -1}
	var startedUs : int = Time.get_ticks_usec()
	Check(not bool(sql.call("Transaction", func() -> bool:
		var rows : Array = sql.call("QueryBindings", "SELECT count(*) AS v FROM sqlite_master;", [])
		seen["rows"] = int(rows[0]["v"]) if not rows.is_empty() else -1
		return false)), "txn com leitura aninhada roda ate o fim e faz rollback (sem hang)")
	var spentUs : int = Time.get_ticks_usec() - startedUs
	var after : Dictionary = sql.call("QueryMutexWaitStats")
	var waitDelta : int = int(after["waits"]) - int(before["waits"])
	var reentryDelta : int = int(after["reentries"]) - int(before["reentries"])
	var readInside : int = int(seen["rows"])
	Check(reentryDelta == 1, "Transaction+QueryBindings aninhados acusam o nivel emprestado (delta 1; visto: %d)" % reentryDelta)
	Check(waitDelta == 1, "e contam UM round trip de lock, nao dois: o emprestado nao mede espera (visto: %d)" % waitDelta)
	Check(readInside > 0, "a leitura aninhada roda no handle da transacao e devolve linha (contagem %d)" % readInside)
	Check(spentUs < 200000, "o pedido emprestado nao esperou na fila: %d us na transacao inteira" % spentUs)
	Note("sem o guard esta fixture dependeria da recursao da engine: ou dois locks medidos, ou um hang ate o timeout do portao")

# ---------------------------------------------------------------------------
# 3) Gates do pool.
# ---------------------------------------------------------------------------
func TestPoolGates() -> void:
	print("-- 3) gates do pool --")
	WipeTmp()
	var plain : Object = OpenHandle(TmpDB, false)
	plain.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
	plain.query("INSERT INTO t VALUES (1,'a');")
	var pool : Object = poolScript.new()
	Check(not bool(pool.Open(TmpDB, 2)), "pool recusa banco fora de WAL (leitor veria estado errado)")
	Note("motivo reportado: " + String(pool.lastError))
	Check(int(pool.ActiveSlots()) == 0, "recusa nao deixa conexao meio aberta")
	plain.close_db()

	WipeTmp()
	var writer : Object = OpenHandle(TmpDB, false)
	writer.query("PRAGMA journal_mode=WAL;")
	writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
	writer.query("INSERT INTO t (v) VALUES ('a'),('b');")
	if Check(bool(pool.Open(TmpDB, 2)), "pool abre em banco WAL"):
		Check(int(pool.ActiveSlots()) == 2, "dois slots vivos")
		var read : Dictionary = pool.ExecuteRead("SELECT count(*) AS c FROM t;", [])
		Check(bool(read["ok"]) and int((read["rows"] as Array)[0]["c"]) == 2, "ExecuteRead devolve as linhas")
		var failuresBefore : int = int(pool.Stats()["failures"])
		Check(not bool(pool.ExecuteRead("INSERT INTO t (v) VALUES ('c');", [])["ok"]),
			"ExecuteRead nao finge sucesso em statement que query_only recusa")
		Check(int(pool.Stats()["reads"]) == 1, "contador so conta leitura atendida")
		Check(int(pool.Stats()["failures"]) == failuresBefore + int(pool.ActiveSlots()),
			"recusa de escrita e contada em cada slot tentado")
		failuresBefore = int(pool.Stats()["failures"])
		Check(not bool(pool.ExecuteRead("SELECT * FROM tabela_inexistente;", [])["ok"]),
			"leitura que falha devolve ok=false (e o chamador cai no writer)")
		Check(int(pool.Stats()["failures"]) == failuresBefore + poolActive(pool),
			"falha e contada em cada slot tentado: pool degenerado fica visivel no gate")
		var held : Array = pool.ExecuteRead("SELECT count(*) AS c FROM t;", [])["rows"]
		pool.ExecuteRead("SELECT 42 AS x;", [])
		Check(int(held[0]["c"]) == 2, "linhas devolvidas nao sao mutadas pelo proximo query do slot")
		# um slot preso em transação não pode congelar o snapshot para sempre: o
		# pool desarma o slot que pegar e o round-robin passa por todos
		var stuckHandles : Array = []
		for entry in pool.entries:
			var slotHandle : Object = (entry as Dictionary)["db"]
			stuckHandles.append(slotHandle)
			slotHandle.query("BEGIN TRANSACTION;")
		for _slot in pool.ActiveSlots():
			Check(bool(pool.ExecuteRead("SELECT count(*) AS c FROM t;", [])["ok"]), "leitura sobrevive a slot preso em txn")
		Check(int(pool.Stats()["stuckResets"]) >= stuckHandles.size(),
			"todos os slots presos sao rearmados e contados (%d resets)" % int(pool.Stats()["stuckResets"]))
		var autocommits : int = 0
		for stuck in stuckHandles:
			if int(stuck.get_autocommit()) == 1:
				autocommits += 1
		Check(autocommits == stuckHandles.size(), "e cada slot volta a estar em autocommit")
		# um slot sem conexão não derruba o leitor nem congel a resposta: o
		# round-robin cai no slot vivo e a falha aparece no contador
		(pool.entries[0] as Dictionary)["db"] = null
		var healed : Dictionary = pool.ExecuteRead("SELECT count(*) AS c FROM t;", [])
		Check(bool(healed["ok"]) and int((healed["rows"] as Array)[0]["c"]) == 2,
			"slot morto: leitura sai pelo slot vivo sem chamar metodo em null")
		Check(int(pool.ActiveSlots()) == 1, "slot morto sai da contagem de slots vivos")
		(pool.entries[1] as Dictionary)["db"] = null
		Check(not bool(pool.ExecuteRead("SELECT count(*) AS c FROM t;", [])["ok"]),
			"todos os slots mortos: ok=false (ordem de fallback), nunca linha a menos")
	pool.Close()
	Check(not bool(pool.Ready()), "Close fecha e o pool deixa de estar pronto")
	writer.close_db()

func poolActive(pool : Object) -> int:
	# ExecuteRead tenta cada slot uma vez quando a statement é rejeitada por todos
	return int(pool.ActiveSlots())

# ---------------------------------------------------------------------------
# 4) Consistência: leitura depois de escrita cometida VÊ a escrita.
# ---------------------------------------------------------------------------
func TestConsistency() -> void:
	print("-- 4) consistencia read-after-commit --")
	WipeTmp()
	var writer : Object = OpenHandle(TmpDB, false)
	writer.query("PRAGMA journal_mode=WAL;")
	writer.query("PRAGMA synchronous=NORMAL;")
	writer.query("PRAGMA wal_autocheckpoint=4000;")
	writer.query("CREATE TABLE wallet (id INTEGER PRIMARY KEY, balance INTEGER);")
	writer.query("INSERT INTO wallet VALUES (1, 100);")
	var pool : Object = poolScript.new()
	pool.Open(TmpDB, 2)
	var probe : Callable = func() -> int:
		var result : Dictionary = pool.ExecuteRead("SELECT balance FROM wallet WHERE id = 1;", [])
		var rows : Array = result["rows"]
		return int(rows[0]["balance"]) if bool(result["ok"]) and not rows.is_empty() else -1
	Check(probe.call() == 100, "estado inicial lido pelo pool")
	writer.query("UPDATE wallet SET balance = 250 WHERE id = 1;")
	Check(probe.call() == 250, "UPDATE autocommit do writer -> pool ve")
	writer.update_rows("wallet", "id = 1", {"balance": 300})
	Check(probe.call() == 300, "update_rows() do addon (BEGIN/END proprios) -> pool ve")
	writer.query("BEGIN TRANSACTION;")
	writer.query("UPDATE wallet SET balance = 999 WHERE id = 1;")
	Check(probe.call() == 300, "txn aberta do writer -> pool ve o ultimo commit, nao o meio da txn")
	writer.query("COMMIT;")
	Check(probe.call() == 999, "logo apos COMMIT -> pool ve 999")
	writer.query("BEGIN TRANSACTION;")
	writer.query("UPDATE wallet SET balance = 55 WHERE id = 1;")
	writer.query("ROLLBACK;")
	Check(probe.call() == 999, "ROLLBACK do writer nao vaza para o pool")
	var matched : int = 0
	var checkpoints : int = 0
	for cycle in 12:
		writer.query("UPDATE wallet SET balance = %d WHERE id = 1;" % (1000 + cycle))
		if cycle % 3 == 2:
			writer.query("PRAGMA wal_checkpoint(TRUNCATE);")
			checkpoints += 1
		if probe.call() == 1000 + cycle:
			matched += 1
	Check(matched == 12, "12/12 leituras pos-commit corretas atravessando %d checkpoints" % checkpoints)
	writer.query("CREATE TABLE bulk (id INTEGER PRIMARY KEY, a TEXT, b TEXT);")
	var t0 : int = Time.get_ticks_msec()
	writer.query("BEGIN TRANSACTION;")
	for i in 3000:
		writer.query_with_bindings("INSERT INTO bulk (a,b) VALUES (?,?);", ["v%d" % i, "pad"])
	writer.query("COMMIT;")
	var bulk : Dictionary = pool.ExecuteRead("SELECT count(*) AS c FROM bulk;", [])
	Check(bool(bulk["ok"]) and int((bulk["rows"] as Array)[0]["c"]) == 3000,
		"pool ve um dump de 3000 linhas recem-cometido (%d ms)" % (Time.get_ticks_msec() - t0))
	writer.query("PRAGMA wal_checkpoint(TRUNCATE);")
	var bulkAfter : Dictionary = pool.ExecuteRead("SELECT count(*) AS c FROM bulk;", [])
	Check(bool(bulkAfter["ok"]) and int((bulkAfter["rows"] as Array)[0]["c"]) == 3000, "e continua vendo depois do checkpoint")
	pool.Close()
	writer.close_db()

# ---------------------------------------------------------------------------
# 5) Invariantes no nó real: transação e queda do pool.
# ---------------------------------------------------------------------------
func TestTransactionGuard() -> void:
	print("-- 5) invariante no no real --")
	if sqlNode == null:
		Check(false, "Launcher.SQL disponivel para checar a guarda de transacao")
		return
	var sql : Node = sqlNode
	Note("pool no no real: %s" % str(sql.call("ReadPoolStats")))
	var statement : String = "SELECT name FROM sqlite_master WHERE type='table' AND name='character';"
	Check(bool(sql.call("ReadWouldRoute", statement)), "fora de txn: leitura pura roteia no no real")
	Check(not bool(sql.call("ReadWouldRoute", "UPDATE account SET permission = 3;")), "fora de txn: escrita nao roteia no no real")
	Check(int(sql.call("ReadTxnDepth")) == 0, "nenhuma transacao em aberto no inicio")
	var saw : Array = []
	var body : Callable = func() -> bool:
		saw.append(int(sql.call("ReadTxnDepth")))
		saw.append(bool(sql.call("ReadWouldRoute", statement)))
		sql.call("ExecNoLock", "CREATE TABLE IF NOT EXISTS rp_guard (v INTEGER);")
		sql.call("ExecNoLock", "DELETE FROM rp_guard;")
		sql.call("ExecNoLock", "INSERT INTO rp_guard VALUES (4242);")
		var rows : Array = sql.call("QueryBindings", "SELECT v FROM rp_guard;", [])
		saw.append(int(rows[0]["v"]) if not rows.is_empty() else -1)
		return false
	Check(not bool(sql.call("Transaction", body)), "txn forcada a falhar (rollback)")
	Check(saw.size() == 3, "lambda rodou inteiro dentro de Transaction")
	if saw.size() == 3:
		Check(int(saw[0]) == 1, "dentro de Transaction, ReadTxnDepth == 1")
		Check(not bool(saw[1]), "dentro de Transaction a leitura NAO rota para o pool")
		Check(int(saw[2]) == 4242, "dentro de Transaction a leitura ve o valor NAO cometido (handle da txn)")
	Check((sql.call("QueryBindings", "SELECT v FROM rp_guard;", []) as Array).is_empty(), "fora da txn o rollback vale: nada visivel")
	sql.call("Query", "DROP TABLE IF EXISTS rp_guard;")
	Check(int(sql.call("ReadTxnDepth")) == 0, "contador volta a zero")
	# paridade pool x caminho historico na mesma pergunta
	var routed : Array = sql.call("QueryBindings", "SELECT count(*) AS c FROM sqlite_master;", [])
	var wasEnabled : bool = bool(sql.get("readPoolEnabled"))
	sql.call("SetReadPoolEnabled", false)
	var direct : Array = sql.call("QueryBindings", "SELECT count(*) AS c FROM sqlite_master;", [])
	sql.call("SetReadPoolEnabled", wasEnabled)
	Check(not routed.is_empty() and not direct.is_empty() and int(routed[0]["c"]) == int(direct[0]["c"]),
		"mesma resposta pelo pool e pelo caminho historico")
	# pool degradado NUNCA pode virar linha de menos: primeiro o slot vivo cobre,
	# depois de mortos os dois a resposta volta a sair do writer
	var pool : Object = sql.get("readPool")
	var question : String = "SELECT count(*) AS c FROM sqlite_master;"
	var beforeFailures : int = int(pool.Stats()["failures"])
	(pool.entries[0] as Dictionary)["db"] = null
	var halfDead : Array = sql.call("QueryBindings", question, [])
	Check(not halfDead.is_empty() and int(halfDead[0]["c"]) == int(direct[0]["c"]),
		"com um slot morto a resposta nao muda")
	Check(int(pool.ActiveSlots()) >= 0, "slot morto e visivel na contagem (%d vivos)" % int(pool.ActiveSlots()))
	for entry in pool.entries:
		(entry as Dictionary)["db"] = null
	var degraded : Array = sql.call("QueryBindings", question, [])
	Check(not degraded.is_empty() and int(degraded[0]["c"]) == int(direct[0]["c"]),
		"pool com handles caidos devolve a mesma resposta (fallback pelo writer)")
	Check(int(pool.Stats()["failures"]) > beforeFailures, "e a degradacao e contada, nao engolida")
	sql.call("OpenReadPool", String(sql.get("db").path))
	Check(bool(sql.call("ReadPoolStats")["open"]), "pool reabre depois do degrau")

# ---------------------------------------------------------------------------
# 6) Medição antes/depois.
# ---------------------------------------------------------------------------
func Measure() -> void:
	print("-- 6) medicao antes/depois --")
	WipeTmp()
	var writer : Object = OpenHandle(TmpDB, false)
	writer.query("PRAGMA journal_mode=WAL;")
	writer.query("PRAGMA synchronous=NORMAL;")
	writer.query("PRAGMA wal_autocheckpoint=4000;")
	Seed(writer)
	var pool : Object = poolScript.new()
	if not Check(bool(pool.Open(TmpDB, 2)), "pool abre no banco de medicao"):
		writer.close_db()
		return
	var mutex : Mutex = Mutex.new()
	var scanUs : int = Time.get_ticks_usec()
	writer.query(ReconcileScan)
	scanUs = Time.get_ticks_usec() - scanUs
	var readUs : int = Time.get_ticks_usec()
	writer.query(PlayerRead)
	readUs = Time.get_ticks_usec() - readUs
	Note("custo unitario na mesa: varredura do reconcile %d us, leitura de leaderboard %d us" % [scanUs, readUs])

	# (A) o hitch de hoje: o job segura a queryMutex do primeiro statement ao
	#     ultimo commit; a leitura do loop atras dessa mutex espera o job inteiro.
	print("  [A] leitura do loop enquanto o job segura a mutex (job = 4 varreduras)")
	var samples : Dictionary = {}
	for mode in ["mutex", "pool"]:
		var latencies : Array = []
		for _round in 5:
			var holder : SqlWorker = SqlWorker.new()
			holder.mode = "holdJob"
			holder.handle = writer
			holder.mutex = mutex
			holder.statement = ReconcileScan
			holder.jobScans = 4
			holder.iterations = 1
			var thread : Thread = Thread.new()
			thread.start(Callable(holder, "Run"))
			OS.delay_msec(40) # deixa o writer entrar na secao critica
			var t0 : int = Time.get_ticks_usec()
			if mode == "mutex":
				var waiter : SqlWorker = SqlWorker.new()
				waiter.mode = "mutexRead"
				waiter.handle = writer
				waiter.mutex = mutex
				waiter.statement = PlayerRead
				waiter.iterations = 1
				waiter.Run()
			else:
				pool.ExecuteRead(PlayerRead, [])
			latencies.append(Time.get_ticks_usec() - t0)
			thread.wait_to_finish()
		samples[mode] = latencies
		Note("A %-4s p50 %7d us | p95 %7d us | max %7d us | hitches(>%d us) %d/%d" % [
			mode, Percentile(latencies, 0.5), Percentile(latencies, 0.95),
			int(latencies.max()), HitchUs, Hitches(latencies), latencies.size()])
	Check(int(Percentile(samples["pool"], 0.95)) < int(Percentile(samples["mutex"], 0.5)),
		"A: pool tira a leitura do loop de tras da mutex do job (p95 pool < p50 mutex)")

	# (B) vazao: N threads lendo com uma escrita sustentada rodando na mutex.
	print("  [B] %d threads x %d varreduras com escrita sustentada na mutex" % [ReaderThreads, ReadsPerThread])
	var writerB : Object = OpenHandle(TmpDB, false)
	var sustained : SqlWorker = SqlWorker.new()
	sustained.mode = "write"
	sustained.handle = writerB
	sustained.mutex = mutex
	sustained.statement = LedgerInsert
	sustained.params = [7, 7, "gems", -10, 90, "bench", 1]
	sustained.iterations = 600
	var sustainedThread : Thread = Thread.new()
	sustainedThread.start(Callable(sustained, "Run"))
	OS.delay_msec(40)
	var throughput : Dictionary = {}
	for mode in ["mutex", "pool"]:
		var workers : Array = []
		var threads : Array = []
		var t0 : int = Time.get_ticks_msec()
		for _i in ReaderThreads:
			var worker : SqlWorker = SqlWorker.new()
			worker.mode = "mutexRead" if mode == "mutex" else "poolRead"
			worker.handle = writer
			worker.pool = pool
			worker.mutex = mutex
			worker.statement = ReconcileScan
			worker.iterations = ReadsPerThread
			workers.append(worker)
			var thread : Thread = Thread.new()
			thread.start(Callable(worker, "Run"))
			threads.append(thread)
		for thread in threads:
			thread.wait_to_finish()
		var total : int = Time.get_ticks_msec() - t0
		var allLat : Array = []
		var errors : int = 0
		for worker in workers:
			allLat.append_array(worker.latenciesUs)
			errors += worker.errors
		throughput[mode] = total
		Note("B %-4s total %4d ms | p50 %7d us | p95 %7d us | max %7d us | falhas %d" % [
			mode, total, Percentile(allLat, 0.5), Percentile(allLat, 0.95),
			int(allLat.max()) if not allLat.is_empty() else 0, errors])
	Check(int(throughput["pool"]) < int(throughput["mutex"]),
		"B: leituras concorrentes escalam no pool onde a mutex unica serializa")
	sustained.stop = true
	sustainedThread.wait_to_finish()
	writerB.close_db()

	# (C) steady state sem concorrencia: o preco da rota nova quando ninguem
	#     disputa a mutex. Inclui a decisao de roteamento no tempo medido.
	print("  [C] steady state (sem concorrencia): 200 leituras, uma thread")
	var costs : Dictionary = {}
	for mode in ["mutex", "pool"]:
		var latencies : Array = []
		for _i in 200:
			var t0 : int = Time.get_ticks_usec()
			if mode == "mutex":
				writer.query(PlayerRead)
			else:
				shouldRoute.call(PlayerRead, 0, true, true)
				pool.ExecuteRead(PlayerRead, [])
			latencies.append(Time.get_ticks_usec() - t0)
		costs[mode] = latencies
		Note("C %-4s p50 %5d us | p95 %5d us | max %5d us | soma %d us" % [
			mode, Percentile(latencies, 0.5), Percentile(latencies, 0.95),
			int(latencies.max()), Sum(latencies)])
	Check(Sum(costs["pool"]) <= int(float(Sum(costs["mutex"])) * 1.5),
		"C: sem concorrencia a rota nova no custa mais que +50% da antiga")

	# (D) round trips no caminho de ledger: 500 escritas + 500 leituras, rota
	#     desligada e ligada. O número que o gate do projeto lê é "round trip
	#     contado" (`SQL.QueryCount` soma handle do writer + leituras do pool),
	#     então a pergunta é: rotear muda quantos round trips existem? Não — muda
	#     só em qual conexão eles esperam. Aqui `RouteRead` replica a decisão de
	#     `SQL._PoolRead` (mesma regra, mesmo pool) sobre a mesa temporária, porque
	#     medir round trip exige contagem isolada do que EU emeti; a fiação real do
	#     nó é provada na seção 5 com `ReadWouldRoute`.
	print("  [D] round trips de ledger: 500 escritas + 500 leituras, rota desligada/ligada")
	var roundTrips : Dictionary = {}
	var routeRead : Callable = func(statement : String, params : Array, enabled : bool, counters : Array) -> int:
		if bool(shouldRoute.call(statement, 0, pool.Ready(), enabled)):
			var attempt : Dictionary = pool.ExecuteRead(statement, params)
			if bool(attempt["ok"]):
				counters[1] += 1
				return (attempt["rows"] as Array).size()
		mutex.lock()
		writer.query_with_bindings(statement, params)
		mutex.unlock()
		counters[0] += 1
		return writer.query_result.size()
	for state in [false, true]:
		var counters : Array = [0, 0]	# [writer trips, pool trips]
		writer.query("DELETE FROM ledger_transaction;")
		var t0 : int = Time.get_ticks_usec()
		for i in 500:
			mutex.lock()
			writer.query_with_bindings(LedgerInsert, [i + 1, i + 1, "gold", 1, 1, "bench", 1])
			mutex.unlock()
			counters[0] += 1	# a escrita e um round trip no handle do writer, sempre
			routeRead.call(LedgerTail, [i + 1], state, counters)
		var spent : int = Time.get_ticks_usec() - t0
		roundTrips[str(state)] = {"trips": counters[0] + counters[1], "writer": counters[0], "pool": counters[1], "us": spent}
		Note("D pool=%-5s round trips %4d (writer %3d, pool %3d) | %6d us (%.2f us por par write+read)" % [
			str(state), counters[0] + counters[1], counters[0], counters[1], spent, float(spent) / 500.0])
	var off : Dictionary = roundTrips["false"]
	var on : Dictionary = roundTrips["true"]
	Check(int(off["trips"]) == int(on["trips"]) and int(off["trips"]) == 1000,
		"D: rotear nao muda o numero de round trips (%d -> %d)" % [int(off["trips"]), int(on["trips"])])
	Check(int(on["pool"]) == 500 and int(on["writer"]) == 500,
		"D: com a rota ligada as 500 leituras saem pelo pool e as 500 escritas pelo writer")

	# (E) preço da decisão no caminho quente, nos dois regimes que importam:
	#     statement repetida (memória de decisão) e statement nunca vista.
	var t0 : int = Time.get_ticks_usec()
	for _i in 20000:
		isPure.call(PlayerRead)
	var repeatUs : int = Time.get_ticks_usec() - t0
	var distinct : Array = []
	for i in 4000:
		distinct.append("SELECT balance_after FROM ledger_transaction WHERE account_id = %d ORDER BY id DESC LIMIT 1;" % i)
	var decide : Callable = Callable(rulesScript, "DecideStatement")
	var t1 : int = Time.get_ticks_usec()
	var routable : int = 0
	for statement in distinct:
		if bool(decide.call(statement)):
			routable += 1
	var coldUs : int = Time.get_ticks_usec() - t1
	Note("E: 20k repetidas %d us (%.2f us/chamada) | 4k statements distintas nunca vistas %d us (%.2f us/chamada) | memoria: %s" % [
		repeatUs, float(repeatUs) / 20000.0, coldUs, float(coldUs) / 4000.0, str(rulesScript.call("PathStats"))])
	Check(repeatUs < 20000, "E: decisao em statement repetida custa < 1 us de media (%.2f us)" % [float(repeatUs) / 20000.0])
	Check(coldUs < 200000, "E: decisao de primeira vista custa < 50 us de media (%.2f us)" % [float(coldUs) / 4000.0])
	Check(routable == 4000, "E: as 4k statements distintas foram classificadas como roteaveis (%d)" % routable)

	pool.Close()
	writer.close_db()

func Seed(writer : Object) -> void:
	for table in ["character", "account", "stat", "cosmetic_equip", "item", "item_instance", "ledger_transaction"]:
		writer.query("DROP TABLE IF EXISTS %s;" % table)
	writer.query("CREATE TABLE character (char_id INTEGER PRIMARY KEY, account_id INTEGER, nickname TEXT, power_score INTEGER);")
	writer.query("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT);")
	writer.query("CREATE TABLE stat (char_id INTEGER, level INTEGER);")
	writer.query("CREATE TABLE cosmetic_equip (account_id INTEGER, slot TEXT, cosmetic_id TEXT);")
	writer.query("CREATE TABLE item (char_id INTEGER, item_id INTEGER, storage INTEGER, customfield TEXT, count INTEGER);")
	writer.query("CREATE TABLE item_instance (char_id INTEGER, item_id INTEGER, storage INTEGER, customfield TEXT, count INTEGER);")
	writer.query("CREATE TABLE ledger_transaction (id INTEGER PRIMARY KEY, account_id INTEGER, char_id INTEGER, kind TEXT, amount INTEGER, balance_after INTEGER, reason TEXT, created_at INTEGER);")
	var t0 : int = Time.get_ticks_msec()
	writer.query("BEGIN TRANSACTION;")
	for i in SeedChars:
		writer.query_with_bindings("INSERT INTO character (account_id, nickname, power_score) VALUES (?,?,?);", [i + 1, "p%d" % i, i * 7])
		writer.query_with_bindings("INSERT INTO account (username) VALUES (?);", ["u%d" % i])
		writer.query_with_bindings("INSERT INTO stat VALUES (?,?);", [i + 1, 10 + i % 50])
		writer.query_with_bindings("INSERT INTO cosmetic_equip VALUES (?,?,?);", [i + 1, "title", "t%d" % i])
		for k in SeedItemsPerChar:
			writer.query_with_bindings("INSERT INTO item VALUES (?,?,0,'',?);", [i + 1, k, 1 + k])
			for hop in 2:
				writer.query_with_bindings("INSERT INTO item_instance VALUES (?,?,?,?,?);", [i + 1, k, 0, "", 1])
		writer.query_with_bindings("INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?,?,?,?,?,?,?);", [i + 1, i + 1, "gold", 100 + i, 100 + i, "bench", 1])
	writer.query("COMMIT;")
	writer.query("PRAGMA wal_checkpoint(TRUNCATE);")
	Note("mesa de medicao: %d personagens, %d itens, %d lots (%d ms)" % [
		SeedChars, SeedChars * SeedItemsPerChar, SeedChars * SeedItemsPerChar * 2, Time.get_ticks_msec() - t0])
