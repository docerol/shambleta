extends RefCounted
class_name EconomyCatalog

# SOM-IDLE / ROADMAP_COMERCIAL S3: catálogo de dados puros + helpers puros
# extraídos de EconomyService.gd (fatia 1 — zero mudança de comportamento).
# EconomyService mantém aliases/wrappers p/ compatibilidade.

# (de EconomyService.gd:9)
const LedgerKindGold : String = "gold"

# (de EconomyService.gd:10)
const LedgerKindXP : String = "xp"

# (de EconomyService.gd:11)
const LedgerKindItem : String = "item"

# (de EconomyService.gd:12)
const LedgerKindGems : String = "gems"

# (de EconomyService.gd:13)
const LedgerKindBossKey : String = "boss_key"

# (de EconomyService.gd:14)
const LedgerKindEssence : String = "essence"

# (de EconomyService.gd:19)
const SHARD_COUNT : int = 8

# (de EconomyService.gd:34)
const GrantPollSec : float = 30.0

# (de EconomyService.gd:507)
const TradeFeeGems : int = 10

# (de EconomyService.gd:514)
const TradeRequireVerifiedEmail : bool = true

# (de EconomyService.gd:605)
const ChestPityEvery : int = 10		# guaranteed rare (T3+) every N opens

# (de EconomyService.gd:702)
const VIP1CostGems : int = 440

# (de EconomyService.gd:703)
const VIP2CostGems : int = 880

# (de EconomyService.gd:704)
const VIPDays : int = 30

# (de EconomyService.gd:728)
const GrantKinds : Array[String] = ["gems", "gold", "vip_days", "pass_premium", "cosmetic"]

# (de EconomyService.gd:732)
const VIP_GRANT_TIERS : Dictionary = {
	"vip.1mo": 1, "vip.3mo": 2, "founder.pack": 1, "starter.pack": 1,
}

# (de EconomyService.gd:739)
const ChestCostGems : int = 120

# (de EconomyService.gd:740)
const MaxChestsPerPurchase : int = 10

# (de EconomyService.gd:782)
const SHOP_CATALOG : Array = [
	{"sku": "gems.550", "label": "550 gems", "price": 19.90},
	{"sku": "gems.1200", "label": "1200 gems", "price": 39.90},
	{"sku": "gems.3000", "label": "3000 gems", "price": 79.90},
	{"sku": "vip.1mo", "label": "VIP 30 days", "price": 24.90},
	{"sku": "vip.3mo", "label": "VIP 90 days", "price": 59.90},
	{"sku": "starter.pack", "label": "Starter: VIP 7d + 220 gems (D0–D3, one-time)", "price": 9.90},
	{"sku": "founder.pack", "label": "Founder: 1200 gems + VIP 30d + title", "price": 39.90},
	{"sku": "donate.support", "label": "Support: Apoiador title", "price": 4.90},
	{"sku": "pass.s1.deluxe", "label": "Pass S1 Deluxe: premium + 10 levels + gems", "price": 44.90},
]

# (de EconomyService.gd:793)
const STARTER_SKU : String = "starter.pack"

# (de EconomyService.gd:794)
const STARTER_MAX_AGE_SEC : int = 3 * 86400

# (de EconomyService.gd:855)
const DAILY_REROLL_COST : int = 20

# (de EconomyService.gd:856)
const DAILY_REROLLS_MAX : int = 3

# (de EconomyService.gd:857)
const DAILY_OFFERS_SHOWN : int = 3

# (de EconomyService.gd:859)
const SHOP_DAY_UTC_OFFSET : int = 6 * 3600

# (de EconomyService.gd:860)
const DAILY_POOL : Array = [
	{"id": "deal_chest1", "label": "1 chest", "kind": "chests", "count": 1, "cost": 120},
	{"id": "deal_chests5", "label": "5 chests (save 120)", "kind": "chests", "count": 5, "cost": 480},
	{"id": "deal_chests10", "label": "10 chests (save 240)", "kind": "chests", "count": 10, "cost": 960},
	{"id": "deal_vip3", "label": "VIP 3-day trial", "kind": "vip_days", "count": 3, "cost": 150},
]

