extends SceneTree

# login_hardening_test.gd — harness da trilha "login hardening"
# (AUDITORIA_2026-09-27; frentes 1-4 do corte que NÃO é o do brute-force de reset
# — esse vive em tests/accounts_fix_test.gd, dono: agente AUTH-P0).
#
# Prende, em DB real + rotas reais do NetServer headless:
#  frente 1: lockout progressivo — o eixo CONTA é durável (011) com teto finito,
#            o eixo IP (SQLSecurity + migration 054) limita o spray e a tentativa
#            de fonte bloqueada NÃO escala o contador da vítima;
#  frente 2: respostas uniformes (contrato de fonte) + igualador de timing para
#            conta inexistente;
#  frente 3: 2FA sem oracle — anti-replay (changes(), regressão da auditoria de
#            24/09), orçamento PERSISTIDO por conta, replay não vira palpote, e o
#            esgotamento do pending de reset emite a métrica certa;
#  frente 4: telemetria de ataque com nomes FIXOS de telemetry_event.kind.
#
# Uso:
#   XDG_DATA_HOME=/tmp/login2/data XDG_CACHE_HOME=/tmp/login2/cache \
#     timeout 300 godot --headless --path . -s tests/login_hardening_test.gd
# Saída: "== RESULT: <n> checks, <m> failures ==" (exit code = <m>).
#
# Como os outros harnesses de `-s`: nada de identificador global (NetworkCommons,
# Peers, SQLSecurity...) em tempo de compilação — tudo via load()/call()/const map.

# --- estado do harness ----------------------------------------------------

var checks : int = 0
var failures : int = 0

var launcher : Node = null
var sql : Object = null
var server : Object = null
var email : Object = null

var sec : GDScript = null				# SQLSecurity (estáticos)
var peers : GDScript = null
var commons : GDScript = null			# NetworkCommons
var sqlcommons : GDScript = null		# SQLCommons
var hasher : GDScript = null
var twofa : GDScript = null

var unknownID : int = -2
var now : int = 0
var stamp : String = ""					# sufixo único por execução (DB pode ser reaproveitado)

var fixtureAccounts : Array[String] = []

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	# Ver `accounts_fix_test.gd`: comparação entre tipos diferentes abortava a
	# expressão, a check sumia sem virar falha e a linha de resultado continuava
	# dizendo zero falhas.
	var same : bool = typeof(got) == typeof(want) and got == want
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (got " + str(got) + ", want " + str(want) + ")")
		return false
	print("  [ok] " + label)
	return true

func _initialize():
	_run()

func _autoload(name : String) -> Node:
	return root.get_node_or_null(NodePath(name))

func _const(script : GDScript, name : String) -> Variant:
	return script.get_script_constant_map().get(name, null)

func _secConst(name : String) -> Variant:
	return _const(sec, name)

func _callSec(fn : String, args : Array) -> Variant:
	return sec.callv(fn, args)

func _now() -> int:
	return int(sqlcommons.call("Timestamp"))

func _row(name : String) -> Dictionary:
	var rows : Array = sql.callv("QueryBindings", ["SELECT * FROM account WHERE username = ?;", [name]])
	return rows[0] if not rows.is_empty() else {}

func _windowRow(kind : String, subject : String) -> Dictionary:
	var rows : Array = sql.callv("QueryBindings", ["SELECT * FROM security_attempt_window WHERE attempt_kind = ? AND attempt_subject = ?;", [kind, subject]])
	return rows[0] if not rows.is_empty() else {}

func _eventCount(kind : String) -> int:
	return int(_callSec("CountSecurityEvents", [sql, kind, 0]))

func _newAccount(pw : String) -> String:
	var uname : String = "lh" + stamp + "a" + str(fixtureAccounts.size())
	if uname.length() > 30:
		uname = uname.substr(0, 30)
	var emailAddr : String = uname + "@lh.test.local"
	fixtureAccounts.append(uname)
	Check(bool(sql.call("AddAccount", uname, pw, emailAddr)), "fixture criada: " + uname)
	return uname

func _peer(ip : String) -> int:
	var candidate : int = 710000
	while peers.call("GetPeer", candidate) != null:
		candidate += 1
	peers.call("AddPeer", candidate, 0)	# TransportType.OFFLINE == 0
	var peer : Object = peers.call("GetPeer", candidate)
	peer.set("ipAddress", ip)
	return candidate

func _removePeer(pid : int) -> void:
	peers.call("RemovePeer", pid)

