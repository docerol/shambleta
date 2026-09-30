# SOM-IDLE P1-1 / P1-2: a Auction House JOGÁVEL (não mais "UI em desenvolvimento").
#
# Herda de `AuctionHouseWindow` de propósito: filtros, ordenação por preço e a
# janela de leitura daquela tela já estavam prontos e testados
# (tests/IdleTests.gd:3932) — o que faltava era o resto do leilão, não outra
# janela concorrente. Aqui entram a lista paginada com linhas selecionáveis, o
# detalhe do anúncio (item, preço em GOLD, vendedor), a venda/cancelamento e,
# sobretudo, a CONFIRMAÇÃO antes de gastar: nenhum clique em "Buy" toca a rede.
#
# Por que a confirmação é estrutural e não cosmética: comprar no leilão move ouro
# e consome o anúncio — é irreversível para o jogador. O único caminho que emite
# RPC é `ConfirmPending()`; `RequestBuy()`/`RequestList()`/`RequestBid()`/… só
# armam o estado pendente. O harness `tests/spend_confirm_test.gd` injeta
# `SendHook` e prova que zero dispatches acontecem sem confirmação, e
# `tests/auction_house_wiring_test.gd` prova o outro lado do mesmo contrato: que
# CADA alvo que o painel sabe emitir tem braços até o `Network` real — porque a
# costura de teste intercepta ANTES do dispatch, e um alvo sem braço no `match`
# era verde aqui e `push_error` na tela do jogador (foi assim que a página, a bid
# e o cancelamento de bid da migração 059 ficaram presos no serviço).
#
# Os números mostrados NA PRÉVIA vêm do servidor (`GetAuctionListings`/
# `GetAuctionPage` entregam taxa de anúncio, taxa do criador, gold, gems, slots,
# preço realizado e as ordens da conta) — a UI não inventa custo.
#
# O arquivo é só estado + decisão. As três fatias coesas saíram para módulos
# próprios, cada uma com a sua régua: `AuctionHouseRows` (linha e prévia, tudo
# puro), `AuctionHouseForm` (a árvore de nós) e `AuctionHouseQuery` (a aritmética
# de pedir página ao servidor).
extends AuctionHouseWindow
class_name AuctionHousePanel

# Costura de teste: quando definido, `NetworkSend` chama este Callable em vez do
# `Network`. Producao nunca seta isso. NOTE: ela intercepta DEPOIS do portão de
# nomes (`_send`) — é o que deixa o harness de wiring abaixo provar "o painel
# sabe emitir X" mesmo sem tocarmos a rede.
var SendHook : Callable

const PageSize : int = 8

# Toda a UI de leilão sai para aqui, um `Request*` armado para aqui, e a janela
# de leitura do servidor é uma função destes dois. `SentTargets` é o rastro: sem
# ele, "emitiu" só seria observável com a rede ligada.
const NetworkTargets : Array[String] = [
	"AuctionBuy", "AuctionCancel", "AuctionHighlight", "AuctionBidCancel",
	"AuctionList", "AuctionBid", "GetAuctionPage", "GetAuctionListings", "AuctionBuySlot",
]

var _state : Dictionary = {}
var _page : int = 0			# página DENTRO do bloco entregue
var _shownOffset : int = 0		# offset do bloco que o servidor entregou
var _askedOffset : int = 0		# offset que nós pedimos (o próximo a chegar)
var _askedMaxPrice : int = -1		# último teto de preço pedido ao servidor
var _askedItemID : int = -1		# último item pedido ao servidor (-1 = nunca pedi)
var _selected : int = 0			# id do anúncio selecionado (0 = nenhum)
var _pending : Dictionary = {}	# {kind, listing, args, line}
var _tradeLine : String = ""
var SentTargets : Array[String] = []

