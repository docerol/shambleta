extends RefCounted
class_name PassService

# SOM-IDLE Fatia 3 (ROADMAP_COMERCIAL S3): domínio Fase C (passe de temporada,
# BATTLE_PASS_S1.md) extraído de EconomyService. Composição com back-reference
# (_eco): o serviço não tem transação nem mutex próprios — usa o MESMO
# settleMutex e os MESMOS helpers raw de EconomyService, então a semântica de
# locking é 100% idêntica à de antes da extração. Os wrappers públicos ficam em
# EconomyService (callers Server.gd/SeasonPass.gd/testes não mudam).
#
# PT (Pontos de Temporada — não confundir com XP do jogo) por conta/temporada:
# diárias 40 + semanais 120 + marcos 50, curva L1–10:100 · L11–20:120 ·
# L21–30/31–40:140 (máx 5000 PT = L40). VIP +10%, 2× nos últimos 3 dias.
# Missões 100% server-side a partir de ledger/telemetry (nada client-side).
# Desvios do design documentados onde ocorrem (3 substituições de missão por
# falta de sistema-fonte, baús sem raridade, 4 bosses em vez de 8 zonas).
# Trilha grátis (BATTLE_PASS_S1 §3). Baús não têm raridade no jogo (pool por
# zona no open): "rara" = 2 baús, "épica" = 3.
# Trilha premium (BATTLE_PASS_S1 §4). Cosméticos viram cosmetic_grant (uso
# pleno na Fase D); trial VIP entra como tier 1.
# Diárias (3/dia, mesmas p/ todos, seed do dia). SUB = substituição por falta
# de sistema-fonte: equip (sem evento server-side) → levelup; 25 mobs (sem
# kill counter) → 2h de settle; reforja (sistema inexistente) → listar no AH;
# rewarded ad (Fase E) → abrir a loja.
# Semanais (3/semana). W3 conta qualquer sink de gems; W5 aceita level-up OU
# 3 depósitos (sem vault de gold no jogo).
#
# OPS-2 (2026-09-27): as TRILHAS do passe passaram a poder ser declaradas pela
# temporada vigente em `data/conf/seasons.json` (`pass_tiers`); desde 2026-09-29
# a S1 — a temporada que está no ar — declara a sua, espelhando o catálogo. Nada
# aqui mudou de REGRA: sem trilha declarada para a temporada da linha vale o
# `EconomyCatalog`, o default que a curva do passe sempre usou. A
# curva de PT, o custo do skip e o valor das missões ficam no catálogo de
# propósito — são uma regra só prometida no beta, e curva por temporada com uma
# coluna `season_account_state.pt` compartilhada criaria duas escalas de nível
# para o mesmo número. O que virou dado de configuração é o que cada nível
# ENTREGA, o teto de nível da temporada, o começo/valor do bônus e a etiqueta de
# origem do cosmético (`pass_s2:premium:12`).

var _eco : EconomyService = null

func _PassStateRaw(accountID : int, seasonID : int) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	sql.ExecuteBindings("INSERT OR IGNORE INTO season_account_state (account_id, season_id) VALUES (?, ?);", [accountID, seasonID])
	var rows : Array[Dictionary] = sql.QueryBindings("SELECT pt, premium, claimed_free, claimed_premium, skips_used FROM season_account_state WHERE account_id = ? AND season_id = ?;", [accountID, seasonID])
	if rows.is_empty():
		return {"pt": 0, "premium": 0, "claimed_free": [], "claimed_premium": [], "skips_used": 0}
	var r : Dictionary = rows[0]
	var cf : Variant = JSON.parse_string(str(r.get("claimed_free", "[]")))
	var cp : Variant = JSON.parse_string(str(r.get("claimed_premium", "[]")))
	# Normaliza p/ int: JSON devolve float e `lvl in lista` não bate int×float.
	var claimedF : Array = []
	for x in (cf if cf is Array else []):
		claimedF.append(int(x))
	var claimedP : Array = []
	for x in (cp if cp is Array else []):
		claimedP.append(int(x))
	return {"pt": int(r.get("pt", 0)), "premium": int(r.get("premium", 0)),
		"claimed_free": claimedF, "claimed_premium": claimedP,
		"skips_used": int(r.get("skips_used", 0))}

