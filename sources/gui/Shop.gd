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
@onready var gemsLabel : Label	= $Layout/ShopScroll/ShopContent/Gems
@onready var vipLabel : Label	= $Layout/ShopScroll/ShopContent/VIP
@onready var buyChest1 : Button	= $Layout/ShopScroll/ShopContent/BuyChest1
@onready var buyChest5 : Button	= $Layout/ShopScroll/ShopContent/BuyChest5
@onready var buyVip1 : Button	= $Layout/ShopScroll/ShopContent/BuyVip1
@onready var buyVip2 : Button	= $Layout/ShopScroll/ShopContent/BuyVip2
@onready var catalogBox : VBoxContainer = $Layout/ShopScroll/ShopContent/CatalogBox
@onready var starterLabel : Label = $Layout/ShopScroll/ShopContent/StarterOffer
@onready var pendingLabel : Label = $Layout/ShopScroll/ShopContent/PendingGrants
@onready var intentLabel : Label = $Layout/ShopScroll/ShopContent/IntentStatus
@onready var paySandboxButton : Button = $Layout/ShopScroll/ShopContent/PaySandbox
@onready var dailyBox : VBoxContainer = $Layout/ShopScroll/ShopContent/DailyBox
@onready var rerollButton : Button = $Layout/ShopScroll/ShopContent/RerollDaily
@onready var rerollAdButton : Button = $Layout/ShopScroll/ShopContent/RerollDailyAd
@onready var oneTimeBox : VBoxContainer = $Layout/ShopScroll/ShopContent/OneTimeBox

var _pendingIntent : Dictionary = {}
var _http : HTTPRequest = null
# SOM-IDLE auditoria 2026-09-27: quatro gastos gem/endurecidos daqui (baús,
# vendor, oferta diária, reroll) saíam com um clique sem qualquer freio. Entram
# no idiom da casa (arm + ConfirmPending, mesmo de AuctionHousePanel/ArenaPanel
# e do checkout de dinheiro real que já era intent + dialog): os handlers abaixo
# APENAS ARMAM a pendência; `ConfirmPending()` é o ÚNICO caminho que emite RPC.
# `SendHook` é a costura do harness — "emitiu" é medido, não lido do código.
# O checkout real (`_on_buy_sku_pressed` → GetCheckoutIntent → dialog) NÃO passa
# por aqui: ele já era confirmado por definição (a intent não cobra nada).
var SendHook : Callable
var _pending : Dictionary = {}
# Últimos preços vistos no estado do servidor — a linha armada cita o número
# que sai da conta, não um chute da UI (mesma regra do preview do leilão).
var _chestCost : int = 120
var _rerollCost : int = 20

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
	# Guardado para a linha de confirmação citar o TOTAL real que sai do bolso —
	# o número exibido é o número gasto, mesma régua do preview do leilão.
	_chestCost = chestCost
	var vip1Cost : int = int(state.get("vip1_cost", 440))
	var vip2Cost : int = int(state.get("vip2_cost", 880))
	buyChest1.text = "Buy 1 Chest — %d gems" % chestCost
	buyChest5.text = "Buy 5 Chests — %d gems" % (chestCost * 5)
	# A vitrine lê o teto da MESMA constante que o settle aplica. Anunciar "1h"
	# aqui quando `BaseCapHours` mudou é a classe de defeito que a suíte de
	# vitrine honesta existe para pegar: o rótulo é promessa de produto.
	buyVip1.text = "VIP 1 — %d gems / 30 days (%.0fh offline, no ads)" % [vip1Cost, OfflineSettle.CapHoursVIP1]
	buyVip2.text = "VIP 2 — %d gems / 30 days (%.0fh offline, loot 2×)" % [vip2Cost, OfflineSettle.CapHoursVIP2]

	var vip : Dictionary = state.get("vip", {})
	if bool(vip.get("active", false)):
		var daysLeft : int = ceili((int(vip.get("until", 0)) - Time.get_unix_time_from_system()) / 86400.0)
		vipLabel.text = "VIP%d: active (%d days left, idle faucet x%.1f, offline cap %.0fh)" % [
			int(vip.get("tier", 0)), maxi(daysLeft, 0),
			float(vip.get("mods", 1.0)), float(vip.get("cap_hours", 24.0))]
	else:
		vipLabel.text = "VIP: inactive (offline cap %.0fh + %.0fh per ad)" % [
			OfflineSettle.BaseCapHours, EconomyCatalog.AD_OFFLINE_HOURS_PER_AD]

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
		$Layout/ShopScroll/ShopContent.add_child(_vendorBox)
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
			# Carrega rótulo e preço no bind: a linha de confirmação precisa NOMEAR
			# o que se compra e quanto sai — primitivos no bind, nunca closure.
			b.pressed.connect(_on_buy_vendor_pressed.bind(str((e as Dictionary).get("id", "")), str((e as Dictionary).get("label", "?")), int((e as Dictionary).get("cost", 0))))
		box.add_child(b)

# Os handlers a seguir só ARMAM (`Request*`); a rede fala por `ConfirmPending()`.
func _on_buy_vendor_pressed(offerID : String, offerLabel : String = "", costGold : int = 0):
	RequestBuyVendor(offerID, offerLabel, costGold)

