extends RefCounted
class_name SQLRetention

# AUDITORIA_2026-09-27 §12 — política de retenção do ledger. A migration 056 criou
# as tabelas e a autorização de drop; este módulo é o único caminho que exerce essa
# autorização, e o faz em duas transações com ordem obrigatória:
#
#   T1 (dura)  : escreve o lote agregado (`ledger_daily_rollup`) + a cobertura
#                (`ledger_compaction_cover`) + vira o estado da rodada para
#                'aggregated'. Nada cru é tocado aqui.
#   T2 (aplica): apaga as linhas cruas COBERTAS (a trigger nega qualquer linha sem
#                cover, então apagar sem T1 cometido é erro de banco, não de código)
#                e insere a linha-agregado no lugar da última linha do lote.
#
# Crash entre T1 e T2: as linhas cruas continuam lá (rollback do T2 ou processo
# morto), o agregado está durável, e `FinishPendingRuns` retoma exatamente do ponto.
# Crash antes do commit do T1: não existe cover nem agregado, e a poda simplesmente
# não aconteceu — o ledger não tem estado intermediário.
#
# O que NUNCA sai: qualquer reason fora de `BulkExact`/`BulkPrefixes`. A lista é
# fechada e espelhada no predicado SQL pelo mesmo teste que amarra a trigger
# (tests/scale_test.gd), porque podar proveniência de dinheiro seria pior que o
# problema de arquivo que isto resolve.

const DaySec : int = 86400
# Nada mais novo que isto é candidato. O teto precisa ficar ACIMA do maior lookback
# que a economia faz em linha crua (contagem por reason do passe: temporada ~30 dias,
# fraude 24 h, funil 30 dias) — 90 dias deixa folga de 3× e ainda é o que derruba o
# "51 GB" da auditoria, porque o corpo antigo é o que pesa.
const HorizonSec : int = 90 * DaySec
const BatchRows : int = 2000
const CoverChunkRows : int = 500
const RollupRoot : String = "rollup"

const StatusOpen : String			= "open"
const StatusAggregated : String		= "aggregated"
const StatusDone : String			= "done"

# Reasons de corpo: alto volume, lidos só em agregado. `kill_z` é a linha de faucet
# que §7.1 do AUDITORIA_2026-09-27 manda escrever; entra aqui desde já para que o
# dia em que ela existir não reabra o problema de arquivo.
const BulkExact : PackedStringArray		= ["offline_settle", "settle"]
const BulkPrefixes : PackedStringArray	= ["kill_z", "offline_settle:", "settle:"]

# Root = o reason até o primeiro ':' (o resto é id de objeto, não classe contábil).
static func ReasonRoot(reason : String) -> String:
	var colon : int = reason.find(":")
	return reason if colon < 0 else reason.substr(0, colon)

static func IsBulkReason(reason : String) -> bool:
	if reason == RollupRoot or reason.begins_with(RollupRoot + ":"):
		return false
	if reason in BulkExact:
		return true
	for prefix in BulkPrefixes:
		if reason.begins_with(prefix):
			return true
	return false

# O MESMO conjunto de reasons, na voz do SQLite. `_FastCertify` de `SQLReadRules`
# não vê código e conteúdo separados aqui, então os padrões entram como binding.
static func BulkPredicate() -> Dictionary:
	var parts : PackedStringArray = []
	var params : Array = []
	for exact in BulkExact:
		parts.append("reason = ?")
		params.append(exact)
	for prefix in BulkPrefixes:
		parts.append("reason LIKE ?")
		params.append(prefix + "%")
	return {"sql": "(" + " OR ".join(parts) + ")", "params": params}

static func DayStart(timestamp : int) -> int:
	return int(float(timestamp) / float(DaySec)) * DaySec

# Corte alinhado ao dia: mantém o bucket diário estável entre rodadas.
static func CutoffAt(now : int, horizonSec : int = HorizonSec) -> int:
	return DayStart(now - horizonSec)

# Por baixo: a fronteira de id já processada. O cover é escrito para TODA linha
# processada, então `MAX(ledger_id)` é o frontier honesto — e é o que mantém o
# trabalho por rodada proporcional ao corpo NOVO, não ao arquivo inteiro. Varrer por
# `created_at` exigiria reler o morto a cada poda.
#
# A fronteira por id assume o invariante do `LedgerAppend`: `created_at` é o relógio
# do instante da escrita, então id e tempo crescem juntos. Um escritor que inventasse
# timestamp no passado deixaria linhas abaixo da fronteira sem poda — o efeito é o
# comportamento antigo (a linha fica crua para sempre), nunca soma duplicada.
# `tests/scale_test.gd` mede a monotonicidade da mesa em vez de assumir.
static func LowerBoundID(sql : Object) -> int:
	var rows : Array = sql.QueryBindings("SELECT COALESCE(MAX(ledger_id), 0) AS m FROM ledger_compaction_cover;", [])
	return int(rows[0]["m"]) if not rows.is_empty() else 0

