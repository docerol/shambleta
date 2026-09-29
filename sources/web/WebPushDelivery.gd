extends Node
class_name WebPushDelivery
# SOM-W5: contrato de entrega de web push — a parte DO JOGO do caminho que o
# companion já anda (migration 052: push_subscription + push_outbox; CLI
# `--push-register`/`--push-sweep`/`--push-drain`; `GET /push/vapid`; POST
# `/push/test` com sender plugável). Este arquivo é static-only e não é autoload:
# mora ao lado de `WebPush.gd` para o harness headless
# (`tests/web_delivery_test.gd`) amarrar as duas pontas sem subir a árvore de nós.
#
# POR QUE UMA CONJUNÇÃO, E POR QUE NÃO UM `return false`
# ---------------------------------------------------------------------------
# Houve um `return false` aqui, justificado por "o sender do companion é
# NotImplementedError". Isso era verdade em 2026-09-26 e deixou de ser em
# 2026-09-27, quando `companion/push_vapid.py` passou a assinar VAPID (RFC 8292)
# e a cifrar `aes128gcm` (RFC 8291/8188) com stdlib puro. O `false` continuou
# lá, e a régua (`tests/web_delivery_test.gd`) media o `false`, não o mundo: um
# gate que devolve o que o teste espera não gate nada.
#
# Agora cada peça do caminho é UMA função com UM nome, cada função tem UMA
# asserção no harness, e `CanDeliver()` é a E delas. No dia em que uma peça
# nascer (ou apodrecer), só a asserção daquela peça muda. Nada aqui é literal de
# veredito: ou é fato de repositório medido por EXECUÇÃO no harness, ou é sonda
# de runtime que responde pelo que o processo consegue ver agora.
#
# COMO CADA PEÇA É MEDIDA (o que o harness executa, não o que este texto crê)
# ---------------------------------------------------------------------------
#   SenderImplemented()            Fato do companion: o sender VAPID/ES256 de
#                                  stdlib puro existe (`companion/push_vapid.py:
#                                  ecdsa_sign`, `send()`) e a imagem o embarca
#                                  (`deploy/companion/Dockerfile` copia as quatro
#                                  camadas). A régua é EXECUTADA: o passo python
#                                  do harness gera um par P-256 em runtime
#                                  (nenhum segredo mora no repositório), sobe um
#                                  push service de mentira em 127.0.0.1 e exige
#                                  que `send()` produza o POST com
#                                  `Authorization: vapid` e corpo `aes128gcm`
#                                  real. NÃO é a resposta à pergunta "push pode
#                                  sair agora?" — isso é a peça 2b. O rótulo que a
#                                  fila grava quando o sender não pode rodar
#                                  mudou de significado: `vapid_sender_unimplemented`
#                                  hoje quer dizer "sem chave no deploy"
#                                  (fail-closed verdadeiro), não "sem sender".
#   CompanionReportsPushReady()    PRONTIDÃO de runtime, observada: só vira true
#                                  depois que UMA resposta real de
#                                  `GET /push/vapid` do companion disse
#                                  `ready: true`. É a única pergunta que existe
#                                  para "a deploy consegue entregar agora", e o
#                                  writer é um só
#                                  (`WebPushService.ObserveCompanionPushResponse`
#                                  → `ObserveCompanionPushReady`). Sem resposta, o
#                                  motivo é `companion_not_probed` — e
#                                  `CanDeliver()` fecha. Foi exatamente aqui que
#                                  o contrato quase mentiu ao contrário: trocar
#                                  `SenderImplemented()` por `CanDeliver()` ligaria
#                                  o toggle e registraria o worker de todo
#                                  jogador numa deploy sem chave, onde cada push
#                                  morre em `vapid_sender_unimplemented`.
#   VapidKeyConfigured()           Estado OBSERVADO pela MESMA resposta de 2b: a
#                                  pública só entra por `ObserveCompanionPushReady`
#                                  (ou por `ObserveVapidPublicKey`, o ponto único
#                                  embaixo), e uma resposta `ready: false` a
#                                  LIMPA — as duas pontas nunca divergem. Sem
#                                  ela nenhuma subscription nasce, e o único
#                                  entregador possível é o companion: em browser
#                                  a pergunta sai pela origem da página, que
#                                  proxya o caminho EXATO `GET /push/vapid`
#                                  (`deploy/web/nginx.conf`) e mantém a fila fora
#                                  do proxy — `/push/test` não é rota pública.

