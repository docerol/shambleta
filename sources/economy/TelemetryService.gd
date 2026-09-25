extends ServiceBase
class_name TelemetryService

# SOM-IDLE D2: product telemetry — buffered event sink (login/settle/levelup).
# A economia (mint/burn/trade/VIP) já vive no ledger; o dashboard (/metrics no
# companion) cruza as duas fontes. Flush periódico em 1 transação; buffer
# limitado (drop-oldest) para nunca pressionar memória sob carga.

const FlushIntervalSec : float = 60.0
const BufferCap : int = 500

# ROADMAP_COMERCIAL S1: funil de receita — kinds reservados, nunca renomear
# (dashboard e queries históricas dependem destes nomes).
# K1 (AUDITORIA_INDEPENDENTE §23 Bloco 1 item 9): os eventos de dinheiro entram
# aqui. Antes só existia a ponta de progressão, então "cobrou e não entregou" não
# tinha como ser visto — o `purchase` é emitido na entrega do grant (o momento em
# que o produto cumpre), `checkout_intent` na intenção, e os dois carregam
# price_paid/currency no meta para o dashboard separar dinheiro de sandbox.
const FUNNEL_KINDS : Array[String] = ["onboarding_done", "first_boss", "first_chest", "d1_return",
	"checkout_intent", "purchase", "ah_list", "ah_buy", "ah_cancel", "trade", "rebirth", "pass_claim"]

var _buffer : Array[Dictionary] = []
var _accum : float = 0.0

func _post_launch():
	isInitialized = true

func Destroy():
	Flush()
	isInitialized = false

func _process(delta : float) -> void:
	if not isInitialized:
		return
	_accum += delta
	if _accum >= FlushIntervalSec:
		_accum = 0.0
		Flush()

# kind: login | settle | levelup. value: xp (settle), níveis (levelup), 1 (login).
func Record(kind : String, accountID : int = 0, charID : int = 0, value : int = 0, meta : String = "{}", fingerprint : Dictionary = {}) -> void:
	if _buffer.size() >= BufferCap:
		_buffer.pop_front()
	var event : Dictionary = {
		"created_at" = SQLCommons.Timestamp(),
		"account_id" = accountID, "char_id" = charID,
		"kind" = kind, "value" = value, "meta" = meta,
	}
	if not fingerprint.is_empty():
		event["fingerprint"] = JSON.stringify(fingerprint)
	_buffer.append(event)

func BufferedCount() -> int:
	return _buffer.size()

# ROADMAP_COMERCIAL S1: helper do funil — best-effort, valida o kind para
# evitar typo que quebra o dashboard. Retorna false se kind inválido.
func RecordFunnel(kind : String, accountID : int = 0, charID : int = 0, meta : String = "{}") -> bool:
	if not FUNNEL_KINDS.has(kind):
		return false
	Record(kind, accountID, charID, 1, meta)
	return true

# K1: evento de DINHEIRO — grava e dá flush imediato. O buffer de 60 s serve ao
# tráfego de progressão (login/settle/levelup), onde perder um evento no crash é
# irrelevante; perder um `purchase` é perder exatamente o número que existe para
# responder "cobramos e não entregamos?". Flush só faz transação se o buffer tem
# algo, então o custo é uma escrita por compra.
func RecordMoney(kind : String, accountID : int, charID : int = 0, meta : String = "{}") -> bool:
	if not RecordFunnel(kind, accountID, charID, meta):
		return false
	Flush()
	return true

# Esvazia o buffer em 1 transação. Retorna eventos persistidos.
func Flush() -> int:
	if _buffer.is_empty():
		return 0
	var batch : Array = _buffer.duplicate()
	var count : int = 0
	if Launcher.SQL.Transaction(func() -> bool:
		for event in batch:
			var fp : String = str(event.get("fingerprint", ""))
			var sql : String = "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?);"
			var bindings : Array = [int(event["created_at"]), int(event["account_id"]), int(event["char_id"]), str(event["kind"]), int(event["value"]), str(event["meta"]), fp]
			if not Launcher.SQL.db.query_with_bindings(sql, bindings):
				return false
		return true):
		count = batch.size()
		_buffer = _buffer.slice(count)
	return count

func Count(kind : String, sinceSec : int = 0) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ?;", [kind, sinceSec])
	return int(rows[0]["n"]) if not rows.is_empty() else 0

# ROADMAP_COMERCIAL S1: dashboard mínimo — 4 KPIs do funil + base de logins.
# Conta contas distintas (não eventos) desde sinceSec. Leitura pura, sem escrita.
func FunnelSummary(sinceSec : int = 0) -> Dictionary:
	var out : Dictionary = {}
	var kinds : Array[String] = ["login", "onboarding_done", "first_boss", "first_chest", "d1_return",
		"checkout_intent", "purchase"]
	for kind in kinds:
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
			"SELECT COUNT(DISTINCT account_id) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ?;", [kind, sinceSec])
		out[kind] = int(rows[0]["n"]) if not rows.is_empty() else 0
	return out

# K1: coorte D1/D7/D30 lida da view `cohort_retention` (migration 045), que é a
# régua reescrita de ROADMAP_COMERCIAL §Semana 2. A definição está no SQL e não
# mudou aqui: login no dia calendário UTC exato +1/+7/+30 a partir do dia-zero da
# conta. Contas sem login ficam fora do numerador E do denominador — somar "quem
# nunca abriu o jogo" embaixo de uma meta de retenção é como o healthcheck
# fictício nasceu.
# Retorna {"accounts", "d1", "d7", "d30"} em contas; percentual é conta do leitor
# (o dashboard corta por período, e aqui não há período a cortar).
func CohortSummary() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COUNT(*) AS n, COALESCE(SUM(d1), 0) AS d1, COALESCE(SUM(d7), 0) AS d7, "
		+ "COALESCE(SUM(d30), 0) AS d30 FROM cohort_retention;", [])
	if rows.is_empty():
		return {"accounts" = 0, "d1" = 0, "d7" = 0, "d30" = 0}
	var row : Dictionary = rows[0]
	return {"accounts" = int(row.get("n", 0)), "d1" = int(row.get("d1", 0)),
		"d7" = int(row.get("d7", 0)), "d30" = int(row.get("d30", 0))}