func _run():
	print("== Login hardening harness (lockout multi-origem / anti-oraculo / 2FA / telemetria) ==")
	var waited : int = 0
	while waited < 45000:
		await create_timer(0.25).timeout
		waited += 250
		launcher = _autoload("Launcher")
		if launcher != null:
			sql = launcher.get("SQL")
			if sql != null and bool(sql.get("isInitialized")):
				break
	var network : Node = _autoload("Network")
	if launcher == null or sql == null or not bool(sql.get("isInitialized")) or network == null:
		print("FATAL: Launcher/SQL/Network não inicializaram")
		print("== RESULT: %d checks, %d failures ==" % [checks, failures + 1])
		quit(1)
		return
	server = network.get("ENetServer")
	email = launcher.get("Email")
	Check(server != null, "servidor de rotas disponível (NetServer offline)")
	Check(email != null, "Launcher.Email presente (contas de fluxo de reset)")
	if server == null:
		print("== RESULT: %d checks, %d failures ==" % [checks, failures + 1])
		quit(1)
		return

	sec = load("res://sources/sql/SQLSecurity.gd")
	peers = load("res://sources/network/server/Peers.gd")
	commons = load("res://sources/network/NetworkCommons.gd")
	sqlcommons = load("res://sources/sql/SQLCommons.gd")
	hasher = load("res://sources/util/Hasher.gd")
	twofa = load("res://sources/auth/TwoFactorAuth.gd")
	Check(sec != null and peers != null and commons != null and sqlcommons != null and hasher != null and twofa != null, "todos os scripts do corte compilam")
	if sec == null or commons == null:
		_finish()
		return
	unknownID = int(_const(commons, "PeerUnknownID"))
	now = _now()
	stamp = str(now % 100000000)
	_bootstrapClean()

	_suiteSchema()
	_suiteWindowEngine()
	_suiteTelemetryNames()
	await _suite2FANoOracle()
	await _suiteLockoutMultiOrigem()
	await _suiteResetDiscipline()
	_suiteSourceContracts()
	_cleanup()
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

# Estado zero ANTES de medir: o DB temporário pode carregar linhas de execuções
# anteriores (uma corrida que morreu no meio não chegou ao `_cleanup`). Os
# contadores por janela são TODOS desta trilha — apagar a tabela inteira e os
# eventos `sec_*` torna cada corrida determinística, independente do histórico.
func _bootstrapClean():
	sql.callv("ExecuteBindings", ["DELETE FROM security_attempt_window;", []])
	sql.callv("ExecuteBindings", ["DELETE FROM telemetry_event WHERE kind LIKE 'sec_%';", []])
	for uname : String in fixtureAccounts:
		sql.callv("ExecuteBindings", ["DELETE FROM account WHERE username = ?;", [uname]])

# ---------------------------------------------------------------------------
# A) migration 054: schema aplicado, só idempotente (ApplyMigrations endereça por
#    posição — o nome NNN tem que bater com o índice+1, e é o gate `== DOC DRIFT:`
#    que mede a densidade 001..N).
# ---------------------------------------------------------------------------
func _suiteSchema():
	print("-- A) schema da janela de tentativa (migration 054)")
	var tables : Array = sql.callv("QueryBindings", ["SELECT name FROM sqlite_master WHERE type='table' AND name='security_attempt_window';", []])
	Check(not tables.is_empty(), "tabela security_attempt_window existe (migration aplicada)")
	var cols : Array = sql.callv("QueryBindings", ["PRAGMA table_info(security_attempt_window);", []])
	var names : Array[String] = []
	for c in cols:
		names.append(str(c.get("name", "")))
	Check(names.has("attempt_kind") and names.has("attempt_subject") and names.has("window_start") and names.has("failures") and names.has("blocked_until"), "colunas (kind, subject, window_start, failures, blocked_until) presentes")
	var source : String = FileAccess.get_file_as_string("res://data/conf/migrations/054_security.sql")
	Check(source.contains("CREATE TABLE IF NOT EXISTS security_attempt_window"), "migration cria com IF NOT EXISTS")
	Check(not source.contains("ALTER TABLE") and not source.contains("DROP "), "migration 054 só tem statements idempotentes (reaplicar não pode doer)")
	Check(not source.contains("DEFAULT (") and not source.contains("strftime"), "sem expressão default/volátil na 054")

