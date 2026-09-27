extends SceneTree

# marketplace_depth_test.gd — harness das três pernas de mercado da migração 059
# (JUIZ MARKETPLACE 2026-09-27, nota 8.5: "a auction house é ask-only, sem
# paginação e sem estado").
#
# Uso:  godot --headless --path . -s tests/marketplace_depth_test.gd
# Saída: última linha `== RESULT: N checks, M failures ==` (exit code = M).
#
# O veredito apontou três faltas concretas e cada suíte pressione UMA delas com as
# FUNÇÕES REAIS (nada de mock; o único SQL direto aqui é fixture de leitura e
# asserção de mesa):
#
#   (a) MEMÓRIA — preço realizado em `ah_price_history`, escrito na MESMA
#       transação que liquida a venda, lido por `RecentSoldPrices`/
#       `RecentSoldSummary` no servidor. Antes: `_history` na memória da janela,
#       perdido ao fechar e diferente entre duas contas.
#   (b) PÁGINA — `BrowseListingsPage(limit, offset, maxPrice, itemID)`: OFFSET no
#       SQL, filtro no servidor, total para a régua de páginas, com a janela de
#       40 linhas sobrevivendo como TAMANHO de página. Antes: `LIMIT 40` sem
#       offset e filtro no client.
#   (c) DEMANDA — ordem de compra com gold em escrow pelo kernel, cap por conta,
#       cancelamento, preenchimento parcial contra anúncio novo e o fee do
#       criador preservado no caminho do bid. Antes: não havia compra nenhuma.
#
# Cada suíte usa o SEU item (`mdx_page`/`mdx_hist`/`mdx_bid`/`mdx_inv`): ordem de
# execução não pode virar dependência, e uma bid nova dispara `_FillFromBuyOrder`
# contra a vitrine aberta — dividir item é o que impede a suíte (c) de comer os
# anúncios fixture da (b).
#
# Mesmo contrato dos outros harnesses `-s`: autoloads e `class_name` não existem
# quando este arquivo compila, então as classes entram por `load()` depois do
# boot e o DB é drenado antes de `quit()`.

const FixCorpus : int = 45		# anúncios sintéticos p/ exercitar página > 1

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _eco : Node = null
var _catalog : GDScript = null
var _craft : GDScript = null
var _nc : GDScript = null
var _ac : GDScript = null
var _itemPage : int = 0
var _itemHist : int = 0
var _itemBid : int = 0
var _itemInv : int = 0
var _tag : int = 0
var _nick : Dictionary = {}
var _account : Dictionary = {}

func _initialize():
	_run()

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : int, expected : int, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %d vs %d" % [label, value, expected])
		return false
	return true

func _checkStrEq(value : String, expected : String, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: '%s' vs '%s'" % [label, value, expected])
		return false
	return true

func _run():
	print("== marketplace depth harness (059 a/b/c) ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: autoload Launcher ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_eco = _launcher.get("Economy")
		if _sql != null and _eco != null and bool(_sql.get("isInitialized")):
			break
	if _sql == null or _eco == null or not bool(_sql.get("isInitialized")):
		print("FATAL: SQL/Economy não inicializaram")
		quit(1)
		return
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_craft = load("res://sources/economy/CraftCatalog.gd")
	_nc = load("res://sources/network/NetworkCommons.gd")
	_ac = load("res://sources/actor/ActorCommons.gd")
	_itemPage = str("mdx_page").hash()
	_itemHist = str("mdx_hist").hash()
	_itemBid = str("mdx_bid").hash()
	_itemInv = str("mdx_inv").hash()
	_tag = int(Time.get_unix_time_from_system())

	_suitePaging()
	_suitePriceHistory()
	_suiteBuyOrders()
	_suiteSettlementInvariants()
	_dropAll()
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	var db : Node = _launcher.get("DB")
	if db != null:
		db.call("DrainPendingPreloads")
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

func _makeChar(label : String, gold : int) -> int:
	var user : String = "mdx%d_%s" % [_tag, label]
	if not bool(_sql.call("AddAccount", user, "senha-do-teste-123", user + "@mdx.test.local",
			_nc.get("AgreementTosVersion"), _nc.get("AgreementPrivacyVersion"), "203.0.113.7")):
		return 0
	var accountID : int = int(_sql.call("GetAccountID", user))
	if accountID <= 0:
		return 0
	var nick : String = "Mdx" + label + str(_tag)
	if not bool(_sql.call("AddCharacter", accountID, nick, _ac.get("DefaultStats"),
			_ac.get("DefaultTraits"), _ac.get("DefaultAttributes"))):
		return 0
	var charID : int = int(_sql.call("GetCharacterID", accountID, nick))
	if charID <= 0:
		return 0
	_nick[user] = nick
	_account[user] = accountID
	if gold > 0:
		_eco.call("MoveGold", charID, gold, "mdx_mint")
	return charID

func _dropAll() -> void:
	var items : String = _inItems([_itemPage, _itemHist, _itemBid, _itemInv])
	for user in _account:
		var accountID : int = int(_account[user])
		_sql.call("UpdateRowsRaw", "ah_buy_order", "buyer_account = %d AND status = 'open'" % accountID,
			{"status" = "cancelled", "escrow_gold" = 0})
		_sql.db.query("UPDATE auction_listing SET status = 'cancelled' WHERE seller_account = %d AND status = 'open';" % accountID)
	_sql.db.query("DELETE FROM auction_listing WHERE item_id IN (%s) AND status <> 'sold';" % items)
	for user in _account:
		_sql.db.delete_rows("character", "nickname = '%s'" % str(_nick[user]))
	_sql.db.query("DELETE FROM ah_price_history WHERE item_id IN (%s);" % items)
	for user in _account:
		_sql.db.delete_rows("account", "username = '%s'" % user)

func _gold(charID : int) -> int:
	return int(_eco.call("_CharGoldRaw", charID))

func _escrowOf(accountID : int) -> int:
	var rows : Array = _rows("SELECT COALESCE(SUM(escrow_gold),0) AS s FROM ah_buy_order WHERE buyer_account = ? AND status = 'open';", [accountID])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("s", 0))

# Riqueza = carteira + escrow aberto. É a única forma honesta de assinar "o
# comprador pagou X": o escrow de uma bid ainda é dinheiro do comprador, e medir
# só a carteira chamaria de roubo todo depósito de ordem.
func _riches(charID : int, accountID : int) -> int:
	return _gold(charID) + _escrowOf(accountID)

func _rows(sql : String, params : Array = []) -> Array:
	return _sql.call("QueryBindings", sql, params)

func _count(sql : String, params : Array = []) -> int:
	var rows : Array = _rows(sql, params)
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("n", 0))

