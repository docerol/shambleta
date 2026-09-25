extends WindowPanel

# SOM-IDLE beta GUI: Shop — sink de gems (chests) + checkout VIP. Compras são
# server-authoritative (EconomyService); a resposta traz ShopFeedback +
# EconomyState fresco, que redesenha esta janela via NetClient.
const AdProvider = preload("res://sources/ads/AdProvider.gd")
# SOM-IDLE checkout: Checkout.gd não tem class_name (janela criada em runtime),
# então referencia via preload em vez do identificador global.
const CheckoutDialog = preload("res://sources/gui/Checkout.gd")
#
# Fase A (checkout sandbox): seção "Buy gems (sandbox)" lista o catálogo
# (display-only; grants são server-authoritative no companion), a oferta
# starter one-time e os grants pendentes. Fluxo: Buy → GetCheckoutIntent →
# external_reference → POST companion /checkout/simulate (allow_dev) →
# grant entra na fila e credita no próximo poll (~30s). Produção troca o
# simulate pelo checkout MP (mesma external_reference, handoff §2).
# A base do companion não mora mais aqui: `NetworkCommons.CompanionURL` é a única
# resolução (env > conf > origem da página no web), porque browser não tem variável
# de ambiente e o default de desenvolvimento é o loopback da própria máquina.
@onready var gemsLabel : Label	= $Layout/Gems
@onready var vipLabel : Label	= $Layout/VIP
@onready var buyChest1 : Button	= $Layout/BuyChest1
@onready var buyChest5 : Button	= $Layout/BuyChest5
@onready var buyVip1 : Button	= $Layout/BuyVip1
@onready var buyVip2 : Button	= $Layout/BuyVip2
@onready var catalogBox : VBoxContainer = $Layout/CatalogBox
@onready var starterLabel : Label = $Layout/StarterOffer
@onready var pendingLabel : Label = $Layout/PendingGrants
@onready var intentLabel : Label = $Layout/IntentStatus
@onready var paySandboxButton : Button = $Layout/PaySandbox
@onready var dailyBox : VBoxContainer = $Layout/DailyBox
@onready var rerollButton : Button = $Layout/RerollDaily
@onready var rerollAdButton : Button = $Layout/RerollDailyAd
@onready var oneTimeBox : VBoxContainer = $Layout/OneTimeBox

var _pendingIntent : Dictionary = {}
var _http : HTTPRequest = null

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_simulate_done)
	add_child(_http)
	if is_visible():
		RefreshState()

func _on_visibility_changed():
	if is_visible():
		RefreshState()

func RefreshState():
	ShowState(NetClient.LastEconomyState)
	ShowDailyShop(NetClient.LastDailyShop)
	Network.GetEconomyState()
	Network.GetDailyShop()

# Redesenho a partir do estado consolidado (preços vivem no servidor).
func ShowState(state : Dictionary):
	if state.is_empty():
		return
	gemsLabel.text = "Gems: %s" % Util.FormatNumber(int(state.get("gems", 0)))
	var chestCost : int = int(state.get("chest_cost", 120))
	var vip1Cost : int = int(state.get("vip1_cost", 440))
	var vip2Cost : int = int(state.get("vip2_cost", 880))
	buyChest1.text = "Buy 1 Chest — %d gems" % chestCost
	buyChest5.text = "Buy 5 Chests — %d gems" % (chestCost * 5)
	buyVip1.text = "VIP 1 — %d gems / 30 days (+20%% AFK)" % vip1Cost
	buyVip2.text = "VIP 2 — %d gems / 30 days (+20%% AFK)" % vip2Cost

	var vip : Dictionary = state.get("vip", {})
	if bool(vip.get("active", false)):
		var daysLeft : int = ceili((int(vip.get("until", 0)) - Time.get_unix_time_from_system()) / 86400.0)
		vipLabel.text = "VIP%d: active (%d days left, idle faucet x%.1f, offline cap %.0fh)" % [
			int(vip.get("tier", 0)), maxi(daysLeft, 0),
			float(vip.get("mods", 1.0)), float(vip.get("cap_hours", 12.0))]
	else:
		vipLabel.text = "VIP: inactive (offline cap 12h)"

	# Fase A: catálogo (botões construídos 1×; texto atualiza a cada estado).
	var catalog : Array = state.get("catalog", [])
	_rebuild_catalog_buttons(catalog)
	var offer : Dictionary = state.get("starter_offer", {})
	if bool(offer.get("eligible", false)):
		var leftH : int = maxi(0, int(offer.get("expires_at", 0)) - int(Time.get_unix_time_from_system())) / 3600
		starterLabel.text = "Starter pack: available (~%dh left, one-time R$ 9,90)" % leftH
	else:
		starterLabel.text = "Starter pack: unavailable (%s)" % str(offer.get("reason", "?"))
	var pending : Array = state.get("pending_grants", [])
	if pending.is_empty():
		pendingLabel.text = "Pending purchases: none"
	else:
		var parts : PackedStringArray = []
		for p in pending:
			parts.append(str(p.get("sku", "?")))
		pendingLabel.text = "Pending purchases: %s (credit in ~30s)" % ", ".join(parts)
	ShowVendor(state.get("vendor", {}))