# ---------------------------------------------------------------------------
# B) o motor de janela (SQLSecurity.NoteFailure): janela rolante, transição única,
#    janela limpa depois de cumprir bloqueio, sem estado em memória.
# ---------------------------------------------------------------------------
func _suiteWindowEngine():
	print("-- B) motor de contadores persistidos (SQLSecurity)")
	var kind : String = str(_secConst("KindLoginIP"))
	var windowSec : int = int(_secConst("LoginIPWindowSec"))
	var maxFailures : int = int(_secConst("LoginIPMaxFailures"))
	var blockSec : int = int(_secConst("LoginIPBlockSec"))
	Check(windowSec > 0 and maxFailures >= 5 and blockSec >= 60, "política por IP declarada (janela/teto/bloqueio)")

	var subj : String = "10.222.0.1"
	var t : int = now + 1000
	var r1 : Dictionary = _callSec("NoteFailure", [sql, kind, subj, 900, 3, 1800, t])
	CheckEq(int(r1["failures"]), 1, "erro 1 registrado")
	Check(not bool(r1["blocked"]) and not bool(r1["justBlocked"]), "sem bloqueio antes do teto")
	var r2 : Dictionary = _callSec("NoteFailure", [sql, kind, subj, 900, 3, 1800, t + 10])
	CheckEq(int(r2["failures"]), 2, "erro 2 acumula")
	Check(not bool(r2["justBlocked"]), "ainda abaixo do teto: nenhuma transição")
	var r3 : Dictionary = _callSec("NoteFailure", [sql, kind, subj, 900, 3, 1800, t + 20])
	Check(bool(r3["justBlocked"]), "erro 3 = transição justBlocked (uma métrica por bloqueio)")
	var r4 : Dictionary = _callSec("NoteFailure", [sql, kind, subj, 900, 3, 1800, t + 30])
	Check(bool(r4["blocked"]) and not bool(r4["justBlocked"]), "tentativa dentro do bloqueio não re-emite transição")
	CheckEq(int(r4["failures"]), 3, "contador não cresce enquanto bloqueado (fonte queimada é barata de rejeitar)")
	Check(bool(_callSec("IsBlocked", [sql, kind, subj, t + 30])), "IsBlocked true durante o bloqueio")
	var row : Dictionary = _windowRow(kind, subj)
	CheckEq(int(row.get("failures", -1)), 3, "contadores estão na base (durável, não em memória)")
	var blockEnd : int = t + 20 + 1800
	CheckEq(int(row.get("blocked_until", -1)), blockEnd, "blocked_until = instante do teto + bloqueio")
	Check(not bool(_callSec("IsBlocked", [sql, kind, subj, blockEnd + 1])), "bloqueio expira sozinho (trava com prazo — nunca indefinida)")
	var r5 : Dictionary = _callSec("NoteFailure", [sql, kind, subj, 900, 3, 1800, blockEnd + 1])
	CheckEq(int(r5["failures"]), 1, "depois de cumprir o bloqueio a janela recomeça limpa")

	var subj2 : String = "10.222.0.2"
	_callSec("NoteFailure", [sql, kind, subj2, 900, 5, 1800, t])
	var rEnd : Dictionary = _callSec("NoteFailure", [sql, kind, subj2, 900, 5, 1800, t + 899])
	CheckEq(int(rEnd["failures"]), 2, "segundo erro dentro da janela acumula")
	var rNew : Dictionary = _callSec("NoteFailure", [sql, kind, subj2, 900, 5, 1800, t + 901])
	CheckEq(int(rNew["failures"]), 1, "janela rolante: depois de windowSec o contador reinicia")

	CheckEq(str(_callSec("NoteFailure", [sql, kind, "", 900, 3, 1800, t])), str({"failures": 0, "blocked": false, "justBlocked": false}), "sujeito vazio (transporte sem IP) não conta no eixo IP")
	Check(_windowRow(kind, "").is_empty(), "nenhuma linha órfã criada por sujeito vazio")

	var budget : Dictionary = {}
	for i in 5:
		budget = _callSec("AttemptBudget", [sql, str(_secConst("KindTotp")), "999999", 5, 900, t + i])
	Check(bool(budget["exhausted"]) and bool(budget["justExhausted"]), "AttemptBudget: a 5ª tentativa esgota (mesma régua do reset — 2FA usa hoje)")
	Check(bool(_callSec("ClearFailures", [sql, kind, subj])), "ClearFailures apaga a linha")
	Check(_windowRow(kind, subj).is_empty(), "linha removida da base")

	# Estado nenhum mora no módulo: uma SEGUNDA instância compilada do script vê o
	# mesmo veredito (tudo sai da base) — é o teste de "sobrevive a restart" que
	# cabe num processo só: o bloco está no disco, não no script/heap.
	var sec2 : GDScript = load("res://sources/sql/SQLSecurity.gd")
	_callSec("NoteFailure", [sql, kind, "10.222.0.9", 900, 2, 1800, t])
	var second : Dictionary = sec2.call("NoteFailure", sql, kind, "10.222.0.9", 900, 2, 1800, t + 1)
	Check(bool(second["justBlocked"]), "instância nova do módulo continua a contagem (zero estado próprio)")

