extends RefCounted
class_name TournamentArenaService

# SOM-IDLE Fatia 9: dominio de competicao extraido do EconomyService
# (ROADMAP_COMERCIAL S3). Fase F - torneios semanais (inscricao com entrada em
# gems, leaderboard, settle com premios, tick de ciclo e reconciliacao diaria R-1)
# e R4 - arena assimetrica offline (tickets, defesa registrada, ataque com
# resolacao deterministica + ELO, board). Composicao com back-reference: este
# servico NAO tem mutex proprio - toda mutacao passa pelo settleMutex do
# EconomyService via _eco, exatamente como antes da fatia.

var _eco : EconomyService = null

# ------------------------------------------------------------------ R4: async arena (COMMUNITY_ROADMAP)
# Arena assíncrona: defesa = snapshot de poder do char; ataque = ticket diário.
# Ranking por ELO simplificado com reset semanal; recompensa em cosméticos/títulos.
# Servidor simula os dois lados (sem RNG do cliente); derrota não tira nada do
# defensor (atacar é sempre seguro psicologicamente).

func TickArenaTickets() -> Dictionary:
	var now : int = SQLCommons.Timestamp()
	var dayStart : int = now - (now % 86400)
	var refilled : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT account_id, ticket_reset_at FROM arena_entry;", []):
		var accountID : int = int(row["account_id"])
		var resetAt : int = int(row["ticket_reset_at"])
		if resetAt < dayStart:
			var tickets : int = EconomyCatalog.ARENA_TICKETS_PER_DAY
			var vipUntil : int = Launcher.SQL.GetVIPUntil(accountID)
			if vipUntil > now:
				tickets += EconomyCatalog.ARENA_TICKETS_VIP_BONUS
			if Launcher.SQL.ExecuteBindings("UPDATE arena_entry SET tickets = ?, ticket_reset_at = ? WHERE account_id = ?;", [tickets, dayStart, accountID]):
				refilled += 1
	return {"refilled": refilled}

func ArenaSetDefense(charID : int) -> Dictionary:
	var accountID : int = _eco._AccountIDForCharacterRaw(charID)
	if accountID == 0:
		return {"ok": false, "reason": "no_character"}
	var powerScore : int = 0
	var powerRow : Array = Launcher.SQL.QueryBindings("SELECT power_score FROM character WHERE char_id = ?;", [charID])
	if not powerRow.is_empty():
		powerScore = int(powerRow[0].get("power_score", 0))
	var snapshot : String = JSON.stringify({"char_id": charID, "power": powerScore, "ts": SQLCommons.Timestamp()})
	var now : int = SQLCommons.Timestamp()
	var existing : Array = Launcher.SQL.QueryBindings("SELECT account_id FROM arena_entry WHERE account_id = ?;", [accountID])
	if existing.is_empty():
		var tickets : int = EconomyCatalog.ARENA_TICKETS_PER_DAY
		var vipUntil : int = Launcher.SQL.GetVIPUntil(accountID)
		if vipUntil > now:
			tickets += EconomyCatalog.ARENA_TICKETS_VIP_BONUS
		Launcher.SQL.ExecuteBindings("INSERT INTO arena_entry (account_id, tickets, ticket_reset_at, defense_char_id, defense_snapshot, updated_at) VALUES (?, ?, ?, ?, ?, ?);", [accountID, tickets, now, charID, snapshot, now])
	else:
		Launcher.SQL.ExecuteBindings("UPDATE arena_entry SET defense_char_id = ?, defense_snapshot = ?, updated_at = ? WHERE account_id = ?;", [charID, snapshot, now, accountID])
	_EnsureArenaLadder(accountID)
	return {"ok": true, "power": powerScore}

func _EnsureArenaLadder(accountID : int) -> void:
	var existing : Array = Launcher.SQL.QueryBindings("SELECT account_id FROM arena_ladder WHERE account_id = ?;", [accountID])
	if existing.is_empty():
		Launcher.SQL.ExecuteBindings("INSERT INTO arena_ladder (account_id, elo, wins, losses, updated_at) VALUES (?, ?, 0, 0, ?);", [accountID, EconomyCatalog.ARENA_BASE_ELO, SQLCommons.Timestamp()])