# (de EconomyService.gd:868)
const BOSS_PACK_COST : int = 240

# (de EconomyService.gd:869)
const BOSS_PACK_CHESTS : int = 3

# (de EconomyService.gd:870)
const FINALE_CHESTS : int = 5

# (de EconomyService.gd:871)
const FINALE_COST : int = 400

# (de EconomyService.gd:872)
const FINALE_WINDOW_SEC : int = 2 * 86400

# (de EconomyService.gd:1056)
const VENDOR_STOCK_PER_DAY : int = 20

# (de EconomyService.gd:1057)
const VENDOR_CATALOG : Array = [
	{"id": "apple", "label": "Apple x1", "item": "Apple", "count": 1, "cost": 50},
	{"id": "water", "label": "Water Bottle x1", "item": "WaterBottle", "count": 1, "cost": 80},
	{"id": "candy", "label": "Cactus Sour Candy x1", "item": "CactusSourCandy", "count": 1, "cost": 150},
	{"id": "croissant", "label": "Croissant x1", "item": "Croissant", "count": 1, "cost": 120},
	{"id": "drink", "label": "Cactus Drink x1", "item": "CactusDrink", "count": 1, "cost": 200},
	{"id": "pitaya", "label": "Pitaya x1", "item": "Pitaya", "count": 1, "cost": 350},
	{"id": "potion", "label": "Cactus Potion x1", "item": "CactusPotion", "count": 1, "cost": 500},
]

# (de EconomyService.gd:1131)
const LIVE_EVENT_DEFAULT_MOD : float = 1.0

# (de EconomyService.gd:1226)
const ARENA_TICKETS_PER_DAY : int = 3

# (de EconomyService.gd:1227)
const ARENA_TICKETS_VIP_BONUS : int = 1

# (de EconomyService.gd:1228)
const ARENA_BASE_ELO : int = 1000

# (de EconomyService.gd:1229)
const ARENA_ELO_K : int = 32

# (de EconomyService.gd:1341)
const CORRUPT_FEE_BASE : int = 500		# gold × tier², queimado mesmo se brickar

# (de EconomyService.gd:1342)
const CORRUPT_BRICK_W : float = 0.25

# (de EconomyService.gd:1343)
const CORRUPT_SEALED_W : float = 0.30

# (de EconomyService.gd:1344)
const CORRUPT_BLESSED_W : float = 0.30

# (de EconomyService.gd:1346)
const CUBE_COUNT : int = 3

# (de EconomyService.gd:1347)
const SALVAGE_GOLD_PER_TIER2 : int = 25	# gold = tier² × 25

# (de EconomyService.gd:1348)
const SALVAGE_ESSENCE_TIER_MIN : int = 4

# (de EconomyService.gd:1349)
const SALVAGE_ESSENCE_PER_TIER : int = 2	# essência (loop do rebirth)

# (de EconomyService.gd:1549)
const FRONTIER_KEY_CHANCE : float = 0.30

# (de EconomyService.gd:1550)
const BOSS_KEY_GOLD_PRICE : int = 10000

# (de EconomyService.gd:1551)
const BOSS_RUSH_ESCALATION : int = 2

# (de EconomyService.gd:1834)
const RefundWindowSeconds : int = 7 * 86400

# (de EconomyService.gd:1880)
const GuildCreateCostGold : int = 5000

# (de EconomyService.gd:1881)
const GuildMaxLevel : int = 10

# (de EconomyService.gd:1884)
const GuildLevelCostGold : Array[int] = [0, 5000, 15000, 40000, 100000, 250000, 600000, 1500000, 4000000, 10000000]

# (de EconomyService.gd:1885)
const GuildLevelCostGems : Array[int] = [0, 50, 120, 300, 700, 1500, 3000, 6000, 12000, 25000]

