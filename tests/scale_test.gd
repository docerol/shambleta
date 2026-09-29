extends SceneTree

# scale_test.gd — harness de escalabilidade (AUDITORIA_2026-09-27 §12): retenção de
# ledger implementada e MEDIDA, com a disciplina de money-boundary intacta.
#
# Uso:    ./scripts/test.sh fixation   (caso descoberto por nome; marcador == RESULT:)
# Saída:  "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# O que ele responde, na ordem:
#   1) O CONTRATO PURO da partição (`SQLRetention`): o que é compactável e o que nunca
#      é, o root de agrupamento, e o cruzamento entre o predicado SQL e a função
#      GDScript — as duas vozes da mesma lista têm que concordar linha por linha sobre
#      um corpus de reasons reais.
#   2) O BANCO, no DB que o boot real migrou: a trigger de DELETE é condicional por
#      cobertura (linha crua sem agregado durável NÃO sai), UPDATE continua negado, e o
#      T2 recusa rodada cujo T1 não comitou — provado com um T1 envenenado que volta.
#   3) A MESA: um SEGUNDO `SQLService` (mesma classe de produção, migrations reais)
#      num arquivo temporário próprio, com ~74k linhas de ledger em 180 dias. A mesa é
#      de propósito separada do `testing.db` do sandbox: poda é operação destrutiva, e
#      um harness que acumula corpo a cada execução do gate vira relógio de areia.
#   4) A MEDIDA: as SOMAS/CAUDAS/PROVENIÊNCIAS lidas com o TEXTO DE SQL DA PRODUÇÃO
#      extraído dos fontes (`EconomyKernel.GetBalance`, `GetGoldLedgerSum`, o scan de
#      gold negativo do `ReconcileDaily`) — não com cópias deste harness, que é como
#      uma otimização passa a bater régua própria e continua quebrada em produção.
#      Bytes de arquivo, round trips, µs por leitura quente antes/depois, custo do
#      gatilho em regime estacionário e o preço real do VACUUM.
#   5) OS PLANOS: `EXPLAIN QUERY PLAN` da varredura de fronteira (PK seek, não SCAN) e
#      da leitura de cauda — as asserções que caem se alguém trocar o índice ou a ordem.
#   6) A FIAÇÃO do job no worker de backup e o botão de desligar.
#
# Nada aqui apaga nada de um banco de usuário: roda pelo `scripts/test.sh`, que aponta
# XDG_DATA_HOME para `.test-home/scale_test/`, e a mesa vive num diretório de /tmp criado
# para este run e destruído no fim. O nome é decidido por `DirAccess.make_dir_absolute`,
# que devolve erro se o diretório já existe — é o teste atômico que permite a duas
# execuções coexistirem. O lock do portão é por harness, mas um arquivo em /tmp não é
# protegido por ele, e duas execuções no mesmo `ledger.db` produziam um vermelho que não é
# do código. (`Godot 4` não expõe pid para o script, por isso a escolha é por nome livre
# em vez de `/tmp/shambleta-scale-<pid>`.)
var ScratchRoot : String = _FreshScratch("shambleta-scale")
var ScratchDB : String = ScratchRoot + "/ledger.db"

static func _FreshScratch(prefix : String) -> String:
	var base : String = OS.get_temp_dir().rstrip("/")
	for attempt in 64:
		var cand : String = "%s/%s-%d-%d" % [base, prefix, Time.get_unix_time_from_system(), randi()]
		if DirAccess.make_dir_absolute(cand) == OK:
			return cand
	# `ERR_ALREADY_EXISTS` em 64 nomes seguidos seria azar de `randi()`, não defeito do
	# código — mas voltar sem mesa é diagnóstico melhor do que escrever no diretório de
	# outra execução.
	return ""

const SeedAccounts : int		= 4
const SeedCharsPerAccount : int	= 6
const SeedDays : int			= 180
const KillRowsPerDay : int		= 20
const HorizonSec : int			= 90 * 86400
const DaySec : int				= 86400
const BatchRows : int			= 2000

# Orçamentos. São números que este arquivo mediu nesta máquina; crescer além deles é
# regression de caminho quente, não "variação de CI".
const BudgetSeedRows : int			= 30000
const BudgetTailReadUs : int		= 400
const BudgetIdleRunMs : int			= 40
const BudgetQueriesPerRawRow : float	= 1.0

var checks : int = 0
var failures : int = 0
var boot = null
var sql = null
var retention : GDScript = null
var bulkPredicateSQL : String = ""
var bulkParams : Array = []

