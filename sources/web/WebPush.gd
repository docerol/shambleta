extends Node
# SOM-IDLE parser: class_name WebPush escondia o autoload homônimo (erro de
# parse no Godot estrito) — a API estática vive em WebPushService; o autoload
# `WebPush` (nó) continua existindo para a cena/service worker.
class_name WebPushService

# SOM-IDLE F3: web push notification support for browser builds.
# Uses the browser's Notification API and a service worker for push events.
# Requires HTTPS (or localhost) and user permission.
#
# AUDITORIA_INDEPENDENTE W5. Os guards `Engine.has_singleton("Conf")` /
# `("LauncherCommons")` que abriam todas as funções abaixo nunca foram
# verdadeiros: `Conf` e `LauncherCommons` são `class_name` (ServiceBase /
# RefCounted), não autoload — os autoloads do projeto são Launcher, Network,
# FSM, Monitoring, WebPush e PwaUpdate. `Engine.has_singleton` devolvia false em 100% dos
# builds e cada função saía pelo ramo nulo: o toggle de Settings não gravava
# nada, `Initialize` não registrava o service worker e `Show` nunca entregava.
# Chamada estática direta é o que o resto do código já usa (Settings.gd lê
# `LauncherCommons.isWeb` e `Conf.Type.USERSETTINGS` direto) e funciona também
# sob `godot -s`, que era o pretexto do guard. Mesmo defeito de FSM.gd:41.
#
# Os tipos literais `0` que existiam nestas chamadas também estavam errados:
# `Conf.Type` é { NONE = -1, SETTINGS = 0, USERSETTINGS = 1 }, ou seja o `0`
# apontava para o settings.cfg embarcado (o override do jogador nunca era
# escrito e um SaveType gravaria por cima do arquivo do pacote).

static var _permission : String = "default"
static var _enabled : bool = false

# Estado do FLUXO do toggle (`EnablePush`/`DisablePush`), separado do estado da
# preferência. `pushManager.subscribe()` e `.unsubscribe()` são Promises: a
# primeira leitura logo depois do pedido pode não ter resposta ainda (`pending`),
# e sem memória o jogador ligava o push sem assinatura nenhuma e desligava sem
# avisar o servidor — as duas metades do "push não entrega". `_owedJob` é essa
# memória e `RetryOwedJob()` o ponto único que a quita (pela abertura do painel,
# em `Initialize`, e pelo harness).
const OwedNone : String = ""
const OwedSubmit : String = "submit"
const OwedUnregister : String = "unregister"
const PermissionGranted : String = "granted"
const MaxOwedTries : int = 3
static var _owedJob : String = OwedNone
static var _owedTries : int = 0

# A ponte com o navegador, por UMA porta. `JavaScriptBridge.get_interface` devolve
# `null` sob `godot -s`, e o caminho permissão → subscription → entrega só existe
# num browser. Sem esta porta a prova de "nada é enviado sem permissão" teria de
# ser um grep (grep não executa) ou um browser (ninguém abre um por gate).
# `SetBridgeOverrideForHarness` instala um objeto com os MESMOS nomes da ponte
# (`request_permission`, `get_permission`, `subscribe`, `get_subscription`,
# `unsubscribe`) e o corpo abaixo roda palavra por palavra, com o nó `Network`
# gravando o que saiu. Em produção o override é `null` e nenhum ramo muda.
static var _bridgeOverride : Object = null

static func SetBridgeOverrideForHarness(bridge : Object) -> void:
	_bridgeOverride = bridge

static func _Bridge():
	if _bridgeOverride != null:
		return _bridgeOverride
	return JavaScriptBridge.get_interface("ShambletaPush")