# (de EconomyService.gd:1886)
const GuildBuffPerLevel : float = 0.02

# (de EconomyService.gd:2120)
const GUILD_POINT_PER_SETTLE_HOUR : int = 1

# (de EconomyService.gd:2121)
const GUILD_POINT_PER_BOSS_WIN : int = 5

# (de EconomyService.gd:2122)
const GUILD_VAULT_BASE_SLOTS : int = 10

# (de EconomyService.gd:2123)
const GUILD_VAULT_PER_LEVEL : int = 2

# (de EconomyService.gd:2124)
const GUILD_VAULT_SLOT_COST : int = 200

# (de EconomyService.gd:2125)
const GUILD_VAULT_SLOTS_MAX : int = 20

# (de EconomyService.gd:2126)
const GUILD_PRIZE_GEMS : Array[int] = [1000, 600, 300]

# (de EconomyService.gd:2254)
const SeasonsBetaLock : bool = true

# (de EconomyService.gd:2341)
const SEASON_KINDS : Array[String] = ["power", "spend", "boss_kills", "guild_points"]

# (de EconomyService.gd:2345)
const SeasonPrizeGems : Array[int] = [3000, 1800, 1200, 700, 500, 400, 300, 300, 200, 200]

# (de EconomyService.gd:2431)
const AD_AFK2X : String = "afk2x"

# (de EconomyService.gd:2432)
const AD_CHEST : String = "chest"

# (de EconomyService.gd:2433)
const AD_REROLL : String = "reroll"

# (de EconomyService.gd:2434)
const AD_BOSSKEY : String = "bosskey"

# (de EconomyService.gd:2435)
const AD_PLACEMENTS : Array[String] = ["afk2x", "chest", "reroll", "bosskey"]

# (de EconomyService.gd:2436)
const AD_PLACEMENT_CAPS : Dictionary = {"chest": 1, "bosskey": 2}

# (de EconomyService.gd:2441)
const AdStubEnabled : bool = true

# (de EconomyService.gd:2442)
const AD_DAILY_CAP : int = 6

# (de EconomyService.gd:2539)
const COSMETIC_CATALOG : Dictionary = {
	# Passe S1 (fonte: trilha; volta na Loja do Legado após ≥2 temporadas —
	# live-ops futuro, por isso price 0 aqui).
	"skin_manto": {"type": "formation_skin", "label": "Manto do Descobridor", "price": 0, "req_rebirths": 0},
	"fx_faisca": {"type": "drop_fx", "label": "Faísca de Mana", "price": 0, "req_rebirths": 0},
	"frame_sazonal": {"type": "frame", "label": "Moldura Sazonal S1", "price": 0, "req_rebirths": 0},
	"skin_mascara": {"type": "formation_skin", "label": "Máscara Ritual de Tulimshar", "price": 0, "req_rebirths": 0},
	"emote_guilda": {"type": "emote", "label": "Sinal da Guilda", "price": 0, "req_rebirths": 0},
	"emote_tocha": {"type": "emote", "label": "Tocha do Explorador", "price": 0, "req_rebirths": 0},
	"title_redescobridor": {"type": "title", "label": "Redescobridor", "price": 0, "req_rebirths": 0},
	"title_veterano": {"type": "title", "label": "Veterano da Redescoberta", "price": 0, "req_rebirths": 0},
	"banner_guilda": {"type": "guild_banner", "label": "Estandarte da Redescoberta", "price": 0, "req_rebirths": 0},
	# Vitrine do renascimento (MONETIZATION §2.7): básico grátis no 1º ciclo,
	# estilo à venda em gems — sempre gems/passe, nunca essência (§0.1).
	"rebirth_t1": {"type": "title", "label": "Renascido I", "price": 0, "req_rebirths": 1},
	"rebirth_f1": {"type": "frame", "label": "Moldura do Primeiro Ciclo", "price": 0, "req_rebirths": 1},
	"rebirth_t3": {"type": "title", "label": "Renascido III", "price": 150, "req_rebirths": 3},
	"rebirth_f5": {"type": "frame", "label": "Moldura do Quinto Ciclo", "price": 300, "req_rebirths": 5},
	"rebirth_f10": {"type": "frame", "label": "Moldura do Décimo Ciclo", "price": 600, "req_rebirths": 10},
	"rebirth_fx": {"type": "rebirth_fx", "label": "Partículas do Renascimento", "price": 250, "req_rebirths": 1},
	# Apoio (backfill de compras Fase A; títulos prometidos nos payloads).
	"title_recruta": {"type": "title", "label": "Recruta", "price": 0, "req_rebirths": 0},
	"title_fundador": {"type": "title", "label": "Fundador", "price": 0, "req_rebirths": 0},
	# Fase F: campeão da copa semanal + apoiador (doação via companion).
	"title_campeao": {"type": "title", "label": "Campeão", "price": 0, "req_rebirths": 0},
	"title_apoiador": {"type": "title", "label": "Apoiador", "price": 0, "req_rebirths": 0},
	# Passe Deluxe (BATTLE_PASS_S1 §4): exclusivo vitalício, nunca retorna nem
	# na Loja do Legado.
	"emote_coroa": {"type": "emote", "label": "Coroa do Sol", "price": 0, "req_rebirths": 0},
}

