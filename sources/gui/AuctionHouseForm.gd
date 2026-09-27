extends RefCounted
class_name AuctionHouseForm

# A ÁRVORE do painel do leilão, montada fora do `AuctionHousePanel` (059, e o
# mesmo corte de `GuildPanelRows`). O painel herda de `WindowPanel` e não pode
# herdar de mais nada, então quem constrói é um RefCounted estático que recebe os
# `Callable` das ações e devolve as referências de nó — assim o `_ready` do painel
# fica dizendo QUAL estado cada seção mostra, em vez de escrever 180 linhas de
# `.new()` + `.name =`.
#
# Nada aqui decide gasto: os campos só entreguem texto/número a quem confirma. O
# único caminho que fala com a rede continua sendo `AuctionHousePanel.ConfirmPending`.
#
# Os nomes de nó são CONTRATO: a cena `presets/gui/AuctionHouse.tscn`, o
# `tests/hud_wiring_test.gd` (árvore real) e o `tests/panel_fit_test.gd` (retângulos)
# procuram por eles. Mudar um nome muda as três.

# Par quantidade/preço da fila de venda e da fila de bid. Uma classe em vez de
# posicional: o valor que sai daqui alimenta `RequestList`/`RequestBid`, e ordem
# trocada é ouro onde era item.
class Amounts:
	var count : int = 0
	var price : int = 0

	static func Of(count : int, price : int) -> Amounts:
		var a := Amounts.new()
		a.count = count
		a.price = price
		return a

static func Build(root : Node, handlers : Dictionary) -> Dictionary:
	var refs : Dictionary = {}
	refs["title"] = AuctionHouseRows.Header(root, "AuctionTitle", "Auction House", 18)
	# Saldo e estado do mercado: os números vêm do payload do servidor, nunca da
	# memória do painel.
	refs["balance"] = AuctionHouseRows.LabelOf(root, "AuctionBalance", "Gold: 0 • Gems: 0 • Listings: 0/0")
	refs["status"] = AuctionHouseRows.LabelOf(root, "AuctionStatus", "Loading listings…")

	_BuildSearch(root, refs, handlers)
	_BuildList(root, refs, handlers)
	refs["detail"] = AuctionHouseRows.LabelOf(root, "AuctionDetail", "Select a listing to see the item, price and seller.")
	_BuildActions(root, refs, handlers)
	refs["confirmRow"] = _BuildConfirm(root, refs, handlers)
	_BuildSell(root, refs, handlers)
	_BuildBid(root, refs, handlers)
	_BuildMemory(root, refs)
	return refs

# Busca por nome + teto de preço. Os dois são PEDIDO AO SERVIDOR (059b): o teto
# vira `price_gold <= ?` no SQL e o nome, quando resolve para um único item,
# vira `item_id = ?`. O recorte local que o pai faz é refinamento do bloco.
static func _BuildSearch(root : Node, refs : Dictionary, handlers : Dictionary) -> void:
	var search := LineEdit.new()
	search.name = "AuctionSearch"
	search.placeholder_text = "Search by name"
	var onSearch : Callable = handlers.get("search", Callable())
	if onSearch.is_valid():
		search.text_changed.connect(onSearch)
	root.add_child(search)
	refs["search"] = search
	var filterRow := HBoxContainer.new()
	root.add_child(filterRow)
	var maxPrice := LineEdit.new()
	maxPrice.name = "AuctionMaxPrice"
	maxPrice.placeholder_text = "Max price (gold)"
	maxPrice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var onMaxPrice : Callable = handlers.get("maxPrice", Callable())
	if onMaxPrice.is_valid():
		maxPrice.text_changed.connect(onMaxPrice)
	filterRow.add_child(maxPrice)
	refs["maxPrice"] = maxPrice
	var refresh := Button.new()
	refresh.name = "AuctionRefresh"
	refresh.text = "Refresh"
	var onRefresh : Callable = handlers.get("refresh", Callable())
	if onRefresh.is_valid():
		refresh.pressed.connect(onRefresh)
	filterRow.add_child(refresh)
	refs["refresh"] = refresh

# Vitrine + régua de páginas. "Previous/Next" são o par que atravessa BLOCOS: o
# painel pergunta a página ao servidor quando o bloco entregue acaba, e é por
# isso que o teto de 40 linhas deixou de ser teto do catálogo.
static func _BuildList(root : Node, refs : Dictionary, handlers : Dictionary) -> void:
	var listBox := VBoxContainer.new()
	listBox.name = "ListingBox"
	root.add_child(listBox)
	refs["listBox"] = listBox
	var pager := HBoxContainer.new()
	pager.name = "AuctionPager"
	root.add_child(pager)
	var onPage : Callable = handlers.get("page", Callable())
	var prev := Button.new()
	prev.name = "AuctionPrev"
	prev.text = "Previous"
	if onPage.is_valid():
		prev.pressed.connect(onPage.bind(-1))
	pager.add_child(prev)
	var pageLabel := Label.new()
	pageLabel.name = "AuctionPage"
	pageLabel.text = "Page 1/1"
	pager.add_child(pageLabel)
	refs["pageLabel"] = pageLabel
	var next := Button.new()
	next.name = "AuctionNext"
	next.text = "Next"
	if onPage.is_valid():
		next.pressed.connect(onPage.bind(1))
	pager.add_child(next)

static func _BuildActions(root : Node, refs : Dictionary, handlers : Dictionary) -> void:
	# Os três botões só ARMAM a prévia (`Request*`): nenhum deles fala com a rede
	# sem `ConfirmPending()`.
	var actions := HBoxContainer.new()
	actions.name = "AuctionActions"
	root.add_child(actions)
	refs["buy"] = _ActionButton(actions, "AuctionBuyButton", "Buy", true, handlers.get("buy", Callable()))
	refs["cancel"] = _ActionButton(actions, "AuctionCancelButton", "Cancel listing", true, handlers.get("cancel", Callable()))
	refs["highlight"] = _ActionButton(actions, "AuctionHighlightButton", "Highlight", true, handlers.get("highlight", Callable()))

