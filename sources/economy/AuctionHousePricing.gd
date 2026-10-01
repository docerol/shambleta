extends RefCounted
class_name AuctionHousePricing

# Fatia #93.1 que saiu de `AuctionHouseService.gd` quando o teto anti-god-node
# dele estourou. O critério de corte aqui não é "menor arquivo": a banda é função
# de (item, preço por unidade) mais LEITURA de `ah_price_history` — não toca
# mutex, escrow, ledger nem o laço de preenchimento, que são justamente as pernas
# que exigem o `_eco` da fachada. Por isso ela pode ser estática e por isso ela
# sai sem mudar nenhuma semântica de locking. A fachada mantém o chamamento
# (`ListItemForSaleChecked`): o contrato público do leilão continua o serviço, e
# quem consulta a régua de preço é ele.

# Banda de preço do ask (achado #93.1: `ListItemForSale` olhava só `> 0`, então
# "preço" era o que o vendedor quisesse e a lavagem começava com o preço já
# combinado). O teto é uma FAIXA sobre o preço por unidade, ancorada em dado de
# mercado real: a mediana das últimas `AHBandSamples` unidades REALIZADAS do item
# (`ah_price_history`, migração 059) e, na falta de histórico, o preço do vendor
# para aquele item — que é o teto econômico honesto: qualquer um pode comprar a
# mercadoria do vendor por aquele valor, então pedir 8× o vendor é ruim, não é
# prova de conluio. Fora da faixa o anúncio é RECUSADO com o motivo na resposta.
# Item sem histórico e sem vendor (engrenagem nova de um jogador) fica sem banda:
# a primeira venda dele é o que cria a âncora, e as próximas perguntas já são
# medidas. Isso é limitação declarada, não buraco escondido — as outras três
# pernas (par de contas, cap diário, prazo) continuam valendo para o item novo.
const AHBandSamples : int = 10
const AHBandMinPct : int = 25
const AHBandMaxPct : int = 1000

# ------------------------------------------------------------------ #93.1: banda de preço do ask
# Âncora = mediana das unidades REALIZADAS mais recentes do item
# (`ah_price_history`, migração 059) e, sem histórico, o preço do vendor para
# aquele template. As duas fontes são dado de mercado, não opinião: a primeira é
# o que o item valeu, a segunda é o teto econômico honesto — qualquer jogador pode
# comprar a mercadoria no vendor por aquele valor, então pedir 8× o vendor é preço
# ruim, não prova de conluio. Item sem histórico e sem vendor (engrenagem nova de
# um jogador) fica SEM banda: a primeira venda dele é o que cria a âncora, e isso é
# limitação declarada — as outras três pernas do #93 (par de contas, cap diário,
# prazo) continuam valendo para ele.
static func AHVendorUnitPrice(itemID : int) -> int:
	if itemID <= 0:
		return 0
	for entry in EconomyCatalog.VENDOR_CATALOG:
		var offer : Dictionary = entry
		if int(str(offer.get("item", "")).hash()) != itemID:
			continue
		var perOffer : int = maxi(1, int(offer.get("count", 1)))
		var cost : int = int(offer.get("cost", 0))
		return 0 if cost <= 0 else maxi(1, int(round(float(cost) / float(perOffer))))
	return 0


static func AHPriceAnchor(itemID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT unit_price FROM ah_price_history WHERE item_id = ? ORDER BY sold_at DESC, id DESC LIMIT ?;", [itemID, AHBandSamples])
	var units : Array = []
	for row in rows:
		var unit : int = int((row as Dictionary).get("unit_price", 0))
		if unit > 0:
			units.append(unit)
	var median : int = 0
	if not units.is_empty():
		units.sort()
		var mid : int = units.size() / 2
		median = int(units[mid]) if units.size() % 2 == 1 else int(round((float(units[mid - 1]) + float(units[mid])) / 2.0))
	var vendor : int = AHVendorUnitPrice(itemID)
	var source : String = "none"
	if median > 0 and vendor > 0:
		source = "history+vendor"
	elif median > 0:
		source = "history"
	elif vendor > 0:
		source = "vendor"
	return {"anchor" = median, "vendor" = vendor, "source" = source, "samples" = units.size()}


# As duas bordas NÃO são simétricas de propósito, e é isso que faz a banda ser
# economicamente defensável em vez de um chute percentual:
#  - TETO = `AHBandMaxPct` × max(mediana, vendor). O vendor é o preço de substituto
#    perfeito: quem paga 10× o vendor pode comprar do vendor. Se a mediana REAL
#    estiver acima do vendor (item raro, mercado quente), o mercado manda — teto
#    sobre a mediana, não sobre a loja, senão o item que vale 5000 passa a não ter
#    anúncio válido nenhum.
#  - PISO = `AHBandMinPct` × min(mediana, vendor) (e, com uma das duas fontes
#    ausente, a que existe). O piso existe para matar o ask simbólico — 1 gold de
#    "venda" que transfere riqueza para a alt e registra histórico de preço sem
#    mercado. ancorá-lo no MÍNIMO das referências é o que impede uma venda cara
#    pontual de criminalizar o vendedor barato: mercado caindo é preço baixo, e
#    preço baixo é o que a descoberta de preço faz.
# Item sem histórico e sem vendor fica SEM banda: a primeira venda dele é o que
# cria a âncora.
# `unitPrice` é POR UNIDADE — o mesmo `unit_price` que `_RecordSoldLocked` grava e
# que `RecentSoldSummary` mostra a quem vai pôr preço. Comparar a banda com
# `price_gold` (o TOTAL do anúncio) é a fonte clássica de banda errada em favor do
# esperto: um anúncio de 5 unidades por 60 gold vale 12/unidade.
static func AHPriceBand(itemID : int, unitPrice : int) -> Dictionary:
	var anchor : Dictionary = AHPriceAnchor(itemID)
	var median : int = int(anchor.get("anchor", 0))
	var vendor : int = int(anchor.get("vendor", 0))
	var highBase : int = maxi(median, vendor)
	var lowBase : int = 0
	if median > 0 and vendor > 0:
		lowBase = mini(median, vendor)
	elif median > 0:
		lowBase = median
	else:
		lowBase = vendor
	if highBase <= 0:
		return {"ok" = true, "reason" = "no_anchor", "anchor" = 0, "min" = 0, "max" = 0, "source" = str(anchor.get("source", "none"))}
	var low : int = maxi(1, int(round(float(lowBase) * float(AHBandMinPct) / 100.0)))
	var high : int = maxi(low, int(round(float(highBase) * float(AHBandMaxPct) / 100.0)))
	var out : Dictionary = {"anchor" = highBase, "min" = low, "max" = high, "source" = str(anchor.get("source", ""))}
	if unitPrice < low:
		out["ok"] = false
		out["reason"] = "price_below_band"
	elif unitPrice > high:
		out["ok"] = false
		out["reason"] = "price_above_band"
	else:
		out["ok"] = true
		out["reason"] = "ok"
	return out