# Campos de nó: continuam sendo OBRIGATÓRIOS fora de cena (todo painel de `_.gd`
# tem um `_ready` que aborta escondido — ver `AuctionHouseWindow`) e a cena só
# entrega o TitleBar, nunca estes nós. As referências do resto da árvore vivem em
# `_refs`.
var _refs : Dictionary = {}
var _balanceLabel : Label = null
var _statusLabel : Label = null
var _detailLabel : Label = null
var _pageLabel : Label = null
var _confirmRow : HBoxContainer = null
var _confirmLabel : Label = null
var _sellOption : OptionButton = null
var _buyButton : Button = null
var _cancelButton : Button = null
var _highlightButton : Button = null
var _sellItems : Array = []

# ------------------------------------------------------------------ construção
func _ready():
	# O `AuctionHouseWindow` pai empilha Labels num PanelContainer; a árvore aqui é
	# um VBox único dentro da rolagem, e os dois campos herdados (`_listBox`,
	# `_historyLabel`) continuam sendo os alvos de `_render_list`/`_render_history`.
	name = "AuctionHouse"
	custom_minimum_size = Vector2(360, 420)

	var root := VBoxContainer.new()
	root.name = "AuctionRoot"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Nascendo da cena (presets/gui/AuctionHouse.tscn), o TitleBar é quem dá o botão
	# de fechar e o conteúdo entra num ScrollContainer DEBAIXO dele: a janela tem
	# tamanho fixo e a lista cresce com o mercado — sem rolagem, corte real no alvo
	# web/mobile (§13). Instanciado fora de cena (teste headless), segue colado.
	var host : Node = get_node_or_null("Layout")
	if host != null:
		var scroll := ScrollContainer.new()
		scroll.name = "AuctionScroll"
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		host.add_child(scroll)
		scroll.add_child(root)
	else:
		add_child(root)

	_refs = AuctionHouseForm.Build(root, _handlers())
	_balanceLabel = _refs["balance"] as Label
	_statusLabel = _refs["status"] as Label
	_detailLabel = _refs["detail"] as Label
	_pageLabel = _refs["pageLabel"] as Label
	_confirmRow = _refs["confirmRow"] as HBoxContainer
	_confirmLabel = _refs["confirmLabel"] as Label
	_sellOption = _refs["sellOption"] as OptionButton
	_buyButton = _refs["buy"] as Button
	_cancelButton = _refs["cancel"] as Button
	_highlightButton = _refs["highlight"] as Button
	_listBox = _refs["listBox"] as VBoxContainer
	_historyLabel = _refs["history"] as Label
	_render_list()
	_render_history()

# Um dicionário, e é ele que amarra cada botão ao seu `Request*`. Os handlers de
# gasto (`buy`/`cancel`/`highlight`/`list`/`slot`/`bid`) apenas ARMAM a prévia.
func _handlers() -> Dictionary:
	return {
		"search" = _on_search_changed, "maxPrice" = _on_max_price_changed,
		"refresh" = _on_refresh_pressed, "page" = _on_page_pressed,
		"buy" = _on_buy_pressed, "cancel" = _on_cancel_pressed,
		"highlight" = _on_highlight_pressed, "list" = _on_list_pressed,
		"slot" = _on_slot_pressed, "bid" = _on_bid_pressed,
		"confirm" = ConfirmPending, "abort" = CancelPending,
	}

# ------------------------------------------------------------------ estado (servidor)
# `state` é o payload de `Network.AuctionListings`, que hoje também responde por
# `GetAuctionPage`. Sem `ok` (ex.: não logado) a janela diz o motivo em vez de
# fingir um mercado vazio.
func ShowState(state : Dictionary) -> void:
	_state = state
	if not bool(state.get("ok", false)):
		if _statusLabel:
			_statusLabel.text = ReasonLine(str(state.get("reason", "unavailable")))
		return
	if _balanceLabel:
		_balanceLabel.text = BalanceLine(state)
	if _statusLabel:
		_statusLabel.text = StatusLine(state)
	# `name`/`type` são o que o `FilterListings` herdado usa; preços seguem em gold.
	var rows : Array = []
	for row in state.get("listings", []):
		var entry : Dictionary = Dictionary(row).duplicate(true)
		var itemID : int = int(entry.get("item_id", 0))
		entry["name"] = ItemName(itemID)
		entry["type"] = SlotLabel(itemID)
		entry["price"] = int(entry.get("price_gold", 0))
		entry["qty"] = int(entry.get("count", 1))
		rows.append(entry)
	RefreshAuction(rows)
	# Bloco novo entregue pelo servidor ⇒ recomeça do topo da fatia desenhada
	# (sem isto o "Next" pediria offset e a UI mostraria página vazia).
	if int(state.get("offset", 0)) != _shownOffset:
		_shownOffset = int(state.get("offset", 0))
		_askedOffset = _shownOffset
		_page = 0
	if _selected > 0 and FindListing(_selected).is_empty():
		_selected = 0
	_render_detail()
	_render_history()