func Note(text : String) -> void:
	print("  . " + text)

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func CheckEq(actual : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	# Comparar tipos diferentes aborta a expressão em GDScript 4, e a check abortada
	# não era contada como falha — a linha de resultado continuava limpa. Ver
	# `doc_facts_test.gd`, onde `scripts/ci_gate_log.sh` pegou isso em run verde.
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (esperado " + str(expected) + ", atual " + str(actual) + ")")
		return false
	return true

func Finish(dbs : GDScript) -> void:
	# Um preload em aberto não é vazamento benigno: o worker é destruído no meio do
	# parse e o processo segfaulta na saída (ver DB.DrainPendingPreloads).
	if dbs != null:
		dbs.call("DrainPendingPreloads")
	# A mesa de medição é efêmera: ~9 MB por run, e depois do veredito ela não é
	# evidência nenhuma, é lixo em /tmp. `Finish` é o único caminho de saída, então
	# é aqui que o corte vale para as saídas antecipadas também.
	for suffix in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(ScratchDB + suffix)
	DirAccess.remove_absolute(ScratchRoot)
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func OneInt(query : String, params : Array = []) -> int:
	var rows : Array = sql.QueryBindings(query, params)
	return int(rows[0].values()[0]) if not rows.is_empty() else -1

func PlanDetail(query : String, params : Array) -> String:
	var rows : Array = sql.QueryBindings("EXPLAIN QUERY PLAN " + query, params)
	var joined : String = ""
	for row in rows:
		joined += str(row.get("detail", "")) + " | "
	return joined

# Copia do truque de tests/read_pool_test.gd: certificar o TEXTO que roda em
# produção em vez de uma cópia deste harness.
func QuotedStatementFromSource(path : String, signature : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = String(file.get_as_text()).replace("\\\n", "")
	file.close()
	var at : int = text.find(signature)
	if at < 0:
		return ""
	var nextFunc : int = text.find("\nfunc ", at + signature.length())
	var chunk : String = text.substr(at) if nextFunc < 0 else text.substr(at, nextFunc - at)
	# O statement real pode ser montado por concatenação de linhas; o que importa
	# aqui é o primeiro literal entre aspas do trecho, que é onde a cláusula do
	# ledger mora nas três queries certificadas abaixo.
	var open : int = chunk.find("\"")
	if open < 0:
		return ""
	var close : int = chunk.find("\"", open + 1)
	return "" if close < 0 else chunk.substr(open + 1, close - open - 1)

func _initialize():
	print("== Escalabilidade (AUDITORIA 2026-09-27 §12): retenção de ledger medida ==")
	retention = load("res://sources/sql/SQLRetention.gd")
	var dbs : GDScript = load("res://sources/db/DB.gd")
	if not Check(retention != null, "SQLRetention.gd carrega"):
		Finish(dbs)
		return

	var launcher : Node = root.get_node_or_null(NodePath("Launcher"))
	if not Check(launcher != null, "autoload Launcher presente"):
		Finish(dbs)
		return
	var waited : int = 0
	while waited < 10000:
		await create_timer(0.25).timeout
		waited += 250
		boot = launcher.get("SQL")
		if boot != null and bool(boot.get("isInitialized")) and bool(dbs.get("isInitialized")):
			break
	if not Check(boot != null and bool(boot.get("isInitialized")), "Launcher.SQL inicializado"):
		Finish(dbs)
		return
	sql = boot
	Note("SQL pronto apos %d ms (sandbox .test-home/scale_test)" % waited)

	TestPureContract()
	TestDatabaseAuthorization()

	# Sem diretório próprio a mesa vira `/ledger.db` e o vermelho que sai daí não é do
	# código: é melhor dizer isso numa check do que abrir SQLite em caminho absurdo.
	if not Check(ScratchRoot != "", "este run tem diretório privativo em /tmp (%s)" % ScratchRoot):
		Finish(dbs)
		return
	sql = OpenScratch()
	if not Check(sql != null, "segundo SQLService abre a mesa em %s" % ScratchDB):
		sql = boot
		Finish(dbs)
		return
	var corpus : Dictionary = SeedCorpus()
	TestCompaction(corpus)
	CloseScratch()

	Finish(dbs)

# ---------------------------------------------------------------------------
# 1) contrato puro
# ---------------------------------------------------------------------------
func TestPureContract() -> void:
	print("-- 1) contrato de partição --")
	var reasonRoot : Callable = Callable(retention, "ReasonRoot")
	var isBulk : Callable = Callable(retention, "IsBulkReason")
	var predicate : Dictionary = retention.call("BulkPredicate")
	bulkPredicateSQL = str(predicate["sql"])
	bulkParams = predicate["params"]

	CheckEq(reasonRoot.call("offline_settle"), "offline_settle", "root de reason sem ':' e o proprio reason")
	CheckEq(reasonRoot.call("trade_out:9:12345"), "trade_out", "root para no primeiro ':'")
	CheckEq(reasonRoot.call("kill_z12"), "kill_z12", "linha de kill nao tem dois-pontos")

	# Proveniência de dinheiro: a lista que NUNCA sai, amarrada uma a uma.
	var protectedReasons : Array = [
		"refund:co-dlx-1", "clawback:pay-9", "grant:k-gems-1", "vip:grant-1",
		"trade_out:9:1", "trade_in:9:2", "ah_buy:77", "ah_list:77", "ah_creator_fee:77",
		"chest:1", "vault_deposit:3", "vault_withdraw:3", "referral_bonus:4:9",
		"season_prize:1:power:2", "tournament_prize:1:1", "pass_reward:free:8",
		"pass_pt:skip", "guild_create", "guild_level", "craft_submit_fee:tier3",
		"vendor:apple", "chest_buy:5", "trade_fee", "cosmetic:buy", "mail:7",
		"rollup:20408:offline_settle",
	]
	var leaked : Array = []
	for reason in protectedReasons:
		if bool(isBulk.call(reason)):
			leaked.append(reason)
	Check(leaked.is_empty(), "nenhum reason de proveniência de dinheiro é compactável (%s)" % [", ".join(PackedStringArray(leaked))])

	var bulkReasons : Array = ["offline_settle", "offline_settle:2", "kill_z1", "kill_z27", "settle"]
	var missed : Array = []
	for reason in bulkReasons:
		if not bool(isBulk.call(reason)):
			missed.append(reason)
	Check(missed.is_empty(), "todo reason de corpo esta na lista compactavel (%s)" % [", ".join(PackedStringArray(missed))])

	# As DUAS vozes da lista têm que concordar sobre o mesmo corpus: a função
	# GDScript que decide o bucket e o `LIKE`/`=` que decide o que sai do banco. Se
	# divergirem, a fronteira de id avança sobre uma linha que nunca foi agregada.
	var mismatch : int = 0
	for reason in protectedReasons + bulkReasons:
		var verdict : Array = sql.QueryBindings("SELECT 1 AS bulk FROM (SELECT ? AS reason) WHERE " + bulkPredicateSQL + ";", [reason] + bulkParams)
		if (not verdict.is_empty()) != bool(isBulk.call(reason)):
			mismatch += 1
			Note("divergencia gd/banco em '%s'" % str(reason))
	CheckEq(mismatch, 0, "predicado SQL concorda com IsBulkReason em todo o corpus")

	# Partição: dois personagens na mesma conta não se misturam, dias não se misturam,
	# kinds não se misturam, e o saldo que o agregado atesta é o da ÚLTIMA linha do
	# lote (não a média, não o primeiro).
	var rows : Array = [
		{"id": 1, "account_id": 10, "char_id": 100, "kind": "gold", "amount": 10, "balance_after": 10, "reason": "offline_settle", "created_at": 1 * DaySec + 5},
		{"id": 2, "account_id": 10, "char_id": 200, "kind": "gold", "amount": 20, "balance_after": 20, "reason": "offline_settle", "created_at": 1 * DaySec + 6},
		{"id": 3, "account_id": 10, "char_id": 100, "kind": "gold", "amount": -4, "balance_after": 6, "reason": "kill_z3", "created_at": 1 * DaySec + 7},
		{"id": 4, "account_id": 10, "char_id": 100, "kind": "gold", "amount": 5, "balance_after": 11, "reason": "kill_z3", "created_at": 2 * DaySec + 1},
		{"id": 5, "account_id": 10, "char_id": 100, "kind": "xp", "amount": 99, "balance_after": 99, "reason": "offline_settle", "created_at": 2 * DaySec + 2},
		{"id": 6, "account_id": 10, "char_id": 100, "kind": "gold", "amount": 7, "balance_after": 18, "reason": "refund:x", "created_at": 2 * DaySec + 3},
	]
	var buckets : Dictionary = retention.call("PlanFromRows", rows)
	CheckEq(buckets.size(), 5, "particao: 5 lotes (char, dia, kind e root separam; refund fica de fora)")
	var day1 : Dictionary = buckets.get("%d|10|100|gold|offline_settle" % DaySec, {})
	CheckEq(int(day1.get("tx_count", -1)), 1, "lote do dia 1 tem uma linha")
	var killDay1 : Dictionary = buckets.get("%d|10|100|gold|kill_z3" % DaySec, {})
	CheckEq(int(killDay1.get("net", -1)), -4, "net assinado do lote de kill")
	CheckEq(int(killDay1.get("inflow", -1)), 0, "inflow nao conta saida")
	CheckEq(int(killDay1.get("outflow", -1)), -4, "outflow preserva o sinal")
	CheckEq(int(killDay1.get("closing_balance", -1)), 6, "closing_balance e o saldo da ultima linha do lote")
	CheckEq(int(killDay1.get("opening_balance", -1)), 6, "opening_balance e o saldo da primeira linha do lote")
	CheckEq(int(killDay1.get("last_id", -1)), 3, "o id herdado e o id da ultima linha")
	CheckEq(int(retention.call("BucketsTotalRows", buckets)), 5, "BucketsTotalRows conta as linhas cruas dos lotes")
	CheckEq(retention.call("AggregateReason", DaySec * 2, "kill_z3"), "rollup:2:kill_z3", "reason do agregado em GDScript")
	var sqlReason : Array = sql.QueryBindings("SELECT ('rollup:' || (? / ?) || ':' || ?) AS r;", [DaySec * 2, DaySec, "kill_z3"])
	Check(not sqlReason.is_empty() and str(sqlReason[0]["r"]) == str(retention.call("AggregateReason", DaySec * 2, "kill_z3")),
		"a mesma string de reason montada em SQL e em GDScript")

# ---------------------------------------------------------------------------
# 2) autorização no banco: sem agregado durável não há drop
# ---------------------------------------------------------------------------
func TestDatabaseAuthorization() -> void:
	print("-- 2) gatilho de cobertura, UPDATE negado e T2 sem T1 --")
	# `presence_session` entra aqui como FATO DE SCHEMA (a migration 057 subiu na base
	# que o boot migrou) e nada mais: a vida da tabela — heartbeat, TTL, poda, os três
	# planos e os dois processos lendo o mesmo arquivo — é medida em
	# tests/presence_fuzz.gd, não nesta lista.
	for table in ["ledger_transaction", "ledger_daily_rollup", "ledger_compaction_cover", "ledger_compaction_run", "presence_session"]:
		CheckEq(OneInt("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = ? AND type = 'table';", [table]), 1,
			"tabela '%s' existe depois das migrations do boot" % table)
	var triggerText : String = ""
	for row in sql.QueryBindings("SELECT sql AS s FROM sqlite_master WHERE type='trigger' AND name='ledger_transaction_no_delete';", []):
		triggerText = str(row["s"])
	Check(triggerText.contains("ledger_compaction_cover"),
		"a trigger append-only so deixa sair linha coberta por agregado")
	var now : int = int(Time.get_unix_time_from_system())
	CheckEq(int(retention.call("CutoffAt", now, HorizonSec)), int(retention.call("DayStart", now - HorizonSec)),
		"o corte de retencao e meia-noite do dia `now - horizon`")
	Check(now - int(retention.call("CutoffAt", now, HorizonSec)) >= HorizonSec,
		"o corte nunca entra na janela de retencao (poda so o que ja venceu)")
	var probeAt : int = now - 400 * DaySec
	Check(bool(sql.ExecuteBindings("INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?,?,?,?,?,?,?);",
			[999001, 999002, "gold", 33, 33, "offline_settle", probeAt])), "linha crua de teste inserida")
	var probeID : int = OneInt("SELECT id FROM ledger_transaction WHERE account_id = 999001;", [])
	Check(probeID > 0, "id da linha de prova conhecido (%d)" % probeID)

	Check(not bool(sql.ExecuteBindings("DELETE FROM ledger_transaction WHERE id = ?;", [probeID])),
		"DELETE de linha crua SEM cobertura é negado pela trigger")
	Check(not bool(sql.ExecuteBindings("UPDATE ledger_transaction SET amount = 1 WHERE id = ?;", [probeID])),
		"UPDATE de linha crua continua negado (nada reescreve história)")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE id = ?;", [probeID]), 1, "a recusa não apagou nada")

	# T1 envenenado: o agregado é escrito DENTRO da transação que volta => nada
	# durável => o T2 não tem cobertura e o banco recusa. É isto que torna "agregado
	# antes do drop" uma garantia de banco e não um costume do código.
	var runID : int = retention.call("OpenRun", sql, now - HorizonSec, now)
	Check(runID > 0, "rodada de teste aberta para o T1 envenenado")
	var poisoned : Dictionary = {
		"probe": {
			"day": retention.call("DayStart", probeAt), "account_id": 999001, "char_id": 999002, "kind": "gold",
			"reason_root": "offline_settle", "ids": [probeID], "tx_count": 1, "inflow": 33, "outflow": 0, "net": 33,
			"opening_balance": 33, "closing_balance": 33, "first_id": probeID, "last_id": probeID,
			"first_at": probeAt, "last_at": probeAt,
		}
	}
	var wroteInside : Array = [false]
	var rolledBack : bool = sql.Transaction(func() -> bool:
		wroteInside[0] = int(retention.call("WriteAggregatesNoLock", sql, runID, poisoned, now)) >= 0
		return false)
	Check(wroteInside[0], "o T1 escreveu dentro da transação que estava por voltar")
	Check(not rolledBack, "Transaction() com lambda falso devolve false e desfaz o T1")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_compaction_cover WHERE run_id = ?;", [runID]), 0,
		"T1 desfeito: nenhuma linha de cobertura durável")
	Check(not bool(retention.call("ApplyRun", sql, runID, now)), "T2 sem T1 cometido é recusado")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE id = ?;", [probeID]), 1,
		"e a linha crua continua lá (drop só depois do agregado durável)")

	# O caminho inverso, com T1 cometido: aí sim a linha sai, e sai no lugar dela.
	CheckEq(int(retention.call("WriteAggregates", sql, runID, poisoned, now)), 1, "T1 honesto comita (1 agregado)")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_compaction_cover WHERE run_id = ?;", [runID]), 1, "cobertura durável escrita")
	Check(bool(retention.call("ApplyRun", sql, runID, now)), "T2 com cobertura aplicada")
	# Contar por id sozinho acharia a própria linha-agregado: o contrato do T2 é o
	# agregado HERDAR o id da última linha crua do lote (e a régua logo abaixo pinha
	# isso positivamente). O que tem que sumir é o CRU naquele id.
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE id = ? AND reason NOT LIKE 'rollup:%';", [probeID]), 0,
		"a linha crua podada saiu do id que o agregado passou a ocupar")
	CheckEq(OneInt("SELECT COALESCE(SUM(amount), 0) AS s FROM ledger_transaction WHERE account_id = 999001;", []), 33,
		"a soma da conta sobreviveu ao drop via linha-agregado")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE id = ? AND reason LIKE 'rollup:%';", [probeID]), 1,
		"a linha-agregado herda o id da linha crua que substituiu")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_compaction_run WHERE id = ? AND status = 'done' AND rows_dropped = 1;", [runID]), 1,
		"a rodada registra quantas linhas caíram e fecha")

	for cleanup in [
		"DELETE FROM ledger_transaction WHERE id = ?;",
		"DELETE FROM ledger_compaction_cover WHERE run_id = ?;",
		"DELETE FROM ledger_daily_rollup WHERE run_id = ?;",
		"DELETE FROM ledger_compaction_run WHERE id = ?;",
	]:
		sql.ExecuteBindings(cleanup, [probeID if cleanup.contains("ledger_transaction") else runID])

