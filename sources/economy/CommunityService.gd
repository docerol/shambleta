extends RefCounted
class_name CommunityService

# SOM-IDLE Fatia 10: dominio de comunidade extraido do EconomyService
# (ROADMAP_COMERCIAL S3). R3 - live events rotativos (modificadores somados no
# mesmo eixo dos bonus VIP/ads) + boards nomeados; conquistas one-time sem wipe
# (resgate idempotente por PK); R1 - referral por conta com marcos e scan
# anti-fraude (multi-account, rajada de troca, velocidade de level, flip). Usa o
# MESMO settleMutex do EconomyService via _eco - nenhuma mudanca de locking.
# Live Ops antifraude: o detector com severidade composta e fila de revisão
# acionável vive em FraudeReview.gd (gate anti-god-node); esta classe é a FACHADA
# que a EconomyService/WorldCommands já conhecem — RunFraudScan, FlagMultiAccount,
# a fila (ListFlagsPaged/ReviewFlag/FlagContext/FraudMetrics) e as portas de
# referral (SetReferralCode/GrantReferralBonuses) consultam o módulo via _fraud().

var _eco : EconomyService = null

# Detector/fila de fraude (FraudeReview.gd). Lazy: o job diário e os comandos
# /cs_* criam via este getter — nada de estado novo de processo.
var fraud : FraudeReview = null

func _fraud() -> FraudeReview:
	if fraud == null:
		fraud = FraudeReview.new()
		fraud._eco = _eco
	return fraud

# ------------------------------------------------------------------ R3: live events (COMMUNITY_ROADMAP)
# Eventos temporários rotativos: framework ativado por timestamp no job diário.
# 2 kinds iniciais: "weekend_drops" (multiplicador no settle/sim) e "smith_week"
# (taxa de crafting -50%). O modificador soma no mesmo eixo dos bônus VIP/ads.
#
# #27: `live_event_tick` é o diário de ativação — uma linha por janela ativada
# (o `NOT IN` abaixo é por evento, sem predicado de tempo: re-tickar a mesma
# janela todo dia só inchava a tabela e fazia o log do job reportar "activated"
# para um evento que já estava ativo). As três leituras perguntam "esta janela já
# foi ativada?", e por isso o predicado é `ticked_at <= now`. Estava `>= now`, que
# só é verdadeiro DENTRO do mesmo segundo do tick: em produção o modificador nunca
# chegava ao settle (OfflineSettle.gd:188) e o SuiteLiveEvents só passava porque
# tick e leitura caíam no mesmo segundo do relógio.
#
# As leituras de modificador usam EXISTS, não JOIN com a tabela de tick: JOIN
# emitiria uma linha por tick e `GetLiveEventMods` multiplicaria `drops_mod` por
# ela (2x → 4x → 8x). Uma janela vale um modificador, quantos ticks ela tiver.

# Calendário derivado do relógio UTC (#27): semear a janela desta semana e as
# LIVE_EVENT_SEED_WEEKS - 1 seguintes, idempotente por (kind, starts_at). Sem
# isto o mecanismo roda sobre tabela vazia e nenhum jogador vê evento nenhum.
func EnsureCalendarLiveEvents() -> int:
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	var dayStart : int = now - (now % 86400)
	var weekday : int = (dayStart / 86400 + 4) % 7		# 0 = domingo (1970-01-01 foi quinta)
	var seeded : int = 0
	for week : int in EconomyCatalog.LIVE_EVENT_SEED_WEEKS:
		var sat : int = dayStart + ((6 - weekday + 7) % 7) * 86400 + week * 7 * 86400
		if _SeedLiveEvent(sql, "weekend_drops", sat, sat + 2 * 86400, '{"drops_mod": %s}' % str(EconomyCatalog.LIVE_EVENT_WEEKEND_MOD)):
			seeded += 1
		var mon : int = dayStart + ((1 - weekday + 7) % 7) * 86400 + week * 7 * 86400
		if int(mon / 86400 / 7) % 2 == 0:
			if _SeedLiveEvent(sql, "smith_week", mon, mon + 5 * 86400, '{"fee_mod": %s}' % str(EconomyCatalog.LIVE_EVENT_SMITH_FEE_MOD)):
				seeded += 1
	return seeded