# Capacidade real de entrega — é o que a linha de Settings consulta.
# Não há veredito aqui: `WebPushDelivery.CanDeliver()` é a fonte única, e ela é a
# CONJUNÇÃO das peças do caminho (o CÓDIGO do sender no companion, a prontidão
# observada desse companion, a chave VAPID que veio junto, o navegador capaz de
# assinar, o servidor que persiste a subscription e o RPC que a entrega). Cada
# peça tem função própria, asserção própria e valor medido no harness
# (`tests/web_delivery_test.gd`), então no dia em que uma nascer só aquela
# asserção muda — e o gate abre sozinho.
#
# É por isso que esta função delega `CanDeliver()` e NÃO `SenderImplemented()`:
# o sender existir é fato permanente (o assinador ES256 de stdlib pura está
# escrito e a imagem do companion embarca as quatro camadas), e usar esse fato
# como porta de oferta ligaria o toggle e registraria o service worker de TODO
# jogador numa deploy sem chave VAPID — onde o companion levanta
# `NotImplementedError` e cada notificação morre em `vapid_sender_unimplemented`.
# Promessa vazia na outra direção é tão mentira quanto o `return false` antigo.
#
# O que ainda segura o toggle (medido nesta máquina em 2026-09-27): a peça 4 —
# `BrowserCanSubscribe()` depende do service worker registrado num browser de
# verdade, e nenhum harness headless registra worker. A peça 6 landou no mesmo
# dia: os dois RPCs estão em `sources/network/Network.gd:543,549` (wrappers no
# canal CONNECT) e `sources/network/server/Server.gd:1111,1118` (handlers com a
# conta vinda de `Peers.GetAccount`, nunca do payload — o detalhe completo está no
# cabeçalho de `sources/web/WebPushSubscription.gd`), e
# `tests/web_delivery_test.gd` não acredita no comentário: executa a sonda contra
# o autoload `Network` do processo. As peças 2 e 3 tinham um terceiro motivo,
# que não era falta de código e sim de caminho: `GET /push/vapid` não chegava a um
# browser porque a origem da página não proxyava a rota. Desde
# `deploy/web/nginx.conf` (`location = /push/vapid`) a pergunta tem por onde ser
# respondida — é o `ProbeCompanionPushReady()` abaixo que a faz.
# Notificação local não cobre o caso de uso: com a aba em background o navegador
# pausa o requestAnimationFrame e o main loop do export web para de rodar
# (godotengine/godot#37031) — o jogo não percebe o evento que teria de avisar.
# Enquanto faltar peça, mostrar o controle é prometer "avise-me quando voltar"
# sem poder cumprir; W5 é P3 na tabela do audit e cai depois do beta.
static func CanDeliver() -> bool:
	return WebPushDelivery.CanDeliver()

# --------------------------------------------------------------------------
# OFERECER != ENTREGAR AGORA (o deadlock da linha de Settings)
# --------------------------------------------------------------------------
# `CanDeliver()` responde pelo que sai HOJE, e uma das peças dela — o navegador
# assinando (`BrowserCanSubscribe`) — só nasce quando o jogador liga o toggle.
# Perguntar a `CanDeliver()` se a linha do toggle deve aparecer é, portanto,
# pedir a permissão de existir para o objeto que cria a permissão: num client
# novo a linha nunca aparece e o achado "push não entrega" fica fechado por
# construção. A pergunta certa para DESENHAR CONTROLE é outra: "o que falta é
# coisa que o jogador cria ao ligar, ou coisa que o deploy não tem?".
#
# Durso (nunca oferecemos): a chave VAPID observada, o servidor que persiste a
# subscription e o RPC que a entrega — sem qualquer um dos três ligar o toggle
# não produz linha nenhuma no banco, que é exatamente a promessa vazia que o
# gate existe para impedir. Macio: `not_web`/`no_bridge`/`not_subscribed_yet`
# (o navegador — é o que o toggle cria) e `companion_not_probed` (a pergunta sai
# sozinha na abertura do painel, em `Initialize`). Um companion já perguntado que
# disse "não estou pronto" volta a ser durso: oferecer ali seria prometer entrega
# que o próprio deploy confessou não fazer. Não é `CanOfferToPlayer()`: essa
# função é, e continua sendo, a igualdade com `CanDeliver()`
# (`sources/web/WebPushDelivery.gd:307`, asserrada em
# `tests/web_delivery_test.gd:736`) — dois sentidos no mesmo nome seria uma das
# duas mentir.
const OfferSoftBlockers : Array[String] = ["not_web", "no_bridge", "not_subscribed_yet", "companion_not_probed"]

