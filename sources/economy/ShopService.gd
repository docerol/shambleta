extends RefCounted
class_name ShopService

# SOM-IDLE Fatia 5 (ROADMAP_COMERCIAL S3): domínio de loja extraído de
# EconomyService (baús por gems da beta GUI + Fase B loja diária/ofertas + R2
# vendor gold). Composição com back-reference (_eco): o serviço não tem
# transação nem mutex próprios — usa o MESMO settleMutex e os MESMOS helpers raw
# de EconomyService, então a semântica de locking é 100% idêntica à de antes da
# extração. Os wrappers públicos ficam em EconomyService (Server RPC, Gui/testes
# não mudam). GetEconomyState continua agregador em EconomyService.

var _eco : EconomyService = null

# ------------------------------------------------------------------ beta GUI: shop (sink de gems) + estado consolidado das janelas

# Placeholder pricing (mesmo regime do VIP — tuning pós-beta).

# Gems -> N baús fechados (origin 'shop'). Atômico: débito, ledger e rows no
# MESMO Transaction com ops db-diretas (regra F4 — nada de update_rows aninhado;
# o mutex não re-entra em AddGems, por isso o path é raw).
# Retorna {"count", "cost", "balance"} ou {} quando rejeitado.
func BuyChests(accountID : int, charID : int, count : int) -> Dictionary:
	var result : Dictionary = {}
	if count < 1 or count > EconomyCatalog.MaxChestsPerPurchase:
		return result
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		var cost : int = EconomyCatalog.ChestCostGems * count
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -cost, balance - cost, "chest_buy:%d" % count):
			return false
		for i in count:
			if not sql.AddChestInstance(charID, 0, "shop"):
				return false
		result.clear()
		result.merge({"count" = count, "cost" = cost, "balance" = balance - cost})
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# ------------------------------------------------------------------ Fase B: loja diária + ofertas (MONETIZATION §2.6)
#
# Rotação determinística server-side (3 de 4 deals por dia), reroll pago em
# gems (3×/dia) e ofertas one-time (packs de boss, fim de temporada). Tudo
# lastreado em mecânicas existentes (baús, vip_until) — sem moeda nova.
# Reset do "dia" às 03:00 BRT (= 06:00 UTC), mesmo boundary das missões (S1).
# Packs de boss: 3 baús por 240 (save 120), um por boss vencido (ordem
# BossService.BossNames). Fim de temporada: 5 baús por 400 nas últimas 48h.

static func ShopDay(now : int) -> int:
	return EconomyCatalog.ShopDay(now)
func _RotatedDailyOffers(accountID : int, day : int, salt : int) -> Array:
	var out : Array = []
	var n : int = EconomyCatalog.DAILY_POOL.size()
	var start : int = absi(accountID + day * 7 + salt * 13) % n
	for k in EconomyCatalog.DAILY_OFFERS_SHOWN:
		var e : Dictionary = (EconomyCatalog.DAILY_POOL[(start + k) % n] as Dictionary).duplicate()
		e["claimed"] = false
		out.append(e)
	return out