func RequestBuyVendor(offerID : String, offerLabel : String, costGold : int) -> bool:
	if offerID.is_empty():
		return false
	_pending = {
		"method" = "BuyVendorOffer",
		"args" = [offerID],
		"line" = "Buy %s for %d gold? The gold is spent now — vendor supplies are not refundable." % [
			("\"%s\"" % offerLabel) if not offerLabel.is_empty() else "the vendor offer", costGold],
	}
	_Ask(str(_pending["line"]))
	return true

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
	RequestBuyChests(count)

func RequestBuyChests(count : int) -> bool:
	if count <= 0:
		return false
	_pending = {
		"method" = "BuyChests",
		"args" = [count],
		"line" = "Buy %d chest(s) for %d gems? Gems are spent now and closed chests are not refundable." % [count, _chestCost * count],
	}
	_Ask(str(_pending["line"]))
	return true

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
	intentLabel.text = "Intent %s — %s R$ %.2f. %s" % [
		str(intent.get("external_reference", "?")), str(intent.get("label", "?")), float(intent.get("price", 0.0)),
		"Press Pay to open secure checkout." if LauncherCommons.isWeb else "Compra apenas na versão web (o sandbox do companion responde 403 no nativo)."]
	paySandboxButton.disabled = not LauncherCommons.isWeb

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
			# Rótulo e preço via bind (primitivos, não closure): a confirmação tem
			# que citar o que sai da conta antes do RPC existir.
			b.pressed.connect(_on_buy_daily_offer_pressed.bind(oid, str(e.get("label", oid)), int(e.get("cost", 0))))
		dailyBox.add_child(b)
	for c in oneTimeBox.get_children():
		c.queue_free()
	for e in shop.get("one_time", []):
		if not (e is Dictionary):
			continue
		var oid : String = str(e.get("id", ""))
		var ob := Button.new()
		ob.text = "%s — %d gems (one-time)" % [str(e.get("label", oid)), int(e.get("cost", 0))]
		ob.pressed.connect(_on_buy_daily_offer_pressed.bind(oid, str(e.get("label", oid)), int(e.get("cost", 0))))
		oneTimeBox.add_child(ob)
	var used : int = int(shop.get("rerolls_used", 0))
	var maxR : int = int(shop.get("rerolls_max", 3))
	_rerollCost = int(shop.get("reroll_cost", 20))
	if used >= maxR:
		rerollButton.text = "Reroll daily shop — cap reached (%d/%d)" % [used, maxR]
		rerollButton.disabled = true
		rerollAdButton.disabled = true
	else:
		rerollButton.text = "Reroll daily shop — %d gems (%d/%d)" % [int(shop.get("reroll_cost", 20)), used, maxR]
		rerollButton.disabled = false
		rerollAdButton.disabled = false
		rerollAdButton.text = "Free reroll (ad, %d/%d used)" % [used, maxR]

func _on_buy_daily_offer_pressed(offerID : String, offerLabel : String = "", costGems : int = 0):
	RequestBuyDailyOffer(offerID, offerLabel, costGems)

func RequestBuyDailyOffer(offerID : String, offerLabel : String, costGems : int) -> bool:
	if offerID.is_empty():
		return false
	_pending = {
		"method" = "BuyDailyOffer",
		"args" = [offerID],
		"line" = "Buy %s for %d gems? Gems are spent the moment the server accepts — no undo." % [
			("\"%s\"" % offerLabel) if not offerLabel.is_empty() else "the daily offer", costGems],
	}
	_Ask(str(_pending["line"]))
	return true

func _on_reroll_daily_pressed():
	RequestRerollDaily()

func RequestRerollDaily() -> bool:
	_pending = {
		"method" = "RerollDailyShop",
		"args" = [],
		"line" = "Reroll the daily shop for %d gems? The gems are gone even if you hate the new offers." % _rerollCost,
	}
	_Ask(str(_pending["line"]))
	return true

# ------------------------------------------------------------------ confirmação
# Blocos espelhados de AuctionHousePanel: um único ponto arma (`_Arm` implícito
# nos Request*), um único ponto emite (`ConfirmPending`), uma única superfície
# (o modal da casa). O `pendingLabel` faz de linha visível fora do modal porque
# esta janela, nascida de .tscn, não tem confirm-row própria — e "gasto pendente"
# é exatamente o que aquele rótulo significa.
func _Ask(text : String) -> void:
	if pendingLabel:
		pendingLabel.text = text
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if modal:
		UICommons.MessageBox(text, Callable(self, "ConfirmPending"), "Confirm")

# ÚNICO caminho que fala com a rede. Sem confirmação, este método não é chamado.
func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	_send(methodName, args)
	# Recupera o rodapé de estado: a pergunta não pode ficar na tela depois de
	# respondida. Só com a janela montada na árvore — o harness fora-da-árvore
	# lê o cache, não redraw.
	if is_node_ready():
		ShowState(NetClient.LastEconomyState)
		ShowDailyShop(NetClient.LastDailyShop)

func CancelPending() -> void:
	_pending = {}

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

# Costura de produção: `Network.<rpc>` sempre em nome literal (a porta de
# dispatch de `Network` exige o mesmo formato dos demais calls).
func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"BuyChests":
			Network.BuyChests(int(args[0]))
		"BuyVendorOffer":
			Network.BuyVendorOffer(str(args[0]))
		"BuyDailyOffer":
			Network.BuyDailyOffer(str(args[0]))
		"RerollDailyShop":
			Network.RerollDailyShop()
		_:
			push_error("Shop: unknown send target " + methodName)

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