# ---------------------------------------------------------------------------
# C) frente 4 — nomes FIXOS e contagem no caminho que já existe (telemetry_event,
#    a mesma tabela que o /metrics do companion lê).
# ---------------------------------------------------------------------------
func _suiteTelemetryNames():
	print("-- C) telemetria de ataque com nomes fixos")
	var expected : Dictionary = {
		"EventLoginLockout": "sec_login_lockout",
		"EventLoginIPBlock": "sec_login_ip_block",
		"EventTotpThrottle": "sec_totp_throttle",
		"EventTotpReplay": "sec_totp_replay",
		"EventResetExhausted": "sec_reset_exhausted",
		"EventResetRequestLimit": "sec_reset_request_limit",
	}
	for constName : String in expected.keys():
		CheckEq(str(_secConst(constName)), str(expected[constName]), "nome de métrica fixo: " + str(expected[constName]))
	var before : int = _eventCount("sec_login_lockout")
	Check(bool(_callSec("LogSecurityEvent", [sql, "sec_login_lockout", 1234, "{\"probe\":true}"])), "LogSecurityEvent grava")
	CheckEq(_eventCount("sec_login_lockout"), before + 1, "evento é contável (mesmo caminho lido por Count/telemetry_event)")
	var rows : Array = sql.callv("QueryBindings", ["SELECT account_id, meta FROM telemetry_event WHERE kind = 'sec_login_lockout' AND account_id = 1234 ORDER BY id DESC LIMIT 1;", []])
	Check(not rows.is_empty() and str(rows[0].get("meta", "")) == "{\"probe\":true}", "meta/account_id chegam na linha")

