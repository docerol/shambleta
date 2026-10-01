extends RefCounted
class_name SQLSecurity

# SOM-IDLE AUTH-P1 (auditoria 2026-09-27, trilha "login hardening): contador de
# tentativas PERSISTIDO por origem para as rotas de auth que o `SQL.gd` (allowlist
# anti-god-node, com o teto valendo por ratchet no gate de tamanho de arquivo) não
# pode hospedar. Toda regra abaixo é estática e recebe o store (`Launcher.SQL`, ou um
# fake no harness — mesmo seam do
# `EmailService.resetStore`) como parâmetro: nenhum contador mora em memória de
# processo, porque lockout que morre no restart é oracle de brute-force (o
# atacante só espera o deploy).
#
# DECISÃO DE DESIGN — CONTA vs IP (frente 1):
#  - O eixo AUTORITÁTRIO é a CONTA. O backoff por conta já é durável desde a
#    migration 011 (`account.failed_attempts`/`locked_until`, escritos por
#    `SQL.RecordFailedLogin` dentro de `ValidateAuthPassword`): 5 erros travam,
#    dobra a cada erro extra, teto em `NetworkCommons.MaxLockoutSec` (2 h), e
#    login certo zera. travamento com prazo que se auto-limpa + reset no sucesso é
#    o que garante que um pagante legítimo NUNCA fica travado indefinidamente —
#    o residual (spray contínuo re-trava a cada janela) é o preço de não ter
#    segundo fator no Brasil pré-pagamento, e vira sinal de suporte via telemetria
#    (`sec_login_lockout`), não vira trava manual.
#  - O eixo SECUNDÁRIO é o IP (esta tabela): teto por origem para o spray não
#    precisar nem chegar na conta. Tentativa vinda de IP já bloqueado é recusada
#    ANTES de tocar `ValidateAuthPassword` — tráfego de origem queimada para de
#    ESCALAR o contador da vítima (é assim que o teto por IP protege o eixo conta
#    contra DoS por lockout).
#  - Por que o teto de IP é folgado (25 erros / 15 min, bloqueio de 30 min, janela
#    zera depois do bloqueio expirar): atrás do proxy o IP é COMPARTILHADO (Nota
#    da auditoria 24/09 sobre o reset), e trava agressiva por IP seria o novo DoS
#    de inocentes. IP vazio (transporte sem origem — ex. webhook local) não conta
#    no eixo IP: sem origem atribuível, só o eixo conta protege.
#  - 2FA vive no eixo CONTA (`totp_account`), não no IP: o segredo TOTP é durável,
#    então diferente do pending de reset (que morre no restart junto do código e
#    por isso conta em memória — ver `EmailService`), o orçamento de tentativa de
#    TOTP PRECISA sobreviver a deploy. Teto: 10 erros / 15 min por conta.
#
# Frente 3, régua COMPARTILHADA com o reset de senha: `AttemptBudget` é a função
# que o `EmailService.ValidateReset` deve passar a chamar quando quiser o mesmo
# contador durável (o agente do reset é o dono do EmailService; a chamada fica
# registrada como pendência no relatório — hoje a disciplina dele está correta em
# memória porque o pending é volátil, e nada aqui duplica aquele código).
#
# Frente 4 — telemetria de ataque: nomes FIXOS de `telemetry_event.kind` (constantes
# abaixo; dashboards e o `/metrics` do companion contam por esses nomes, nunca
# renomear). Escrita direta na tabela (não no buffer de 60 s do `TelemetryService`,
# que dropa antigo e morre no restart — o registro de ataque não pode ser o que se
# perde primeiro).

# Eixos de contagem (coluna `attempt_kind`)
const KindLoginIP : String				= "login_ip"
const KindTotp : String					= "totp_account"

# Política — IP (explicação no cabeçalho; generosa de propósito: NAT/proxy)
const LoginIPWindowSec : int			= 900
const LoginIPMaxFailures : int			= 25
const LoginIPBlockSec : int				= 1800

# Política — tentativa errada de TOTP por conta
const TotpWindowSec : int				= 900
const TotpMaxFailures : int				= 10

# Retenção da tabela de janelas: linhas mais velhas que isto são podadas pela
# própria escrita (a tabela não pode crescer sem teto).
const WindowRetentionSec : int			= 86400