#   BrowserCanSubscribe()          Pergunta à ponte `ShambletaPush` do template do
#                                  export (`can_subscribe()`): existe
#                                  `PushManager`, e existe registration ativa?
#                                  Fora do Web nem se pergunta. É a peça que o
#                                  `pushManager.subscribe()` do shell fecha — sem
#                                  ela nenhuma subscription nasce.
#   ServerPersistsSubscriptions()  Sonda de schema no SQL do processo:
#                                  `ColumnsOf("push_subscription")` (migration
#                                  052) devolve colunas. É o caminho de escrita
#                                  real: `WebPushSubscription.Register()`.
#   ClientSubmitWired()            Sonda de fiação: pergunta ao nó `Network` do
#                                  processo se ele tem o RPC client->server
#                                  `RegisterPushSubscription`. Sem ele a
#                                  subscription que o navegador criou nunca chega
#                                  à linha que o servidor escreve. Landou em
#                                  2026-09-27 (`Network.gd:543`/`Server.gd:1111`),
#                                  e aqui a sonda responde true — o que fecha o
#                                  gate hoje é a peça 4, não esta.
#
# O registrador do worker (`WebPushService._register_service_worker`) e a linha de
# Settings continuam lendo `CanDeliver()`: UMA fonte de verdade, sem segundo
# `return false` para lembrar de atualizar — nem um `return true` solto, que é o
# outro modo de mentir. Como a prontidão chega por resposta assíncrona de HTTP, o
# registrador é re-entrado quando ela chega (`WebPushService._OnCompanionProbe`),
# e só então o `pushManager` do navegador passa a existir para o jogo. O worker
# de push (`deploy/web/sw.js`) é SERVIDO (Dockerfile/nginx, no-cache) e registrado
# no escopo estreito `/sw/`,
# nunca em `/`: registrar em `/` deslocaria `index.service.worker.js` do engine,
# que é o dono do cache offline dos assets.

# RPC client->server que entrega a subscription ao servidor de jogo. É NOME de
# método, não promessa: `ClientSubmitWired()` consulta `has_method` no nó
# `Network` do processo, então a asserção acompanha o mundo — ela era false até
# 2026-09-27 e é true desde que a linha landou em `Network.gd` + `Server.gd`, sem
# que ninguém tocasse neste arquivo.
const RpcRegister : String = "RegisterPushSubscription"
const RpcUnregister : String = "UnregisterPushSubscription"

# Tabelas da migration 052 — a única fonte do schema é `data/conf/migrations/`.
const SubscriptionTable : String = "push_subscription"
const OutboxTable : String = "push_outbox"

# Formato de `applicationServerKey`: 65 octetos X9.62 não comprimidos
# (`0x04 || x || y`) em base64url sem padding = 87 caracteres.
const PublicKeyLength : int = 87

static var _observedPublicKey : String = ""
static var _lastReason : String = "not_probed"

# Prontidão observada do companion. `companion_not_probed` é o estado inicial E o
# estado honesto de qualquer processo que nunca falou com um companion — inclusive
# o harness headless: aqui ninguém acorda `true` por padrão.
const ReasonNotProbed : String = "companion_not_probed"

static var _companionReady : bool = false
static var _companionReason : String = ReasonNotProbed

# --------------------------------------------------------------------------
# peça 1 — o CÓDIGO do sender existe
# --------------------------------------------------------------------------