# (de EconomyService.gd:2696)
const PASS_DAILY_PT : int = 40

# (de EconomyService.gd:2697)
const PASS_WEEKLY_PT : int = 120

# (de EconomyService.gd:2698)
const PASS_MILESTONE_PT : int = 50

# (de EconomyService.gd:2699)
const PASS_SKIP_COST : int = 50

# (de EconomyService.gd:2700)
const PASS_SKIP_MAX : int = 10

# (de EconomyService.gd:2701)
const PASS_MAX_LEVEL : int = 40

# (de EconomyService.gd:2702)
const PASS_BONUS_START : int = 31

# (de EconomyService.gd:2703)
const PASS_BONUS_GEMS : int = 20

# (de EconomyService.gd:2704)
const PASS_DOUBLEXP_LAST_DAYS : int = 3

# (de EconomyService.gd:2707)
const PASS_FREE : Dictionary = {
	3: {"gems": 10}, 5: {"chests": 1}, 8: {"gems": 10},
	10: {"cosmetics": ["emote_tocha"]}, 13: {"gems": 15}, 16: {"chests": 1},
	20: {"gems": 15}, 24: {"chests": 2}, 27: {"gems": 20},
	30: {"gems": 30, "cosmetics": ["title_redescobridor"]},
}

# (de EconomyService.gd:2715)
const PASS_PREMIUM : Dictionary = {
	1: {"cosmetics": ["skin_manto"]}, 3: {"gems": 25}, 5: {"vip_days": 3},
	6: {"gems": 25}, 8: {"cosmetics": ["fx_faisca"]}, 9: {"gems": 25},
	11: {"chests": 2}, 12: {"gems": 25}, 14: {"cosmetics": ["frame_sazonal"]},
	15: {"gems": 50}, 17: {"cosmetics": ["skin_mascara"]}, 18: {"gems": 25},
	21: {"chests": 3}, 22: {"gems": 25}, 24: {"cosmetics": ["emote_guilda"]},
	26: {"gems": 25}, 28: {"gems": 50},
	30: {"gems": 100, "cosmetics": ["title_veterano", "banner_guilda"]},
}