func ShowTradeResult(result : Dictionary) -> void:
	_tradeLine = TradeLine(result)
	if _statusLabel:
		_statusLabel.text = _tradeLine
	# O gasto aconteceu: a prévia pendente não vale mais (saldo mudou, e no
	# "list" o item saiu do inventário). Limpar aqui é o que impede um segundo
	# "Confirm" de repetir uma ação sobre números velhos.
	CancelPending()
	# Compra, venda e bid movem gold em `stat.gp`, itens e escrow: o ouro do HUD
	# só acompanha quando o servidor reenvia o estado de economia, e o preço
	# realizado / as ordens em pé vêm na própria janela de anúncios.
	RequestListings()

# ------------------------------------------------------------------ texto (módulo)
# Finas por delegação: quem lê o payload é `AuctionHouseRows`, e a tela é o que
# o servidor respondeu. `TradeLine`/`ReasonLine` são chamada pública — o cliente
# as usa para avisar o veredito com a janela fechada (`Client.gd:526`).
func BalanceLine(state : Dictionary) -> String:
	return AuctionHouseRows.BalanceLine(state)

func StatusLine(state : Dictionary) -> String:
	return AuctionHouseRows.StatusLine(state)

func DetailLine(listing : Dictionary, state : Dictionary) -> String:
	return AuctionHouseRows.DetailLine(listing, state)

func TradeLine(result : Dictionary) -> String:
	return AuctionHouseRows.TradeLine(result)

func ReasonLine(reason : String) -> String:
	return AuctionHouseRows.ReasonLine(reason)

func PreviewBuy(listing : Dictionary, state : Dictionary) -> Dictionary:
	return AuctionHouseRows.PreviewBuy(listing, state)

func PreviewList(priceGold : int, count : int, state : Dictionary) -> Dictionary:
	return AuctionHouseRows.PreviewList(priceGold, count, state)

func PreviewHighlight(state : Dictionary) -> Dictionary:
	return AuctionHouseRows.PreviewHighlight(state)

func PreviewSlot(state : Dictionary) -> Dictionary:
	return AuctionHouseRows.PreviewSlot(state)

func PreviewBid(count : int, unitPrice : int, state : Dictionary) -> Dictionary:
	return AuctionHouseRows.PreviewBid(count, unitPrice, state)

func SlotLabel(itemID : int) -> String:
	var cell : ItemCell = DB.ItemsDB.get(itemID, null)
	if cell == null:
		return "other"
	return "equip" if cell.slot >= ActorCommons.Slot.FIRST_EQUIPMENT and cell.slot < ActorCommons.Slot.LAST_EQUIPMENT else "other"

func ItemName(itemID : int) -> String:
	var cell : ItemCell = DB.ItemsDB.get(itemID, null)
	return cell.name if cell != null else "Item %d" % itemID

# ------------------------------------------------------------------ página (servidor)
# 059(b): quem pagina e quem filtra é o SERVIDOR (`GetAuctionPage` → OFFSET e
# `WHERE price_gold <= ? AND item_id = ?`). O `PageSize` daqui é a fatia DESENHADA
# dentro do bloco de `page_size` linhas que chegou; ao acabar o bloco, o painel
# PEDE a próxima janela em vez de fingir que acabou o mercado. A régua de páginas
# usa o `total` do servidor, não o tamanho do recorte local — era assim que a
# janela antiga mostrava "1/1" para um mercado com mil anúncios.
func BlockSize() -> int:
	return maxi(PageSize, int(_state.get("page_size", PageSize)))

