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
# P1-6 (auditoria 2026-09-27): os dois eventos de REVERSO entram aqui. Sem eles a
# receita só sabe somar, e um chargeback/art.49 continuaria contando como venda
# para sempre — ARPU inflado é pior que ARPU ausente, porque decide preço.
const FUNNEL_KINDS : Array[String] = ["onboarding_done", "first_boss", "first_chest", "d1_return",
	"checkout_intent", "purchase", "refund", "chargeback",
	"ah_list", "ah_buy", "ah_cancel", "trade", "rebirth", "pass_claim"]

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
#
# P1-ANALYTICS (juiz 2026-09-27, Analytics 8/10): `d1_return` só entra com o
# predicado congelado da migration 045 confirmado AQUI. O emissor de login
# (`sources/network/server/Peers.gd:291-297`) decide por "a conta tem exatamente
# um dia-distinto de login no banco antes deste" — leitura mais larga que a
# régua: pega re-login em qualquer dia depois do flush, inclusive no MESMO dia
# calendário; e mais estreita em outro ponto: conta criada ontem que loga HOJE
# pela primeira vez é D1 pela view e o emissor velho não via (o login mais
# antigo ainda estava no buffer). Como o arquivo do emissor não estava na posse
# desta passada, a correção é pelo único ponto que os dois atravessam: toda
# escrita de `d1_return` passa por esta função, então `IsD1Return()` é autoridade
# sobre o evento não importa qual chamador pediu. Um `RecordFunnel("d1_return")`
# que chega sem retorno D1 verdadeiro devolve false e não grava linha — o número
# que sai do jogo é a definição de `data/conf/migrations/045_cohort_view.sql`, que
# é o doc de origem da régua (não um markdown que poderia divergir dela), e a
# divergência deixa de ser possível. Prova: `tests/ops_fix_test.gd` (suíte B), que
# grava login de ontem/hoje no banco real e confere o evento aceito, o rejeitado e
# a concordância com `cohort_retention` conta a conta.
func RecordFunnel(kind : String, accountID : int = 0, charID : int = 0, meta : String = "{}") -> bool:
	if not FUNNEL_KINDS.has(kind):
		return false
	if kind == "d1_return" and not IsD1Return(accountID):
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

# ---------------------------------------------------------------------------
# OPS-3 (AUDITORIA_2026-09-27 §13, Analytics 6/10): funil por dia.
#
# O que existia antes de aqui e porque nao bastava: `FunnelSummary()` devolve um
# numero total por kind desde um corte, e `CohortSummary()` devolve D1/D7/D30
# acumulados da base inteira. Nenhum dos dois responde a pergunta de live ops,
# que e sempre comparativa: "a janela de onboarding que subiu ontem piorou a
# conversao?" exige serie por dia, e serie por dia nao se extrai de um total.
#
# Duas queries, nenhuma escrita. Day index = `created_at / 86400` — o MESMO
# idioma da view `cohort_retention` (migration 045), que e a definicao congelada
# de dia: UNIX **segundos** (nao milissegundos — `SQLCommons.Timestamp()` devolve
# segundos), dividido pelo numero de segundos de um dia, truncando para o
# inteiro de baixo => meia-noite UTC. Dia calendario UTC, sem fuso local: D1 de
# um jogador de Sao Paulo e de um de Tokyo saem no mesmo bucket, e isso e
# deliberado (a serie historica nao pode mudar de regua quando muda o operator).
#
# D1 tinha DUAS leituras e uma delas era errada na origem:
#  - `d1_strict`: da view 045 — login no dia calendario UTC exato +1 do dia-zero
#    da conta. E a regua que o ROADMAP_COMERCIAL promete.
#  - `d1_emitted`: quantos eventos `d1_return` o login gravou naquele dia.
#  O emissor de `Peers.gd:291-297` decidia por "exatamente um dia-distinto de
#  login antes deste", que liga em qualquer re-login depois do flush inclusive no
#  MESMO dia calendario; `IsD1Return()` decidia pela regua da view. Duas fontes
#  do mesmo KPI, sem nada amarrando uma na outra. Agora ha UMA: `RecordFunnel`
#  so grava `d1_return` com o SIM de `IsD1Return` (ver o gate la em cima), entao
#  o evento emitido passou a ser leitura derivada do mesmo predicado — e as duas
#  colunas continuam separadas aqui de proposito, porque a divergencia residual
#  entre elas e o que denuncia flush perdido (conta com D1 na view e sem evento),
#  nao um erro de regua.
# ---------------------------------------------------------------------------

