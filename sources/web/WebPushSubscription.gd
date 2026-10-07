extends Node
class_name WebPushSubscription
# SOM-W5 C4: persistência SERVER-SIDE da subscription de web push do jogador.
#
# É a ponta do caminho que o navegador não alcança: o `sw.js` cria a
# subscription (`pushManager.subscribe`), a ponte `ShambletaPush` devolve os
# campos, o client web manda para o servidor de jogo, e SÓ AÍ a linha
# `push_subscription` (migration 052) nasce. Sem esta peça não há alvo: o
# `--push-sweep` do companion varre contas offline COM subscription, e nenhuma
# conta jamais teve uma.
#
# AUTORIDADE DE SERVIDOR — POR QUE `account_id` NUNCA VEM DO CLIENTE
# ------------------------------------------------------------------
# A conta da linha é SEMPRE a conta da SESSÃO (`Peers.GetAccount(peerID)`), e
# este módulo nem lê `account_id` do payload. O motivo não é elegância:
# `push_subscription.account_id` escolhe QUEM recebe. Uma subscription escrita
# para a conta X com o `endpoint`/`p256dh`/`auth` do atacante faz o companion
# cifrar as notificações da conta X para o push service do atacante — o corpo
# da notificação (título, corpo, ícone, URL) vaza para fora da conta, sem o
# dono dela clicar em nada. Aceitar `account_id` do client seria abrir uma
# fila de exfiltração por conta; por isso `Normalize()` DEVOLVE a conta da
# sessão no campo `account_id`, sempre, e `Register()` só usa esse valor.
#
# O mesmo vale para `updated_at`: relógio do servidor, nunca do navegador.
#
# O que este módulo NÃO faz, e por quê:
#  * não fala com o push service — a entrega é do companion
#    (`companion/push_vapid.py:send()`) lewat a fila `push_outbox`;
#  * não abre transação — é UMA statement (`INSERT ... ON CONFLICT`), e
#    encaixar `SQL.Transaction()` aqui seria exatamente o `Transaction()`
#    aninhado que este motor não perdoa (o `END` de dentro comete o trabalho de
#    fora; medido em `tests/read_pool_test.gd`);
#  * não loga endpoint: a URL do provedor de push é um bearer — quem souber o
#    endpoint + tiver a chave VAPID empurra notificação naquela assinatura. Por
#    isso a resposta traz `target` = esquema+host, nunca o caminho completo.
#
# A LINHA QUE FALTAVA landou em 2026-09-27, exatamente nesses quatro corpos, e é
# a superfície inteira que existe entre o `pushManager.subscribe()` do navegador e
# a linha que ESTE arquivo escreve:
#   1) `sources/network/Network.gd:543,549` — dois RPC client->server no bloco de
#      Auth/Config, junto de `SetReferralCode` (mesmo canal CONNECT: registro de
#      sessão não deve competir com o burst de ACTION):
#        @rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
#        func RegisterPushSubscription(endpoint, p256dh, auth, peerID = NetworkCommons.PeerAuthorityID)
#        func UnregisterPushSubscription(peerID = NetworkCommons.PeerAuthorityID)
#      Os wrappers devolvem void e mandam só os três campos do payload; o que o
#      jogador recebe de volta é o MOTIVO (`CommandFeedback`), nunca o endpoint.
#   2) `sources/network/server/Server.gd:1270,1277` — UM handler por RPC, com a
#      conta vindo de `Peers.GetAccount(peerID)` e NUNCA do payload:
#        func RegisterPushSubscription(endpoint, p256dh, auth, peerID):
#            WebPushSubscription.RegisterAndReport(Peers.GetAccount(peerID), ...)
#        func UnregisterPushSubscription(peerID):
#            WebPushSubscription.ReportUnregister(Peers.GetAccount(peerID), peerID)
#      `ReportUnregister` é o par do "Off" do toggle: sem ele o jogador diz não,
#      a linha fica no banco e o sweep continua notificando quem recusou.
# Quem mede isso não é a crença deste comentário: `tests/web_delivery_test.gd`
# executa `WebPushDelivery.ClientSubmitWired()` contra o autoload `Network` do
# processo e ainda força os dois motivos de falha (`no_network_node`,
# `rpc_not_landed:<rpc>`) antes de restaurar a árvore.
#   Nada mais neste repositório alcança essas duas linhas: o client web não tem
#   rota HTTP para o servidor de jogo (o nginx do serviço `web` serve shell e
#   proxya apenas `/webhooks/`, `/checkout/`, `GET /push/vapid` e `/catalog` para o
#   companion; a fila `/push/*` continua de fora de propósito), e o companion não
#   tem sessão de jogo — ele não sabe quem é o dono do token.
#   `sources/world/WorldCommands.gd` NÃO precisa de nada: a subscription caberia
#   num comando de chat (`/pushsub <url> <chave> <auth>`), mas mando de chat é
#   logado/telemetriadado como texto e a URL do endpoint é credencial — o caminho
#   é o RPC, não o chat.
#
# A PRONTIDÃO DO COMPANION (peça 2 do contrato) não passa por aqui: é uma
# leitura, não uma escrita autorizada por sessão. O
# client já sabe perguntar (`WebPushService.ProbeCompanionPushReady()` →
# `GET <NetworkCommons.CompanionURL>/push/vapid`), e a resposta entra no contrato
# por UM ponto (`ObserveCompanionPushResponse`). O caminho por onde a resposta
# chega a um browser foi escolhido e implementado em 2026-09-27:
#   (a) UMA `location = /push/vapid` no nginx do serviço `web` proxyando para o
#       companion (rota somente-leitura, GET-only, responde `ready` + pública +
#       motivo coarse; `POST /push/test` e a fila continuam de fora — a rota é
#       EXATA justamente para que `/push/test` não herde proxy). Zero linha nova
#       em `Server.gd`/`Network.gd`. A régua deixou de dizer "nginx não proxya
#       /push" e passou a dizer "não proxya /push/test nem nenhum outro /push"
#       (tests/web_delivery_test.gd e a suíte F de tests/nginx_hardening_test.gd).
#   (b) relay pelo servidor de jogo: `Server.gd` chama `ProbeCompanionPushReady()`
#       uma vez no boot e anuncia o corpo aos peers por um RPC a mais. Custa duas
#       linhas nos arquivos fenceados e mantém a fronteira pública fechada. É a
#       alternativa se um dia a prontidão precisar de segredo na resposta — hoje
#       não precisa, e (a) ganhou por isso.
# O que ainda mantém `CanDeliver()` false nesta máquina: a peça 4 (nenhum harness
# headless registra service worker num browser) e as peças 2/3, que só abrem com
# uma resposta real de `GET /push/vapid` vindo de uma deploy com chave — código e
# caminho existem, falta o processo do outro lado. A peça 6 abriu em 2026-09-27
# (os quatro corpos acima). Enquanto qualquer peça faltar, `CanDeliver()` responde
# false — que é a resposta correta, não um bug a contornar com `return true`.