# R2 vendor gold (runtime, sem .tscn): suprimentos por gold, estoque diário.
var _vendorBox : VBoxContainer = null

func _vendor_box() -> VBoxContainer:
	if _vendorBox == null:
		_vendorBox = VBoxContainer.new()
		_vendorBox.name = "VendorBox"
		$Layout.add_child(_vendorBox)
	return _vendorBox

func ShowVendor(vendor : Dictionary):
	var box : VBoxContainer = _vendor_box()
	for c in box.get_children():
		c.queue_free()
	if vendor.is_empty() or not bool(vendor.get("ok", false)):
		return
	for e in vendor.get("offers", []):
		if not (e is Dictionary):
			continue
		var left : int = int((e as Dictionary).get("left", 0))
		var b := Button.new()
		if left <= 0:
			b.text = "%s — sold out today" % str((e as Dictionary).get("label", "?"))
			b.disabled = true
		else:
			b.text = "%s — %d gold (%d left today)" % [str((e as Dictionary).get("label", "?")), int((e as Dictionary).get("cost", 0)), left]
			b.pressed.connect(_on_buy_vendor_pressed.bind(str((e as Dictionary).get("id", ""))))
		box.add_child(b)

func _on_buy_vendor_pressed(offerID : String):
	Network.BuyVendorOffer(offerID)

func _rebuild_catalog_buttons(catalog : Array):
	for c in catalogBox.get_children():
		c.queue_free()
	for e in catalog:
		if not (e is Dictionary):
			continue
		var sku : String = str(e.get("sku", ""))
		var b := Button.new()
		b.text = "Buy %s — R$ %.2f" % [str(e.get("label", sku)), float(e.get("price", 0.0))]
		b.pressed.connect(_on_buy_sku_pressed.bind(sku))
		catalogBox.add_child(b)

func _on_buy_chest_pressed(count : int):
	Network.BuyChests(count)

func _on_buy_vip_pressed(tier : int):
	Network.PurchaseVIP(tier)

# Fase A: pede a intenção ao servidor (valida SKU + elegibilidade starter).
func _on_buy_sku_pressed(sku : String):
	_pendingIntent = {}
	paySandboxButton.disabled = true
	intentLabel.text = "Requesting checkout intent for %s…" % sku
	Network.GetCheckoutIntent(sku)

func ShowCheckoutIntent(intent : Dictionary):
	if not bool(intent.get("ok", false)):
		intentLabel.text = "Checkout rejected: %s" % str(intent.get("reason", "?"))
		return
	_pendingIntent = intent
	intentLabel.text = "Intent %s — %s R$ %.2f. Press Pay to open secure checkout." % [
		str(intent.get("external_reference", "?")),
		str(intent.get("label", "?")), float(intent.get("price", 0.0))]
	paySandboxButton.disabled = false

	# SOM-IDLE F2: web-only checkout dialog for paid items.
	if LauncherCommons.isWeb and not bool(intent.get("sandbox", false)):
		_show_web_checkout(intent)