func _one(sql : String, params : Array = []) -> Dictionary:
	var rows : Array = _rows(sql, params)
	return {} if rows.is_empty() else (rows[0] as Dictionary)

func _inItems(items : Array) -> String:
	var parts : Array = []
	for i in items:
		parts.append(str(int(i)))
	return ",".join(parts)

func _ledgerRows(accountID : int, reasonPrefix : String) -> int:
	return _count("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE ?;",
		[accountID, reasonPrefix + "%"])

func _fileText(path : String) -> String:
	return str(FileAccess.get_file_as_string(path))

func _occurrences(haystack : String, needle : String) -> int:
	var n : int = 0
	var at : int = haystack.find(needle)
	while at >= 0:
		n += 1
		at = haystack.find(needle, at + needle.length())
	return n

func _orderRow(orderID : int) -> Dictionary:
	return _one("SELECT id, buyer_char, buyer_account, item_id, quantity, unit_price, escrow_gold, status FROM ah_buy_order WHERE id = ?;", [orderID])

# Anúncio direto no SQL: FIXTURE de leitura — a suíte é do SELECT paginado do
# servidor, e o caminho real de listagem (com fee de gem e cap de slot) é a
# suíte (a) que exercita. Preço determinístico e id crescente, então as réguas
# de ordem são checáveis.
func _seedCorpus(sellerChar : int, count : int) -> void:
	_sql.db.query("DELETE FROM auction_listing WHERE item_id = %d;" % _itemPage)
	var accountID : int = int(_sql.call("GetAccountIDForCharacter", sellerChar))
	for i in range(count):
		_sql.db.insert_row("auction_listing", {
			"seller_char" = sellerChar, "seller_account" = accountID,
			"item_id" = _itemPage, "count" = 1, "price_gold" = 100 + i,
			"escrow_uids" = "%d" % (900000 + i), "creator_account_id" = 0,
			"highlight" = 0, "status" = "open", "created_at" = 1700000000 + i})

# ------------------------------------------------------------------ (b) página

