extends RefCounted
class_name RebirthData

# SOM-IDLE: rebirth (híbrido B+C). Motor de prestige com moeda de custo
# superlinear + soft-cap. Contrato: XP_PROGRESSION.md §4.2 · decisão
# quantificada: REBALANCE_XP_OPTIONS.md.
#
# Invariantes de design (da simulação de burnout do doc):
#  - o bônus COMPÕEM na renda (1.05^n), mas o CUSTO cresce mais rápido (1.7^n)
#    ⇒ tempo por upgrade eventualmente sobe: o motor não converge para zero.
#  - attune é o único bônus com cap (preserva o piso honesto do offline).

const EssenceDivisor : int = 100			# 100 XP de overflow -> 1 essência (1%)

const UpgradeXp : String		= "favor_xp"
const UpgradeGold : String		= "favor_gold"
const UpgradeAttune : String	= "attune_offline"
const UpgradeOrder : Array[String] = [UpgradeXp, UpgradeGold, UpgradeAttune]

const XpStep : float		= 0.05			# +5%/nível, composto na renda de XP
const GoldStep : float		= 0.05			# +5%/nível, composto na renda de ouro
const OfflineStep : float	= 0.02			# +0.02 no fator offline por nível...
const OfflineMaxLevels : int = 10			# ...cap: 10 níveis (0.60 -> 0.80)

const BaseCost : Dictionary = {
	UpgradeXp : 2000,
	UpgradeGold : 1500,
	UpgradeAttune : 3000,
}
const CostGrowth : float = 1.7				# custo do nível n = base × 1.7^n

#
static func IsUpgrade(upgradeID : String) -> bool:
	return upgradeID in UpgradeOrder

static func Cost(upgradeID : String, owned : int) -> int:
	if not BaseCost.has(upgradeID):
		return -1
	return roundi(float(BaseCost[upgradeID]) * pow(CostGrowth, float(maxi(0, owned))))

static func XpMult(owned : int) -> float:
	return pow(1.0 + XpStep, float(maxi(0, owned)))

static func GoldMult(owned : int) -> float:
	return pow(1.0 + GoldStep, float(maxi(0, owned)))

static func OfflineFactorWithBonus(base : float, levels : int) -> float:
	return clampf(base + OfflineStep * float(levels), base, base + OfflineStep * float(OfflineMaxLevels))

static func EssenceFromOverflowXp(overflowXp : int) -> int:
	return maxi(0, overflowXp / EssenceDivisor)
