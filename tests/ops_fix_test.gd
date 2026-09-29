extends SceneTree

# ops_fix_test.gd — harness da lacuna P1-ANALYTICS / OPS-4 (juiz 2026-09-27:
# Analytics 8.0/10, Live Ops 9.2/10). É a prova que os comentários de
# `sources/economy/TelemetryService.gd`, `sources/system/MetricsServer.gd` e
# `sources/ops/LiveOpsCalendar.gd` prometiam e que NÃO existia: sem este arquivo,
# "d1_return tem um predicado" e "o funil diário é servido" eram afirmação de
#注释, não fato medido.
#
# Uso:
#   XDG_DATA_HOME=/tmp/impl-analytics/.data XDG_CACHE_HOME=/tmp/impl-analytics/.cache \
#     timeout 300 godot --headless --path . -s tests/ops_fix_test.gd
# Saída: "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# Contrato dos scripts `-s` do repo (ver `balance_test.gd` / `login_hardening_test.gd`):
# o harness compila ANTES dos autoloads, então nada de `TelemetryService`,
# `LiveOpsCalendar` ou `Launcher` como identificador global — classes entram por
# `load()`, instâncias por `root.get_node("Launcher")`.
#
# O que ele amarra, suíte a suíte:
#   A  o funil diário sai no `/metrics` (não é só calculado): nomes, inteiros por
#      dia e os quatro gauges derivados da série, conferidos contra um recálculo
#      independente no mesmo SQLite, com `cohort_retention` (view da migration
#      045) como fonte dos números de coorte; e o contador do anexo anda.
#   B  UM predicado de D1: `IsD1Return` é a expressão da view, o gate em
#      `RecordFunnel` recusa o evento que a heurística velha do emissor emitiria,
#      e para cada conta de fixture o SIM do gate bate com `cohort_retention.d1`.
#   C  kill switch de runtime (`analytics_funnel_daily`) desliga a série sem
#      quebrar os nomes que `deploy/alerts.rules.yml` já pagina.
#   D  `chest_bonus` cai no caminho real do budget de baú: `BuildReport` ( preview
#      do settle, mesma função do grant) entrega o baú turbinado e o teto diário
#      continua mandando; o eixo do XP não é tocado.
#   E  `tournament` cai no pool de prêmios: âncora em `ends_at`, banda fail-closed,
#      `prizes_json` aceito/rejeitado, e o anunciado == pago (sem ×2 sobre ×2).
#   F  a agenda RECUSA kind declarado sem consumidor: os três kinds implementados
#      têm a chamada real no arquivo do consumidor, lida do fonte.
#   G  `data/conf/liveops_calendar.json` tem campanha FUTURA real: parseia, o
#      `next_start` sai no `/metrics`, e dentro da janela dela os modificadores
#      aterrçam. Fora de janela o consumidor devolve o catálogo 1.0 — e o instante
#      fora de janela é DERIVADO do arquivo, nunca o relógio de quem roda, porque
#      desde a costura do Achado #98 o eixo `tournament` está no ar quase todos os
#      dias (só `double_xp`/`chest_bonus` é que têm de continuar fora do instante do
#      run: é isso o que protege o `SuiteSettleGolden`).

const DaySeconds : int = 86400
const HourSeconds : int = 3600
const CalendarResPath : String = "res://data/conf/liveops_calendar.json"
const WindowDays : int = 7

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Object = null
var _tele : Object = null
var _metrics : Node = null

var _teleScript : GDScript = null
var _cal : GDScript = null
var _offline : GDScript = null
var _arena : GDScript = null
var _catalog : GDScript = null
var _flags : GDScript = null
var _sqlCommons : GDScript = null
var _actorCommons : GDScript = null

var stamp : String = ""
var now : int = 0
var dayIndex : int = 0
var dayStart : int = 0
var fixtureAccounts : Array[int] = []
var fixtureChars : Array[int] = []

# ------------------------------------------------------------------ contagem

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(value), str(expected)])
		return false
	return true

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (+/-%f)" % [label, value, expected, tolerance])
		return false
	return true

func _contains(hay : String, needle : String, label : String) -> bool:
	return _check(hay.contains(needle), "%s (faltou \"%s\")" % [label, needle])

func _const(script : GDScript, name : String) -> Variant:
	return script.get_script_constant_map().get(name, null)

# ------------------------------------------------------------------ banco

func _query(sql : String, bindings : Array = []) -> Array[Dictionary]:
	return _sql.callv("QueryBindings", [sql, bindings])

func _exec(sql : String, bindings : Array = []) -> bool:
	return bool(_sql.callv("ExecuteBindings", [sql, bindings]))

func _count(sql : String, bindings : Array = []) -> int:
	var rows : Array[Dictionary] = _query(sql, bindings)
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func _newAccount(username : String, createdTs : int) -> int:
	var email : String = username + "@opsfix.test.local"
	if not bool(_sql.call("AddAccount", username, "opsfixpass", email)):
		return 0
	var accountID : int = int(_sql.call("GetAccountID", username))
	if accountID <= 0:
		return 0
	_sql.db.update_rows("account", "account_id = %d" % accountID, {"created_timestamp" = createdTs})
	fixtureAccounts.append(accountID)
	return accountID

func _newCharacter(accountID : int, nickname : String) -> int:
	if not bool(_sql.call("AddCharacter", accountID, nickname, _actorCommons.get("DefaultStats"), _actorCommons.get("DefaultTraits"), _actorCommons.get("DefaultAttributes"))):
		return 0
	var charID : int = int(_sql.call("GetCharacterID", accountID, nickname))
	if charID <= 0:
		return 0
	_sql.db.update_rows("character", "char_id = %d" % charID, {"farm_zone" = 1, "last_settled_at" = now - 9 * HourSeconds})
	fixtureChars.append(charID)
	return charID

func _login(accountID : int, ts : int) -> void:
	_exec("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'login', 1, '{}');", [ts, accountID])

func _funnelEvent(accountID : int, kind : String, ts : int) -> void:
	_exec("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, ?, 1, '{}');", [ts, accountID, kind])