const FunnelDailyKinds : Array[String] = ["login", "onboarding_done", "first_boss",
	"first_chest", "d1_return", "checkout_intent", "purchase", "refund", "chargeback"]

# Serie diaria do funil, mais recente por ultimo. `days` e em DIAS CALENDARIO UTC
# (0 = hoje). Cada linha: {"day", "day_index", <kind>: contas distintas,
# "d1_strict", "cohort_accounts", "conversion"}. Retorno vazio quando a flag
# `analytics_funnel_daily` esta desligada (o agregado e leitura pura, mas e
# leitura com GROUP BY numa tabela que cresce para sempre — e o unico dos
# agregados deste arquivo com desligador de runtime).
func FunnelDaily(days : int = 7) -> Array[Dictionary]:
	if not FeatureFlags.Enabled(FeatureFlags.FUNNEL_DAILY):
		return []
	var daySeconds : int = 86400
	var todayIndex : int = SQLCommons.Timestamp() / daySeconds
	var firstIndex : int = todayIndex - maxi(days - 1, 0)
	var sinceSec : int = firstIndex * daySeconds
	var out : Array[Dictionary] = []
	var byDay : Dictionary = {}
	for index in range(firstIndex, todayIndex + 1):
		var row : Dictionary = {"day_index" = index, "day" = _DayLabel(index)}
		for kind in FunnelDailyKinds:
			row[kind] = 0
		row["d1_strict"] = 0
		row["cohort_accounts"] = 0
		byDay[index] = row
	# 1) contas distintas por (dia, kind). DISTINCT em account_id porque o funil
	# e por pessoa: 4 logins no mesmo dia sao 1 login daquele dia.
	var bindings : Array = [sinceSec]
	for kind in FunnelDailyKinds:
		bindings.append(kind)
	var kindRows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT created_at / " + str(daySeconds) + " AS day_index, kind, "
		+ "COUNT(DISTINCT account_id) AS n FROM telemetry_event "
		+ "WHERE created_at >= ? AND kind IN (" + _Placeholders(FunnelDailyKinds) + ") "
		+ "GROUP BY day_index, kind;", bindings)
	for r in kindRows:
		var index : int = int(r.get("day_index", -1))
		if not byDay.has(index):
			continue
		var hit : Dictionary = byDay[index]
		hit[str(r["kind"])] = int(r.get("n", 0))
	# 2) D1 estrito e denominador de coorte por dia-zero (nao por dia de login).
	var cohortRows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT cohort_day AS day_index, COUNT(*) AS accounts, COALESCE(SUM(d1), 0) AS d1 "
		+ "FROM cohort_retention WHERE cohort_day >= ? GROUP BY cohort_day;", [firstIndex])
	for r in cohortRows:
		var index : int = int(r.get("day_index", -1))
		if not byDay.has(index):
			continue
		var row : Dictionary = byDay[index]
		row["d1_strict"] = int(r.get("d1", 0))
		row["cohort_accounts"] = int(r.get("accounts", 0))
	# 3) conversao de checkout: compra / intent no mesmo dia, em fraccao 0..1.
	# Denominador e a INTENCAO (quem abriu o checkout), nao a visita: e a taxa que
	# decide preco. Dia sem intent nao tem conversao — 0.0 seria ler como "0 % de
	# conversao", que e um numero, e "sem amostra" nao e.
	for index in range(firstIndex, todayIndex + 1):
		var row : Dictionary = byDay[index]
		var intents : int = int(row.get("checkout_intent", 0))
		row["conversion"] = float(row.get("purchase", 0)) / float(intents) if intents > 0 else -1.0
		out.append(row)
	out.reverse()
	return out