# ------------------------------------------------------------------ passe por temporada (OPS-2)

# A entrada do calendário que governa uma linha de temporada. `{}` significa "o
# arquivo não declara nada para esta linha" — que é o estado de toda linha
# anterior ao OPS-2 e de toda `/season create <dias>` (`rules_frozen` = "{}", sem
# `config_id`) — e quer dizer "usa os defaults do catálogo", NUNCA "temporada
# inexistente". Nenhum `season_*` já gravado é reescrito por aqui.
func _SeasonEntry(season : Dictionary) -> Dictionary:
	if season.is_empty():
		return {}
	return SeasonConfig.EntryForSeasonRow(SeasonConfig.Entries(), season)

# Idem a partir do id, para quem só tem a temporada fechada na mão
# (`_AutoClaimPass` liquida uma linha que não está mais `active`).
func _EntryForSeasonID(seasonID : int) -> Dictionary:
	if seasonID <= 0:
		return {}
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT season_id, starts_at, ends_at, rules_frozen, status FROM season WHERE season_id = ?;", [seasonID])
	return _SeasonEntry(rows[0]) if not rows.is_empty() else {}

# Tabela da trilha: a da temporada quando declarada, a do catálogo quando não.
func _PassTrackTable(entry : Dictionary, track : String) -> Dictionary:
	var tiers : Dictionary = SeasonConfig.PassTiers(entry, track)
	if not tiers.is_empty():
		return tiers
	return EconomyCatalog.PASS_FREE if track == "free" else EconomyCatalog.PASS_PREMIUM

# Origem do cosmético ganha pelo passe. Continua `pass_s1:...` para a S1 do beta
# (`SeasonConfig.ConfigID` da entrada é "s1"), então o que já foi concedido não
# muda de etiqueta; a S2 nasce com a sua.
func _PassCosmeticSource(entry : Dictionary, track : String, level : int) -> String:
	var cid : String = SeasonConfig.ConfigID(entry)
	return "pass_%s:%s:%d" % [cid if not cid.is_empty() else "s1", track, level]

func _PassDoubleXP(season : Dictionary, now : int) -> bool:
	var startsAt : int = int(season.get("starts_at", 0))
	var endsAt : int = int(season.get("ends_at", 0))
	if endsAt <= now or endsAt - startsAt < 7 * 86400:
		return false
	return endsAt - now <= EconomyCatalog.PASS_DOUBLEXP_LAST_DAYS * 86400

# PT com multiplicadores (VIP +10%, 2× fim de temporada), teto L40, ledger.
func _AwardPT(accountID : int, seasonID : int, base : int, reason : String) -> int:
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty() or int(season.get("season_id", 0)) != seasonID:
		return 0
	var pts : int = base
	if sql.GetVIPUntil(accountID) > now:
		pts = roundi(float(pts) * 1.1)
	if _PassDoubleXP(season, now):
		pts *= 2
	var st : Dictionary = _PassStateRaw(accountID, seasonID)
	var maxPT : int = int((EconomyCatalog.PassThresholds() as Array).back())
	var newPT : int = mini(int(st.get("pt", 0)) + pts, maxPT)
	sql.ExecuteBindings("UPDATE season_account_state SET pt = ? WHERE account_id = ? AND season_id = ?;", [newPT, accountID, seasonID])
	_eco._LedgerAppendLocked(accountID, 0, "pass_pt", pts, newPT, "pass_pt:" + reason)
	return pts

# Rotação do dia/semana (pura, mesma p/ todos): 3 consecutivas do pool.
func _PassChars(accountID : int) -> Array:
	var ids : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT char_id FROM character WHERE account_id = ? ORDER BY char_id;", [accountID]):
		ids.append(int(row["char_id"]))
	return ids