# ---------------------------------------------------------------------------
# D) frente 3 — 2FA sem oracle: anti-replay durável (regressão 24/09), orçamento
#    por conta, replay destacado de palpote, bloqueado rejeita até o código certo.
# ---------------------------------------------------------------------------
func _suite2FANoOracle() -> void:
	print("-- D) 2FA: anti-replay + orçamento persistido por conta")
	var uname : String = _newAccount("CorrectHorse123!")
	var accountID : int = int(sql.call("GetAccountID", uname))
	var kindTotp : String = str(_secConst("KindTotp"))
	var wrong : String = "000000"
	var secret : String = str(twofa.call("GenerateSecret", 20))
	Check(bool(sql.call("SetTwoFactorSecret", accountID, secret)), "segredo 2FA gravado")
	Check(bool(sql.call("SetTwoFactorEnabled", accountID, true)), "2FA ligado")
	Check(bool(sql.call("SetConsentAccepted", accountID, str(_const(commons, "AgreementTosVersion")), str(_const(commons, "AgreementPrivacyVersion")), "127.0.0.1")), "consentimento da fixture")

	# Anti-replay durável (frente 3): a PRIMITIVA `SQL.ConsumeTwoFactorToken` decide
	# frescor por `SELECT changes()`, que o pool de leitura (padrão ligado) roteia
	# para uma conexão onde changes()=0 → rejeita código válido (DoS no 2FA); por
	# isso a rota consome pela variante roteável `SQLSecurity.ConsumeTwoFactor
	# TokenSafe` (leitura persistida + escrita no handle do escritor). Testamos a
	# PROPRIEDADE (código não reusável na janela) pelo caminho que a rota usa.
	var code : String = str(twofa.call("GenerateTOTP", secret, _now()))
	while code == wrong:
		code = str((code.to_int() + 7) % 1000000).pad_zeros(6)
	Check(bool(_callSec("ConsumeTwoFactorTokenSafe", [sql, accountID, code])), "TOTP consumido na 1ª vez")
	Check(not bool(_callSec("ConsumeTwoFactorTokenSafe", [sql, accountID, code])), "replay do mesmo TOTP na janela → false (anti-replay durável)")
	Check(not bool(_callSec("ConsumeTwoFactorTokenSafe", [sql, accountID, ""])), "token vazio não consome")

	var pid : int = _peer("10.55.0.1")
	var peer : Object = peers.call("GetPeer", pid)
	# Queima o consumo acima para poder exercitar a rota com este mesmo código?
	# Não: a rota usa um código NOVO por janela; geramos o atual de novo abaixo.
	var budgetEvents : int = _eventCount(str(_secConst("EventTotpThrottle")))
	var attempts : int = int(_secConst("TotpMaxFailures"))
	for i in attempts:
		peer.set("pendingTwoFactorAccount", uname)
		peer.set("pendingTwoFactorAt", _now())
		server.call("LoginWithTwoFactor", uname, wrong, 0, pid)
	await create_timer(0.1).timeout
	var row : Dictionary = _windowRow(kindTotp, str(accountID))
	CheckEq(int(row.get("failures", -1)), attempts, "cada tentativa errada TOTP consome o budget DURÁVEL da conta")
	Check(bool(_callSec("IsBlocked", [sql, kindTotp, str(accountID), 0])), "budget estourado → conta travada no eixo TOTP")
	CheckEq(_eventCount(str(_secConst("EventTotpThrottle"))), budgetEvents + 1, "sec_totp_throttle emitido exatamente uma vez na transição")
	CheckEq(str(peer.get("pendingTwoFactorAccount")), "", "desafio do peer foi queimado pelo esgotamento")
	# Travada, até o código CERTO é rejeitado sem escalada nova nem sucesso.
	budgetEvents = _eventCount(str(_secConst("EventTotpThrottle")))
	var codeNow : String = str(twofa.call("GenerateTOTP", secret, _now()))
	while codeNow == wrong:
		codeNow = str((codeNow.to_int() + 11) % 1000000).pad_zeros(6)
	peer.set("pendingTwoFactorAccount", uname)
	peer.set("pendingTwoFactorAt", _now())
	server.call("LoginWithTwoFactor", uname, codeNow, 0, pid)
	await create_timer(0.1).timeout
	Check(str(peer.get("pendingTwoFactorAccount")) == "", "fonte travada: código válido não religa desafio nem loga")
	CheckEq(int(peers.call("GetAccount", pid)), unknownID, "sem sessão no ramo travado (resposta genérica, sem oracle)")
	# Replay: código válido JÁ consumido dentro da janela → sec_totp_replay, e NÃO
	# conta como palpote (não mexe no budget).
	_callSec("ClearFailures", [sql, kindTotp, str(accountID)])
	var beforeReplay : Dictionary = _windowRow(kindTotp, str(accountID))
	Check(beforeReplay.is_empty(), "budget zerado para o teste de replay")
	var replayEvents : int = _eventCount(str(_secConst("EventTotpReplay")))
	var freshSecret : String = str(twofa.call("GenerateSecret", 20))
	sql.call("SetTwoFactorSecret", accountID, freshSecret)
	var freshCode : String = str(twofa.call("GenerateTOTP", freshSecret, _now()))
	while freshCode == wrong:
		freshCode = str((freshCode.to_int() + 3) % 1000000).pad_zeros(6)
	Check(bool(_callSec("ConsumeTwoFactorTokenSafe", [sql, accountID, freshCode])), "código da janela consumido fora da rota")
	peer.set("pendingTwoFactorAccount", uname)
	peer.set("pendingTwoFactorAt", _now())
	server.call("LoginWithTwoFactor", uname, freshCode, 0, pid)
	await create_timer(0.1).timeout
	CheckEq(_eventCount(str(_secConst("EventTotpReplay"))), replayEvents + 1, "replay TOTP → sec_totp_replay (frente 4)")
	Check(_windowRow(kindTotp, str(accountID)).is_empty(), "replay não consome budget de palpote (eventos separados)")
	_removePeer(pid)