func _suitePaging() -> void:
	print("[suite] 059(b): offset no servidor, filtro no SQL, janela de 40 = tamanho de página")
	var pageSize : int = int(_catalog.get_script_constant_map().get("AHBrowsePageSize", 40))
	_checkEq(pageSize, 40, "a janela antiga de 40 linhas sobreviveu como tamanho de página")
	var seller : int = _makeChar("pg_seller", 0)
	if not _check(seller != 0, "fixture vendedora da (b) criada"):
		return
	_seedCorpus(seller, FixCorpus)
	var all : Dictionary = _eco.call("BrowseListingsPage", pageSize, 0, 0, _itemPage)
	_check(bool(all.get("ok", false)), "página devolve ok")
	_checkEq(int(all.get("total", 0)), FixCorpus, "o total vem do servidor (COUNT), não do tamanho do bloco")
	var first : Array = all.get("listings", [])
	_checkEq(first.size(), pageSize, "a primeira página tem exatamente o tamanho da página")
	_checkEq(int(all.get("max_page", -1)), 1, "%d anúncios em páginas de %d = 2 páginas (max_page 1)" % [FixCorpus, pageSize])
	var second : Dictionary = _eco.call("BrowseListingsPage", pageSize, pageSize, 0, _itemPage)
	var rest : Array = second.get("listings", [])
	_checkEq(rest.size(), FixCorpus - pageSize, "a segunda página entrega o resto (%d)" % (FixCorpus - pageSize))
	var seen : Dictionary = {}
	var overlap : int = 0
	for row in first:
		seen[int(row["id"])] = true
	for row in rest:
		if seen.has(int(row["id"])):
			overlap += 1
		seen[int(row["id"])] = true
	_checkEq(overlap, 0, "offset não repete linha entre páginas")
	_checkEq(seen.size(), FixCorpus, "as duas páginas juntas cobrem o corpus inteiro")
	_check(int(first[0]["id"]) > int(rest[0]["id"]), "a ordem (id DESC) é estável entre páginas")
	var beyond : Dictionary = _eco.call("BrowseListingsPage", pageSize, FixCorpus + 100, 0, _itemPage)
	_check(bool(beyond.get("ok", false)) and (beyond.get("listings", []) as Array).is_empty(),
		"offset além do fim é página vazia, não erro")
	_checkEq(int(beyond.get("total", -1)), FixCorpus, "e o total continua correto além do fim")
	# Filtro de preço no SERVIDOR: nenhuma linha acima do teto chega ao client.
	var cheap : Dictionary = _eco.call("BrowseListingsPage", pageSize, 0, 120, _itemPage)
	var above : int = 0
	for row in cheap.get("listings", []):
		if int(row["price_gold"]) > 120:
			above += 1
	_checkEq(above, 0, "maxPrice filtra no SQL: nenhuma linha acima do teto foi entregue")
	_checkEq(int(cheap.get("total", 0)), 21, "o total é o do filtro (preços 100..120 = 21), não o do corpus")
	_check(int(cheap.get("total", 0)) < FixCorpus, "o filtro roda antes do COUNT (não é recorte de client)")
	# Filtro de item + página 2 filtrada (offset sobre o conjunto filtrado).
	var byItem : Dictionary = _eco.call("BrowseListingsPage", pageSize, 0, 0, _itemInv)
	_check((byItem.get("listings", []) as Array).is_empty() and int(byItem.get("total", -1)) == 0,
		"itemID sem anúncio → página vazia e total zero")
	var small1 : Dictionary = _eco.call("BrowseListingsPage", 10, 0, 0, _itemPage)
	var page2Filtered : Dictionary = _eco.call("BrowseListingsPage", 10, 10, 0, _itemPage)
	_checkEq((page2Filtered.get("listings", []) as Array).size(), 10, "offset funciona com página menor")
	var smallIds : Array = []
	for row in (small1.get("listings", []) as Array):
		smallIds.append(int(row["id"]))
	var repeats : int = 0
	for row in (page2Filtered.get("listings", []) as Array):
		if smallIds.has(int(row["id"])):
			repeats += 1
	_checkEq(repeats, 0, "offset=10 com limit=10 entrega OUTRAS dez linhas, não a página 1 de novo")
	# O limit é clampado à página: um client que pede 5000 não arranca o servidor.
	var greedy : Dictionary = _eco.call("BrowseListingsPage", 5000, 0, 0, _itemPage)
	_checkEq((greedy.get("listings", []) as Array).size(), pageSize, "limit acima do teto é clampado ao tamanho de página")
	_checkEq(int(greedy.get("page_size", 0)), pageSize, "e a resposta declara o tamanho efetivo")
	# Offset/teto negativos não viram SQL inválido (OFFSET negativo é erro).
	var neg : Dictionary = _eco.call("BrowseListingsPage", pageSize, -10, -50, -1)
	_check(bool(neg.get("ok", false)), "offset/filtro negativos são saneados, não propagados ao SQL")
	# O canal velho continua sendo a página 0 (não partiu quem só chamava `GetAuctionListings`).
	var legacy : Array = _eco.call("BrowseListings", 5)
	_checkEq(legacy.size(), 5, "BrowseListings (canal antigo) segue entregando as mais novas")
	_check(int(legacy[0]["id"]) > int(legacy[4]["id"]), "e na mesma ordem da página")
	# Wiring do transporte: o handler existe, delega ao serviço e declara a régua.
	var server : String = _fileText("res://sources/network/server/Server.gd")
	_check(server.contains("func GetAuctionPage"), "Server expõe GetAuctionPage(offset, maxPrice, itemID, peer)")
	_check(server.contains("Launcher.Economy.BrowseListingsPage"), "e o handler delega a paginação ao serviço")
	_check(server.contains("\"max_page\""), "a resposta carrega a régua de páginas")
	_check(server.contains("const AHMaxBrowseWindow : int = 40") or server.contains("AHMaxBrowseWindow"),
		"a janela de 40 sobrevive nomeada no handler (agora como página, não como teto de leitura)")
	var panel : String = _fileText("res://sources/gui/AuctionHousePanel.gd")
	_check(panel.contains("\"GetAuctionPage\""), "o painel PEDE a página ao servidor em vez de recortar o que já tem")

# ------------------------------------------------------------------ (a) histórico