# ---------------------------------------------------------------------------
# 3) mesa de medição: segundo SQLService, arquivo próprio
# ---------------------------------------------------------------------------
func OpenScratch():
	# Mesma classe de produção, outro arquivo. A base nasce do MESMO template do boot
	# (`SQLCommons.CopyDatabase`) e recebe as migrations reais: é o caminho exato de um
	# servidor novo, e é por isso que a mesa prova as migrations 056/057 subindo do
	# zero em vez de herdar um `testing.db` com estado de corrida anterior.
	DirAccess.make_dir_recursive_absolute(ScratchRoot)
	for suffix in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(ScratchDB + suffix)
	var commons : GDScript = load("res://sources/sql/SQLCommons.gd")
	if not bool(commons.call("CopyDatabase", ScratchDB)):
		Note("mesa nao nasceu do template")
		return null
	var handle : SQLite = SQLite.new()
	handle.path = ScratchDB
	handle.verbosity_level = SQLite.QUIET
	if not handle.open_db():
		Note("mesa nao abriu em %s: %s" % [ScratchDB, String(handle.error_message)])
		return null
	var node = load("res://sources/sql/SQL.gd").new()
	node.db = handle
	node.Query("PRAGMA journal_mode=WAL;")
	node.Query("PRAGMA busy_timeout=5000;")
	node.ApplyMigrations()
	return node

