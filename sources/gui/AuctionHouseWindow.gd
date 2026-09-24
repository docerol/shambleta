# SOM-IDLE P1 / Social: Auction House Window (UI gráfica).
# Estilo Grand Exchange OSRS: busca por nome, filtro por tipo/preço máximo,
# ordenação por preço e histórico das últimas 10 vendas (local, sessão).
# Nota honesta: não há RPC de listagem no servidor — esta janela filtra e
# ordena o array entregue via RefreshAuction(listings) e registra o histórico
# via RecordSale(). Compra/venda continuam pelo ExecuteTrade (/ah comandos).
extends WindowPanel
class_name AuctionHouseWindow

const MaxHistory : int = 10

var _listings : Array = []
var _history : Array = []
var _query : String = ""
var _typeFilter : String = ""
var _maxPrice : int = 0  # 0 = sem teto

var _listBox : VBoxContainer = null
var _historyLabel : Label = null

func _ready():
	name = "AuctionHouse"
	var titleBar : Label = Label.new()
	titleBar.text = "Leilão — Grand Exchange"
	titleBar.add_theme_font_size_override("font_size", 18)
	titleBar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(titleBar)

	var info : Label = Label.new()
	info.text = "Busca por nome, filtro por tipo e teto de preço. Histórico: últimas 10 vendas da sessão."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(info)

	_listBox = VBoxContainer.new()
	_listBox.name = "ListingBox"
	add_child(_listBox)

	_historyLabel = Label.new()
	_historyLabel.name = "History"
	_historyLabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_historyLabel)
	_render_history()

func SetSearchQuery(query : String) -> void:
	_query = query.strip_edges().to_lower()
	_render_list()

func SetTypeFilter(itemType : String) -> void:
	_typeFilter = itemType.strip_edges().to_lower()
	_render_list()

func SetMaxPrice(price : int) -> void:
	_maxPrice = maxi(0, price)
	_render_list()

func RecordSale(entry : Dictionary) -> void:
	_history.push_front(entry)
	while _history.size() > MaxHistory:
		_history.pop_back()
	_render_history()

func GetHistory() -> Array:
	return _history.duplicate()

# Filtra por nome (substring), tipo (igualdade) e teto de preço; ordena por
# preço crescente. Puro — testável sem cena (opera só sobre _listings).
func FilterListings(listings : Array, query : String, itemType : String, maxPrice : int) -> Array:
	var out : Array = []
	var q : String = query.strip_edges().to_lower()
	var t : String = itemType.strip_edges().to_lower()
	for e in listings:
		if not (e is Dictionary):
			continue
		var d : Dictionary = e
		if not q.is_empty() and str(d.get("name", "")).to_lower().find(q) < 0:
			continue
		if not t.is_empty() and str(d.get("type", "")).to_lower() != t:
			continue
		if maxPrice > 0 and int(d.get("price", 0)) > maxPrice:
			continue
		out.append(d)
	out.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return int(a.get("price", 0)) < int(b.get("price", 0)))
	return out

func RefreshAuction(listings : Array) -> void:
	_listings = listings.duplicate()
	_render_list()

func _render_list() -> void:
	if _listBox == null:
		return
	for child in _listBox.get_children():
		child.queue_free()
	var shown : Array = FilterListings(_listings, _query, _typeFilter, _maxPrice)
	if shown.is_empty():
		var empty : Label = Label.new()
		empty.text = "Nenhum anúncio combina com os filtros." if not _listings.is_empty() else "Nenhum anúncio no momento."
		_listBox.add_child(empty)
		return
	for e in shown:
		var d : Dictionary = e
		var row : Label = Label.new()
		row.text = "%s [%s] x%d — %d gems" % [str(d.get("name", "?")), str(d.get("type", "—")), int(d.get("qty", 1)), int(d.get("price", 0))]
		_listBox.add_child(row)

func _render_history() -> void:
	if _historyLabel == null:
		return
	if _history.is_empty():
		_historyLabel.text = "Histórico: nenhuma venda nesta sessão."
		return
	var parts : PackedStringArray = PackedStringArray()
	for e in _history:
		var d : Dictionary = e
		parts.append("%s x%d (%d)" % [str(d.get("name", "?")), int(d.get("qty", 1)), int(d.get("price", 0))])
	_historyLabel.text = "Histórico (%d): %s" % [_history.size(), ", ".join(parts)]
