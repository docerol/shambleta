extends RefCounted
class_name AuctionHouseService

# SOM-IDLE Fatia 4 (ROADMAP_COMERCIAL S3): domínio de auction house extraído de
# EconomyService (E2 listings + S2 bot seed). Composição com back-reference
# (_eco): o serviço não tem transação nem mutex próprios — usa o MESMO
# settleMutex e os MESMOS helpers raw de EconomyService, então a semântica de
# locking é 100% idêntica à de antes da extração. Os wrappers públicos ficam em
# EconomyService (callers não mudam: WorldCommands + Server via Launcher.Economy).
# Gold de leilão (compra, crédito ao vendedor e fee ao criador) passa pelo
# caminho único do kernel — _eco.kernel._MoveGoldLocked na transação +
# ApplyGoldMoves no commit — porque SQL.UpdateStat persiste o stat row como
# snapshot da memória: escrita crua em stat.gp sem o espelho evapora no ciclo de
# backup de 600 s. Gems não: wallet é account-level e não tem espelho em memória.

var _eco : EconomyService = null

# ------------------------------------------------------------------ S2: AH bot seed
# A AH nasce morta sem oferta (cold start clássico de marketplace). Bots de
# sistema listam consumíveis do vendor a preço-âncora (~20% acima); jogador
# compra pelo caminho NORMAL (BuyListing), o gold do jogador paga o bot e fica
# retido (sink — o bot nunca recompra, então o estoque é finito por design).
# Trava T5-style: SHAMBLETA_AH_BOTS=1 (staging/soft-launch liga; beta off).

static func AHBotsEnabled() -> bool:
	return OS.get_environment("SHAMBLETA_AH_BOTS") == "1"

var _ahBotsChecked : bool = false

# Boot-once via _process (server): roda quando o SQL abre, decide uma vez e
# nunca mais pergunta. `SHAMBLETA_AH_BOTS` é do processo e não muda depois do
# boot; com a trava desligada — que é o estado do beta — a versão antiga fazia
# um `OS.get_environment` por frame no main thread do server, para sempre.
func _trySeedAuctionBots():
	if _ahBotsChecked:
		return
	_ahBotsChecked = true
	if not AHBotsEnabled():
		return
	var created : int = EnsureAuctionBots()
	if created > 0:
		Util.PrintLog("Economy", "AH bot seed: %d listings" % created)

# Idempotente: garante 1 conta/char de bot + 1 open listing por seed (uid
# marker no escrow). Retorna quantos listings NOVOS criou.
func EnsureAuctionBots() -> int:
	if not AHBotsEnabled():
		return 0
	var sql : SQLService = Launcher.SQL
	var created : int = 0
	_eco.settleMutex.lock()
	for botIndex in EconomyCatalog.AH_BOT_ACCOUNTS.size():
		var botUser : String = EconomyCatalog.AH_BOT_ACCOUNTS[botIndex]
		var spec : Dictionary = EconomyCatalog.AH_BOT_LISTINGS[botIndex % EconomyCatalog.AH_BOT_LISTINGS.size()]
		var itemHash : int = str(spec.get("item", "")).hash()
		# já seedado? QUALQUER listing do bot p/ o item (open OU sold) → pula.
		# Estoque finito por design: bot não reabastece (senão vira faucet de
		# gold/itens sem custo — o sink do comprador precisa ficar retido).
		var botAccount : int = sql.GetAccountID(botUser)
		if botAccount != NetworkCommons.PeerUnknownID:
			var existing : Array = sql.QueryBindings("SELECT id FROM auction_listing WHERE seller_account = ? AND item_id = ?;", [botAccount, itemHash])
			if not existing.is_empty():
				continue
		var botChar : int = 0
		if botAccount == NetworkCommons.PeerUnknownID:
			if not sql.AddAccount(botUser, Hasher.GenerateSalt(), botUser + "@system.local"):
				continue
			botAccount = sql.GetAccountID(botUser)
			if botAccount == NetworkCommons.PeerUnknownID:
				continue
			if not sql.AddCharacter(botAccount, botUser, ActorCommons.DefaultStats, ActorCommons.DefaultTraits, ActorCommons.DefaultAttributes):
				continue
		botChar = sql.GetCharacterID(botAccount, botUser)
		if botChar == NetworkCommons.PeerUnknownID:
			continue
		# transação: stock (lot) + listagem (consume + escrow), sem fee de gem
		# (bots não têm carteira; o sink real é o gold do comprador, retido)
		if not sql.Transaction(func() -> bool:
			var qty : int = int(spec.get("count", 1))
			if not sql.AddItemToCharacter(botChar, itemHash, qty, "ah_bot_seed"):
				return false
			var consumed : Array = sql.ConsumeItemLotsRaw(botChar, itemHash, qty, false)
			if consumed.is_empty():
				return false
			var stock : int = _eco._ItemCountRaw(botChar, itemHash)
			if stock > qty:
				if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, botChar], {"count" = stock - qty}):
					return false
			elif stock > 0 and not stock == qty:
				return false
			elif stock == qty:
				if not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, botChar]):
					return false
			if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, creator_account_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, 'open', ?);", [botChar, botAccount, itemHash, qty, int(spec.get("price", 1)), _eco._UIDList(consumed), SQLCommons.Timestamp()]):
				return false
			return _eco._LedgerAppendLocked(botAccount, botChar, EconomyCatalog.LedgerKindItem, -qty, 0, "ah_list:%d:uids%s" % [itemHash, _eco._UIDList(consumed)])):
			continue
		created += 1
	_eco.settleMutex.unlock()
	return created