const Table : String = "push_subscription"

# Tetos de tamanho: `endpoint` é URL escolhida pelo provedor (RFC 8030 §5.1 não
# fixa teto; 2048 é o menor teto de navegador para URL e sobra para qualquer
# provedor real) e o material de criptografia é base64url de 65/16 octetos —
# 512 dá duas ordens de folga e ainda mata payload inflado.
const MaxEndpoint : int = 2048
const MaxMaterial : int = 512

# Motivos estabilizados — são a resposta do gate e o que o log pode dizer. Um
# motivo nunca ecoa o valor recebido (endpoint é credencial).
const ReasonNoSession : String = "no_session"
const ReasonUnknownAccount : String = "unknown_account"
const ReasonMissing : String = "missing_"
const ReasonTooLong : String = "too_long_"
const ReasonBadMaterial : String = "material_not_base64url"
const ReasonBadScheme : String = "endpoint_not_https"
const ReasonWriteRefused : String = "sql_write_refused"

# Mesma lista de loopback do companion (`push_common.CLEARTEXT_HOSTS`): http só
# é aceitável onde nenhum segredo de verdade viaja — harness e receiver local.
# Literal de Array e não `PackedStringArray([...])`: em Godot 4.7 chamar um
# construtor aqui NÃO é expressão constante e o arquivo inteiro deixa de parsear
# (`Constant "CleartextHosts" isn't a constant expression`), o que derruba todo
# harness que dependa desta classe. `has()` funciona igual nos dois tipos.
const CleartextHosts : Array[String] = ["127.0.0.1", "localhost", "::1"]

static func _now() -> int:
	return int(Time.get_unix_time_from_system())

static func _IsBase64Url(text : String) -> bool:
	if text.is_empty():
		return false
	for i : int in range(text.length()):
		var c : int = text.unicode_at(i)
		var ok : bool = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 45 or c == 95
		if not ok:
			return false
	return true

static func _Refusal(reason : String) -> Dictionary:
	return {"ok": false, "reason": reason}

