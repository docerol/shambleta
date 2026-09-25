extends RefCounted
class_name ItemForgeService

# SOM-IDLE Fatia 6 (ROADMAP_COMERCIAL S3): domínio de forja de itens extraído de
# EconomyService (item sinks — altar de corrupção, cubagem 3:1, desmanche — e
# Fase H criação de itens com aprovação GM). Composição com back-reference
# (_eco): sem transação nem mutex próprios — usa o MESMO settleMutex, o MESMO
# roteamento de shard e os MESMOS helpers raw de EconomyService, então a
# semântica de locking é 100% idêntica à de antes da extração. Wrappers públicos
# ficam em EconomyService (Server RPC, WorldCommands e testes não mudam).

var _eco : EconomyService = null

# ------------------------------------------------------------------ item sinks (sem wipe)
# Três sumidouros voluntários (a la comunidade ARPG): altar de corrupção
# (risco estilo vaal), cubagem 3:1 e desmanche. Tudo server-side e atômico
# (settleMutex + Transaction + ops raw, com espelho no ledger). Sem wipe de
# temporada: itens só saem do jogo pela decisão do próprio jogador.
# exalted = restante (0.15): item vira equipamento aleatório de tier+1

# Queima gold dentro de transação aberta (raw; não chama AddGems — mutex).
func _BurnGoldRaw(sql : SQLService, charID : int, accountID : int, fee : int, reason : String) -> bool:
	var gp : int = _eco._CharGoldRaw(charID)
	if gp < fee:
		return false
	if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - fee}):
		return false
	return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -fee, gp - fee, reason)

# Recompensa de upgrade (corrupção exaltada / cubo): equipamento aleatório de
# tier+1 no pool da zona do char; fallback mesmo tier (outra peça); 0 se vazio.
func _RollUpgradeReward(charID : int, itemID : int, tier : int) -> int:
	var char : Dictionary = Launcher.SQL.GetCharacter(charID)
	var zoneID : int = int(char.get("farm_zone", 0) if char.get("farm_zone", 0) != null else 0)
	if zoneID <= 0:
		zoneID = 1
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	var target : int = mini(tier + 1, 8)
	var cands : Array = []
	for h in pool:
		var c : ItemCell = DB.GetItem(int(h))
		if c != null and c.slot != ActorCommons.Slot.NONE and c.tier == target and int(h) != itemID:
			cands.append(int(h))
	if cands.is_empty():
		for h in pool:
			var c2 : ItemCell = DB.GetItem(int(h))
			if c2 != null and c2.slot != ActorCommons.Slot.NONE and int(h) != itemID:
				cands.append(int(h))
	if cands.is_empty():
		return 0
	return int(cands[randi() % cands.size()])

# Altar de corrupção: consome 1 unidade + fee em gold. Selado (bound) não pode
# ser corrompido de novo — corrupção é terminal, como no PoE. forceOutcome =
# "brick"|"sealed"|"blessed"|"exalted" (testes); "" rola de verdade.
func CorruptItem(charID : int, itemID : int, forceOutcome : String = "") -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var cell : ItemCell = DB.GetItem(itemID)
	if cell == null or cell.slot == ActorCommons.Slot.NONE:
		result["reason"] = "not_equipment"
		return result
	var accountID : int = _eco._AccountIDForCharacterRaw(charID)
	if accountID == NetworkCommons.PeerUnknownID:
		result["reason"] = "no_character"
		return result
	var fee : int = EconomyCatalog.CORRUPT_FEE_BASE * maxi(cell.tier, 1) * maxi(cell.tier, 1)
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if sql.GetLotBalanceRaw(charID, itemID, false) < 1:
			result["reason"] = "no_stock"
			return false
		var outcome : String = forceOutcome
		if outcome != "brick" and outcome != "sealed" and outcome != "blessed" and outcome != "exalted":
			var r : float = randf()
			if r < EconomyCatalog.CORRUPT_BRICK_W:
				outcome = "brick"
			elif r < EconomyCatalog.CORRUPT_BRICK_W + EconomyCatalog.CORRUPT_SEALED_W:
				outcome = "sealed"
			elif r < EconomyCatalog.CORRUPT_BRICK_W + EconomyCatalog.CORRUPT_SEALED_W + EconomyCatalog.CORRUPT_BLESSED_W:
				outcome = "blessed"
			else:
				outcome = "exalted"
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, 1, false)
		if consumed.is_empty():
			result["reason"] = "consume_failed"
			return false
		if not _BurnGoldRaw(sql, charID, accountID, fee, "corrupt_fee:%d" % itemID):
			result["reason"] = "insufficient_gold"
			return false
		match outcome:
			"brick":
				if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, -1, 0, "corrupt_brick:%d" % itemID):
					return false
			"sealed":
				if _eco._GrantStackRaw(charID, accountID, itemID, 1, "corrupt_sealed:%d" % itemID, "corrupt_sealed", 1, int(consumed[0])) == 0:
					return false
			"blessed":
				var gain : int = maxi(cell.tier, 1) * 5
				var next : int = sql.AddCharacterEssence(charID, gain)
				if next < 0:
					return false
				if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindEssence, gain, next, "corrupt_blessed:%d" % itemID):
					return false
				result["essence"] = gain
			_:
				var prize : int = _RollUpgradeReward(charID, itemID, cell.tier)
				if prize <= 0:
					result["reason"] = "no_upgrade_pool"
					return false
				if _eco._GrantStackRaw(charID, accountID, prize, 1, "corrupt_exalted:%d->%d" % [itemID, prize], "corrupt_exalted", 0, int(consumed[0])) == 0:
					return false
				result["prize"] = prize
				var prizeCell : ItemCell = DB.GetItem(prize)
				result["prize_name"] = prizeCell.name if prizeCell else str(prize)
		result["ok"] = true
		result["reason"] = "ok"
		result["outcome"] = outcome
		return true):
		pass
	mutex.unlock()
	return result

