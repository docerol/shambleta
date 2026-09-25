extends WindowPanel

# SOM-IDLE F2: checkout UI (produção Mercado Pago + sandbox dev).
# Produção: pede POST /checkout/preference ao companion (valor do catálogo,
# nunca do cliente) e abre a URL de pagamento retornada (init_point). O grant
# chega pelo webhook, independente do jogador voltar — esta janela só mostra
# "aguardando confirmação" e o poll de pending_grants (~30s) credita sozinho.
# Sandbox dev: POST /checkout/simulate atrás de SHAMBLETA_ALLOW_DEV_CHECKOUT.
#
# This window is created programmatically (no .tscn edit required).
# A base do companion vem de `NetworkCommons.CompanionURL` (env > conf > origem da
# página no web) — não de uma constante daqui: em browser não existe variável de
# ambiente, e 127.0.0.1 é a máquina do jogador, não o servidor.

var _http : HTTPRequest				= null
var _pendingIntent : Dictionary		= {}
var _awaitingPreference : bool		= false
var _pendingSKU : String			= ""
var _titleLabel : Label				= null
var _detailLabel : Label			= null
var _priceLabel : Label				= null
var _payButton : Button				= null
var _statusLabel : Label			= null
# Segunda porta do dinheiro: abre a página de pagamento de novo, a pedido.
var _openPaymentButton : Button		= null
var _openPaymentURL : String		= ""

func _ready():
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_checkout_done)
	add_child(_http)
	_BuildUI()
	hide()

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if _http and _http.request_completed.is_connected(_on_checkout_done):
			_http.request_completed.disconnect(_on_checkout_done)

func _BuildUI():
	var root : VBoxContainer = VBoxContainer.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)

	_titleLabel = Label.new()
	_titleLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_titleLabel)

	_priceLabel = Label.new()
	_priceLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_priceLabel.add_theme_color_override("font_color", Color(0.2, 0.8, 0.4))
	root.add_child(_priceLabel)

	_detailLabel = Label.new()
	_detailLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detailLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(_detailLabel)

	_statusLabel = Label.new()
	_statusLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_statusLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_statusLabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_statusLabel)

	_payButton = Button.new()
	_payButton.text = tr("Pay now")
	_payButton.pressed.connect(_on_pay_pressed)
	root.add_child(_payButton)

	# A segunda porta. `_open_payment_url` chega por dois caminhos, e eles não são
	# iguais para o browser: o clique em "Pagar agora" com a URL já na intent acontece
	# dentro da user activation, mas a URL que volta do `POST /checkout/preference`
	# chega de um round trip — e um `window.open` disparado fora da activation é o que
	# o bloqueador de popup come. Sem remédio visível o jogador fica olhando "awaiting
	# confirmation" de uma página que nunca abriu, e o grant do webhook não tem o que
	# confirmar. Botão comum e não `LinkButton`: quem abre a aba tem que ser um clique
	# do jogador, que é exatamente o que reabre a janela de activation.
	_openPaymentButton = Button.new()
	_openPaymentButton.text = tr("Open payment page")
	_openPaymentButton.visible = false
	_openPaymentButton.pressed.connect(_on_open_payment_pressed)
	root.add_child(_openPaymentButton)

func StartCheckout(sku : String, label : String, price : float, currency : String = "BRL"):
	_pendingSKU = sku
	_pendingIntent = {}
	_openPaymentURL = ""
	_openPaymentButton.visible = false
	_titleLabel.text = label
	_priceLabel.text = "%.2f %s" % [price, currency]
	_detailLabel.text = "SKU: %s" % sku
	_statusLabel.text = tr("Requesting payment...")
	# O texto volta junto do resto do estado: `_open_payment_url` e o aceite do sandbox
	# deixam o botão como "Close", e reabrir a janela para outro SKU sem resetar deixava
	# um botão rotulado "Fechar" que, apertado, iniciava uma cobrança.
	_payButton.text = tr("Pay now")
	_payButton.disabled = true
	# SOM-IDLE parser: WindowPanel não tem popup_centered() (era erro de parse
	# no Godot estrito) — ToggleControl() é o padrão das outras janelas.
	if not is_visible():
		ToggleControl()