# O que falta para entregar, por nome. Lista, não bool: o motivo cru é o que o
# console do operador lê quando a linha aparece e a notificação não chega.
static func OfferBlockers() -> PackedStringArray:
	var missing : PackedStringArray = PackedStringArray()
	if not WebPushDelivery.SenderImplemented():
		missing.append("sender_not_implemented")
	if not WebPushDelivery.VapidKeyConfigured():
		missing.append("vapid_key_not_observed")
	if not ServerPersistsSubscriptionsReachable():
		missing.append("server_does_not_persist")
	if not WebPushDelivery.ClientSubmitWired():
		missing.append("client_submit_not_wired")
	if not WebPushDelivery.CompanionReportsPushReady():
		missing.append(WebPushDelivery.ReasonNotProbed
			if WebPushDelivery.CompanionReadyReason() == WebPushDelivery.ReasonNotProbed
			else "companion_not_ready")
	if not WebPushDelivery.BrowserCanSubscribe():
		var why : String = str(WebPushDelivery.LastReason())
		missing.append(why if why == "not_web" or why == "no_bridge" else "not_subscribed_yet")
	return missing

static func CanOfferToggle() -> bool:
	for blocker in OfferBlockers():
		if not OfferSoftBlockers.has(blocker):
			return false
	return true

# Peça 5 lida de onde ela está. No processo que ESCREVE (dedicated server, dev com
# client+server) é a coluna do SQLite local, como sempre foi. Num client web não há
# SQLite nenhum — `Launcher.SQL` só nasce no ramo `--server` (`sources/launcher/Launcher.gd`)
# — e quem persiste a linha é o servidor da sessão. A evidência honesta lida DAQUI
# é, então, a sessão autenticada de pé mais o RPC do outro lado (`ClientSubmitWired`,
# cujo handler par está asserrado corpo a corpo em `tests/web_delivery_test.gd:433-436`
# — `Peers.GetAccount(peerID)`, nunca o `account_id` do payload). Sem as duas
# qualquer coisa oferecida aqui seria subscription que ninguém guarda.
static func ServerPersistsSubscriptionsReachable() -> bool:
	if WebPushDelivery.ServerPersistsSubscriptionsObserved():
		return true
	return SessionConnected() and WebPushDelivery.ClientSubmitWired()

static func SessionConnected() -> bool:
	var net : Node = _SessionNetwork()
	if net == null:
		return false
	var flag : Variant = net.get("clientConnected")
	return flag != null and bool(flag)

static func _SessionNetwork() -> Node:
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Network"))

# --------------------------------------------------------------------------
# a pergunta de prontidão (peça 2 do contrato)
# --------------------------------------------------------------------------

# Onde a pergunta é feita: `<base do companion>/push/vapid`, a mesma rota que o
# sender usa para confessar o próprio estado (`companion/push_vapid.py:push_ready()`
# → `{ready, public_key|reason}`). A base é `NetworkCommons.CompanionURL` — env >
# conf > origem da página — e NÃO uma constante daqui. Em browser a origem da
# página é o nginx, que proxya exatamente este caminho (`location = /push/vapid`,
# GET-only): a fila (`POST /push/test`) continua fora do proxy de propósito, e é
# por isso que a rota é exata e não um prefixo `/push`.

static func CompanionPushStatusURL() -> String:
	var base : String = str(NetworkCommons.CompanionURL).strip_edges().trim_suffix("/")
	if base.is_empty():
		return ""
	return base + "/push/vapid"