# Progresso de uma missão a partir de ledger/telemetry (nada client-side).
func _MissionProgress(accountID : int, missionID : String, periodStart : int, seasonID : int) -> int:
	var sql : SQLService = Launcher.SQL
	match missionID:
		"d_settle2":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_chest1":
			# Ledger de open usa reason "chest:<id>|<hash>|<seed>:uid<n>"
			# (o "chest_open" vai p/ o lote, não p/ o ledger).
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND kind = 'item' AND reason LIKE 'chest:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_level1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'levelup' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_farm2h":
			var r : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(CAST(json_extract(meta, '$.hours') AS REAL)), 0) AS h FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])
			return int(floor(float(r[0]["h"])))
		"d_vault1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'vault_deposit:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_trade1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND (reason LIKE 'trade_out:%' OR reason LIKE 'ah_buy:%') AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_ahlist1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'ah_list:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_shop1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'shop_visit' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"w_boss1":
			var chars : Array = _PassChars(accountID)
			if chars.is_empty():
				return 0
			var placeholders : String = ",".join(chars.map(func(_c : int) -> String: return "?"))
			var query : String = "SELECT COUNT(*) AS n FROM chest_instance WHERE origin = 'boss' AND created_at >= ? AND char_id IN (%s);" % placeholders
			var bindings : Array = [periodStart]
			bindings.append_array(chars)
			return int(sql.QueryBindings(query, bindings)[0]["n"])
		"w_eff3":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ? AND CAST(json_extract(meta, '$.eff') AS REAL) >= 0.9;", [accountID, periodStart])[0]["n"])
		"w_spend100":
			var s : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(-amount), 0) AS t FROM ledger_transaction WHERE account_id = ? AND kind = 'gems' AND amount < 0 AND created_at >= ?;", [accountID, periodStart])
			return int(s[0]["t"])
		"w_dailies15":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM season_mission_state WHERE account_id = ? AND season_id = ? AND mission_id LIKE 'd_%' AND claimed = 1 AND claimed_at >= ?;", [accountID, seasonID, periodStart])[0]["n"])
		"w_guild1":
			var lv : int = int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = 'guild_level' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
			if lv > 0:
				return 1
			return 1 if int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'vault_deposit:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"]) >= 3 else 0
		"w_farm8h":
			var h : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(CAST(json_extract(meta, '$.hours') AS REAL)), 0) AS t FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])
			return int(floor(float(h[0]["t"])))
	return 0