func CloseScratch() -> void:
	sql.db.close_db()
	sql.free()
	sql = boot

func SeedCorpus() -> Dictionary:
	print("-- 3) mesa: %d contas x %d chars x %d dias --" % [SeedAccounts, SeedCharsPerAccount, SeedDays])
	var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var chars : Array = []
	for accountIndex in SeedAccounts:
		var username : String = "scale_acct_%d" % accountIndex
		sql.AddAccount(username, "senha-de-teste-123", "%s@scale.test" % username, "", "", "")
		var accountID : int = int(sql.GetAccountID(username))
		for charIndex in SeedCharsPerAccount:
			var nickname : String = "scale_%d_%d" % [accountIndex, charIndex]
			sql.AddCharacter(accountID, nickname, actorCommons.DefaultStats, actorCommons.DefaultTraits, actorCommons.DefaultAttributes)
			chars.append({"account_id": accountID, "char_id": int(sql.GetCharacterID(accountID, nickname))})
	Check(not chars.is_empty(), "personagens da mesa existem no banco")

	var now : int = int(Time.get_unix_time_from_system())
	var balances : Dictionary = {}
	var rows : Array = []
	var order : int = 0
	for day in range(SeedDays, 0, -1):
		var createdAt : int = now - day * DaySec + 3600
		var charIndex : int = 0
		for entry in chars:
			var accountID : int = int(entry["account_id"])
			var charID : int = int(entry["char_id"])
			# Janela própria por personagem dentro do dia (50 min), e offsetos que só
			# crescem. O `(order % 50)` que esteve aqui gerava timestamp MAIS VELHO para
			# id maior — 4312 inversões medidas — e a régua de monotonicidade acusava a
			# mesa, não o produto. A fronteira por id do `LedgerAppend` pressupõe tempo
			# crescente com id; inocular desordem na seed seria medir um escritor que não
			# existe em lugar nenhum.
			var at : int = createdAt + charIndex * 3000
			charIndex += 1
			var lineIndex : int = 0
			for line in [
				{"kind": "gold", "amount": 120 + (day % 37), "reason": "offline_settle"},
				{"kind": "xp", "amount": 500 + (day % 53), "reason": "offline_settle"},
				{"kind": "essence", "amount": 3, "reason": "offline_settle"},
			]:
				order += 1
				rows.append(MakeLedgerRow(accountID, charID, str(line["kind"]), int(line["amount"]), str(line["reason"]), at + lineIndex, balances))
				lineIndex += 1
			for kill in KillRowsPerDay:
				order += 1
				rows.append(MakeLedgerRow(accountID, charID, "gold", 7 + kill, "kill_z%d" % (1 + day % 40), at + 100 + kill * 30, balances))
	# Proveniência de dinheiro: uma linha de cada, espalhadas pela mesma janela, para
	# que a poda as encontre e NÃO as toque.
	for entry in chars:
		var accountID : int = int(entry["account_id"])
		var charID : int = int(entry["char_id"])
		var at : int = now - (SeedDays - 5) * DaySec
		for line in [
			{"kind": "gems", "amount": 50, "reason": "grant:scale-%d" % charID},
			{"kind": "gems", "amount": -50, "reason": "refund:scale-%d" % charID},
			{"kind": "gems", "amount": -7, "reason": "clawback:scale-%d" % charID},
			{"kind": "item", "amount": 1, "reason": "chest:scale-%d" % charID},
			{"kind": "gold", "amount": -800, "reason": "trade_out:scale-%d:1" % charID},
			{"kind": "gold", "amount": 900, "reason": "ah_buy:scale-%d" % charID},
		]:
			rows.append(MakeLedgerRow(accountID, charID, str(line["kind"]), int(line["amount"]), str(line["reason"]), at, balances))

	var insertStatement : String = "INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES "
	var t1 : int = Time.get_ticks_msec()
	# Caixa, não escalar: GDScript captura variável local de lambda POR VALOR, então um
	# `insertedRows += chunk.size()` dentro do closure deixaria o escopo de fora em 0 e
	# a régua abaixo acusaria "mesa carregada (0 de 99504)" sobre uma mesa cheia — que
	# foi exatamente o que este harness fez na primeira vez que rodou. Mesma caixa de
	# `wroteInside` na mesa de prova.
	var seeded : Array = [0]
	var ok : bool = sql.Transaction(func() -> bool:
		var cursor : int = 0
		while cursor < rows.size():
			var chunk : Array = rows.slice(cursor, mini(cursor + 500, rows.size()))
			var clauses : PackedStringArray = []
			var params : Array = []
			for row in chunk:
				clauses.append("(?,?,?,?,?,?,?)")
				params.append_array([row["account_id"], row["char_id"], row["kind"], row["amount"], row["balance_after"], row["reason"], row["created_at"]])
			if not sql.ExecNoLock(insertStatement + ", ".join(clauses) + ";", params):
				return false
			seeded[0] += chunk.size()
			cursor += 500
		return true)
	Check(ok and seeded[0] == rows.size(), "mesa carregada (%d de %d linhas)" % [seeded[0], rows.size()])
	Note("seed: %d linhas em %d ms" % [seeded[0], Time.get_ticks_msec() - t1])
	Check(rows.size() >= BudgetSeedRows, "a mesa tem corpo suficiente para medir (%d linhas)" % rows.size())
	return {"chars": chars, "now": now, "rows": seeded[0]}

