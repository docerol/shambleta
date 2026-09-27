extends RefCounted
class_name AuctionHouseRows

# 059 (JUIZ MARKETPLACE 2026-09-27): as LINHAS da vitrine, da memória de preço e
# das ordens em pé, mais os números que a prévia de gasto mostra. Saiu do
# `AuctionHousePanel` pelo mesmo motivo de `GuildPanelRows`: o painel precisa
# decidir O QUE cada clique faz, não escrever 150 linhas de formatação no meio.
#
# Tudo aqui é puro de propósito (payload entra, texto/nó sai, nenhum lê `DB` ou
# o banco com decisão de economia): os valores que aparecem na tela são os que o
# SERVIDOR mandou (`GetAuctionListings`/`GetAuctionPage` devolvem gold, gems,
# taxas, `sold`, `orders`). Nada nesta fileira calcula um preço que o kernel não
# cobrou — é a regra do painel, e ela continua valendo aqui.
#
# Os nomes de nó (`AuctionRow_<id>`, `AuctionSold`, `AuctionOrders`,
# `AuctionOrder_<id>`) são estáveis porque é por eles que `tests/hud_wiring_test.gd`
# e `tests/auction_house_wiring_test.gd` acham a linha sem depender de texto.

const SoldSamples : int = 6

static func Clear(box : Node) -> void:
	if box == null:
		return
	for child in box.get_children():
		box.remove_child(child)
		child.free()

static func LabelOf(parent : Node, nodeName : String, text : String) -> Label:
	var label := Label.new()
	label.name = nodeName
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

static func Header(parent : Node, nodeName : String, text : String, fontSize : int) -> Label:
	var label := LabelOf(parent, nodeName, text)
	label.add_theme_font_size_override("font_size", fontSize)
	return label

# ------------------------------------------------------------------ texto (puro)

# Vitrine: `highlight` e `mine` vêm na linha (servidor), não deduzidos aqui.
static func ListingRowText(listing : Dictionary) -> String:
	var star : String = "★ " if int(listing.get("highlight", 0)) == 1 else ""
	var yours : String = " (yours)" if bool(listing.get("mine", false)) else ""
	return "%s#%d %s x%d — %d gold%s" % [star, int(listing.get("id", 0)), str(listing.get("name", "?")),
		int(listing.get("qty", 1)), int(listing.get("price_gold", listing.get("price", 0))), yours]

static func BalanceLine(state : Dictionary) -> String:
	return "Gold: %d • Gems: %d • Your open listings: %d/%d • Bids held: %d gold" % [
		int(state.get("gold", 0)), int(state.get("gems", 0)),
		int(state.get("open", 0)), int(state.get("cap", 0)), HeldEscrow(state)]

static func StatusLine(state : Dictionary) -> String:
	return "%d of %d open listings (server page at offset %d)" % [
		(state.get("listings", []) as Array).size(), int(state.get("total", 0)), int(state.get("offset", 0))]

static func PageLine(page : int, pages : int) -> String:
	return "Page %d/%d" % [page + 1, pages]

static func HeldEscrow(state : Dictionary) -> int:
	var held : int = 0
	for row in state.get("orders", []):
		held += int((row as Dictionary).get("escrow_gold", 0))
	return held

# Detalhe do anúncio selecionado. O fee do criador é o percentual que o servidor
# declarou (`creator_fee_pct`) aplicado sobre o ask — a mesma conta do kernel, e
# mostrada ANTES do clique porque é irreversível.
static func DetailLine(listing : Dictionary, state : Dictionary) -> String:
	if listing.is_empty():
		return "Select a listing to see the item, price and seller."
	var preview : Dictionary = PreviewBuy(listing, state)
	var flags : String = "★ highlighted • " if int(listing.get("highlight", 0)) == 1 else ""
	var mine : String = " (your listing)" if bool(listing.get("mine", false)) else ""
	return "%s#%d — %s x%d • %d gold • seller: %s%s\nYour gold after: %d • seller nets %d gold%s" % [
		flags, int(listing.get("id", 0)), str(listing.get("name", "?")), int(listing.get("qty", 1)),
		int(preview["price"]), str(listing.get("seller", "?")), mine, int(preview["after"]),
		int(preview["seller_net"]),
		(" (after %d%% creator fee)" % int(preview["fee_pct"])) if int(preview["creator_fee"]) > 0 else ""]

