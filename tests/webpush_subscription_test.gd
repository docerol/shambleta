extends SceneTree

# webpush_subscription_test.gd — harness do FLUXO do toggle de web push (achado
# do juiz de Retenção/Live-Ops: "push não entrega").
#
# `tests/web_delivery_test.gd` mede o CAMINHO: as seis peças da conjunção, o
# sender ES256, a fila do companion, a ponte `ShambletaPush` do template. Este
# arquivo mede o GESTO: o que acontece quando o jogador mexe na linha de
# `sources/gui/Settings.gd`, executando o corpo real de `WebPush`.
#
# Quatro famílias de régua:
#  1. FONTE (grep do código, nunca do comentário): `set_webpush` é o gesto que
#     chama o fluxo; `item_selected` mapeia ÍNDICE para bool antes de entrar numa
#     `func ...(enabled : bool)` (o `int` caindo direto era erro de tipo); o corpo
#     de `EnablePush()` tem permissão, subscription e entrega NA ORDEM; e a linha
#     é desenhada por `CanOfferToggle()`, não por `CanDeliver()`.
#  2. EXECUÇÃO do "On": com a ponte de mentira e um nó `Network` de mentira, o
#     corpo de `WebPush` roda palavra por palavra. Permissão concedida =>
#     `subscribe()` com a pública OBSERVADA => os três campos chegam ao servidor
#     exatamente uma vez. Permissão NÃO concedida (prompt fechado ou negado) =>
#     zero chamadas ao `Network` e o navegador nem é questionado. É aqui que
#     "nada é enviado sem permissão" deixa de ser esperança sobre o navegador e
#     vira fato medido.
#  3. EXECUÇÃO do "Off": desassinar CONFIRMADO pelo navegador pede a remoção da
#     linha; o navegador que ainda não respondeu NÃO pode fazer o client afirmar
#     ao servidor que desassinou (linha viva + sweep notificando quem disse não é
#     o pior tipo de mentira desta superfície) — fica devendo, e a dívida é
#     quitada na leitura seguinte, com teto de tentativas.
#  4. OFERTA != ENTREGA: uma das peças de `CanDeliver()` (`BrowserCanSubscribe`)
#     só nasce quando o jogador liga o toggle, então cobrar `CanDeliver()` para
#     desenhar a linha é o deadlock que mantinha o achado aberto por construção.
#     Aqui `CanOfferToggle()` abre com o que o gesto cria, e continua fechado com
#     o que o deploy não tem — enquanto `CanDeliver()` permanece false.
#
# NADA DISCADO: o `Network` de produto é escondido (renomeado, como em
# `tests/web_delivery_test.gd:452` — realocar o nó dispararia `_exit_tree` do
# caminho de rede por causa de um teste) e entra um gravador no lugar; a sonda de
# prontidão é medida pelo guard de re-entrância, nunca por um HTTP real.
# `Initialize()` não é chamado aqui (ele sonda por si e escreve em `Conf`): o que
# se mede são as funções do fluxo, uma a uma, com estado restaurado na saída — um
# harness que deixa chave VAPID "observada" para o próximo run é o segundo jeito
# de fingir.
#
# Uso:
#   XDG_DATA_HOME=/tmp/webpushsub/data XDG_CACHE_HOME=/tmp/webpushsub/cache \
#     timeout 300 godot --headless --path . -s tests/webpush_subscription_test.gd
# Saída: "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# Como os harnesses irmãos, este arquivo é duck-typed: um main-loop `-s` compila
# antes dos autoloads e dos `class_name` existirem, então `WebPushService`,
# `WebPushDelivery`, `WebPushSubscription` e `LauncherCommons` entram por
# `load()` e tudo que vem deles é chamado por `call()`.

const FakeEndpoint : String = "https://push.example.invalid/s/webpush-subscription-harness"
const FakeP256dh : String = "BFkU214PYUHq21IuLfahO-BkbVL3rtVMXrCPMNjBS_jzDZtPNeAvNYQHGdmCb"
const FakeAuth : String = "8_kWq9VJ0OZUuBIz1zLvVQ"
# O corpo que a ponte `ShambletaPush` devolve hoje (`getSubscription`): `ok`,
# `endpoint` e `keys{p256dh,auth}`. Montado como JSON de propósito: quem é testado
# é o parse do produto, não uma convenção deste harness.
const SubscribedReply : String = "{\"ok\": true, \"endpoint\": \"" + FakeEndpoint \
	+ "\", \"keys\": {\"p256dh\": \"" + FakeP256dh + "\", \"auth\": \"" + FakeAuth + "\"}}"
const UnsubscribedReply : String = "{\"unsubscribed\": true}"
const PendingReply : String = ""

var checks : int = 0
var failures : int = 0

var _wps : GDScript = null
var _wpd : GDScript = null
var _wsub : GDScript = null
var _lc : GDScript = null
var _realNetwork : Node = null
var _recorder : RecordingNetwork = null
var _bridge : FakeBridge = null