static func EligibleRows(sql : Object, cutoffAt : int, batchRows : int) -> Array[Dictionary]:
	var predicate : Dictionary = BulkPredicate()
	var params : Array = [LowerBoundID(sql), cutoffAt]
	params.append_array(predicate["params"])
	params.append(batchRows)
	return sql.QueryBindings(
		"SELECT id, account_id, char_id, kind, amount, balance_after, reason, created_at FROM ledger_transaction"
		+ " WHERE id > ? AND created_at < ? AND " + predicate["sql"]
		+ " ORDER BY id LIMIT ?;", params)

# Partição pura (sem banco): linhas ordenadas por id -> lotes por
# (dia, conta, personagem, kind, root). É a função que decide o que vira agregado,
# então é testável linha por linha — e é testada assim.
static func PlanFromRows(rows : Array) -> Dictionary:
	var buckets : Dictionary = {}
	for row in rows:
		var reason : String = str(row.get("reason", ""))
		if not IsBulkReason(reason):
			continue
		var accountID : int = int(row.get("account_id", 0))
		var charID : int = int(row.get("char_id", 0))
		var kind : String = str(row.get("kind", ""))
		var id : int = int(row.get("id", 0))
		var amount : int = int(row.get("amount", 0))
		var createdAt : int = int(row.get("created_at", 0))
		var day : int = DayStart(createdAt)
		var root : String = ReasonRoot(reason)
		var key : String = "%d|%d|%d|%s|%s" % [day, accountID, charID, kind, root]
		if not buckets.has(key):
			buckets[key] = {
				"day": day, "account_id": accountID, "char_id": charID, "kind": kind, "reason_root": root,
				"ids": [], "tx_count": 0, "inflow": 0, "outflow": 0, "net": 0,
				"opening_balance": int(row.get("balance_after", 0)), "closing_balance": int(row.get("balance_after", 0)),
				"first_id": id, "last_id": id, "first_at": createdAt, "last_at": createdAt,
			}
		var bucket : Dictionary = buckets[key]
		bucket["ids"].append(id)
		bucket["tx_count"] = int(bucket["tx_count"]) + 1
		bucket["net"] = int(bucket["net"]) + amount
		if amount >= 0:
			bucket["inflow"] = int(bucket["inflow"]) + amount
		else:
			bucket["outflow"] = int(bucket["outflow"]) + amount
		if id < int(bucket["first_id"]):
			bucket["first_id"] = id
			bucket["opening_balance"] = int(row.get("balance_after", 0))
		if id > int(bucket["last_id"]):
			bucket["last_id"] = id
			bucket["closing_balance"] = int(row.get("balance_after", 0))
		if createdAt < int(bucket["first_at"]):
			bucket["first_at"] = createdAt
		if createdAt > int(bucket["last_at"]):
			bucket["last_at"] = createdAt
	return buckets

# Razão publicada na linha-agregado. A string é montada em SQL pela mesma fórmula
# (`'rollup:' || day || ':' || reason_root`); o teste amarra as duas.
static func AggregateReason(day : int, root : String) -> String:
	return "%s:%d:%s" % [RollupRoot, int(float(day) / float(DaySec)), root]

static func OpenRun(sql : Object, cutoffAt : int, now : int) -> int:
	sql.ExecuteBindings("INSERT INTO ledger_compaction_run (started_at, cutoff_at, status) VALUES (?, ?, ?);", [now, cutoffAt, StatusOpen])
	var rows : Array = sql.QueryBindings("SELECT last_insert_rowid() AS id;", [])
	return int(rows[0]["id"]) if not rows.is_empty() else 0

# T1 — o agregado fica durável. Uma transação só: ou lote + cobertura + estado
# existem juntos, ou não existe nada e o corpo permanece intocado.
static func WriteAggregates(sql : Object, runID : int, buckets : Dictionary, now : int) -> int:
	var written : Array = [-1]
	var committed : bool = sql.Transaction(func() -> bool:
		written[0] = WriteAggregatesNoLock(sql, runID, buckets, now)
		return written[0] >= 0)
	return written[0] if committed else -1