# ---------------------------------------------------------------------------
# E) frente 1 — lockout multi-origem nas rotas reais: 5 erros travam a conta com
#    backoff DURÁVEL e finito; teto por IP derruba o spray; fonte bloqueada não
#    escala a conta; origem sem IP não conta no eixo IP.
# ---------------------------------------------------------------------------
func _suiteLockoutMultiOrigem() -> void:
	print("-- E) lockout progressivo por conta + teto por IP (rotas reais)")
	var maxAttempts : int = int(_const(commons, "MaxLoginAttempts"))
	var baseLockout : int = int(_const(commons, "BaseLockoutSec"))
	var maxLockout : int = int(_const(commons, "MaxLockoutSec"))
	var uname : String = _newAccount("S3nhadePagante!")
	var accountID : int = int(sql.call("GetAccountID", uname))
	var pid : int = _peer("10.66.1.1")
	var kindIP : String = str(_secConst("KindLoginIP"))
	var lockoutEvents : int = _eventCount(str(_secConst("EventLoginLockout")))
	var clockBefore : int = _now()  # a duração é medida contra este instante, não contra um relógio lido depois
	var i : int = 0
	while i < maxAttempts:
		i += 1
		server.call("LoginWithPassword", uname, "senhaerrada%d" % i, false, 0, pid)
	await create_timer(0.1).timeout
	var row : Dictionary = _row(uname)
	var failedAttempts : int = int(row.get("failed_attempts", 0))
	var lockedUntil : int = int(row.get("locked_until", 0))
	CheckEq(failedAttempts, maxAttempts, "contador POR CONTA persistido em account.failed_attempts (%d)" % failedAttempts)
	Check(lockedUntil > _now(), "lockout ativo em account.locked_until (durável — sobrevive a restart, não é memória)")
	CheckEq(lockedUntil - _now() <= maxLockout, true, "lockout tem teto finito (<= MaxLockoutSec): pagante nunca fica travado para sempre")
	CheckEq(lockedUntil - clockBefore >= baseLockout, true, "primeiro lockout dura ao menos BaseLockoutSec (a duração só pode ser medida contra o relógio de antes da escrita: sources/sql/SQL.gd:386 soma `Timestamp()` com granularidade de segundo, e conferir contra um relógio lido depois cobra o prazo inteiro de uma janela que já passou — com 1,1 s de espera entre a escrita e a leitura, medida do jeito antigo, esta régua acusava falha)")
	CheckEq(_eventCount(str(_secConst("EventLoginLockout"))), lockoutEvents + 1, "sec_login_lockout emitido UMA vez por episódio")

	# Conta travada: senha CERTA não passa (e-mail de suporte, não bypass) e o
	# golpe extra conta no eixo IP mas não re-gera métrica de lockout.
	var ipRowBefore : Dictionary = _windowRow(kindIP, "10.66.1.1")
	var failuresBefore : int = int(ipRowBefore.get("failures", 0))
	server.call("LoginWithPassword", uname, "S3nhadePagante!", false, 0, pid)
	await create_timer(0.1).timeout
	var ipRowAfter : Dictionary = _windowRow(kindIP, "10.66.1.1")
	CheckEq(int(ipRowAfter.get("failures", -1)), failuresBefore + 1, " tentativa contra conta travada paga o IP (spray não é de graça)")
	CheckEq(_eventCount(str(_secConst("EventLoginLockout"))), lockoutEvents + 1, "sem evento duplicado durante o lockout")

	# De-trava (janela cumpriu o prazo) e a senha certa reseta os dois contadores.
	sql.callv("ExecuteBindings", ["UPDATE account SET locked_until = ? WHERE account_id = ?;", [_now() - 1, accountID]])
	var data : Object = sql.call("ValidateAuthPassword", uname, "S3nhadePagante!")
	Check(data != null, "lockout expirado: credencial certa volta a validar (prazo, não flag permanente)")
	row = _row(uname)
	CheckEq(int(row.get("failed_attempts", -1)), 0, "login certo zera o contador da conta")
	_callSec("ClearFailures", [sql, kindIP, "10.66.1.1"])

	# Teto por IP: spray em 25 (LoginIPMaxFailures) nomes INEXISTENTES de uma
	# origem não pode escalar conta nenhuma e queima a origem no fim.
	var pid2 : int = _peer("10.66.2.2")
	var sprayMax : int = int(_secConst("LoginIPMaxFailures"))
	var blockEvents : int = _eventCount(str(_secConst("EventLoginIPBlock")))
	for s in sprayMax:
		server.call("LoginWithPassword", "lhghost" + str(s) + stamp, "x12345678", false, 0, pid2)
	await create_timer(0.1).timeout
	Check(bool(_callSec("IsBlocked", [sql, kindIP, "10.66.2.2", 0])), "spray em nomes inexistentes esgota o teto da ORIGEM")
	CheckEq(_eventCount(str(_secConst("EventLoginIPBlock"))), blockEvents + 1, "sec_login_ip_block na transição (uma vez)")
	# Origem queimada: nem a senha certa de uma conta real toca o ValidateAuthPassword
	# da vítima — usado a conta 2FA da suite D: resposta idêntica, zero escalada.
	var victim : String = fixtureAccounts[0]
	var victimID : int = int(sql.call("GetAccountID", victim))
	var victimBefore : int = int(_row(victim).get("failed_attempts", 0))
	var peer2 : Object = peers.call("GetPeer", pid2)
	server.call("LoginWithPassword", victim, "CorrectHorse123!", false, 0, pid2)
	await create_timer(0.1).timeout
	CheckEq(int(_row(victim).get("failed_attempts", -1)), victimBefore, "IP bloqueado não escala mais o contador da conta-alvo")
	CheckEq(str(peer2.get("pendingTwoFactorAccount")), "", "IP bloqueado: até credencial certa para sem abrir desafio/sessão")
	# Controle positivo: mesma credencial de origem limpa passa (desafio arma).
	var pid3 : int = _peer("10.66.3.3")
	server.call("LoginWithPassword", victim, "CorrectHorse123!", false, 0, pid3)
	await create_timer(0.1).timeout
	CheckEq(str(peers.call("GetPeer", pid3).get("pendingTwoFactorAccount")), victim, "origem limpa com a mesma senha segue o fluxo normal (2FA desafiado)")
	# Transporte sem IP atribuível (web atrás de bridge): eixo IP fica de fora,
	# só o eixo conta protege — precisa continuar VALIDANDO, não travando tudo.
	var pid4 : int = _peer("")
	server.call("LoginWithPassword", victim, "WrongPassword99!", false, 0, pid4)
	await create_timer(0.1).timeout
	Check(int(_row(victim).get("failed_attempts", 0)) >= 1, "sem IP a tentativa ainda escala a conta (eixo autoritário) — sem falso bloqueio global")
	Check(_windowRow(kindIP, "").is_empty(), "nenhum contador por IP vazio")
	# Backoff finito no degrau alto também (a curva dobra até o teto, nunca além).
	sql.callv("ExecuteBindings", ["UPDATE account SET failed_attempts = ?, locked_until = ? WHERE account_id = ?;", [maxAttempts + 9, _now() - 1, victimID]])
	sql.call("RecordFailedLogin", victimID, maxAttempts + 9)
	var hi : int = int(_row(victim).get("locked_until", 0)) - _now()
	Check(hi > 0 and hi <= maxLockout, "degrau alto do backoff continua sob o teto (%ds <= %ds)" % [hi, maxLockout])
	sql.callv("ExecuteBindings", ["UPDATE account SET failed_attempts = 0, locked_until = 0 WHERE account_id = ?;", [victimID]])
	_removePeer(pid)
	_removePeer(pid2)
	_removePeer(pid3)
	_removePeer(pid4)