func _d1Rows(accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'd1_return' AND account_id = ?;", [accountID])

# A definição congelada, recalculada AQUI por outro caminho de código: a view da
# migration 045 respondendo para uma conta. O harness não reimplementa a régua em
# GDScript — lê a mesma view que `/metrics` soma.
func _viewD1(accountID : int) -> int:
	var rows : Array[Dictionary] = _query("SELECT d1, cohort_day FROM cohort_retention WHERE account_id = ?;", [accountID])
	return int(rows[0].get("d1", 0)) if not rows.is_empty() else 0

func _viewCohortDay(accountID : int) -> int:
	var rows : Array[Dictionary] = _query("SELECT cohort_day FROM cohort_retention WHERE account_id = ?;", [accountID])
	return int(rows[0].get("cohort_day", -1)) if not rows.is_empty() else -1

# ------------------------------------------------------------------ run

func _initialize():
	_run()

func _run():
	print("== ops_fix harness: funil servido no /metrics, D1 com UM predicado, live ops com consumidor ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		_fatal("Launcher autoload missing")
		return
	var waited : int = 0
	while waited < 40000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_tele = _launcher.get("Telemetry")
		_metrics = _launcher.get("Metrics")
		if _sql != null and bool(_sql.get("isInitialized")) and _tele != null and _metrics != null:
			break
	if _sql == null or not bool(_sql.get("isInitialized")) or _tele == null or _metrics == null:
		_fatal("Launcher.SQL/Telemetry/Metrics não inicializaram (waited %d ms)" % waited)
		return
	_teleScript = load("res://sources/economy/TelemetryService.gd")
	_cal = load("res://sources/ops/LiveOpsCalendar.gd")
	_offline = load("res://sources/idle/OfflineSettle.gd")
	_arena = load("res://sources/economy/TournamentArenaService.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_flags = load("res://sources/ops/FeatureFlags.gd")
	_sqlCommons = load("res://sources/sql/SQLCommons.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	if not _check(_teleScript != null and _cal != null and _offline != null and _arena != null and _catalog != null and _flags != null and _sqlCommons != null and _actorCommons != null, "todos os scripts do corte compilam"):
		_finish()
		return
	if not _check(_tele.get_script() != null and str(_tele.get_script().resource_path).contains("TelemetryService.gd"), "Launcher.Telemetry é o TelemetryService do boot (o harness mede o serviço real, não uma cópia)"):
		_finish()
		return

	# O catálogo de conteúdo NÃO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` (`sources/db/DB.gd:224`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:228`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar só o SQL e medir com o
	# catálogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI não,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a máquina. O check nomeado é o
	# ponto — boot leve é vermelho visível, não medição parcial silenciosa.
	# Padrão de tests/content_hygiene_test.gd.
	var dbScript : GDScript = _dbScript()
	var dbReady : bool = false
	for i in 80:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (entities/maps/items carregados)"):
		_finish()
		return

	now = int(_sqlCommons.call("Timestamp"))
	dayIndex = int(now / DaySeconds)
	dayStart = dayIndex * DaySeconds
	stamp = str(now % 100000000)
	_bootstrapClean()

	_suiteServedFunnel()
	await _suiteD1Predicate()
	_suiteKillSwitch()
	_suiteChestBonus()
	_suiteTournamentPool()
	_suiteCalendarConsumers()
	_suiteFutureCampaign()

	_cleanup()
	_finish()

func _fatal(label : String):
	print("FATAL: " + label)
	print("== RESULT: %d checks, %d failures ==" % [checks, failures + 1])
	quit(1)

func _finish():
	if _cal != null:
		_cal.call("ClearRawForTests")
	if _flags != null:
		_flags.call("Forget", "analytics_funnel_daily")
	if _dbScript() != null:
		_dbScript().call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _dbScript() -> GDScript:
	return load("res://sources/db/DB.gd")

# Estado zero ANTES de medir: a série do funil é um GROUP BY sobre a tabela
# inteira, então linha de execução anterior (run que morreu no meio) entraria na
# régua como se fosse do fixture. Apaga só o que este harness cria.
func _bootstrapClean():
	_exec("DELETE FROM telemetry_event WHERE account_id IN (SELECT account_id FROM account WHERE username LIKE 'ofx%');", [])
	_exec("DELETE FROM telemetry_event WHERE account_id IN (SELECT account_id FROM account WHERE username LIKE 'ofx%');", [])

func _cleanup():
	for charID in fixtureChars:
		_exec("DELETE FROM chest_instance WHERE char_id = ?;", [charID])
		_exec("DELETE FROM stat WHERE char_id = ?;", [charID])
		_exec("DELETE FROM character WHERE char_id = ?;", [charID])
	for accountID in fixtureAccounts:
		_exec("DELETE FROM telemetry_event WHERE account_id = ?;", [accountID])
		_exec("DELETE FROM account WHERE account_id = ?", [accountID])

# ------------------------------------------------------------------ suíte A

# O corpo servido. `MetricsBody()` tem cache de 5 s de propósito; o probe abaixo
# derruba o cache e lê o texto que o scrape de `deploy/docker-compose.yml` veria.
func _metricsBody() -> String:
	_metrics.set("metricsCache", "")
	_metrics.set("metricsCacheAt", -1000000)
	_metrics.set("telemetryService", _tele)
	return String(_metrics.call("MetricsBody"))

func _gaugeValue(body : String, name : String) -> String:
	for line in body.split("\n", false):
		var text : String = String(line)
		if text.begins_with(name + " "):
			return text.substr(name.length() + 1).strip_edges()
		if text.begins_with(name) and text.length() > name.length() and text[name.length()] == "":
			return ""
	return "<ausente>"

func _seriesLines(body : String) -> Array[String]:
	var out : Array[String] = []
	for line in body.split("\n", false):
		if String(line).begins_with("# series day="):
			out.append(String(line))
	return out

func _suiteServedFunnel():
	print("[suite] A: o funil diário SAI no /metrics (média, série por dia e coorte da view)")
	var teleSrc : String = FileAccess.get_file_as_string("res://sources/economy/TelemetryService.gd")
	var metricsSrc : String = FileAccess.get_file_as_string("res://sources/system/MetricsServer.gd")
	_contains(teleSrc, "func FunnelDaily(days : int = 7)", "FunnelDaily existe no serviço")
	_contains(metricsSrc, "body += _funnelSection()", "o corpo do /metrics anexa a seção do funil")
	_contains(metricsSrc, "return tele.FunnelGaugeLines(FunnelWindowDays)", "e anexa o texto calculado pelo TelemetryService")

	# Fixture: duas contas criadas ontem (coorte de ontem) com login hoje (D1), e
	# uma conta hoje com intent+purchase. Números conhecidos, não "algum".
	var cohortA : int = _newAccount("ofx" + stamp + "a", dayStart - DaySeconds + 60)
	var cohortB : int = _newAccount("ofx" + stamp + "b", dayStart - DaySeconds + 90)
	var buyer : int = _newAccount("ofx" + stamp + "c", dayStart + 60)
	if not _check(cohortA > 0 and cohortB > 0 and buyer > 0, "três contas de fixture criadas"):
		return
	_login(cohortA, dayStart - DaySeconds + 120)
	_login(cohortA, dayStart + 30)
	_login(cohortB, dayStart - DaySeconds + 300)
	_login(cohortB, now - 10)
	_login(buyer, dayStart + 120)
	_funnelEvent(buyer, "checkout_intent", dayStart + 200)
	_funnelEvent(buyer, "purchase", dayStart + 240)
	_funnelEvent(cohortA, "first_chest", dayStart + 260)

	var callsBefore : int = int(_metrics.get("funnelSectionCalls"))
	var body : String = _metricsBody()
	var callsAfter : int = int(_metrics.get("funnelSectionCalls"))
	_check(callsAfter > callsBefore, "o anexo do funil roda de verdade (funnelSectionCalls %d -> %d)" % [callsBefore, callsAfter])

	for kind in (_teleScript.get("FunnelDailyKinds") as Array):
		var name : String = "shambleta_funnel_accounts_%s" % String(kind)
		_check(body.contains("\n" + name + " "), "/metrics serve %s" % name)
	for wanted : String in ["shambleta_funnel_conversion_intent_to_purchase", "shambleta_funnel_d1_strict_rate", "shambleta_funnel_active_days", "shambleta_funnel_login_daily_mean"]:
		_check(body.contains(wanted + " "), "/metrics serve %s" % wanted)
	_check(_seriesLines(body).size() == WindowDays, "a série por dia sai servida com %d linhas (janela == FunnelWindowDays), não só calculada: %d" % [WindowDays, _seriesLines(body).size()])

	# 1) Os gauges por kind batem com um recálculo INDEPENDENTE no mesmo banco.
	var kinds : Array = _teleScript.get("FunnelDailyKinds") as Array
	var sinceSec : int = (dayIndex - (WindowDays - 1)) * DaySeconds
	for kind in kinds:
		var k : String = String(kind)
		var expected : int = _count(
			"SELECT COUNT(DISTINCT account_id) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ? AND account_id IN (SELECT account_id FROM account WHERE username LIKE 'ofx%');",
			[k, sinceSec])
		var served : int = int(_gaugeValue(body, "shambleta_funnel_accounts_%s" % k))
		_checkEq(served, expected, "shambleta_funnel_accounts_%s servido == recálculo da janela (só contas do fixture)" % k)

	# 2) D1 servido é a VIEW, não um palpite: `cohort_retention` (migration 045)
	# restrito às contas do fixture, somado no dia-zero dentro da janela.
	var viewD1 : int = _count(
		"SELECT COALESCE(SUM(d1), 0) AS n FROM cohort_retention WHERE cohort_day >= ? AND account_id IN (SELECT account_id FROM account WHERE username LIKE 'ofx%');",
		[dayIndex - (WindowDays - 1)])
	var viewAccounts : int = _count(
		"SELECT COUNT(*) AS n FROM cohort_retention WHERE cohort_day >= ? AND account_id IN (SELECT account_id FROM account WHERE username LIKE 'ofx%');",
		[dayIndex - (WindowDays - 1)])
	_checkEq(viewD1, 2, "a view dá D1 = 2 para as duas contas criadas ontem com login hoje (fixture confere a view, não a gente)")
	_check(viewAccounts >= 3, "denominador de coorte da janela inclui as contas do fixture (%d)" % viewAccounts)
	var rows : Array[Dictionary] = _tele.call("FunnelDaily", WindowDays)
	var servedYesterday : Dictionary = {}
	for row in rows:
		if int(row.get("day_index", -1)) == dayIndex - 1:
			servedYesterday = row
	_check(not servedYesterday.is_empty(), "a série tem a linha do dia-zero de ontem")
	_checkEq(int(servedYesterday.get("d1_strict", -1)) >= 2, true, "d1_strict da linha de ontem carrega o SIM da view")
	_checkEq(int(servedYesterday.get("login", 0)) >= 2, true, "login de ontem conta as duas contas do fixture")
	_checkEq(int(servedYesterday.get("cohort_accounts", 0)) >= 2, true, "cohort_accounts de ontem é o denominador da view")
	var conversion : float = float(servedYesterday.get("conversion", -2.0))
	var intents : int = int(servedYesterday.get("checkout_intent", 0))
	var purchases : int = int(servedYesterday.get("purchase", 0))
	_checkNear(conversion, float(purchases) / float(intents) if intents > 0 else -1.0, 0.000001, "conversion da linha == purchase/checkout_intent da própria linha")

	# 3) A forma servida da série: cada linha tem que trazer o inteiro exato por
	# dia (é o que o harness do deploy não consegue raspar, e o que o operador lê).
	var yesterdayLine : String = ""
	for line in _seriesLines(body):
		if line.contains("day=" + _dayLabel(dayIndex - 1)):
			yesterdayLine = line
	_check(not yesterdayLine.is_empty(), "a linha expositória do dia de ontem saiu no corpo")
	_contains(yesterdayLine, "d1_strict=%d" % int(servedYesterday.get("d1_strict", -1)), "a série servida traz o d1_strict calculado")
	_contains(yesterdayLine, "cohort_accounts=%d" % int(servedYesterday.get("cohort_accounts", 0)), "e traz o denominador de coorte")

	# 4) Média/dias ativos só existem porque a série é consumida.
	var activeDays : int = 0
	var loginTotal : int = 0
	for row in rows:
		if int(row.get("login", 0)) > 0:
			activeDays += 1
		loginTotal += int(row.get("login", 0))
	_checkEq(int(_gaugeValue(body, "shambleta_funnel_active_days")), activeDays, "shambleta_funnel_active_days == dias com login na série")
	_checkNear(float(_gaugeValue(body, "shambleta_funnel_login_daily_mean")), float(loginTotal) / float(maxi(activeDays, 1)), 0.0001, "shambleta_funnel_login_daily_mean == média por dia ativo da série")
	_checkNot(_gaugeValue(body, "shambleta_funnel_login_daily_mean") == "-1", "há amostra, então a média não é o marcador de ausente")

	# 5) Conversão agregada da janela e o marcador de "sem amostra".
	var totalIntents : int = int(_gaugeValue(body, "shambleta_funnel_accounts_checkout_intent"))
	var totalPurchases : int = int(_gaugeValue(body, "shambleta_funnel_accounts_purchase"))
	_checkNear(float(_gaugeValue(body, "shambleta_funnel_conversion_intent_to_purchase")), float(totalPurchases) / float(totalIntents) if totalIntents > 0 else -1.0, 0.0001, "a conversão servida é purchase/intent da janela")
	_checkEq(String(_teleScript.call("_Ratio", 0, 0)), "-1", "sem intent não é lido como 0 % de conversão (é ausência)")
	_checkEq(String(_teleScript.call("_Mean", 7, 0)), "-1", "sem dia ativo a média é ausência, não zero")

	# 6) Contrato do deploy: nenhum nome já paginado saiu do corpo.
	for keep : String in ["shambleta_up ", "shambleta_players_online ", "shambleta_grant_queue_pending ", "shambleta_reconcile_divergences ", "shambleta_fraud_flags_open "]:
		_check(body.contains("\n" + keep), "nome já em deploy/alerts.rules.yml continua emitido: %s" % keep.strip_edges())

func _checkNot(condition : bool, label : String) -> bool:
	return _check(not condition, label)

func _dayLabel(index : int) -> String:
	return String(_teleScript.call("_DayLabel", index))

# ------------------------------------------------------------------ suíte B

func _suiteD1Predicate():
	print("[suite] B: UM predicado de D1 — gate, view e emissor na mesma régua")
	var dayBefore : int = dayStart - DaySeconds
	# (1) Retorno verdadeiro: conta criada ontem, login ontem, login hoje.
	var yes : int = _newAccount("ofx" + stamp + "d1yes", dayBefore + 60)
	_login(yes, dayBefore + 120)
	_login(yes, dayStart + 40)
	# (2) FALSO POSITIVO da heurística velha: conta de faz-tempo que só logou no
	# dia-zero. `COUNT(DISTINCT date) == 1` era verdadeiro e o emissor gravava
	# `d1_return` em qualquer re-login depois do flush — nunca foi D1.
	var stale : int = _newAccount("ofx" + stamp + "d1stale", dayStart - 4 * DaySeconds + 60)
	_login(stale, dayStart - 4 * DaySeconds + 300)
	# (3) FALSO NEGATIVO da heurística velha: conta criada ontem que loga HOJE pela
	# primeira vez. É D1 pela view; o emissor velho lia 0 dias-distintos (o login
	# de estreia ainda estava no buffer) e não gravava nada.
	var debut : int = _newAccount("ofx" + stamp + "d1debut", dayBefore + 30)
	_login(debut, dayStart + 50)
	# (4) Re-login no MESMO dia calendário: dois logins hoje, nenhum ontem.
	var samaday : int = _newAccount("ofx" + stamp + "d1samaday", dayStart + 10)
	_login(samaday, dayStart + 20)
	_login(samaday, dayStart + 30)
	if not _check(yes > 0 and stale > 0 and debut > 0 and samaday > 0, "quatro contas de D1 criadas"):
		return

	_checkEq(bool(_tele.call("IsD1Return", yes, now)), true, "IsD1Return: retorno no dia +1 do dia-zero é SIM")
	_checkEq(bool(_tele.call("IsD1Return", stale, now)), false, "IsD1Return: re-login 4 dias depois do dia-zero NÃO é D1")
	_checkEq(bool(_tele.call("IsD1Return", debut, now)), true, "IsD1Return: estreia ontem + logar hoje É D1 (a régua é o dia-zero, não 'teve um dia de login')")
	_checkEq(bool(_tele.call("IsD1Return", samaday, now)), false, "IsD1Return: re-login no MESMO dia calendário não é D1")
	_checkEq(bool(_tele.call("IsD1Return", 0, now)), false, "IsD1Return: conta anônima nunca é retorno")
	_checkEq(bool(_tele.call("IsD1Return", 999999999, now)), false, "IsD1Return: conta inexistente fecha em false")

	# A heurística velha, medida no banco: ela diria "emite" para a conta velha.
	var oldRows : Array[Dictionary] = _query("SELECT COUNT(DISTINCT date(created_at, 'unixepoch')) AS d FROM telemetry_event WHERE kind = 'login' AND account_id = ?;", [stale])
	var oldDays : int = int(oldRows[0].get("d", 0)) if not oldRows.is_empty() else 0
	_checkEq(oldDays, 1, "o emissor velho (COUNT DISTINCT date == 1) DIRIA sim para a conta de 4 dias atrás")

	# O gate: toda escrita de d1_return passa por RecordFunnel.
	_checkEq(bool(_tele.call("RecordFunnel", "d1_return", stale)), false, "RecordFunnel recusa o d1_return que a heurística velha emitiria")
	_checkEq(bool(_tele.call("RecordFunnel", "d1_return", samaday)), false, "RecordFunnel recusa re-login no mesmo dia")
	_checkEq(bool(_tele.call("RecordFunnel", "d1_return", yes)), true, "RecordFunnel aceita o D1 verdadeiro")
	_checkEq(bool(_tele.call("RecordFunnel", "d1_return", debut)), true, "RecordFunnel aceita o D1 que a heurística velha perdia")
	_checkEq(bool(_tele.call("RecordFunnel", "d1_return", 0)), false, "RecordFunnel não grava retorno anônimo")
	_checkEq(bool(_tele.call("RecordFunnel", "kind_inventado", yes)), false, "RecordFunnel continua recusando kind fora do funil")
	_tele.call("Flush")
	_checkEq(_d1Rows(stale), 0, "nenhuma linha d1_return para a conta velha (era aqui que o funil mentia)")
	_checkEq(_d1Rows(samaday), 0, "nenhuma linha d1_return para o re-login no mesmo dia")
	_check(_d1Rows(yes) >= 1, "o D1 verdadeiro virou linha no banco")
	_check(_d1Rows(debut) >= 1, "o D1 de estreia ontem virou linha no banco")

	# Uma régua, duas leituras: o SIM do gate == o que a view 045 soma.
	for accountID in [yes, debut, stale, samaday]:
		var gate : bool = bool(_tele.call("IsD1Return", accountID, now))
		var view : int = _viewD1(accountID)
		_checkEq(view, 1 if gate else 0, "gate e cohort_retention.d1 concordam para a conta %d (gate=%s view=%d)" % [accountID, str(gate), view])
	_checkEq(_viewCohortDay(yes), dayIndex - 1, "o dia-zero da view é o dia de ontem (fixture confere a régua da migration 045)")

	# O emissor continua chamando o funil — e agora só existe um caminho dele.
	var teleSrc : String = FileAccess.get_file_as_string("res://sources/economy/TelemetryService.gd")
	var peersSrc : String = FileAccess.get_file_as_string("res://sources/network/server/Peers.gd")
	_contains(peersSrc, "RecordFunnel(\"d1_return\", accountData.accountID)", "o emissor de login escreve pelo funil (o gate vale para ele)")
	_contains(teleSrc, "if kind == \"d1_return\" and not IsD1Return(accountID):", "o gate está em RecordFunnel, o chokepoint dos dois lados")
	# `Record()` cru o funil jamais: quem escreve kind de funil tem que passar pela
	# validação (senão um chamador novo fura o gate de novo).
	var emitterWrite : int = peersSrc.find("Telemetry.RecordFunnel(\"d1_return\"")
	var emitterRaw : int = peersSrc.find("Telemetry.Record(\"d1_return\"")
	_check(emitterWrite >= 0 and emitterRaw < 0, "o login não tem caminho cru de escrita de d1_return")

# ------------------------------------------------------------------ suíte C

func _suiteKillSwitch():
	print("[suite] C: kill switch analytics_funnel_daily desliga a série sem quebrar o scrape")
	var flagKey : String = String(_flags.get("FUNNEL_DAILY"))
	_check(_flags.call("IsKnown", flagKey), "a flag do funil diário é conhecida (FeatureFlags.FUNNEL_DAILY)")
	_checkEq(bool(_flags.call("DefaultOf", flagKey)), true, "liga por padrão (métrica de funil não é feature escondida)")
	var bodyOn : String = _metricsBody()
	_check(bodyOn.contains("shambleta_funnel_accounts_login "), "com a flag ligada o funil sai no corpo")
	if not _check(bool(_flags.call("Set", flagKey, "0")), "Set() da flag no banco (kill switch de runtime)"):
		return
	var dailyOff : Array = _tele.call("FunnelDaily", WindowDays)
	_checkEq(dailyOff.size(), 0, "desligada, FunnelDaily não roda o GROUP BY (devolve vazio)")
	var gaugeOff : String = String(_tele.call("FunnelGaugeLines", WindowDays))
	_contains(gaugeOff, "disabled by feature_flag analytics_funnel_daily", "e FunnelGaugeLines diz POR QUE sumiu (ausência muda de lugar, não é)")
	var bodyOff : String = _metricsBody()
	_check(not bodyOff.contains("shambleta_funnel_accounts_login "), "desligada, a série do funil não sai no corpo")
	_check(bodyOff.contains("\nshambleta_up "), "os nomes que a alerta já pagina continuam lá com o funil desligado")
	_check(bodyOff.contains("shambleta_liveops_calendar_valid "), "a agenda de live ops não depende da flag do funil")
	_check(bool(_flags.call("Forget", flagKey)), "Forget() restaura o default")
	_check(bool(_flags.call("Enabled", flagKey)), "e o funil volta ao ar sem reiniciar o processo")

# ------------------------------------------------------------------ suíte D

func _suiteChestBonus():
	print("[suite] D: chest_bonus cai no budget real de baú do settle, sob o teto diário")
	var settleSrc : String = FileAccess.get_file_as_string("res://sources/idle/OfflineSettle.gd")
	_contains(settleSrc, "static func LiveOpsChestMods(now : int) -> float:", "o seam do baú existe (puro: timestamp entra, float sai)")
	_contains(settleSrc, "LiveOpsCalendar.BonusMod(LiveOpsCalendar.KindChestBonus, now)", "e lê o kind certo da agenda")
	var formula : int = settleSrc.find("static func _ApplyFormula")
	if not _check(formula >= 0, "_ApplyFormula localizada"):
		return
	# O corpo da função, e NÃO um corte fixo de 3000 bytes: `_ApplyFormula` tem
	# ~5,3 KB de fonte (os comentários são a justificativa do faucet, não enfeite)
	# e a janela truncada parava no meio dos drops — o teste acusava "faltou" o
	# código da linha do cofre que existe arquivo afora. O corte é o próximo
	# `static func`, i.e. exatamente o corpo, sem vazar para a função vizinha.
	var nextFunc : int = settleSrc.find("\nstatic func ", formula + 1)
	var bodySpan : int = (nextFunc - formula) if nextFunc > formula else (settleSrc.length() - formula)
	var body : String = settleSrc.substr(formula, bodySpan)
	_check(nextFunc > formula, "o corpo de _ApplyFormula foi lido por inteiro (não cortado)")
	_contains(body, "var chestMods : float = LiveOpsChestMods(_now())", "a fórmula do settle consulta o modificador de baú")
	_contains(body, "chestWanted = maxi(chestWanted, roundi(float(chestWanted) * chestMods))", "e aplica na linha do cofre antes do teto")
	var applyAt : int = body.find("* chestMods)")
	var capAt : int = body.find("_ChestBudgetToday(sql, report.charID)")
	_check(applyAt >= 0 and capAt > applyAt, "o teto diário é aplicado DEPOIS da campanha (a agenda enche o dia mais cedo, não mintar mais baú)")
	_check(body.find("report.mods *") < body.find("var chestMods : float"), "o eixo do `mods` (XP/ouro/chaves) não toca a linha do baú")

	# Fail-closed no seam, com o arquivo injetado.
	var openTs : int = 1890000000
	_cal.call("SetRawForTests", _eventsRaw([_event("chest_bonus", "baus_teste", openTs, openTs + 2 * DaySeconds, 2.0)]))
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs + HourSeconds)), 2.0, 0.000001, "dentro da janela o seam devolve o valor do arquivo")
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs + 2 * DaySeconds)), 1.0, 0.000001, "no fim exclusivo volta ao neutro")
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs - 1)), 1.0, 0.000001, "antes da janela é neutro")
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs + HourSeconds)), float(_cal.call("BonusMod", _cal.get("KindChestBonus"), openTs + HourSeconds)), 0.000001, "o que a agenda resolve == o que o settle usa (uma fonte, um leitor)")
	_checkNear(float(_offline.call("LiveOpsXpMods", openTs + HourSeconds)), 1.0, 0.000001, "chest_bonus NÃO entra no eixo do XP")
	_cal.call("SetRawForTests", _eventsRaw([_event("chest_bonus", "baus_nerf", openTs, openTs + DaySeconds, 0.5)]))
	_checkEq(_cal.call("ValidateCalendar", _eventsRaw([_event("chest_bonus", "baus_nerf", openTs, openTs + DaySeconds, 0.5)])).size(), 1, "bônus < 1.0 é recusado na validação (nerf disfarçado)")
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs + HourSeconds)), 1.0, 0.000001, "com o arquivo recusado o settle recebe o neutro (fail-closed)")
	_cal.call("SetRawForTests", "{\"events\": [ }")
	_checkNear(float(_offline.call("LiveOpsChestMods", openTs + HourSeconds)), 1.0, 0.000001, "arquivo quebrado = 1.0, nunca o último valor bom")
	_cal.call("ClearRawForTests")

	# O BAÚ REAL: `BuildReport` é a mesma função do caminho de liquidação; sem
	# campanha o baú é o da janela, com campanha é o turbinado, e o teto diário
	# continua sendo o teto mesmo com ×4 no arquivo.
	var accountID : int = _newAccount("ofx" + stamp + "bausch", now - HourSeconds)
	var charID : int = _newCharacter(accountID, "ofxbausch" + stamp)
	if not _check(accountID > 0 and charID > 0, "personagem de fixture para o teste de baú"):
		return
	var perDay : int = int(_catalog.get("ChestsPerDayFromSettle"))
	var report : Object = _offline.call("BuildReport", charID, 0)
	var baseChests : int = int(report.get("chests"))
	var baseXp : int = int(report.get("xpEarned"))
	_checkEq(baseChests, 2, "sem campanha, 8h liquidadas pagam floor(8/4) = 2 baús (golden do settle)")
	_cal.call("SetRawForTests", _eventsRaw([_event("chest_bonus", "baus_agora", now - HourSeconds, now + HourSeconds, 2.0)]))
	var boosted : Object = _offline.call("BuildReport", charID, 0)
	_checkEq(int(boosted.get("chests")), 4, "com ×2 no ar a MESMA janela paga 4 baús (o modificador chega no grant)")
	_checkEq(int(boosted.get("xpEarned")), baseXp, "e o XP da liquidação não se mexe (chest_bonus não é double_xp)")
	_checkNear(float(boosted.get("mods")), float(report.get("mods")), 0.000001, "o eixo mods continua o mesmo com a campanha de baú no ar")
	# Teto diário: mintar os baús do dia e conferir que a campanha não passa.
	var minted : int = 0
	while minted < perDay:
		_exec("INSERT INTO chest_instance (char_id, chest_hash, origin, item_state, created_at) VALUES (?, 1, 'settle', 'closed', ?);", [charID, now])
		minted += 1
	_cal.call("SetRawForTests", _eventsRaw([_event("chest_bonus", "baus_teto", now - HourSeconds, now + HourSeconds, 4.0)]))
	var capped : Object = _offline.call("BuildReport", charID, 0)
	_checkEq(int(capped.get("chests")), 0, "com o dia de baús cheio (teto %d), nem ×4 mintar baú novo" % perDay)
	_exec("DELETE FROM chest_instance WHERE char_id = ?;", [charID])
	# E com o dia vazio, ×4 bate no teto, não em 8.
	var bigFour : Object = _offline.call("BuildReport", charID, 0)
	_checkEq(int(bigFour.get("chests")), mini(8, perDay), "com ×4 e dia vazio o resultado é o teto diário (%d), não 8 baús" % perDay)
	_cal.call("ClearRawForTests")
	var afterClear : Object = _offline.call("BuildReport", charID, 0)
	_checkEq(int(afterClear.get("chests")), baseChests, "fora de campanha volta exatamente ao baú da janela (nenhum estado travado)")