func _SeedLiveEvent(sql : SQLService, kind : String, startsAt : int, endsAt : int, params : String) -> bool:
	if not sql.QueryBindings("SELECT id FROM live_event WHERE kind = ? AND starts_at = ?;", [kind, startsAt]).is_empty():
		return false
	return sql.ExecuteBindings("INSERT INTO live_event (kind, starts_at, ends_at, params_json, created_at) VALUES (?, ?, ?, ?, ?);", [kind, startsAt, endsAt, params, SQLCommons.Timestamp()])

func TickLiveEvents() -> Dictionary:
	var now : int = SQLCommons.Timestamp()
	var activated : int = 0
	var closed : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT id, kind, starts_at, ends_at, params_json FROM live_event WHERE starts_at <= ? AND ends_at > ? AND id NOT IN (SELECT event_id FROM live_event_tick);", [now, now]):
		var eventID : int = int(row["id"])
		var kind : String = str(row["kind"])
		var raw : String = str(row["params_json"])
		var params : Dictionary = JSON.parse_string(raw) if raw.length() > 0 else {}
		if not (params is Dictionary):
			params = {}
		var startsAt : int = int(row["starts_at"])
		var endsAt : int = int(row["ends_at"])
		if now >= startsAt and now < endsAt:
			Launcher.SQL.ExecuteBindings("INSERT OR IGNORE INTO live_event_tick (event_id, ticked_at) VALUES (?, ?);", [eventID, now])
			activated += 1
			_ApplyLiveEventActivation(kind, params, true)
		else:
			closed += 1
			_ApplyLiveEventActivation(kind, params, false)
	return {"activated": activated, "closed": closed}

func _ApplyLiveEventActivation(kind : String, params : Dictionary, active : bool) -> void:
	match kind:
		"weekend_drops", "smith_week":
			_ApplyLiveEventMods(kind, params, active)
		_:
			pass

func _ApplyLiveEventMods(kind : String, params : Dictionary, active : bool) -> void:
	pass

func GetActiveEventsState(accountID : int) -> Dictionary:
	var now : int = SQLCommons.Timestamp()
	var active : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT id, kind, starts_at, ends_at, params_json FROM live_event WHERE starts_at <= ? AND ends_at > ? AND id IN (SELECT event_id FROM live_event_tick WHERE ticked_at <= ?);", [now, now, now]):
		var raw : String = str(row["params_json"])
		var params : Dictionary = JSON.parse_string(raw) if raw.length() > 0 else {}
		if not (params is Dictionary):
			params = {}
		active.append({
			"id": int(row["id"]),
			"kind": str(row["kind"]),
			"ends_at": int(row["ends_at"]),
			"params": params,
		})
	return {"ok": true, "now": now, "events": active}

func GetLiveEventMods(accountID : int) -> float:
	var now : int = SQLCommons.Timestamp()
	var mods : float = EconomyCatalog.LIVE_EVENT_DEFAULT_MOD
	for row in Launcher.SQL.QueryBindings("SELECT l.params_json FROM live_event l WHERE l.starts_at <= ? AND l.ends_at > ? AND EXISTS (SELECT 1 FROM live_event_tick t WHERE t.event_id = l.id AND t.ticked_at <= ?);", [now, now, now]):
		var raw : String = str(row["params_json"])
		var params : Dictionary = JSON.parse_string(raw) if raw.length() > 0 else {}
		if not (params is Dictionary):
			continue
		var dropsMod : float = float(params.get("drops_mod", 1.0))
		if dropsMod > 1.0:
			mods *= dropsMod
	return mods

func GetLiveEventCraftingFeeMod() -> float:
	var now : int = SQLCommons.Timestamp()
	for row in Launcher.SQL.QueryBindings("SELECT l.params_json FROM live_event l WHERE l.kind = 'smith_week' AND l.starts_at <= ? AND l.ends_at > ? AND EXISTS (SELECT 1 FROM live_event_tick t WHERE t.event_id = l.id AND t.ticked_at <= ?);", [now, now, now]):
		var raw : String = str(row["params_json"])
		var params : Dictionary = JSON.parse_string(raw) if raw.length() > 0 else {}
		if not (params is Dictionary):
			continue
		var feeMod : float = float(params.get("fee_mod", 1.0))
		return feeMod
	return 1.0