func ArenaAttack(attackerCharID : int, defenderAccountID : int) -> Dictionary:
	var attackerAcct : int = _eco._AccountIDForCharacterRaw(attackerCharID)
	if attackerAcct == 0:
		return {"ok": false, "reason": "no_attacker"}
	if attackerAcct == defenderAccountID:
		return {"ok": false, "reason": "self_attack"}
	var now : int = SQLCommons.Timestamp()
	var attackerRow : Array = Launcher.SQL.QueryBindings("SELECT tickets FROM arena_entry WHERE account_id = ?;", [attackerAcct])
	if attackerRow.is_empty() or int(attackerRow[0].get("tickets", 0)) <= 0:
		return {"ok": false, "reason": "no_tickets"}
	var defenderRow : Array = Launcher.SQL.QueryBindings("SELECT defense_char_id, defense_snapshot FROM arena_entry WHERE account_id = ? AND defense_char_id > 0;", [defenderAccountID])
	if defenderRow.is_empty():
		return {"ok": false, "reason": "no_defense"}
	var attackerPower : int = 0
	var attackerPowerRow : Array = Launcher.SQL.QueryBindings("SELECT power_score FROM character WHERE char_id = ?;", [attackerCharID])
	if not attackerPowerRow.is_empty():
		attackerPower = int(attackerPowerRow[0].get("power_score", 0))
	var defenderCharID : int = int(defenderRow[0].get("defense_char_id", 0))
	var defenderPower : int = 0
	var defenderPowerRow : Array = Launcher.SQL.QueryBindings("SELECT power_score FROM character WHERE char_id = ?;", [defenderCharID])
	if not defenderPowerRow.is_empty():
		defenderPower = int(defenderPowerRow[0].get("power_score", 0))
	var win : bool = attackerPower >= defenderPower
	var attackerElo : int = EconomyCatalog.ARENA_BASE_ELO
	var attackerLadder : Array = Launcher.SQL.QueryBindings("SELECT elo FROM arena_ladder WHERE account_id = ?;", [attackerAcct])
	if not attackerLadder.is_empty():
		attackerElo = int(attackerLadder[0].get("elo", EconomyCatalog.ARENA_BASE_ELO))
	var newAttackerElo : int = maxi(100, attackerElo + (EconomyCatalog.ARENA_ELO_K if win else -EconomyCatalog.ARENA_ELO_K))
	_EnsureArenaLadder(attackerAcct)
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var curTickets : Array = sql.db.select_rows("arena_entry", "account_id = %d" % attackerAcct, ["tickets"])
		if curTickets.is_empty() or int(curTickets[0].get("tickets", 0)) <= 0:
			return false
		if not sql.UpdateRowsRaw("arena_entry", "account_id = %d" % attackerAcct, {"tickets": int(curTickets[0].get("tickets", 0)) - 1}):
			return false
		var ladder : Array = sql.db.select_rows("arena_ladder", "account_id = %d" % attackerAcct, ["wins", "losses"])
		var w : int = int(ladder[0].get("wins", 0)) if not ladder.is_empty() else 0
		var l : int = int(ladder[0].get("losses", 0)) if not ladder.is_empty() else 0
		if not sql.UpdateRowsRaw("arena_ladder", "account_id = %d" % attackerAcct, {"elo": newAttackerElo, "wins": w + (1 if win else 0), "losses": l + (0 if win else 1), "updated_at": now}):
			return false
		result["ok"] = true
		return true):
		pass
	_eco.settleMutex.unlock()
	if not bool(result.get("ok", false)):
		return {"ok": false, "reason": "rejected"}
	return {"ok": true, "win": win, "attacker_power": attackerPower, "defender_power": defenderPower, "new_attacker_elo": newAttackerElo}