# ------------------------------------------------------------------ suíte E

func _suiteTournamentPool():
	print("[suite] E: tournament cai no pool de prêmios congelado (anunciado == pago)")
	var arenaSrc : String = FileAccess.get_file_as_string("res://sources/economy/TournamentArenaService.gd")
	_contains(arenaSrc, "static func PrizePoolMod(endsAt : int) -> float:", "o seam do pool existe (puro)")
	_contains(arenaSrc, "LiveOpsCalendar.BonusMod(LiveOpsCalendar.KindTournament, endsAt)", "e lê o kind de copa da agenda")
	_contains(arenaSrc, "FormatPrizes(EconomyCatalog.TOURNAMENT_PRIZES, PrizePoolMod(endsAt))", "a criação congela o pool já turbinado pela campanha do fim")
	_contains(arenaSrc, "var frozenPool : Array = PrizePoolOfRow(rows[0])", "a liquidação paga o congelado na linha")
	_checkEq(arenaSrc.count("PrizePoolMod(endsAt)"), 2, "o multiplicador é lido na CRIAÇÃO e no preview, e NUNCA de novo na liquidação (×2 sobre ×2 seria faucet inventado)")
	_check(not arenaSrc.contains("roundi(float(baseGems) * endMod)"), "não há segunda multiplicação no SettleTournament")
	_contains(arenaSrc, "var prize : int = maxi(frozenGems, floorGems)", "o papel do catálogo na liquidação é o PISO por posição")

	var openTs : int = 1890000000
	var endsAt : int = openTs + DaySeconds
	_cal.call("SetRawForTests", _eventsRaw([_event("tournament", "copa_teste", openTs, openTs + 2 * DaySeconds, 1.5)]))
	_checkNear(float(_arena.call("PrizePoolMod", endsAt)), 1.5, 0.000001, "copa que encerra dentro da janela pega ×1,5")
	_checkNear(float(_arena.call("PrizePoolMod", openTs - DaySeconds)), 1.0, 0.000001, "fora da janela o pool é o catálogo (neutro)")
	var base : Array[int] = _catalog.get("TOURNAMENT_PRIZES") as Array[int]
	var frozen : Array = _arena.call("FormatPrizes", base, 1.5)
	_checkEq(frozen.size(), base.size(), "o congelado tem o mesmo comprimento da régua do catálogo")
	for rank in base.size():
		_checkEq(int((frozen[rank] as Dictionary).get("gems", -1)), int(roundi(float(base[rank]) * 1.5)), "prêmio da posição %d turbinado item a item" % (rank + 1))
	# Banda fail-closed no CONSUMIDOR (kind de pool não é cheque no arquivo).
	_cal.call("SetRawForTests", _eventsRaw([_event("tournament", "copa_fora_da_banda", openTs, openTs + 2 * DaySeconds, 99.0)]))
	_checkEq(_cal.call("ValidateCalendar", _eventsRaw([_event("tournament", "copa_fora_da_banda", openTs, openTs + 2 * DaySeconds, 99.0)])).size(), 0, "value 99 de copa NÃO derruba a agenda (não é multiplicador de ganho)")
	_checkNear(float(_arena.call("PrizePoolMod", endsAt)), 1.0, 0.000001, "mas o consumidor recusa e paga o neutro (dedo no teclado não vira prêmio)")
	_cal.call("SetRawForTests", _eventsRaw([_event("tournament", "copa_zero", openTs, openTs + 2 * DaySeconds, 0.5)]))
	_checkNear(float(_arena.call("PrizePoolMod", endsAt)), 1.0, 0.000001, "e um multiplicador < 1.0 nunca reduz o prêmio anunciado")
	_cal.call("ClearRawForTests")

	# Leitura do `prizes_json`: os dois formatos do repo aceitos, lixo rejeitado.
	var ints : Variant = _arena.call("ParsePrizePool", JSON.stringify(base))
	_check(ints != null, "lista de inteiros (o JSON.stringify do catálogo de hoje) é aceita")
	_checkEq((ints as Array).size(), base.size(), "e vira uma posição por prêmio")
	var objs : Variant = _arena.call("ParsePrizePool", JSON.stringify(_arena.call("FormatPrizes", base, 2.0)))
	_checkEq(int((objs as Array)[0].get("gems", 0)), base[0] * 2, "lista de objetos {gems:N} é aceita com o valor turbinado")
	_check(_arena.call("ParsePrizePool", "[]") == null, "\"[]\" não é lido como copa sem prêmio (cai no catálogo)")
	_check(_arena.call("ParsePrizePool", "{\"gems\": 5}") == null, "topo que não é lista é rejeição, não prêmio zero")
	_check(_arena.call("ParsePrizePool", JSON.stringify([{"glims": 5}])) == null, "chave de moeda desconhecida é rejeição")
	_check(_arena.call("ParsePrizePool", JSON.stringify(["cinco"])) == null, "item que não é número nem objeto é rejeição")
	_check(_arena.call("ParsePrizePool", null) == null, "campo ausente é nulo (o chamador cai no catálogo)")
	var poolFallback : Array = _arena.call("PrizePoolOfRow", {"name": "sem o campo"})
	_checkEq(poolFallback.size(), base.size(), "linha sem prizes_json resolve o catálogo, não o vazio")
	var poolFrozen : Array = _arena.call("PrizePoolOfRow", {"prizes_json": JSON.stringify(_arena.call("FormatPrizes", base, 1.5))})
	_checkEq(int(poolFrozen[0].get("gems", 0)), int(roundi(float(base[0]) * 1.5)), "linha congelada resolve o pool turbinado")

	# O copo REAL: a linha criada pelo job carrega o turbinado e o preview lê a
	# MESMA linha (anunciado == pago). Usa o serviço montado do boot.
	var eco : Object = _launcher.get("Economy")
	if not _check(eco != null, "Launcher.Economy disponível para o teste da copa real"):
		return
	var arena : Object = eco.get("tournamentArenaService")
	if not _check(arena != null, "TournamentArenaService composto no EconomyService"):
		return
	_exec("DELETE FROM tournament_entry WHERE tournament_id IN (SELECT tournament_id FROM tournament WHERE status = 'active');", [])
	_exec("UPDATE tournament SET status = 'settled' WHERE status = 'active';", [])
	var futureEnd : int = now + int(_catalog.get("TOURNAMENT_DAYS")) * DaySeconds
	_cal.call("SetRawForTests", _eventsRaw([_event("tournament", "copa_agora", now - HourSeconds, futureEnd + HourSeconds, 2.0)]))
	var createdID : int = int(arena.call("EnsureWeeklyTournament"))
	if not _check(createdID > 0, "EnsureWeeklyTournament abriu a copa da semana"):
		_cal.call("ClearRawForTests")
		return
	var row : Dictionary = _query("SELECT prizes_json, ends_at FROM tournament WHERE tournament_id = ?;", [createdID])[0]
	var rowPool : Array = _arena.call("PrizePoolOfRow", row)
	_checkEq(int(rowPool[0].get("gems", 0)), base[0] * 2, "o pool CONGELADO na linha é o turbinado pela campanha que cobre o ends_at (não o catálogo)")
	_check(_gaugeValue(_metricsBody(), "shambleta_liveops_mod_tournament") != "<ausente>", "e o /metrics serve o modificador de copa")
	var preview : Dictionary = arena.call("GetTournaments", 0)
	var active : Dictionary = preview.get("active", {}) as Dictionary
	var announced : Array = active.get("prizes", []) as Array
	_checkEq(int(announced[0]), base[0] * 2, "o que o jogador LÊ em /tournament é o pool que vai ser pago")
	_exec("DELETE FROM tournament WHERE tournament_id = ?;", [createdID])
	_cal.call("ClearRawForTests")