# Boards da temporada ativa em um shot, já com nomes resolvidos (GUI de
# leaderboard). {} quando não há temporada ativa.
func GetSeasonBoardsState(limit : int = 10) -> Dictionary:
	var season : Dictionary = _eco.ActiveSeason()
	if season.is_empty():
		return {}
	var seasonID : int = int(season["season_id"])
	return {
		"season_id" = seasonID,
		"ends_at" = int(season["ends_at"]),
		# O regime do número, lido da coluna que a 064 grava na abertura. "delta"
		# é o que vale para toda temporada aberta depois daqui; "current" existe
		# para a vitrine não chamar de "o que você fez nesta temporada" um número
		# que é tudo o que o personagem já fez.
		"scoring" = "delta" if int(season.get("baselines_at", 0)) > 0 else "current",
		"power" = _NamedSeasonBoard(seasonID, "power", limit),
		"spend" = _NamedSeasonBoard(seasonID, "spend", limit),
		"boss_kills" = _NamedSeasonBoard(seasonID, "boss_kills", limit),
		"guild_points" = _NamedSeasonBoard(seasonID, "guild_points", limit),
	}

# subject_id → nome legível: power é por char (nickname), spend por conta
# (username). ≤ limit rows por board, chamada rate-limited — queries por linha OK.
# Fase D: inclui o título equipado (vitrine social do passe/renascimento).
func _NamedSeasonBoard(seasonID : int, kind : String, limit : int) -> Array:
	var named : Array = []
	for row in _eco.GetSeasonBoard(seasonID, kind, limit):
		var name : String = "?"
		var title : String = ""
		if kind == "power":
			var chars : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT nickname, account_id FROM character WHERE char_id = ?;", [int(row["subject_id"])])
			if not chars.is_empty():
				name = str(chars[0].get("nickname", "?"))
				title = _eco.EquippedTitleLabel(int(chars[0].get("account_id", 0)))
		else:
			var accounts : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username FROM account WHERE account_id = ?;", [int(row["subject_id"])])
			name = str(accounts[0]["username"]) if not accounts.is_empty() else "?"
			title = _eco.EquippedTitleLabel(int(row["subject_id"]))
		if kind == "boss_kills":
			var bchars : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT nickname, account_id FROM character WHERE char_id = ?;", [int(row["subject_id"])])
			if not bchars.is_empty():
				name = str(bchars[0].get("nickname", "?"))
				title = _eco.EquippedTitleLabel(int(bchars[0].get("account_id", 0)))
		if kind == "guild_points":
			var guilds : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT name, tag, leader_account FROM guild WHERE guild_id = ?;", [int(row["subject_id"])])
			if not guilds.is_empty():
				name = str(guilds[0].get("name", "?"))
				var gtag : String = str(guilds[0].get("tag", ""))
				if not gtag.is_empty():
					name = "[%s] %s" % [gtag, name]
				title = _eco.EquippedTitleLabel(int(guilds[0].get("leader_account", 0)))
		named.append({"name" = name, "value" = int(row["value"]), "title" = title})
	return named

# ------------------------------------------------------------------ conquistas (sem wipe)
# Metas one-time sobre contadores existentes (bestiary, chest_instance,
# bosses_beaten, level, rebirths). Progresso é derivado (sem sync); aqui só
# vive o resgate, idempotente por PK em achievement_state (migration 036).
# Recompensas: gems + (no topo) cosméticos existentes, nunca poder direto.