# Parse da resposta, SEPARADO do transporte de propósito: é o trecho que o
# harness executa headless, com o corpo exato que a rota devolve hoje — e o
# caminho por onde um relay de servidor entrega a mesma resposta ao client.
# Nada aqui acredita no que não tem forma: corpo ruim, `ready: true` sem pública
# ou HTTP de erro são todos "não pronto", nunca "assume pronto". Uma resposta que
# diz pronto sem chave é recusada porque a pública é o `applicationServerKey` do
# `pushManager.subscribe()`: sem ela o readiness não tem como virar subscription.
static func ObserveCompanionPushResponse(body : String) -> Dictionary:
	var parsed : Variant = JSON.parse_string(body.strip_edges())
	if typeof(parsed) != TYPE_DICTIONARY:
		WebPushDelivery.ObserveCompanionPushReady(false, "", "bad_response")
		return {"ok": false, "ready": false, "reason": "bad_response"}
	var data : Dictionary = parsed
	var ready : bool = bool(data.get("ready", false))
	var publicKey : String = str(data.get("public_key", "")).strip_edges()
	var reason : String = str(data.get("reason", "")).strip_edges()
	if ready and publicKey.length() != WebPushDelivery.PublicKeyLength:
		WebPushDelivery.ObserveCompanionPushReady(false, "", "ready_without_public_key")
		return {"ok": false, "ready": false, "reason": "ready_without_public_key"}
	var why : String = reason if not reason.is_empty() else ("companion_ready" if ready else "companion_not_ready")
	WebPushDelivery.ObserveCompanionPushReady(ready, publicKey, why)
	return {"ok": true, "ready": ready, "reason": why}

# Encaminha a pergunta. `HTTPRequest` é assíncrono e precisa de um nó na árvore
# (o `request_completed` só é processado pelo SceneTree), então isto devolve
# `false` sem tocar no estado observado quando não há árvore: um harness `-s`
# nunca finge que sondou. Um nó por vez — re-entrar sem resposta não multiplica
# pedido. O retorno é "a pergunta foi feita", não "push está pronto".
static func ProbeCompanionPushReady() -> bool:
	var url : String = CompanionPushStatusURL()
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if url.is_empty() or tree == null or tree.root == null:
		return false
	if tree.root.get_node_or_null(NodePath("WebPushReadinessProbe")) != null:
		return false
	var http : HTTPRequest = HTTPRequest.new()
	http.name = "WebPushReadinessProbe"
	http.timeout = 8.0
	tree.root.add_child(http)
	http.request_completed.connect(WebPushService.ProbeCompleted.bind(http))
	if int(http.request(url, PackedStringArray(["Accept: application/json"]),
			HTTPClient.METHOD_GET, "")) != OK:
		http.queue_free()
		return false
	return true

# O único lugar onde a resposta vira estado. Depois de um "pronto" verdadeiro, o
# worker passa a poder ser registrado — é aqui, não no boot, que a peça 4 do
# navegador nasce; `register_sw` com o mesmo script+escopo é idempotente pela
# própria especificação, então re-entrar não duplica registration.
static func ProbeCompleted(result : int, responseCode : int, _headers : PackedStringArray,
		body : PackedByteArray, http : HTTPRequest) -> void:
	if http != null:
		http.queue_free()
	if result != int(HTTPRequest.RESULT_SUCCESS) or responseCode != 200:
		WebPushDelivery.ObserveCompanionPushReady(false, "", "http_%d" % responseCode)
		return
	ObserveCompanionPushResponse(body.get_string_from_utf8())
	if WebPushDelivery.CanDeliver():
		_register_service_worker()

static func Initialize():
	if not LauncherCommons.isWeb:
		return
	# A pergunta sai ANTES de qualquer leitura de estado: `CanDeliver()` vai
	# responder com o que foi observado até aqui, e a resposta chega no próximo
	# tick (a linha de Settings é reconstruída a cada abertura do painel).
	ProbeCompanionPushReady()
	_enabled = Conf.GetBool("web", "push_enabled", Conf.Type.USERSETTINGS)
	_permission = _BrowserPermission()
	_register_service_worker()
	# `subscribe`/`unsubscribe` do navegador são Promises: o que ficou devendo na
	# última abertura do painel é quitado aqui, antes de qualquer controle reler o
	# estado — é este o "quadro seguinte" que `Subscribe()` sempre prometeu no
	# comentário acima e ninguém cobrava.
	RetryOwedJob()