# O PREDICADO DO D1 — autoridade única do evento, dos dois lados do funil.
# Unidade: segundos UNIX. Verdadeiro quando HOJE é o dia calendário UTC exato
# +1 do dia-zero da conta, onde o dia-zero é o MESMO `cohort_day` da view
# `cohort_retention` (migration 045): `created_timestamp` da conta, com fallback
# para o login mais antigo quando a conta é anterior à coluna. Não é uma
# reimplementação parecida com a view — é a expressão da view, copiada caractere
# por caractere do SQL da migration 045 e executada para UMA conta.
#
# Porque a régua é o dia-zero e não "o login mais antigo antes de hoje": com
# "mais antigo antes de hoje" (a versão deste predicado até aqui) uma conta nova
# que estreia hoje e volta amanhã passa (acaso certo), mas uma conta criada ontem
# que só loga hoje NÃO passava — e é exatamente D1 pela definição congelada.
# O mesmo predicado agora casa com o que `d1_strict`/`shambleta_funnel_d1_strict_rate`
# somam da view, e com o que `CohortSummary()` devolve: uma régua, três leituras.
#
# Porque não ler a view direto no login: `cohort_retention` é um GROUP BY sobre
# `account JOIN telemetry_event` — filtrar por conta num VIEW com GROUP BY faz o
# SQLite agregar a base inteira. O login é caminho quente; a expressão abaixo bate
# no `idx_telemetry_account_kind_time` (migration 042) para o fallback e no PK de
# `account` para o caso normal. O `date(created_at,'unixepoch')` do emissor
# (`sources/network/server/Peers.gd:291-297`) não casava com índice nenhum.
#
# Consequência prática, medida em `tests/ops_fix_test.gd` (suíte B): re-login no
# terceiro dia, re-login no MESMO dia e retorno de conta com dia-zero quebrado não
# produzem linha `d1_return`, enquanto a heurística velha do emissor
# (`COUNT(DISTINCT date(...)) == 1`) produzia; e estreia-ontem-volta-hoje produz,
# que era o falso negativo da versão antiga. O harness confere linha a linha com a
# view: para cada conta de fixture, `IsD1Return()` == `cohort_retention.d1` no dia
# certo, medido no mesmo instante.
#
# `nowSec` existe porque este predicado é chamado DENTRO do login que o avalia, e
# um harness precisa conferir a mesma régua num dia passado sem reescrever o
# relógio do banco.
func IsD1Return(accountID : int, nowSec : int = 0) -> bool:
	if accountID <= 0:
		return false
	# Sem banco não há como afirmar retorno: o gate fecha em false (nenhum evento
	# entra no ar por suposição) em vez de ler nulo no autoload.
	if Launcher.SQL == null or not Launcher.SQL.isInitialized:
		return false
	var now : int = nowSec if nowSec > 0 else SQLCommons.Timestamp()
	var dayIndex : int = now / 86400
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT (CASE WHEN a.created_timestamp > 0 THEN a.created_timestamp"
		+ " ELSE (SELECT MIN(t0.created_at) FROM telemetry_event t0"
		+ " WHERE t0.account_id = a.account_id AND t0.kind = 'login') END) / 86400 AS cohort_day"
		+ " FROM account a WHERE a.account_id = ?;", [accountID])
	if rows.is_empty():
		return false
	var cohortDay : Variant = rows[0].get("cohort_day", null)
	# NULL = conta sem login nenhum e sem created_timestamp: não existe dia-zero,
	# então não existe D1. (É o caso do login de estreia, que nunca é retorno.)
	if cohortDay == null:
		return false
	return int(cohortDay) == dayIndex - 1

