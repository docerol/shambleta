extends RefCounted
class_name GuildPerkCatalog

# M-2 (2026-10-07): a PRATELARIA da loja de perks de guilda — o que existe, quanto
# custa e o que cada tier entrega, tudo função pura, declarada uma única vez. Os
# números vivem aqui (e o espelho do painel é lido daqui); a MOEDA (pontos) e o
# estado (tier comprado) moram em `guild.points` e na tabela `guild_perk`
# (migração 072); o GASTO é serializado por `GuildService.BuyGuildPerk` dentro do
# funil `settleMutex + Transaction`, e os CONSUMIDORES do tier são `VaultSlotsForGuild`,
# `GuildBuffForAccount` e o teto de `GuildRoster`.
#
# Por que custo ESCALA COM O NÍVEL (a decisão do dono, 2026-10-07): a guilda
# grande colhe pontos na mesma taxa da pequena (1/hora + 5/boss), então um preço
# fixo transformaria a guilda de nível 1 em doadora perpétua para si mesma no
# longo prazo — o `(base + level_cost × level) × próximo_tier` aperta o custo
# junto com a receita acumulada e mantém cada compra uma decisão, não um click.

# Efeitos declarados (o consumidor lê o tier, NUNCA re-derive o número aqui):
#  vault  → +2 stacks distintas no cofre por tier (soma no cap de `VaultSlotsForGuild`)
#  boon   → +1% no mod de settle (xp E gold) por tier (multiplica em `GuildBuffForAccount`)
#  roster → +1 account na fileira por tier (soma no teto de `GuildRoster`)
const PERKS : Dictionary = {
	"vault": {"label": "Vault shelf", "base_cost": 30, "level_cost": 4, "max_tier": 5},
	"boon": {"label": "Camp boon", "base_cost": 40, "level_cost": 6, "max_tier": 4},
	"roster": {"label": "Roster push", "base_cost": 50, "level_cost": 8, "max_tier": 2},
}

const VaultSlotsPerTier : int = 2
const BoonPctPerTier : float = 0.01
const RosterSlotsPerTier : int = 1

static func Exists(perkID : String) -> bool:
	return PERKS.has(perkID)

# O preço do PRÓXIMO tier. `currentTier` vem do disco (0 = nunca comprado); um
# tier acima do máximo é recusa antes do cálculo, então o produto nunca expõe
# preço de coisa indisponível.
static func NextCost(perkID : String, guildLevel : int, currentTier : int) -> int:
	var entry : Variant = PERKS.get(perkID, null)
	if not (entry is Dictionary):
		return -1
	var lvl : int = maxi(1, guildLevel)
	return (int(entry["base_cost"]) + int(entry["level_cost"]) * lvl) * (currentTier + 1)

static func VaultBonusSlots(tier : int) -> int:
	return VaultSlotsPerTier * maxi(0, tier)

static func BoonMult(tier : int) -> float:
	return 1.0 + BoonPctPerTier * maxi(0, tier)

static func RosterBonusSlots(tier : int) -> int:
	return RosterSlotsPerTier * maxi(0, tier)