func AchievementProgress(accountID : int, entry : Dictionary) -> int:
	var sql : SQLService = Launcher.SQL
	match str(entry.get("counter", "")):
		"kills_total":
			var rows : Array = sql.db.select_rows("bestiary", "char_id IN (SELECT char_id FROM character WHERE account_id = %d)" % accountID, ["killed_count"])
			var total : int = 0
			for row in rows:
				total += int(row.get("killed_count", 0))
			return total
		"kills_mob":
			var mobID : int = str(entry.get("mob", "")).hash()
			var rows : Array = sql.db.select_rows("bestiary", "mob_id = %d AND char_id IN (SELECT char_id FROM character WHERE account_id = %d)" % [mobID, accountID], ["killed_count"])
			var total : int = 0
			for row in rows:
				total += int(row.get("killed_count", 0))
			return total
		"chests":
			var rows : Array = sql.db.select_rows("chest_instance", "item_state = 'opened' AND char_id IN (SELECT char_id FROM character WHERE account_id = %d)" % accountID, ["id"])
			return rows.size()
		"bosses":
			var rows : Array = sql.QueryBindings("SELECT COALESCE(SUM(bosses_beaten), 0) AS n FROM character WHERE account_id = ?;", [accountID])
			return int(rows[0].get("n", 0)) if not rows.is_empty() else 0
		"level":
			var rows : Array = sql.QueryBindings("SELECT MAX(s.level) AS m FROM stat s INNER JOIN character c ON c.char_id = s.char_id WHERE c.account_id = ?;", [accountID])
			if rows.is_empty() or rows[0].get("m", null) == null:
				return 0
			return int(rows[0]["m"])
		"rebirths":
			var rows : Array = sql.QueryBindings("SELECT MAX(rebirths) AS m FROM character WHERE account_id = ?;", [accountID])
			if rows.is_empty() or rows[0].get("m", null) == null:
				return 0
			return int(rows[0]["m"])
	return 0

func GetAchievements(accountID : int) -> Array:
	var out : Array = []
	var claimed : Dictionary = {}
	for row in Launcher.SQL.QueryBindings("SELECT achievement_id FROM achievement_state WHERE account_id = ? AND claimed = 1;", [accountID]):
		claimed[str(row.get("achievement_id", ""))] = true
	for entry in EconomyCatalog.ACHIEVEMENTS:
		var aid : String = str(entry.get("id", ""))
		out.append({
			"id": aid, "label": str(entry.get("label", aid)), "desc": str(entry.get("desc", "")),
			"goal": int(entry.get("goal", 0)), "progress": AchievementProgress(accountID, entry),
			"claimed": claimed.has(aid), "gems": int(entry.get("gems", 0)),
			"cosmetic": str(entry.get("cosmetic", "")),
		})
	return out

func ClaimAchievement(accountID : int, achievementID : String) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var entry : Dictionary = EconomyCatalog.AchievementByID(achievementID)
	if entry.is_empty():
		result["reason"] = "unknown_achievement"
		return result
	if AchievementProgress(accountID, entry) < int(entry.get("goal", 0)):
		result["reason"] = "not_completed"
		return result
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var done : Array = sql.db.select_rows("achievement_state", "account_id = %d AND achievement_id = '%s' AND claimed = 1" % [accountID, achievementID], ["account_id"])
		if not done.is_empty():
			result["reason"] = "already_claimed"
			return false
		var gems : int = int(entry.get("gems", 0))
		if gems > 0:
			var balance : int = sql.GetGemsRaw(accountID)
			if not sql.SetGemsRaw(accountID, balance + gems):
				return false
			if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, gems, balance + gems, "achievement:%s" % achievementID):
				return false
		var cid : String = str(entry.get("cosmetic", ""))
		if not cid.is_empty():
			if not EconomyCatalog.COSMETIC_CATALOG.has(cid):
				return false
			if not sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, cid, "achievement:%s" % achievementID, SQLCommons.Timestamp()]):
				return false
			if not _eco._LedgerAppendLocked(accountID, 0, "cosmetic", 1, 1, "achievement:%s" % achievementID):
				return false
		if not sql.ExecuteBindings("INSERT OR REPLACE INTO achievement_state (account_id, achievement_id, claimed, claimed_at) VALUES (?, ?, 1, ?);", [accountID, achievementID, SQLCommons.Timestamp()]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["gems"] = gems
		result["cosmetic"] = cid
		return true):
		pass
	mutex.unlock()
	return result

# ------------------------------------------------------------------ R1: referral (COMMUNITY_ROADMAP)
# Código por conta, recompensa por marco (L10 + e-mail verificado). Anti-farma
# (Live Ops): marco + teto semanal + auto-referral/ciclo recusados em
# SetReferralCode + porta ReferralGuard no payout (maturidade de 5d, hold
# protetor, teto vitalício e ring de fingerprint no resgate) — ver FraudeReview.
# Valores são proposta (dono confirma).

