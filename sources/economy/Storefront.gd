class_name Storefront

# Política de vitrine (plano 2026-09-25, fatias 2 e 4). Vive separada de
# `EconomyCatalog` porque o catálogo é dado amarrado a `data/conf/paid_catalog.json`
# por duas asserções de igualdade, e aqui é decisão: o que OFERTAR. Nada aqui
# muda o que se cobra: a porta do dinheiro continua sendo a outra
# (companion + `_GrantApplyAndMark`), e o que um SKU entrega continua vindo do
# `kind` do catálogo canônico.

# SKUs de passe. A verdade sobre o que É passe mora no `kind` de
# data/conf/paid_catalog.json; `SuiteStorefrontHonesty` amarra esta lista a ele
# para isto não virar uma quarta cópia à deriva.
const PassSkus : Array[String] = ["pass.s1", "pass.s1.deluxe"]

# O passe só entrega com temporada ativa: `season_offer_status` no companion
# barra intent, preferência e sandbox quando a tabela `season` não tem linha
# `status='active'` (fail-closed). Anunciar o botão fora de temporada é
# merchandising mentiroso — dois cliques que morrem na etapa de preferência.
# Filtra a PAYLOAD, não o catálogo: o SKU continua cobrável e continua sendo um
# dos dez que o validador de boot amarra a `data/conf/paid_catalog.json`.
static func ShopCatalog(seasonActive : bool) -> Array:
	if seasonActive:
		return EconomyCatalog.SHOP_CATALOG
	var out : Array = []
	for entry in EconomyCatalog.SHOP_CATALOG:
		if PassSkus.has(str(entry.get("sku", ""))):
			continue
		out.append(entry)
	return out

# Tipos de cosmético que alguém renderiza de fato. `title` vive no placar
# (`Leaderboard.gd:43,105` via `EquippedTitleLabel`); `formation_skin` é lido
# (`sources/gui/Formation.gd:37`). `frame`, `emote`, `drop_fx`, `guild_banner` e
# `rebirth_fx` não têm consumidor nenhum: os grants de marco/passe continuam
# valendo como registro, mas vender renderizador inexistente é cobrar por um
# produto que o jogo não mostra.
const RenderedCosmeticTypes : Array[String] = ["title", "formation_skin"]

static func IsRenderedCosmetic(cosmeticID : String) -> bool:
	var entry : Variant = EconomyCatalog.COSMETIC_CATALOG.get(cosmeticID, {})
	if not (entry is Dictionary):
		return false
	return RenderedCosmeticTypes.has(str((entry as Dictionary).get("type", "")))