static func _ActionButton(parent : Node, nodeName : String, text : String, disabled : bool, onPress : Callable) -> Button:
	var button := Button.new()
	button.name = nodeName
	button.text = text
	button.disabled = disabled
	if onPress.is_valid():
		button.pressed.connect(onPress)
	parent.add_child(button)
	return button

# Linha de confirmação: o modal (`UICommons.MessageBox`) é o caminho normal, mas
# em mobile/web o diálogo pode não estar montado — sem fallback o jogador ficaria
# com um botão que não faz nada. Nenhum dos dois envia sozinho: os dois chamam
# `ConfirmPending()`.
static func _BuildConfirm(root : Node, refs : Dictionary, handlers : Dictionary) -> HBoxContainer:
	var confirmRow := HBoxContainer.new()
	confirmRow.name = "AuctionConfirmRow"
	confirmRow.visible = false
	root.add_child(confirmRow)
	refs["confirmLabel"] = AuctionHouseRows.LabelOf(confirmRow, "AuctionConfirmText", "")
	(refs["confirmLabel"] as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ActionButton(confirmRow, "AuctionConfirm", "Confirm", false, handlers.get("confirm", Callable()))
	_ActionButton(confirmRow, "AuctionAbort", "Cancel", false, handlers.get("abort", Callable()))
	return confirmRow

static func _BuildSell(root : Node, refs : Dictionary, handlers : Dictionary) -> void:
	AuctionHouseRows.Header(root, "AuctionSellTitle", "Sell an item", 14)
	var sellOption := OptionButton.new()
	sellOption.name = "AuctionSellItem"
	root.add_child(sellOption)
	refs["sellOption"] = sellOption
	var sellRow := HBoxContainer.new()
	sellRow.name = "AuctionSellRow"
	root.add_child(sellRow)
	refs["sellCount"] = _SpinBox(sellRow, "AuctionSellCount")
	var sellPrice := LineEdit.new()
	sellPrice.name = "AuctionSellPrice"
	sellPrice.placeholder_text = "Price (gold)"
	sellPrice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sellRow.add_child(sellPrice)
	refs["sellPrice"] = sellPrice
	_ActionButton(sellRow, "AuctionListButton", "List for sale", false, handlers.get("list", Callable()))
	_ActionButton(root, "AuctionSlotButton", "Buy open slot", false, handlers.get("slot", Callable()))

# Demanda (059c): o mesmo item da vitrine, uma quantidade e um teto por unidade.
# O ouro sai para escrow na hora do "Confirm" — é o mesmo freio de gasto
# irreversível da compra, e a prévia diz que o ouro NÃO vai para ninguém até lá.
static func _BuildBid(root : Node, refs : Dictionary, handlers : Dictionary) -> void:
	AuctionHouseRows.Header(root, "AuctionBidTitle", "Bid on an item (gold is held in escrow)", 14)
	var bidRow := HBoxContainer.new()
	bidRow.name = "AuctionBidRow"
	root.add_child(bidRow)
	refs["bidCount"] = _SpinBox(bidRow, "AuctionBidCount")
	var bidPrice := LineEdit.new()
	bidPrice.name = "AuctionBidPrice"
	bidPrice.placeholder_text = "Max gold per unit"
	bidPrice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bidRow.add_child(bidPrice)
	refs["bidPrice"] = bidPrice
	_ActionButton(bidRow, "AuctionBidButton", "Place bid", false, handlers.get("bid", Callable()))

# As duas pernas de estado que deixaram de ser memória de sessão: preço realizado
# (`ah_price_history`) e ordens da conta (`ah_buy_order`). Cada ordem em pé é uma
# linha clicável — rótulo único não dá para desfazer uma ordem específica.
static func _BuildMemory(root : Node, refs : Dictionary) -> void:
	refs["history"] = AuctionHouseRows.LabelOf(root, "AuctionSold", "Recently sold: nothing on record yet.")
	refs["orders"] = AuctionHouseRows.LabelOf(root, "AuctionOrders", "Your bids: none open.")
	var orderBox := VBoxContainer.new()
	orderBox.name = "AuctionOrderBox"
	root.add_child(orderBox)
	refs["orderBox"] = orderBox

static func _SpinBox(parent : Node, nodeName : String) -> SpinBox:
	var spin := SpinBox.new()
	spin.name = nodeName
	spin.min_value = 1
	spin.max_value = 99
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spin)
	return spin

# ------------------------------------------------------------------ leituras de campo
# Uma conversão por campo: o `Request*` do painel é quem decide se o argumento
# vale (e explica na linha de prévia quando não vale), então aqui só sai número —
# zero quando o nó ainda não existe, que é o estado de um painel montado fora de
# cena em teste headless.
static func SellAmounts(refs : Dictionary) -> Amounts:
	return _AmountsOf(refs.get("sellCount"), refs.get("sellPrice"))

static func BidAmounts(refs : Dictionary) -> Amounts:
	return _AmountsOf(refs.get("bidCount"), refs.get("bidPrice"))

static func _AmountsOf(countField : Variant, priceField : Variant) -> Amounts:
	var count : int = int((countField as SpinBox).value) if countField is SpinBox else 0
	var price : int = 0
	if priceField is LineEdit:
		price = str((priceField as LineEdit).text).to_int()
	elif priceField is SpinBox:
		price = int((priceField as SpinBox).value)
	return Amounts.Of(count, price)
