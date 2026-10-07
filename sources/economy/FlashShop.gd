extends RefCounted
class_name FlashShop

# M-5 (2026-10-07): a vitrine do dia. Três ofertas por dia UTC (`ShopDay`),
# idênticas para TODOS os jogadores, derivadas de seed = dia — o mesmo contrato
# das `PassDailies(day)` da casa ("mesmas p/ todos, seed do dia"), e por isso
# mora numa classe pura sem banco nem conta: nada aqui depende de quem olha.
# O desconto (10–30%, degraus de 5) é sorteado do mesmo hash; o PREÇO base é
# âncora viva do catálogo (`ChestCostGems`, `VIP1CostGems`), passado pelo
# chamador — se o knob de economia anda, a vitrine anda junto no mesmo boot.
#
# Por que determinístico e por que isso NÃO é o defeito P1-F: P1-F acusava o
# baú do drop de usar seed previsível para um prêmio que deveria ser sorte. Aqui
# previsibilidade É o produto — a vitrine é anúncio, não loot; o sorte do jogo
# continua nos caminhos que a régua de previsibilidade de baú protege.

const Slots : int = 3
const MinPct : int = 10
const MaxPct : int = 30
const PctStep : int = 5

# LCG 32-bit puro (s = (s*40503 + 7921) mod 2^31-1): mesmo dia → mesma vitrine
# em qualquer máquina, sem depender do `hash()` do runtime.
static func _seeded(day : int, slot : int) -> int:
	var s : int = (day * 2654435761) % 2147483647
	for k : int in range(0, slot + 1):
		s = (s * 40503 + 7921) % 2147483647
	return s

# `chestGems`/`vip30Gems` vêm do catálogo vivo no chamador (nunca congelados
# aqui). Uma oferta: {"slot","kind","count","pct","base","cost","label"}.
static func Showcase(day : int, chestGems : int, vip30Gems : int) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	for slot : int in range(0, Slots):
		var s : int = _seeded(day, slot)
		var isChests : bool = (s % 2) == 0
		var pct : int = MinPct + PctStep * int((s >> 8) % ((MaxPct - MinPct) / PctStep + 1))
		var count : int = 0
		var base : int = 0
		var kind : String = ""
		if isChests:
			kind = "chests"
			count = 2 + (s >> 4) % 4
			base = chestGems * count
		else:
			kind = "vip_days"
			count = 3 + (s >> 4) % 5
			base = maxi(1, roundi(float(vip30Gems) * float(count) / 30.0))
		var cost : int = maxi(1, roundi(float(base) * float(100 - pct) / 100.0))
		out.append({"slot" = slot, "kind" = kind, "count" = count, "pct" = pct,
			"base" = base, "cost" = cost,
			"label" = "%dx %s −%d%%" % [count, kind, pct]})
	return out

# O token do ledger que CARIMBA a compra: um por (dia, slot) — a prova de que o
# mesmo dia não vende duas vezes a mesma prateleira vive no `flash:<dia>:<slot>`
# (append-only, sobrevive a restart; sem tabela nova, sem estado em memória).
static func Reason(day : int, slot : int) -> String:
	return "flash:%d:%d" % [day, slot]
