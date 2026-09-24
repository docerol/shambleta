extends RefCounted
class_name GuildService

# SOM-IDLE Fatia 2 (ROADMAP_COMERCIAL S3): guild domain extraído de
# EconomyService. Composição com back-reference (_eco): o serviço não tem
# transação nem mutex próprios — usa o MESMO settleMutex e os MESMOS helpers
# raw de EconomyService, então a semântica de locking é 100% idêntica à de
# antes da extração (nenhum risco novo de concorrência). Os wrappers públicos
# ficam em EconomyService (callers não mudam).

var _eco : EconomyService = null

# ------------------------------------------------------------------ E1: guilds
# Custo de nível 1→2 .. 9→10 (índice = nível atual). Pontos: coluna pronta,
# acúmulo via settle = fast follow (v0 = gold+gems).

func GetGuildForAccount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int(rows[0]["guild_id"]) if not rows.is_empty() else 0

func GetGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id, name, level, points, leader_account, created_at FROM guild WHERE guild_id = ?;", [guildID])
	return {} if rows.is_empty() else rows[0]

func GetMemberRank(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str(rows[0]["rank"]) if not rows.is_empty() else ""

func GuildBuffForAccount(accountID : int) -> float:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT g.level FROM guild g INNER JOIN guild_member m ON m.guild_id = g.guild_id WHERE m.account_id = ?;", [accountID])
	if rows.is_empty():
		return 1.0
	return 1.0 + EconomyCatalog.GuildBuffPerLevel * float(maxi(0, int(rows[0]["level"]) - 1))

func GetGuildLeaderboard(limit : int = 10) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT g.guild_id, g.name, g.level, g.points, COUNT(m.account_id) AS members FROM guild g LEFT JOIN guild_member m ON m.guild_id = g.guild_id GROUP BY g.guild_id ORDER BY g.level DESC, g.points DESC, members DESC LIMIT ?;", [limit])

func CreateGuild(accountID : int, charID : int, guildName : String) -> int:
	var clean : String = guildName.strip_edges()
	if not NetworkCommons.CheckSize(clean, 3, 30) or GetGuildForAccount(accountID) != 0:
		return 0
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if _eco._CharGoldRaw(charID) < EconomyCatalog.GuildCreateCostGold:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild (name, level, points, leader_account, created_at) VALUES (?, 1, 0, ?, ?);", [clean, accountID, SQLCommons.Timestamp()]):
			return false
		var guildID : int = sql.LastInsertRowIDRaw()
		if guildID <= 0:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'leader', ?);", [guildID, accountID, SQLCommons.Timestamp()]):
			return false
		var gp : int = _eco._CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - EconomyCatalog.GuildCreateCostGold}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -EconomyCatalog.GuildCreateCostGold, gp - EconomyCatalog.GuildCreateCostGold, "guild_create"):
			return false
		out["id"] = guildID
		return true):
		pass
	_eco.settleMutex.unlock()
	return int(out["id"])

func JoinGuild(accountID : int, guildID : int) -> bool:
	if GetGuildForAccount(accountID) != 0 or GetGuild(guildID).is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);", [guildID, accountID, SQLCommons.Timestamp()])

func LeaveGuild(accountID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var left : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var members : Array = sql.db.select_rows("guild_member", "guild_id = %d ORDER BY joined_at" % guildID, ["account_id", "rank"])
		if members.is_empty():
			return false
		var isLeader : bool = false
		for m in members:
			if int(m["account_id"]) == accountID and str(m["rank"]) == "leader":
				isLeader = true
		if members.size() == 1:
			# Último membro dissolve a guild — vault precisa estar vazio (sem perda).
			if not sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"]).is_empty():
				return false
			if not sql.DeleteRowsRaw("guild_member", "guild_id = %d" % guildID):
				return false
			return sql.DeleteRowsRaw("guild", "guild_id = %d" % guildID)
		if not sql.DeleteRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, accountID]):
			return false
		if isLeader:
			# Promove o membro mais antigo a líder.
			for m in members:
				if int(m["account_id"]) != accountID:
					return sql.UpdateRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, int(m["account_id"])], {"rank" = "leader"}) \
						and sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"leader_account" = int(m["account_id"])})
			return false
		return true):
		left = true
	_eco.settleMutex.unlock()
	return left

func DepositToVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _eco._ItemCountRaw(charID, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID]):
			return false
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty():
			# Fase F: teto de stacks distintas (expansível por nível/compra).
			var distinct : Array = sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"])
			if distinct.size() >= VaultSlotsForGuild(guildID).get("cap", 0):
				return false
			if not sql.db.insert_row("guild_vault", {"guild_id" = guildID, "item_id" = itemID, "count" = count}):
				return false
		elif not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = int(vault[0]["count"]) + count}):
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'deposit', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()]):
			return false
		return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, -count, 0, "vault_deposit:%d:%d" % [guildID, itemID])):
		ok = true
	_eco.settleMutex.unlock()
	return ok

func WithdrawFromVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty() or int(vault[0]["count"]) < count:
			return false
		var remain : int = int(vault[0]["count"]) - count
		if remain > 0:
			if not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = remain}):
				return false
		elif not sql.DeleteRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID]):
			return false
		if _eco._GrantStackRaw(charID, accountID, itemID, count, "vault_withdraw:%d:%d" % [guildID, itemID], "vault_withdraw") == 0:
			return false
		return sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'withdraw', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()])):
		ok = true
	_eco.settleMutex.unlock()
	return ok