func ArenaBoard(accountID : int, limit : int = 10) -> Dictionary:
	var myRow : Array = Launcher.SQL.QueryBindings("SELECT elo, wins, losses FROM arena_ladder WHERE account_id = ?;", [accountID])
	var my : Dictionary = {}
	if not myRow.is_empty():
		my = {"elo": int(myRow[0].get("elo", EconomyCatalog.ARENA_BASE_ELO)), "wins": int(myRow[0].get("wins", 0)), "losses": int(myRow[0].get("losses", 0))}
	var top : Array = Launcher.SQL.QueryBindings("SELECT a.account_id, a.elo, a.wins, a.losses, acc.username FROM arena_ladder a INNER JOIN account acc ON acc.account_id = a.account_id ORDER BY a.elo DESC, a.account_id ASC LIMIT ?;", [limit])
	var board : Array = []
	for row in top:
		board.append({"account_id": int(row["account_id"]), "username": str(row.get("username", "?")), "elo": int(row["elo"]), "wins": int(row["wins"]), "losses": int(row["losses"])})
	return {"ok": true, "my": my, "top": board}


# ------------------------------------------------------------------ Fase F: torneios (MONETIZATION §1 item 11)
#
# Copas assíncronas de poder: inscrição em GOLD (sink), ranking por ganho de
# power na janela, prêmios em gems + título de Campeão. Entrada NUNCA em
# dinheiro (risco loteria/azar no BR). Rotação semanal automática no job diário.

func ActiveTournament() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT tournament_id, name, entry_gold, starts_at, ends_at, status FROM tournament WHERE status = 'active' ORDER BY tournament_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

func EnsureWeeklyTournament() -> int:
	if not ActiveTournament().is_empty():
		return int(ActiveTournament()["tournament_id"])
	var now : int = SQLCommons.Timestamp()
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		if not ActiveTournament().is_empty():
			return false
		if not Launcher.SQL.ExecuteBindings("INSERT INTO tournament (name, entry_gold, starts_at, ends_at, status, prizes_json) VALUES (?, ?, ?, ?, 'active', ?);", ["Copa Semanal", EconomyCatalog.TOURNAMENT_ENTRY_GOLD, now, now + EconomyCatalog.TOURNAMENT_DAYS * 86400, JSON.stringify(EconomyCatalog.TOURNAMENT_PRIZES)]):
			return false
		out["id"] = Launcher.SQL.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	_eco.settleMutex.unlock()
	return int(out["id"])

func GetTournaments(accountID : int) -> Dictionary:
	var t : Dictionary = ActiveTournament()
	if t.is_empty():
		return {"ok": true, "active": {}, "my_entry": {}}
	var tid : int = int(t.get("tournament_id", 0))
	var mine : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_start, power_end FROM tournament_entry WHERE tournament_id = ? AND account_id = ?;", [tid, accountID])
	var entries : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM tournament_entry WHERE tournament_id = ?;", [tid])
	return {"ok": true, "active": {"id": tid, "name": str(t.get("name", "?")), "entry_gold": int(t.get("entry_gold", 0)),
		"ends_at": int(t.get("ends_at", 0)), "players": int(entries[0]["n"]) if not entries.is_empty() else 0,
		"prizes": EconomyCatalog.TOURNAMENT_PRIZES}, "my_entry": mine[0] if not mine.is_empty() else {}}

func EnterTournament(accountID : int, charID : int, tournamentID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("tournament", "tournament_id = %d AND status = 'active'" % tournamentID, ["entry_gold", "ends_at"])
		if rows.is_empty():
			result["reason"] = "not_open"
			return false
		if SQLCommons.Timestamp() > int(rows[0].get("ends_at", 0)):
			result["reason"] = "not_open"
			return false
		if not sql.QueryBindings("SELECT account_id FROM tournament_entry WHERE tournament_id = ? AND account_id = ?;", [tournamentID, accountID]).is_empty():
			result["reason"] = "already_entered"
			return false
		var fee : int = int(rows[0].get("entry_gold", 0))
		var gp : int = _eco._CharGoldRaw(charID)
		if gp < fee:
			result["reason"] = "insufficient_gold"
			return false
		var power : Array = sql.db.select_rows("character", "char_id = %d" % charID, ["power_score"])
		var start : int = int(power[0].get("power_score", 0)) if not power.is_empty() and power[0].get("power_score", null) != null else 0
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - fee}):
			return false
		if not sql.ExecuteBindings("INSERT INTO tournament_entry (tournament_id, account_id, char_id, power_start) VALUES (?, ?, ?, ?);", [tournamentID, accountID, charID, start]):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -fee, gp - fee, "tournament_entry:%d" % tournamentID):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# Liquida um torneio vencido: power_end = power atual, rank por ganho,