# ------------------------------------------------------------------ pontes de
# mentira. Mesmos nomes da ponte real, com um registro de sequência por gesto: é
# o que permite afirmar a ORDEM (permissão antes de subscription) e CONTAR o que
# saiu (zero envios sem permissão), sem browser e sem disco.
class FakeBridge extends RefCounted:
	var calls : Array[String] = []
	var permission : String = "default"
	var subscribeReply : String = ""
	var unsubscribeReply : String = ""
	var subscribeKeys : Array[String] = []
	var swScripts : Array[String] = []
	var swScopes : Array[String] = []
	var _reply : String = ""

	func request_permission() -> void:
		calls.append("request_permission")

	func get_permission() -> String:
		calls.append("get_permission")
		return permission

	func subscribe(applicationServerKey : String) -> void:
		calls.append("subscribe")
		subscribeKeys.append(applicationServerKey)
		_reply = subscribeReply

	func get_subscription() -> String:
		calls.append("get_subscription")
		return _reply

	# Simula a Promise do navegador resolvendo ENTRE duas leituras. O produto só
	# conhece `get_subscription()`, então é por aqui que o "quadro seguinte" chega —
	# mudar `subscribeReply` depois do `subscribe()` não faria nada, e a régua de
	# dívida (submit pendente → quitado na leitura seguinte) passaria a medir o
	# estado errado da ponte.
	func resolve(reply : String) -> void:
		_reply = reply

	func unsubscribe() -> void:
		calls.append("unsubscribe")
		_reply = unsubscribeReply

	func register_sw(script : String, scope : String) -> void:
		calls.append("register_sw")
		swScripts.append(script)
		swScopes.append(scope)

# Nó de produto fingido. Três leitores dependem dele:
# `WebPushSubscription._NetworkNode()` (olha o caminho "Network"),
# `WebPushDelivery.ClientSubmitWired()` (pergunta `has_method`) e
# `WebPush.SessionConnected()` (lê a propriedade `clientConnected`). Um nó só
# registra — nenhum pedido de rede sai daqui.
class RecordingNetwork extends Node:
	var clientConnected : bool = true
	var registerCalls : Array[Dictionary] = []
	var unregisterCalls : int = 0

	func RegisterPushSubscription(endpoint : String, p256dh : String, auth : String,
			_peerID : int = -1) -> void:
		registerCalls.append({"endpoint": endpoint, "p256dh": p256dh, "auth": auth})

	func UnregisterPushSubscription(_peerID : int = -1) -> void:
		unregisterCalls += 1

# ------------------------------------------------------------------ contagem

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
		return false
	print("  [ok] " + label)
	return true

func _checkInt(value : int, expected : int, label : String) -> bool:
	return _check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _checkSame(value : String, expected : String, label : String) -> bool:
	return _check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fontes