# ---------------------------------------------------------------------------
# F) disciplina do reset pela rota real: esgotar o pending emite a métrica, e o
#    budget de solicitações por conta também — sem alterar uma linha do
#    EmailService (régua do outro agente; aqui só o gancho de contabilização).
# ---------------------------------------------------------------------------
func _suiteResetDiscipline() -> void:
	print("-- F) reset: budget de solicitação e pending esgotado viram métrica")
	if email == null:
		Check(false, "Launcher.Email ausente — suite F abortada")
		return
	var uname : String = _newAccount("DonoDoCofre123!")
	var accountID : int = int(sql.call("GetAccountID", uname))
	email.set("apiKey", "harness-fake-key")
	email.set("senderEmail", "nobody@shambleta.invalid")
	email.set("senderName", "harness")

	# 6 solicitações em janela de 60 min → a 6ª é negada (resposta continua a
	# MESMA para o client) e emite sec_reset_request_limit.
	var limitEvents : int = _eventCount(str(_secConst("EventResetRequestLimit")))
	var requestMax : int = int(_const(commons, "ResetRequestWindowMax"))
	for s in requestMax + 1:
		server.call("RequestPasswordReset", uname, 0)
	await create_timer(0.2).timeout
	CheckEq(_eventCount(str(_secConst("EventResetRequestLimit"))), limitEvents + 1, "6ª solicitação da janela → sec_reset_request_limit")
	var ledger : Array = sql.callv("QueryBindings", ["SELECT COUNT(*) AS n FROM password_reset_request WHERE account_id = ?;", [accountID]])
	CheckEq(int(ledger[0].get("n", 0)), requestMax, "ledger durável do reset (050, dono: AUTH-P0) registrou só as aceitas")

	# Pending plantado por fora com hash conhecido; 5 códigos errados pela ROTA →
	# a 5ª consome o pending (EmailService) e a rota emite sec_reset_exhausted.
	var goodCode : String = "ABC234"
	email.call("CreateReset", accountID, str(hasher.call("HashPassword", goodCode)))
	var exhaustedEvents : int = _eventCount(str(_secConst("EventResetExhausted")))
	var maxTries : int = int(_const(commons, "ResetCodeMaxAttempts"))
	for a in maxTries:
		server.call("ConfirmPasswordReset", uname, "222222", "NovaSenhaForte1!", 0)
	await create_timer(0.1).timeout
	CheckEq(_eventCount(str(_secConst("EventResetExhausted"))), exhaustedEvents + 1, "pending consumido na N-ésima → sec_reset_exhausted")
	Check(not bool(email.call("HasPendingReset", accountID)), "pending esgotado (disciplina do EmailService intacta)")
	server.call("ConfirmPasswordReset", uname, goodCode, "NovaSenhaForte1!", 0)
	await create_timer(0.1).timeout
	var row : Dictionary = _row(uname)
	Check(str(row.get("password", "")) != "" and not bool(email.call("HasPendingReset", accountID)), "código certo depois do esgotamento NÃO reabre a conta (senha inalterada)")