func LocalPages() -> int:
	return AuctionHouseQuery.BlockPages((_listings as Array).size(), PageSize)

func TotalPages() -> int:
	return AuctionHouseQuery.TotalPages(int(_state.get("total", 0)), PageSize)

func AbsolutePage() -> int:
	return int(_shownOffset / maxi(1, BlockSize())) * maxi(1, int(BlockSize() / PageSize)) + _page

func RequestPage(delta : int) -> void:
	var next : int = AuctionHouseQuery.NextOffset(_askedOffset, delta, BlockSize(), int(_state.get("total", 0)))
	if next == _askedOffset:
		return
	_askedOffset = next
	RequestListings()

# Nome → item_id no servidor. Texto que não resolve para UM item do catálogo
# local não vira filtro SQL (0 = "sem filtro"), e continua refinando por
# substring dentro da página.
func QueryItemID() -> int:
	return AuctionHouseQuery.ItemIDFor(_query, DB.ItemsDB)

# A única decisão de QUE canal de leitura usar: sem filtro e sem offset, o canal
# histórico da janela (`GetAuctionListings`, que hoje é a página 0); com
# qualquer um dos dois, a página pedida ao servidor com os filtros dentro.
func RequestListings() -> void:
	if _askedOffset > 0 or _askedMaxPrice > 0 or _askedItemID > 0:
		_send("GetAuctionPage", [_askedOffset, maxi(0, _askedMaxPrice), maxi(0, _askedItemID)])
	else:
		_send("GetAuctionListings", [])

# ------------------------------------------------------------------ render
# Sobrescreve o `_render_list` do pai: as linhas deixam de ser Labels inertes e
# viram botões selecionáveis, com a página atual e o destaque do próprio anúncio.
func _render_list() -> void:
	if _listBox == null:
		return
	AuctionHouseRows.Clear(_listBox)
	var shown : Array = FilterListings(_listings, _query, _typeFilter, _maxPrice)
	_page = clampi(_page, 0, maxi(0, LocalPages() - 1))
	_syncServerWindow()
	if shown.is_empty():
		AuctionHouseRows.LabelOf(_listBox, "AuctionEmpty", AuctionHouseRows.EmptyLine(not _listings.is_empty()))
		if _pageLabel:
			_pageLabel.text = AuctionHouseRows.PageLine(0, 1)
		return
	for entry in AuctionHouseQuery.Slice(shown, _page, PageSize):
		var listing : Dictionary = entry
		var listingID : int = int(listing.get("id", 0))
		_listBox.add_child(AuctionHouseRows.ListingRow(listing, listingID == _selected, _on_row_pressed.bind(listingID)))
	if _pageLabel:
		_pageLabel.text = AuctionHouseRows.PageLine(AbsolutePage(), TotalPages())

# O teto de preço e o nome digitado SÓ valem se forem ao servidor: um mercado com
# mais anúncios do que o bloco entregue tem linhas abaixo do teto em páginas que
# ainda não chegaram. Pedir de novo quando (e só quando) o pedido mudou evita o
# RPC por tecla.
func _syncServerWindow() -> void:
	var wantPrice : int = maxi(0, _maxPrice)
	var wantItem : int = maxi(0, QueryItemID())
	if wantPrice == _askedMaxPrice and wantItem == _askedItemID:
		return
	_askedMaxPrice = wantPrice
	_askedItemID = wantItem
	_askedOffset = 0
	RequestListings()