# ------------------------------------------------------------------ E2: listings
# Escrow em lots, taxa flat queimada. Destaque pago (15 gems, fila em cima) +
# slots extras (+1 por 50×(n+1) gems, máx +5). Taxa flat e guards RMT inalterados.

func AHOpenCap(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	return EconomyCatalog.AHMaxOpenPerAccount + mini(maxi(extra, 0), EconomyCatalog.AHSlotsMaxExtra)

func BuyAHSlot(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	if extra >= EconomyCatalog.AHSlotsMaxExtra:
		return {"ok": false, "reason": "slots_cap"}
	var cost : int = EconomyCatalog.AHSlotBaseCost * (extra + 1)
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < cost:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - cost):
			return false
		if not sql.ExecuteBindings("INSERT OR REPLACE INTO ah_slots (account_id, extra) VALUES (?, ?);", [accountID, extra + 1]):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -cost, gems - cost, "ah_slot"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = EconomyCatalog.AHMaxOpenPerAccount + extra + 1
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

func HighlightListing(accountID : int, listingID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["seller_account", "highlight"])
		if rows.is_empty():
			result["reason"] = "not_found"
			return false
		if int(rows[0].get("seller_account", 0)) != accountID:
			result["reason"] = "not_yours"
			return false
		if int(rows[0].get("highlight", 0)) == 1:
			result["reason"] = "already_highlighted"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.AHHighlightFeeGems:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.AHHighlightFeeGems):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"highlight" = 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -EconomyCatalog.AHHighlightFeeGems, gems - EconomyCatalog.AHHighlightFeeGems, "ah_highlight_fee"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

func BrowseListings(limit : int = 20) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE status = 'open' ORDER BY highlight DESC, id DESC LIMIT ?;", [limit])

# ------------------------------------------------------------------ JUIZ MARKETPLACE 2026-09-27
# Três pernas que faltavam no leilão: PÁGINA (offset + filtro no servidor, com o
# total para a régua de páginas), MEMÓRIA (preço realizado em `ah_price_history`,
# migração 059) e DEMANDA (ordem de compra com gold em escrow, espelho do escrow
# de item de `ListItemForSale`). Nada aqui decide ouro, taxa ou saldo por fora do
# kernel: cada movimento de gold passa por `_eco.kernel._MoveGoldLocked` dentro
# da transação e por `ApplyGoldMoves` no commit, pela mesma razão documentada no
# cabeçalho deste arquivo (o snapshot de 600 s de `SQL.UpdateStat` apaga escrita
# crua em `stat.gp`).