static func _register_service_worker():
	# `js.has_method("register_sw")` não é checagem de existência: Godot encaminha o
	# nome para o lado JS, `ShambletaPush.has_method` não existe, e cada boot
	# despejava um `TypeError: obj[method] is not a function` no console do
	# navegador (medido em 2026-09-25). O guard real é CanDeliver().
	#
	# O escopo do registro é `/sw/`, e isso é decisão, não descuido: o worker do
	# engine (`index.service.worker.js`) já está registrado em `/` — é ele o dono do
	# cache offline dos assets (.pck/.wasm). Um `register('/sw.js', {scope:'/'})`
	# SUBSTITUIRIA aquele registro (um worker por escopo) e o primeiro load do
	# jogador voltaria a baixar o pacote inteiro. Registrado em escopo estreito,
	# `/sw.js` é um SEGUNDO worker que não controla página nenhuma e só existe para
	# receber `push`: subscription é por registration, não por escopo, então a
	# entrega funciona igual. O COOP/COEP do build vem do nginx
	# (deploy/web/nginx.conf:72-79), não do worker, e é por isso que o escopo
	# estreito não custa os threads.
	if not CanDeliver():
		return
	var js = _Bridge()
	if not js:
		return
	js.register_sw("/sw.js", "/sw/")

# Cria a subscription do navegador e devolve os campos que o servidor de jogo
# precisa. A `applicationServerKey` vem de `WebPushDelivery.VapidPublicKey()` — o
# valor que este processo OBSERVOU (`ObserveVapidPublicKey`), nunca uma chave
# escrita neste repositório: assinar com a pública errada cria subscription que
# nenhum sender do companion consegue usar, e o erro volta meses depois como 403
# mudo do provedor.
#
# A bridge é o mesmo padrão de `RequestPermission`/`_BrowserPermission`:
# `subscribe()` é uma Promise, então o resultado NÃO está no tick da chamada — a
# ponte guarda o estado e o Godot lê `get_subscription()`. Um `Subscribe()` pode
# devolver `pending`; quem chama relê no quadro seguinte (`PollSubscription`).
static func Subscribe() -> Dictionary:
	if not IsSupported():
		return {"ok": false, "reason": "not_web"}
	if not WebPushDelivery.VapidKeyConfigured():
		return {"ok": false, "reason": "vapid_key_not_observed"}
	var js = _Bridge()
	if not js:
		return {"ok": false, "reason": "no_bridge"}
	js.subscribe(WebPushDelivery.VapidPublicKey())
	return PollSubscription()

static func PollSubscription() -> Dictionary:
	if not IsSupported():
		return {"ok": false, "reason": "not_web"}
	var js = _Bridge()
	if not js:
		return {"ok": false, "reason": "no_bridge"}
	return _ParseSubscription(str(js.get_subscription()))

static func _ParseSubscription(text : String) -> Dictionary:
	var trimmed : String = text.strip_edges()
	if trimmed == "" or trimmed == "<null>" or trimmed == "null":
		return {"ok": false, "reason": "pending"}
	var parsed : Variant = JSON.parse_string(trimmed)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "bad_bridge_json"}
	var sub : Dictionary = parsed
	if not bool(sub.get("ok", false)):
		return {"ok": false, "reason": str(sub.get("error", "browser_refused"))}
	var keys : Dictionary = sub.get("keys", {})
	return {
		"ok": true,
		"endpoint": str(sub.get("endpoint", "")),
		"p256dh": str(keys.get("p256dh", "")),
		"auth": str(keys.get("auth", "")),
	}

# Desassina o navegador (o toggle de Settings em Off tem de chegar aqui, senão o
# jogador continua sendo notificado depois de dizer não) e pede a remoção da
# linha no servidor.
static func Unsubscribe() -> Dictionary:
	if not IsSupported():
		return {"ok": false, "reason": "not_web"}
	var js = _Bridge()
	if not js:
		return {"ok": false, "reason": "no_bridge"}
	js.unsubscribe()
	var raw : Variant = JSON.parse_string(str(js.get_subscription()))
	var gone : bool = typeof(raw) == TYPE_DICTIONARY and bool((raw as Dictionary).get("unsubscribed", false))
	if gone:
		WebPushSubscription.SubmitUnregisterToServer()
	# Confirmado ou ainda em voo: é aqui que a diferença vira memória, e não no
	# chamador — `Unsubscribe()` é o único ponto que lê a resposta do navegador.
	_SetOwed(OwedNone if gone else OwedUnregister)
	return {"ok": gone, "reason": "unsubscribed" if gone else "pending"}

