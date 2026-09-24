extends RefCounted
class_name TradeChestService

# SOM-IDLE Fatia 11: dominio de troca e baus extraido do EconomyService
# (ROADMAP_COMERCIAL S3, ultima fatia). Trade direto char->char com escrow
# all-or-nothing, fee de gems queimado (sink primario), cooldown + teto diario
# (knobs estaticos continuam no EconomyService, que e a superficie de tuning);
# baus: abertura com pity deterministico, odds publicas, estado de pity e replay
# golden. Usa o MESMO settleMutex do EconomyService via _eco - nenhuma mudanca
# de locking.

var _eco : EconomyService = null

# ROADMAP_COMERCIAL S2: taxa e limites visíveis p/ UI (AH mostra antes de confirmar).
func GetTradeFeeState(accountID : int) -> Dictionary:
	var vip : bool = Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp()
	return {
		"fee_gems" = EconomyCatalog.TradeFeeGems,
		"cooldown_sec" = EconomyService.TradeCooldownSec,
		"daily_cap" = EconomyService.TradeDailyCapVIP if vip else EconomyService.TradeDailyCap,
		"vip" = vip,
	}

func ExecuteTrade(charIDFrom : int, charIDTo : int, itemsFrom : Array, itemsTo : Array) -> bool:
	_eco.settleMutex.lock()
	var traded : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		# No self-trade: both sides must belong to different players
		if charIDFrom == charIDTo:
			return false
		var accountFrom : int = _eco._AccountIDForCharacterRaw(charIDFrom)
		var accountTo : int = _eco._AccountIDForCharacterRaw(charIDTo)
		if accountFrom == NetworkCommons.PeerUnknownID or accountTo == NetworkCommons.PeerUnknownID:
			return false

		# SOM-IDLE D3: antifraud gates — identidade verificada, cooldown, cap diário.
		if EconomyCatalog.TradeRequireVerifiedEmail and (not sql.IsEmailVerifiedRaw(accountFrom) or not sql.IsEmailVerifiedRaw(accountTo)):
			return false
		var nowSec : int = SQLCommons.Timestamp()
		if nowSec - sql.LastTradeTimestampRaw(charIDFrom) < EconomyService.TradeCooldownSec:
			return false
		if nowSec - sql.LastTradeTimestampRaw(charIDTo) < EconomyService.TradeCooldownSec:
			return false
		# ROADMAP_COMERCIAL S2: cap diário F2P (20) vs VIP (40) — QoL, não power.
		var vipTrade : bool = sql.GetVIPUntil(accountFrom) > nowSec
		var capTrade : int = EconomyService.TradeDailyCapVIP if vipTrade else EconomyService.TradeDailyCap
		if sql.TradeCountTodayRaw(accountFrom, nowSec) >= capTrade:
			return false

		# Escrow check: every offered stack must exist with the offered count
		for stack : Dictionary in itemsFrom:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _eco._ItemCountRaw(charIDFrom, itemID) < count:
				return false
		for stack : Dictionary in itemsTo:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _eco._ItemCountRaw(charIDTo, itemID) < count:
				return false

		# Fee burn first (all-or-nothing: a failed fee aborts the whole trade).
		# wallet.gems is the source of truth; the ledger row mirrors the burn.
		var feeBalance : int = sql.GetGemsRaw(accountFrom)
		if feeBalance < EconomyCatalog.TradeFeeGems:
			return false
		if not sql.SetGemsRaw(accountFrom, feeBalance - EconomyCatalog.TradeFeeGems):
			return false
		if not _eco._LedgerAppendLocked(accountFrom, charIDFrom, EconomyCatalog.LedgerKindGems, -EconomyCatalog.TradeFeeGems, feeBalance - EconomyCatalog.TradeFeeGems, "trade_fee"):
			return false

		# Move the stacks (remove from source, add to target) — raw db ops only.
		# SOM-IDLE B1: cada perna consome lotes (FIFO, unbound) e concede lote
		# encadeado; o espelho no ledger carrega os uids (invariant 1 + history).
		for stack : Dictionary in itemsFrom:
			var mv : Dictionary = _eco._MoveStackUIDs(charIDFrom, charIDTo, int(stack["item_id"]), int(stack["count"]))
			if mv.is_empty():
				return false
			if not _eco._LedgerAppendLocked(accountFrom, charIDFrom, EconomyCatalog.LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _eco._UIDList(mv["consumed"])]):
				return false
			if not _eco._LedgerAppendLocked(accountTo, charIDTo, EconomyCatalog.LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv["granted"])]):
				return false
		for stack : Dictionary in itemsTo:
			var mv2 : Dictionary = _eco._MoveStackUIDs(charIDTo, charIDFrom, int(stack["item_id"]), int(stack["count"]))
			if mv2.is_empty():
				return false
			if not _eco._LedgerAppendLocked(accountTo, charIDTo, EconomyCatalog.LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _eco._UIDList(mv2["consumed"])]):
				return false
			if not _eco._LedgerAppendLocked(accountFrom, charIDFrom, EconomyCatalog.LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv2["granted"])]):
				return false
		return true):
		traded = true
	_eco.settleMutex.unlock()
	if traded:
		Util.PrintLog("Economy", "Trade %d -> %d executed (%d/%d stacks, fee %d gems)" % [charIDFrom, charIDTo, itemsFrom.size(), itemsTo.size(), EconomyCatalog.TradeFeeGems])
	return traded