func _on_pay_sandbox_pressed():
	if _pendingIntent.is_empty():
		return
	var username : String = ""
	if Launcher.GUI and Launcher.GUI.loginPanel:
		username = str(Launcher.GUI.loginPanel.nameText)
	if username.is_empty():
		intentLabel.text = "Sandbox: login username unknown — log in with username first."
		return
	var extRef : String = str(_pendingIntent.get("external_reference", ""))
	var body : Dictionary = {
		"username": username,
		"sku": str(_pendingIntent.get("sku", "")),
		"idempotency_key": "%s:sb%d" % [extRef, int(Time.get_unix_time_from_system())],
	}
	paySandboxButton.disabled = true
	intentLabel.text = "Simulating sandbox payment %s…" % extRef
	# allow_dev exige o segredo compartilhado; em sandbox local o padrão é
	# vazio — o companion rejeita sem SHAMBLETA_WEBHOOK_SECRET (fail-closed).
	_http.request(NetworkCommons.CompanionURL + "/checkout/simulate",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

# Fase B (loja diária): ofertas do dia + reroll pago + one-time (boss/finale).
func ShowDailyShop(shop : Dictionary):
	if shop.is_empty() or not bool(shop.get("ok", false)):
		return
	for c in dailyBox.get_children():
		c.queue_free()
	for e in shop.get("offers", []):
		if not (e is Dictionary):
			continue
		var b := Button.new()
		var oid : String = str(e.get("id", ""))
		if bool(e.get("claimed", false)):
			b.text = "%s — claimed" % str(e.get("label", oid))
			b.disabled = true
		else:
			b.text = "%s — %d gems" % [str(e.get("label", oid)), int(e.get("cost", 0))]
			b.pressed.connect(_on_buy_daily_offer_pressed.bind(oid))
		dailyBox.add_child(b)
	for c in oneTimeBox.get_children():
		c.queue_free()
	for e in shop.get("one_time", []):
		if not (e is Dictionary):
			continue
		var oid : String = str(e.get("id", ""))
		var ob := Button.new()
		ob.text = "%s — %d gems (one-time)" % [str(e.get("label", oid)), int(e.get("cost", 0))]
		ob.pressed.connect(_on_buy_daily_offer_pressed.bind(oid))
		oneTimeBox.add_child(ob)
	var used : int = int(shop.get("rerolls_used", 0))
	var maxR : int = int(shop.get("rerolls_max", 3))
	if used >= maxR:
		rerollButton.text = "Reroll daily shop — cap reached (%d/%d)" % [used, maxR]
		rerollButton.disabled = true
		rerollAdButton.disabled = true
	else:
		rerollButton.text = "Reroll daily shop — %d gems (%d/%d)" % [int(shop.get("reroll_cost", 20)), used, maxR]
		rerollButton.disabled = false
		rerollAdButton.disabled = false
		rerollAdButton.text = "Free reroll (ad, %d/%d used)" % [used, maxR]

func _on_buy_daily_offer_pressed(offerID : String):
	Network.BuyDailyOffer(offerID)

func _on_reroll_daily_pressed():
	Network.RerollDailyShop()

# Fase E: reroll grátis via ad (mesmo contador 3/dia do pago).
func _on_reroll_daily_ad_pressed():
	if not AdProvider.IsReady("reroll"):
		return
	rerollAdButton.disabled = true
	AdProvider.ShowRewarded("reroll", func(token : String) -> void:
		if token.is_empty():
			rerollAdButton.disabled = false
			return
		Network.RerollDailyShopAd(token))

func _on_simulate_done(result : int, _code : int, _headers : PackedStringArray, body : PackedByteArray):
	if result != HTTPRequest.RESULT_SUCCESS:
		intentLabel.text = "Sandbox: companion unreachable (%s). Is it running?" % NetworkCommons.CompanionURL
		paySandboxButton.disabled = false
		return
	var parsed : Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or str(parsed.get("status", "")) != "ok":
		intentLabel.text = "Sandbox rejected: %s" % body.get_string_from_utf8().left(160)
		paySandboxButton.disabled = false
		return
	_pendingIntent = {}
	intentLabel.text = "Sandbox payment accepted %s — credit in ~30s (poll)." % str(parsed.get("items", []))
	RefreshState()

# SOM-IDLE F2: web-only checkout dialog.
func _show_web_checkout(intent : Dictionary):
	if not Launcher.GUI.checkoutWindow:
		Launcher.GUI.checkoutWindow = CheckoutDialog.new()
		Launcher.GUI.add_child(Launcher.GUI.checkoutWindow)
	if Launcher.GUI.checkoutWindow:
		Launcher.GUI.checkoutWindow.StartCheckout(
			str(intent.get("sku", "")),
			str(intent.get("label", "")),
			float(intent.get("price", 0.0)),
			str(intent.get("currency", "BRL")))