# (b) Página de verdade. O teto de 40 linhas de antes (`AHMaxBrowseWindow` em
# Server.gd) sobrevive como TAMANHO de página; quem pagina é o servidor, com
# OFFSET, e quem filtra é o SQL (`maxPrice`/`itemID`, 0 = sem filtro).
func BrowseListingsPage(limit : int, offset : int, maxPrice : int, itemID : int) -> Dictionary:
	var size : int = clampi(limit, 1, EconomyCatalog.AHBrowsePageSize)
	var start : int = maxi(0, offset)
	var where : String = "status = 'open'"
	var params : Array = []
	if itemID > 0:
		where += " AND item_id = ?"
		params.append(itemID)
	if maxPrice > 0:
		where += " AND price_gold <= ?"
		params.append(maxPrice)
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE %s ORDER BY highlight DESC, id DESC LIMIT ? OFFSET ?;" % where,
		params + [size, start])
	var countParams : Array = params.duplicate()
	var totalRows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COUNT(*) AS n FROM auction_listing WHERE %s;" % where, countParams)
	var total : int = int(totalRows[0].get("n", 0)) if not totalRows.is_empty() else 0
	return {
		"ok" = true,
		"listings" = rows,
		"total" = total,
		"offset" = start,
		"page_size" = size,
		"max_page" = maxi(0, int(ceil(float(total) / float(size))) - 1),
	}

# (a) Preço REALIZADO. O painel lê daqui em vez da própria memória de sessão
# (`AuctionHouseWindow._history`), então "o que este item vendeu" sobrevive ao
# fechar a janela, é o mesmo para duas contas e não depende de a venda ter
# acontecido NAQUELA sessão.
func RecentSoldPrices(itemID : int, limit : int) -> Array[Dictionary]:
	var size : int = clampi(limit, 1, 50)
	if itemID > 0:
		return Launcher.SQL.QueryBindings("SELECT listing_id, item_id, count, unit_price, price_gold, via, sold_at FROM ah_price_history WHERE item_id = ? ORDER BY sold_at DESC, id DESC LIMIT ?;", [itemID, size])
	return Launcher.SQL.QueryBindings("SELECT listing_id, item_id, count, unit_price, price_gold, via, sold_at FROM ah_price_history ORDER BY sold_at DESC, id DESC LIMIT ?;", [size])

# Resumo numérico do preço realizado + o menor ask aberto da mesma faixa: é o
# par "quanto foi / quanto pedem" que falta a quem vai pôr um preço.
func RecentSoldSummary(itemID : int, limit : int) -> Dictionary:
	var rows : Array[Dictionary] = RecentSoldPrices(itemID, limit)
	var sum : int = 0
	var low : int = 0
	var high : int = 0
	var last : int = 0
	for row in rows:
		var unit : int = int(row.get("unit_price", 0))
		sum += unit
		if low == 0 or unit < low:
			low = unit
		if unit > high:
			high = unit
		if last == 0:
			last = unit
	var asks : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COALESCE(MIN(CAST(price_gold AS INTEGER) / MAX(count, 1)), 0) AS unit FROM auction_listing WHERE status = 'open' AND item_id = ?;", [itemID])
	# MIN() sobre zero linhas é NULL, não 0, e `int(null)` é erro de runtime no
	# GDScript (a chamada INTEIRA de `RecentSoldSummary` arrebentava no item sem
	# anúncios abertos — exatamente o estado de um item que acabou de esvaziar).
	var askRaw : Variant = asks[0].get("unit", 0) if not asks.is_empty() else null
	var askUnit : int = 0 if askRaw == null else int(askRaw)
	return {
		"samples" = rows.size(),
		"avg_unit" = int(round(float(sum) / float(maxi(1, rows.size())))) if not rows.is_empty() else 0,
		"low_unit" = low,
		"high_unit" = high,
		"last_unit" = last,
		"ask_unit" = askUnit,
	}

# Uma venda liquidada vira UMA linha de histórico, na mesma transação que move o
# ouro — ou a venda não aconteceu. `UNIQUE(listing_id)` (migração 059) é o que
# torna a segunda tentativa na mesma linha um erro visível em vez de dois
# registros de um mesmo fato.
func _RecordSoldLocked(sql : SQLService, listing : Dictionary, buyerAccount : int, via : String) -> bool:
	var count : int = maxi(1, int(listing.get("count", 1)))
	var price : int = int(listing.get("price_gold", 0))
	return sql.db.query_with_bindings("INSERT INTO ah_price_history (listing_id, item_id, count, unit_price, price_gold, buyer_account, seller_account, via, sold_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);", [
		int(listing.get("id", 0)), int(listing.get("item_id", 0)), count,
		maxi(1, int(round(float(price) / float(count)))), price,
		buyerAccount, int(listing.get("seller_account", 0)), via, SQLCommons.Timestamp()])