# Cubagem 3:1: 3 unidades NÃO-bound do mesmo item viram 1 equipamento aleatório
# de tier+1 (linhagem via parent_uid). forceResultID = 0 rola de verdade.
func CubeUpcycle(charID : int, itemID : int, forceResultID : int = 0) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var cell : ItemCell = DB.GetItem(itemID)
	if cell == null or cell.slot == ActorCommons.Slot.NONE:
		result["reason"] = "not_equipment"
		return result
	var accountID : int = _eco._AccountIDForCharacterRaw(charID)
	if accountID == NetworkCommons.PeerUnknownID:
		result["reason"] = "no_character"
		return result
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if sql.GetLotBalanceRaw(charID, itemID, false) < EconomyCatalog.CUBE_COUNT:
			result["reason"] = "need_three"
			return false
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, EconomyCatalog.CUBE_COUNT, false)
		if consumed.is_empty():
			result["reason"] = "consume_failed"
			return false
		var prize : int = forceResultID
		if prize <= 0 or DB.GetItem(prize) == null:
			prize = _RollUpgradeReward(charID, itemID, cell.tier)
		if prize <= 0:
			result["reason"] = "no_upgrade_pool"
			return false
		if _eco._GrantStackRaw(charID, accountID, prize, 1, "cube_upcycle:%d->%d" % [itemID, prize], "cube_upcycle", 0, int(consumed[0])) == 0:
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["prize"] = prize
		var prizeCell : ItemCell = DB.GetItem(prize)
		result["prize_name"] = prizeCell.name if prizeCell else str(prize)
		return true):
		pass
	mutex.unlock()
	return result

# Desmanche: destrói 1 unidade (bound vale) e devolve gold por tier; T4+
# também rende essência (amarra no loop do rebirth).
func SalvageItem(charID : int, itemID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var cell : ItemCell = DB.GetItem(itemID)
	if cell == null or cell.slot == ActorCommons.Slot.NONE:
		result["reason"] = "not_equipment"
		return result
	var accountID : int = _eco._AccountIDForCharacterRaw(charID)
	if accountID == NetworkCommons.PeerUnknownID:
		result["reason"] = "no_character"
		return result
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if sql.GetLotBalanceRaw(charID, itemID, true) < 1:
			result["reason"] = "no_stock"
			return false
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, 1, true)
		if consumed.is_empty():
			result["reason"] = "consume_failed"
			return false
		var tier : int = maxi(cell.tier, 1)
		var gain : int = EconomyCatalog.SALVAGE_GOLD_PER_TIER2 * tier * tier
		var gp : int = _eco._CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp + gain}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, gain, gp + gain, "salvage:%d" % itemID):
			return false
		result["gold"] = gain
		if tier >= EconomyCatalog.SALVAGE_ESSENCE_TIER_MIN:
			var egain : int = EconomyCatalog.SALVAGE_ESSENCE_PER_TIER * tier
			var next : int = sql.AddCharacterEssence(charID, egain)
			if next < 0:
				return false
			if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindEssence, egain, next, "salvage_essence:%d" % itemID):
				return false
			result["essence"] = egain
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, -1, 0, "salvage_burn:%d" % itemID):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	mutex.unlock()
	return result

# ------------------------------------------------------------------ Fase H: criação de itens (ITEM_CRAFTING.md, v1 gold)
#
# Teto = melhor item REAL por (tier, slot), extraído por tools/extract_budget.py
# (soma só de valores positivos; negativos são drawback livre). Célula 0 = sem
# precedente = crafting bloqueado. Slots seguem ActorCommons.Slot (0–7).
# Pesos 1:1 = TUNING_PENDING (dado de gameplay, não economia).