# Esquema+host do endpoint — o único pedaço dele que pode virar log.
static func TargetLabel(endpoint : String) -> String:
	var idx : int = endpoint.find("://")
	if idx < 0:
		return "invalid"
	var rest : String = endpoint.substr(idx + 3)
	var cut : int = rest.find("/")
	var hostport : String = rest if cut < 0 else rest.substr(0, cut)
	var scheme : String = endpoint.substr(0, idx).to_lower()
	return "%s://%s" % [scheme, hostport.to_lower()]

static func _Host(endpoint : String) -> String:
	var idx : int = endpoint.find("://")
	if idx < 0:
		return ""
	var rest : String = endpoint.substr(idx + 3)
	var cut : int = rest.find("/")
	if cut >= 0:
		rest = rest.substr(0, cut)
	var at : int = rest.rfind("@")
	if at >= 0:
		rest = rest.substr(at + 1)
	# IPv6 literal vem entre colchetes (`http://[::1]:8080/p`); o `:` de dentro
	# NUNCA é porta. Sem isto o host sairia "[::1]" e a lista de loopback abaixo
	# divergiria da do companion (`push_common.CLEARTEXT_HOSTS` tem "::1").
	if rest.begins_with("["):
		var close : int = rest.find("]")
		if close > 0:
			return rest.substr(1, close - 1).to_lower()
		return rest.to_lower()
	# Porta só sai quando há UM `:` e o que vem depois é número.
	if rest.count(":") == 1 and rest.substr(rest.find(":") + 1).is_valid_int():
		rest = rest.substr(0, rest.find(":"))
	return rest.to_lower()

# Validação pura (sem SQL, sem estado): é isto que responde "por que não entrou".
# `sessionAccountID` É a conta da linha; qualquer `account_id` no payload é
# descartado — ver o cabeçalho.
static func Normalize(sessionAccountID : int, payload : Dictionary) -> Dictionary:
	if sessionAccountID <= 0:
		return _Refusal(ReasonNoSession)
	var endpoint : String = str(payload.get("endpoint", "")).strip_edges()
	var p256dh : String = str(payload.get("p256dh", "")).strip_edges()
	var auth : String = str(payload.get("auth", "")).strip_edges()
	if endpoint.is_empty():
		return _Refusal(ReasonMissing + "endpoint")
	if p256dh.is_empty():
		return _Refusal(ReasonMissing + "p256dh")
	if auth.is_empty():
		return _Refusal(ReasonMissing + "auth")
	if endpoint.length() > MaxEndpoint:
		return _Refusal(ReasonTooLong + "endpoint")
	if p256dh.length() > MaxMaterial or auth.length() > MaxMaterial:
		return _Refusal(ReasonTooLong + "material")
	if not _IsBase64Url(p256dh) or not _IsBase64Url(auth):
		return _Refusal(ReasonBadMaterial)
	if not endpoint.begins_with("https://"):
		if not endpoint.begins_with("http://") or not CleartextHosts.has(_Host(endpoint)):
			return _Refusal(ReasonBadScheme)
	return {
		"ok": true,
		"account_id": sessionAccountID,
		"endpoint": endpoint,
		"p256dh": p256dh,
		"auth": auth,
		"target": TargetLabel(endpoint),
	}

# A ÚNICA escrita de `push_subscription` no lado do jogo. Upsert de uma linha
# por conta (PRIMARY KEY em `account_id` é o desenho da migration 052: trocar de
# navegador re-escreve o mesmo registro). Uma statement, sem `Transaction()`.
static func Register(sql : Object, sessionAccountID : int, payload : Dictionary) -> Dictionary:
	if sql == null:
		return _Refusal("no_sql_handle")
	var data : Dictionary = Normalize(sessionAccountID, payload)
	if not bool(data.get("ok", false)):
		return data
	var accountID : int = int(data["account_id"])
	# A conta tem de existir no banco do jogo — registration de conta fantasma é
	# lixo na fila (mesma regra do `--push-register` do companion).
	var known : Array = sql.QueryBindings("SELECT account_id FROM account WHERE account_id = ?;", [accountID])
	if known.is_empty():
		return _Refusal(ReasonUnknownAccount)
	var wrote : bool = bool(sql.ExecuteBindings(
		"INSERT INTO push_subscription (account_id, endpoint, p256dh, auth, updated_at) "
		+ "VALUES (?, ?, ?, ?, ?) "
		+ "ON CONFLICT(account_id) DO UPDATE SET endpoint = excluded.endpoint, "
		+ "p256dh = excluded.p256dh, auth = excluded.auth, updated_at = excluded.updated_at;",
		[accountID, data["endpoint"], data["p256dh"], data["auth"], _now()]))
	if not wrote:
		return _Refusal(ReasonWriteRefused)
	return {"ok": true, "account_id": accountID, "target": data["target"],
			"reason": "registered"}