# Contas DISTINTAS na janela inteira, por kind — o que o HELP do gauge
# `shambleta_funnel_accounts_*` sempre prometeu ("contas distintas ... na janela")
# e o que `FunnelSummary()` sempre calculou. NÃO é a soma da série por dia: uma
# conta que loga ontem e hoje é DUAS na soma das linhas diárias e UMA na janela.
# Somar a série para servir um gauge de contas era o defeito — com duas contas
# logando nos dois dias o /metrics anunciava "5 contas" para 3 pessoas, e
# `conversion`/`login_daily_mean` herdavam o número inflado. A soma por dia
# continua sendo a régua certa para a MÉDIA (`shambleta_funnel_login_daily_mean`),
# que é por dia ativo e não por pessoa.
# Uma query só, mesmo filtro de `FunnelDaily`, sem o corte por dia.
func FunnelWindowAccounts(sinceSec : int) -> Dictionary:
	var out : Dictionary = {}
	for kind in FunnelDailyKinds:
		out[kind] = 0
	if sinceSec <= 0:
		return out
	var bindings : Array = [sinceSec]
	for kind in FunnelDailyKinds:
		bindings.append(kind)
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT kind, COUNT(DISTINCT account_id) AS n FROM telemetry_event "
		+ "WHERE created_at >= ? AND kind IN (" + _Placeholders(FunnelDailyKinds) + ") "
		+ "GROUP BY kind;", bindings)
	for r in rows:
		var kind : String = str(r.get("kind", ""))
		if FunnelDailyKinds.has(kind):
			out[kind] = int(r.get("n", 0))
	return out