# Entrega a subscription criada pelo navegador ao servidor de jogo — é lá que a
# linha `push_subscription` nasce, com a conta da SESSÃO (nunca a que o client
# mandar: ver o cabeçalho de `WebPushSubscription.gd`). O RPC landed em
# `Network.gd:543` em 2026-09-27, então hoje isto devolve `submitted`; os motivos
# `no_network_node`/`rpc_not_landed` continuam sendo o que a sonda responde se a
# fiação apodrecer — e é uma sonda de `has_method` no nó real, não opinião.
static func SubmitSubscription() -> Dictionary:
	var sub : Dictionary = PollSubscription()
	if not bool(sub.get("ok", false)):
		return sub
	return WebPushSubscription.SubmitToServer(str(sub["endpoint"]), str(sub["p256dh"]), str(sub["auth"]))

# --------------------------------------------------------------------------
# o fluxo do toggle — o que Settings chama quando o jogador mexe no Web-Push
# --------------------------------------------------------------------------
# Ordem que não pode ser trocada: PERMISSÃO → subscription do navegador → entrega
# ao servidor. Recusar antes do passo 1 é o que faz "nada é enviado sem permissão"
# um fato executado (e asserrado por `tests/webpush_subscription_test.gd`), não uma
# esperança sobre o comportamento do navegador. Cada passo devolve o motivo pelo
# próprio nome: `permission_not_granted`, `no_bridge`, `not_web`,
# `vapid_key_not_observed`, `pending`, `no_network_node`, `rpc_not_landed`,
# `not_submitted` — nenhum deles chega à tela do jogador (motivo de console/log,
# nunca toast: ver o census de `tests/reason_toast_test.gd`), e nenhum deles faz a
# linha do servidor nascer pela metade.
static func EnablePush() -> Dictionary:
	var permission : String = RequestPermission()
	if permission != PermissionGranted:
		# Passo zero: nada foi assinado, nada sai para o servidor. Só a preferência
		# volta a "off" — sem chamar `Unsubscribe()`, que diria ao servidor que
		# desassinou uma subscription que nunca chegou a existir.
		_SetOwed(OwedNone)
		_enabled = false
		_Save()
		return {"ok": false, "submitted": false, "reason": "permission_not_granted",
			"permission": permission}
	var sub : Dictionary = Subscribe()
	if not bool(sub.get("ok", false)):
		var why : String = str(sub.get("reason", "browser_refused"))
		# `pending` é a Promise do navegador ainda resolvendo: a subscription pode
		# chegar na próxima leitura, e só então sai. Qualquer outro motivo é fim de
		# linha — sem assinatura não há o que entregar ao servidor.
		_SetOwed(OwedSubmit if why == "pending" else OwedNone)
		return {"ok": false, "submitted": false, "reason": why, "permission": permission}
	var sent : Dictionary = SubmitSubscription()
	var sentWhy : String = str(sent.get("reason", "not_submitted"))
	_SetOwed(OwedSubmit if sentWhy == "pending" else OwedNone)
	return {"ok": bool(sent.get("ok", false)), "submitted": bool(sent.get("ok", false)),
		"reason": sentWhy, "permission": permission}

# Par do "Off". `SetEnabled(false)` já era o par (grava a preferência e desassina);
# o que ele não fazia era REPORTAR — e sem relatório o jogador podia dizer não com
# a linha ainda no servidor, onde o sweep continua empurrando notificação em quem
# recusou. `_owedJob` é escrito por `Unsubscribe()`, então é por ele que DisablePush
# sabe se o navegador confirmou ou se a Promise ainda está em voo.
static func DisablePush() -> Dictionary:
	# "Off" mandado embora qualquer dívida anterior: um `submit` pendente de uma
	# tentativa passada não pode virar notificação depois do "não".
	_SetOwed(OwedNone)
	SetEnabled(false)
	if not IsSupported():
		return {"ok": true, "submitted": false, "reason": "off"}
	if _owedJob == OwedUnregister:
		return RetryOwedJob()
	# Dívida zerada não é ainda "desassinado": `Unsubscribe()` sai por `no_bridge`
	# sem tocar em `_owedJob`, e dizer `unsubscribed` aí seria o mesmo tipo de
	# mentira que este par inteiro existe para fechar.
	if _Bridge() == null:
		return {"ok": false, "submitted": false, "reason": "no_bridge"}
	return {"ok": true, "submitted": false, "reason": "unsubscribed"}