# ------------------------------------------------------------------ suíte F

func _suiteCalendarConsumers():
	print("[suite] F: kind declarado sem consumidor é RECUSADO (e os três têm)")
	var kinds : Array = _cal.get("Kinds") as Array
	var implemented : Array = _cal.get("ImplementedKinds") as Array
	var consumers : Dictionary = _cal.get("Consumers") as Dictionary
	_checkEq(kinds.size(), 3, "a agenda declara três kinds")
	_checkEq(implemented.size(), kinds.size(), "todo kind declarado tem consumidor (Kinds == ImplementedKinds)")
	for kind in kinds:
		var k : String = String(kind)
		_check(implemented.has(k), "kind %s está em ImplementedKinds" % k)
		_check(consumers.has(k), "kind %s tem destino declarado em Consumers" % k)
	# Kind fora da lista (typo, ou um kind futuro declarado antes de existir o
	# leitor) derruba o arquivo inteiro: é o fail-closed do `SeasonConfig.Validate`
	# aplicado à agenda — nada entra no ar pela metade.
	var t0 : int = 1890000000
	var typoRaw : String = _eventsRaw([_event("double_xp", "xp_ok", t0, t0 + DaySeconds, 2.0), _event("guild_rush", "guild_sem_leitor", t0, t0 + DaySeconds, 2.0)])
	_checkEq(_cal.call("ValidateCalendar", typoRaw).size(), 1, "um kind sem consumidor no servidor é erro (não 'aceito e fica esperando o dono')")
	_cal.call("SetRawForTests", typoRaw)
	_checkEq(_cal.call("Entries").size(), 0, "e o arquivo inteiro sai do ar, não só a linha ruim")
	_checkNear(float(_offline.call("LiveOpsXpMods", t0 + HourSeconds)), 1.0, 0.000001, "com a recusa, o consumidor que existia também recebe o neutro (fail-closed)")
	_cal.call("ClearRawForTests")
	# O texto do erro diz ONDE ligar — é o que o operador lê no log.
	var errText : String = ""
	for e in _cal.call("ValidateCalendar", typoRaw):
		errText += String(e)
	_contains(errText, "sem consumidor no servidor", "o erro nomeia a falha")
	_contains(errText, "implemented", "e lista os kinds implementados (a mensagem é a régua)")

	# Cada kind implementado tem que estar CHAMADO no arquivo do consumidor — o
	# mapa `Consumers` não é comentário: um nome falso aqui falha este check.
	var paths : Dictionary[String, String] = {
		"OfflineSettle": "res://sources/idle/OfflineSettle.gd",
		"TournamentArenaService": "res://sources/economy/TournamentArenaService.gd",
	}
	for kind in implemented:
		var k : String = String(kind)
		var target : String = String(consumers.get(k, ""))
		var head : String = target.substr(0, target.find("(")).strip_edges()
		var parts : PackedStringArray = PackedStringArray(head.split("."))
		if not _checkEq(parts.size(), 2, "Consumers[\"%s\"] tem forma Arquivo.Funcao (%s)" % [k, head]):
			continue
		var path : String = String(paths.get(parts[0], ""))
		if not _check(not path.is_empty(), "o arquivo do consumidor de %s é conhecido pelo harness (%s)" % [k, parts[0]]):
			continue
		var src : String = FileAccess.get_file_as_string(path)
		_check(not src.is_empty(), "%s.lido do disco" % path)
		_contains(src, "func %s(" % parts[1], "%s define %s (o kind aponta para uma função real)" % [parts[0], parts[1]])
		_contains(src, "Kind%s" % _KindCamel(k), "%s referencia o kind by name" % parts[0])
	# O terceiro lado do contrato: quem CONSOME também é servido (senão a medição
	# de live ops volta a ser "2 de 3 kinds não alcançam ninguém").
	var body : String = _metricsBody()
	for kind in implemented:
		var k : String = String(kind)
		_check(body.contains("shambleta_liveops_mod_%s " % k), "/metrics serve o modificador de %s" % k)
		_check(body.contains("shambleta_liveops_active_%s " % k), "/metrics diz se %s está no ar" % k)
		_check(body.contains("multiplicador resolvido") or body.contains("multiplicador"), "/metrics documenta o que o número é")