func _render_detail() -> void:
	var listing : Dictionary = SelectedListing()
	var mine : bool = bool(listing.get("mine", false))
	# Quem seleciona vê apenas as ações possíveis para aquele anúncio: comprar o
	# dos outros, desfazer/destacar o próprio. O servidor já recusa o resto — o
	# botão desligado existe para não prometer um clique que ia falhar.
	if _buyButton:
		_buyButton.disabled = listing.is_empty() or mine
	if _cancelButton:
		_cancelButton.disabled = not mine
	if _highlightButton:
		_highlightButton.disabled = not mine
	if _detailLabel == null:
		return
	if listing.is_empty():
		_detailLabel.text = DetailLine({}, {})
		return
	var lines : Array[String] = [DetailLine(listing, _state)]
	if mine:
		lines.append("Your listing: you can cancel it or pay %d gems to highlight it." % int(_state.get("highlight_fee_gems", 0)))
	else:
		var preview : Dictionary = PreviewBuy(listing, _state)
		if not bool(preview["affordable"]):
			lines.append("You cannot afford this yet.")
	_detailLabel.text = "\n".join(lines)

# As duas pernas de estado que deixaram de ser memória de sessão: o preço
# realizado vem de `ah_price_history` no servidor (o pai mantém o `RecordSale` de
# sessão para as janelas antigas; este painel não o usa, porque histórico que só
# existe nesta tela não é mercado) e as ordens em pé vêm de `ah_buy_order`, com
# o escrow declarado linha a linha.
func _render_history() -> void:
	if _historyLabel != null:
		_historyLabel.text = AuctionHouseRows.SoldLine(_state.get("sold_recent", []) as Array, _state.get("sold", {}) as Dictionary)
	if _ordersLabel() != null:
		_ordersLabel().text = AuctionHouseRows.OrdersLine(_state.get("orders", []) as Array)
	var box : VBoxContainer = _refs.get("orderBox", null) as VBoxContainer
	if box != null:
		AuctionHouseRows.Clear(box)
		for row in _state.get("orders", []):
			var order : Dictionary = row
			var orderID : int = int(order.get("id", 0))
			box.add_child(AuctionHouseRows.OrderRow(order, _on_bid_cancel_pressed.bind(orderID)))

func _ordersLabel() -> Label:
	return _refs.get("orders", null) as Label

func SelectedListing() -> Dictionary:
	return FindListing(_selected)

func FindListing(listingID : int) -> Dictionary:
	for entry in _listings:
		if entry is Dictionary and int((entry as Dictionary).get("id", 0)) == listingID:
			return entry as Dictionary
	return {}

func FindBuyOrder(orderID : int) -> Dictionary:
	for row in _state.get("orders", []):
		if int((row as Dictionary).get("id", 0)) == orderID:
			return row as Dictionary
	return {}

# ------------------------------------------------------------------ ações
# As prévias abaixo saem do payload do servidor e NENHUMA delas toca a rede: o
# clique arma `_pending`, e o único caminho que emite é `ConfirmPending()`.
func RequestBuy(listingID : int) -> bool:
	var listing : Dictionary = FindListing(listingID)
	if listing.is_empty() or bool(listing.get("mine", false)):
		return false
	var preview : Dictionary = PreviewBuy(listing, _state)
	if not bool(preview["affordable"]):
		_Ask("You cannot afford this listing: %d gold, you have %d." % [int(preview["price"]), int(preview["gold"])])
		return false
	_Arm({
		"kind" = "buy",
		"listing" = listingID,
		"method" = "AuctionBuy",
		"args" = [listingID],
		"line" = "Spend %d gold on %s x%d? Your gold would go from %d to %d." % [
			int(preview["price"]), str(listing.get("name", "?")), int(listing.get("qty", 1)),
			int(preview["gold"]), int(preview["after"])],
	})
	return true

func RequestCancel(listingID : int) -> bool:
	var listing : Dictionary = FindListing(listingID)
	if listing.is_empty() or not bool(listing.get("mine", false)):
		return false
	_Arm({
		"kind" = "cancel",
		"listing" = listingID,
		"method" = "AuctionCancel",
		"args" = [listingID],
		"line" = "Cancel listing #%d? The items come back; the %d-gem listing fee does not." % [
			listingID, int(_state.get("list_fee_gems", 0))],
	})
	return true