func ListItemForSale(sellerChar : int, itemID : int, count : int, priceGold : int) -> int:
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		return 0
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _eco._AccountIDForCharacterRaw(sellerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			return false
		var openRows : Array = sql.db.select_rows("auction_listing", "seller_account = %d AND status = 'open'" % accountID, ["id"])
		if openRows.size() >= AHOpenCap(accountID):
			return false
		if _eco._ItemCountRaw(sellerChar, itemID) < count:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.AHListFeeGems:
			return false
		# SOM-IDLE Fase H §7: capture creator_account_id BEFORE consume deletes lots
		# (ConsumeItemLotsRaw deletes item_instance rows). Read from the seller's
		# existing lots, defaulting to 0 (non-crafted items → no fee).
		var creatorAccount : int = 0
		var lots : Array = sql.db.select_rows("item_instance", "char_id = %d AND item_id = %d AND storage = 0 AND bound = 0" % [sellerChar, itemID], ["uid", "creator_account_id"])
		for lot in lots:
			var ca : int = int(lot.get("creator_account_id", 0))
			if ca != 0:
				creatorAccount = ca
				break
		var consumed : Array = sql.ConsumeItemLotsRaw(sellerChar, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _eco._ItemCountRaw(sellerChar, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar]):
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.AHListFeeGems):
			return false
		if not _eco._LedgerAppendLocked(accountID, sellerChar, EconomyCatalog.LedgerKindGems, -EconomyCatalog.AHListFeeGems, gems - EconomyCatalog.AHListFeeGems, "ah_list_fee"):
			return false
		if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, creator_account_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?);", [sellerChar, accountID, itemID, count, priceGold, _eco._UIDList(consumed), creatorAccount, SQLCommons.Timestamp()]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		if int(out["id"]) <= 0:
			return false
		return _eco._LedgerAppendLocked(accountID, sellerChar, EconomyCatalog.LedgerKindItem, -count, 0, "ah_list:%d:uids%s" % [itemID, _eco._UIDList(consumed)])):
		pass
	_eco.settleMutex.unlock()
	if int(out["id"]) > 0:
		# 059(c): anúncio novo cruza a melhor ordem de compra aberta ANTES de
		# voltar para a vitrine — é assim que um mercado com demanda forma preço.
		# Roda depois do commit do anúncio (com o lock já solto) de propósito: se
		# o cruzamento falhar por qualquer motivo, o anúncio continua vivo e a
		# taxa de anúncio não foi paga duas vezes.
		var matched : int = _TryMatchListing(int(out["id"]))
		_RecordAH("ah_list", sellerChar, {"listing" = int(out["id"]), "item" = itemID,
			"count" = count, "price_gold" = priceGold, "via" = "bid" if matched > 0 else "ask"})
	return int(out["id"])