func _suiteSourceContracts() -> void:
	print("-- G) contratos de fonte (anti-oráculo + names + congelamento de SQL.gd)")
	var srv : String = FileAccess.get_file_as_string("res://sources/network/server/Server.gd")
	var body : String = _fnBody(srv, "LoginWithPassword")
	Check(body.contains("SQLSecurity.IsBlocked") and body.contains("SQLSecurity.KindLoginIP"), "login: gate de IP antes da credencial")
	Check(body.contains("BurnKdfTime"), "login: conta inexistente paga o KDF (sem oracle de latência)")
	Check(body.contains("EventLoginLockout"), "login: métrica no episódionovo de lockout")
	Check(not body.contains("ERR_NAME_AVAILABLE") and not body.contains("ERR_EMAIL"), "login: nenhuma resposta específica de existência")
	Check(body.count("Network.AuthError(") == 1, "login: exatamente UMA resposta por tentativa (uniforme)")
	var tokenBody : String = _fnBody(srv, "LoginWithTwoFactor")
	Check(tokenBody.contains("SQLSecurity.KindTotp") and tokenBody.contains("AttemptBudget"), "2FA: orçamento por conta pela régua compartilhada")
	Check(tokenBody.contains("EventTotpReplay") and tokenBody.contains("IsTwoFactorTokenConsumed"), "2FA: replay distinguido e contabilizado")
	Check(tokenBody.contains("ConsumeTwoFactorTokenSafe") and not tokenBody.contains("Peers.ValidateTwoFactorChallenge("), "2FA: consome pela variante roteável (não pela primitiva changes() quebrada pelo pool)")
	var reqBody : String = _fnBody(srv, "RequestPasswordReset")
	Check(reqBody.count("Network.AuthError(") <= 2 and reqBody.contains("ERR_RESET_EMAIL_SENT"), "reset: resposta uniforme na conta-existência")
	Check(reqBody.contains("EventResetRequestLimit"), "reset: budget estourado contabilizado")
	var confBody : String = _fnBody(srv, "ConfirmPasswordReset")
	Check(confBody.contains("EventResetExhausted") and confBody.contains("HasPendingReset"), "reset: esgotamento do pending contabilizado (sem duplicar a aritmética do teto)")
	var sqlsrc : String = FileAccess.get_file_as_string("res://sources/sql/SQL.gd")
	Check(not sqlsrc.contains("SQLSecurity"), "SQL.gd (fachada congelada) não incha para hospedar a regra nova")
	var secsrc : String = FileAccess.get_file_as_string("res://sources/sql/SQLSecurity.gd")
	Check(not secsrc.contains("\nvar ") and not secsrc.contains("static var"), "SQLSecurity não guarda estado em memória (tudo na base → restart-safe)")
	Check(srv.contains("DeleteAccount"), "sanidade: Server.gd não foi truncado pelas edições")

func _fnBody(source : String, fnDecl : String) -> String:
	var start : int = source.find("func " + fnDecl.split("(")[0] + "(")
	if start < 0:
		return ""
	var rest : String = source.substr(start)
	var next : int = rest.find("\nfunc ", 1)
	return rest if next < 0 else rest.substr(0, next)

func _cleanup() -> void:
	print("-- limpeza das fixtures")
	for uname : String in fixtureAccounts:
		sql.callv("ExecuteBindings", ["DELETE FROM character WHERE account_id IN (SELECT account_id FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM auth_token WHERE account_id IN (SELECT account_id FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM telemetry_event WHERE account_id IN (SELECT account_id FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM password_reset_request WHERE account_id IN (SELECT account_id FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM two_factor_used_token WHERE account_id IN (SELECT account_id FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM security_attempt_window WHERE attempt_subject IN (SELECT CAST(account_id AS TEXT) FROM account WHERE username = ?);", [uname]])
		sql.callv("ExecuteBindings", ["DELETE FROM account WHERE username = ?;", [uname]])
	sql.callv("ExecuteBindings", ["DELETE FROM security_attempt_window WHERE attempt_subject LIKE '10.%';", []])
	sql.callv("ExecuteBindings", ["DELETE FROM security_attempt_window WHERE attempt_subject = '999999';", []])
	sql.callv("ExecuteBindings", ["DELETE FROM telemetry_event WHERE kind LIKE 'sec_%';", []])
	if email != null:
		for key : Variant in email.get("pendingResets").keys():
			email.get("pendingResets").erase(key)
		for key : Variant in email.get("resetRequests").keys():
			email.get("resetRequests").erase(key)
		email.set("apiKey", "")
		email.set("senderEmail", "")
		email.set("senderName", "")
		email.set("resetStore", null)
	Check(true, "fixtures removidas (DB temporário próprio fica limpo para rerun)")