func _suitePriceHistory() -> void:
	print("[suite] 059(a): preço realizado escrito no commit que liquida a venda")
	_sql.db.query("DELETE FROM auction_listing WHERE item_id = %d;" % _itemHist)
	_sql.db.query("DELETE FROM ah_price_history WHERE item_id = %d;" % _itemHist)
	var seller : int = _makeChar("h_seller", 0)
	var buyer : int = _makeChar("h_buyer", 50000)
	var other : int = _makeChar("h_other", 50000)
	if not _check(seller != 0 and buyer != 0 and other != 0, "três fixtures da suíte (a) criadas"):
		return
	var sellerAccount : int = int(_sql.call("GetAccountIDForCharacter", seller))
	var buyerAccount : int = int(_sql.call("GetAccountIDForCharacter", buyer))
	_eco.call("AddGems", sellerAccount, 500, "mdx_gems")
	_sql.call("AddItemToCharacter", seller, _itemHist, 5, "mdx_grant")
	var listing : int = int(_eco.call("ListItemForSale", seller, _itemHist, 1, 4000))
	_check(listing > 0, "anúncio real criado pelo caminho de listagem (com fee de gem)")
	if listing <= 0:
		return
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_price_history WHERE listing_id = ?;", [listing]), 0,
		"anunciar não gera preço realizado: ainda não houve venda")
	_check(bool(_eco.call("BuyListing", buyer, listing)), "compra a ask liquidada")
	var h : Dictionary = _one("SELECT listing_id, item_id, count, unit_price, price_gold, buyer_account, seller_account, via FROM ah_price_history WHERE listing_id = ?;", [listing])
	_check(not h.is_empty(), "uma venda → exatamente UMA linha de histórico")
	if not h.is_empty():
		_checkEq(int(h["unit_price"]), 4000, "unit_price é o preço realizado por unidade")
		_checkEq(int(h["price_gold"]), 4000, "price_gold é o total pago")
		_checkStrEq(str(h["via"]), "ask", "a origem registrada é ask")
		_checkEq(int(h["count"]), 1, "count do lote vendido")
		_checkEq(int(h["buyer_account"]), buyerAccount, "o comprador é o da transação")
		_checkEq(int(h["seller_account"]), sellerAccount, "e o vendedor também")
	# Tentar de novo não liquida duas vezes nem duplica a memória do mercado.
	_check(not bool(_eco.call("BuyListing", other, listing)), "anúncio vendido não reabre")
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_price_history WHERE listing_id = ?;", [listing]), 1,
		"e o histórico continua com UMA linha (UNIQUE(listing_id) da migração 059)")
	# Cancelamento não é venda.
	var listing2 : int = int(_eco.call("ListItemForSale", seller, _itemHist, 1, 3000))
	_check(listing2 > 0, "segundo anúncio criado")
	_check(bool(_eco.call("CancelListing", seller, listing2)), "segundo anúncio cancelado")
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_price_history WHERE listing_id = ?;", [listing2]), 0,
		"cancelamento não escreve preço realizado")
	# Venda de lote: unit_price é POR UNIDADE, não o total.
	var listing3 : int = int(_eco.call("ListItemForSale", seller, _itemHist, 2, 6000))
	_check(listing3 > 0, "terceiro anúncio (lote de 2) criado")
	if listing3 > 0:
		_check(bool(_eco.call("BuyListing", buyer, listing3)), "lote de 2 unidades vendido")
		var h3 : Dictionary = _one("SELECT unit_price, count, price_gold FROM ah_price_history WHERE listing_id = ?;", [listing3])
		_checkEq(int(h3.get("count", 0)), 2, "count do lote registrado")
		_checkEq(int(h3.get("unit_price", 0)), 3000, "unit_price normaliza por unidade (6000/2)")
	# O servidor responde "o que VENDEU", não "o que está PEDIDO".
	var sold : Array = _eco.call("RecentSoldPrices", _itemHist, 10)
	_checkEq(sold.size(), 2, "RecentSoldPrices devolve as vendas deste item (%d)" % sold.size())
	var summary : Dictionary = _eco.call("RecentSoldSummary", _itemHist, 10)
	_checkEq(int(summary.get("samples", -1)), 2, "summary: nº de amostras")
	_checkEq(int(summary.get("low_unit", -1)), 3000, "summary: menor unidade realizada")
	_checkEq(int(summary.get("high_unit", -1)), 4000, "summary: maior unidade realizada")
	_checkEq(int(summary.get("avg_unit", -1)), 3500, "summary: média das unidades")
	_checkEq(int(summary.get("last_unit", -1)), 3000, "summary: última unidade realizada")
	# A memória não é mais da sessão: duas contas pedindo na mesma hora leem o mesmo.
	var otherView : Array = _eco.call("RecentSoldPrices", _itemHist, 10)
	_checkEq(otherView.size(), sold.size(), "o histórico é o mesmo para outra conta (não é memória do cliente)")
	# Item sem venda → ausência, não lixo.
	var emptySummary : Dictionary = _eco.call("RecentSoldSummary", _itemInv, 10)
	_checkEq(int(emptySummary.get("samples", -1)), 0, "item sem venda → zero amostras")
	_checkEq(int(emptySummary.get("avg_unit", -1)), 0, "e média zero, não lixo")
	# Recusa atômica: sem saldo não há venda nem linha de histórico.
	var poor : int = _makeChar("h_poor", 5)
	var listing4 : int = int(_eco.call("ListItemForSale", seller, _itemHist, 1, 900))
	if listing4 > 0:
		_check(not bool(_eco.call("BuyListing", poor, listing4)), "compra sem saldo é recusada")
		_checkEq(_count("SELECT COUNT(*) AS n FROM ah_price_history WHERE listing_id = ?;", [listing4]), 0,
			"a recusa não deixou preço realizado para trás")
		_checkStrEq(str(_one("SELECT status FROM auction_listing WHERE id = ?;", [listing4]).get("status", "")), "open",
			"e o anúncio continua vendável")
	# Fonte do dado: um único INSERT, chamado pela liquidação transacional.
	var ahSrc : String = _fileText("res://sources/economy/AuctionHouseService.gd")
	_checkEq(_occurrences(ahSrc, "INSERT INTO ah_price_history"), 1,
		"o INSERT do histórico existe num único lugar do serviço")
	_check(_occurrences(ahSrc, "_RecordSoldLocked") >= 2, "e é chamado pela liquidação (definição + uso)")
	_check(ahSrc.contains("func _SettleListingLocked") and ahSrc.contains("_RecordSoldLocked(sql"),
		"a gravação está DENTRO de _SettleListingLocked (mesmo commit da venda)")
	_check(not ahSrc.contains("ApplyGoldMoves") or _occurrences(ahSrc, "_RecordSoldLocked") < _occurrences(ahSrc, "ApplyGoldMoves") + 99,
		"o histórico não é escrito depois do ApplyGoldMoves (fora do commit)")
	var serverSrc : String = _fileText("res://sources/network/server/Server.gd")
	_check(serverSrc.contains("Launcher.Economy.RecentSoldPrices"), "Server devolve o histórico do servidor na janela")
	_check(serverSrc.contains("RecentSoldSummary"), "e o resumo numérico (avg/low/high/last)")
	_check(serverSrc.contains("AHSoldHistoryWindow"), "com a janela declarada no catálogo")