func SubmitCraft(charID : int, accountID : int, slot : int, baseItemHash : int, name : String, modifiers : Dictionary) -> Dictionary:
	var result : Dictionary = {"ok" = false, "reason" = ""}
	if slot < 0 or slot > 7:
		result["reason"] = "invalid_slot"
		return result
	if baseItemHash <= 0:
		result["reason"] = "invalid_base_item"
		return result
	var cleanName : String = EconomyCatalog.CraftNormName(name)
	if not NetworkCommons.CheckSize(name.strip_edges(), 3, 30):
		result["reason"] = "invalid_name"
		return result
	if cleanName.is_empty():
		result["reason"] = "invalid_name"
		return result

	# Derive tier from baseItemHash — the visual template's slot+tier must match.
	var baseCell : ItemCell = DB.ItemsDB.get(baseItemHash, null)
	if baseCell == null:
		result["reason"] = "invalid_base_item"
		return result
	if baseCell.slot != slot:
		result["reason"] = "slot_mismatch"
		return result
	var tier : int = baseCell.tier
	if tier < 1 or tier > 8:
		result["reason"] = "invalid_tier"
		return result

	var budgetCap : int = EconomyCatalog.CraftBudgetCap(tier, slot)
	if budgetCap <= 0:
		result["reason"] = "slot_crafting_blocked"
		return result

	var budgetUsed : int = 0
	for modKey in modifiers.keys():
		var effect : int = CellCommons.Modifier.get(str(modKey), CellCommons.Modifier.None)
		if effect == CellCommons.Modifier.None:
			result["reason"] = "invalid_modifier"
			return result
		var weight : float = EconomyCatalog.CRAFT_MOD_WEIGHTS[effect] if effect < EconomyCatalog.CRAFT_MOD_WEIGHTS.size() else 0.0
		var value : int = int(modifiers[modKey])
		if value < 0:
			# Drawbacks are free-form (doc §3.1) — ignore in budget sum.
			continue
		budgetUsed += int(weight * float(value))
	if budgetUsed > budgetCap:
		result["reason"] = "budget_exceeded"
		return result

	var rarity : String = EconomyCatalog.CraftRarityForUsage(float(budgetUsed) / float(budgetCap) * 100.0)
	var fee : int = EconomyCatalog.CraftSubmitFee(tier)
	# #27: `smith_week` existia como kind com `fee_mod` no parâmetro, mas nenhum
	# caminho de código lia o valor — o evento era inerte. Esta é a taxa que ele
	# modula. Leitura pura, antes do lock (a consulta abaixo pega o queryMutex).
	fee = maxi(1, roundi(float(fee) * _eco.GetLiveEventCraftingFeeMod()))
	var now : int = SQLCommons.Timestamp()

	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var dbNode : SQLite = Launcher.SQL.db

		# D3 auth gate: email verificado
		var acctRows : Array = dbNode.select_rows("account", "account_id = %d" % accountID, ["email_verified"])
		if acctRows.is_empty() or int(acctRows[0].get("email_verified", 0)) != 1:
			result["reason"] = "email_not_verified"
			return false

		# Daily cap: CRAFT_MAX_PER_DAY submissões hoje
		var dayStart : int = now - (now % 86400)
		var todayCount : int = 0
		if dbNode.query_with_bindings(
			"SELECT COUNT(*) AS n FROM craft_submission WHERE account_id = ? AND created_at >= ?;",
			[accountID, dayStart]):
			if dbNode.query_result.size() > 0:
				todayCount = int(dbNode.query_result[0].get("n", 0))
		if todayCount >= EconomyCatalog.CRAFT_MAX_PER_DAY:
			result["reason"] = "daily_cap_reached"
			return false

		# Name blocklist + edit-distance duplicate check
		if dbNode.query_with_bindings(
			"SELECT term FROM craft_name_blocklist;", []):
			for row in dbNode.query_result:
				if cleanName.contains(str(row["term"])):
					result["reason"] = "name_blocked"
					return false
		# Check against existing official item names (edit distance < 2 = dup)
		for itemHash in DB.ItemsDB.keys():
			var existing : ItemCell = DB.ItemsDB[itemHash]
			if existing.slot == slot and EconomyCatalog.CraftEditDistance(cleanName, EconomyCatalog.CraftNormName(existing.name)) < 2:
				result["reason"] = "name_duplicate"
				return false

		# Gold fee sink
		var statRows : Array = dbNode.select_rows("stat", "char_id = %d" % charID, ["gp"])
		if statRows.is_empty():
			result["reason"] = "stat_missing"
			return false
		var gp : int = int(statRows[0].get("gp", 0)) if statRows[0].get("gp", null) != null else 0
		if gp < fee:
			result["reason"] = "insufficient_gold"
			return false
		if not Launcher.SQL.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - fee}):
			result["reason"] = "stat_update_failed"
			return false

		# Insert submission (pending)
		var modifiersJSON : String = JSON.stringify(modifiers)
		var ok : bool = dbNode.insert_row("craft_submission", {
			"account_id" = accountID, "char_id" = charID, "slot" = slot,
			"name" = name, "template_hash" = baseItemHash, "tier" = tier,
			"modifiers_json" = modifiersJSON, "budget_used" = budgetUsed,
			"rarity" = rarity, "status" = "pending", "submits_used" = 1,
			"created_at" = now, "decided_at" = 0, "decided_by" = 0,
			"decide_reason" = ""})
		if not ok:
			result["reason"] = "submission_failed"
			return false

		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -fee, gp - fee, "craft_submit_fee:tier%d_slot%d" % [tier, slot]):
			result["reason"] = "ledger_failed"
			return false

		result["ok"] = true
		result["reason"] = "pending"
		result["fee"] = fee
		return true):
		pass
	_eco.settleMutex.unlock()
	if bool(result.get("ok", false)):
		var subRows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(id) AS id FROM craft_submission WHERE char_id = ? AND created_at = ?;", [charID, now])
		result["submission_id"] = int(subRows[0]["id"]) if not subRows.is_empty() else 0
	return result