static func WriteAggregatesNoLock(sql : Object, runID : int, buckets : Dictionary, now : int) -> int:
	var written : int = 0
	for key in buckets:
		var b : Dictionary = buckets[key]
		if not sql.ExecNoLock(
				"INSERT INTO ledger_daily_rollup (run_id, day, account_id, char_id, kind, reason_root, aggregate_id,"
				+ " tx_count, inflow, outflow, net, opening_balance, closing_balance, first_id, last_id, first_at, last_at, compacted_at)"
				+ " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);",
				[runID, b["day"], b["account_id"], b["char_id"], b["kind"], b["reason_root"], b["last_id"],
					b["tx_count"], b["inflow"], b["outflow"], b["net"], b["opening_balance"], b["closing_balance"],
					b["first_id"], b["last_id"], b["first_at"], b["last_at"], now]):
			return -1
		var ids : Array = sql.ExecNoLockQuery("SELECT last_insert_rowid() AS id;", [])
		if ids.is_empty():
			return -1
		var bucketID : int = int(ids[0]["id"])
		if not WriteCoverNoLock(sql, runID, int(b["last_id"]), bucketID, b["ids"], now):
			return -1
		written += 1
	sql.ExecNoLock("UPDATE ledger_compaction_run SET aggregated_at = ?, status = ?, rows_read = (SELECT COUNT(*) FROM ledger_compaction_cover WHERE run_id = ?), aggregates_written = ? WHERE id = ?;",
		[now, StatusAggregated, runID, written, runID])
	return written

static func WriteCoverNoLock(sql : Object, runID : int, aggregateID : int, bucketID : int, ids : Array, now : int) -> bool:
	var cursor : int = 0
	while cursor < ids.size():
		var chunk : Array = ids.slice(cursor, mini(cursor + CoverChunkRows, ids.size()))
		var clauses : PackedStringArray = []
		var params : Array = []
		for id in chunk:
			clauses.append("(?,?,?,?,?)")
			params.append(int(id))
			params.append(runID)
			params.append(aggregateID)
			params.append(bucketID)
			params.append(now)
		if not sql.ExecNoLock("INSERT OR IGNORE INTO ledger_compaction_cover (ledger_id, run_id, aggregate_id, bucket_id, compacted_at) VALUES " + ", ".join(clauses) + ";", params):
			return false
		cursor += CoverChunkRows
	return true

# T2 — só agora o cru sai, e só porque o cover do T1 comitou. A ordem dentro da
# transação é apagar e depois inserir: a linha-agregado herda o id da última linha
# do lote, e o id tem que estar livre antes de ser reassumido.
#
# A primeira coisa que o T2 faz é ler o ESTADO DA RODADA, não o cover: uma rodada
# sem `status = 'aggregated'` não tem T1 cometido, e apagaria corpo sem agregado
# nenhum (a trigger nega linha sem cover, mas uma rodada vazia não tem linha para
# negar — fecharia "ok" e mentiria no registro). É o que permite ao teste provar a
# recusa pelo banco em vez de confiar na ordem do código.
static func ApplyRun(sql : Object, runID : int, now : int) -> bool:
	return sql.Transaction(func() -> bool:
		var state : Array = sql.ExecNoLockQuery("SELECT status FROM ledger_compaction_run WHERE id = ?;", [runID])
		if state.is_empty() or str(state[0]["status"]) != StatusAggregated:
			return false
		if not sql.ExecNoLock("DELETE FROM ledger_transaction WHERE id IN (SELECT ledger_id FROM ledger_compaction_cover WHERE run_id = ?);", [runID]):
			return false
		# Se sobrou crua coberta, o drop não pegou: aborta antes de inserir qualquer
		# coisa. A ordem É o conserto — a linha-agregado herda o id da última linha do
		# lote (linhas 210-211 acima), então conferir isto DEPOIS do INSERT contava a
		# própria linha-agregado como "crua que sobreviveu", devolvia false sempre,
		# e o ROLLBACK desfazia o poda inteira: a retenção rodava, media, abria
		# rodada, e nunca derrubava uma linha. O arquivo de 51 GB da auditoria §12
		# continuava crescendo com o job verde no log.
		var left : Array = sql.ExecNoLockQuery("SELECT COUNT(*) AS n FROM ledger_transaction WHERE id IN (SELECT ledger_id FROM ledger_compaction_cover WHERE run_id = ?);", [runID])
		if not left.is_empty() and int(left[0]["n"]) != 0:
			return false
		if not sql.ExecNoLock("INSERT INTO ledger_transaction (id, account_id, char_id, kind, amount, balance_after, reason, created_at)"
				+ " SELECT aggregate_id, account_id, char_id, kind, net, closing_balance, 'rollup:' || (day / " + str(DaySec) + ") || ':' || reason_root, last_at"
				+ " FROM ledger_daily_rollup WHERE run_id = ? ORDER BY aggregate_id;", [runID]):
			return false
		var covers : Array = sql.ExecNoLockQuery("SELECT COUNT(*) AS n FROM ledger_compaction_cover WHERE run_id = ?;", [runID])
		var dropped : int = int(covers[0]["n"]) if not covers.is_empty() else 0
		return sql.ExecNoLock("UPDATE ledger_compaction_run SET finished_at = ?, rows_dropped = ?, status = ? WHERE id = ?;",
			[now, dropped, StatusDone, runID]))