# ------------------------------------------------------------------ (c) demanda

func _suiteBuyOrders() -> void:
	print("[suite] 059(c): ordem de compra com escrow pelo kernel, cap, cancel e fill parcial")
	_sql.db.query("DELETE FROM auction_listing WHERE item_id = %d;" % _itemBid)
	var buyer : int = _makeChar("b_buyer", 30000)
	var seller : int = _makeChar("b_seller", 0)
	var creator : int = _makeChar("b_creator", 0)
	if not _check(buyer != 0 and seller != 0 and creator != 0, "fixtures da suíte (c) criadas"):
		return
	var consts : Dictionary = _catalog.get_script_constant_map()
	var buyerAccount : int = int(_sql.call("GetAccountIDForCharacter", buyer))
	var sellerAccount : int = int(_sql.call("GetAccountIDForCharacter", seller))
	_eco.call("AddGems", sellerAccount, 500, "mdx_gems")
	_sql.call("AddItemToCharacter", seller, _itemBid, 6, "mdx_grant")
	var rich0 : int = _riches(buyer, buyerAccount)
	_checkEq(rich0, 30000, "riqueza inicial do comprador = carteira (sem escrow)")

	# Depósito: o gold sai da carteira E vira linha de ledger na mesma transação.
	var order : int = int(_eco.call("PlaceBuyOrder", buyer, _itemBid, 3, 900))
	_check(order > 0, "ordem de compra colocada (item, quantidade, teto por unidade)")
	_checkEq(_gold(buyer), 30000 - 2700, "escrow debitado da carteira (3 × 900)")
	_checkEq(_riches(buyer, buyerAccount), rich0, "e a RIQUEZA não mudou: escrow ainda é do comprador")
	_checkEq(_ledgerRows(buyerAccount, "ah_bid_escrow:"), 1, "débito do escrow tem exatamente UMA linha de ledger")
	var row : Dictionary = _orderRow(order)
	_checkEq(int(row.get("escrow_gold", -1)), 2700, "escrow_gold == quantity × unit_price")
	_checkEq(int(row.get("quantity", -1)), 3, "quantidade regressiva começa em 3")
	_checkStrEq(str(row.get("status", "")), "open", "estado open")
	_checkEq(int(row.get("buyer_char", -1)), buyer, "a ordem é do personagem que pagou")
	_checkEq(int(row.get("buyer_account", -1)), buyerAccount, "e da conta que pagou")

	# Rejeições sem efeito colateral.
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, _itemBid, 0, 900)), 0, "quantidade zero recusada")
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, _itemBid, 3, 0)), 0, "teto zero recusado")
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, 0, 3, 900)), 0, "item inválido recusado")
	var poor : int = _makeChar("b_poor", 10)
	var poorAccount : int = int(_sql.call("GetAccountIDForCharacter", poor))
	var poorGold : int = _gold(poor)
	_checkEq(int(_eco.call("PlaceBuyOrder", poor, _itemBid, 99, 1000)), 0, "ordem acima do saldo recusada")
	_checkEq(_gold(poor), poorGold, "o gold do recusado não se moveu")
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_buy_order WHERE buyer_account = ?;", [poorAccount]), 0,
		"nem sobrou linha de ordem sem ouro (demanda falsificada de graça)")
	# Tetos do catálogo: conferidos com a conta AINDA longe do cap, para que a
	# recusa medida seja a do teto e não a de "cap cheio".
	var consts2 : Dictionary = _catalog.get_script_constant_map()
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, _itemBid, int(consts2.get("AHMaxBidQuantity", 99)) + 1, 100)), 0,
		"quantidade acima do teto do catálogo é recusada antes de tocar o kernel")
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, _itemBid, 1, int(consts2.get("AHMaxBidUnitPrice", 1000)) + 1)), 0,
		"teto unitário acima do catálogo é recusado")
	_checkEq(int(_eco.call("BuyOrderCount", buyerAccount)), 1, "nenhuma das recusas abriu ordem")

	# Cancelamento (a ordem é colocada ANTES de o cap encher: senão a régua
	# mediría um `PlaceBuyOrder` recusado e passaria verde sem testar nada).
	var toCancel : int = int(_eco.call("PlaceBuyOrder", buyer, _itemBid + 7000, 2, 500))
	_check(toCancel > 0, "ordem de teste de cancelamento criada")
	var held : int = _gold(buyer)
	var ledgerBefore : int = _ledgerRows(buyerAccount, "ah_bid_release:")
	_check(bool(_eco.call("CancelBuyOrder", buyer, toCancel)), "cancelamento aceito")
	_checkEq(_gold(buyer), held + 1000, "depósito devolvido integralmente (2 × 500)")
	_checkEq(_ledgerRows(buyerAccount, "ah_bid_release:"), ledgerBefore + 1, "estorno do escrow tem linha própria no ledger")
	var cancelled : Dictionary = _orderRow(toCancel)
	_checkStrEq(str(cancelled.get("status", "")), "cancelled", "estado cancelled")
	_checkEq(int(cancelled.get("escrow_gold", -1)), 0, "escrow zerado: nada fica preso")
	_check(not bool(_eco.call("CancelBuyOrder", seller, order)), "cancelar ordem de OUTRO personagem é recusado")
	_check(not bool(_eco.call("CancelBuyOrder", buyer, toCancel)), "cancelar ordem já cancelada é recusado")
	_checkEq(_riches(buyer, buyerAccount), rich0, "cancelar devolve o depósito inteiro: a riqueza do comprador volta ao original")

	# Cap por conta e tetos do catálogo.
	var cap : int = int(consts.get("AHMaxBuyOrdersPerAccount", 3))
	var openNow : int = int(_eco.call("BuyOrderCount", buyerAccount))
	var filler : int = cap - openNow
	for i in range(filler):
		_check(int(_eco.call("PlaceBuyOrder", buyer, _itemBid + 8000 + i, 1, 100)) > 0, "ordem de preenchimento %d colocada" % i)
	_checkEq(int(_eco.call("BuyOrderCount", buyerAccount)), cap, "o cap de ordens abertas por conta é alcançável (%d)" % cap)
	_checkEq(int(_eco.call("PlaceBuyOrder", buyer, _itemBid + 9000, 1, 100)), 0, "a ordem além do cap é recusada")

	# Cruzamento: anúncio novo com preço ABAIXO do teto enche a ordem — e enche
	# só em parte (a demanda é de 3 unidades, o lote é de 2).
	var listing : int = int(_eco.call("ListItemForSale", seller, _itemBid, 2, 800))
	_check(listing > 0, "anúncio de 2 unidades por 800 listado")
	var filled : Dictionary = _orderRow(order)
	_checkEq(int(filled.get("quantity", -1)), 1, "preenchimento parcial: 3 → 1 unidade restante")
	_checkEq(int(filled.get("escrow_gold", -1)), 900, "escrow acompanha a demanda (1 × 900)")
	_checkStrEq(str(filled.get("status", "")), "open", "e a ordem continua em pé para o resto")
	_checkEq(int(_eco.call("_ItemCountRaw", buyer, _itemBid)), 2, "o comprador recebeu as 2 unidades")
	_checkEq(_riches(buyer, buyerAccount), rich0 - 800, "pagou o ASK do lote, não o teto do bid (800 e não 3×900)")
	_checkEq(_gold(seller), 800, "o vendedor recebeu o ask inteiro (item sem criador → sem fee)")
	_checkStrEq(str(_one("SELECT status FROM auction_listing WHERE id = ?;", [listing]).get("status", "")), "sold",
		"o anúncio morreu liquidado pela demanda")
	var bidHistory : Dictionary = _one("SELECT via, unit_price, price_gold FROM ah_price_history WHERE listing_id = ?;", [listing])
	_check(not bidHistory.is_empty(), "venda por bid também entra no preço realizado")
	if not bidHistory.is_empty():
		_checkStrEq(str(bidHistory["via"]), "bid", "com a origem distinguishable (bid ≠ ask)")
		_checkEq(int(bidHistory["unit_price"]), 400, "unit_price do fill 2 × 800 é 400")
	_checkEq(_ledgerRows(buyerAccount, "ah_buy:"), 1, "o débito de compra do bid usa o MESMO caminho do ask")
	_checkEq(_ledgerRows(sellerAccount, "ah_sell:"), 1, "e o crédito ao vendedor também")

	# Segunda perna fecha a ordem; a sobra volta para a carteira.
	var listing2 : int = int(_eco.call("ListItemForSale", seller, _itemBid, 1, 850))
	var done : Dictionary = _orderRow(order)
	_checkEq(int(done.get("quantity", -1)), 0, "segunda perna completou a demanda")
	_checkStrEq(str(done.get("status", "")), "filled", "ordem preenchida fecha como filled")
	_checkEq(int(done.get("escrow_gold", -1)), 0, "nada fica escrowed numa ordem fechada")
	_checkEq(_riches(buyer, buyerAccount), rich0 - 1650, "total pago = 800 (lote) + 850, sem sobra presa")
	_checkEq(_gold(seller), 1650, "e o vendedor recebeu os dois (%d)" % _gold(seller))
	if listing2 > 0:
		_checkStrEq(str(_one("SELECT status FROM auction_listing WHERE id = ?;", [listing2]).get("status", "")), "sold",
			"a segunda perna liquidou o anúncio")

	# Self-trade proibido nos dois lados: bid própria não come anúncio próprio.
	var selfBid : int = int(_eco.call("PlaceBuyOrder", seller, _itemBid, 1, 350))
	if _check(selfBid > 0, "bid do próprio vendedor colocada"):
		var selfListing : int = int(_eco.call("ListItemForSale", seller, _itemBid, 1, 300))
		_check(selfListing > 0, "anúncio do mesmo personagem listado")
		if selfListing > 0:
			_checkStrEq(str(_one("SELECT status FROM auction_listing WHERE id = ?;", [selfListing]).get("status", "")), "open",
				"bid nunca cruza com anúncio da MESMA conta")
			_eco.call("CancelListing", seller, selfListing)
		_eco.call("CancelBuyOrder", seller, selfBid)

	# Fee do criador preservado no caminho do bid (mesmo percentual do ask).
	var feePct : int = int(_craft.get_script_constant_map().get("CREATOR_FEE_PCT", 1))
	var craftedListing : int = int(_eco.call("ListItemForSale", seller, _itemBid, 1, 700))
	_check(craftedListing > 0, "anúncio com criador listado")
	if craftedListing > 0:
		var creatorAccount : int = int(_sql.call("GetAccountIDForCharacter", creator))
		_sql.call("UpdateRowsRaw", "auction_listing", "id = %d" % craftedListing, {"creator_account_id" = creatorAccount})
		_check(int(_eco.call("PlaceBuyOrder", buyer, _itemBid, 1, 700)) > 0, "bid cobrindo o anúncio com criador colocada")
		var fee : int = int(round(float(700) * float(feePct) / 100.0))
		_checkEq(_gold(creator), fee, "o criador recebeu o fee também no fill por bid (%d%% de 700)" % feePct)
		_checkEq(_gold(seller), 1650 + 700 - fee, "e o vendedor recebeu o líquido do fee (%d)" % _gold(seller))
		_checkEq(_ledgerRows(creatorAccount, "ah_creator_fee:"), 1, "o fee tem linha de ledger como no caminho ask")
		_checkEq(_riches(buyer, buyerAccount), rich0 - 1650 - 700, "o comprador pagou o preço do anúncio, não preço + fee")

	# A vitrine não mostra mais o que a demanda comeu.
	var page : Dictionary = _eco.call("BrowseListingsPage", 40, 0, 0, _itemBid)
	var stillOpen : int = 0
	for entry in page.get("listings", []):
		if int(entry["id"]) == listing or int(entry["id"]) == listing2:
			stillOpen += 1
	_checkEq(stillOpen, 0, "anúncios liquidados pelo bid sumiram da vitrine paginada")

	# Contabilidade da mesa, para TUDOQUANTO ainda está em pé.
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_buy_order WHERE status = 'open' AND escrow_gold <> quantity * unit_price;"), 0,
		"nenhuma ordem aberta com escrow ≠ quantity × unit_price")
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_buy_order WHERE status <> 'open' AND escrow_gold > 0;"), 0,
		"nenhuma ordem fechada com ouro preso")
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_buy_order WHERE escrow_gold < 0 OR quantity < 0;"), 0,
		"nenhum valor de ordem negativo")
	var orders : Array = _eco.call("BuyOrdersFor", buyer, 10)
	_checkEq(orders.size(), int(_eco.call("BuyOrderCount", buyerAccount)), "BuyOrdersFor devolve exatamente as ordens abertas da conta")
	for o in orders:
		_check(int(o.get("unit_price", 0)) > 0 and int(o.get("quantity", 0)) > 0, "ordem aberta bem formada")
	# Transporte da demanda existe e é fino (ouro decide no serviço).
	var server : String = _fileText("res://sources/network/server/Server.gd")
	_check(server.contains("func AuctionBid"), "Server expõe AuctionBid(item, count, unitPrice)")
	_check(server.contains("func AuctionBidCancel"), "e AuctionBidCancel(order)")
	_check(server.contains("Launcher.Economy.PlaceBuyOrder"), "o handler delega ao serviço (nenhum SQL de ouro no transporte)")
	var net : String = _fileText("res://sources/network/Network.gd")
	_check(net.contains("AuctionBid") and net.contains("AuctionBidCancel"), "Network declara as duas chamadas")
	var panel : String = _fileText("res://sources/gui/AuctionHousePanel.gd")
	_check(panel.contains("\"AuctionBid\"") and panel.contains("\"AuctionBidCancel\""), "o painel chama bid e cancel")
	# Régua de compilação do painel: `pressed.connect(_on_bid_pressed)` apontando
	# para um método que não existe derruba o script INTEIRO em tempo de parse
	# (o Gui falha ao carregar o painel e a AH desaparece da HUD), e nenhum teste
	# de comportamento do serviço percebe. Todo `connect` do arquivo precisa ter
	# alvo declarado.
	_check(_panelConnectsResolve(), "todo .connect() do painel aponta para um método declarado no arquivo")