# Verdade sobre `companion/push_vapid.py`: `send()` (@:368) faz o POST real com
# assertion VAPID e payload `aes128gcm`; `vapid_authorization()` (@:296) assina
# e AUTO-CONFERE antes de sair pela porta. Não há mais `NotImplementedError` em
# nenhum dos quatro módulos do caminho (`push_common`/`push_p256`/`push_aesgcm`/
# `push_vapid`) — o que restou de fail-closed mora em `server.py`
# (`vapid_webpush_send` levanta `NotImplementedError` SEM CHAVE no deploy, ou sem
# as camadas na imagem, e a fila grava `vapid_sender_unimplemented`), e isso é
# comportamento correto de CONFIGURAÇÃO, não ausência de código. A régua desta
# linha é o passo python do harness, que executa o sender contra um receiver
# loopback. O que esta função NÃO responde é " sai agora?": isso é a peça 2.
static func SenderImplemented() -> bool:
	return true

# --------------------------------------------------------------------------
# peça 2 — o companion está pronto (prontidão observada, nunca suposta)
# --------------------------------------------------------------------------

# Única porta de entrada da prontidão. Quem fala com o companion
# (`WebPushService.ProbeCompanionPushReady()`, ou o relay que entregar a resposta
# ao client) chama isto com o que a resposta disse — e nada neste arquivo tem
# opinião sobre o resultado. `ready: false` LIMPA a pública observada: as duas
# pontas vêm da mesma resposta, então "chave configurada" e "companion pronto"
# nunca podem discordar (discordar é o bug que este contrato existe para pegar).
static func ObserveCompanionPushReady(ready : bool, publicKey : String, reason : String) -> void:
	var why : String = reason.strip_edges()
	_companionReady = ready
	_companionReason = why if not why.is_empty() else ("companion_ready" if ready else "companion_not_ready")
	if ready:
		var key : String = publicKey.strip_edges()
		if not key.is_empty():
			_observedPublicKey = key
	else:
		_observedPublicKey = ""

# O veredito lido por `CanDeliver()`: false até um companion responder pronto.
# Em qualquer harness headless isto é `companion_not_probed` — não há companion
# na máquina, e fingir o contrário é o "toggle prometendo push que não chega".
static func CompanionReportsPushReady() -> bool:
	if not _companionReady:
		_lastReason = "companion_push_not_ready:%s" % _companionReason
		return false
	return true

static func CompanionReadyReason() -> String:
	return _companionReason

# --------------------------------------------------------------------------
# peça 3 — chave VAPID configurada (estado observado, nunca suposto)
# --------------------------------------------------------------------------

# Porta de baixo da chave PÚBLICA — chamada por `ObserveCompanionPushReady()`,
# que é o ponto único por onde a resposta do companion entra. A PRIVADA nunca
# passa por aqui — nem por este processo, nem por log, nem por este repositório.
static func ObserveVapidPublicKey(publicKey : String) -> void:
	_observedPublicKey = publicKey.strip_edges()

static func VapidPublicKey() -> String:
	return _observedPublicKey

static func IsBase64Url(text : String) -> bool:
	if text.is_empty():
		return false
	for i : int in range(text.length()):
		var c : int = text.unicode_at(i)
		var ok : bool = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 45 or c == 95
		if not ok:
			return false
	return true

static func VapidKeyConfigured() -> bool:
	if _observedPublicKey.length() != PublicKeyLength or not IsBase64Url(_observedPublicKey):
		_lastReason = "vapid_key_not_observed"
		return false
	return true

# --------------------------------------------------------------------------
# peça 4 — o navegador consegue assinar
# --------------------------------------------------------------------------

static func BrowserCanSubscribe() -> bool:
	if not LauncherCommons.isWeb:
		_lastReason = "not_web"
		return false
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if js == null:
		_lastReason = "no_bridge"
		return false
	var answer : bool = bool(js.can_subscribe())
	_lastReason = "browser_ready" if answer else str(js.subscribe_error())
	return answer

# --------------------------------------------------------------------------
# peça 5 — o servidor de jogo persiste a subscription
# --------------------------------------------------------------------------