# Opens a settle-granted chest with an odds snapshot + provably-fair seeds
# (TECH_SPEC §4 invariant 4; ECONOMY_STUDY §7). The roll is deterministic:
# hash(server_seed + client_seed + nonce) selects a stack from the tier pool
# of the character's farm zone (or zone 1 when unbound).

func OpenChest(charID : int, chestID : int) -> Dictionary:
	var result : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array[Dictionary] = sql.db.select_rows("chest_instance", "id = %d AND char_id = %d AND item_state = 'closed'" % [chestID, charID], ["*"])
		if rows.is_empty():
			return false
		var chest : Dictionary = rows[0]
		var accountID : int = _eco._AccountIDForCharacterRaw(charID)
		if accountID == NetworkCommons.PeerUnknownID:
			return false

		# Nonce = open count for this character (pity timer input)
		var nonceRows : Array[Dictionary] = sql.db.select_rows("chest_instance", "char_id = %d AND item_state = 'opened'" % charID, ["id"])
		var nonce : int = nonceRows.size()
		var serverSeed : String = str(chest["id"]) + ":" + str(chest["created_at"]) + ":shambleta"
		var clientSeed : String = str(charID) + ":" + str(nonce)
		var roll : int = Hasher.HashPassword(serverSeed, clientSeed).substr(0, 8).hex_to_int()

		# Farm zone of the character decides the item pool band
		var char : Dictionary = sql.GetCharacter(charID)
		var zoneID : int = int(char.get("farm_zone", 0) if char.get("farm_zone", 0) != null else 0)
		if zoneID <= 0:
			zoneID = 1
		var pity : bool = (nonce + 1) % EconomyCatalog.ChestPityEvery == 0
		var itemHash : int = _RollChestItem(zoneID, roll, pity)
		var count : int = 1

		# SOM-IDLE B2: snapshot de odds + server seed persistidos (dispute replay).
		var odds : Dictionary = GetChestOdds(zoneID)
		var snapshot : String = JSON.stringify({"zone" = zoneID, "pool" = odds["pool"], "tiers" = odds["tiers"], "nonce" = nonce, "pity" = pity, "pity_every" = EconomyCatalog.ChestPityEvery})

		# SOM-IDLE B1: entrega com lote (uid) + espelho no ledger (invariante 1).
		if _eco._GrantStackRaw(charID, accountID, itemHash, count, "chest:%d|%d|%s" % [chestID, itemHash, clientSeed], "chest_open") == 0:
			return false
		if not sql.UpdateRowsRaw("chest_instance", "id = %d" % chestID, {"item_state" = "opened", "odds_snapshot" = snapshot, "server_seed" = serverSeed}):
			return false

		result.clear()
		result.merge({"chest_id" = chestID, "item_id" = itemHash, "count" = count, "pity" = pity, "nonce" = nonce, "server_seed" = serverSeed, "client_seed" = clientSeed, "odds" = odds})
		return true):
		pass
	_eco.settleMutex.unlock()
	# ROADMAP_COMERCIAL S1: funil first_chest (best-effort, fora da transação).
	if not result.is_empty() and Launcher.get("Telemetry") != null and Launcher.Telemetry.has_method("RecordFunnel"):
		Launcher.Telemetry.RecordFunnel("first_chest", _eco._AccountIDForCharacterRaw(charID), charID)
	return result

