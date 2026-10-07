extends RefCounted
class_name GuildPerkShop

# M-2 (2026-10-07): a loja de perks no MESMO regime do `GuildSlotShop` — preço e
# linha de prévia são função do estado que o servidor já mandou (nível + tiers),
# e a cobrança é despachada para o service (boot dev/single-process) ou para o
# facade `Network` (cliente puro), na mesma ordem. A moeda aqui são PONTOS DA
# GUILDA, não gems do jogador: a prévia cita o custo porque cobrar sem dizer
# quanto era é o bug que `tests/spend_confirm_test.gd` prendeu, e o portão de
# confirmação do painel não abre sem linha impressa.
#
# O catálogo é `GuildPerkCatalog` — congelado no binário dos dois lados, então a
# prévia desenhada e o veredito do funil (`GuildService.BuyGuildPerk`) usam a
# MESMA fórmula; divergiria se a tela re-digitasse número.

static func Line(perkID : String, guildLevel : int, currentTier : int) -> String:
	var entry : Variant = GuildPerkCatalog.PERKS.get(perkID, null)
	if not (entry is Dictionary):
		return "Unknown perk."
	if currentTier >= int((entry as Dictionary)["max_tier"]):
		return "This perk is already at max tier."
	var cost : int = GuildPerkCatalog.NextCost(perkID, guildLevel, currentTier)
	return "Buy '%s' tier %d for %d guild points? Points leave the guild board now, the effect is permanent. Spend?" % [str(entry["label"]), currentTier + 1, cost]

static func Label(perkID : String) -> String:
	var entry : Variant = GuildPerkCatalog.PERKS.get(perkID, null)
	return str(entry["label"]) if entry is Dictionary else "perk"

static func Charge(eco : EconomyService, network : Object, accountID : int, perkID : String) -> Dictionary:
	if not GuildPerkCatalog.Exists(perkID):
		return {"ok" = false, "reason" = "perk_unknown"}
	if eco != null and accountID > 0:
		return eco.BuyGuildPerk(accountID, perkID)
	if network != null and network.has_method("BuyGuildPerk"):
		network.call("BuyGuildPerk", perkID)
		return {"ok" = true, "reason" = "requested"}
	return {"ok" = false, "reason" = "unavailable"}