func MakeLedgerRow(accountID : int, charID : int, kind : String, amount : int, reason : String, createdAt : int, balances : Dictionary) -> Dictionary:
	var key : String = "%d|%d|%s" % [accountID, charID, kind]
	var balance : int = int(balances.get(key, 0)) + amount
	balances[key] = balance
	return {"account_id": accountID, "char_id": charID, "kind": kind, "amount": amount, "balance_after": balance, "reason": reason, "created_at": createdAt}

# ---------------------------------------------------------------------------
# 4) poda medida
# ---------------------------------------------------------------------------
func TestCompaction(corpus : Dictionary) -> void:
	print("-- 4) poda medida --")
	var now : int = int(corpus["now"])

	# Leituras da PRODUÇÃO, extraídas do fonte, não copiadas aqui.
	var balanceQuery : String = QuotedStatementFromSource("res://sources/economy/EconomyKernel.gd", "func GetBalance(")
	var goldSumQuery : String = QuotedStatementFromSource("res://sources/economy/EconomyKernel.gd", "func GetGoldLedgerSum(")
	var reconcileQuery : String = QuotedStatementFromSource("res://sources/economy/TournamentArenaService.gd", "func ReconcileDaily()")
	Check(balanceQuery.contains("balance_after") and balanceQuery.contains("ORDER BY id DESC LIMIT 1"),
		"SQL de cauda lido do fonte vivo (EconomyKernel.GetBalance)")
	Check(goldSumQuery.contains("SUM(amount)"), "SQL de soma vitalicio lido do fonte vivo (GetGoldLedgerSum)")
	Check(reconcileQuery.contains("HAVING total < 0"), "SQL do scan de gold negativo lido do fonte vivo (ReconcileDaily)")

	var accountID : int = int(corpus["chars"][0]["account_id"])
	var before : Dictionary = SnapshotLedger()
	var protectedBefore : Dictionary = SnapshotProtected()
	var pagesBefore : Dictionary = Pages()
	# Âncora de tamanho, mesma disciplina do resto da casa: sem isto, um `Pages()` que
	# não abre o arquivo devolve 0 e toda régua de byte vira comparação de zeros.
	Check(int(pagesBefore["bytes"]) > 0, "o arquivo da mesa é legível em bytes (%d)" % int(pagesBefore["bytes"]))
	var rowsBefore : int = int(before["rows"])
	Check(rowsBefore >= BudgetSeedRows, "corpo antes da poda: %d linhas" % rowsBefore)

	# O contrato da fronteira por id é a ordem de inserção acompanhar o tempo. Medido,
	# não assumido: linha fora de ordem ficaria crua para sempre (conservador, nunca
	# duplo), então contar é contar o risco real.
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM (SELECT created_at, LAG(created_at) OVER (ORDER BY id) AS prev"
		+ " FROM ledger_transaction WHERE " + bulkPredicateSQL + ") WHERE prev IS NOT NULL AND prev > created_at;", bulkParams), 0,
		"corpo compactavel esta em ordem id/created_at (fronteira por id e exata)")

	var planFrontier : String = PlanDetail("SELECT id FROM ledger_transaction WHERE id > ? AND created_at < ? AND "
		+ bulkPredicateSQL + " ORDER BY id LIMIT ?;", [0, now - HorizonSec] + bulkParams + [BatchRows])
	Check(planFrontier.contains("PRIMARY KEY") or planFrontier.contains("USING INTEGER PRIMARY KEY"),
		"varredura de fronteira busca por PK, nao SCAN do corpo (%s)" % planFrontier.left(160))
	var planTail : String = PlanDetail(balanceQuery, [accountID])
	Check(not planTail.contains("TEMP B-TREE") and not planTail.contains("CO-ROUTINE"),
		"leitura de cauda nao introduz ordenacao temporaria nem varre a tabela (%s)" % planTail.left(160))

	# Custo das três leituras quentes ANTES, com o corpo cheio.
	var tailUsBefore : int = TimeRead(balanceQuery, [accountID], 60)
	var sumUsBefore : int = TimeRead(goldSumQuery, [accountID, "gold"], 30)
	var reconcileUsBefore : int = TimeRead(reconcileQuery, [], 3)
	Note("antes: cauda %d us | soma conta %d us | scan reconcile %d us" % [tailUsBefore, sumUsBefore, reconcileUsBefore])
	Check(tailUsBefore >= 0 and sumUsBefore >= 0 and reconcileUsBefore >= 0, "as tres leituras quentes foram medidas")

	var t0 : int = Time.get_ticks_usec()
	sql.ResetCounters()
	var job : Dictionary = retention.call("RunRetentionJob", sql, now, 60)
	var jobUs : int = Time.get_ticks_usec() - t0
	var jobQueries : int = int(sql.QueryCount())
	var jobTx : int = int(sql.TransactionCount())
	var dropped : int = int(job.get("rows_dropped", 0))
	Note("poda: %d rodadas, lidas %d, dropadas %d, retomadas %d, ok=%s em %d ms (%d queries, %d tx)" % [
		int(job.get("rounds", 0)), int(job.get("rows_read", 0)), dropped,
		int(job.get("resumed", 0)), str(job.get("ok", false)), int(jobUs / 1000), jobQueries, jobTx])
	Check(bool(job.get("ok", false)), "job de retenção completou todas as rodadas")
	Check(dropped > 0, "linhas cruas saíram do arquivo (%d)" % dropped)

	var after : Dictionary = SnapshotLedger()
	var protectedAfter : Dictionary = SnapshotProtected()
	var pagesAfter : Dictionary = Pages()
	var summary : Dictionary = retention.call("Summary", sql)

	# (a) SOMAS IDÊNTICAS: o contrato que a auditoria cobra antes de qualquer
	#    conversa sobre bytes.
	CheckEq(after["totals"], before["totals"], "soma por kind identica antes/depois da poda (o contrato do dinheiro)")
	CheckEq(after["tails"], before["tails"], "saldo-atestado por (char,kind) identico antes/depois da poda")
	CheckEq(after["accountTotals"], before["accountTotals"], "soma vitalicia por (conta,kind) identica (leitura da producao)")

	# (b) PROVENIÊNCIA INTACTA, linha por linha, id por id.
	CheckEq(protectedAfter, protectedBefore, "cada linha de refund/clawback/grant/trade/chest continua crua, com o mesmo id e valor")
	CheckEq(protectedAfter.size(), protectedBefore.size(), "inventario de linhas protegidas nao encolheu")
	var chargeback : Dictionary = {}
	for row in sql.QueryBindings("SELECT id, char_id, amount, balance_after, created_at, reason FROM ledger_transaction WHERE reason LIKE 'refund:scale-%' OR reason LIKE 'clawback:scale-%' ORDER BY id;", []):
		chargeback[str(row["reason"])] = "%d:%d:%d" % [int(row["id"]), int(row["amount"]), int(row["balance_after"])]
	CheckEq(chargeback.size(), 2 * SeedAccounts * SeedCharsPerAccount,
		"trilha de refund+chargeback continua reconstruivel linha a linha (%d pares)" % (chargeback.size() / 2))

	# (c) cobertura e agregado batem com o que o banco diz que fez.
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_compaction_run WHERE status = 'aggregated';", []), 0,
		"nenhuma rodada presa entre T1 e T2")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_compaction_cover c WHERE EXISTS (SELECT 1 FROM ledger_transaction t WHERE t.id = c.ledger_id AND t.reason NOT LIKE 'rollup:%');", []), 0,
		"nenhuma linha crua sobreviveu a propria cobertura")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_daily_rollup r WHERE r.tx_count <> (SELECT COUNT(*) FROM ledger_compaction_cover c WHERE c.bucket_id = r.bucket_id);", []), 0,
		"tx_count de cada lote == numero de linhas cobertas no lote")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_daily_rollup r WHERE NOT EXISTS (SELECT 1 FROM ledger_compaction_cover c WHERE c.bucket_id = r.bucket_id);", []), 0,
		"nenhum agregado sem linha coberta (nada foi escrito duas vezes)")
	var rollupCovered : int = int(summary.get("covered", -1))
	CheckEq(rollupCovered, int(summary.get("cover_rows", -2)), "todo row cru removido tem exatamente uma linha de cobertura")
	var accounted : int = int(after["rows"]) + dropped - OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'rollup:%';", [])
	CheckEq(accounted, int(before["rows"]), "cruas restantes + removidas - agregados = corpo anterior (nada evaporou sem conta)")

	# (d) o agregado está na MESA na posição cronológica certa.
	var aggregates : int = OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'rollup:%';", [])
	CheckEq(aggregates, int(summary.get("buckets", -1)), "um linha-agregado por bucket")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction l WHERE l.reason LIKE 'rollup:%' AND NOT EXISTS (SELECT 1 FROM ledger_compaction_cover c WHERE c.ledger_id = l.id);", []), 0,
		"o id herdado pela linha-agregado e de uma linha que ela de fato substituiu")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'rollup:%' AND amount != (SELECT net FROM ledger_daily_rollup r WHERE r.aggregate_id = ledger_transaction.id);", []), 0,
		"amount do agregado == net do bucket")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'rollup:%' AND balance_after != (SELECT closing_balance FROM ledger_daily_rollup r WHERE r.aggregate_id = ledger_transaction.id);", []), 0,
		"balance_after do agregado == saldo da ultima linha engolida")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'rollup:%' AND created_at >= ?;", [int(retention.call("CutoffAt", now, HorizonSec))]), 0,
		"nenhum agregado cobre linha dentro da janela de retencao")

	# (e) arquivo: páginas mortas e o custo real de devolvê-las ao SO.
	Check(int(after["rows"]) < rowsBefore, "o corpo encolheu: %d -> %d linhas" % [rowsBefore, int(after["rows"])])
	Note("arquivo antes: %d bytes / %d paginas | depois: %d paginas, %d mortas" % [
		int(pagesBefore["bytes"]), int(pagesBefore["count"]), int(pagesAfter["count"]), int(pagesAfter["free"])])
	var tVacuum : int = Time.get_ticks_msec()
	sql.Query("VACUUM;")
	var vacuumMs : int = Time.get_ticks_msec() - tVacuum
	sql.Query("PRAGMA wal_checkpoint(TRUNCATE);")
	var pagesVacuumed : Dictionary = Pages()
	Note("VACUUM: %d ms | arquivo %d -> %d bytes (%d paginas mortas devolvidas)" % [
		vacuumMs, int(pagesBefore["bytes"]), int(pagesVacuumed["bytes"]), int(pagesAfter["free"])])
	Check(int(pagesVacuumed["bytes"]) < int(pagesBefore["bytes"]),
		"o arquivo encolhe de verdade depois de podar + VACUUM (%d -> %d bytes)" % [int(pagesBefore["bytes"]), int(pagesVacuumed["bytes"])])
	Check(vacuumMs < 30000, "VACUUM da mesa cabe numa janela de manutenção (%d ms)" % vacuumMs)

	# (f) leituras quentes depois.
	var tailUsAfter : int = TimeRead(balanceQuery, [accountID], 60)
	var sumUsAfter : int = TimeRead(goldSumQuery, [accountID, "gold"], 30)
	var reconcileUsAfter : int = TimeRead(reconcileQuery, [], 3)
	Note("depois: cauda %d us | soma conta %d us | scan reconcile %d us" % [tailUsAfter, sumUsAfter, reconcileUsAfter])
	Check(tailUsAfter <= maxi(tailUsBefore, BudgetTailReadUs), "a poda não encareceu a leitura de cauda (%d us -> %d us)" % [tailUsBefore, tailUsAfter])
	Check(sumUsAfter <= sumUsBefore, "a soma vitalicia por conta ficou mais barata com o corpo podado (%d us -> %d us)" % [sumUsBefore, sumUsAfter])
	Check(reconcileUsAfter <= reconcileUsBefore, "o scan do reconcile ficou mais barato com o corpo podado (%d us -> %d us)" % [reconcileUsBefore, reconcileUsAfter])

	# (g) custo marginal do writer e round trips por linha removida.
	var perRow : float = float(jobQueries) / float(maxi(1, dropped))
	Check(perRow <= BudgetQueriesPerRawRow,
		"round trips por linha removida e O(1) por lote, nao por linha: %.2f queries/linha (%d queries, %d tx)" % [perRow, jobQueries, jobTx])
	Note("writer: %d us de queryMutex para %d linhas podadas (%.2f us/linha)" % [jobUs, dropped, float(jobUs) / float(maxi(1, dropped))])

	# (h) regime estacionário: o gatilho de 6 h com nada para podar.
	var tIdle : int = Time.get_ticks_msec()
	var idle : Dictionary = retention.call("RunRetentionJob", sql, now, 5)
	var idleMs : int = Time.get_ticks_msec() - tIdle
	CheckEq(int(idle.get("rows_read", -1)), 0, "segunda passada não relê corpo já coberto (fronteira por id)")
	CheckEq(int(idle.get("rounds", -1)), 1, "e para na primeira rodada vazia, não em vinte")
	Check(idleMs <= BudgetIdleRunMs, "gatilho ocioso custa <= %d ms (%d ms)" % [BudgetIdleRunMs, idleMs])

	# (i) idempotência: re-aplicar não muda soma nenhuma.
	var repeat : Dictionary = retention.call("RunRetentionJob", sql, now + DaySec, 5)
	CheckEq(SnapshotLedger()["totals"], after["totals"], "rodada seguinte não altera as somas (%d linhas lidas)" % int(repeat.get("rows_read", 0)))

	# (j) botões e fiação.
	Check(bool(retention.call("RetentionEnabled")), "poda ligada por padrão")
	OS.set_environment("SHAMBLETA_LEDGER_RETENTION", "0")
	Check(not bool(retention.call("RetentionEnabled")), "SHAMBLETA_LEDGER_RETENTION=0 desliga a poda sem recompilar")
	var skipped : Dictionary = retention.call("RunRetentionJob", sql, now + DaySec, 5)
	CheckEq(str(skipped.get("skipped", "")), "disabled", "com o botão desligado o job não toca no banco")
	OS.set_environment("SHAMBLETA_LEDGER_RETENTION", "")
	var workerSource : String = FileAccess.get_file_as_string("res://sources/sql/SQLBackups.gd")
	Check(workerSource.contains("SQLRetention.RunRetentionJob(Launcher.SQL)"),
		"o worker de backup chama o job de retenção (fiação viva em SQLBackups.gd)")
	var commonsSource : String = FileAccess.get_file_as_string("res://sources/sql/SQLCommons.gd")
	Check(commonsSource.contains("LedgerRetentionIntervalSec"), "a cadência da poda é constante do serviço, não número solto no laço")
	Note("resumo: %d linhas cruas -> %d agregados (%d linhas por agregado)" % [
		int(after["rows"]), aggregates, int(round(float(dropped) / float(maxi(1, aggregates))))])

