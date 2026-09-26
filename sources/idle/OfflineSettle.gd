extends RefCounted
class_name OfflineSettle

# SOM-IDLE: F2 idle-spike settle (TECH_SPEC_CORE.md §3)
# OfflineFactor = 0.6, death tax 5%, chests floor(h/4) cap 3.
# O cap de horas não é mais um número fixo da conta: F2P liquida 1h, cada
# anúncio assistido desde a última coleta soma +1h, e VIP dá as 24h sem
# assistir nada (regra do dono, 2026-09-25). Ver CapHoursForCharacter.
# The whole settle runs in ONE SQLite transaction; idempotency is enforced by
# re-reading last_settled_at INSIDE the transaction before any write.

const OfflineFactor : float = 0.6
# Baseline de quem não assistiu anúncio nem tem VIP.
const BaseCapHours : float = 1.0
# SOM-IDLE Fase B: cap diferenciado por tier (MONETIZATION §2.2). Desde a regra
# de 2026-09-25 os dois tiers dão as mesmas 24h sem anúncio nenhum; o que
# separa o tier 2 é o ×2 permanente no loot da liquidação (_LootMult).
const CapHoursVIP1 : float = 24.0
const CapHoursVIP2 : float = 24.0
const DeathTaxPct : int = 5
const MaxChests : int = 3
const ChestHoursPerChest : int = 4
const EfficiencyDecayPerDeath : float = 0.05
const MinEfficiency : float = 0.5

# SOM-IDLE: F3 — settle mods (TECH_SPEC_CORE §3; MONETIZATION §2.2). VIP active
# window multiplies the offline faucet by +20%; guild hook stays at 1.0 (F4).
const VIPModFactor : float = 1.2
const GuildHookFactor : float = 1.0

#
class SettleReport:
	var charID : int = 0
	var accountID : int = 0
	var zoneID : int = 0
	var hours : float = 0.0
	var efficiency : float = 1.0
	var deaths : int = 0
	var levelsGained : int = 0
	var newLevel : int = 0
	var xpEarned : int = 0
	var goldEarned : int = 0
	var goldTaxed : int = 0
	var drops : Dictionary[int, int] = {}
	var chests : int = 0
	var bossKeysEarned : int = 0
	var essenceEarned : int = 0
	var lastSettledAt : int = 0
	var mods : float = 1.0
	# `doubled` = o ×2 do tier 2 foi aplicado a esta liquidação. Só XP/ouro/drops
	# dobram — baús, chaves e favores nunca (MONETIZATION §2.5/§0.1).
	var doubled : bool = false
	# Teto que limitou `hours` (base F2P + horas compradas em anúncio + perk de
	# VIP) — a janela mostra "Away: 3.0h (cap 6h)". 0 = relatório vazio.
	var capHours : float = 0.0

	func to_dictionary() -> Dictionary:
		return {
			"char_id": charID,
			"account_id": accountID,
			"zone_id": zoneID,
			"hours": hours,
			"efficiency": efficiency,
			"deaths": deaths,
			"levels_gained": levelsGained,
			"new_level": newLevel,
			"xp_earned": xpEarned,
			"gold_earned": goldEarned,
			"gold_taxed": goldTaxed,
			"drops": drops,
			"chests": chests,
			"boss_keys": bossKeysEarned,
			"essence_earned": essenceEarned,
			"last_settled_at": lastSettledAt,
			"mods": mods,
			"doubled": doubled,
			"cap_hours": capHours,
		}

# Test seams (headless `-s` runs have no Launcher/SQL autoload context)
static var sqlOverride : SQLService		= null
static var economyOverride : EconomyService	= null
static var nowOverride : int				= 0

#
static func _sql() -> SQLService:
	return sqlOverride if sqlOverride else Launcher.SQL

static func _economy() -> EconomyService:
	return economyOverride if economyOverride else Launcher.Economy

static func _telemetry() -> TelemetryService:
	return Launcher.Telemetry

static func _now() -> int:
	return nowOverride if nowOverride > 0 else SQLCommons.Timestamp()

# ------------------------------------------------------------------ public API

