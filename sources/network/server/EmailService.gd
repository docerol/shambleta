extends Node
class_name EmailService

#
const PasswordResetTemplatePath : String	= "conf/email_password_reset.html"
const SmtpApiUrl : String					= "https://api.brevo.com/v3/smtp/email"

var apiKey : String							= ""
var senderName : String						= ""
var senderEmail : String					= ""
var passwordResetTemplate : String			= ""
var httpRequest : HTTPRequest				= null

# Password reset storage: { accountID: { "code_hash": String, "created": int, "expires": int, "attempts": int } }
# UNIDADE de pending por conta: `CreateReset` sobrescreve a entrada, então existe
# sempre um único código vivo por conta e o contador de tentativas vive exatamente
# enquanto o pending viver (mesmo Dictionary, mesma vida, mesmo `erase`).
var pendingResets : Dictionary			= {}

# Solicitações da janela corrente por conta (espelho em memória do ledger
# `password_reset_request`, migration 050): { accountID: Array[int] }
var resetRequests : Dictionary			= {}

# Facada de persistência injetável (harness headless passa um fake). Em runtime é
# `Launcher.SQL`. Sem store disponível as regras de memória continuam valendo — a
# segurança do fluxo não pode depender de a base estar de pé.
var resetStore : Object					= null

#
func _ready():
	apiKey = Conf.GetString("Email", "Email-ApiKey", Conf.Type.CREDENTIAL)
	senderName = Conf.GetString("Email", "Email-SenderName", Conf.Type.CREDENTIAL)
	senderEmail = Conf.GetString("Email", "Email-SenderAddress", Conf.Type.CREDENTIAL)
	if senderName.is_empty():
		senderName = "Shambleta"
	passwordResetTemplate = FileSystem.LoadFile(PasswordResetTemplatePath)
	httpRequest = HTTPRequest.new()
	add_child(httpRequest)
	httpRequest.request_completed.connect(RequestCompleted)

	if IsConfigured():
		Util.PrintLog("EmailService", "Initialized with sender: %s" % senderEmail)
	elif apiKey.is_empty():
		Util.PrintLog("EmailService", "Not configured: missing API key")
	else:
		Util.PrintLog("EmailService", "Not configured: missing sender address")

#
func IsConfigured() -> bool:
	return not apiKey.is_empty() and not senderEmail.is_empty()