func _MissionState(accountID : int, seasonID : int, missionID : String, periodID : String, goal : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT progress, claimed FROM season_mission_state WHERE account_id = ? AND season_id = ? AND mission_id = ? AND period_id = ?;", [accountID, seasonID, missionID, periodID])
	if rows.is_empty():
		return {"progress": 0, "claimed": 0, "goal": goal}
	return {"progress": int(rows[0].get("progress", 0)), "claimed": int(rows[0].get("claimed", 0)), "goal": goal}

func _SeasonMissions(accountID : int, season : Dictionary) -> Dictionary:
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var day : int = EconomyCatalog.ShopDay(now)
	var weekIdx : int = EconomyCatalog.PassWeekIndex(season, now)
	var dayStart : int = EconomyCatalog.PassDayStartTS(day)
	var weekStart : int = EconomyCatalog.PassDayStartTS(EconomyCatalog.ShopDay(int(season.get("starts_at", now))) + weekIdx * 7)
	var dailies : Array = []
	for def in EconomyCatalog.PassDailies(day):
		var mid : String = str(def["id"])
		var mst : Dictionary = _MissionState(accountID, sid, mid, "d%d" % day, int(def["goal"]))
		dailies.append({"id": mid, "label": str(def["label"]), "goal": int(def["goal"]),
			"progress": mini(_MissionProgress(accountID, mid, dayStart, sid), int(def["goal"])),
			"claimed": int(mst["claimed"]), "pt": EconomyCatalog.PASS_DAILY_PT})
	var weeklies : Array = []
	for def in EconomyCatalog.PassWeeklies(weekIdx):
		var mid : String = str(def["id"])
		var mst : Dictionary = _MissionState(accountID, sid, mid, "w%d" % weekIdx, int(def["goal"]))
		weeklies.append({"id": mid, "label": str(def["label"]), "goal": int(def["goal"]),
			"progress": mini(_MissionProgress(accountID, mid, weekStart, sid), int(def["goal"])),
			"claimed": int(mst["claimed"]), "pt": EconomyCatalog.PASS_WEEKLY_PT})
	var beaten : int = 0
	for c in _PassChars(accountID):
		beaten = maxi(beaten, Launcher.SQL.GetCharacterBossesBeaten(c))
	var milestones : Array = []
	for i in BossService.BossNames.size():
		var mid : String = "m_boss%d" % i
		var mst : Dictionary = _MissionState(accountID, sid, mid, "s%d" % sid, 1)
		milestones.append({"id": mid, "label": "Defeat %s (first)" % BossService.BossNames[i],
			"goal": 1, "progress": 1 if (beaten > i or int(mst["claimed"]) == 1) else 0,
			"claimed": int(mst["claimed"]), "pt": EconomyCatalog.PASS_MILESTONE_PT})
	return {"dailies": dailies, "weeklies": weeklies, "milestones": milestones,
		"day": day, "week": weekIdx}

# Estado do passe p/ a janela (substitui o stub da F3/F4).
func GetSeasonPass(accountID : int) -> Dictionary:
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var st : Dictionary = _PassStateRaw(accountID, sid)
	var level : int = EconomyCatalog.PassLevelForPT(int(st.get("pt", 0)))
	# Trilha e teto vêm da entrada da temporada quando ela declara uma (OPS-2);
	# `{}` = defaults do catálogo, que é o que toda linha do beta usa hoje.
	var entry : Dictionary = _SeasonEntry(season)
	var maxLevel : int = SeasonConfig.PassMaxLevel(entry)
	var bonusStart : int = SeasonConfig.PassBonusStart(entry)
	var freeTable : Dictionary = _PassTrackTable(entry, "free")
	var premiumTable : Dictionary = _PassTrackTable(entry, "premium")
	var ms : Dictionary = _SeasonMissions(accountID, season)
	var freeTodo : Array = []
	var premTodo : Array = []
	for lvl in range(1, mini(level, maxLevel) + 1):
		if freeTable.has(lvl) and not (lvl in st["claimed_free"]):
			freeTodo.append(lvl)
		if int(st.get("premium", 0)) == 1 and ((premiumTable.has(lvl)) or lvl >= bonusStart) and not (lvl in st["claimed_premium"]):
			premTodo.append(lvl)
	return {"ok": true, "season_id": sid, "ends_at": int(season.get("ends_at", 0)),
		"season_config": SeasonConfig.ConfigID(entry), "theme": str(entry.get("theme", "")),
		"day_index": EconomyCatalog.ShopDay(now) - EconomyCatalog.ShopDay(int(season.get("starts_at", now))),
		"pt": int(st.get("pt", 0)), "level": level, "max_level": maxLevel, "premium": int(st.get("premium", 0)),
		"skips_used": int(st.get("skips_used", 0)), "skips_max": EconomyCatalog.PASS_SKIP_MAX,
		"double_xp": _PassDoubleXP(season, now),
		"dailies": ms["dailies"], "weeklies": ms["weeklies"], "milestones": ms["milestones"],
		"free_claimable": freeTodo, "premium_claimable": premTodo}

# Reivindica PT de missão do período (diária/semanal/marco). Idempotente.
func ClaimMission(accountID : int, missionID : String) -> Dictionary:
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var day : int = EconomyCatalog.ShopDay(now)
	var periodID : String = ""
	var goal : int = 1
	var award : int = EconomyCatalog.PASS_DAILY_PT
	var progress : int = 0
	if missionID.begins_with("d_"):
		for def in EconomyCatalog.PassDailies(day):
			if str(def["id"]) == missionID:
				goal = int(def["goal"])
				periodID = "d%d" % day
				progress = _MissionProgress(accountID, missionID, EconomyCatalog.PassDayStartTS(day), sid)
				break
		if periodID.is_empty():
			return {"ok": false, "reason": "not_active_today"}
	elif missionID.begins_with("w_"):
		var weekIdx : int = EconomyCatalog.PassWeekIndex(season, now)
		for def in EconomyCatalog.PassWeeklies(weekIdx):
			if str(def["id"]) == missionID:
				goal = int(def["goal"])
				periodID = "w%d" % weekIdx
				award = EconomyCatalog.PASS_WEEKLY_PT
				progress = _MissionProgress(accountID, missionID, EconomyCatalog.PassDayStartTS(EconomyCatalog.ShopDay(int(season.get("starts_at", now))) + weekIdx * 7), sid)
				break
		if periodID.is_empty():
			return {"ok": false, "reason": "not_active_this_week"}
	elif missionID.begins_with("m_boss"):
		var idx : int = int(missionID.get_slice("_", 1).substr(4))
		if idx < 0 or idx >= BossService.BossNames.size():
			return {"ok": false, "reason": "unknown_mission"}
		goal = 1
		periodID = "s%d" % sid
		award = EconomyCatalog.PASS_MILESTONE_PT
		var beaten : int = 0
		for c in _PassChars(accountID):
			beaten = maxi(beaten, Launcher.SQL.GetCharacterBossesBeaten(c))
		progress = 1 if beaten > idx else 0
	else:
		return {"ok": false, "reason": "unknown_mission"}
	if progress < goal:
		return {"ok": false, "reason": "incomplete", "progress": progress, "goal": goal}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var mst : Dictionary = _MissionState(accountID, sid, missionID, periodID, goal)
		if int(mst.get("claimed", 0)) == 1:
			result["reason"] = "already_claimed"
			return false
		Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_mission_state (account_id, season_id, mission_id, period_id, progress, goal, claimed, claimed_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?);", [accountID, sid, missionID, periodID, progress, goal, now])
		var pts : int = _AwardPT(accountID, sid, award, "mission:" + missionID)
		result["ok"] = true
		result["reason"] = "ok"
		result["pt"] = pts
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

func _GrantPassRewardRaw(accountID : int, charID : int, seasonID : int, level : int, track : String, entry : Dictionary = {}) -> bool:
	var sql : SQLService = Launcher.SQL
	var table : Dictionary = _PassTrackTable(entry, track)
	var reward : Dictionary = {}
	if track == "premium" and level >= SeasonConfig.PassBonusStart(entry):
		reward = {"gems": SeasonConfig.PassBonusGems(entry)}
	elif table.has(level):
		reward = table[level]
	else:
		return false
	var gems : int = int(reward.get("gems", 0))
	if gems > 0:
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + gems):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, gems, balance + gems, "pass_reward:%s:%d" % [track, level]):
			return false
	var chests : int = int(reward.get("chests", 0))
	for i in chests:
		if not sql.AddChestInstance(charID, 0, "pass"):
			return false
	var vipDays : int = int(reward.get("vip_days", 0))
	if vipDays > 0:
		var now : int = SQLCommons.Timestamp()
		var cur : int = sql.GetVIPUntil(accountID)
		if not sql.SetVIPUntil(accountID, maxi(now, cur) + vipDays * 86400):
			return false
		var curTier : int = sql.GetVIPTier(accountID)
		if curTier < 1 or cur <= now:
			if not sql.SetVIPTier(accountID, 1):
				return false
	var cosmetics : Array = reward.get("cosmetics", [])
	for cid in cosmetics:
		if track == "premium" and not Storefront.IsRenderedCosmetic(str(cid)):
			# Dupla do `ValidatePassTables` do boot: cosmético invisível não sai
			# para quem pagou. O motivo do refusal morre no log do serviço — o
			# caller só vê `rejected`, porque a resposta honesta aqui é bug de
			# catálogo, não estado do jogador.
			Util.PrintLog("Pass", "premium grant bloqueado: nível %d cosmético '%s' sem renderizador" % [level, str(cid)])
			return false
		if not sql.ExecuteBindings("INSERT INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, str(cid), _PassCosmeticSource(entry, track, level), SQLCommons.Timestamp()]):
			return false
	return true

# Reivindica recompensa de nível (grátis ou premium). Compra tardia libera
# retroativo; bônus 31–40 exigem premium.
func ClaimPassReward(accountID : int, charID : int, level : int, track : String) -> Dictionary:
	if track != "free" and track != "premium":
		return {"ok": false, "reason": "bad_track"}
	if level < 1 or level > EconomyCatalog.PASS_MAX_LEVEL:
		return {"ok": false, "reason": "bad_level"}
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	# A temporada pode ter um teto menor que o catálogo (uma S2 com 25 níveis). O
	# teto do catálogo logo acima continua sendo a régua de input: nível acima dele
	# não é "acima do passe da temporada", é botão inexistente.
	var entry : Dictionary = _SeasonEntry(season)
	var maxLevel : int = SeasonConfig.PassMaxLevel(entry)
	if level > maxLevel:
		return {"ok": false, "reason": "bad_level"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var st : Dictionary = _PassStateRaw(accountID, sid)
		if EconomyCatalog.PassLevelForPT(int(st.get("pt", 0))) < level:
			result["reason"] = "locked"
			return false
		var key : String = "claimed_free" if track == "free" else "claimed_premium"
		if track == "premium" and int(st.get("premium", 0)) == 0:
			result["reason"] = "not_premium"
			return false
		if level in st[key]:
			result["reason"] = "already_claimed"
			return false
		if not _GrantPassRewardRaw(accountID, charID, sid, level, track, entry):
			return false
		var claimed : Array = (st[key] as Array).duplicate()
		claimed.append(level)
		if not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET %s = ? WHERE account_id = ? AND season_id = ?;" % key, [JSON.stringify(claimed), accountID, sid]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	_eco.settleMutex.unlock()
	# K1: resgate do passe, por trilha. "pass_premium processado" diz que o dinheiro
	# entrou; isto diz que alguém abriu e usou — a diferença entre os dois é o churn
	# que o roadmap chama de D30.
	if bool(result.get("ok", false)) and Launcher.Telemetry != null:
		Launcher.Telemetry.RecordFunnel("pass_claim", accountID, charID, JSON.stringify({"season" = sid, "level" = level, "track" = track}))
	return result

# Skip de nível (catch-up justo): compra o PT faltante p/ o próximo nível,
# 50 gems, máx 10/temporada. Sem multiplicadores (atalho, não prêmio).
func SkipPassLevel(accountID : int) -> Dictionary:
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var st : Dictionary = _PassStateRaw(accountID, sid)
		if int(st.get("skips_used", 0)) >= EconomyCatalog.PASS_SKIP_MAX:
			result["reason"] = "skip_cap"
			return false
		var level : int = EconomyCatalog.PassLevelForPT(int(st.get("pt", 0)))
		# Catch-up para até o teto do PASSE DA TEMPORADA: numa S2 mais curta,
		# comprar PT além do último nível seria gastar gem em nada.
		if level >= SeasonConfig.PassMaxLevel(_SeasonEntry(season)):
			result["reason"] = "max_level"
			return false
		var missing : int = int((EconomyCatalog.PassThresholds() as Array)[level]) - int(st.get("pt", 0))
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < EconomyCatalog.PASS_SKIP_COST:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, balance - EconomyCatalog.PASS_SKIP_COST):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -EconomyCatalog.PASS_SKIP_COST, balance - EconomyCatalog.PASS_SKIP_COST, "pass_skip"):
			return false
		var maxPT : int = int((EconomyCatalog.PassThresholds() as Array).back())
		var newPT : int = mini(int(st.get("pt", 0)) + missing, maxPT)
		sql.ExecuteBindings("UPDATE season_account_state SET pt = ?, skips_used = skips_used + 1 WHERE account_id = ? AND season_id = ?;", [newPT, accountID, sid])
		_eco._LedgerAppendLocked(accountID, 0, "pass_pt", missing, newPT, "pass_pt:skip")
		result["ok"] = true
		result["reason"] = "ok"
		result["pt"] = missing
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# Crédito automático do marco na vitória (só com temporada ativa).
func _PassMilestoneCredit(accountID : int, bossIndex : int) -> void:
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return
	var sid : int = int(season.get("season_id", 0))
	var mid : String = "m_boss%d" % bossIndex
	var mst : Dictionary = _MissionState(accountID, sid, mid, "s%d" % sid, 1)
	if int(mst.get("claimed", 0)) == 1:
		return
	Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_mission_state (account_id, season_id, mission_id, period_id, progress, goal, claimed, claimed_at) VALUES (?, ?, ?, ?, 1, 1, 1, ?);", [accountID, sid, mid, "s%d" % sid, SQLCommons.Timestamp()])
	_AwardPT(accountID, sid, EconomyCatalog.PASS_MILESTONE_PT, "mission:" + mid)