# SOM-IDLE B2: public chest odds (loot-box compliance). Tier distribution of
# the zone pool + pity rule — shown BEFORE opening (/chests) and snapshotted
# per chest at open time (dispute replay: snapshot + seeds + roll algorithm).
func GetChestOdds(zoneID : int) -> Dictionary:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	var tiers : Dictionary = {}
	for itemHash in pool:
		var item : ItemCell = DB.ItemsDB.get(itemHash, null)
		var tier : int = item.tier if item != null else 0
		tiers[tier] = int(tiers.get(tier, 0)) + 1
	return {"zone" = zoneID, "pool" = pool.size(), "tiers" = tiers, "pity_every" = EconomyCatalog.ChestPityEvery}

func GetChestOddsForCharacter(charID : int) -> Dictionary:
	var zoneID : int = 1
	var rows : Array = Launcher.SQL.db.select_rows("character", "char_id = %d" % charID, ["farm_zone"])
	if not rows.is_empty() and rows[0].get("farm_zone", null) != null:
		zoneID = maxi(1, int(rows[0]["farm_zone"]))
	return GetChestOdds(zoneID)

# Contador de pity por personagem: quantos baús faltam para o raro garantido.
# Leitura pura (sem lock); mesma fonte de nonce do OpenChest (chest_instance
# opened). Exposto no EconomyState para a UI mostrar "raro garantido em N".
func GetChestPityStatus(charID : int) -> Dictionary:
	var every : int = EconomyCatalog.ChestPityEvery
	var opened : int = 0
	var rows : Array = Launcher.SQL.db.select_rows("chest_instance", "char_id = %d AND item_state = 'opened'" % charID, ["id"])
	opened = rows.size()
	var sincePity : int = opened % every
	var toPity : int = every - sincePity
	if toPity <= 0:
		toPity = every
	return {"opened" = opened, "since_pity" = sincePity, "to_pity" = toPity, "pity_every" = every}

func FormatChestOdds(odds : Dictionary) -> String:
	var parts : PackedStringArray = PackedStringArray()
	var tiers : Dictionary = odds.get("tiers", {})
	var total : int = maxi(1, int(odds.get("pool", 1)))
	var keys : Array = tiers.keys()
	keys.sort()
	for tier in keys:
		parts.append("T%d %.1f%%" % [int(tier), 100.0 * float(tiers[tier]) / float(total)])
	return "Zona %d (pool %d: %s; pity T3+ a cada %d)" % [int(odds.get("zone", 1)), int(odds.get("pool", 0)), ", ".join(parts), int(odds.get("pity_every", EconomyCatalog.ChestPityEvery))]

# Deterministic chest roll: pity forces a T3+ band, otherwise the zone band.
func _RollChestItem(zoneID : int, roll : int, pity : bool) -> int:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	if pity:
		var rare : Array[int] = []
		for itemHash in pool:
			var item : ItemCell = DB.ItemsDB.get(itemHash, null)
			if item != null and item.tier >= 3:
				rare.append(itemHash)
		if not rare.is_empty():
			return rare[roll % rare.size()]
	# Fall back to the zone pool (Apple included)
	return FarmZoneData.GetDropForRoll(zoneID, roll)