# ------------------------------------------------------------------ prévias (puras)
# Cada uma devolve o par "quanto sai / o que sobra" com o `affordable` decidido
# contra o saldo QUE O SERVIDOR REPORTOU. O painel não reimplementa taxa nenhuma:
# os fee chegam no payload da janela (`list_fee_gems`, `highlight_fee_gems`,
# `slot_cost_gems`, `creator_fee_pct`).

static func PreviewBuy(listing : Dictionary, state : Dictionary) -> Dictionary:
	var price : int = int(listing.get("price_gold", listing.get("price", 0)))
	var gold : int = int(state.get("gold", 0))
	var feePct : int = int(state.get("creator_fee_pct", 0))
	var creatorFee : int = maxi(0, roundi(float(price) * float(feePct) / 100.0))
	return {
		"price" = price,
		"gold" = gold,
		"after" = gold - price,
		"affordable" = gold >= price,
		"creator_fee" = creatorFee,
		"seller_net" = price - creatorFee,
		"fee_pct" = feePct,
	}

static func PreviewList(priceGold : int, count : int, state : Dictionary) -> Dictionary:
	var fee : int = int(state.get("list_fee_gems", 0))
	var gems : int = int(state.get("gems", 0))
	var feePct : int = int(state.get("creator_fee_pct", 0))
	var creatorFee : int = maxi(0, roundi(float(priceGold) * float(feePct) / 100.0))
	return {
		"price" = priceGold,
		"count" = count,
		"fee_gems" = fee,
		"gems" = gems,
		"gems_after" = gems - fee,
		"affordable" = gems >= fee,
		"creator_fee" = creatorFee,
		"net" = priceGold - creatorFee,
		"full_net" = priceGold,
	}

static func PreviewHighlight(state : Dictionary) -> Dictionary:
	var fee : int = int(state.get("highlight_fee_gems", 0))
	var gems : int = int(state.get("gems", 0))
	return {"fee_gems" = fee, "gems" = gems, "gems_after" = gems - fee, "affordable" = gems >= fee}

# Custo do PRÓXIMO slot: o servidor já entrega `slot_cost_gems` como o valor da
# próxima compra, então a fórmula base × (extra+1) não mora aqui.
static func PreviewSlot(state : Dictionary) -> Dictionary:
	var cost : int = int(state.get("slot_cost_gems", 0))
	var gems : int = int(state.get("gems", 0))
	var cap : int = int(state.get("cap", 0))
	return {"fee_gems" = cost, "gems" = gems, "gems_after" = gems - cost,
		"affordable" = cost > 0 and gems >= cost, "cap_after" = cap + 1}

# Bid: o ouro NÃO vai para o vendedor aqui — vai para escrow, e a linha diz
# exatamente isso. Cap de ordens e teto de quantidade vêm no payload (`bid_cap`,
# `bid_max_quantity`), porque a UI não tem que adivinhar regra do servidor.
static func PreviewBid(count : int, unitPrice : int, state : Dictionary) -> Dictionary:
	var escrow : int = count * unitPrice
	var gold : int = int(state.get("gold", 0))
	var cap : int = int(state.get("bid_cap", 0))
	var open : int = (state.get("orders", []) as Array).size()
	var maxQty : int = int(state.get("bid_max_quantity", 1))
	return {
		"escrow" = escrow,
		"gold" = gold,
		"after" = gold - escrow,
		"affordable" = escrow > 0 and gold >= escrow,
		"cap" = cap,
		"open" = open,
		"max_qty" = maxQty,
		"has_room" = cap <= 0 or open < cap,
		"within_quantity" = maxQty <= 0 or count <= maxQty,
	}

# ------------------------------------------------------------------ memórias (059)

# Preço REALIZADO, lido de `ah_price_history` no servidor. Não é mais a memória
# da janela: duas contas abertas na mesma hora leem o mesmo número, e ele
# sobrevive a fechar a tela.
static func SoldLine(recent : Array, summary : Dictionary) -> String:
	if recent.is_empty():
		return "Recently sold: nothing on record yet."
	var parts : PackedStringArray = PackedStringArray()
	for row in recent.slice(0, SoldSamples):
		var d : Dictionary = row
		parts.append("x%d @ %d/unit" % [int(d.get("count", 1)), int(d.get("unit_price", 0))])
	return "Recently sold on record (%d): %s • mean %d/unit • lowest ask %d/unit" % [
		int(summary.get("samples", recent.size())), ", ".join(parts),
		int(summary.get("avg_unit", 0)), int(summary.get("ask_unit", 0))]