# Builds the AFK report preview WITHOUT applying anything.
static func BuildReport(charID : int, now : int = 0) -> SettleReport:
	var sql : SQLService = _sql()
	var report : SettleReport = SettleReport.new()
	var char : Dictionary = sql.GetCharacter(charID)
	if char.is_empty():
		return report

	var clock : int = now if now > 0 else _now()
	var elapsed : int = clock - int(char.get("last_settled_at", 0) if char.get("last_settled_at", 0) != null else 0)
	report.charID = charID
	report.accountID = _statInt(char, "account_id", 0)
	report.zoneID = _statInt(char, "farm_zone", 0)
	report.lastSettledAt = _statInt(char, "last_settled_at", 0)
	# Cap do PERSONAGEM: o que a compra da conta dá (1h no F2P, 24h no VIP) mais
	# o que este personagem assistiu desde a última coleta. O anchor entra no
	# corte porque hora já liquidada não pode ser vendida de novo.
	report.capHours = CapHoursForCharacter(charID, report.accountID, report.lastSettledAt, clock)
	report.hours = minf(float(elapsed) / 3600.0, report.capHours)
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0) if char.get("session_efficiency", 1.0) != null else 1.0), MinEfficiency, 1.0)
	_ApplyFormula(sql, report, _LootMult(report.accountID, clock))
	return report

# Applies a pending settle for charID. Returns empty dict when nothing to settle.
static func SettlePending(charID : int) -> Dictionary:
	var sql : SQLService = _sql()
	var char : Dictionary = sql.GetCharacter(charID)
	if char.is_empty():
		return {}

	var lastSettled : int = int(char.get("last_settled_at", 0))
	var now : int = _now()
	if now <= lastSettled:
		return {}		# nothing elapsed (idempotent fast-path)

	var zoneID : int = int(char.get("farm_zone", 0))
	if zoneID <= 0:
		# No farming configured: just advance the anchor so time keeps flowing
		_UpdateAnchor(sql, charID, now)
		return {}

	var report : SettleReport = SettleReport.new()
	report.charID = charID
	report.accountID = _statInt(char, "account_id", 0)
	report.zoneID = zoneID
	report.lastSettledAt = now
	# O corte das horas compradas é o anchor VELHO (lastSettled), não
	# report.lastSettledAt: este já é `now` e filtraria toda view da própria
	# janela que estamos liquidando.
	report.capHours = CapHoursForCharacter(charID, report.accountID, lastSettled, now)
	report.hours = minf(float(now - lastSettled) / 3600.0, report.capHours)
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0) if char.get("session_efficiency", 1.0) != null else 1.0), MinEfficiency, 1.0)
	# NOTE: session deaths are already baked into session_efficiency on disconnect
	# (NetServer SOM-IDLE hook); the spike does not track a separate death count.

	_ApplyFormula(sql, report, _LootMult(report.accountID, now))
	if not _Apply(sql, report):
		return {}
	return report.to_dictionary()

# Multiplicador de loot da liquidação (1 ou 2). Desde a regra de 2026-09-25 o
# único ×2 é o perk permanente do VIP tier 2: anúncio não entra aqui, anúncio
# compra HORA (CapHoursForCharacter). Só XP/ouro/drops escalam.
static func _LootMult(accountID : int, now : int = 0) -> int:
	if accountID <= 0:
		return 1
	var sql : SQLService = _sql()
	var t : int = now if now > 0 else _now()
	if sql.GetVIPTier(accountID) == 2 and sql.GetVIPUntil(accountID) > t:
		return 2
	return 1

# ------------------------------------------------------------------ formula

# Teto comprado pela CONTA: 1h no F2P, 24h em qualquer tier de VIP (válido só
# com janela ativa; expirado volta ao base). É a metade que não depende de
# anúncio — a outra metade (horas assistidas) entra em CapHoursForCharacter.
# Pura p/ seams.
static func CapHoursForAccount(accountID : int, now : int = 0) -> float:
	if accountID <= 0:
		return BaseCapHours
	var t : int = now if now > 0 else _now()
	var sql : SQLService = _sql()
	if sql.GetVIPUntil(accountID) <= t:
		return BaseCapHours
	match sql.GetVIPTier(accountID):
		1:
			return CapHoursVIP1
		2:
			return CapHoursVIP2
	return BaseCapHours