func SendPasswordResetEmail(toEmail : String, code : String) -> void:
	if not IsConfigured():
		push_error("EmailService is not configured, can't send password reset email")
		return


	var headers : PackedStringArray = [
		"api-key: %s" % apiKey,
		"Content-Type: application/json",
		"accept: application/json"
	]

	var body : Dictionary = {
		"sender": {
			"name": senderName,
			"email": senderEmail
		},
		"to": [
			{ "email": toEmail }
		],
		"subject": "Password Reset Request",
		"htmlContent": FormatPasswordResetEmail(code)
	}

	Util.PrintLog("EmailService", "Sending password reset email to: %s" % toEmail)
	var err : Error = httpRequest.request(SmtpApiUrl, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		Util.PrintLog("EmailService", "Failed to initiate HTTP request (error: %d)" % err)

func FormatPasswordResetEmail(code : String) -> String:
	if passwordResetTemplate.is_empty():
		return "<p>Your password reset code is: <strong>%s</strong></p><p>This code expires in %d minutes.</p>" % [code, NetworkCommons.ResetCodeExpiryMinutes]
	return passwordResetTemplate.replace("{CODE}", code).replace("{EXPIRY_MINUTES}", str(NetworkCommons.ResetCodeExpiryMinutes)).replace("{SENDER_NAME}", senderName)

func RequestCompleted(result : int, responseCode : int, _headers : PackedStringArray, body : PackedByteArray):
	if result != HTTPRequest.RESULT_SUCCESS or responseCode < 200 or responseCode >= 300:
		var responseBody : String = body.get_string_from_utf8()
		Util.PrintLog("EmailService", "Failed to send email (result: %d, code: %d, body: %s)" % [result, responseCode, responseBody])
	else:
		Util.PrintLog("EmailService", "Email sent successfully (code: %d)" % responseCode)

# Password Reset Storage
# SOM-IDLE AUTH-P0 (auditoria 2026-09-27 §10/§22-P0-2). Regras deste bloco:
#  - UM pending por conta; a nova solicitação substitui a anterior (TTL de
#    `NetworkCommons.ResetCodeExpiryMinutes` e contador zerado — código novo,
#    budget novo);
#  - cada tentativa errada consome uma de `NetworkCommons.ResetCodeMaxAttempts`;
#    na última o pending é apagado e o usuário precisa pedir outro código;
#  - a quantidade de SOLICITAÇÕES é limitada por conta em janela rolante
#    (memória + ledger `password_reset_request`), não por peer;
#  - a comparação do hash é em tempo constante (`Hasher.SecureEquals`).
# O erro de tentativa errada NÃO vira lockout de conta de propósito: o lockout de
# senha (`SQL.RecordFailedLogin`, já em `LoginWithPassword`) é acionado por
# credencial errada, e amarrar o reset a ele daria a quem sabe um nome de conta um
# DoS de 2h contra o dono (5 palpites errados, sem precisar de nenhum e-mail).

# Seam do harness: 0 = relógio real; >0 = tempo fixo para provar TTL.
var nowOverride : int					= 0

func _Now() -> int:
	return nowOverride if nowOverride > 0 else SQLCommons.Timestamp()

# `Launcher.SQL` resolto em runtime (nunca em parse): o EmailService nasce no
# `Launcher.Server()` junto do SQL, e o harness headless injeta `resetStore`.
func _ResetStore() -> Object:
	if resetStore != null:
		return resetStore
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var launcher : Node = tree.root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		return null
	return launcher.get("SQL")

func CreateReset(accountID : int, codeHash : String):
	var now : int = _Now()
	pendingResets[accountID] = {
		"code_hash": codeHash,
		"created": now,
		"expires": now + NetworkCommons.ResetCodeExpiryMinutes * 60,
		"attempts": 0,
	}

# Tenta abrir uma solicitação de reset para a conta. Devolve false SEM registrar
# nada quando o teto da janela já valia — o chamador responde a mesma coisa ao
# client (anti-enumeration) e simplesmente não sai e-mail.
func BeginResetRequest(accountID : int) -> bool:
	var now : int = _Now()
	var windowStart : int = now - NetworkCommons.ResetRequestWindowMinutes * 60
	_PrunePendingResets(now)

	var store : Object = _ResetStore()
	if store != null and _DurableRequestCount(store, accountID, windowStart) >= NetworkCommons.ResetRequestWindowMax:
		return false

	var stamps : Array = resetRequests.get(accountID, [])
	var kept : Array = []
	for stamp in stamps:
		if int(stamp) > windowStart:
			kept.append(int(stamp))
	if kept.size() >= NetworkCommons.ResetRequestWindowMax:
		resetRequests[accountID] = kept
		return false

	kept.append(now)
	resetRequests[accountID] = kept
	if store != null:
		_RecordDurableRequest(store, accountID, now, now + NetworkCommons.ResetCodeExpiryMinutes * 60)
	return true

func HasPendingReset(accountID : int) -> bool:
	return pendingResets.has(accountID)

func ResetAttempts(accountID : int) -> int:
	if not pendingResets.has(accountID):
		return 0
	return int(pendingResets[accountID]["attempts"])

func ValidateReset(accountID : int, codeHash : String) -> bool:
	if not pendingResets.has(accountID):
		return false
	var entry : Dictionary = pendingResets[accountID]
	if int(entry["expires"]) <= _Now():
		RemoveReset(accountID)
		return false
	if Hasher.SecureEquals(str(entry["code_hash"]), codeHash):
		# O acerto NÃO consome o pending aqui: quem apaga é o chamador, depois de a
		# transação de troca de senha commitar. Consumir aqui deixaria o dono sem
		# código válido se o SQL falhasse no meio.
		return true
	var attempts : int = int(entry["attempts"]) + 1
	entry["attempts"] = attempts
	if attempts >= NetworkCommons.ResetCodeMaxAttempts:
		RemoveReset(accountID)
		Util.PrintLog("EmailService", "Reset: account %d exhausted %d attempts, pending consumed" % [accountID, attempts])
	return false

# Apaga o pending (e, com ele, o contador de tentativas — os dois são a mesma
# linha). O histórico de SOLICITAÇÕES (`resetRequests` + ledger) fica de propósito:
# é o que impede o flood de e-mail depois de um exhaustion.
func RemoveReset(accountID : int):
	pendingResets.erase(accountID)

func _PrunePendingResets(now : int):
	for accountID in pendingResets.keys():
		if int(pendingResets[accountID]["expires"]) <= now:
			pendingResets.erase(accountID)

# Ledger durável (`password_reset_request`, migration 050): o budget por janela é o
# único número que precisa sobreviver ao restart — o pending em si é de memória e
# um restart derruba o código, então o atacante precisa que o DONO peça outro.
func _DurableRequestCount(store : Object, accountID : int, windowStart : int) -> int:
	var rows : Array = store.QueryBindings("SELECT COUNT(*) AS n FROM password_reset_request WHERE account_id = ? AND requested_at > ?;", [accountID, windowStart])
	if rows.is_empty():
		return 0
	return int(rows[0].get("n", 0))

func _RecordDurableRequest(store : Object, accountID : int, now : int, codeExpiresAt : int):
	# Purga acoplada à escrita: a tabela não pode crescer sem teto e o teto
	# (24h) é maior que a janela contada (60 min), então a janela nunca é podada.
	store.ExecuteBindings("DELETE FROM password_reset_request WHERE requested_at < ?;", [now - 24 * 60 * 60])
	store.ExecuteBindings("INSERT INTO password_reset_request (account_id, requested_at, code_expires_at) VALUES (?, ?, ?);", [accountID, now, codeExpiresAt])