func GetReferralState(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username, referral_code, referred_by FROM account WHERE account_id = ?;", [accountID])
	if rows.is_empty():
		return {"ok" = false, "reason" = "unknown_account"}
	var code : String = str(rows[0].get("referral_code", ""))
	if code.is_empty():
		code = EconomyCatalog.ReferralCodeFor(accountID, str(rows[0].get("username", "?")))
		Launcher.SQL.ExecuteBindings("UPDATE account SET referral_code = ? WHERE account_id = ?;", [code, accountID])
	var invited : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM account WHERE referred_by = ?;", [accountID])
	var paid : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE ?;", [accountID, "referral_bonus:%"])
	return {"ok" = true, "code" = code,
		"referred_by" = int(rows[0].get("referred_by", 0)),
		"invited" = int(invited[0].get("n", 0)) if not invited.is_empty() else 0,
		"bonuses" = int(paid[0].get("n", 0)) if not paid.is_empty() else 0,
		"bonus_gems" = EconomyCatalog.REFERRAL_BONUS_GEMS, "min_level" = EconomyCatalog.REFERRAL_MIN_LEVEL}

func SetReferralCode(accountID : int, code : String) -> Dictionary:
	var clean : String = code.strip_edges()
	if clean.is_empty():
		return {"ok" = false, "reason" = "bad_code"}
	var me : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username, created_timestamp, referred_by, referral_code FROM account WHERE account_id = ?;", [accountID])
	if me.is_empty():
		return {"ok" = false, "reason" = "unknown_account"}
	if int(me[0].get("referred_by", 0)) != 0:
		return {"ok" = false, "reason" = "already_referred"}
	if SQLCommons.Timestamp() - int(me[0].get("created_timestamp", 0)) > EconomyCatalog.REFERRAL_WINDOW_SEC:
		return {"ok" = false, "reason" = "window_expired"}
	if clean == str(me[0].get("referral_code", "")) and not clean.is_empty():
		return {"ok" = false, "reason" = "self_referral"}
	# Ghost anonimizado (LGPD) não pode receber indicação: 'deleted_%' sai da
	# busca; sem isto o código órfão de uma conta apagada rouba o referred_by.
	var inv : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, username FROM account WHERE referral_code = ? AND username NOT LIKE 'deleted%' ORDER BY account_id LIMIT 1;", [clean])
	if inv.is_empty():
		return {"ok" = false, "reason" = "unknown_code"}
	var inviter : int = int(inv[0]["account_id"])
	if inviter == accountID:
		return {"ok" = false, "reason" = "self_referral"}
	# R1-hardening (Live Ops): a escada A→B→A pagava os dois degraus. O ciclo é
	# auto-indicação com um passo de intermediário — recusar antes do UPDATE.
	if _fraud().IsSelfLadder(accountID, inviter):
		return {"ok" = false, "reason" = "referral_cycle"}
	if not Launcher.SQL.ExecuteBindings("UPDATE account SET referred_by = ? WHERE account_id = ? AND referred_by = 0;", [inviter, accountID]):
		return {"ok" = false, "reason" = "db_error"}
	return {"ok" = true, "reason" = "ok", "inviter" = str(inv[0].get("username", "?"))}

func _ReferralMaxLevel(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(s.level) AS m FROM stat s INNER JOIN character c ON c.char_id = s.char_id WHERE c.account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

# Job diário: paga bônus de marco (inviter + invitee). Idempotente por flag +
# reason do ledger; teto semanal por inviter. Retorna pares pagos.
# R1-hardening: antes do dinheiro, a porta ReferralGuard (FraudeReview) exige
# qualificação de 5 dias da indicada, recusa hold protetor em qualquer ponta,
# teto vitalício por inviter e o ring "mesma instalação resgatando o próprio
# bônus". Tudo que bloqueia é PROTETIVO e temporário: nada marca
# referral_bonus_claimed, então a passada seguinte paga o bônus legítimo quando
# a janela passar / o operador descartar a flag.
func GrantReferralBonuses() -> int:
	var paid : int = 0
	var now : int = SQLCommons.Timestamp()
	var weekAgo : int = now - 7 * 86400
	for row in Launcher.SQL.QueryBindings("SELECT account_id, referred_by FROM account WHERE referred_by > 0 AND referral_bonus_claimed == 0;", []):
		var invitee : int = int(row["account_id"])
		var inviter : int = int(row["referred_by"])
		if not Launcher.SQL.IsEmailVerifiedRaw(invitee):
			continue
		if _ReferralMaxLevel(invitee) < EconomyCatalog.REFERRAL_MIN_LEVEL:
			continue
		var guard : Dictionary = _fraud().ReferralGuard(inviter, invitee, now)
		if not bool(guard.get("allow", false)):
			continue
		var week : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'referral_bonus:%' AND created_at >= ?;", [inviter, weekAgo])
		if not week.is_empty() and int(week[0].get("n", 0)) >= EconomyCatalog.REFERRAL_WEEKLY_CAP:
			continue
		if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE reason = ? LIMIT 1;", ["referral_bonus:%d:%d" % [inviter, invitee]]).is_empty():
			Launcher.SQL.ExecuteBindings("UPDATE account SET referral_bonus_claimed = 1 WHERE account_id = ?;", [invitee])
			continue
		if not _eco.AddGems(inviter, EconomyCatalog.REFERRAL_BONUS_GEMS, "referral_bonus:%d:%d" % [inviter, invitee]):
			continue
		if not _eco.AddGems(invitee, EconomyCatalog.REFERRAL_BONUS_GEMS, "referral_welcome:%d" % inviter):
			continue
		Launcher.SQL.ExecuteBindings("UPDATE account SET referral_bonus_claimed = 1 WHERE account_id = ?;", [invitee])
		paid += 1
	return paid

# ------------------------------------------------------------------ D3/S5: antifraude (FraudeReview.gd)
# As heurísticas v1 (rajada de troca, velocidade de level, flip) continuam
# rodando, agora como SINAIS COM PESO dentro do score composto de
# FraudeReview.Scan — IP/dispositivo sem sobreposição nunca abre flag sozinho
# (LAN house/NGM é uso normal). A revisão é sempre humana (/cs_flags, /cs_flag);
# a única ação automática é o hold protetor de referral em violação
# determinística de ledger. Ver a matriz no cabeçalho de FraudeReview.gd.

func RunFraudScan() -> int:
	var fr : FraudeReview = _fraud()
	var result : Dictionary = fr.Scan()
	# Métrica de revisão no caminho que o /metrics do companion já lê: sem
	# contadores fixos ninguém sabe se o detector está calibrado no beta.
	fr.RecordMetricsTelemetry()
	return int(result.get("flags_opened", 0))

# SOM-IDLE S5: mantém a assinatura pública (EconomyService.FlagMultiAccount) e a
# fila manual, agora com severidade forte por premissa de sobreposição. Nunca
# ban: punição é decisão humana na fila. O produtor automático continua não
# existindo por design (a heurística de login coletava o hash do HARDWARE DO
# SERVIDOR e sinalizava todas as contas — removida em 2026-09-24, ver
# AUDITORIA_INDEPENDENTE item (s) e o comentário em Peers.FinalizeLogin).
func FlagMultiAccount(accountID : int, detail : String) -> bool:
	return _fraud().FlagMultiAccount(accountID, detail)

# P1-6b: porta da fachada para o rombo de clawback (chargeback sem gem paga
# suficiente). O chamador é CheckoutService, que sabe o pedido e o tomado; quem
# decide kind/severidade/score é o detector, no mesmo mapa de todo sinal — ver
# FraudeReview.ChargebackShortfall. Continua sendo fila de REVISÃO: nenhuma linha
# daqui bane, silencia ou tira saldo.
func ChargebackShortfall(accountID : int, paymentID : String, requested : int, debited : int, sku : String, grantID : int = 0) -> bool:
	return _fraud().ChargebackShortfall(accountID, paymentID, requested, debited, sku, grantID)

# ------------------------------------------------------------------ fila de revisão (Live Ops)
# Fachada dos comandos /cs_flags /cs_flag /cs_flag_info /cs_fraud_stats
# (WorldCommands) — o operador não toca SQL.

func ListFlagsPaged(status : String, page : int = 1, perPage : int = 10) -> Dictionary:
	return _fraud().ListFlagsPaged(status, page, perPage)

func ReviewFlag(flagID : int, status : String, reviewerAccountID : int, note : String = "") -> Dictionary:
	return _fraud().ReviewFlag(flagID, status, reviewerAccountID, note)

func FlagContext(flagID : int) -> Dictionary:
	return _fraud().FlagContext(flagID)

func FraudMetrics(now : int = 0) -> Dictionary:
	return _fraud().Metrics(now)