# Liquidação de um anúncio: UM caminho para as duas origens da demanda — o
# comprador que aceita um ask (`BuyListing`) e a ordem de compra que cruza o ask
# (`PlaceBuyOrder`, `ListItemForSale`). Ordem dos movimentos de ouro, fee do
# criador, entrega do lote em escrow, ledger de item e linha de histórico são os
# mesmos nos dois lados: bifurcar isso é exatamente a classe de defeito que o
# fuzzer de invariantes caça (duas operações legalmente individuais, um centavo
# a mais ou a menos conforme o caminho).
func _SettleListingLocked(sql : SQLService, listing : Dictionary, buyerChar : int, buyerAccount : int, via : String, goldMoves : Dictionary) -> bool:
	var listingID : int = int(listing.get("id", 0))
	var sellerChar : int = int(listing.get("seller_char", 0))
	var sellerAccount : int = int(listing.get("seller_account", 0))
	var itemID : int = int(listing.get("item_id", 0))
	var count : int = int(listing.get("count", 1))
	var price : int = int(listing.get("price_gold", 0))
	if listingID <= 0 or itemID <= 0 or count <= 0 or price <= 0:
		return false
	# Nunca comprar de si mesmo — vale para o ask e para o bid cruzado.
	if buyerAccount == NetworkCommons.PeerUnknownID or buyerAccount == sellerAccount or buyerChar == sellerChar:
		return false
	# SOM-IDLE Fase H §7: creator fee 1% — `creator_account_id` foi capturado no
	# anúncio (os lotes consumidos já não existem). Só fire se o criador não é o
	# vendedor, e sai do preço: o comprador nunca paga duas vezes.
	var creatorAccount : int = int(listing.get("creator_account_id", 0))
	var creatorFee : int = 0
	var sellerNet : int = price
	if creatorAccount != 0 and creatorAccount != sellerAccount:
		creatorFee = maxi(0, roundi(float(price) * float(CraftCatalog.CREATOR_FEE_PCT) / 100.0))
		sellerNet = price - creatorFee
		# Credit the creator's gold (stat.gp on their first char)
		var creatorChars : PackedInt64Array = sql.GetCharacters(creatorAccount)
		if creatorChars.is_empty():
			return false
		if not _eco.kernel._MoveGoldLocked(sql, int(creatorChars[0]), creatorAccount, creatorFee, "ah_creator_fee:%d" % listingID, goldMoves):
			return false
	if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, -price, "ah_buy:%d" % listingID, goldMoves):
		return false
	if not _eco.kernel._MoveGoldLocked(sql, sellerChar, sellerAccount, sellerNet, "ah_sell:%d" % listingID, goldMoves):
		return false
	var parentUID : int = int(str(listing.get("escrow_uids", "0")).split(",")[0])
	var granted : int = sql.GrantItemLotRaw(buyerChar, itemID, count, "ah_buy", 0, "", parentUID)
	if granted == 0:
		return false
	var existing : Array = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], ["count"])
	if existing.is_empty():
		if not sql.db.insert_row("item", {"item_id" = itemID, "char_id" = buyerChar, "count" = count, "storage" = 0, "customfield" = ""}):
			return false
	elif not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], {"count" = int(existing[0]["count"]) + count}):
		return false
	if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "sold"}):
		return false
	# 059(a): o preço realizado nasce DENTRO deste commit. Sem o par "venda +
	# histórico" na mesma transação, o histórico seria uma projeção do cliente.
	if not _RecordSoldLocked(sql, listing, buyerAccount, via):
		return false
	# #26: o AH tinha o próprio namespace de ledger (ah_list/ah_sell/ah_buy),
	# mas esta perna — a única que ainda não tinha — escrevia `trade_in:`, o
	# mesmo formato da troca direta. Consequência medida (run K1, ledger
	# 18433): LastTradeTimestampRaw casa 'trade_out:%'/'trade_in:%', então
	# COMPRAR NO LEILÃO armava o cooldown de 60 s de troca direta no
	# comprador; e _FlagFlipTrades lia o mesmo par, abrindo flag de lavagem em
	# quem vendeu um item e o recomprou no mercado (compra pública, não
	# bilateral). O motivo do cooldown é a troca entre duas contas conhecidas;
	# o AH já tem fricção própria (ouro + taxa + slot).
	return _eco._LedgerAppendLocked(buyerAccount, buyerChar, EconomyCatalog.LedgerKindItem, count, 0, "ah_in:%d:lot%d" % [itemID, granted])

func BuyListing(buyerChar : int, listingID : int) -> bool:
	var bought : bool = false
	# Deltas de gold aplicados no banco pela transação, espelhados no agente
	# carregado depois do commit (EconomyKernel._MoveGoldLocked). Sem o espelho,
	# o snapshot absoluto de SQL.UpdateStat (RefreshCharacter, ciclo de 600 s)
	# escrevia de volta o gold antigo: o comprador ficava com o que gastou e o
	# vendedor perdia o que recebeu.
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		var buyerAccount : int = _eco._AccountIDForCharacterRaw(buyerChar)
		if buyerAccount == NetworkCommons.PeerUnknownID:
			return false
		# Pré-checagem do saldo só refina o motivo; o kernel recusa carteira
		# negativa de qualquer forma.
		if _eco._CharGoldRaw(buyerChar) < int(listing.get("price_gold", 0)):
			return false
		return _SettleListingLocked(sql, listing, buyerChar, buyerAccount, "ask", goldMoves)):
		# O flag é escrito FORA do lambda, de propósito: lambda GDScript captura
		# locais por valor, então `bought = true` dentro da closure não chegava
		# aqui — a compra dava commit, movia ouro e item no banco, e o RPC
		# respondia falso (e `ApplyGoldMoves` nunca espelhava o delta na memória,
		# que é exatamente o que o snapshot de 600 s revertia).
		bought = true
	_eco.settleMutex.unlock()
	if bought:
		_eco.kernel.ApplyGoldMoves(goldMoves)
		_RecordAH("ah_buy", buyerChar, {"listing" = listingID})
	return bought