# Garante a linha do dia (cria com salt 0) e aplica claimed por cima.
func _DailyRow(accountID : int, day : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT salt, offers_json, claimed_json, rerolls_used FROM shop_daily WHERE account_id = ? AND day = ?;", [accountID, day])
	if rows.is_empty():
		var offers : Array = _RotatedDailyOffers(accountID, day, 0)
		Launcher.SQL.ExecuteBindings("INSERT OR IGNORE INTO shop_daily (account_id, day, salt, offers_json, claimed_json, rerolls_used) VALUES (?, ?, 0, ?, '[]', 0);", [accountID, day, JSON.stringify(offers)])
		return {"salt": 0, "offers": offers, "claimed": [], "rerolls_used": 0}
	var row : Dictionary = rows[0]
	var offersParsed : Variant = JSON.parse_string(str(row.get("offers_json", "[]")))
	var claimedParsed : Variant = JSON.parse_string(str(row.get("claimed_json", "[]")))
	var offers : Array = offersParsed if offersParsed is Array else _RotatedDailyOffers(accountID, day, int(row.get("salt", 0)))
	var claimed : Array = claimedParsed if claimedParsed is Array else []
	for e in offers:
		(e as Dictionary)["claimed"] = str((e as Dictionary).get("id", "")) in claimed
	return {"salt": int(row.get("salt", 0)), "offers": offers, "claimed": claimed, "rerolls_used": int(row.get("rerolls_used", 0))}

func _MaxBossesBeaten(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(bosses_beaten) AS m FROM character WHERE account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

func _OneTimeOffers(accountID : int) -> Array:
	var out : Array = []
	var beaten : int = _MaxBossesBeaten(accountID)
	for i in mini(beaten, BossService.BossNames.size()):
		var oid : String = "boss-%d-pack" % i
		var claimed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT 1 FROM shop_offer_claim WHERE account_id = ? AND offer_id = ?;", [accountID, oid])
		if claimed.is_empty():
			out.append({"id": oid, "label": "%s victory pack: %d chests" % [BossService.BossNames[i], EconomyCatalog.BOSS_PACK_CHESTS],
				"kind": "chests", "count": EconomyCatalog.BOSS_PACK_CHESTS, "cost": EconomyCatalog.BOSS_PACK_COST, "claimed": false})
	var season : Dictionary = _eco.ActiveSeason()
	if not season.is_empty():
		var sid : int = int(season.get("season_id", 0))
		var left : int = int(season.get("ends_at", 0)) - SQLCommons.Timestamp()
		if sid > 0 and left > 0 and left <= EconomyCatalog.FINALE_WINDOW_SEC:
			var fid : String = "season-%d-finale" % sid
			var fclaimed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT 1 FROM shop_offer_claim WHERE account_id = ? AND offer_id = ?;", [accountID, fid])
			if fclaimed.is_empty():
				out.append({"id": fid, "label": "Season finale: %d chests" % EconomyCatalog.FINALE_CHESTS,
					"kind": "chests", "count": EconomyCatalog.FINALE_CHESTS, "cost": EconomyCatalog.FINALE_COST, "claimed": false})
	return out

func GetDailyShop(accountID : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	return {"ok": true, "day": day, "offers": row["offers"],
		"rerolls_used": int(row["rerolls_used"]), "rerolls_max": EconomyCatalog.DAILY_REROLLS_MAX,
		"reroll_cost": EconomyCatalog.DAILY_REROLL_COST, "one_time": _OneTimeOffers(accountID)}

func RerollDailyShop(accountID : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	if int(row["rerolls_used"]) >= EconomyCatalog.DAILY_REROLLS_MAX:
		return {"ok": false, "reason": "reroll_cap"}
	if not _eco.AddGems(accountID, -EconomyCatalog.DAILY_REROLL_COST, "daily_reroll"):
		return {"ok": false, "reason": "insufficient_gems"}
	return _DoReroll(accountID, day, row)

# Gira a rotação (contador compartilhado pago/ad). Chamador já validou e
# cobrou (ou registrou a view, no caso do ad).
func _DoReroll(accountID : int, day : int, row : Dictionary) -> Dictionary:
	var salt : int = int(row["salt"]) + 1
	var offers : Array = _RotatedDailyOffers(accountID, day, salt)
	var claimed : Array = row["claimed"]
	for e in offers:
		(e as Dictionary)["claimed"] = str((e as Dictionary).get("id", "")) in claimed
	Launcher.SQL.ExecuteBindings("UPDATE shop_daily SET salt = ?, offers_json = ?, rerolls_used = rerolls_used + 1 WHERE account_id = ? AND day = ?;", [salt, JSON.stringify(offers), accountID, day])
	return {"ok": true, "day": day, "offers": offers,
		"rerolls_used": int(row["rerolls_used"]) + 1, "rerolls_max": EconomyCatalog.DAILY_REROLLS_MAX,
		"reroll_cost": EconomyCatalog.DAILY_REROLL_COST, "one_time": _OneTimeOffers(accountID)}

# Compra oferta diária ou one-time. Débito + grant + marca claimed na MESMA
# transação (mesmo mutex do settle; ops raw, regra F4).
func BuyDailyOffer(accountID : int, charID : int, offerID : String) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	var offer : Dictionary = {}
	for e in row["offers"]:
		if str((e as Dictionary).get("id", "")) == offerID:
			offer = e
			break
	var oneTime : bool = false
	if offer.is_empty():
		for e in _OneTimeOffers(accountID):
			if str((e as Dictionary).get("id", "")) == offerID:
				offer = e
				oneTime = true
				break
	if offer.is_empty():
		return {"ok": false, "reason": "unknown_offer"}
	if bool(offer.get("claimed", false)):
		return {"ok": false, "reason": "already_claimed"}
	var cost : int = int(offer.get("cost", 0))
	var kind : String = str(offer.get("kind", ""))
	var count : int = int(offer.get("count", 0))
	if cost <= 0 or count <= 0 or (kind != "chests" and kind != "vip_days"):
		return {"ok": false, "reason": "bad_offer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -cost, balance - cost, "daily_offer:" + offerID):
			return false
		if kind == "chests":
			for i in count:
				if not sql.AddChestInstance(charID, 0, "daily"):
					return false
		else:
			var now : int = SQLCommons.Timestamp()
			var cur : int = sql.GetVIPUntil(accountID)
			var until : int = maxi(now, cur) + count * 86400
			if not sql.SetVIPUntil(accountID, until):
				return false
			var curTier : int = sql.GetVIPTier(accountID)
			if curTier < 1 or cur <= now:
				if not sql.SetVIPTier(accountID, 1):
					return false
		if oneTime:
			if not sql.ExecuteBindings("INSERT OR IGNORE INTO shop_offer_claim (account_id, offer_id, claimed_at) VALUES (?, ?, ?);", [accountID, offerID, SQLCommons.Timestamp()]):
				return false
		else:
			var claimed : Array = (row["claimed"] as Array).duplicate()
			claimed.append(offerID)
			if not sql.ExecuteBindings("UPDATE shop_daily SET claimed_json = ? WHERE account_id = ? AND day = ?;", [JSON.stringify(claimed), accountID, day]):
				return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = cost
		result["balance"] = balance - cost
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# ------------------------------------------------------------------ R2: vendor gold (COMMUNITY_ROADMAP)
# Loja de consumíveis por gold (poções usáveis de verdade, mesmo loop do
# auto-potion). Preço só server-side; estoque diário por oferta; sem reroll,
# sem chave de boss (não canibaliza gems/ads), sem poder permanente.

func GetVendorState(accountID : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var offers : Array = []
	for e in EconomyCatalog.VENDOR_CATALOG:
		var claimed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT count FROM vendor_claim WHERE account_id = ? AND day = ? AND offer_id = ?;", [accountID, day, str(e.get("id", ""))])
		var bought : int = int(claimed[0].get("count", 0)) if not claimed.is_empty() else 0
		var row : Dictionary = (e as Dictionary).duplicate()
		row["bought"] = bought
		row["left"] = maxi(0, EconomyCatalog.VENDOR_STOCK_PER_DAY - bought)
		offers.append(row)
	return {"ok" = true, "day" = day, "stock" = EconomyCatalog.VENDOR_STOCK_PER_DAY, "offers" = offers}

# Compra com gold do char (débito + grant + estoque na MESMA transação).
func BuyVendorOffer(accountID : int, charID : int, offerID : String) -> Dictionary:
	var offer : Dictionary = {}
	for e in EconomyCatalog.VENDOR_CATALOG:
		if str((e as Dictionary).get("id", "")) == offerID:
			offer = e
			break
	if offer.is_empty():
		return {"ok" = false, "reason" = "unknown_offer"}
	var cost : int = int(offer.get("cost", 0))
	var count : int = int(offer.get("count", 0))
	if cost <= 0 or count <= 0:
		return {"ok" = false, "reason" = "bad_offer"}
	var result : Dictionary = {"ok" = false, "reason" = "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
		var claimed : Array = []
		if sql.db.query_with_bindings("SELECT count FROM vendor_claim WHERE account_id = ? AND day = ? AND offer_id = ?;", [accountID, day, offerID]):
			claimed = sql.db.query_result
		var bought : int = int(claimed[0].get("count", 0)) if not claimed.is_empty() else 0
		if bought >= EconomyCatalog.VENDOR_STOCK_PER_DAY:
			result["reason"] = "sold_out"
			return false
		var gp : int = _eco._CharGoldRaw(charID)
		if gp < cost:
			result["reason"] = "insufficient_gold"
			return false
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - cost}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -cost, gp - cost, "vendor:" + offerID):
			return false
		var itemHash : int = str(offer.get("item", "")).hash()
		if _eco._GrantStackRaw(charID, accountID, itemHash, count, "vendor:" + offerID, "vendor") == 0:
			return false
		if claimed.is_empty():
			if not sql.db.query_with_bindings("INSERT INTO vendor_claim (account_id, day, offer_id, count) VALUES (?, ?, ?, 1);", [accountID, day, offerID]):
				return false
		elif not sql.db.query_with_bindings("UPDATE vendor_claim SET count = ? WHERE account_id = ? AND day = ? AND offer_id = ?;", [bought + 1, accountID, day, offerID]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = cost
		result["balance"] = gp - cost
		return true):
		pass
	_eco.settleMutex.unlock()
	return result