func _KindCamel(kind : String) -> String:
	var out : String = ""
	var upper : bool = true
	for c in kind:
		if c == "_":
			upper = true
			continue
		out += c.to_upper() if upper else c
		upper = false
	return out

# ------------------------------------------------------------------ suíte G

func _eventsRaw(list : Array) -> String:
	return JSON.stringify({"events": list})

func _event(kind : String, key : String, starts : int, ends : int, value : float) -> Dictionary:
	return {"kind": kind, "key": key, "start_unix": starts, "end_unix": ends, "value": value}

func _suiteFutureCampaign():
	print("[suite] G: o arquivo do repo tem campanha FUTURA e os modificadores aterrçam")
	_cal.call("ClearRawForTests")
	var errors : PackedStringArray = _cal.call("ValidateCalendarFile")
	_checkEq(errors.size(), 0, "data/conf/liveops_calendar.json valida limpo: %s" % [str(errors)])
	var entries : Array = _cal.call("Entries")
	_check(entries.size() >= 2, "a agenda do repo tem histórico + campanhas futuras (%d)" % entries.size())
	var nextStart : int = int(_cal.call("NextStart", entries, now, ""))
	_check(nextStart > now, "existe promessa futura no ar do repo (next_start_unix = %d > agora %d)" % [nextStart, now])
	var futureChest : Dictionary = {}
	var futureTourney : Dictionary = {}
	for item in entries:
		var entry : Dictionary = item
		if int(entry.get("start_unix", 0)) <= now:
			continue
		if str(entry.get("kind", "")) == "chest_bonus" and futureChest.is_empty():
			futureChest = entry
		if str(entry.get("kind", "")) == "tournament" and futureTourney.is_empty():
			futureTourney = entry
	if not _check(not futureChest.is_empty(), "há uma campanha chest_bonus futura declarada"):
		return
	var mid : int = int(futureChest.get("start_unix", 0)) + HourSeconds
	_check(mid < int(futureChest.get("end_unix", 0)), "a instante consultado está dentro da janela futura")
	_checkNear(float(_cal.call("ValueAtKind", _cal.get("KindChestBonus"), mid, 1.0)), float(futureChest.get("value", 0.0)), 0.000001, "a campanha futura resolve o value do arquivo")
	_checkNear(float(_offline.call("LiveOpsChestMods", mid)), float(futureChest.get("value", 0.0)), 0.000001, "e o MODIFICADOR ATERISA no consumidor do baú")
	_checkNear(float(_offline.call("LiveOpsChestMods", now)), 1.0, 0.000001, "hoje (fora da janela) o settle não recebe bônus nenhum")
	_checkEq(String(_cal.call("ActiveKeyAt", _cal.get("KindChestBonus"), mid)), str(futureChest.get("key", "")), "a consulta diz QUAL campanha está no ar (é o texto que sai no scrape)")
	_check(not futureTourney.is_empty(), "há uma campanha tournament futura declarada")
	if not futureTourney.is_empty():
		var tourMid : int = int(futureTourney.get("start_unix", 0)) + HourSeconds
		_checkNear(float(_arena.call("PrizePoolMod", tourMid)), float(futureTourney.get("value", 0.0)), 0.000001, "o pool de copa da janela futura pega o value do arquivo")
		# "Hoje" não é neutro por construção, e a régua que jurava isso tinha virado
		# suposição de calendário, não régua de produto: desde a costura do Achado #98 o
		# eixo `tournament` é o ÚNICO que pode ficar permanentemente no ar
		# (data/conf/liveops_calendar.json, `_cuidado_com_a_suite`:5 e `_estado_atual`:7,
		# que declara `copa_semanal_set23_out07` NO AR), e tests/season_liveops_test.gd
		# E1/E1b (:578-579) exige campanha no ar no instante do run. O que se afirma do
		# consumidor é uma coisa só, em qualquer instante: ELE PAGA A LINHA DO ARQUIVO que
		# cobre o instante consultado — e nenhuma, quando nenhuma cobre. A linha é lida
		# do `entries` pela key que o próprio resolvedor anuncia (`ActiveKeyAt`), então o
		# esperado vem do arquivo e não do resolvedor: um consumidor que parar de
		# consultar a agenda continua acusado. O instante "fora de toda janela" é
		# DERIVADO do arquivo (uma hora depois do fim da última janela de copa), nunca o
		# relógio de quem roda.
		var tourEnd : int = 0
		for item in entries:
			var e2 : Dictionary = item
			if str(e2.get("kind", "")) == str(_cal.get("KindTournament")):
				tourEnd = maxi(tourEnd, int(e2.get("end_unix", 0)))
		if _check(tourEnd > 0, "há janela tournament no arquivo para derivar o instante fora de janela"):
			_checkNear(float(_arena.call("PrizePoolMod", tourEnd + HourSeconds)), 1.0, 0.000001, "fora de toda janela de copa o consumidor devolve o catálogo")
		var tourKey : String = String(_cal.call("ActiveKeyAt", _cal.get("KindTournament"), now))
		var tourExpected : float = 1.0
		if not tourKey.is_empty():
			var tourLine : Dictionary = _entryByKey(entries, tourKey)
			if _check(not tourLine.is_empty(), "a copa que o resolvedor põe no ar (%s) é uma linha do arquivo" % tourKey):
				tourExpected = float(tourLine.get("value", 0.0))
				var poolLo : float = float(_cal.get("MinPoolMod"))
				var poolHi : float = float(_cal.get("MaxPoolMod"))
				# Faixa do consumidor LIDA do produto, não redigitada: uma linha de copa
				# fora dela é recusada por `SanitizePoolMod` e paga o catálogo, i.e. a
				# campanha foi declarada e não chega a ninguém. É o `value == 1,0` da
				# fachada com outra cara, e a régua abaixo acusaria por um motivo errado se
				# isto não estivesse dito aqui.
				_check(tourExpected >= poolLo and tourExpected <= poolHi, "a copa no ar (%s) paga dentro da faixa do consumidor (%s..%s): %s" % [tourKey, str(poolLo), str(poolHi), str(tourExpected)])
		_checkNear(float(_arena.call("PrizePoolMod", now)), tourExpected, 0.000001, "e a copa de hoje paga a linha do arquivo que está no ar (%s)" % (tourKey if not tourKey.is_empty() else "sem janela"))
		# Controle negativo do MESMO predicado, plantado: troca-se só a linha no ar, no
		# MESMO instante consultado. Sem isto a régua acima poderia continuar verde com um
		# consumidor que não lê a agenda (1,0 == 1,0 num dia sem copa) nem com um que lê a
		# linha errada, porque esperado e medido viriam do mesmo lugar.
		var planted : float = 1.75
		_cal.call("SetRawForTests", _eventsRaw([_event("tournament", "copa_hoje_plantada", now - HourSeconds, now + HourSeconds, planted)]))
		_checkNear(float(_arena.call("PrizePoolMod", now)), planted, 0.000001, "controle plantado: com outra linha no ar no MESMO instante, o consumidor paga %s (nem o catálogo, nem a linha do repo)" % str(planted))
		_checkEq(String(_cal.call("ActiveKeyAt", _cal.get("KindTournament"), tourEnd + HourSeconds)), "", "e o plantado cobre só a janela que ele declara — o instante derivado continua fora")
		_cal.call("ClearRawForTests")
		_checkNear(float(_arena.call("PrizePoolMod", now)), tourExpected, 0.000001, "e o plantado foi desmontado: a linha do repo voltou a pagar no mesmo instante (%s)" % (tourKey if not tourKey.is_empty() else "sem janela"))
	# XP: nenhuma janela double_xp cobre o instante do run (protege o
	# SuiteSettleGolden, que calcula expectativa com mods = 1.0).
	_checkNear(float(_offline.call("LiveOpsXpMods", now)), 1.0, 0.000001, "nenhum double_xp no ar neste instante (a suíte dourada continua em mods 1.0)")
	for item in entries:
		var entry : Dictionary = item
		if str(entry.get("kind", "")) == "double_xp" and int(entry.get("start_unix", 0)) <= now and now < int(entry.get("end_unix", 0)):
			_check(false, "janela double_xp cobrindo o run (%s)" % str(entry.get("key", "")))
	# A forma servida da promessa: o corpo do /metrics mostra o próximo marco.
	var body : String = _metricsBody()
	_checkEq(int(_gaugeValue(body, "shambleta_liveops_next_start_unix")), nextStart, "/metrics serve o start_unix da próxima campanha")
	_contains(body, "# next_campaign kind=%s" % str(_entryStartingAt(entries, nextStart).get("kind", "")), "e diz qual kind assume")
	_contains(body, str(_entryStartingAt(entries, nextStart).get("key", "")), "com a key da campanha")
	_checkEq(int(_gaugeValue(body, "shambleta_liveops_calendar_valid")), 1, "a agenda do repo está VA- LIDA no scrape (1, não 'espera-se que sim')")
	# E no instante futuro, a linha expositória da campanha aparece.
	var futureBody : String = String(_cal.call("GaugeLines", mid))
	_contains(futureBody, "# campaign kind=chest_bonus key=%s" % str(futureChest.get("key", "")), "dentro da janela a campanha aparece no scrape com a key")
	_contains(futureBody, "shambleta_liveops_mod_chest_bonus %.4f" % float(futureChest.get("value", 0.0)), "e com o multiplicador da janela")
	_contains(futureBody, "shambleta_liveops_active_chest_bonus 1", "e o marcador de 'no ar'")
	var nowBody : String = String(_cal.call("GaugeLines", now))
	_contains(nowBody, "shambleta_liveops_active_chest_bonus 0", "hoje a mesma linha diz 0 (nada entra no ar por engano)")

func _entryStartingAt(entries : Array, start : int) -> Dictionary:
	for item in entries:
		var entry : Dictionary = item
		if int(entry.get("start_unix", 0)) == start:
			return entry
	return {}

# A linha do arquivo por `key`. `key` é única no arquivo (é o que `ValidateCalendar`
# cobra), então isto é uma leitura, não uma resolução: quem decide QUAL janela está no
# ar continua sendo o produto (`ActiveKeyAt`), e a régua só pergunta quanto que essa
# linha promete — esperado do arquivo, medido no consumidor.
func _entryByKey(entries : Array, key : String) -> Dictionary:
	if key.is_empty():
		return {}
	for item in entries:
		var entry : Dictionary = item
		if str(entry.get("key", "")) == key:
			return entry
	return {}
