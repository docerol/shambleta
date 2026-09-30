extends SceneTree

# d1_return_metric_test.gd — harness da origem errada da metrica `d1_return`.
#
# O defeito (corrigido em `sources/network/server/Peers.gd`): o emisor de login
# decidia o evento por uma HEURISTICA PROPRIA — um SELECT
# `COUNT(DISTINCT date(created_at,'unixepoch')) == 1` sobre os logins ja gravados
# (o codigo velho estava em `Peers.gd:292-297`) — ANTES de chamar o funil. Isso
# era um segundo predicado sobre o MESMO evento, e era o que puxava o numero do
# funil para baixo: a conta criada ontem que loga HOJE pela primeira vez e D1 pela
# regua da view `cohort_retention` (migration 045), mas a heuristica via 0
# dias-distintos no banco (o login de estreia ainda estava no buffer) e SUPRIMIA
# exatamente esse caso. A unica autoridade agora e `IsD1Return`
# (`sources/economy/TelemetryService.gd:80-92`), atingida via `RecordFunnel`
# (o gate em `:83`) — dos dois lados, sem como divergir.
#
# Este harness fecha a lacuna que `tests/ops_fix_test.gd` (suite B) nao fechava:
# aquela suite mede o PREDICADO e o GATE chamando `RecordFunnel` por fora, mas
# nunca dirigia o EMISOR REAL nem provava que o veredito dele casa com
# `IsD1Return`. Aqui dirige `Peers.FinalizeLogin` (o caminho vivo do login) e
# confere o `d1_return` que SAI do emisor contra `IsD1Return` na mesma base.
# Sem a correcao, a assercao (a) falha (o emisor velho nao gravava nada para o
# caso estreia-ontem-loga-hoje) e a concordancia (c) tambem.
#
# Uso (mesmo contrato dos `-s` do repo; ver `balance_test.gd`):
#   XDG_DATA_HOME=/tmp/d1m/.data XDG_CACHE_HOME=/tmp/d1m/.cache \
#     timeout 300 godot --headless --path . -s tests/d1_return_metric_test.gd
# Saida: "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# Como os outros harnesses `-s`: o script compila ANTES dos autoloads, entao nada
# de identificador global de classe (`Peers`, `NetworkCommons`, ...): classes
# entram por `load()`, enums por `get_script_constant_map()`, autoloads por
# `root.get_node(...)`.

const DaySeconds : int = 86400

var checks : int = 0
var failures : int = 0

var launcher : Node = null
var sql : Object = null
var tele : Object = null
var network : Node = null

var peers : GDScript = null			# Peers.gd (o emisor vivo)
var teleScript : GDScript = null		# TelemetryService.gd (a autoridade `IsD1Return`)
var sqlCommons : GDScript = null		# SQLCommons.gd (Timestamp)

var now : int = 0
var dayIndex : int = 0
var dayStart : int = 0
var stamp : String = ""

var fixtureAccounts : Array[int] = []
var livePeers : Array[int] = []

# ------------------------------------------------------------------ contagem
# Copiada de `tests/ops_fix_test.gd` (mesma casa): `_checkEq` compara tipo-a-tipo
# para um veredito bool nao "passar" por coincidez de `true == 1`.

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	var same : bool = typeof(got) == typeof(want) and got == want
	if not same:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(got), str(want)])
		return false
	return true

# ------------------------------------------------------------------ banco (house pattern de ops_fix_test.gd)

func _query(sqlText : String, bindings : Array = []) -> Array[Dictionary]:
	return sql.callv("QueryBindings", [sqlText, bindings])

func _exec(sqlText : String, bindings : Array = []) -> bool:
	return bool(sql.callv("ExecuteBindings", [sqlText, bindings]))