# ------------------------------------------------- invariantes do caminho comum

# Ask e bid são duas portas do MESMO assentamento (`_SettleListingLocked`). O
# risco de acrescentar demanda é exatamente haver dois preços, dois fees e dois
# históricos. Esta suíte mede a convergência e a conservação de gold na mesa.
func _suiteSettlementInvariants() -> void:
	print("[suite] invariante: ask e bid liquidam pelo mesmo caminho (um preço, um fee, um histórico)")
	_sql.db.query("DELETE FROM auction_listing WHERE item_id = %d;" % _itemInv)
	_sql.db.query("DELETE FROM ah_price_history WHERE item_id = %d;" % _itemInv)
	var buyer : int = _makeChar("i_buyer", 100000)
	var seller : int = _makeChar("i_seller", 0)
	if not _check(buyer != 0 and seller != 0, "fixtures da suíte de invariantes criadas"):
		return
	var buyerAccount : int = int(_sql.call("GetAccountIDForCharacter", buyer))
	var sellerAccount : int = int(_sql.call("GetAccountIDForCharacter", seller))
	_eco.call("AddGems", sellerAccount, 500, "mdx_gems")
	_sql.call("AddItemToCharacter", seller, _itemInv, 4, "mdx_grant")
	var start : int = _riches(buyer, buyerAccount)
	var l1 : int = int(_eco.call("ListItemForSale", seller, _itemInv, 1, 111))
	var l2 : int = int(_eco.call("ListItemForSale", seller, _itemInv, 1, 222))
	if not _check(l1 > 0 and l2 > 0, "dois anúncios do mesmo item criados"):
		return
	_check(bool(_eco.call("BuyListing", buyer, l1)), "porta 1: compra por ask")
	_check(int(_eco.call("PlaceBuyOrder", buyer, _itemInv, 1, 222)) > 0, "porta 2: compra por bid")
	var soldCount : int = _count("SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ?;", [_itemInv])
	_checkEq(soldCount, 2, "as duas portas escreveram preço realizado")
	var unitSum : int = 0
	var vias : Dictionary = {}
	for r in _rows("SELECT via, unit_price FROM ah_price_history WHERE item_id = ?;", [_itemInv]):
		unitSum += int(r["unit_price"])
		vias[str(r["via"])] = true
	_checkEq(unitSum, 333, "o histórico guarda o PREÇO PEDIDO realizado nas duas portas (111 + 222)")
	_check(bool(vias.get("ask", false)) and bool(vias.get("bid", false)), "as duas origens aparecem no histórico")
	_checkEq(_gold(seller), 333, "o vendedor recebeu as duas vendas pelo mesmo líquido")
	_checkEq(_riches(buyer, buyerAccount), start - 333, "o comprador pagou exatamente o que o vendedor recebeu")
	_checkEq(_ledgerRows(buyerAccount, "ah_buy:"), 2, "cada venda debitou o comprador uma vez")
	_checkEq(_ledgerRows(sellerAccount, "ah_sell:"), 2, "e creditou o vendedor uma vez")
	# Ledger de gold bate com carteira + escrow nas duas pontas.
	_checkEq(int(_eco.call("GetGoldLedgerSum", buyerAccount)), _riches(buyer, buyerAccount),
		"carteira + escrow do comprador == soma do ledger de gold")
	_checkEq(int(_eco.call("GetGoldLedgerSum", sellerAccount)), _gold(seller),
		"carteira do vendedor == soma do ledger de gold")
	# Uma linha de histórico por anúncio liquidado, na mesa inteira deste harness.
	var items : String = _inItems([_itemPage, _itemHist, _itemBid, _itemInv])
	_checkEq(_count("SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id IN (%s);" % items),
		_count("SELECT COUNT(*) AS n FROM auction_listing WHERE status = 'sold' AND item_id IN (%s);" % items),
		"uma linha de histórico por anúncio liquidado (nada vendeu sem deixar memória)")
	# O UNIQUE é a régua, não o bom senso: segunda linha na mesma liquidação falha.
	_check(not _tryDuplicateHistoryRow(l1), "regravar o histórico de um anúncio liquidado falha (UNIQUE(listing_id))")
	# A migração 059 está embarcada e numerada onde o loader procura.
	var mig : String = _fileText("res://data/conf/migrations/059_ah_market_depth.sql")
	_check(mig.contains("CREATE TABLE IF NOT EXISTS ah_price_history"), "059 cria ah_price_history")
	_check(mig.contains("CREATE TABLE IF NOT EXISTS ah_buy_order"), "059 cria ah_buy_order")
	_check(mig.contains("CREATE UNIQUE INDEX IF NOT EXISTS idx_ah_price_history_listing"),
		"059 declara UNIQUE(listing_id) no histórico")
	_check(not _sqlHasDefault(mig), "059 não usa DEFAULT em coluna (regra das migrações gerenciadas)")