# ---------------------------------------------------------------------------
# snapshots e probes
# ---------------------------------------------------------------------------
func SnapshotLedger() -> Dictionary:
	var totals : Dictionary = {}
	# SOMENTE a soma por kind, e isto é decisão — não esquecimento: a poda existe para
	# trocar N linhas cruas por 1 linha-agregado, então CONTAR linhas muda por
	# construção e uma régua de contagem aqui só podia acusar de falha o próprio
	# sucesso da poda. Quem conserva a
	# contagem de entradas é o `tx_count` do lote, conferido pela régua de cobertura
	# ("cruas restantes + removidas - agregados = corpo anterior").
	for row in sql.QueryBindings("SELECT kind, COALESCE(SUM(amount),0) AS t FROM ledger_transaction GROUP BY kind;", []):
		totals[str(row["kind"])] = str(int(row["t"]))
	var tails : Dictionary = {}
	for row in sql.QueryBindings("SELECT char_id, kind, balance_after FROM ledger_transaction l WHERE id = (SELECT MAX(id) FROM ledger_transaction m WHERE m.char_id = l.char_id AND m.kind = l.kind) ORDER BY char_id, kind;", []):
		tails["%d|%s" % [int(row["char_id"]), str(row["kind"])]] = int(row["balance_after"])
	var accountTotals : Dictionary = {}
	for row in sql.QueryBindings("SELECT account_id, kind, COALESCE(SUM(amount),0) AS t FROM ledger_transaction GROUP BY account_id, kind ORDER BY account_id, kind;", []):
		accountTotals["%d|%s" % [int(row["account_id"]), str(row["kind"])]] = int(row["t"])
	return {"rows": OneInt("SELECT COUNT(*) AS n FROM ledger_transaction;", []), "totals": totals, "tails": tails, "accountTotals": accountTotals}