# K1: AH sem evento é marketplace no escuro — quantos anunciam, quantos compram,
# quantos desistem (e o último é o que diz se o preço está errado). É ouro/gems de
# jogo, não dinheiro, então vai pelo funil comum (buffer de 60 s) em vez do
# caminho de flush imediato do `purchase`. Sempre fora da transação: o flush da
# telemetria pega o queryMutex, e chamá-lo de dentro do lambda seria lock
# recursivo numa Mutex não-recursiva.
func _RecordAH(kind : String, charID : int, meta : Dictionary) -> void:
	if Launcher.Telemetry == null:
		return
	Launcher.Telemetry.RecordFunnel(kind, _eco._AccountIDForCharacterRaw(charID), charID, JSON.stringify(meta))

func CancelListing(charID : int, listingID : int) -> bool:
	var done : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty() or int(rows[0]["seller_char"]) != charID:
			return false
		var listing : Dictionary = rows[0]
		var accountID : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		if _eco._GrantStackRaw(charID, accountID, itemID, count, "ah_cancel:%d" % listingID, "ah_cancel") == 0:
			return false
		return sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "cancelled"})):
		done = true
	_eco.settleMutex.unlock()
	if done:
		_RecordAH("ah_cancel", charID, {"listing" = listingID})
	return done

# ------------------------------------------------------------------ 059(c): ordens de compra (bid)
# O leilão tinha só oferta: sem demanda depositada, o spread não fecha e "preço
# justo" é o que o vendedor acha justo. Uma ordem de compra é o espelho exato de
# um anúncio — onde o anúncio tranca ITEM por uid (`ListItemForSale`, acima), a
# ordem tranca GOLD pela conta do kernel. Depósito: `ah_bid_escrow:<ordem>`;
# cruzamento: libera o valor das unidades na carteira e a mesma
# `_SettleListingLocked` paga vendedor e criador (o caminho único do fee, sem
# segunda versão dele); sobra volta como `ah_bid_release:<ordem>`; cancelamento
# devolve o inteiro depósito. Preenchimento parcial é a regra: `quantity` é
# regressiva e o escrow acompanha, unidade a unidade.
#
# Invariante de contabilidade que o fuzzer pressiona: em todo instante
# `escrow_gold == quantity × unit_price` para ordem aberta, e a carteira do
# comprador já foi debitada desse valor. O ouro do escrow NÃO existe na carteira
# de ninguém enquanto a ordem estiver em pé — é o mesmo estatuto do item em
# escrow de um anúncio, e é por isso que a ordem que preenche recebe o depósito
# DE VOLTA na carteira antes de pagar: um débito duplo no comprador (escrow + o
# `-price` do assentamento) seria criar gold do nada no vendedor.

func BuyOrderCount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ah_buy_order WHERE buyer_account = ? AND status = 'open';", [accountID])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func BuyOrdersFor(charID : int, limit : int) -> Array[Dictionary]:
	return BuyOrdersForAccount(_eco._AccountIDForCharacterRaw(charID), charID, limit)

# Órdenes abertas da CONTA (o cap é por conta, não por personagem), já com o nome
# do item: `item_id` é um hash e escrow sem rosto não é decisão — quem cancela uma
# ordem precisa saber qual item está travando ouro dele. O nome vem do catálogo
# local do servidor (`DB.ItemsDB`), nunca do pacote do cliente; vazio = item que o
# servidor não conhece (o painel cai em "item <id>").
#
# O pedido por personagem continua restrito à própria conta: a linha de ordem é
# apenas visibilidade, e a chave de quem pode cancelá-la é `buyer_char`
# (`CancelBuyOrder`), conferida no servidor contra a sessão.
func BuyOrdersForAccount(accountID : int, charID : int, limit : int) -> Array[Dictionary]:
	if accountID == NetworkCommons.PeerUnknownID:
		return []
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, buyer_char, item_id, quantity, unit_price, escrow_gold, status, created_at FROM ah_buy_order WHERE buyer_account = ? AND status = 'open' ORDER BY id DESC LIMIT ?;", [accountID, clampi(limit, 1, 50)])
	for row in rows:
		row["item_name"] = str(_ItemName(int(row.get("item_id", 0))))
		# O personagem que pediu é o único que vê o botão de cancelar na linha.
		row["mine"] = int(row.get("buyer_char", 0)) == charID
	return rows

func _ItemName(itemID : int) -> String:
	if DB.ItemsDB == null or not DB.ItemsDB.has(itemID):
		return ""
	var cell : ItemCell = DB.ItemsDB.get(itemID, null)
	return str(cell.name) if cell != null else ""

