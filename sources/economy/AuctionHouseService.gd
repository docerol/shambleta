extends RefCounted
class_name AuctionHouseService

# SOM-IDLE Fatia 4 (ROADMAP_COMERCIAL S3): domínio de auction house extraído de
# EconomyService (E2 listings + S2 bot seed). Composição com back-reference
# (_eco): o serviço não tem transação nem mutex próprios — usa o MESMO
# settleMutex e os MESMOS helpers raw de EconomyService, então a semântica de
# locking é 100% idêntica à de antes da extração. Os wrappers públicos ficam em
# EconomyService (callers não mudam: WorldCommands + Server via Launcher.Economy).

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
		_RecordAH("ah_list", sellerChar, {"listing" = int(out["id"]), "item" = itemID,
			"count" = count, "price_gold" = priceGold})
	return int(out["id"])

func BuyListing(buyerChar : int, listingID : int) -> bool:
	var bought : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		var sellerChar : int = int(listing["seller_char"])
		var sellerAccount : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		var price : int = int(listing["price_gold"])
		var buyerAccount : int = _eco._AccountIDForCharacterRaw(buyerChar)
		if buyerAccount == NetworkCommons.PeerUnknownID or buyerAccount == sellerAccount or buyerChar == sellerChar:
			return false
		var buyerGold : int = _eco._CharGoldRaw(buyerChar)
		if buyerGold < price:
			return false
		var sellerGold : int = _eco._CharGoldRaw(sellerChar)

		# SOM-IDLE Fase H §7: creator fee 1% — creator_account_id was captured at
		# listing time (consumed lots are deleted, so we can't re-read them).
		# Fee only fires if the creator differs from the seller.
		var creatorAccount : int = int(listing.get("creator_account_id", 0))
		var creatorFee : int = 0
		var sellerNet : int = price
		if creatorAccount != 0 and creatorAccount != sellerAccount:
			creatorFee = maxi(0, roundi(float(price) * float(EconomyCatalog.CRAFT_CREATOR_FEE_PCT) / 100.0))
			sellerNet = price - creatorFee
			# Credit the creator's gold (stat.gp on their first char)
			var creatorChars : PackedInt64Array = sql.GetCharacters(creatorAccount)
			if creatorChars.is_empty():
				return false
			var creatorChar : int = int(creatorChars[0])
			var creatorGold : int = _eco._CharGoldRaw(creatorChar)
			if not sql.UpdateRowsRaw("stat", "char_id = %d" % creatorChar, {"gp" = creatorGold + creatorFee}):
				return false
			if not _eco._LedgerAppendLocked(creatorAccount, creatorChar, EconomyCatalog.LedgerKindGold, creatorFee, creatorGold + creatorFee, "ah_creator_fee:%d" % listingID):
				return false

		if not sql.UpdateRowsRaw("stat", "char_id = %d" % buyerChar, {"gp" = buyerGold - price}):
			return false
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % sellerChar, {"gp" = sellerGold + sellerNet}):
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
		if not _eco._LedgerAppendLocked(buyerAccount, buyerChar, EconomyCatalog.LedgerKindGold, -price, buyerGold - price, "ah_buy:%d" % listingID):
			return false
		if not _eco._LedgerAppendLocked(sellerAccount, sellerChar, EconomyCatalog.LedgerKindGold, sellerNet, sellerGold + sellerNet, "ah_sell:%d" % listingID):
			return false
		# #26: o AH tinha o próprio namespace de ledger (ah_list/ah_sell/ah_buy),
		# mas esta perna — a única que ainda não tinha — escrevia `trade_in:`, o
		# mesmo formato da troca direta. Consequência medida (run K1, ledger
		# 18433): LastTradeTimestampRaw casa 'trade_out:%'/'trade_in:%', então
		# COMPRAR NO LEILÃO armava o cooldown de 60 s de troca direta no
		# comprador; e _FlagFlipTrades lia o mesmo par, abrindo flag de lavagem
		# em quem vendeu um item e o recomprou no mercado (compra pública, não
		# bilateral). O motivo do cooldown é a troca entre duas contas
		# conhecidas; o AH já tem fricção própria (ouro + taxa + slot).
		return _eco._LedgerAppendLocked(buyerAccount, buyerChar, EconomyCatalog.LedgerKindItem, count, 0, "ah_in:%d:lot%d" % [itemID, granted])):
		bought = true
	_eco.settleMutex.unlock()
	if bought:
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