# prêmios em gems + título ao campeão. Idempotente por status.
func SettleTournament(tournamentID : int) -> Dictionary:
	var out : Dictionary = {"ok": false, "reason": "rejected", "awarded": 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("tournament", "tournament_id = %d" % tournamentID, ["status"])
		if rows.is_empty() or str(rows[0].get("status", "")) != "active":
			out["reason"] = "not_active"
			return false
		var now : int = SQLCommons.Timestamp()
		var ends : Array = sql.db.select_rows("tournament", "tournament_id = %d" % tournamentID, ["ends_at"])
		if int(ends[0].get("ends_at", now + 1)) > now:
			out["reason"] = "not_ended"
			return false
		var entries : Array[Dictionary] = sql.QueryBindings("SELECT account_id, char_id, power_start FROM tournament_entry WHERE tournament_id = ?;", [tournamentID])
		var ranked : Array = []
		for e in entries:
			var prow : Array = sql.db.select_rows("character", "char_id = %d" % int(e["char_id"]), ["power_score"])
			var pend : int = int(prow[0].get("power_score", 0)) if not prow.is_empty() and prow[0].get("power_score", null) != null else 0
			sql.ExecuteBindings("UPDATE tournament_entry SET power_end = ? WHERE tournament_id = ? AND account_id = ?;", [pend, tournamentID, int(e["account_id"])])
			ranked.append({"account_id": int(e["account_id"]), "char_id": int(e["char_id"]), "gain": pend - int(e["power_start"])})
		ranked.sort_custom(func(a : Dictionary, b : Dictionary) -> bool:
			if int(a["gain"]) != int(b["gain"]):
				return int(a["gain"]) > int(b["gain"])
			return int(a["char_id"]) < int(b["char_id"]))
		var awarded : int = 0
		for rank in mini(ranked.size(), EconomyCatalog.TOURNAMENT_PRIZES.size()):
			var prize : int = EconomyCatalog.TOURNAMENT_PRIZES[rank]
			var acct : int = int(ranked[rank]["account_id"])
			var balance : int = sql.GetGemsRaw(acct)
			if not sql.SetGemsRaw(acct, balance + prize):
				return false
			if not _eco._LedgerAppendLocked(acct, int(ranked[rank]["char_id"]), EconomyCatalog.LedgerKindGems, prize, balance + prize, "tournament_prize:%d:%d" % [tournamentID, rank + 1]):
				return false
			if rank == 0:
				sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [acct, EconomyCatalog.TOURNAMENT_CHAMPION_TITLE, "tournament:%d" % tournamentID, now])
			awarded += 1
		if not sql.UpdateRowsRaw("tournament", "tournament_id = %d" % tournamentID, {"status" = "settled"}):
			return false
		out["ok"] = true
		out["reason"] = "settled"
		out["awarded"] = awarded
		return true):
		pass
	_eco.settleMutex.unlock()
	return out

# Ciclo do job diário: liquida vencidos + garante a copa da semana.
func TickTournaments() -> Dictionary:
	var settled : int = 0
	var now : int = SQLCommons.Timestamp()
	for row in Launcher.SQL.QueryBindings("SELECT tournament_id FROM tournament WHERE status = 'active' AND ends_at <= ?;", [now]):
		var res : Dictionary = SettleTournament(int(row["tournament_id"]))
		if bool(res.get("ok", false)):
			settled += 1
	var active : Dictionary = ActiveTournament()
	var created : int = 0
	if active.is_empty():
		created = 1 if EnsureWeeklyTournament() > 0 else 0
	return {"settled": settled, "created": created}