func ShowIntent(intent : Dictionary):
	if not bool(intent.get("ok", false)):
		_statusLabel.text = tr("Checkout unavailable: %s") % str(intent.get("reason", "?"))
		return
	_pendingIntent = intent
	_awaitingPreference = false
	var price : float = float(intent.get("price", 0.0))
	var currency : String = str(intent.get("currency", "BRL"))
	_priceLabel.text = "%.2f %s" % [price, currency]
	if bool(intent.get("sandbox", false)):
		_statusLabel.text = tr("Ready to pay (sandbox)")
	else:
		_statusLabel.text = tr("Ready to pay — a secure payment page will open")
	_payButton.disabled = false

func _on_pay_pressed():
	if _pendingIntent.is_empty() or _awaitingPreference:
		return
	# Sandbox dev explícito (staging): simula o pagamento aprovado.
	if bool(_pendingIntent.get("sandbox", false)):
		_pay_sandbox()
		return
	# Produção: a intent do game server já traz a URL quando o Shop a tem;
	# senão, pede a preferência real ao companion (valor do catálogo).
	var paymentURL : String = str(_pendingIntent.get("payment_url", ""))
	if not paymentURL.is_empty():
		_open_payment_url(paymentURL)
		return
	_request_preference()

func _pay_sandbox():
	var companionURL : String = NetworkCommons.CompanionURL
	_statusLabel.text = tr("Processing sandbox payment...")
	_payButton.disabled = true
	var body : Dictionary = {
		"username": _get_username(),
		"sku": str(_pendingIntent.get("sku", "")),
		"idempotency_key": "%s:web%d" % [str(_pendingIntent.get("external_reference", "")), int(Time.get_unix_time_from_system())],
	}
	_http.request(companionURL + "/checkout/simulate",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

func _request_preference():
	var companionURL : String = NetworkCommons.CompanionURL
	var sku : String = str(_pendingIntent.get("sku", _pendingSKU))
	if sku.is_empty():
		_statusLabel.text = tr("Payment URL not available")
		return
	# Beta fechado: o companion vincula o checkout à sessão (auth_token do
	# login remember-me); sem ele, o servidor rejeita (anti cross-account).
	var token : String = _get_auth_token()
	if token.is_empty():
		_statusLabel.text = tr("Log in with remember-me to enable checkout")
		_payButton.disabled = false
		return
	_statusLabel.text = tr("Creating secure payment...")
	_payButton.disabled = true
	_awaitingPreference = true
	var body : Dictionary = {
		"auth_token": token,
		"account_id": int(_pendingIntent.get("account_id", 0)),
		"sku": sku,
		"external_reference": str(_pendingIntent.get("external_reference", "")),
	}
	_http.request(companionURL + "/checkout/preference",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

func _open_payment_url(paymentURL : String):
	if paymentURL.is_empty():
		_statusLabel.text = tr("Payment URL not available")
		_payButton.disabled = false
		return
	_show_payment_url(paymentURL)
	_launch_payment_url(paymentURL)
	_poll_pending_grants()

# Metade visual: é o que a janela mostra quando existe uma página de pagamento
# esperando o jogador. Deliberadamente não toca o navegador — assim ela abre e é
# verificável headless, e o único caminho para fora da tela é `_launch_payment_url`.
func _show_payment_url(paymentURL : String):
	_statusLabel.text = tr("Awaiting payment confirmation — items credit automatically when approved.")
	_payButton.text = tr("Close")
	_payButton.disabled = false
	_openPaymentURL = paymentURL
	_pendingIntent["payment_url"] = paymentURL
	_openPaymentButton.visible = true

# Metade que navega. Chamada uma vez pelo clique direto (dentro da user activation) e
# de novo pelo botão acima, que é clique do jogador e portanto activation fresca —
# é o que sobra quando o browser come o popup do caminho assíncrono.
func _launch_payment_url(paymentURL : String):
	if LauncherCommons.isWeb:
		JavaScriptBridge.eval("window.open(%s, '_blank');" % JSON.stringify(paymentURL))
	else:
		OS.shell_open(paymentURL)

func _on_open_payment_pressed():
	if not _openPaymentURL.is_empty():
		_launch_payment_url(_openPaymentURL)

func _poll_pending_grants():
	# O grant chega pelo webhook independente do retorno; o poll de
	# pending_grants (~30s) mostra quando creditou. Pede um estado fresco.
	if Launcher.GUI:
		Network.GetEconomyState()

func _on_checkout_done(result : int, _code : int, _headers : PackedStringArray, body : PackedByteArray):
	if _awaitingPreference:
		_awaitingPreference = false
		_on_preference_done(result, body)
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_statusLabel.text = tr("Payment failed: %s") % str(result)
		_payButton.disabled = false
		return
	var parsed : Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or str(parsed.get("status", "")) != "ok":
		_statusLabel.text = tr("Payment rejected: %s") % body.get_string_from_utf8().left(160)
		_payButton.disabled = false
		return
	_pendingIntent = {}
	_statusLabel.text = tr("Payment accepted — items will be credited shortly")
	_payButton.text = tr("Close")
	_payButton.disabled = false
	if Launcher.GUI:
		Launcher.GUI.shopWindow.RefreshState()

func _on_preference_done(result : int, body : PackedByteArray):
	if result != HTTPRequest.RESULT_SUCCESS:
		_statusLabel.text = tr("Checkout unavailable — try again later (%s)") % str(result)
		_payButton.disabled = false
		return
	var parsed : Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary and str(parsed.get("error", "")) == "consent_required":
		# O aceite gravado na conta não é a versão vigente (bump de ToS/
		# privacidade/idade, ou conta anterior à migration 046, que lê ''). O jogo
		# já barrou o login e o companion barra o checkout: a ação é re-aceitar os
		# textos, não insistir — por isso isto não cai no "try again later".
		_statusLabel.text = tr("Payment blocked: log in again to accept the current agreements.")
		_payButton.disabled = false
		return
	if not (parsed is Dictionary) or str(parsed.get("payment_url", "")).is_empty():
		_statusLabel.text = tr("Checkout unavailable — try again later (%s)") % body.get_string_from_utf8().left(120)
		_payButton.disabled = false
		return
	_open_payment_url(str(parsed.get("payment_url", "")))

func _get_username() -> String:
	if Launcher.GUI and Launcher.GUI.loginPanel:
		return str(Launcher.GUI.loginPanel.nameText)
	return ""

func _get_auth_token() -> String:
	# O token da sessão mora em conf, não no painel: `SaveToken` grava em
	# `Conf.Type.AUTH_TOKEN` e `Connect()` zera `savedToken` logo depois de usá-lo no
	# auto-login (sources/gui/Login.gd:311). Ler só o var devolvia "" em qualquer
	# sessão — no login por senha porque o var nunca chega a ser atribuído, no por
	# token porque ele é aparado — e o companion respondia 401 `missing_token` na
	# frente do pagamento, com a janela aconselhando "lembrar" justamente a quem já
	# marcou. A porta de remember-me continua intacta: o server emite token só com
	# rememberMe (sources/network/server/Peers.gd:286), então sem ele o conf está
	# vazio e o aviso acionável lá em cima é o caminho certo.
	var panel : Control = Launcher.GUI.loginPanel if Launcher.GUI else null
	var panelToken : String = str(panel.savedToken) if panel and "savedToken" in panel else ""
	if not panelToken.is_empty():
		return panelToken
	return str(Conf.GetString("auth", "token", Conf.Type.AUTH_TOKEN))