# Só as linhas de SQL valem: o cabeçalho da migração EXPLICA que não há DEFAULT,
# e uma régua que lê comentário passa a ser prose management.
func _sqlHasDefault(mig : String) -> bool:
	for line in mig.split("\n"):
		var t : String = str(line).strip_edges()
		if t.begins_with("--") or t.is_empty():
			continue
		if t.to_upper().contains("DEFAULT"):
			return true
	return false

func _tryDuplicateHistoryRow(listingID : int) -> bool:
	var sqlText : String = "INSERT INTO ah_price_history (listing_id, item_id, count, unit_price, price_gold, buyer_account, seller_account, via, sold_at) VALUES (%d, %d, 1, 1, 1, 1, 1, 'ask', 1);" % [listingID, _itemInv]
	var first : bool = bool(_sql.db.query(sqlText))
	var second : bool = bool(_sql.db.query(sqlText))
	_sql.db.query("DELETE FROM ah_price_history WHERE item_id = %d AND price_gold = 1;" % _itemInv)
	return first and second

# Régua de compilação da UI: `_on_*` é a convenção deste repo para callback de
# botão, e `pressed.connect(_on_x)` com `_on_x` ausente é erro de PARSE — o
# arquivo inteiro não carrega, o painel some da HUD e nenhum teste do serviço
# percebe. Varre os `connect(` do painel e exige alvo declarado.
func _panelConnectsResolve() -> bool:
	var src : String = _fileText("res://sources/gui/AuctionHousePanel.gd")
	var declared : Dictionary = {}
	for line in src.split("\n"):
		var t : String = str(line).strip_edges()
		if t.begins_with("func "):
			declared[str(t.substr(5).split("(")[0]).strip_edges()] = true
	var ok : bool = true
	var at : int = src.find(".connect(")
	while at >= 0:
		var rest : String = src.substr(at + len(".connect("))
		var ident : String = ""
		for i in range(rest.length()):
			var c : String = rest[i]
			# Para no `.` porque `pressed.connect(_on_row_pressed.bind(3))` chama
			# `_on_row_pressed` com argumento preso: o alvo a verificar é o primeiro
			# identificador, não o nome composto com o método do Callable.
			if c != "(" and c != ")" and c != "." and c != "," and c != " " and c != "\t" and c != "\r" and c != "\n":
				ident += c
			else:
				break
		if ident.begins_with("_on_") and not declared.has(ident):
			ok = false
			print("  [detalhe] connect órfão em " + ident)
		at = src.find(".connect(", at + 1)
	return ok