# Métricas fixas (telemetry_event.kind) — frente 4
const EventLoginLockout : String		= "sec_login_lockout"
const EventLoginIPBlock : String		= "sec_login_ip_block"
const EventTotpThrottle : String		= "sec_totp_throttle"
const EventTotpReplay : String			= "sec_totp_replay"
const EventResetExhausted : String		= "sec_reset_exhausted"
const EventResetRequestLimit : String	= "sec_reset_request_limit"

static func _Now(now : int) -> int:
	return SQLCommons.Timestamp() if now <= 0 else now

# O IP está bloqueado AGORA? Leitura pura; sem linha = sem bloqueio.
static func IsBlocked(sql : Object, kind : String, subject : String, now : int = 0) -> bool:
	if sql == null or subject.is_empty():
		return false
	var rows : Array = sql.QueryBindings("SELECT blocked_until FROM security_attempt_window WHERE attempt_kind = ? AND attempt_subject = ?;", [kind, subject])
	return not rows.is_empty() and int(rows[0].get("blocked_until", 0)) > _Now(now)

# Carimba uma tentativa falhada no eixo (kind, subject). Devolve
# {"failures": int, "blocked": bool, "justBlocked": bool} — `justBlocked` é a
# transição (só ela emite métrica; tentativa dentro do bloqueio não incha a
# tabela). Janela rolante simples: `windowSec` a partir do PRIMEIRO erro da janela;
# quando um bloqueio expira a janela recomeça limpa (a fonte paga o teto de novo
# por onda — é o preço por tentativa de onda, não uma vida).
static func NoteFailure(sql : Object, kind : String, subject : String, windowSec : int, maxFailures : int, blockSec : int, now : int = 0) -> Dictionary:
	var notBlocked : Dictionary = {"failures": 0, "blocked": false, "justBlocked": false}
	if sql == null or subject.is_empty() or maxFailures <= 0:
		return notBlocked
	var stamp : int = _Now(now)
	_Prune(sql, stamp)
	var rows : Array = sql.QueryBindings("SELECT window_start, failures, blocked_until FROM security_attempt_window WHERE attempt_kind = ? AND attempt_subject = ?;", [kind, subject])
	var windowStart : int = stamp
	var failures : int = 0
	var blockedUntil : int = 0
	if not rows.is_empty():
		var row : Dictionary = rows[0]
		windowStart = int(row.get("window_start", stamp))
		failures = int(row.get("failures", 0))
		blockedUntil = int(row.get("blocked_until", 0))
		if blockedUntil > stamp:
			return {"failures": failures, "blocked": true, "justBlocked": false}
		# janela vencida OU bloqueio que já cumpriu: recomeça limpa
		if windowStart + windowSec <= stamp or blockedUntil > 0:
			failures = 0
			windowStart = stamp
	failures += 1
	var justBlocked : bool = false
	if failures >= maxFailures:
		blockedUntil = stamp + blockSec
		justBlocked = true
	sql.ExecuteBindings("INSERT OR REPLACE INTO security_attempt_window (attempt_kind, attempt_subject, window_start, failures, blocked_until) VALUES (?, ?, ?, ?, ?);", [kind, subject, windowStart, failures, blockedUntil])
	return {"failures": failures, "blocked": blockedUntil > stamp, "justBlocked": justBlocked}

# Régua compartilhada (frente 3): "N tentativas por janela, a N-ésima esgota".
# É o formato do budget do `EmailService.ValidateReset` (5 tentativas por pending)
# exposto em storage durável — 2FA usa daqui hoje, e o reset pode migrar para cá
# sem o dono do EmailService duplicar a máquina (pendência registrada).
static func AttemptBudget(sql : Object, kind : String, subject : String, maxAttempts : int, windowSec : int, now : int = 0) -> Dictionary:
	var result : Dictionary = NoteFailure(sql, kind, subject, windowSec, maxAttempts, windowSec, now)
	return {"attempts": int(result["failures"]), "exhausted": bool(result["blocked"]), "justExhausted": bool(result["justBlocked"])}

# Zera o eixo (login/budget certo): sucesso devolve o direito ao teto pleno.
static func ClearFailures(sql : Object, kind : String, subject : String) -> bool:
	if sql == null or subject.is_empty():
		return false
	return bool(sql.ExecuteBindings("DELETE FROM security_attempt_window WHERE attempt_kind = ? AND attempt_subject = ?;", [kind, subject]))