func RequestHighlight(listingID : int) -> bool:
	var listing : Dictionary = FindListing(listingID)
	if listing.is_empty() or not bool(listing.get("mine", false)):
		return false
	var preview : Dictionary = PreviewHighlight(_state)
	if not bool(preview["affordable"]):
		_Ask("Not enough gems to highlight (needs %d, you have %d)." % [int(preview["fee_gems"]), int(preview["gems"])])
		return false
	_Arm({
		"kind" = "highlight",
		"listing" = listingID,
		"method" = "AuctionHighlight",
		"args" = [listingID],
		"line" = "Pay %d gems to move listing #%d to the top? Gems after: %d." % [
			int(preview["fee_gems"]), listingID, int(preview["gems_after"])],
	})
	return true

# Venda: o item vem do inventário local, o preço é do jogador, a taxa é do
# servidor — e as três coisas aparecem antes do clique confirmar.
func RequestList(itemID : int, count : int, priceGold : int) -> bool:
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		_Ask("Pick an item, a quantity and a price in gold.")
		return false
	var preview : Dictionary = PreviewList(priceGold, count, _state)
	if not bool(preview["affordable"]):
		_Ask("Listing costs %d gems and you have %d." % [int(preview["fee_gems"]), int(preview["gems"])])
		return false
	_Arm({
		"kind" = "list",
		"listing" = 0,
		"method" = "AuctionList",
		"args" = [itemID, count, priceGold],
		"line" = "List %s x%d for %d gold? The %d-gem listing fee is burned now (gems after: %d). You receive %d gold if another player made the item, otherwise %d." % [
			ItemName(itemID), count, priceGold, int(preview["fee_gems"]), int(preview["gems_after"]),
			int(preview["net"]), int(preview["full_net"])],
	})
	return true

func RequestSlot() -> bool:
	var preview : Dictionary = PreviewSlot(_state)
	if int(_state.get("cap", 0)) <= 0:
		return false
	if not bool(preview["affordable"]):
		_Ask("Not enough gems for another open slot (needs %d, you have %d)." % [int(preview["fee_gems"]), int(preview["gems"])])
		return false
	_Arm({
		"kind" = "slot",
		"listing" = 0,
		"method" = "AuctionBuySlot",
		"args" = [],
		"line" = "Pay %d gems to raise your open-listing cap from %d to %d? Gems after: %d." % [
			int(preview["fee_gems"]), int(_state.get("cap", 0)), int(preview["cap_after"]), int(preview["gems_after"])],
	})
	return true

# Ordem de compra (059c): o ouro NÃO vai para o vendedor aqui — vai para escrow,
# e a prévia diz exatamente isso, com o quanto sai agora e o que volta se nada
# cruzar. Cap de ordens abertas e teto de quantidade vêm no payload da janela
# (`bid_cap`, `bid_max_quantity`): a UI não reimplementa regra do servidor.
func RequestBid(itemID : int, count : int, unitPrice : int) -> bool:
	if itemID <= 0 or count <= 0 or unitPrice <= 0:
		_Ask("Pick an item, a quantity and a max price per unit.")
		return false
	var preview : Dictionary = PreviewBid(count, unitPrice, _state)
	if not bool(preview["within_quantity"]):
		_Ask("A bid holds at most %d units." % int(preview["max_qty"]))
		return false
	if not bool(preview["has_room"]):
		_Ask("You already have %d bids open (cap %d). Cancel one first." % [int(preview["open"]), int(preview["cap"])])
		return false
	if not bool(preview["affordable"]):
		_Ask("This bid would hold %d gold in escrow and you have %d." % [int(preview["escrow"]), int(preview["gold"])])
		return false
	_Arm({
		"kind" = "bid",
		"listing" = 0,
		"method" = "AuctionBid",
		"args" = [itemID, count, unitPrice],
		"line" = "Bid up to %d gold per unit for %s x%d? %d gold leaves your purse NOW as escrow (gold after: %d); it pays the cheapest listing that crosses your ceiling and the rest comes back." % [
			unitPrice, ItemName(itemID), count, int(preview["escrow"]), int(preview["after"])],
	})
	return true

