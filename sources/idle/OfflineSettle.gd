extends RefCounted
class_name OfflineSettle

# SOM-IDLE: F2 idle-spike settle (TECH_SPEC_CORE.md §3)
# OfflineFactor = 0.6, BaseCapHours = 12, death tax 5%, chests floor(h/4) cap 3.
# The whole settle runs in ONE SQLite transaction; idempotency is enforced by
# re-reading last_settled_at INSIDE the transaction before any write.

const OfflineFactor : float = 0.6
const BaseCapHours : float = 12.0
# SOM-IDLE Fase B: cap diferenciado por tier (MONETIZATION §2.2) — F2P sente o
# teto de 12h; VIP1 estende a 24h; VIP2 a 36h. Expirado volta a 12h.
const CapHoursVIP1 : float = 24.0
const CapHoursVIP2 : float = 36.0
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
	# Fase E: rewarded ad no claim (2× F2P, 4× VIP). `armed` = preview (vale no
	# próximo Collect); `doubled` = aplicado. Só XP/ouro/drops dobram — baús,
	# chaves e favores nunca (MONETIZATION §2.5/§0.1).
	var armed : bool = false
	var doubled : bool = false

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
			"armed": armed,
			"doubled": doubled,
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

	var elapsed : int = (now if now > 0 else _now()) - int(char.get("last_settled_at", 0) if char.get("last_settled_at", 0) != null else 0)
	report.charID = charID
	report.accountID = _statInt(char, "account_id", 0)
	report.zoneID = _statInt(char, "farm_zone", 0)
	report.lastSettledAt = _statInt(char, "last_settled_at", 0)
	report.hours = minf(float(elapsed) / 3600.0, CapHoursForAccount(report.accountID))
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0) if char.get("session_efficiency", 1.0) != null else 1.0), MinEfficiency, 1.0)
	_ApplyFormula(sql, report, _AdMult(report.accountID, charID, report.lastSettledAt))
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
	report.hours = minf(float(now - lastSettled) / 3600.0, CapHoursForAccount(report.accountID))
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0)), MinEfficiency, 1.0)
	# NOTE: session deaths are already baked into session_efficiency on disconnect
	# (NetServer SOM-IDLE hook); the spike does not track a separate death count.

	_ApplyFormula(sql, report, _AdMult(report.accountID, charID, lastSettled))
	if not _Apply(sql, report):
		return {}
	return report.to_dictionary()

# Fase E: multiplicador do ad armado (0/2/4). VIP dobra o bônus (2×→4×) no
# momento do settle. Puro p/ seams; null-safe sem Economy (retorna 1).
static func _AdMult(accountID : int, charID : int, anchorTs : int) -> int:
	var eco : EconomyService = _economy()
	if eco == null or not eco.IsAfkAdArmed(accountID, charID, anchorTs):
		return 1
	var sql : SQLService = _sql()
	if sql.GetVIPUntil(accountID) > _now():
		return 4
	return 2

# ------------------------------------------------------------------ formula

# SOM-IDLE Fase B: teto de horas liquidáveis por conta — 12h F2P / 24h VIP1 /
# 36h VIP2 (válido só com janela ativa; expirado volta ao base). Pura p/ seams.
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
	# Fase E: ad armado dobra XP/ouro/drops da liquidação (4× com VIP). Baús,
	# chaves e favores intactos. Essência de overflow acompanha o XP dobrado
	# (mesmo eixo tempo-por-tempo do VIP 1.2× — §2.5, não é faucet de essência).
	report.doubled = adMult > 1
	report.xpEarned = roundi(float(zone.xpPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * report.mods * rebXp * float(adMult))
	report.goldEarned = roundi(float(zone.goldPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * report.mods * rebGold * float(adMult))
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
	report.armed = adMult > 1
	if dropCount > 0:
		# SOM-IDLE: F3 — tier-banded drop pool (deterministic pick per char+zone)
		var itemHash : int = FarmZoneData.GetDropForRoll(report.zoneID, report.charID + report.zoneID)
		report.drops[itemHash] = dropCount

	report.chests = mini(floori(h / float(ChestHoursPerChest)), MaxChests)

	# SOM-IDLE: chaves de boss também acumulam offline (idle-first) — kills
	# equivalentes da sessão × KeyDropPPM, com o mesmo carry determinístico de
	# fração (>=0.5) usado nos drops de item. Sem RNG no caminho golden.
	var equivKills : float = float(zone.parKillsPerHour) * h * eff * offFactor * report.mods
	var keyExpected : float = float(BossService.KeyDropPPM) * equivKills / 1000000.0
	var keyCount : int = floori(keyExpected)
	if keyExpected - float(keyCount) >= 0.5:
		keyCount += 1
	report.bossKeysEarned = maxi(0, keyCount)

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