# Evento de ataque (frente 4). `accountID` 0 quando o sujeito não tem conta
# (spray a nome inexistente / IP bloqueado sem alvo resolvido).
static func LogSecurityEvent(sql : Object, eventKind : String, accountID : int, meta : String = "{}") -> bool:
	if sql == null or eventKind.is_empty():
		return false
	return bool(sql.ExecuteBindings("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, ?, 1, ?);", [SQLCommons.Timestamp(), maxi(accountID, 0), eventKind, meta]))

static func CountSecurityEvents(sql : Object, eventKind : String, sinceSec : int = 0) -> int:
	if sql == null:
		return 0
	var rows : Array = sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ?;", [eventKind, sinceSec])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

# Anti-replay (leitura): o hash do token já está na tabela de consumidos? Somente
# junto de um `VerifyTOTP` positivo isto distingue REPLAY de palpote errado — o
# Server usa para emitir `sec_totp_replay` sem tocar em `Peers.gd`.
static func IsTwoFactorTokenConsumed(sql : Object, accountID : int, token : String) -> bool:
	if sql == null or accountID <= 0 or token.is_empty():
		return false
	var rows : Array = sql.QueryBindings("SELECT 1 AS hit FROM two_factor_used_token WHERE account_id = ? AND token_hash = ? AND expires_at > ?;", [accountID, TwoFactorAuth.HashToken(token), SQLCommons.Timestamp()])
	return not rows.is_empty()

# Consumir + decidir frescor SEM depender de `SELECT changes()` (frente 3).
# `SQL.ConsumeTwoFactorToken` decide se foi replay por `changes()` logo após um
# `INSERT OR IGNORE`; com o pool de leitura ligado por padrão (ReadPoolDefault
# Enabled=true, aberto fora de web), o `SELECT changes()` é roteado para uma
# conexão só-leitura onde `changes()` vale sempre 0 → todo código VÁLIDO é lido
# como replay e o login 2FA vira DoS. Aqui o veredito vem de uma leitura
# persistida (uma `SELECT` por fato já cometido — roteável com segurança) e a
# escrita vai pelo handle do escritor (`ExecuteBindings`).
# Residual honesto: duas requisições CONCORRENTES do mesmo código numa fração de
# segundo podem ambas passar no pré-check (não há `changes()` atômico sem tocar
# `SQL.gd`). A correção definitiva é do dono do read-pool: excluir funções de
# estado de conexão (`changes()`, `last_insert_rowid()`) de `IsPureRead`.
# Registrado como pendência P0 no relatório.
static func ConsumeTwoFactorTokenSafe(sql : Object, accountID : int, token : String, ttlSec : int = 600) -> bool:
	if sql == null or accountID <= 0 or token.is_empty() or ttlSec <= 0:
		return false
	if IsTwoFactorTokenConsumed(sql, accountID, token):
		return false
	var stamp : int = SQLCommons.Timestamp()
	sql.ExecuteBindings("DELETE FROM two_factor_used_token WHERE expires_at <= ?;", [stamp])
	return bool(sql.ExecuteBindings("INSERT OR IGNORE INTO two_factor_used_token(account_id, token_hash, expires_at) VALUES (?, ?, ?);", [accountID, TwoFactorAuth.HashToken(token), stamp + ttlSec]))

# Igualador de timing (frente 2): conta inexistente saía da verificação SEM pagar
# o KDF, conta existente pagava 12.000 iterações — a diferença de latência responde
# "esse nome existe?" sem erro nenhum na tela. Queimar o MESMO custo num hash de
# ninguém fecha o canal; o salt fixo não é segredo (o resultado é descartado).
static func BurnKdfTime(password : String) -> void:
	var discarded : String = Hasher.HashPasswordV1(password, "shambleta-timing-equalizer")
	if discarded.length() < 0:
		push_error("unreachable")

# Poda acoplada à escrita (a tabela não cresce sem teto): tudo que não pode mais
# nem bloquear nem abrir janela nova.
static func _Prune(sql : Object, now : int) -> void:
	sql.ExecuteBindings("DELETE FROM security_attempt_window WHERE window_start < ? AND blocked_until < ?;", [now - WindowRetentionSec, now - WindowRetentionSec])