# Horas de offline compradas com anúncio e ainda não liquidadas (0 sem Economy
# no caminho, p/ o seam headless continuar puro).
static func AdHoursEarned(accountID : int, charID : int, anchorTs : int) -> float:
	var eco : EconomyService = _economy()
	if eco == null:
		return 0.0
	return eco.AfkHoursEarned(accountID, charID, anchorTs)

# Teto liquidável do PERSONAGEM = o que a conta comprou (F2P/VIP) + o que o
# personagem assistiu e ainda não coletou. A leitura é por personagem porque o
# anchor é character.last_settled_at e a view carrega char_id.
static func CapHoursForCharacter(charID : int, accountID : int, anchorTs : int, now : int = 0) -> float:
	return CapHoursForAccount(accountID, now) + AdHoursEarned(accountID, charID, anchorTs)

# SOM-IDLE: F3 — settle mods by account: VIP window (+20% idle faucet),
# guild hook reserved (F4). Kept as a pure function for test seams.
static func GetModsForAccount(accountID : int, now : int = 0) -> float:
	var mods : float = GuildHookFactor
	if accountID > 0 and now > 0:
		var sql : SQLService = _sql()
		var vipUntil : int = sql.GetVIPUntil(accountID)
		if vipUntil > now:
			mods *= VIPModFactor
		# SOM-IDLE E1: buff de guild (2%/nível a partir do 2) no faucet idle.
		var eco : EconomyService = _economy()
		if eco:
			mods *= eco.GuildBuffForAccount(accountID)
		if eco:
			mods *= eco.GetLiveEventMods(accountID)
	return mods