# (de EconomyService.gd:2728)
const PASS_DAILY_POOL : Array = [
	{"id": "d_settle2", "label": "Collect AFK 2×", "goal": 2},
	{"id": "d_chest1", "label": "Open 1 chest", "goal": 1},
	{"id": "d_level1", "label": "Gain 1 level (SUB equip)", "goal": 1},
	{"id": "d_farm2h", "label": "Settle 2h (SUB kills)", "goal": 2},
	{"id": "d_vault1", "label": "Deposit 1 item in guild vault", "goal": 1},
	{"id": "d_trade1", "label": "Complete 1 trade", "goal": 1},
	{"id": "d_ahlist1", "label": "List 1 item on AH (SUB reforge)", "goal": 1},
	{"id": "d_shop1", "label": "Open the shop (SUB ad)", "goal": 1},
]

# (de EconomyService.gd:2740)
const PASS_WEEKLY_POOL : Array = [
	{"id": "w_boss1", "label": "Defeat 1 zone boss", "goal": 1},
	{"id": "w_eff3", "label": "3 sessions ≥ 90% efficiency", "goal": 3},
	{"id": "w_spend100", "label": "Spend 100 gems", "goal": 100},
	{"id": "w_dailies15", "label": "Claim 15 dailies", "goal": 15},
	{"id": "w_guild1", "label": "Guild level-up or 3 vault deposits", "goal": 1},
	{"id": "w_farm8h", "label": "Settle 8h", "goal": 8},
]

# (de EconomyService.gd:3204)
const AHListFeeGems : int = 5

# (de EconomyService.gd:3205)
const AHMaxOpenPerAccount : int = 5

# (de EconomyService.gd:3208)
const AHHighlightFeeGems : int = 15

# (de EconomyService.gd:3209)
const AHSlotBaseCost : int = 50

# (de EconomyService.gd:3210)
const AHSlotsMaxExtra : int = 5

# (de EconomyService.gd:3338)
const TOURNAMENT_ENTRY_GOLD : int = 1000

# (de EconomyService.gd:3339)
const TOURNAMENT_DAYS : int = 7

# (de EconomyService.gd:3340)
const TOURNAMENT_PRIZES : Array[int] = [2000, 1200, 800, 500, 300]

# (de EconomyService.gd:3341)
const TOURNAMENT_CHAMPION_TITLE : String = "title_campeao"

# (de EconomyService.gd:3622)
const ACHIEVEMENTS : Array = [
	{"id": "slayer_100", "label": "Exterminador iniciante", "desc": "Derrote 100 monstros", "counter": "kills_total", "goal": 100, "gems": 25},
	{"id": "slayer_1000", "label": "Exterminador", "desc": "Derrote 1.000 monstros", "counter": "kills_total", "goal": 1000, "gems": 50, "cosmetic": "emote_tocha"},
	{"id": "slime_100", "label": "Caça-slimes", "desc": "Derrote 100 Slimes", "counter": "kills_mob", "mob": "Slime", "goal": 100, "gems": 30},
	{"id": "chest_10", "label": "Abre-baús", "desc": "Abra 10 baús", "counter": "chests", "goal": 10, "gems": 20},
	{"id": "chest_100", "label": "Mestre dos baús", "desc": "Abra 100 baús", "counter": "chests", "goal": 100, "gems": 60},
	{"id": "boss_1", "label": "Caçador de chefes", "desc": "Vença 1 chefe", "counter": "bosses", "goal": 1, "gems": 30},
	{"id": "boss_10", "label": "Lenda viva", "desc": "Vença 10 chefes", "counter": "bosses", "goal": 10, "gems": 100},
	{"id": "level_20", "label": "Veterano", "desc": "Alcance o nível 20", "counter": "level", "goal": 20, "gems": 25},
	{"id": "level_40", "label": "Elite", "desc": "Alcance o nível 40", "counter": "level", "goal": 40, "gems": 60},
	{"id": "rebirth_1", "label": "Renascer", "desc": "Renasça 1 vez", "counter": "rebirths", "goal": 1, "gems": 50},
]

# (de EconomyService.gd:3737)
const REFERRAL_BONUS_GEMS : int = 200

# (de EconomyService.gd:3738)
const REFERRAL_MIN_LEVEL : int = 10