# SOM-IDLE Fase H: GM approval of a pending craft submission.
# - Updates status to 'approved', records decided_at/decided_by
# - Inserts into craft_item_template (parallel dictionary to ItemsDB)
# - Grants a bound copy to the creator (creator_account_id for future 1% fee)
# - Invalidates drop pool cache so the new item can drop
func ApproveCraftSubmission(gm : PlayerAgent, submissionID : int) -> bool:
	var gmAccount : int = Peers.GetAccount(gm.peerID) if gm != null else 0
	if gmAccount == 0 or Peers.GetPermission(gm.peerID) < ActorCommons.Permission.GM:
		return false
	_eco.settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var dbNode : SQLite = Launcher.SQL.db
		var subRow : Array[Dictionary] = dbNode.select_rows("craft_submission", "id = %d" % submissionID, ["*"])
		# Re-check status inside the transaction (race: another GM may have approved)
		if subRow.is_empty() or str(subRow[0].get("status", "")) != "pending":
			return false
		var sub : Dictionary = subRow[0]
		var now : int = SQLCommons.Timestamp()
		if not Launcher.SQL.UpdateRowsRaw("craft_submission", "id = %d" % submissionID, {
			"status" = "approved", "decided_at" = now, "decided_by" = gmAccount,
			"decide_reason" = "approved"}):
			return false
		# Register in craft_item_template (parallel to ItemsDB)
		if not dbNode.insert_row("craft_item_template", {
			"item_hash" = sub["template_hash"], "slot" = sub["slot"], "name" = sub["name"],
			"tier" = sub["tier"], "modifiers_json" = sub["modifiers_json"],
			"template_hash" = sub["template_hash"], "rarity" = sub["rarity"],
			"creator_account_id" = sub["account_id"], "created_at" = now}):
			return false
		# Invalidate drop pool cache so the new template enters the pool
		FarmZoneData.InvalidateDropPools()
		# Grant a bound copy to the creator (creator_account_id stamped on the lot)
		var charID : int = int(sub["char_id"])
		if not _eco._GrantStackRaw(charID, int(sub["account_id"]), int(sub["template_hash"]), 1,
			"craft_approve:%d" % submissionID, "craft_approve", 1, 0, int(sub["account_id"])):
			return false
		return true):
		ok = true
	_eco.settleMutex.unlock()
	if ok:
		Util.PrintLog("Economy", "Craft submission #%d approved by GM %d" % [submissionID, gmAccount])
	return ok

# SOM-IDLE Fase H: GM rejection of a pending craft submission.
# Per ITEM_CRAFTING.md §5.3: submission fee is NOT refunded (policy decision).
# Updates status to 'rejected' with reason; creator can resubmit (submits_used++).
func RejectCraftSubmission(gm : PlayerAgent, submissionID : int, reason : String) -> bool:
	var gmAccount : int = Peers.GetAccount(gm.peerID) if gm != null else 0
	if gmAccount == 0 or Peers.GetPermission(gm.peerID) < ActorCommons.Permission.GM:
		return false
	var now : int = SQLCommons.Timestamp()
	return Launcher.SQL.ExecuteBindings(
		"UPDATE craft_submission SET status = 'rejected', decided_at = ?, decided_by = ?, decide_reason = ? WHERE id = ? AND status = 'pending';",
		[now, gmAccount, reason, submissionID])