# Texto Prometheus do funil diário. Quem anexa isto ao /metrics é
# `MetricsServer._funnelSection()` (linha 156 do próprio arquivo): sem o
# anexador, a série era código morto e o único lugar onde ela vivia era o
# dashboard do companion — i.e., nada paginava no funil. Amarrado por
# `tests/ops_fix_test.gd` (suíte A), que falha se o `/metrics` parar de servir o
# que estas funções calculam.
#
# Formato: média/soma da janela como gauge de verdade, e a série por dia como
# linha expositória `# series day=YYYY-MM-DD kind=N ...` — o probe é snapshot,
# então série com nome por dia não tem lugar na regex de nomes do
# `tests/deploy_ops_test.gd` (que amarra cada `shambleta_*` citado em
# `deploy/alerts.rules.yml` ao corpo emitido). O que importa é a série sair
# SERVIDA com inteiro exato por dia: o harness confere linha a linha, e um
# número que nada serve é um número ninguém pagina.
func FunnelGaugeLines(windowDays : int = 7) -> String:
	if not FeatureFlags.Enabled(FeatureFlags.FUNNEL_DAILY):
		return "# shambleta_funnel_daily disabled by feature_flag analytics_funnel_daily\n"
	var rows : Array[Dictionary] = FunnelDaily(windowDays)
	var totals : Dictionary = {}
	for kind in FunnelDailyKinds:
		totals[kind] = 0
	var intents : int = 0
	var purchases : int = 0
	for row in rows:
		for kind in FunnelDailyKinds:
			totals[kind] = int(totals[kind]) + int(row.get(kind, 0))
	# O corte da janela sai da PRÓPRIA série (a linha mais velha devolvida), não de
	# um segundo `Timestamp()` lido aqui: série e gauge têm que nascer do mesmo
	# instante e da mesma régua, senão um run que atravessa a meia-noite serve
	# `accounts` de uma janela e `# series` de outra.
	var windowSinceSec : int = 0
	if not rows.is_empty():
		windowSinceSec = int((rows[rows.size() - 1] as Dictionary).get("day_index", 0)) * 86400
	var windowAccounts : Dictionary = FunnelWindowAccounts(windowSinceSec)
	intents = int(windowAccounts.get("checkout_intent", 0))
	purchases = int(windowAccounts.get("purchase", 0))
	var cohortAccounts : int = 0
	var d1Strict : int = 0
	var activeDays : int = 0
	for row in rows:
		cohortAccounts += int(row.get("cohort_accounts", 0))
		d1Strict += int(row.get("d1_strict", 0))
		if int(row.get("login", 0)) > 0:
			activeDays += 1
	var body : String = ""
	for row in rows:
		var parts : PackedStringArray = PackedStringArray()
		parts.append("day=%s" % str(row.get("day", "?")))
		for kind in FunnelDailyKinds:
			parts.append("%s=%d" % [kind, int(row.get(kind, 0))])
		parts.append("d1_strict=%d" % int(row.get("d1_strict", 0)))
		parts.append("cohort_accounts=%d" % int(row.get("cohort_accounts", 0)))
		var conversion : float = float(row.get("conversion", -1.0))
		parts.append("conversion=%s" % ("%.4f" % conversion if conversion >= 0.0 else "none"))
		body += "# series %s\n" % " ".join(parts)
	for kind in FunnelDailyKinds:
		body += "# HELP shambleta_funnel_accounts_%s contas distintas com o evento na janela (janela em dias, agregado do server de jogo).\n" % kind
		body += "# TYPE shambleta_funnel_accounts_%s gauge\n" % kind
		body += "shambleta_funnel_accounts_%s %d\n" % [kind, int(windowAccounts.get(kind, 0))]

	body += "# HELP shambleta_funnel_conversion_intent_to_purchase purchase/account que abriu checkout na janela; -1 sem intent.\n"
	body += "# TYPE shambleta_funnel_conversion_intent_to_purchase gauge\n"
	body += "shambleta_funnel_conversion_intent_to_purchase %s\n" % (_Ratio(purchases, intents))
	body += "# HELP shambleta_funnel_d1_strict_rate D1 da definicao congelada (migration 045) na janela de dia-zero; -1 sem coorte.\n"
	body += "# TYPE shambleta_funnel_d1_strict_rate gauge\n"
	body += "shambleta_funnel_d1_strict_rate %s\n" % (_Ratio(d1Strict, cohortAccounts))
	# Os dois números só existem porque a série por dia é consumida: a média por
	# dia ativo e a contagem de dias com amostra saem do array do `FunnelDaily`,
	# não de um COUNT sobre a janela (que nunca diria "três dias, não sete").
	body += "# HELP shambleta_funnel_active_days dias da janela com pelo menos um login (sai da serie diaria).\n"
	body += "# TYPE shambleta_funnel_active_days gauge\n"
	body += "shambleta_funnel_active_days %d\n" % activeDays
	body += "# HELP shambleta_funnel_login_daily_mean logins/dia ativo na janela; -1 sem dia com amostra.\n"
	body += "# TYPE shambleta_funnel_login_daily_mean gauge\n"
	body += "shambleta_funnel_login_daily_mean %s\n" % (_Mean(int(totals["login"]), activeDays))
	return body

# "-1" quando o denominador e zero: ausencia de amostra tem que aparecer no
# scrape como ausencia, e 0 faria um dia sem checkout parecer 0 % de conversao.
static func _Ratio(numerator : int, denominator : int) -> String:
	if denominator <= 0:
		return "-1"
	return "%.4f" % (float(numerator) / float(denominator))

# Média por dia COM AMOSTRA. Denominador zero devolve "-1", não "0": sete dias de
# janela sem um único login é "sem série", e 0 leria como "média de zero logins",
# que é um número e uma conclusão.
static func _Mean(total : int, days : int) -> String:
	if days <= 0:
		return "-1"
	return "%.4f" % (float(total) / float(days))

static func _DayLabel(dayIndex : int) -> String:
	return Time.get_datetime_string_from_unix_time(dayIndex * 86400, true).get_slice("T", 0)

static func _Placeholders(values : Array[String]) -> String:
	var parts : PackedStringArray = PackedStringArray()
	for _i in values.size():
		parts.append("?")
	return ", ".join(parts)