# (de EconomyService.gd:3739)
const REFERRAL_WINDOW_SEC : int = 3 * 86400

# (de EconomyService.gd:3740)
const REFERRAL_WEEKLY_CAP : int = 10

# (de EconomyService.gd:3820)
const FraudTradeBurstPerDay : int = 10

# (de EconomyService.gd:3821)
const FraudLevelJump : int = 20

# (de EconomyService.gd:3822)
const FraudLevelJumpHours : float = 2.0

# (de EconomyService.gd:3886)
const CRAFT_BUDGET_CAP : Dictionary = {
	1: [20, 20, 15, 15, 5, 0, 20, 20],
	2: [30, 0, 0, 0, 0, 0, 0, 0],
	3: [0, 0, 0, 0, 0, 0, 66, 0],
	4: [0, 0, 0, 0, 0, 0, 95, 0],
	5: [0, 0, 0, 0, 0, 0, 146, 0],
	6: [0, 0, 0, 0, 0, 0, 0, 0],
	7: [0, 0, 0, 0, 0, 0, 0, 0],
	8: [0, 0, 0, 0, 0, 0, 0, 0],
}

# (de EconomyService.gd:3896)
const CRAFT_SLOT_NAMES : Array[String] = ["CHEST", "LEGS", "FEET", "HANDS", "HEAD", "NECK", "WEAPON", "SHIELD"]

# (de EconomyService.gd:3897)
const CRAFT_MOD_WEIGHTS : Array[float] = [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]

# (de EconomyService.gd:3898)
const CRAFT_RARITY_BANDS : Array = [[40, "Comum"], [65, "Incomum"], [85, "Raro"], [97, "Épico"], [101, "Lendário"]]

# (de EconomyService.gd:3899)
const CRAFT_RARITY_WEIGHT : Dictionary = {"Comum": 100, "Incomum": 60, "Raro": 30, "Épico": 12, "Lendário": 5}

# (de EconomyService.gd:3900)
const CRAFT_SUBMIT_FEE_BASE : int = 500

# (de EconomyService.gd:3901)
const CRAFT_MAX_PER_DAY : int = 3

# (de EconomyService.gd:3902)
const CRAFT_RESUB_MAX : int = 3

# (de EconomyService.gd:3903)
const CRAFT_RESUB_DAYS : int = 7

# (de EconomyService.gd:3904)
const CRAFT_CREATOR_FEE_PCT : int = 1

# (de EconomyService.gd:874)
static func ShopDay(now : int) -> int:
	return (now - SHOP_DAY_UTC_OFFSET) / 86400


# (de EconomyService.gd:2750)
static func PassThresholds() -> Array:
	var cum : Array = []
	var total : int = 0
	for lvl in range(1, PASS_MAX_LEVEL + 1):
		var step : int = 100 if lvl <= 10 else (120 if lvl <= 20 else 140)
		total += step
		cum.append(total)
	return cum


# (de EconomyService.gd:2759)
static func PassLevelForPT(pt : int) -> int:
	var cum : Array = PassThresholds()
	var level : int = 0
	for t in cum:
		if pt >= int(t):
			level += 1
		else:
			break
	return level

# Linha da conta/temporada (cria zerada). Leitura crua p/ uso em transações.

