class_name Storefront

# Política de vitrine (plano 2026-09-25, fatias 2 e 4). Vive separada de
# `EconomyCatalog` porque o catálogo é dado amarrado a `data/conf/paid_catalog.json`
# por duas asserções de igualdade, e aqui é decisão: o que OFERTAR. Nada aqui
# muda o que se cobra: a porta do dinheiro continua sendo a outra
# (companion + `_GrantApplyAndMark`), e o que um SKU entrega continua vindo do
# `kind` do catálogo canônico.

# SKUs de passe. A verdade sobre o que É passe mora no `kind` de
# data/conf/paid_catalog.json; `SuiteStorefrontHonesty` amarra esta lista a ele
# para isto não virar uma quarta cópia à deriva. `pass.s2` entra junto com a
# temporada agendada de `data/conf/seasons.json`: um SKU de passe que a temporada
# declara e a vitrine não conhece é botão que o companion recusa.
const PassSkus : Array[String] = ["pass.s1", "pass.s1.deluxe", "pass.s2"]

# O passe só entrega com temporada ativa: `season_offer_status` no companion
# barra intent, preferência e sandbox quando a tabela `season` não tem linha
# `status='active'` (fail-closed). Anunciar o botão fora de temporada é
# merchandising mentiroso — dois cliques que morrem na etapa de preferência.
# `activePassSku` é o SKU base que a temporada em curso vende ("" = nenhuma), e a
# vitrine mostra exatamente {base, base.deluxe} ∩ catálogo: anunciar o passe de
# OUTRA temporada é o mesmo defeito com outra cara — botão pagável que concede
# premium na temporada errada. A segunda mentira foi real até aqui: `pass.s2` foi
# para `PassSkus` com a temporada agendada, mas o `BuyPass` do transport pedia
# `pass.s1` por literal, com a S1 no ar e a S2 por vir.
# Filtra a PAYLOAD, não o catálogo: o SKU continua cobrável e continua sendo um
# dos SKUs que o validador de boot amarra a `data/conf/paid_catalog.json`.
static func ShopCatalog(activePassSku : String) -> Array:
	var deluxe : String = activePassSku + ".deluxe"
	var out : Array = []
	for entry in EconomyCatalog.SHOP_CATALOG:
		var sku : String = str(entry.get("sku", ""))
		if PassSkus.has(sku) and sku != activePassSku and sku != deluxe:
			continue
		out.append(entry)
	return out

# Tipos de cosmético que alguém renderiza de fato. `title` vive no placar
# (`sources/gui/Leaderboard.gd:52,179` via `EquippedTitleLabel`); `formation_skin` é lido
# (`sources/gui/Formation.gd:83`). `frame`, `emote`, `drop_fx`, `guild_banner` e
# `rebirth_fx` não têm consumidor nenhum: os grants de marco/passe continuam
# valendo como registro, mas vender renderizador inexistente é cobrar por um
# produto que o jogo não mostra.
const RenderedCosmeticTypes : Array[String] = ["title", "formation_skin"]

static func IsRenderedCosmetic(cosmeticID : String) -> bool:
	var entry : Variant = EconomyCatalog.COSMETIC_CATALOG.get(cosmeticID, {})
	if not (entry is Dictionary):
		return false
	return RenderedCosmeticTypes.has(str((entry as Dictionary).get("type", "")))