# Quita o que ficou devendo entre o pedido à ponte e a leitura da resposta. Chamado
# pela abertura do painel (`Initialize`) e por quem quer forçar a segunda leitura.
# Teto de tentativas: um navegador que nunca responde não pode fazer este processo
# re-chamar `subscribe()`/`unsubscribe()` para sempre a cada painel aberto.
static func RetryOwedJob() -> Dictionary:
	if _owedJob == OwedNone:
		return {"ok": true, "submitted": false, "reason": "nothing_owed"}
	if _owedTries >= MaxOwedTries:
		_SetOwed(OwedNone)
		return {"ok": false, "submitted": false, "reason": "owed_giveup"}
	_owedTries += 1
	if _owedJob == OwedSubmit:
		var sent : Dictionary = SubmitSubscription()
		if str(sent.get("reason", "")) != "pending":
			_SetOwed(OwedNone)
		return {"ok": bool(sent.get("ok", false)), "submitted": bool(sent.get("ok", false)),
			"reason": str(sent.get("reason", "not_submitted"))}
	var off : Dictionary = Unsubscribe()
	if str(off.get("reason", "")) != "pending":
		_SetOwed(OwedNone)
	return off

# Um trabalho devendo, zero tentativas gastas: as duas coisas mudam juntas, senão o
# teto de tentativas envelhece no trabalho antigo e o novo morre no primeiro read.
static func _SetOwed(job : String) -> void:
	if _owedJob != job:
		_owedTries = 0
	_owedJob = job

static func OwedJob() -> String:
	return _owedJob

# O resultado de `Notification.requestPermission()` só existe no callback da
# Promise — a bridge antiga devolvia a Promise para um `var result : String`,
# que nunca casaria com "granted". `Notification.permission` é um getter
# síncrono: dispara o prompt e lê o estado real por ele.
static func RequestPermission() -> String:
	if not IsSupported():
		return "unsupported"
	var js = _Bridge()
	if not js:
		return "unsupported"
	js.request_permission()
	_permission = str(js.get_permission())
	if _permission == PermissionGranted:
		_enabled = true
		_Save()
	elif _permission == "denied":
		_enabled = false
		_Save()
	return _permission

static func _BrowserPermission() -> String:
	if not IsSupported():
		return _permission
	var js = _Bridge()
	if not js:
		return _permission
	return str(js.get_permission())

static func GetPermission() -> String:
	return _permission

static func IsEnabled() -> bool:
	return _enabled and _permission == "granted"

static func IsSupported() -> bool:
	return LauncherCommons.isWeb

static func Show(title : String, body : String, icon : String = ""):
	if not IsEnabled():
		return
	var js = _Bridge()
	if not js:
		return
	js.show_notification(title, body, icon)

static func SetEnabled(enabled : bool):
	_enabled = enabled
	_Save()
	# "Off" sem desassinar é só uma preferência local: a subscription continua
	# viva no service worker e a linha `push_subscription` continua no servidor,
	# então o sweep do companion segue empurrando notificação para quem acabou de
	# dizer não — exatamente a superfície que promete entrega recusada. Daí este
	# par. Fora de browser `Unsubscribe()` responde `not_web` e nada acontece; o
	# pedido de remoção no servidor só sai quando o navegador confirma
	# (`SubmitUnregisterToServer`), porque confirmar antes seria dizer ao
	# servidor que desassinou enquanto o push continua ativo.
	if not enabled and IsSupported():
		Unsubscribe()

static func _Save():
	if not LauncherCommons.isWeb:
		return
	Conf.SetValue("web", "push_enabled", Conf.Type.USERSETTINGS, _enabled)
	Conf.SaveType("settings", Conf.Type.USERSETTINGS)