# (de EconomyService.gd:2817)
static func PassDailies(day : int) -> Array:
	var out : Array = []
	var n : int = PASS_DAILY_POOL.size()
	var start : int = (day * 5) % n
	for k in 3:
		out.append((PASS_DAILY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out


# (de EconomyService.gd:2825)
static func PassWeeklies(weekIdx : int) -> Array:
	var out : Array = []
	var n : int = PASS_WEEKLY_POOL.size()
	var start : int = (weekIdx * 3) % n
	for k in 3:
		out.append((PASS_WEEKLY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out


# (de EconomyService.gd:2833)
static func PassWeekIndex(season : Dictionary, now : int) -> int:
	return maxi(0, (ShopDay(now) - ShopDay(int(season.get("starts_at", now)))) / 7)


# (de EconomyService.gd:2836)
static func PassDayStartTS(day : int) -> int:
	return day * 86400 + SHOP_DAY_UTC_OFFSET


# (de EconomyService.gd:2570)
static func CosmeticLabel(cosmeticID : String) -> String:
	if COSMETIC_CATALOG.has(cosmeticID):
		return str((COSMETIC_CATALOG[cosmeticID] as Dictionary).get("label", cosmeticID))
	return ""


# (de EconomyService.gd:2287)
static func SeasonS1Rules() -> String:
	return JSON.stringify({
		"season" = "S1", "days" = 30,
		"kinds" = ["power", "spend", "boss_kills", "guild_points"],
		"prizes" = "gems+cosmetics, non-cashable",
		"frozen" = true,
	})


# (de EconomyService.gd:3742)
static func ReferralCodeFor(accountID : int, username : String) -> String:
	return "%s#%04d" % [username, accountID % 10000]


# (de EconomyService.gd:2094)
static func IsValidGuildTag(tag : String) -> bool:
	if tag.length() < 2 or tag.length() > 5:
		return false
	for c in tag:
		if not ((c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return false
	return true


# (de EconomyService.gd:3906)
static func CraftBudgetCap(tier : int, slot : int) -> int:
	if not CRAFT_BUDGET_CAP.has(tier) or slot < 0 or slot > 7:
		return 0
	return int((CRAFT_BUDGET_CAP[tier] as Array)[slot])


# (de EconomyService.gd:3911)
static func CraftRarityForUsage(pct : float) -> String:
	for band in CRAFT_RARITY_BANDS:
		if pct < float((band as Array)[0]):
			return str((band as Array)[1])
	return "Lendário"

# Taxa de submissão em gold: 500 × tier² (proposta; confirmar após o beta).

# (de EconomyService.gd:3918)
static func CraftSubmitFee(tier : int) -> int:
	return CRAFT_SUBMIT_FEE_BASE * tier * tier

# Normaliza nome p/ checagens (pré-filtro + duplicata).

# (de EconomyService.gd:3922)
static func CraftNormName(name : String) -> String:
	return name.strip_edges().to_lower()

# Distância de edição simples (golpe tipo Gladiu5 vs Gladius). O(n*m), nomes
# curtos — sem problema de performance no volume de submissões.

# (de EconomyService.gd:3927)
static func CraftEditDistance(a : String, b : String) -> int:
	var prev : Array = []
	for j in b.length() + 1:
		prev.append(j)
	for i in range(1, a.length() + 1):
		var cur : Array = [i]
		for j in range(1, b.length() + 1):
			cur.append(mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (0 if a[i - 1] == b[j - 1] else 1)))
		prev = cur
	return int(prev[b.length()])

# SOM-IDLE Fase H: validação + gravação de submissão de item criado.
# ITEM_CRAFTING.md §2: paga taxa de gold sink, valida orçamento, nome e capa
# diária; grava como 'pending'. GM aprova depois (WorldCommands).
#
# Validações (server-autorizado):
# - slot válido (0–7), baseItemHash > 0, name não-vazio
# - budget: soma ponderada de modifiers <= CraftBudgetCap(tier, slot) (0 = bloqueado)
# - taxa: player tem gp >= CraftSubmitFee(tier); burnt + ledger mirror
# - nome: não vazio, tamanho 3–30, não na blocklist, não duplicata (edit-distance < 2)
# - daily cap: CRAFT_MAX_PER_DAY submissões hoje
# - email verificado (D3 auth gate)
#
# Retorna {ok: bool, reason: String}.

# (de EconomyService.gd:3635, renomeado sem underscore)
static func AchievementByID(achievementID : String) -> Dictionary:
	for entry in ACHIEVEMENTS:
		if str(entry.get("id", "")) == achievementID:
			return entry
	return {}

