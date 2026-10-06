extends RefCounted
class_name GuildSlotShop

# A "loja" do painel de guilda: o gasto de gems que a guilda oferece — o slot
# extra do vault. Nada aqui toca UI nem autoload: preço e linha de prévia são
# função do estado que o servidor já mandou, e a cobrança é despachada para o
# service (boot dev/single-process, o caminho autoritativo) ou para o facade
# `Network` (cliente puro), na MESMA ordem de resolução que o painel usava antes
# de a loja ser separada. É o motivo de a prévia citar o preço: cobrar sem dizer
# quanto era foi o bug que `tests/spend_confirm_test.gd` prendeu.
#
# P1-C (auditoria 2026-10-06): o fast level-up (2× gems, pula o gold) saiu
# daqui com o serviço — era compra de multiplicador permanente com dinheiro
# real, na face exata que o princípio "sem P2W" do roadmap proíbe.

const KindSlot : int = 1

static func SlotLine() -> String:
	return "Buy one vault slot for %d gems? Gems are spent now, the slot is permanent. Spend?" % EconomyCatalog.GUILD_VAULT_SLOT_COST

# Cobra no caminho autoritativo disponível. `eco == null` OU ids inválidos (cliente
# puro) manda o RPC pelo facade; sem nenhum dos dois, devolve o motivo cru em vez
# de fingir que passou.
static func Charge(eco : EconomyService, network : Object, accountID : int, charID : int, kind : int) -> Dictionary:
	if kind != KindSlot:
		return {"ok": false, "reason": "unknown_kind"}
	if eco != null and accountID > 0 and charID > 0:
		return eco.BuyVaultSlots(accountID, charID)
	if network != null and network.has_method("BuyVaultSlots"):
		network.call("BuyVaultSlots")
		return {"ok": true, "reason": "requested"}
	return {"ok": false, "reason": "unavailable"}

# Rótulo do gasto para o feedback (`"vault slot"`), para a peça que
# monta a mensagem continuar sendo do painel.
static func Label(kind : int) -> String:
	return "vault slot"