# Cancelar uma ordem é o que devolve o escrow inteiro — e o id é SEMPRE o que o
# servidor pôs na linha, nunca um que a UI lembre.
func RequestBidCancel(orderID : int) -> bool:
	var order : Dictionary = FindBuyOrder(orderID)
	if order.is_empty():
		return false
	if not bool(order.get("mine", false)):
		return false
	_Arm({
		"kind" = "bid_cancel",
		"listing" = orderID,
		"method" = "AuctionBidCancel",
		"args" = [orderID],
		"line" = "Cancel bid #%d and release its %d gold escrow back to your purse?" % [
			orderID, int(order.get("escrow_gold", 0))],
	})
	return true

# Único ponto que arma a prévia. Não envia nada.
func _Arm(pending : Dictionary) -> void:
	_pending = pending
	_Ask(str(pending.get("line", "")))

func _Ask(text : String) -> void:
	if _confirmLabel:
		_confirmLabel.text = text
	# O modal da casa (`UICommons.MessageBox`, mesmo padrão de Settings.gd:712 para
	# excluir conta) é o caminho normal. A linha própria do painel só aparece quando
	# o modal não está disponível — HUD ainda montando, ou mensagem maior que o
	# diálogo — porque dois botões "Confirm" simultâneos seriam uma UI mentirosa.
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if _confirmRow:
		_confirmRow.visible = not modal
	if modal:
		UICommons.MessageBox(text, Callable(self, "ConfirmPending"), "Confirm")

# ÚNICO caminho que fala com a rede. Sem confirmação, este método não é chamado.
func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	var listingID : int = int(_pending.get("listing", 0))
	var kind : String = str(_pending.get("kind", ""))
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if methodName.is_empty():
		return
	if kind == "buy":
		_statusLine("Buying listing #%d…" % listingID)
	_send(methodName, args)

func CancelPending() -> void:
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if _confirmLabel:
		_confirmLabel.text = ""

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

func PendingMethod() -> String:
	return str(_pending.get("method", ""))

# ------------------------------------------------------------------ porta de saída
# O portão de nomes roda ANTES da costura de teste de propósito: é o que faz
# "o painel sabe emitir AuctionBid" ser verificável sem rede, e o que transforma
# um braço removido do `match` em falha de harness em vez de `push_error` na
# tela de quem joga. `SentTargets` é o rastro das emissões aceitas.
func _send(methodName : String, args : Array) -> void:
	if not NetworkTargets.has(methodName):
		push_error("AuctionHousePanel: send target outside the declared table: " + methodName)
		return
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		SentTargets.append(methodName)
		return
	if NetworkSend(methodName, args):
		SentTargets.append(methodName)

# Um braço por alvo declarado, cada um chamando o método LITERAL do facade — o
# contrato de `SuiteNetworkDispatch` (todo `Network.<x>(` precisa existir no
# autoload) e o motivo de a dispatch não ser `Network.call(nome)`: aqui o motor
# confere a assinatura, e um argumento trocado é erro de compilação, não de tela.
func NetworkSend(methodName : String, args : Array) -> bool:
	match methodName:
		"AuctionBuy":
			Network.AuctionBuy(int(args[0]))
		"AuctionCancel":
			Network.AuctionCancel(int(args[0]))
		"AuctionList":
			Network.AuctionList(int(args[0]), int(args[1]), int(args[2]))
		"AuctionHighlight":
			Network.AuctionHighlight(int(args[0]))
		"AuctionBuySlot":
			Network.AuctionBuySlot()
		"AuctionBid":
			Network.AuctionBid(int(args[0]), int(args[1]), int(args[2]))
		"AuctionBidCancel":
			Network.AuctionBidCancel(int(args[0]))
		"GetAuctionPage":
			Network.GetAuctionPage(int(args[0]), int(args[1]), int(args[2]))
		"GetAuctionListings":
			Network.GetAuctionListings(AHBrowseWindow())
		_:
			push_error("AuctionHousePanel: no network arm for " + methodName)
			return false
	return true