static func RegisterStrings(sql : Object, sessionAccountID : int, endpoint : String, p256dh : String, auth : String) -> Dictionary:
	return Register(sql, sessionAccountID, {"endpoint": endpoint, "p256dh": p256dh, "auth": auth})

# Leitura da própria conta (ops/harness). Devolve os campos crus — quem chama é
# servidor, nunca log.
static func Read(sql : Object, accountID : int) -> Dictionary:
	if sql == null or accountID <= 0:
		return {}
	var rows : Array = sql.QueryBindings(
		"SELECT endpoint, p256dh, auth, updated_at FROM push_subscription WHERE account_id = ?;",
		[accountID])
	return rows[0] if not rows.is_empty() else {}

static func Remove(sql : Object, sessionAccountID : int) -> Dictionary:
	if sql == null:
		return _Refusal("no_sql_handle")
	if sessionAccountID <= 0:
		return _Refusal(ReasonNoSession)
	var wrote : bool = bool(sql.ExecuteBindings(
		"DELETE FROM push_subscription WHERE account_id = ?;", [sessionAccountID]))
	return {"ok": wrote, "account_id": sessionAccountID,
			"reason": "removed" if wrote else ReasonWriteRefused}

# --------------------------------------------------------------------------
# caminho client->server (web) e resposta ao jogador
# --------------------------------------------------------------------------

static func _NetworkNode() -> Node:
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Network"))

# O client web entrega a subscription criada pelo navegador. `has_method` é a
# régua honesta: enquanto o RPC não landar em `Network.gd`, isto devolve
# `rpc_not_landed` — e `WebPushDelivery.ClientSubmitWired()` mede o mesmo fato,
# que é por que o gate continua fechado em vez de fingir que enviou.
static func SubmitToServer(endpoint : String, p256dh : String, auth : String) -> Dictionary:
	var net : Node = _NetworkNode()
	if net == null:
		return _Refusal("no_network_node")
	if not net.has_method(WebPushDelivery.RpcRegister):
		return _Refusal("rpc_not_landed")
	if not LauncherCommons.isWeb:
		return _Refusal("not_web")
	net.call(WebPushDelivery.RpcRegister, endpoint, p256dh, auth)
	return {"ok": true, "reason": "submitted"}

static func SubmitUnregisterToServer() -> Dictionary:
	var net : Node = _NetworkNode()
	if net == null or not net.has_method(WebPushDelivery.RpcUnregister):
		return _Refusal("rpc_not_landed")
	net.call(WebPushDelivery.RpcUnregister)
	return {"ok": true, "reason": "submitted"}

# O corpo do handler que landar em `Server.gd`: escreve pela sessão e responde
# pelo mesmo canal que os outros comandos já usam (`CommandFeedback`), para que
# a linha nova no arquivo fenceado seja UMA só.
static func RegisterAndReport(sessionAccountID : int, endpoint : String, p256dh : String, auth : String, peerID : int) -> Dictionary:
	var result : Dictionary = Register(WebPushDelivery.SQLHandle(), sessionAccountID,
		{"endpoint": endpoint, "p256dh": p256dh, "auth": auth})
	var net : Node = _NetworkNode()
	if net != null and net.has_method("CommandFeedback"):
		if bool(result.get("ok", false)):
			net.call("CommandFeedback", "push subscription saved (%s)" % str(result.get("target", "")), peerID)
		else:
			net.call("CommandFeedback", "push subscription refused (%s)" % str(result.get("reason", "?")), peerID)
	return result

# Par do "Off" do toggle, e é a metade que evita o pior tipo de mentira: sem
# chamada de remoção a linha fica no banco depois que o jogador recusou, e o
# sweep continua empurrando notificação em quem disse não. Mesmos contratos de
# `RegisterAndReport`: conta vem da SESSÃO (nunca do payload), escrito pelo mesmo
# handle SQL, resposta pelo mesmo `CommandFeedback`. Não loga endpoint nem ecoa
# material — só o motivo estabilizado de `Remove()`.
static func ReportUnregister(sessionAccountID : int, peerID : int) -> Dictionary:
	var result : Dictionary = Remove(WebPushDelivery.SQLHandle(), sessionAccountID)
	var net : Node = _NetworkNode()
	if net != null and net.has_method("CommandFeedback"):
		if bool(result.get("ok", false)):
			net.call("CommandFeedback", "push subscription removed", peerID)
		else:
			net.call("CommandFeedback", "push unsubscribe refused (%s)" % str(result.get("reason", "?")), peerID)
	return result