func LevelUpGuild(accountID : int, charID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= EconomyCatalog.GuildMaxLevel:
			return false
		var costGold : int = EconomyCatalog.GuildLevelCostGold[level]
		var costGems : int = EconomyCatalog.GuildLevelCostGems[level]
		if _eco._CharGoldRaw(charID) < costGold:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < costGems:
			return false
		var gp : int = _eco._CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - costGold}):
			return false
		if not sql.SetGemsRaw(accountID, gems - costGems):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -costGold, gp - costGold, "guild_level"):
			return false
		return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -costGems, gems - costGems, "guild_level")):
		ok = true
	_eco.settleMutex.unlock()
	return ok

func PromoteMember(leaderAccount : int, targetAccount : int) -> bool:
	if GetMemberRank(leaderAccount) != "leader":
		return false
	if GetGuildForAccount(targetAccount) != GetGuildForAccount(leaderAccount) or GetGuildForAccount(leaderAccount) == 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild_member SET rank = 'officer' WHERE account_id = ?;", [targetAccount])

# Follow-up G3: tag da guild (2–5 chars A-Z0-9, só líder). Exibida no board,
# no painel e nas corridas ([TAG] Nome) — identidade sem poder.
func SetGuildTag(accountID : int, tag : String) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	if GetMemberRank(accountID) != "leader":
		return {"ok": false, "reason": "not_leader"}
	var clean : String = tag.strip_edges().to_upper()
	if not EconomyCatalog.IsValidGuildTag(clean):
		return {"ok": false, "reason": "bad_tag"}
	if not Launcher.SQL.ExecuteBindings("UPDATE guild SET tag = ? WHERE guild_id = ?;", [clean, guildID]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "tag": clean}

# ------------------------------------------------------------------ Fase F: guild premium (MONETIZATION §1 item 10)
#
# Pontos acumulam no settle (1/hora) e na vitória de boss (+5): a corrida
# guild_points da temporada nasce daqui. Level-up fast pula o gold (2× gems).
# Vault tem teto de stacks distintas (10 + 2/nível + comprados, máx +20).

func AddGuildPoints(guildID : int, points : int) -> bool:
	if guildID <= 0 or points <= 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild SET points = points + ? WHERE guild_id = ?;", [points, guildID])

# Chamado no settle (dentro da transação do caller): 1 pt/hora liquidada.
func GuildSettlePoints(accountID : int, hours : float) -> void:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID > 0:
		AddGuildPoints(guildID, maxi(1, floori(hours)))

func VaultSlotsForGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT level, vault_slots_purchased FROM guild WHERE guild_id = ?;", [guildID])
	if rows.is_empty():
		return {"cap": 0, "used": 0, "purchased": 0}
	var cap : int = EconomyCatalog.GUILD_VAULT_BASE_SLOTS + EconomyCatalog.GUILD_VAULT_PER_LEVEL * maxi(0, int(rows[0].get("level", 1)) - 1) + int(rows[0].get("vault_slots_purchased", 0))
	var used : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM guild_vault WHERE guild_id = ?;", [guildID])
	return {"cap": cap, "used": int(used[0]["n"]) if not used.is_empty() else 0, "purchased": int(rows[0].get("vault_slots_purchased", 0))}

func GetGuildState(accountID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	var mine : Dictionary = {}
	if guildID > 0:
		var g : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild WHERE guild_id = ?;", [guildID])
		var members : Array = []
		for m in Launcher.SQL.QueryBindings("SELECT a.username, gm.rank FROM guild_member AS gm INNER JOIN account AS a ON a.account_id = gm.account_id WHERE gm.guild_id = ? ORDER BY gm.rank, a.username;", [guildID]):
			members.append({"name": str(m.get("username", "?")), "rank": str(m.get("rank", "member"))})
		if not g.is_empty():
			mine = {"id": guildID, "name": str(g[0].get("name", "?")), "tag": str(g[0].get("tag", "")),
				"level": int(g[0].get("level", 1)),
				"points": int(g[0].get("points", 0)), "my_rank": GetMemberRank(accountID),
				"vault": VaultSlotsForGuild(guildID), "members": members}
	var board : Array = []
	for b in Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild ORDER BY points DESC, guild_id ASC LIMIT 10;", []):
		board.append({"name": str(b.get("name", "?")), "tag": str(b.get("tag", "")), "level": int(b.get("level", 1)), "points": int(b.get("points", 0))})
	return {"ok": true, "my_guild": mine, "board": board,
		"vault_slot_cost": EconomyCatalog.GUILD_VAULT_SLOT_COST}

# Level-up fast (leader/officer): pula o gold pagando 2× gems.
func LevelUpGuildFast(accountID : int, charID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return {"ok": false, "reason": "not_officer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= EconomyCatalog.GuildMaxLevel:
			result["reason"] = "max_level"
			return false
		var cost : int = EconomyCatalog.GuildLevelCostGems[level] * 2
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < cost:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - cost):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -cost, gems - cost, "guild_level_fast"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = cost
		result["level"] = level + 1
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# Expansão do vault (leader/officer): +1 stack distinta por 200 gems (máx 20).
func BuyVaultSlots(accountID : int, charID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return {"ok": false, "reason": "not_officer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["vault_slots_purchased"])
		if rows.is_empty():
			return false
		var bought : int = int(rows[0].get("vault_slots_purchased", 0))
		if bought >= EconomyCatalog.GUILD_VAULT_SLOTS_MAX:
			result["reason"] = "slots_cap"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.GUILD_VAULT_SLOT_COST:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.GUILD_VAULT_SLOT_COST):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"vault_slots_purchased" = bought + 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -EconomyCatalog.GUILD_VAULT_SLOT_COST, gems - EconomyCatalog.GUILD_VAULT_SLOT_COST, "guild_vault_slots"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = bought + 1
		return true):
		pass
	_eco.settleMutex.unlock()
	return result
