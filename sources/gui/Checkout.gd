extends WindowPanel

# SOM-IDLE F2: basic checkout UI (web-only).
# Shows product details and opens the payment provider checkout page.
# For sandbox, uses the companion /checkout/simulate endpoint.
# For production, opens the payment URL returned by the companion.
#
# This window is created programmatically (no .tscn edit required).

const COMPANION_URL_DEFAULT : String = "http://127.0.0.1:8901"

var _http : HTTPRequest				= null
var _pendingIntent : Dictionary		= {}
var _pendingSKU : String			= ""
var _titleLabel : Label				= null
var _detailLabel : Label			= null
var _priceLabel : Label				= null
var _payButton : Button				= null
var _statusLabel : Label			= null

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
	_statusLabel.autowrap = true
	root.add_child(_statusLabel)

	_payButton = Button.new()
	_payButton.text = tr("Pay now")
	_payButton.pressed.connect(_on_pay_pressed)
	root.add_child(_payButton)

func StartCheckout(sku : String, label : String, price : float, currency : String = "BRL"):
	_pendingSKU = sku
	_pendingIntent = {}
	_titleLabel.text = label
	_priceLabel.text = "%.2f %s" % [price, currency]
	_detailLabel.text = "SKU: %s" % sku
	_statusLabel.text = tr("Requesting payment...")
	_payButton.disabled = true
	popup_centered()

func ShowIntent(intent : Dictionary):
	if not bool(intent.get("ok", false)):
		_statusLabel.text = tr("Checkout unavailable: %s") % str(intent.get("reason", "?"))
		return
	_pendingIntent = intent
	var price : float = float(intent.get("price", 0.0))
	var currency : String = str(intent.get("currency", "BRL"))
	_priceLabel.text = "%.2f %s" % [price, currency]
	_statusLabel.text = tr("Ready to pay")
	_payButton.disabled = false

func _on_pay_pressed():
	if _pendingIntent.is_empty():
		return
	var companionURL : String = _companion_url()
	var isWeb : bool = LauncherCommons.isWeb
	var isSandbox : bool = _pendingIntent.get("sandbox", false)
	if isWeb:
		if isSandbox:
			_statusLabel.text = tr("Processing sandbox payment...")
			_payButton.disabled = true
			var body : Dictionary = {
				"username": _get_username(),
				"sku": str(_pendingIntent.get("sku", "")),
				"idempotency_key": "%s:web%d" % [str(_pendingIntent.get("external_reference", "")), int(Time.get_unix_time_from_system())],
			}
			_http.request(companionURL + "/checkout/simulate",
				["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
		else:
			_statusLabel.text = tr("Opening payment page...")
			_payButton.disabled = true
			var paymentURL : String = str(_pendingIntent.get("payment_url", ""))
			if paymentURL.is_empty():
				_statusLabel.text = tr("Payment URL not available")
				_payButton.disabled = false
				return
			OS.shell_open(paymentURL)
			_statusLabel.text = tr("Complete payment in the opened page. Items will be credited automatically.")
			_payButton.text = tr("Close")
			_payButton.disabled = false
	else:
		_statusLabel.text = tr("Checkout is only available on web builds")
		_payButton.disabled = true

func _on_checkout_done(result : int, _code : int, _headers : PackedStringArray, body : PackedByteArray):
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

func _companion_url() -> String:
	if OS.has_environment("SHAMBLETA_COMPANION_URL"):
		return OS.get_environment("SHAMBLETA_COMPANION_URL")
	return COMPANION_URL_DEFAULT

func _get_username() -> String:
	if Launcher.nPanel:
		return str(Launcher.nPanel.nameText)
	return ""