# Acha o SQL do processo sem depender de ordem de boot (o autoload `Launcher`
# pode ainda não existir quando um `load()` toca este arquivo sob `-s`) e sem
# gritar: cada ramo devolve null, nunca exceção. O mesmo `Object`-param de
# `sources/sql/SQLSecurity.gd` — tipar em `SQLService` amarraria este contrato a
# um `class_name` que não é parte dele.
static func SQLHandle() -> Object:
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var launcher : Node = tree.root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		return null
	return launcher.get("SQL")

# A peça em si, com o handle por parâmetro (é assim que o harness a executa com
# o `Launcher.SQL` real). `ColumnsOf` vem do schema vivo: migration 052 aplicada
# => colunas; banco velho sem 052 => vazio.
static func ServerPersistsSubscriptions(sql : Object) -> bool:
	if sql == null:
		_lastReason = "no_sql_handle"
		return false
	var columns : PackedStringArray = sql.ColumnsOf(SubscriptionTable)
	if columns.is_empty():
		_lastReason = "no_subscription_table"
		return false
	return true

static func ServerPersistsSubscriptionsObserved() -> bool:
	return ServerPersistsSubscriptions(SQLHandle())

# --------------------------------------------------------------------------
# peça 6 — a subscription do navegador chega ao servidor
# --------------------------------------------------------------------------

static func _Network() -> Node:
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Network"))

static func ClientSubmitWired() -> bool:
	var net : Node = _Network()
	if net == null:
		_lastReason = "no_network_node"
		return false
	if not net.has_method(RpcRegister):
		_lastReason = "rpc_not_landed:%s" % RpcRegister
		return false
	return true

# --------------------------------------------------------------------------
# o contrato
# --------------------------------------------------------------------------

# Estado de cada peça, numerado — é isto que o harness imprime e compara. Uma
# peça por chave; nenhuma chave esconde a outra.
static func DeliverParts() -> Dictionary:
	return {
		"sender_implemented": SenderImplemented(),
		"companion_ready": CompanionReportsPushReady(),
		"vapid_key_configured": VapidKeyConfigured(),
		"browser_can_subscribe": BrowserCanSubscribe(),
		"server_persists": ServerPersistsSubscriptionsObserved(),
		"client_submit_wired": ClientSubmitWired(),
	}

# A CONJUNÇÃO. Cada conjunção tem nome, asserção própria e valor medido nesta
# máquina (ver `DeliverParts()`); `CanDeliver()` não tem opinião própria — é a E
# das peças, e é assim que o toggle de Settings continua sem prometer notificação
# que não chega enquanto faltar qualquer uma delas. A implicação que nunca pode
# ser violada é esta: se o sender não existe como código, entregar é impossível —
# `SenderImplemented()` é condição, não sinônimo. Confundir as duas coisas foi o
# erro que abriu o toggle numa deploy sem chave VAPID.
static func CanDeliver() -> bool:
	var parts : Dictionary = DeliverParts()
	return bool(parts["sender_implemented"]) and bool(parts["companion_ready"]) \
		and bool(parts["vapid_key_configured"]) and bool(parts["browser_can_subscribe"]) \
		and bool(parts["server_persists"]) and bool(parts["client_submit_wired"])

# O que o jogador pode ganhar HOJE com o estado observado — mesma resposta do
# gate, por definição, para que Settings e o contrato nunca divirjam.
static func CanOfferToPlayer() -> bool:
	return CanDeliver()

# Rótulo do último motivo fino observado por qualquer sonda (diagnóstico de
# console, nunca conteúdo de notificação nem segredo).
static func LastReason() -> String:
	return _lastReason

# Campos mínimos de uma subscription — os mesmos quatro que a CLI
# `--push-register` exige e que a migration 052 declara NOT NULL. `account_id`
# está aqui para a VALIDAÇÃO de um registro completo; a escrita nunca usa o
# `account_id` do client (ver `WebPushSubscription`).
static func SubscriptionFields() -> PackedStringArray:
	return PackedStringArray(["account_id", "endpoint", "p256dh", "auth"])

static func SubscriptionComplete(data : Dictionary) -> bool:
	for field in SubscriptionFields():
		if not data.has(field):
			return false
		if str(data.get(field, "")).strip_edges() == "":
			return false
	return true