static func OrdersLine(orders : Array) -> String:
	if orders.is_empty():
		return "Your bids: none open."
	var parts : PackedStringArray = PackedStringArray()
	for row in orders:
		var d : Dictionary = row
		parts.append("#%d x%d at <= %d" % [int(d.get("id", 0)), int(d.get("quantity", 1)), int(d.get("unit_price", 0))])
	return "Your bids (%d open, gold held in escrow): %s" % [orders.size(), ", ".join(parts)]

static func OrderRowText(order : Dictionary) -> String:
	var itemName : String = str(order.get("item_name", ""))
	if itemName.is_empty():
		itemName = "item %d" % int(order.get("item_id", 0))
	return "Bid #%d • %s x%d • up to %d/unit • %d gold held — tap to cancel" % [
		int(order.get("id", 0)), itemName, int(order.get("quantity", 1)),
		int(order.get("unit_price", 0)), int(order.get("escrow_gold", 0))]

static func EmptyLine(hasListings : bool) -> String:
	return "No listing matches your filters." if hasListings else "No open listings right now."

# ------------------------------------------------------------------ veredito (059)
# Texto estável do que o servidor respondeu. Os `reason` são os de
# `Server._AuctionResult`, nunca livres — por isso cada um tem linha no catálogo
# i18n (§13) e dá para traduzir sem adivinhar. `listing` é o id do anúncio para
# buy/cancel/list/highlight e o id da ORDEM para bid/bid_cancel: a UI imprime o
# que o servidor devolveu, nunca inventa um.

static func ReasonLine(reason : String) -> String:
	if reason.is_empty():
		return PlayerReasons.Describe("unavailable")
	return PlayerReasons.Describe(reason)

static func TradeLine(result : Dictionary) -> String:
	var ok : bool = bool(result.get("ok", false))
	var action : String = str(result.get("action", ""))
	if ok:
		match action:
			"buy":
				return "Purchase complete — gold now %d" % int(result.get("gold", 0))
			"list":
				return "Listing #%d published (listing fee spent)" % int(result.get("listing", 0))
			"cancel":
				return "Listing #%d cancelled (items returned, listing fee kept)" % int(result.get("listing", 0))
			"highlight":
				return "Listing #%d highlighted — gems now %d" % [int(result.get("listing", 0)), int(result.get("gems", 0))]
			"slot":
				return "Open slot bought — gems now %d" % int(result.get("gems", 0))
			"bid":
				return "Bid #%d placed — gold now %d (the rest is held until it fills or you cancel)" % [
					int(result.get("listing", 0)), int(result.get("gold", 0))]
			"bid_cancel":
				return "Bid #%d cancelled — escrow released, gold now %d" % [
					int(result.get("listing", 0)), int(result.get("gold", 0))]
			_:
				return "Auction: done"
	return "Auction rejected: " + ReasonLine(str(result.get("reason", "")))

# ------------------------------------------------------------------ nós prontos

static func ListingRow(listing : Dictionary, selected : bool, onSelect : Callable) -> Button:
	var row := Button.new()
	row.name = "AuctionRow_%d" % int(listing.get("id", 0))
	row.text = ListingRowText(listing)
	row.toggle_mode = selected
	row.button_pressed = selected
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if onSelect.is_valid():
		row.pressed.connect(onSelect)
	return row

static func OrderRow(order : Dictionary, onCancel : Callable) -> Button:
	var row := Button.new()
	row.name = "AuctionOrder_%d" % int(order.get("id", 0))
	row.text = OrderRowText(order)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# `mine` é o servidor que diz (a linha é da CONTA; o cancelamento é pelo
	# PERSONAGEM). Sem isto, um segundo personagem da mesma conta veria um botão
	# que o serviço recusaria.
	row.disabled = not bool(order.get("mine", false))
	if onCancel.is_valid():
		row.pressed.connect(onCancel)
	return row
