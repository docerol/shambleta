extends RefCounted
class_name GuildSlotShop

# A "loja" do painel de guilda: os dois gastos de gems que a guilda oferece — o
# fast level-up (2x o custo em ouro da curva, não reembolsável) e o slot extra do
# vault. Nada aqui toca UI nem autoload: preço e linha de prévia são função do
# estado que o servidor já mandou, e a cobrança é despachada para o service
# (boot dev/single-process, o caminho autoritativo) ou para o facade `Network`
# (cliente puro), na MESMA ordem de resolução que o painel usava antes de a loja
# ser separada. É o motivo de a prévia citar o preço: cobrar sem dizer quanto era
# o bug que `tests/spend_confirm_test.gd` prendeu.

const KindLevelUp : int = 0
const KindSlot : int = 1

# Preço do próximo level em gems (o dobro do custo em ouro da curva), 0 quando não
# dá para calcular (level máximo ou estado ainda não lido).
static func FastLevelCost(guildState : Dictionary) -> int:
	var level : int = int(guildState.get("level", 0))
	if level < 1 or level >= EconomyCatalog.GuildLevelCostGems.size():
		return 0
	return int(EconomyCatalog.GuildLevelCostGems[level]) * 2

static func FastLevelLine(guildState : Dictionary) -> String:
	return "Fast level-up: %s L%d -> L%d for %d gems (2x the gold cost, not refunded). Spend?" % [
		str(guildState.get("name", "?")), int(guildState.get("level", 1)),
		int(guildState.get("level", 1)) + 1, FastLevelCost(guildState)]

static func SlotLine() -> String:
	return "Buy one vault slot for %d gems? Gems are spent now, the slot is permanent. Spend?" % EconomyCatalog.GUILD_VAULT_SLOT_COST

# Cobra no caminho autoritativo disponível. `eco == null` OU ids inválidos (cliente
# puro) manda o RPC pelo facade; sem nenhum dos dois, devolve o motivo cru em vez
# de fingir que passou.
static func Charge(eco : EconomyService, network : Object, accountID : int, charID : int, kind : int) -> Dictionary:
	if eco != null and accountID > 0 and charID > 0:
		if kind == KindLevelUp:
			return eco.LevelUpGuildFast(accountID, charID)
		return eco.BuyVaultSlots(accountID, charID)
	if network != null:
		var method : String = "LevelUpGuildFast" if kind == KindLevelUp else "BuyVaultSlots"
		if network.has_method(method):
			network.call(method)
			return {"ok": true, "reason": "requested"}
	return {"ok": false, "reason": "unavailable"}

# Rótulo do gasto para o feedback (`"level-up"` / `"vault slot"`), para a peça que
# monta a mensagem continuar sendo do painel.
static func Label(kind : int) -> String:
	return "level-up" if kind == KindLevelUp else "vault slot"