func AHBrowseWindow() -> int:
	return PageSize * 5

func _statusLine(text : String) -> void:
	if _statusLabel:
		_statusLabel.text = text

# ------------------------------------------------------------------ callbacks UI
func _on_row_pressed(listingID : int) -> void:
	_selected = listingID
	_render_detail()
	_render_list()

func _on_buy_pressed() -> void:
	if _selected > 0:
		RequestBuy(_selected)

func _on_cancel_pressed() -> void:
	if _selected > 0:
		RequestCancel(_selected)

func _on_highlight_pressed() -> void:
	if _selected > 0:
		RequestHighlight(_selected)

# Dentro do bloco entregue, a seta vira página local; no canto do bloco ela PEDS a
# próxima janela ao servidor. É este `else` que faz do "40" um tamanho de página e
# não um teto do catálogo — sem ele, a linha 41 de um mercado grande continua
# invisível e a migração 059 não chegou a ninguém.
func _on_page_pressed(delta : int) -> void:
	var target : int = _page + delta
	if target >= 0 and target < LocalPages():
		_page = target
		_render_list()
		return
	if target < 0 and _askedOffset > 0:
		RequestPage(-1)
		return
	if target >= LocalPages() and _askedOffset + BlockSize() < int(_state.get("total", 0)):
		RequestPage(1)

func _on_search_changed(text : String) -> void:
	SetSearchQuery(text)

func _on_max_price_changed(text : String) -> void:
	SetMaxPrice(text.to_int())

func _on_refresh_pressed() -> void:
	RequestListings()
	_populate_sell_items()

func _on_list_pressed() -> void:
	var amounts : AuctionHouseForm.Amounts = AuctionHouseForm.SellAmounts(_refs)
	RequestList(_selected_sell_item(), amounts.count, amounts.price)

func _on_slot_pressed() -> void:
	RequestSlot()

# 059(c): demanda. O item sai da linha selecionada na vitrine (bidra-se sobre o
# que se está olhando) e, sem seleção, do item escolhido na fila de venda — os
# dois já são `item_id` do servidor, nunca nome digitado. Quantidade e teto são
# do jogador; quem decide o que sai da carteira é o `RequestBid`, que arma a
# prévia do escrow ANTES de qualquer clique confirmar (gold que vai sem essa
# tela é exatamente o que a régua de confirmação de gasto cobra).
func _on_bid_pressed() -> void:
	var itemID : int = int(SelectedListing().get("item_id", 0))
	if itemID <= 0:
		itemID = _selected_sell_item()
	var amounts : AuctionHouseForm.Amounts = AuctionHouseForm.BidAmounts(_refs)
	RequestBid(itemID, amounts.count, amounts.price)

# O botão de cada linha de "your bids" cancela AQUELA ordem: devolve o depósito
# inteiro, sem taxa.
func _on_bid_cancel_pressed(orderID : int) -> void:
	RequestBidCancel(orderID)

func _selected_sell_item() -> int:
	if _sellOption == null or _sellItems.is_empty():
		return 0
	var idx : int = _sellOption.selected
	if idx < 0 or idx >= _sellItems.size():
		return 0
	return int(_sellItems[idx])

# Vende-se o que está no inventário (mesma fonte do Altar em Activities.gd:193).
func _populate_sell_items() -> void:
	if _sellOption == null:
		return
	_sellOption.clear()
	_sellItems.clear()
	if Launcher.Player == null or Launcher.Player.inventory == null:
		return
	for item in Launcher.Player.inventory.items:
		var cell : ItemCell = DB.GetItem(item.cellID, item.cellCustomfield)
		if cell == null or item.count <= 0:
			continue
		_sellOption.add_item("%s x%d" % [cell.name, item.count])
		_sellItems.append(item.cellID)

# Aberta de fora (Gui/Client): pede a janela de anúncios e recheia a venda.
func OpenAuction() -> void:
	RequestListings()
	_populate_sell_items()
	if not NetClient.LastAuctionListings.is_empty():
		ShowState(NetClient.LastAuctionListings)