func BuyOrderRow(orderID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, buyer_char, buyer_account, item_id, quantity, unit_price, escrow_gold, status, created_at FROM ah_buy_order WHERE id = ?;", [orderID])
	return {} if rows.is_empty() else rows[0]

# Depósito do escrow + linha da ordem, numa transação só. A ordem nasce com
# `escrow_gold = 0` e só ganha valor depois do `_MoveGoldLocked` passar: se o
# débito recusar (carteira insuficiente), o rollback leva a linha e não existe
# ordem sem ouro — o inverso seria demanda falsificada de graça.
func PlaceBuyOrder(buyerChar : int, itemID : int, count : int, unitPrice : int) -> int:
	if itemID <= 0 or count <= 0 or unitPrice <= 0:
		return 0
	if count > EconomyCatalog.AHMaxBidQuantity or unitPrice > EconomyCatalog.AHMaxBidUnitPrice:
		return 0
	var escrow : int = count * unitPrice
	if escrow <= 0 or escrow > EconomyCatalog.AHMaxBuyOrderGold:
		return 0
	var out : Dictionary = {"id" = 0}
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _eco._AccountIDForCharacterRaw(buyerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			return false
		if BuyOrderCount(accountID) >= EconomyCatalog.AHMaxBuyOrdersPerAccount:
			return false
		if _eco._CharGoldRaw(buyerChar) < escrow:
			return false
		if not sql.db.query_with_bindings("INSERT INTO ah_buy_order (buyer_char, buyer_account, item_id, quantity, unit_price, escrow_gold, status, created_at) VALUES (?, ?, ?, ?, ?, 0, 'open', ?);", [buyerChar, accountID, itemID, count, unitPrice, SQLCommons.Timestamp()]):
			return false
		var orderID : int = sql.LastInsertRowIDRaw()
		if orderID <= 0:
			return false
		if not _eco.kernel._MoveGoldLocked(sql, buyerChar, accountID, -escrow, "ah_bid_escrow:%d" % orderID, goldMoves):
			return false
		if not sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, {"escrow_gold" = escrow}):
			return false
		out["id"] = orderID
		return true):
		pass
	_eco.settleMutex.unlock()
	var orderID : int = int(out["id"])
	if orderID <= 0:
		return 0
	_eco.kernel.ApplyGoldMoves(goldMoves)
	_FillFromBuyOrder(orderID)
	_RecordAH("ah_bid", buyerChar, {"order" = orderID, "item" = itemID, "count" = count, "unit_price" = unitPrice, "escrow_gold" = escrow})
	return orderID

# Cancelar é o espelho do cancelamento de anúncio: devolve o depósito inteiro e
# fecha a linha. Sem taxa de volta — a fricção do leilão é a mesma dos dois lados.
func CancelBuyOrder(charID : int, orderID : int) -> bool:
	var done : bool = false
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("ah_buy_order", "id = %d AND status = 'open'" % orderID, ["buyer_char", "buyer_account", "escrow_gold"])
		if rows.is_empty() or int(rows[0].get("buyer_char", 0)) != charID:
			return false
		var accountID : int = int(rows[0].get("buyer_account", 0))
		var held : int = int(rows[0].get("escrow_gold", 0))
		if held > 0 and not _eco.kernel._MoveGoldLocked(sql, charID, accountID, held, "ah_bid_release:%d" % orderID, goldMoves):
			return false
		return sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, {"status" = "cancelled", "escrow_gold" = 0})):
		# Escrito fora do lambda pelo mesmo motivo documentado em `BuyListing`.
		done = true
	_eco.settleMutex.unlock()
	if done:
		_eco.kernel.ApplyGoldMoves(goldMoves)
		_RecordAH("ah_bid_cancel", charID, {"order" = orderID})
	return done