# Auto-claim no encerramento (recompensas não-claimadas nunca expiram
# silenciosamente): tudo que o nível alcançou, nas duas trilhas (premium só
# p/ quem comprou). Chamado no settle da temporada fechada.
func _AutoClaimPass(seasonID : int) -> Dictionary:
	var done : Dictionary = {"claimed": 0}
	# A temporada liquidada já saiu do ar, mas a entrada dela continua no arquivo
	# (janela vencida é histórico, não erro) — é por ela que o auto-claim paga a
	# trilha que o jogador viu na tela, não a tabela hardcodeada.
	var entry : Dictionary = _EntryForSeasonID(seasonID)
	var maxLevel : int = SeasonConfig.PassMaxLevel(entry)
	var bonusStart : int = SeasonConfig.PassBonusStart(entry)
	var freeTable : Dictionary = _PassTrackTable(entry, "free")
	var premiumTable : Dictionary = _PassTrackTable(entry, "premium")
	var eligible : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT account_id, pt, premium, claimed_free, claimed_premium FROM season_account_state WHERE season_id = ?;", [seasonID]):
		var accountID : int = int(row["account_id"])
		var level : int = EconomyCatalog.PassLevelForPT(int(row.get("pt", 0)))
		if level < 1:
			continue
		var chars : Array = _PassChars(accountID)
		if chars.is_empty():
			continue
		eligible.append(row)
	for row in eligible:
		var accountID : int = int(row["account_id"])
		var level : int = EconomyCatalog.PassLevelForPT(int(row.get("pt", 0)))
		var charID : int = int(_PassChars(accountID)[0])
		var cf : Variant = JSON.parse_string(str(row.get("claimed_free", "[]")))
		var cp : Variant = JSON.parse_string(str(row.get("claimed_premium", "[]")))
		var claimedF : Array = []
		for x in (cf if cf is Array else []):
			claimedF.append(int(x))
		var claimedP : Array = []
		for x in (cp if cp is Array else []):
			claimedP.append(int(x))
		# O que autoriza o UPDATE é o crescimento do array, não uma flag: lambda GDScript
		# captura LOCAL por valor, então `changedF = true` escrito dentro do corpo nunca
		# chegava ao escopo de fora e os dois UPDATE de `claimed_*` eram sempre pulados — o
		# reward saía pelo `_GrantPassRewardRaw`, o state da temporada ficava virgem e a
		# passada seguinte revendia a trilha inteira (dupe de season pass no auto-claim de
		# encerramento). O CONTEÚDO do array é compartilhado com o lambda, então tamanho
		# maior que o snapshot é prova direta de que ESTA transação claimou algo.
		var hadFree : int = claimedF.size()
		var hadPremium : int = claimedP.size()
		_eco.settleMutex.lock()
		if Launcher.SQL.Transaction(func() -> bool:
			for lvl in range(1, mini(level, maxLevel) + 1):
				if freeTable.has(lvl) and not (lvl in claimedF):
					if not _GrantPassRewardRaw(accountID, charID, seasonID, lvl, "free", entry):
						return false
					claimedF.append(lvl)
				if int(row.get("premium", 0)) == 1 and ((premiumTable.has(lvl)) or lvl >= bonusStart) and not (lvl in claimedP):
					if not _GrantPassRewardRaw(accountID, charID, seasonID, lvl, "premium", entry):
						return false
					claimedP.append(lvl)
			if claimedF.size() > hadFree and not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET claimed_free = ? WHERE account_id = ? AND season_id = ?;", [JSON.stringify(claimedF), accountID, seasonID]):
				return false
			if claimedP.size() > hadPremium and not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET claimed_premium = ? WHERE account_id = ? AND season_id = ?;", [JSON.stringify(claimedP), accountID, seasonID]):
				return false
			return true):
				# `claimed` é o número que o settle imprime como "rewards", então conta
				# recompensa paga, não conta processada: passada sobre conta já liquidada
				# volta true sem pagar nada. A prova é o MESMO array compartilhado com o
				# lambda (cresceu de tamanho), não uma flag local — ver acima.
				if claimedF.size() > hadFree or claimedP.size() > hadPremium:
					done["claimed"] = int(done.get("claimed", 0)) + 1
		_eco.settleMutex.unlock()
	return done