static func _ApplyFormula(sql : SQLService, report : SettleReport, adMult : int = 1):
	var zone : FarmZoneData = FarmZoneData.GetZone(report.zoneID)
	if zone == null:
		return

	var h : float = report.hours
	var eff : float = report.efficiency

	# SOM-IDLE rebirth: favores compõem o faucet offline; attune eleva o fator de
	# 0.60 até 0.80 (cap). attune 0 / favor 0 ⇒ identidade com o golden de settle.
	var rebInfo : Dictionary = sql.GetRebirthInfo(report.charID)
	var rebXp : float = RebirthData.XpMult(int(rebInfo.get("favor_xp", 0)))
	var rebGold : float = RebirthData.GoldMult(int(rebInfo.get("favor_gold", 0)))
	var offFactor : float = RebirthData.OfflineFactorWithBonus(OfflineFactor, int(rebInfo.get("attune_offline", 0)))

	report.mods = GetModsForAccount(report.accountID, _now())
	# Tormento (D2): recompensa offline escala com a dificuldade do char.
	report.mods *= Formula.TormentRewardMult(sql.GetTormentLevel(report.charID))
	# SOM-IDLE newbie boost: primeiras 48h (até level 10) rendem 5× offline.
	var charLevel : int = int(sql.GetCharacter(report.charID).get("level", 1))
	var newbieMult : float = float(FarmZoneData.NewbieBoostFactor) if charLevel < FarmZoneData.NewbieBoostMaxLevel else 1.0
	# Tier 2: o ×2 dobra XP/ouro/drops da liquidação. Baús, chaves e favores
	# intactos. Essência de overflow acompanha o XP dobrado (mesmo eixo
	# tempo-por-tempo do VIP 1.2× — §2.5, não é faucet de essência).
	report.doubled = adMult > 1
	report.xpEarned = roundi(float(zone.xpPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * report.mods * rebXp * float(adMult) * newbieMult)
	report.goldEarned = roundi(float(zone.goldPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * report.mods * rebGold * float(adMult) * newbieMult)
	if eff < 1.0:
		report.goldTaxed = roundi(float(report.goldEarned) * float(DeathTaxPct) / 100.0)

	# Drops: rate_ppm * h * 3600 * eff * factor / 1e6 (expected value, deterministic in spike)
	var dropExpected : float = float(zone.dropRatePPM) * h * 3600.0 * eff * offFactor / 1000000.0
	var dropCount : int = floori(dropExpected)
	var frac : float = dropExpected - float(dropCount)
	# Deterministic fractional carry (no RNG in the golden path)
	if frac >= 0.5:
		dropCount += 1
	dropCount *= adMult
	if dropCount > 0:
		# SOM-IDLE: F3 — tier-banded drop pool (deterministic pick per char+zone)
		var itemHash : int = FarmZoneData.GetDropForRoll(report.zoneID, report.charID + report.zoneID)
		report.drops[itemHash] = dropCount

	# Baús: 1 a cada 4h liquidadas, no máx. MaxChests por coleta. Com o baseline
	# de 1h o floor() sozinho pagaria 0 baú para quem não assistiu anúncio
	# nenhum, e a janela AFK é exatamente o produto do F2P — então 1h vale 1 baú
	# (abaixo de 1h não há piso: coleta de 20 minutos não entrega nada). O teto
	# diário por personagem fecha a outra ponta: com gate de pegada de 60 s em
	# Server.gd:490, uma coleta por minuto pagaria 1 baú por minuto.
	var chestWanted : int = mini(floori(h / float(ChestHoursPerChest)), MaxChests)
	if chestWanted == 0 and h >= 1.0:
		chestWanted = 1
	report.chests = mini(chestWanted, _ChestBudgetToday(sql, report.charID))

	# SOM-IDLE: chaves de boss também acumulam offline (idle-first) — kills
	# equivalentes da sessão × KeyDropPPM, com o mesmo carry determinístico de
	# fração (>=0.5) usado nos drops de item. Sem RNG no caminho golden.
	var equivKills : float = float(zone.parKillsPerHour) * h * eff * offFactor * report.mods
	var keyExpected : float = float(BossService.KeyDropPPM) * equivKills / 1000000.0
	var keyCount : int = floori(keyExpected)
	if keyExpected - float(keyCount) >= 0.5:
		keyCount += 1
	report.bossKeysEarned = maxi(0, keyCount)

# Baús que ainda cabem no dia do personagem. `created_at` de chest_instance é
# carimbado pelo SQL com o relógio real, então a janela contada aqui também é
# real — régua e prêmio no mesmo relógio, senão o nowOverride do harness
# descentralizaria o contador. Leitura fora de transação: queryMutex não é
# reentrante e _Apply abre a dele logo abaixo.
static func _ChestBudgetToday(sql : SQLService, charID : int) -> int:
	var dayStart : int = EconomyCatalog.PassDayStartTS(EconomyCatalog.ShopDay(SQLCommons.Timestamp()))
	var rows : Array[Dictionary] = sql.QueryBindings("SELECT COUNT(*) AS n FROM chest_instance WHERE char_id = ? AND origin = 'settle' AND created_at >= ?;", [charID, dayStart])
	var minted : int = 0
	if not rows.is_empty():
		minted = int(rows[0]["n"])
	return maxi(0, EconomyCatalog.ChestsPerDayFromSettle - minted)

# ------------------------------------------------------------------ apply (transactional)

static func _Apply(sql : SQLService, report : SettleReport) -> bool:
	var sqlNode : SQLService = sql
	var applied : bool = false
	# Transaction returns TRUE on commit (old `if not` relied on nested-tx corruption, F3/F4 fix)
	if sqlNode.Transaction(func() -> bool:
		# Idempotency guard: re-read the anchor INSIDE the transaction
		var fresh : Dictionary = sqlNode.GetCharacter(report.charID)
		if fresh.is_empty() or int(fresh.get("last_settled_at", 0)) >= report.lastSettledAt:
			return false

		# 1) level recompute through the Experience curve
		# NOTE: sqlite columns may be NULL (fresh characters ship experience = NULL);
		# int(<null>) throws in Godot 4.7, so read through the null-safe helper.
		var stat : Dictionary = sqlNode.GetStat(report.charID)
		var level : int = _statInt(stat, "level", 1)
		var progressXP : int = _statInt(stat, "experience", 0) + report.xpEarned
		var newLevel : int = level
		while not Experience.IsMaxLevel(newLevel):
			var needed : int = Experience.GetNeededExperienceForNextLevel(newLevel)
			if needed == Experience.MAX_LEVEL_REACHED or progressXP < needed:
				break
			progressXP -= needed
			newLevel += 1
		report.levelsGained = newLevel - level
		report.newLevel = newLevel

		# SOM-IDLE rebirth: XP que sobra no cap vira essência (1%) dentro da mesma
		# transação; o resto (< 100 XP) fica acumulado no bucket para o próximo
		# settle. Assim o jogador AFK nunca "perde" progresso por estar no cap.
		var essenceGain : int = 0
		if Experience.IsMaxLevel(newLevel) and progressXP >= RebirthData.EssenceDivisor:
			essenceGain = progressXP / RebirthData.EssenceDivisor
			if essenceGain > 0:
				progressXP -= essenceGain * RebirthData.EssenceDivisor
				if sqlNode.AddCharacterEssence(report.charID, essenceGain) < 0:
					return false
				report.essenceEarned = essenceGain

		# 2) gold (5% tax when efficiency < 1.0)
		var goldNet : int = report.goldEarned - report.goldTaxed
		var newGold : int = _statInt(stat, "gp", 0) + goldNet

		if not sqlNode.UpdateStatDirect(report.charID, newLevel, progressXP, newGold):
			return false

		# 3) drop items straight into character inventory
		for itemHash in report.drops:
			if not sqlNode.AddItemToCharacter(report.charID, itemHash, report.drops[itemHash]):
				return false

		# 4) ledger rows (gold + xp; item rows appended per drop)
		var accountID : int = int(fresh.get("account_id", 0))
		var economy : EconomyService = _economy()
		if economy:
			if goldNet != 0 and not economy.LedgerAppend(report.charID, accountID, "gold", goldNet, newGold, "offline_settle"):
				return false
			if report.xpEarned > 0 and not economy.LedgerAppend(report.charID, accountID, "xp", report.xpEarned, progressXP, "offline_settle"):
				return false
			if report.essenceEarned > 0 and not economy.LedgerAppend(report.charID, accountID, "essence", report.essenceEarned, sqlNode.GetCharacterEssence(report.charID), "offline_settle"):
				return false

		# 5) chests (rows only; opening is F4 scope)
		for i in report.chests:
			if not sqlNode.AddChestInstance(report.charID, 0, "settle"):
				return false

		# 5b) SOM-IDLE: boss keys from offline farming (character column + ledger
		# mirror; the ledger kind is 'boss_key' so it never collides with the
		# gold/xp row-count assertions in the settle golden).
		if report.bossKeysEarned > 0:
			if sqlNode.AddCharacterBossKeys(report.charID, report.bossKeysEarned) < 0:
				return false
			if economy != null:
				if not economy.LedgerAppend(report.charID, accountID, "boss_key", report.bossKeysEarned, sqlNode.GetCharacterBossKeys(report.charID), "offline_settle"):
					return false

		# 6) anchor update
		if not sqlNode.UpdateSettleAnchor(report.charID, report.lastSettledAt, 1.0):
			return false

		# Fase F: pontos de guild (1/hora liquidada) — alimenta a corrida
		# guild_points. Dentro da transação: sem settle, sem ponto.
		var economy2 : EconomyService = _economy()
		if economy2 != null:
			economy2.GuildSettlePoints(accountID, maxi(1, floori(report.hours)))

		return true):
		applied = true
	# SOM-IDLE D2: product telemetry (fora da transação, best-effort).
	var tele : TelemetryService = _telemetry()
	if tele:
		tele.Record("settle", report.accountID, report.charID, report.xpEarned,
			JSON.stringify({"zone" = report.zoneID, "hours" = report.hours, "eff" = report.efficiency, "gold" = report.goldEarned, "mods" = report.mods}))
		if report.levelsGained > 0:
			tele.Record("levelup", report.accountID, report.charID, report.levelsGained,
				JSON.stringify({"zone" = report.zoneID, "from" = report.newLevel - report.levelsGained, "to" = report.newLevel, "hours" = report.hours}))
	return applied

static func _UpdateAnchor(sql : SQLService, charID : int, now : int):
	sql.UpdateSettleAnchor(charID, now, 1.0)

# Null-safe sqlite int read (Godot 4.7 throws on int(<null>))
static func _statInt(row : Dictionary, key : String, fallback : int) -> int:
	var value : Variant = row.get(key, fallback)
	return fallback if value == null else int(value)