static func PendingRuns(sql : Object) -> Array[Dictionary]:
	return sql.QueryBindings("SELECT id FROM ledger_compaction_run WHERE status = ? ORDER BY id;", [StatusAggregated])

static func FinishPendingRuns(sql : Object, now : int = 0) -> int:
	var stamp : int = SQLCommons.Timestamp() if now <= 0 else now
	var finished : int = 0
	for row in PendingRuns(sql):
		if ApplyRun(sql, int(row["id"]), stamp):
			finished += 1
	return finished

# Uma rodada completa: retoma o que ficou para trás, varre, agrega (T1), aplica (T2).
static func CompactLedger(sql : Object, now : int = 0, horizonSec : int = HorizonSec, batchRows : int = BatchRows) -> Dictionary:
	var stamp : int = SQLCommons.Timestamp() if now <= 0 else now
	var out : Dictionary = {"run_id": 0, "cutoff_at": 0, "rows_read": 0, "buckets": 0, "rows_dropped": 0, "resumed": 0, "ok": false}
	out["resumed"] = FinishPendingRuns(sql, stamp)
	var cutoff : int = CutoffAt(stamp, horizonSec)
	out["cutoff_at"] = cutoff
	var rows : Array[Dictionary] = EligibleRows(sql, cutoff, mini(batchRows, BatchRows))
	out["rows_read"] = rows.size()
	if rows.is_empty():
		out["ok"] = true
		return out
	var buckets : Dictionary = PlanFromRows(rows)
	out["buckets"] = buckets.size()
	var runID : int = OpenRun(sql, cutoff, stamp)
	if runID <= 0:
		return out
	out["run_id"] = runID
	if WriteAggregates(sql, runID, buckets, stamp) < 0:
		return out
	out["ok"] = ApplyRun(sql, runID, stamp)
	if bool(out["ok"]):
		out["rows_dropped"] = BucketsTotalRows(buckets)
	return out

static func BucketsTotalRows(buckets : Dictionary) -> int:
	var total : int = 0
	for key in buckets:
		total += int(buckets[key]["tx_count"])
	return total

# Resumo para o job diário e para o harness: quanto corpo virou quanto agregado.
static func Summary(sql : Object) -> Dictionary:
	var rows : Array = sql.QueryBindings(
		"SELECT (SELECT COUNT(*) FROM ledger_transaction) AS ledger_rows,"
		+ " (SELECT COUNT(*) FROM ledger_daily_rollup) AS buckets,"
		+ " (SELECT COALESCE(SUM(tx_count), 0) FROM ledger_daily_rollup) AS covered,"
		+ " (SELECT COUNT(*) FROM ledger_compaction_cover) AS cover_rows,"
		+ " (SELECT COUNT(*) FROM ledger_compaction_run WHERE status = '" + StatusAggregated + "') AS pending_runs;", [])
	return rows[0] if not rows.is_empty() else {}

# Botão do ops (mesma disciplina do read pool): desliga a poda sem recompilar.
static func RetentionEnabled() -> bool:
	var flag : String = OS.get_environment(SQLCommons.LedgerRetentionEnv).strip_edges().to_lower()
	return flag != "0" and flag != "off" and flag != "false"

# Entrada do worker de backup (`SQLBackups.Run`). Vários passes de BatchRows por
# gatilho, com teto: encurta a fila depois de um feriado sem deixar um único
# disparo dominar o writer por tempo ilimitado.
static func RunRetentionJob(sql : Object, now : int = 0, maxRounds : int = 0) -> Dictionary:
	var out : Dictionary = {"rounds": 0, "rows_read": 0, "rows_dropped": 0, "resumed": 0, "ok": true, "skipped": ""}
	if sql == null:
		out["ok"] = false
		out["skipped"] = "no_sql"
		return out
	if not RetentionEnabled():
		out["skipped"] = "disabled"
		return out
	var rounds : int = mini(maxRounds if maxRounds > 0 else SQLCommons.LedgerRetentionMaxRounds, 200)
	for _round in rounds:
		var result : Dictionary = CompactLedger(sql, now, HorizonSec, BatchRows)
		out["rounds"] = int(out["rounds"]) + 1
		out["rows_read"] = int(out["rows_read"]) + int(result.get("rows_read", 0))
		out["rows_dropped"] = int(out["rows_dropped"]) + int(result.get("rows_dropped", 0))
		out["resumed"] = int(out["resumed"]) + int(result.get("resumed", 0))
		if not bool(result.get("ok", false)):
			out["ok"] = false
			break
		# Fila vazia: parar aqui é o que faz o gatilho de 6 h custar um SELECT e não
		# vinte. A próxima rodada útil é quando created_at cruza a janela.
		if int(result.get("rows_read", 0)) == 0:
			break
	return out