func SnapshotProtected() -> Dictionary:
	# A linha-agregado (`reason LIKE 'rollup:%'`) nasce do poda e também não é corpo
	# compactável, então `NOT BulkPredicate` sozinho a contaria como "protegida" e o
	# inventário cresceria depois da poda — que é o oposto do que a régua pergunta.
	var snapshot : Dictionary = {}
	for row in sql.QueryBindings("SELECT id, amount, balance_after, created_at, reason FROM ledger_transaction WHERE NOT (" + bulkPredicateSQL + ") AND reason NOT LIKE 'rollup:%' ORDER BY id;", bulkParams):
		snapshot[str(row["reason"])] = "%d:%d:%d:%d" % [int(row["id"]), int(row["amount"]), int(row["balance_after"]), int(row["created_at"])]
	return snapshot

func Pages() -> Dictionary:
	# Caminho absoluto cru: `file://` NÃO é o prefixo de caminho de SO do Godot 4 (ele
	# conhece `res://` e `user://`, e um `/...` é lido direto como OS path). Com o
	# prefixo, `open` devolvia nulo e as duas leituras de arquivo saíam 0 — a régua de
	# VACUUM abaixo só gritou porque compara `<` (0 < 0 é falso); com `<=` ela teria
	# ficado verde medindo dois zeros, que é o tipo de gate que ninguém desconfia.
	var file : FileAccess = FileAccess.open(ScratchDB, FileAccess.READ)
	var size : int = file.get_length() if file != null else 0
	if file != null:
		file.close()
	return {
		"bytes": size,
		"count": OneInt("PRAGMA page_count;", []),
		"free": OneInt("PRAGMA freelist_count;", []),
		"size": OneInt("PRAGMA page_size;", []),
	}

func TimeRead(query : String, params : Array, iterations : int) -> int:
	if query.is_empty():
		return -1
	var samples : Array = []
	for _i in iterations:
		var t0 : int = Time.get_ticks_usec()
		sql.QueryBindings(query, params)
		samples.append(Time.get_ticks_usec() - t0)
	samples.sort()
	return int(samples[samples.size() / 2])