# A ordem varre a vitrine enquanto houver demanda coberta. Uma rodada = um
# anúncio liquidado = um commit com o lock próprio; o laço para quando nada
# fecha ou quando o teto de rodadas chega (uma ordem nunca pode traver o
# main thread do servidor num laço sobre um mercado grande).
func _FillFromBuyOrder(orderID : int) -> int:
	var units : int = 0
	for passN in EconomyCatalog.AHMaxBidFillRounds:
		var goldMoves : Dictionary = {}
		# Dicionário e não `var`: lambda GDScript captura locais por valor, então
		# um inteiro escrito dentro da closure não chega aqui (lição documentada em
		# `BuyListing`). `Dictionary` é referência — o conteúdo atravessa.
		var tally : Dictionary = {"units" = 0, "listing" = 0, "char" = 0}
		_eco.settleMutex.lock()
		var done : bool = Launcher.SQL.Transaction(func() -> bool:
			var sql : SQLService = Launcher.SQL
			var rows : Array = sql.db.select_rows("ah_buy_order", "id = %d AND status = 'open'" % orderID, ["*"])
			if rows.is_empty():
				return false
			var order : Dictionary = rows[0]
			var need : int = int(order.get("quantity", 0))
			var unitCap : int = int(order.get("unit_price", 0))
			var held : int = int(order.get("escrow_gold", 0))
			var buyerChar : int = int(order.get("buyer_char", 0))
			var buyerAccount : int = int(order.get("buyer_account", 0))
			if need <= 0 or unitCap <= 0:
				return false
			# Escrow menor que a demanda é ordem corrompida: recusar preencher é
			# mais barato que descobrir tarde que se está pagando vendedor com ouro
			# que ninguém depositou.
			if held < need * unitCap:
				return false
			var itemID : int = int(order.get("item_id", 0))
			var candidates : Array = sql.db.select_rows("auction_listing", "status = 'open' AND item_id = %d AND price_gold <= %d AND count <= %d AND seller_account != %d" % [itemID, unitCap, need, buyerAccount], ["*"])
			var best : Dictionary = {}
			for cand in candidates:
				var c : Dictionary = cand
				if best.is_empty():
					best = c
					continue
				if int(c.get("price_gold", 0)) < int(best.get("price_gold", 0)):
					best = c
				elif int(c.get("price_gold", 0)) == int(best.get("price_gold", 0)) and int(c.get("id", 0)) < int(best.get("id", 0)):
					best = c
			if best.is_empty():
				return false
			var qty : int = int(best.get("count", 1))
			var cost : int = int(best.get("price_gold", 0))
			var heldFor : int = qty * unitCap
			# Devolve as unidades ao comprador e deixa a `_SettleListingLocked`
			# cobrá-las: é o MESMO caminho do fee e do ledger de uma compra normal,
			# e o único jeito de o preço realizado das duas origens bater.
			if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, heldFor, "ah_bid_release:%d" % orderID, goldMoves):
				return false
			if not _SettleListingLocked(sql, best, buyerChar, buyerAccount, "bid", goldMoves):
				return false
			var remain : int = need - qty
			var newEscrow : int = maxi(0, held - heldFor)
			if remain <= 0 and newEscrow > 0:
				if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, newEscrow, "ah_bid_release:%d" % orderID, goldMoves):
					return false
				newEscrow = 0
			var patch : Dictionary = {"quantity" = maxi(0, remain), "escrow_gold" = newEscrow, "status" = "open" if remain > 0 else "filled"}
			if not sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, patch):
				return false
			tally["units"] = qty
			tally["listing"] = int(best.get("id", 0))
			tally["char"] = buyerChar
			return true)
		_eco.settleMutex.unlock()
		if not done:
			break
		_eco.kernel.ApplyGoldMoves(goldMoves)
		units += int(tally["units"])
		_RecordAH("ah_bid_fill", int(tally["char"]), {"order" = orderID, "listing" = int(tally["listing"]), "units" = int(tally["units"])})
	return units

# Anúncio novo pede passagem pela melhor ordem aberta (maior teto primeiro, em
# empate a mais antiga). Devolve o id do anúncio se ele foi liquidado a bid.
func _TryMatchListing(listingID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT seller_account, item_id, count, price_gold FROM auction_listing WHERE id = ? AND status = 'open';", [listingID])
	if rows.is_empty():
		return 0
	var listing : Dictionary = rows[0]
	var orders : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM ah_buy_order WHERE status = 'open' AND item_id = ? AND unit_price >= ? AND quantity >= ? AND buyer_account != ? ORDER BY unit_price DESC, id ASC LIMIT 1;", [int(listing.get("item_id", 0)), int(listing.get("price_gold", 0)), int(listing.get("count", 1)), int(listing.get("seller_account", 0))])
	if orders.is_empty():
		return 0
	if _FillFromBuyOrder(int(orders[0]["id"])) <= 0:
		return 0
	var after : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status FROM auction_listing WHERE id = ?;", [listingID])
	if not after.is_empty() and str(after[0].get("status", "")) == "sold":
		return listingID
	return 0