func _count(sqlText : String, bindings : Array = []) -> int:
	var rows : Array[Dictionary] = _query(sqlText, bindings)
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func _newAccount(tag : String, createdTs : int) -> int:
	var username : String = "d1m" + stamp + tag
	var email : String = username + "@d1m.test.local"
	if not bool(sql.call("AddAccount", username, "d1mpass", email)):
		return 0
	var accountID : int = int(sql.call("GetAccountID", username))
	if accountID <= 0:
		return 0
	# O dia-zero da conta e o que `IsD1Return` le (via `created_timestamp`); o
	# emisor velho NAO lia `created_timestamp` — lia contagem de dias de login —
	# e por isso perdia a conta de ontem.
	_exec("UPDATE account SET created_timestamp = ? WHERE account_id = ?;", [createdTs, accountID])
	fixtureAccounts.append(accountID)
	return accountID

# Login ja GRAVADO no banco (bypass do buffer): e o "estado antes" que o emisor
# vai enxergar ao rodar. O caminho quente do login real bufferiza (`Record`), mas
# a heuristica removida consultava o banco — entao so o que ja foi flushado entrava
# nela. Plantar a linha direto reproduz o "antes" deterministico.
func _loginInDb(accountID : int, ts : int) -> void:
	_exec("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'login', 1, '{}');", [ts, accountID])

