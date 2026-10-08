extends RefCounted
class_name EconomyStateView

# FATIA 13 (gate anti-god-node): o agregador de estado que a janela de economia
# pede numa única RPC saiu de `EconomyService.gd` (851 → abaixo do teto de 800)
# para cá. Zero mudança de comportamento: o dicionário abaixo é montado campo por
# campo na mesma ordem, com as mesmas chamadas, e `EconomyService.GetEconomyState`
# continua sendo o ponto de entrada que `Server.gd`, o `Shop.gd` e as suítes
# chamam — inclusive porque `ShopService.gd` registra a decisão de o agregador não
# virar domínio: quem agrega é a fachada, e aqui só está a PROJEÇÃO do que a
# fachada já tinha. Composição com back-reference `_eco` (mesma forma dos serviços
# das Fatias 2-12): nada daqui abre transação, mutex ou SQL próprio.
#
# Por que este pedaço e não um corte arbitrário: é exatamente por aqui que os
# números do catálogo base validado chegam ao jogador — `chest_cost`, `vip1_cost`,
# `vip2_cost` e o espelho `catalog` do `SHOP_CATALOG` —, ou seja, a projeção é o
# vizinho imediato do que a rodada do juiz economia acrescentou à fachada.
#
# Estado consolidado das janelas de economia (Shop/Chests): wallet, baús
# fechados, odds públicas (texto pré-formatado, compliance loot box) e preços.
# Uma RPC única — as janelas pedem ao abrir e as ações devolvem o estado novo.
#
# Fase A (checkout sandbox): inclui `catalog` (espelho DISPLAY-ONLY do catálogo
# pago — `EconomyCatalog.SHOP_CATALOG`, amarrado a data/conf/paid_catalog.json por
# `ValidatePaidCatalog`; o grant autoritativo vive no companion; preço aqui nunca
# vira crédito), `starter_offer` (elegibilidade one-time D0–D3, sem
# migração: idade via account.created_timestamp + compra prévia via
# grant_queue payload) e `pending_grants` (fila do companion p/ esta conta).
#
# Espelho do catálogo: validado contra data/conf/paid_catalog.json no boot do
# servidor e em SuiteCatalogConsistency — não é mais "manter sincronizado à mão".

var _eco : EconomyService = null

func Build(accountID : int, charID : int) -> Dictionary:
	var chestIDs : Array = []
	for chest in Launcher.SQL.GetClosedChests(charID):
		chestIDs.append(int(chest["id"]))
	var until : int = Launcher.SQL.GetVIPUntil(accountID)
	var now : int = SQLCommons.Timestamp()
	var vipActive : bool = until > now
	var odds : Dictionary = _eco.GetChestOddsForCharacter(charID)
	# O cap exibido na Loja é o do PERSONAGEM que pediu o estado: 1h de base +
	# hora comprada em anúncio + perk de VIP. O anchor (last_settled_at) é o que
	# separa hora ganha de hora já liquidada — sem ele a vitrine ofereceria de
	# novo o que o jogador já coletou.
	var anchor : int = int(Launcher.SQL.GetCharacter(charID).get("last_settled_at", 0))
	# A vitrine segue a temporada: sem linha `active` na tabela, o companion recusa
	# intent/preferência/sandbox do passe, então a Loja não oferece o botão. As duas
	# respostas saem da MESMA linha lida uma vez — `season_active` diz se há
	# temporada, `activePassSku` diz qual passe ela vende (e pode ser "" com
	# temporada no ar, quando a linha congelou regras ilegíveis).
	var activeRow : Dictionary = _eco.ActiveSeason()
	var seasonActive : bool = not activeRow.is_empty()
	var activePassSku : String = SeasonConfig.PremiumSkuOfRow(activeRow)
	return {
		"gems" = _eco.GetGems(accountID),
		"chests" = chestIDs,
		"odds" = odds,
		"odds_text" = _eco.FormatChestOdds(odds),
		"pity" = _eco.GetChestPityStatus(charID),
		"chest_cost" = EconomyCatalog.ChestCostGems,
		"vip" = {"active" = vipActive, "until" = until, "mods" = OfflineSettle.VIPModFactor if vipActive else 1.0,
			"tier" = Launcher.SQL.GetVIPTier(accountID) if vipActive else 0,
			"cap_hours" = OfflineSettle.CapHoursForCharacter(charID, accountID, anchor, now)},
		"vip1_cost" = EconomyCatalog.VIP1CostGems,
		"vip2_cost" = EconomyCatalog.VIP2CostGems,
		"catalog" = Storefront.ShopCatalog(activePassSku),
		"season_active" = seasonActive,
		"starter_offer" = _eco.GetStarterOfferState(accountID),
		"pending_grants" = _eco.GetPendingGrants(accountID),
		"vendor" = _eco.GetVendorState(accountID),
		# M-5: a vitrine do dia (3 prateleiras determinísticas + carimbo `claimed`
		# da conta). Preço NÃO se re-derive na tela — ela pinta o que o funil cobra.
		"flash" = _eco.FlashToday(accountID),
		# M-3: o estado da porta do presente (taxa, mínimo, cota do dia, janela
		# anti-flip) — a tela desenha com esses números, o funil decide com eles.
		"gift" = _eco.giftService.GetGiftState(accountID),
	}