# BuyListing / CancelListing: wrappers na seção E2 acima (Fatia 4 → AuctionHouseService.gd).

# Daily reconciliation: ledger gold sums must match stat.gp deltas per account;
# no account may hold a negative balance. Returns number of divergences found.
func ReconcileDaily() -> int:
	var divergences : int = 0
	# SOM-IDLE E: escopo em contas existentes (linhas de fixtures deletados em
	# test-runs não são reconciliáveis — mesma regra dos lots).
	var negatives : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'gold' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += negatives.size()

	# XP rows must never be negative either
	var xpNeg : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'xp' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += xpNeg.size()

	# SOM-IDLE B1: soma dos lotes ativos deve espelhar a stack agregada
	# (storage 0, personagens existentes — órfãos de runs/fixtures excluídos).
	var stackMismatch : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT i.char_id FROM item i WHERE i.storage = 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = i.char_id) AND i.count != COALESCE((SELECT SUM(count) FROM item_instance WHERE item_instance.char_id = i.char_id AND item_instance.item_id = i.item_id AND item_instance.storage = i.storage AND item_instance.customfield = i.customfield), -1);")
	divergences += stackMismatch.size()
	var orphanLots : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT s.char_id FROM (SELECT char_id, item_id, storage, customfield, SUM(count) AS lots FROM item_instance GROUP BY char_id, item_id, storage, customfield) AS s WHERE s.lots != 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = s.char_id) AND NOT EXISTS (SELECT 1 FROM item WHERE item.char_id = s.char_id AND item.item_id = s.item_id AND item.storage = s.storage AND item.customfield = s.customfield);")
	divergences += orphanLots.size()

	return divergences

# SOM-IDLE D2: daily reconcile job — roda após o backup diário (SQLBackups)
# e registra a divergência para o dashboard. Best-effort, nunca derruba o loop.
func RunReconcileJob() -> int:
	var divergences : int = ReconcileDaily()
	Launcher.SQL.ExecuteBindings("INSERT INTO reconcile_run (created_at, divergences) VALUES (?, ?);", [SQLCommons.Timestamp(), divergences])
	if divergences > 0:
		Util.PrintLog("Economy", "Reconcile found %d divergences" % divergences)
	var flagged : int = _eco.RunFraudScan()
	if flagged > 0:
		Util.PrintLog("Economy", "Fraud scan opened %d flags" % flagged)
	# SOM-IDLE (3b): ciclo de vida de temporada (fecha vencidas + liquida prêmios).
	var seasons : Dictionary = _eco.TickSeasonLifecycle()
	if int(seasons.get("settled", 0)) > 0 or int(seasons.get("closed", 0)) > 0:
		Util.PrintLog("Economy", "Season lifecycle: closed %d, settled %d" % [int(seasons.get("closed", 0)), int(seasons.get("settled", 0))])
	# Fase F: copas semanais (liquida vencidas + garante a ativa).
	var tours : Dictionary = TickTournaments()
	if int(tours.get("settled", 0)) > 0 or int(tours.get("created", 0)) > 0:
		Util.PrintLog("Economy", "Tournaments: settled %d, created %d" % [int(tours.get("settled", 0)), int(tours.get("created", 0))])
	# R1: bônus de referral por marco (job diário; idempotente por ledger+flag).
	var ref : int = _eco.GrantReferralBonuses()
	if ref > 0:
		Util.PrintLog("Economy", "Referral bonuses paid: %d" % ref)
	# R3: ativa/desativa eventos temporários por timestamp.
	var events : Dictionary = _eco.TickLiveEvents()
	if int(events.get("activated", 0)) > 0 or int(events.get("closed", 0)) > 0:
		Util.PrintLog("Economy", "Live events: activated %d, closed %d" % [int(events.get("activated", 0)), int(events.get("closed", 0))])
	# R4: refila tickets da arena assíncrona.
	var arena : Dictionary = TickArenaTickets()
	if int(arena.get("refilled", 0)) > 0:
		Util.PrintLog("Economy", "Arena tickets refilled: %d" % int(arena.get("refilled", 0)))
	return divergences