func _repoFile(path : String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

# Só código, sem linhas de comentário: uma régua que lê o arquivo inteiro dá
# verde quando a chamada é apagada e a frase sobrevive na doc de quem a descreveu
# (mesma razão de `_StripCommentLines` em `tests/IdleTests.gd:6124-6139`).
func _codeOnly(text : String) -> String:
	var kept : String = ""
	for rawLine in text.split("\n"):
		var line : String = String(rawLine)
		if line.strip_edges().begins_with("#"):
			continue
		kept += line + "\n"
	return kept

# Corpo de uma função: da assinatura até o próximo membro de topo. `_bodyOf` de
# `tests/web_delivery_test.gd:387` corta só em `\nfunc `, que não existe num
# arquivo 100% estático — leria o arquivo inteiro, e a régua de ORDEM passaria
# sozinha porque os quatro passos estariam todos lá dentro de outro corpo.
func _funcBody(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var out : String = ""
	var first : bool = true
	for rawLine in src.substr(at).split("\n", false):
		var line : String = String(rawLine)
		if not first:
			if line.begins_with("func ") or line.begins_with("static func ") \
					or line.begins_with("class ") or line.begins_with("static var ") \
					or line.begins_with("const "):
				break
		out += line + "\n"
		first = false
	return out

func _const(script : GDScript, name : String) -> Variant:
	return script.get_script_constant_map().get(name, null)

func _publicKey() -> String:
	return "BD" + "a".repeat(85)

# ------------------------------------------------------------------ costura

func _installRecorder() -> void:
	if _recorder != null:
		return
	_realNetwork = root.get_node_or_null(NodePath("Network"))
	if _realNetwork != null:
		_realNetwork.name = "NetworkHiddenByHarness"
	_recorder = RecordingNetwork.new()
	_recorder.name = "Network"
	root.add_child(_recorder)

# Libera o gravador e devolve o nome ao nó de produto. `_realNetwork` continua
# valendo: é com ele que a suíte final confere que a árvore voltou ao original.
func _removeRecorder() -> void:
	if _recorder != null:
		root.remove_child(_recorder)
		_recorder.free()
		_recorder = null
	if _realNetwork != null:
		_realNetwork.name = "Network"

func _resetRecorder() -> void:
	_recorder.registerCalls.clear()
	_recorder.unregisterCalls = 0

func _resetFlow() -> void:
	_wps.set("_owedJob", str(_const(_wps, "OwedNone")))
	_wps.set("_owedTries", 0)
	_wps.set("_permission", "default")
	_wps.set("_enabled", false)

func _owed() -> String:
	return str(_wps.call("OwedJob"))

# Estado de deploy sem chave: a prontidão volta ao "nunca perguntado" e a pública
# observada é limpa (`ObserveCompanionPushReady` com ready=false limpa as duas
# pontas — é a implicação que o contrato proíbe de divergir).
func _clearDeploy() -> void:
	_wpd.call("ObserveCompanionPushReady", false, "", str(_const(_wpd, "ReasonNotProbed")))
	_wpd.call("ObserveVapidPublicKey", "")

# ------------------------------------------------------------------ boot

func _initialize() -> void:
	_run()

func _run() -> void:
	print("-- webpush subscription: o gesto do toggle, executado ponta a ponta")
	_wps = load("res://sources/web/WebPush.gd")
	_wpd = load("res://sources/web/WebPushDelivery.gd")
	_wsub = load("res://sources/web/WebPushSubscription.gd")
	_lc = load("res://sources/launcher/LauncherCommons.gd")
	if not _check(_wps != null and _wpd != null and _wsub != null and _lc != null,
			"os quatro módulos do caminho entram por load() (harness duck-typed)"):
		_finish()
		return
	_installRecorder()
	_suiteSource()
	_suiteEnable()
	_suiteDisable()
	_suiteOffer()
	_suiteProbeSeam()
	_suiteTeardown()
	_finish()

# ------------------------------------------------------------------ 1. fonte

func _suiteSource() -> void:
	print("-- (1) fonte: Settings chama o fluxo, e o fluxo tem a ordem dos passos")
	var settings : String = _codeOnly(_repoFile("res://sources/gui/Settings.gd"))
	var webpush : String = _codeOnly(_repoFile("res://sources/web/WebPush.gd"))

	var setter : String = _funcBody(settings, "func set_webpush(enabled : bool):")
	_check(not setter.is_empty(), "Settings.gd declara set_webpush(enabled : bool)")
	_check(setter.contains("WebPushService.EnablePush()"),
			"o \"On\" chama o fluxo de subscription (EnablePush), não grava preferência")
	_check(setter.contains("WebPushService.DisablePush()"),
			"o \"Off\" chama o fluxo de desassino (DisablePush)")
	_check(not setter.contains("WebPushService.SetEnabled("),
			"set_webpush não volta a ser preferência solitária (ligar sem assinar)")

	var mapper : String = _funcBody(settings, "func _on_webpush_selected(index : int)")
	_check(mapper.contains("set_webpush(index == WebPushOnIndex)"),
			"o índice da OptionButton vira bool ANTES de entrar em set_webpush")
	_check(settings.contains("const WebPushOnIndex : int = 1"),
			"WebPushOnIndex == 1 (Off=0, On=1, pela ordem dos add_item da linha)")
	_check(settings.contains("item_selected.connect(_on_webpush_selected)"),
			"o sinal liga o mapador, não o setter tipado em bool (int para bool era erro de tipo)")
	_check(not settings.contains("item_selected.connect(set_webpush)"),
			"nenhuma volta do connect direto em set_webpush (o defeito de tipo prévio)")

	var gate : String = _funcBody(settings, "func _ready():")
	_check(gate.contains("WebPushService.CanOfferToggle()"),
			"a linha é desenhada por OFERTA (CanOfferToggle), não por entrega-agora")
	_check(not gate.contains("WebPushService.CanDeliver()"),
			"a linha não cobra CanDeliver() (deadlock: a peça faltante é criada pelo gesto)")

	var enable : String = _funcBody(webpush, "static func EnablePush() -> Dictionary:")
	_check(not enable.is_empty(), "WebPush.gd declara EnablePush()")
	var permAt : int = enable.find("RequestPermission()")
	var guardAt : int = enable.find("!= PermissionGranted")
	var subAt : int = enable.find("Subscribe()")
	var submitAt : int = enable.find("SubmitSubscription()")
	_check(permAt >= 0 and guardAt >= 0 and subAt >= 0 and submitAt >= 0,
			"EnablePush nomeia os quatro passos (permissão, guard, subscribe, submit)")
	_check(permAt < guardAt and guardAt < subAt and subAt < submitAt,
			"ordem no corpo: permissão (%d) -> recusa (%d) -> assina (%d) -> entrega (%d)"
			% [permAt, guardAt, subAt, submitAt])
	var refuseAt : int = enable.find("permission_not_granted")
	_check(refuseAt >= 0 and refuseAt < subAt,
			"a recusa por falta de permissão vem antes de qualquer subscription (%d vs %d)"
			% [refuseAt, subAt])
	_check(enable.contains("_Save()"),
			"recusado sem permissão volta a preferência para off (sem linha pela metade)")

	# As quatro réguas que `tests/web_delivery_test.gd` já cobra, repetidas porque
	# é ESTE harness o dono do fluxo que as usa: se alguém "simplificar" o caminho,
	# duas regras caem em vez de uma.
	_check(webpush.contains("js.subscribe(WebPushDelivery.VapidPublicKey())"),
			"a pública vai ao navegador pelo jogo (nunca hardcoded em WebPush)")
	_check(webpush.contains("WebPushDelivery.VapidKeyConfigured()"),
			"Subscribe() só questiona o navegador com chave observada")
	_check(webpush.contains("register_sw(\"/sw.js\", \"/sw/\")"),
			"o worker é registrado no escopo estreito /sw/ (não desloca o do engine)")
	_check(webpush.contains("static func CanDeliver() -> bool:")
			and webpush.contains("return WebPushDelivery.CanDeliver()"),
			"CanDeliver() continua delegando a conjunção (sem veredito próprio)")
	_check(not webpush.contains("func CanOfferToPlayer"),
			"CanOfferToPlayer() não ganha segundo sentido (igualdade asserrada em web_delivery:736)")
	_check(not webpush.contains("result[\"reason\"] ="),
			"nenhum motivo novo no censo de tests/reason_toast_test.gd (forma de atribuição)")
	_check(webpush.contains("if _permission == PermissionGranted:"),
			"o estado \"granted\" é lido pelo nome, não por literal solto")

# ------------------------------------------------------------------ 2. "On"

func _suiteEnable() -> void:
	print("-- (2) On: concedido assina e entrega; recusado não envia nada")
	_lc.set("isWeb", false)
	_wps.call("SetBridgeOverrideForHarness", null)
	_clearDeploy()
	_resetFlow()
	_resetRecorder()

	# O caminho de produção sem browser: recusa com motivo próprio, nada discado.
	var headless : Dictionary = _wps.call("EnablePush")
	_check(str(headless.get("reason", "")) == "permission_not_granted",
			"sem browser EnablePush recusa com permission_not_granted (%s)"
			% str(headless.get("reason", "?")))
	_checkInt(_recorder.registerCalls.size(), 0, "sem browser nada chega ao servidor")

	_lc.set("isWeb", true)
	_wpd.call("ObserveVapidPublicKey", _publicKey())

	# Prompt fechado pelo jogador (permissão continua "default"): o servidor não é
	# tocado e o navegador nem é questionado.
	_bridge = FakeBridge.new()
	_bridge.permission = "default"
	_bridge.subscribeReply = SubscribedReply
	_wps.call("SetBridgeOverrideForHarness", _bridge)
	_resetRecorder()
	var dismissed : Dictionary = _wps.call("EnablePush")
	_check(str(dismissed.get("reason", "")) == "permission_not_granted"
			and str(dismissed.get("permission", "")) == "default",
			"prompt fechado (\"default\") => permission_not_granted (%s)"
			% str(dismissed.get("reason", "?")))
	_checkInt(_recorder.registerCalls.size(), 0, "sem permissão: ZERO registros no servidor")
	_checkInt(_recorder.unregisterCalls, 0, "sem permissão: ZERO remoções no servidor")
	_check(not _bridge.calls.has("subscribe"),
			"sem permissão o navegador nem é questionado (subscribe não chamado)")
	_checkInt(_bridge.calls.find("request_permission"), 0,
			"o primeiro gesto do fluxo é pedir permissão (seq=%s)" % str(_bridge.calls))
	_checkSame(_owed(), "", "recusar não cria dívida (nada pendente atrás do \"não\")")
	_check(not bool(_wps.call("IsEnabled")), "o toggle não acende sem permissão")

	var deniedBridge : FakeBridge = FakeBridge.new()
	deniedBridge.permission = "denied"
	deniedBridge.subscribeReply = SubscribedReply
	_wps.call("SetBridgeOverrideForHarness", deniedBridge)
	var denied : Dictionary = _wps.call("EnablePush")
	_check(str(denied.get("reason", "")) == "permission_not_granted"
			and str(denied.get("permission", "")) == "denied",
			"permissão negada recusa pelo mesmo motivo nomeado (%s)" % str(denied.get("reason", "?")))
	_checkInt(deniedBridge.subscribeKeys.size(), 0, "negada também não assina nada")
	_checkInt(_recorder.registerCalls.size(), 0, "negada também não envia nada")

	# Concedida com a subscription resolvida: o material do navegador chega inteiro
	# ao RPC, exatamente uma vez.
	_bridge = FakeBridge.new()
	_bridge.permission = "granted"
	_bridge.subscribeReply = SubscribedReply
	_wps.call("SetBridgeOverrideForHarness", _bridge)
	_resetRecorder()
	var granted : Dictionary = _wps.call("EnablePush")
	_check(bool(granted.get("ok", false)) and bool(granted.get("submitted", false))
			and str(granted.get("reason", "")) == "submitted",
			"concedida => assinada => entregue (reason=%s)" % str(granted.get("reason", "?")))
	_check(_bridge.calls.find("request_permission") < _bridge.calls.find("subscribe"),
			"executado, não grep: permissão antes de subscribe (seq=%s)" % str(_bridge.calls))
	_checkInt(_bridge.subscribeKeys.size(), 1, "o navegador é questionado exatamente uma vez")
	_checkSame(str(_bridge.subscribeKeys[0]), str(_wpd.call("VapidPublicKey")),
			"a applicationServerKey é a pública OBSERVADA que o jogo devolve")
	_checkInt(_recorder.registerCalls.size(), 1, "uma linha de subscription sai para o servidor")
	var sent : Dictionary = _recorder.registerCalls[0]
	_checkSame(str(sent.get("endpoint", "")), FakeEndpoint,
			"o endpoint que chega ao servidor é o que o navegador deu")
	_checkSame(str(sent.get("p256dh", "")), FakeP256dh, "p256dh entregue intacto")
	_checkSame(str(sent.get("auth", "")), FakeAuth, "auth entregue intacto")
	_check(bool(_wps.call("IsEnabled")), "com permissão e entrega, o toggle está ligado")
	_checkSame(_owed(), "", "entrega confirmada não deixa dívida")

	# Browser SEM ponte (export cujo head_include não carregou `ShambletaPush`): a
	# permissão não é lida de lugar nenhum, então o fluxo recusa ANTES de tocar no
	# servidor. É o mesmo `no_bridge`/`unsupported` que `tests/web_delivery_test.gd`
	# cobra função a função; aqui o que se conta são as chamadas que NÃO saem.
	_wps.call("SetBridgeOverrideForHarness", null)
	_resetRecorder()
	var muteOn : Dictionary = _wps.call("EnablePush")
	_check(str(muteOn.get("reason", "")) == "permission_not_granted",
			"browser sem ponte: o \"On\" recusa com permission_not_granted (%s)"
			% str(muteOn.get("reason", "?")))
	_checkInt(_recorder.registerCalls.size(), 0, "browser sem ponte: ZERO chamadas ao servidor")
	_checkSame(_owed(), "", "browser sem ponte não deixa dívida para o próximo painel")

	# Promise ainda em voo: sem endpoint não há o que entregar, e a entrega fica
	# DEVENDO — a memória que faltava ao "ligar não assinava".
	var pendingBridge : FakeBridge = FakeBridge.new()
	pendingBridge.permission = "granted"
	pendingBridge.subscribeReply = PendingReply
	_wps.call("SetBridgeOverrideForHarness", pendingBridge)
	_resetRecorder()
	var pending : Dictionary = _wps.call("EnablePush")
	_check(str(pending.get("reason", "")) == "pending",
			"subscription em voo devolve pending, nunca um ok falso (%s)"
			% str(pending.get("reason", "?")))
	_check(not bool(pending.get("submitted", false)), "em voo nada é marcado como entregue")
	_checkInt(_recorder.registerCalls.size(), 0, "sem endpoint: ZERO chamadas ao servidor")
	_checkSame(_owed(), str(_const(_wps, "OwedSubmit")), "a entrega fica devendo (submit)")
	# A Promise resolve no quadro seguinte — é o que `Subscribe()` sempre prometeu no
	# comentário da função e ninguém cobrava.
	pendingBridge.subscribeReply = SubscribedReply
	pendingBridge.resolve(SubscribedReply)
	var retried : Dictionary = _wps.call("RetryOwedJob")
	_check(bool(retried.get("submitted", false)),
			"RetryOwedJob quita a dívida na leitura seguinte (%s)" % str(retried.get("reason", "?")))
	_checkInt(_recorder.registerCalls.size(), 1, "a dívida quitada chegou ao servidor uma vez")
	_checkSame(_owed(), "", "dívida quitada some do estado")

	_wps.call("SetBridgeOverrideForHarness", null)

# ------------------------------------------------------------------ 3. "Off"

func _suiteDisable() -> void:
	print("-- (3) Off: confirma no navegador antes de falar ao servidor, e deve quando não pode")
	_lc.set("isWeb", true)
	_wpd.call("ObserveVapidPublicKey", _publicKey())
	_resetFlow()
	var offBridge : FakeBridge = FakeBridge.new()
	offBridge.permission = "granted"
	offBridge.subscribeReply = SubscribedReply
	offBridge.unsubscribeReply = UnsubscribedReply
	_wps.call("SetBridgeOverrideForHarness", offBridge)
	var pre : Dictionary = _wps.call("EnablePush")
	_check(bool(pre.get("submitted", false)),
			"pré-condição: há subscription entregue para desassinar (%s)"
			% str(pre.get("reason", "?")))
	_resetRecorder()

	var off : Dictionary = _wps.call("DisablePush")
	_check(str(off.get("reason", "")) == "unsubscribed",
			"Off com o navegador confirmado devolve unsubscribed (%s)" % str(off.get("reason", "?")))
	_checkInt(_recorder.unregisterCalls, 1, "a linha do servidor é removida quando o navegador confirma")
	_checkInt(_recorder.registerCalls.size(), 0, "desassinar não registra subscription nova")
	_check(not bool(_wps.call("IsEnabled")), "Off desliga o toggle de verdade")
	_checkSame(_owed(), "", "Off confirmado não deixa dívida")

	# O navegador ainda não respondeu: o Off NÃO pode afirmar ao servidor que
	# desassinou. Medido por contagem, não por confiança no comentário de quem
	# escreveu a função.
	var lazyBridge : FakeBridge = FakeBridge.new()
	lazyBridge.permission = "granted"
	lazyBridge.subscribeReply = SubscribedReply
	lazyBridge.unsubscribeReply = PendingReply
	_wps.call("SetBridgeOverrideForHarness", lazyBridge)
	_resetFlow()
	_resetRecorder()
	var lazyOff : Dictionary = _wps.call("DisablePush")
	_check(str(lazyOff.get("reason", "")) == "pending",
			"Off sem resposta do navegador devolve pending (%s)" % str(lazyOff.get("reason", "?")))
	_checkInt(_recorder.unregisterCalls, 0, "Off não confirmado: ZERO remoções no servidor")
	_checkSame(_owed(), str(_const(_wps, "OwedUnregister")), "a remoção fica devendo (unregister)")
	lazyBridge.unsubscribeReply = UnsubscribedReply
	var fixed : Dictionary = _wps.call("RetryOwedJob")
	_check(str(fixed.get("reason", "")) == "unsubscribed",
			"a dívida de remoção é quitada na leitura seguinte (%s)" % str(fixed.get("reason", "?")))
	_checkInt(_recorder.unregisterCalls, 1, "quitada, a remoção chegou ao servidor uma vez")
	_checkSame(_owed(), "", "dívida de remoção quitada sai do estado")
	var nothing : Dictionary = _wps.call("RetryOwedJob")
	_check(str(nothing.get("reason", "")) == "nothing_owed",
			"sem dívida, retry não inventa trabalho (%s)" % str(nothing.get("reason", "?")))

	# Teto de tentativas: um navegador que nunca responde não pode re-perguntar
	# para sempre. O teto conta a partir do gesto do jogador (`DisablePush` já gasta
	# a primeira tentativa ao quitar a dívida na hora); o que o teto segura são as
	# re-aberturas de painel, e é por isso que o laço roda até o veredito mudar.
	var ceilingBridge : FakeBridge = FakeBridge.new()
	ceilingBridge.permission = "granted"
	ceilingBridge.subscribeReply = SubscribedReply
	ceilingBridge.unsubscribeReply = PendingReply
	_wps.call("SetBridgeOverrideForHarness", ceilingBridge)
	_resetFlow()
	_resetRecorder()
	var tries : int = int(_const(_wps, "MaxOwedTries"))
	var muted : Dictionary = _wps.call("DisablePush")
	var lastReason : String = str(muted.get("reason", ""))
	_check(lastReason == "pending" or lastReason == "unsubscribed",
			"o teto começa com o gesto respondendo pelo navegador (%s)" % lastReason)
	var extra : int = 0
	while lastReason == "pending" and extra < tries:
		var retry : Dictionary = _wps.call("RetryOwedJob")
		extra += 1
		lastReason = str(retry.get("reason", ""))
	_check(lastReason == "owed_giveup",
			"depois de %d tentativas o teto devolve owed_giveup, nunca um pending eterno (%s)"
			% [tries, lastReason])
	_checkSame(_owed(), "", "desistir limpa a dívida: nada é re-perguntado para sempre")
	# O "+1" é a leitura que o próprio gesto faz: `SetEnabled(false)` desassina e
	# `DisablePush` quita na hora, gastando a primeira tentativa antes de qualquer
	# re-abertura de painel. O que o teto segura é o resto da série.
	_checkInt(ceilingBridge.calls.count("unsubscribe"), tries + 1,
			"o teto também segura a contagem de pedidos ao navegador (got %d, want %d)"
			% [ceilingBridge.calls.count("unsubscribe"), tries + 1])
	_checkInt(_recorder.unregisterCalls, 0, "nenhuma tentativa falou ao servidor")
	var afterGiveup : Dictionary = _wps.call("RetryOwedJob")
	_check(str(afterGiveup.get("reason", "")) == "nothing_owed"
			and ceilingBridge.calls.count("unsubscribe") == tries + 1,
			"dívida abandonada não reacende: retry seguinte não inventa trabalho (%s)"
			% str(afterGiveup.get("reason", "?")))

	# Ponte ausente em browser: o Off diz no_bridge e não afirma nada ao servidor.
	_wps.call("SetBridgeOverrideForHarness", null)
	_resetFlow()
	_resetRecorder()
	var noBridgeOff : Dictionary = _wps.call("DisablePush")
	_check(str(noBridgeOff.get("reason", "")) == "no_bridge",
			"Off sem ponte devolve no_bridge em vez de \"unsubscribed\" (%s)"
			% str(noBridgeOff.get("reason", "?")))
	_checkInt(_recorder.unregisterCalls, 0, "Off sem ponte não pede remoção ao servidor")

	# Fora de browser o Off continua sendo preferência honesta, sem RPC.
	_lc.set("isWeb", false)
	_resetFlow()
	_resetRecorder()
	var desktop : Dictionary = _wps.call("DisablePush")
	_check(str(desktop.get("reason", "")) == "off",
			"fora de browser o Off devolve off sem fingir desassino (%s)"
			% str(desktop.get("reason", "?")))
	_checkInt(_recorder.unregisterCalls, 0, "fora de browser nenhum RPC de remoção sai")

# ------------------------------------------------------------------ 4. oferta

func _suiteOffer() -> void:
	print("-- (4) oferta != entrega: a linha aparece sem CanDeliver(), e só com o deploy inteiro")
	_lc.set("isWeb", false)
	_wps.call("SetBridgeOverrideForHarness", null)
	_clearDeploy()

	var bare : PackedStringArray = _wps.call("OfferBlockers")
	_check(bare.has("vapid_key_not_observed"),
			"sem pública observada a oferta fecha duro (blockers=%s)" % str(bare))
	_check(not bool(_wps.call("CanOfferToggle")),
			"deploy sem chave: a linha não aparece (ligar o toggle não criaria linha no banco)")
	_check(bare.has("not_web"),
			"o que o gesto cria é macio: not_web está na lista e não barra a oferta (%s)" % str(bare))

	# Deploy COM chave, companion nunca perguntado: o único que falta é coisa que o
	# jogador cria ao ligar (ou a pergunta que `Initialize` já faz sozinho).
	_wpd.call("ObserveVapidPublicKey", _publicKey())
	var offered : PackedStringArray = _wps.call("OfferBlockers")
	_check(bool(_wps.call("CanOfferToggle")),
			"chave observada + RPC + sessão => a linha APARECE mesmo sem entrega (blockers=%s)"
			% str(offered))
	_checkInt(offered.size(), 2, "a oferta aberta tem exatamente os dois furos macios (%s)" % str(offered))
	var soft : Array = _const(_wps, "OfferSoftBlockers")
	for blocker : String in offered:
		_check(soft.has(blocker), "todo blocker da oferta é macio por nome: %s" % blocker)
	_check(not bool(_wps.call("CanDeliver")),
			"CanDeliver() continua false: oferecer não abriu o gate de entrega")
	_check(bool(_wpd.call("CanOfferToPlayer")) == bool(_wpd.call("CanDeliver")),
			"a igualdade de CanOfferToPlayer() permanece (a outra pergunta tem outro nome)")

	# Companion já perguntado que disse "não estou pronto": volta a ser duro —
	# oferecer ali seria prometer entrega que o próprio deploy confessou não ter.
	var refused : Dictionary = _wps.call("ObserveCompanionPushResponse",
			"{\"ready\": false, \"reason\": \"no_vapid_key_in_deploy\"}")
	_check(not bool(refused.get("ready", false)),
			"a resposta \"não pronto\" é lida como não pronto (%s)" % str(refused.get("reason", "?")))
	var hard : PackedStringArray = _wps.call("OfferBlockers")
	_check(hard.has("companion_not_ready") and not bool(_wps.call("CanOfferToggle")),
			"companion confessadamente sem chave não oferece (blockers=%s)" % str(hard))

	# A pública entra pela resposta do companion: uma porta, nunca duas.
	var ready : Dictionary = _wps.call("ObserveCompanionPushResponse",
			"{\"ready\": true, \"public_key\": \"" + _publicKey() + "\"}")
	_check(bool(ready.get("ready", false)) and bool(_wpd.call("VapidKeyConfigured")),
			"resposta pronta alimenta a peça 2 e a peça 3 juntas (%s)" % str(ready.get("reason", "?")))
	_check(bool(_wps.call("CanOfferToggle")),
			"com a resposta pronta a linha volta a ser oferecida")

	# Sem o RPC no nó da sessão não há entrega: a oferta fecha duro mesmo com chave
	# observada e companion pronto. É a diferença entre "o jogador cria" e "o
	# deploy não tem".
	_recorder.name = "NetworkAwayForHarness"
	var offline : PackedStringArray = _wps.call("OfferBlockers")
	_check(offline.has("client_submit_not_wired"),
			"sem o RPC no nó, a sonda nomeia o buraco, não devolve false mudo (%s)" % str(offline))
	_check(not bool(_wps.call("CanOfferToggle")),
			"e a oferta fecha: subscription que ninguém guarda não é oferecida")
	_recorder.name = "Network"
	_check(bool(_wps.call("CanOfferToggle")),
			"o nó de volta, a oferta volta (a régua mede a árvore, não opinião)")

func _suiteProbeSeam() -> void:
	print("-- (5) prontidão: a pergunta tem forma, e nada é discado duas vezes")
	# A base é fixada aqui de propósito: com uma base vazia a função devolveria
	# false por falta de URL, e a régua de re-entrância passaria sozinha. É o NOME
	# do nó que segura o segundo pedido, e é isso que se mede embaixo — nenhum
	# HTTP sai deste processo (a sonda é bloqueada antes de pedir, e `Initialize()`
	# nunca é chamada aqui).
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var previousBase : String = str(nc.get("CompanionURL"))
	nc.set("CompanionURL", "http://127.0.0.1:1/shambleta-harness-sem-ouvinte")
	var url : String = str(_wps.call("CompanionPushStatusURL"))
	_check(url.ends_with("/push/vapid"),
			"a pergunta sai para <base do companion>/push/vapid, nunca um caminho inventado: %s" % url)
	_check(not url.contains("push/test"),
			"a rota sondada é a de prontidão, não a fila (/push/test continua fora do proxy)")

	var parked : HTTPRequest = HTTPRequest.new()
	parked.name = "WebPushReadinessProbe"
	root.add_child(parked)
	_check(not bool(_wps.call("ProbeCompanionPushReady")),
			"com uma sonda em voo, ProbeCompanionPushReady() não multiplica o pedido")
	_check(root.get_node_or_null(NodePath("WebPushReadinessProbe")) == parked,
			"e não trocou nem removeu a sonda que já estava na árvore")
	root.remove_child(parked)
	parked.free()
	_check(root.get_node_or_null(NodePath("WebPushReadinessProbe")) == null,
			"a sonda de mentira saiu da árvore (harness não deixa nó órfão)")

	var lie : Dictionary = _wps.call("ObserveCompanionPushResponse", "{\"ready\": true}")
	_check(str(lie.get("reason", "")) == "ready_without_public_key"
			and not bool(_wpd.call("VapidKeyConfigured")),
			"\"pronto\" sem pública é recusado (sem key não há subscribe): %s"
			% str(lie.get("reason", "?")))
	var junk : Dictionary = _wps.call("ObserveCompanionPushResponse", "<html>404</html>")
	_check(str(junk.get("reason", "")) == "bad_response" and not bool(junk.get("ok", false)),
			"corpo que não é JSON nunca vira \"assume pronto\" (%s)" % str(junk.get("reason", "?")))
	var shortKey : Dictionary = _wps.call("ObserveCompanionPushResponse",
			"{\"ready\": true, \"public_key\": \"BD" + "a".repeat(84) + "\"}")
	_check(str(shortKey.get("reason", "")) == "ready_without_public_key",
			"pública de 86 chars recusada (87 é o X9.62 em base64url): %s"
			% str(shortKey.get("reason", "?")))
	# Browser sem ponte: a leitura responde pelo motivo, não por um `pending` que a
	# UI esperaria para sempre (mesmo contrato da suíte G de `web_delivery_test`).
	_lc.set("isWeb", true)
	var poll : Dictionary = _wps.call("PollSubscription")
	_check(str(poll.get("reason", "")) == "no_bridge",
			"em browser sem ponte, PollSubscription() devolve no_bridge (%s)"
			% str(poll.get("reason", "?")))
	_lc.set("isWeb", false)
	nc.set("CompanionURL", previousBase)

# ------------------------------------------------------------------ 6. herança

func _suiteTeardown() -> void:
	print("-- (6) a árvore e o estado voltam ao que eram (harness não deixa herança)")
	_wps.call("SetBridgeOverrideForHarness", null)
	_clearDeploy()
	_resetFlow()
	_lc.set("isWeb", false)
	_removeRecorder()
	var product : Node = root.get_node_or_null(NodePath("Network"))
	if _realNetwork == null:
		_check(product == null,
				"sem autoload Network neste processo, a árvore não ficou com nó emprestado")
		_check(not bool(_wpd.call("ClientSubmitWired")),
				"e a sonda responde no_network_node (honesto, não um true por tabela)")
	else:
		_check(product == _realNetwork,
				"o nó Network de produto está de volta no caminho de sempre")
		_check(bool(_wpd.call("ClientSubmitWired")),
				"com o nó de produto restaurado a sonda do RPC volta a responder true")
	_checkSame(str(_wpd.call("CompanionReadyReason")), str(_const(_wpd, "ReasonNotProbed")),
			"a prontidão volta ao estado inicial (nenhum \"pronto\" póstumo)")
	_check(not bool(_wpd.call("VapidKeyConfigured")),
			"a pública observada foi limpa: o próximo harness não herda chave")
	_check(not bool(_wps.call("CanDeliver")),
			"CanDeliver() continua fechado no estado restaurado")
	_check(not bool(_wps.call("IsEnabled")), "nenhum toggle ficou ligado por este harness")
	_checkSame(_owed(), "", "nenhuma dívida de fluxo ficou pendente")