func _d1Rows(accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'd1_return' AND account_id = ?;", [accountID])

func _loginRows(accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'login' AND account_id = ?;", [accountID])

func _isD1(accountID : int) -> bool:
	return bool(tele.call("IsD1Return", accountID, now))

# ------------------------------------------------------------------ dirige o EMISOR REAL (não o gate por fora)

func _addPeer() -> int:
	var candidate : int = 780000
	while peers.call("GetPeer", candidate) != null:
		candidate += 1
	peers.call("AddPeer", candidate, 0)	# TransportType.OFFLINE == 0
	livePeers.append(candidate)
	return candidate

# Chama a MESMA função que `Server.gd` chama no login. O veredito de `d1_return`
# sai do caminho vivo (`Peers.FinalizeLogin` -> `RecordFunnel` -> `IsD1Return`),
# não de uma reimplementação aqui: é isto que amarra emisor e predicado.
func _driveEmitter(accountID : int, username : String) -> void:
	var accountDataClass : Variant = peers.get_script_constant_map().get("AccountData", null)
	if accountDataClass == null:
		_check(false, "inner class Peers.AccountData resolvivel via get_script_constant_map")
		return
	var peerID : int = _addPeer()
	var peerObj : Object = peers.call("GetPeer", peerID)
	var permission : Variant = sql.call("GetAccountPermission", accountID)
	var data : Object = (accountDataClass as GDScript).new(accountID, permission)
	peers.call("FinalizeLogin", peerObj, username, data, 0, false)

# ------------------------------------------------------------------ run

func _initialize():
	_run()

func _run():
	print("== d1_return harness: o EMISOR de login e `IsD1Return` na mesma regua (sem o falso negativo) ==")
	var waited : int = 0
	while waited < 40000:
		await create_timer(0.25).timeout
		waited += 250
		launcher = root.get_node_or_null(NodePath("Launcher"))
		if launcher != null:
			sql = launcher.get("SQL")
			tele = launcher.get("Telemetry")
			network = root.get_node_or_null(NodePath("Network"))
			if sql != null and bool(sql.get("isInitialized")) and tele != null and network != null:
				break
	if launcher == null or sql == null or not bool(sql.get("isInitialized")) or tele == null or network == null:
		_fatal("Launcher.SQL/Telemetry ou Network nao inicializaram (waited %d ms)" % waited)
		return
	peers = load("res://sources/network/server/Peers.gd")
	teleScript = load("res://sources/economy/TelemetryService.gd")
	sqlCommons = load("res://sources/sql/SQLCommons.gd")
	if not _check(peers != null and teleScript != null and sqlCommons != null, "scripts do corte compilam (Peers, TelemetryService, SQLCommons)"):
		_finish()
		return
	if not _check(tele.get_script() != null and str(tele.get_script().resource_path).contains("TelemetryService.gd"), "Launcher.Telemetry e o TelemetryService do boot (mede o servico real, nao uma copia)"):
		_finish()
		return

	# O catalogo de conteudo NAO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` (`sources/db/DB.gd:224`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar so o SQL e medir com o
	# catalogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI nao,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a maquina. O check nomeado e o
	# ponto — boot leve e vermelho visivel, nao medicao parcial silenciosa.
	# Padrao de tests/content_hygiene_test.gd.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 80:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (entities/maps/items carregados)"):
		_finish()
		return

	now = int(sqlCommons.call("Timestamp"))
	dayIndex = int(now / DaySeconds)
	dayStart = dayIndex * DaySeconds
	stamp = str(now % 100000000)
	_bootstrapClean()
	# Zera qualquer resquicio no buffer antes de medir: as decisoes do emisor
	# acontecem no momento da chamada, e um Flush atrasado de outro caminho nao
	# pode contaminar a contagem dos fixtures (as queries ja vao escopadas por
	# account_id, mas começar com buffer limpo deixa a deterministica).
	tele.call("Flush")

	_suiteEmitterMatchesPredicate()
	_suiteSourceNoDivergentHeuristic()

	_cleanup()
	_finish()

func _fatal(label : String):
	print("FATAL: " + label)
	print("== RESULT: %d checks, %d failures ==" % [checks, failures + 1])
	quit(1)

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _bootstrapClean():
	_exec("DELETE FROM telemetry_event WHERE account_id IN (SELECT account_id FROM account WHERE username LIKE 'd1m%');", [])
	_exec("DELETE FROM account WHERE username LIKE 'd1m%';", [])

func _cleanup():
	for peerID in livePeers:
		peers.call("RemovePeer", peerID)
	for accountID in fixtureAccounts:
		_exec("DELETE FROM telemetry_event WHERE account_id = ?;", [accountID])
		_exec("DELETE FROM account WHERE account_id = ?", [accountID])

# ------------------------------------------------------------------ suíte principal: emisor == IsD1Return

# Tres fixtures que cobrem os tres casos que a heuristica removida tratava mal:
#  (a) DEBUT   — criada ONTEM, NENHUM login no banco, loga HOJE pela primeira vez.
#                E D1 pela view; o emisor velho lia 0 dias e SUPRIMIA. ESTA e a
#                assercao que falha sem a correcao.
#  (b) STALE   — criada ONTEONT E M (+2 dias atras), login ontem no banco, loga hoje.
#                Ja voltou, nao e D1; a heuristica velha daria 1 dia-distinto (ontem)
#                e tentaria emitir, mas o gate `IsD1Return` recusa (dia-zero = -2).
#  (c) RETURN  — criada ONTEM, login ontem no banco, loga hoje. D1 verdadeiro "normal"
#                (o emisor velho e o novo concordam aqui); prova que a remocao do
#                pre-filtro nao suprimiu retorno legitimo.
func _suiteEmitterMatchesPredicate():
	print("[suite] emisor real (FinalizeLogin) vs IsD1Return, na mesma base")
	var dayBefore : int = dayStart - DaySeconds

	# (a) estreia ontem -> loga hoje. SEM login plantado no banco: o emisor velho via 0.
	var debut : int = _newAccount("debut", dayBefore + 60)
	# (b) re-login: dia-zero = anteontem-ou-mais (hoje NAO e +1 do dia-zero). Login ontem ja no banco.
	var stale : int = _newAccount("stale", dayStart - 2 * DaySeconds + 60)
	_loginInDb(stale, dayBefore + 120)
	# (c) retorno verdadeiro: criada ontem, login ontem no banco, loga hoje.
	var ret : int = _newAccount("ret", dayBefore + 90)
	_loginInDb(ret, dayBefore + 150)
	if not _check(debut > 0 and stale > 0 and ret > 0, "tres contas de fixture criadas"):
		return

	# Pre-condicao do caso que a heuristica perdia: o debut NAO tem login no banco
	# antes de o emisor rodar — o `COUNT(DISTINCT date) == 1` velho daria 0 (falso
	# negativo). O `IsD1Return`, lendo o dia-zero (created_timestamp de ontem), ja da
	# SIM antes mesmo de o emisor tocar.
	_checkEq(_loginRows(debut), 0, "caso (a): conta de estreia tem 0 logins NO BANCO antes do emisor (era ai que a heuristica dava 0)")
	_checkEq(_isD1(debut), true, "caso (a): IsD1Return ja diz SIM para criada-ontem-logando-hoje (a regua e o dia-zero, nao a contagem de logins)")

	# Drena o buffer que a propria criacao/plantacao nao toca (plantamos via SQL cru),
	# para que cada emitor so adicione as suas linhas e nada de fora entre na contagem.
	tele.call("Flush")

	# DIRIGE O EMISOR VIVO nos tres. `FinalizeLogin` bufferiza `login` e, agora sem
	# pre-filtro, delega a decisao de `d1_return` a `RecordFunnel` -> `IsD1Return`.
	_driveEmitter(debut, "d1m" + stamp + "debut")
	_driveEmitter(stale, "d1m" + stamp + "stale")
	_driveEmitter(ret, "d1m" + stamp + "ret")
	tele.call("Flush")

	# (a) O caso que a heuristica suprimia agora vira linha. ESTA falha sem a correcao.
	_check(_d1Rows(debut) >= 1, "caso (a): o EMISOR gravou d1_return para criada-ontem-logando-hoje (o falso negativo que sumiu com a heuristica)")
	# (b) Nao conta.
	_checkEq(_d1Rows(stale), 0, "caso (b): re-login de conta antiga (dia-zero -2) NAO gera d1_return (a heuristica velha tentaria, o gate recusa)")
	# (c) Retorno legitimo continua contando (a remocao nao suprimiu de mais).
	_check(_d1Rows(ret) >= 1, "caso (c): retorno no +1 continua gravado (o emisor nao ficou mudo para o D1 verdadeiro)")

	# (c-de-concordancia) O emisor e `IsD1Return` NAO podem divergir: para cada conta,
	# "o emisor produziu linha?" tem que ser o MESMO bool de `IsD1Return` na mesma base.
	for accountID in [debut, stale, ret]:
		var emitterSaid : bool = _d1Rows(accountID) > 0
		var predicateSaid : bool = _isD1(accountID)
		_checkEq(emitterSaid, predicateSaid, "emisor e IsD1Return concordam para a conta %d (emisor=%s predicado=%s)" % [accountID, str(emitterSaid), str(predicateSaid)])

# ------------------------------------------------------------------ contrato de fonte: nao voltou o segundo predicado

# Trava a regressao estrutural: o emisor nao pode voltar a ter heuristica propria.
# Cuidado: o COMENTARIO de por-que-nao em `Peers.gd` cita a query velha em texto —
# a regua por isso endereca fragmentos que so existiriam no codigo EXECUTAVEL
# (alias `AS d`, a variavel `dayRows`, o `.get("d", 0)`), nenhum deles em prosa.
func _suiteSourceNoDivergentHeuristic():
	print("[suite] contrato de fonte: Peers.gd so conhece IsD1Return para d1_return")
	var peersSrc : String = FileAccess.get_file_as_string("res://sources/network/server/Peers.gd")
	_check(not peersSrc.contains("AS d FROM telemetry_event"), "nao voltou a query de contagem de dias-distintos (alias 'AS d FROM telemetry_event')")
	_check(not peersSrc.contains("dayRows"), "nao voltou a variavel do pre-filtro ('dayRows')")
	_check(not peersSrc.contains(".get(\"d\", 0)"), "nao voltou a leitura do resultado do pre-filtro ('.get(\"d\", 0)')")
	# O unico caminho de escrita do evento e o funil (que carrega `IsD1Return`):
	# sem linha crua `Record("d1_return"` e a chamada real presente.
	_check(peersSrc.contains("RecordFunnel(\"d1_return\", accountData.accountID)"), "o emisor escreve d1_return so pelo funil (o gate IsD1Return vale para ele)")
	_check(not peersSrc.contains("Record(\"d1_return\""), "nao ha caminho cru Record(\"d1_return\") furando o gate no emisor")
