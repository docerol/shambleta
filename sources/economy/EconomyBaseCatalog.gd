extends RefCounted
class_name EconomyBaseCatalog

# FATIA 13 (gate anti-god-node, 2026-09-27): validação e acesso tipado dos DOIS
# catálogos de dados puros — o pago (`data/conf/paid_catalog.json`) e o base
# (`data/conf/economy_base_catalog.json`) — saíram de `EconomyCatalog.gd` (924
# linhas, acima do teto de 800) para cá. Zero mudança de comportamento: cada
# mensagem de erro, cada comparação e cada constante abaixo são as mesmas de
# antes do corte, palavra por palavra; o que mudou foi a representação, no
# mesmo regime do precedente da manhã (`GuildPanel.gd` 856 → 637 em seis
# módulos coesos).
#
# Por que ESTE corte, e não uma fatia arbitrária: `EconomyCatalog.gd` voltou a
# estourar o teto porque a rodada do juiz economia acrescentou aqui o catálogo
# base — a referência congelada (`BASE_KNOBS_REF`/`ShopCatalogRef`), os knobs que
# substituíram os `const` dos botões e o validador fail-closed. Validar um
# catálogo e amarrá-lo à referência do código é uma decisão só, e ela mora bem
# fora da tabela de números que os consumidores leem. `EconomyCatalog` fica com
# os números e o estado em runtime (`SHOP_CATALOG`, `ChestCostGems`, `BaseKnobs`)
# porque `Storefront`, `ShopService`, `CheckoutService`, `SeasonConfig` e
# `Server.gd` leem esses nomes; os wrappers de `ValidatePaidCatalog`,
# `ValidateBaseCatalog`, `LoadBaseCatalog`, `ApplyBaseCatalog` e `ResetBaseCatalog`
# continuam respondendo pelo caminho antigo.
#
# Sem back-reference: este arquivo é puro (recebe texto e tabelas, devolve lista
# de erros) e não conhece `EconomyCatalog`, então não existe ciclo de dependência
# entre os dois — o que existe é `EconomyCatalog` → cá. Nada aqui toca disco,
# banco ou rede, exceto `ValidatePaidCatalogFile`, que é a única leitura declarada.

# ------------------------------------------------------------------ catálogo pago (fonte única)
#
# ROADMAP Bloco 1 item 10: `data/conf/paid_catalog.json` é o catálogo cobrável e
# está nos dois lados da fronteira — o companion cobra dele, o jogo anuncia o
# `SHOP_CATALOG` de `EconomyCatalog` e aplica o grant por `kind`. Três cópias sem
# validação cruzada é o bug: um `kind` que `_GrantApplyAndMark` não conhece
# derruba o grant para `false`, a linha fica `pending` na fila e o jogador pagou
# sem receber — a mesma classe do D1, só que pela borda do catálogo. `data/conf/*`
# é exportado pelos presets (Windows/Android/Linux/macOS), então o servidor em
# produção também enxerga o arquivo; `companion/` não é.
const PaidCatalogPath : String			= "res://data/conf/paid_catalog.json"

const GRANT_KINDS : Array = ["gems", "gold", "vip_days", "pass_premium", "cosmetic", "item"]

# Divergências entre catálogo cobrável, anúncio e aplicador (vazio = batendo).
# Puro — recebe o texto, não toca disco, banco nem rede — para servir ao boot do
# servidor e à suíte com o mesmo código. `cosmetics` e `advertised` são as duas
# tabelas que vivem em `EconomyCatalog`: quem chama passa, este arquivo não lê.
static func ValidatePaidCatalog(raw : String, cosmetics : Dictionary, advertised : Array) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("catálogo pago ausente ou não é um objeto JSON")
		return errors
	var paid : Dictionary = parsed
	# §24-11 (Lei 15.211/2025): `_agreements` é a declaração do aceite que a OUTRA
	# porta do dinheiro cobra — o companion recusa intent/preferência/sandbox
	# quando o aceite gravado na conta não bate com ela. Validar contra os consts
	# aqui fecha o ciclo "uma fonte, dois leitores" no mesmo regime do preço:
	# bumpar `NetworkCommons.Agreement*` sem bumpar o arquivo (ou vice-versa) vira
	# erro de boot, e não duas portas doendo com versões diferentes do contrato.
	var agreements : Variant = paid.get("_agreements")
	if typeof(agreements) != TYPE_DICTIONARY:
		errors.append("_agreements: ausente ou não é um objeto — o companion fica sem versão vigente para cobrar e recusa todo checkout")
	else:
		var declared : Dictionary = agreements
		_ValidateAgreementClause(declared, "tos", NetworkCommons.AgreementTosVersion, errors)
		_ValidateAgreementClause(declared, "privacy", NetworkCommons.AgreementPrivacyVersion, errors)
		_ValidateAgreementClause(declared, "age", NetworkCommons.AgreementAgeVersion, errors)
	var advertisedPrices : Dictionary = {}
	for entry in advertised:
		advertisedPrices[str(entry.get("sku", ""))] = float(entry.get("price", 0.0))
	for key in paid.keys():
		var sku : String = String(key)
		# Chaves de comentário (`_note`) não são SKU.
		if sku.begins_with("_"):
			continue
		var item : Variant = paid[key]
		if typeof(item) != TYPE_DICTIONARY:
			errors.append("%s: linha do catálogo não é um objeto" % sku)
			continue
		_ValidateSkuLine(sku, item, errors, cosmetics, true)
		if not advertisedPrices.has(sku):
			errors.append("%s: cobrável no gateway e não anunciado no SHOP_CATALOG" % sku)
		elif absf(float((item as Dictionary).get("price", -1.0)) - float(advertisedPrices[sku])) > 0.005:
			errors.append("%s: preço cobrado != preço anunciado" % sku)
	for missing in advertisedPrices.keys():
		if not paid.has(String(missing)):
			errors.append("%s: anunciado e o gateway não cobra (intent vira unknown_sku)" % String(missing))
	return errors

# Uma cláusula do aceite (tos/privacy/idade). O comparison é de igualdade e não
# de ordem: o predicate do jogo (`SQL.IsConsentAccepted`) também é, então
# "2027" no arquivo não "autoriza" nada — só faz as duas portas discordarem.
static func _ValidateAgreementClause(declared : Dictionary, clause : String, current : String, errors : PackedStringArray) -> void:
	var value : String = str(declared.get(clause, ""))
	if value != current:
		errors.append("_agreements.%s: catálogo declara \"%s\", o jogo cobra \"%s\"" % [clause, value, current])

static func ValidatePaidCatalogFile(cosmetics : Dictionary, advertised : Array) -> PackedStringArray:
	if not FileAccess.file_exists(PaidCatalogPath):
		return PackedStringArray(["%s não existe — o servidor não tem como validar o catálogo pago" % PaidCatalogPath])
	return ValidatePaidCatalog(FileAccess.get_file_as_string(PaidCatalogPath), cosmetics, advertised)

# Uma linha de catálogo, ou uma perna de bundle. O bundle não chega ao jogo (o
# companion decompõe em N grants atômicos), mas cada perna tem que ser
# aplicável: senão a compra entrega metade.
static func _ValidateSkuLine(sku : String, line : Dictionary, errors : PackedStringArray, cosmetics : Dictionary, topLevel : bool, legIndex : int = 0) -> void:
	# Uma perna de bundle precisa se distinguir da linha-mãe na mensagem: o
	# operador lê o log do boot e tem de saber qual perna não entrega.
	var label : String = sku if topLevel else "%s perna %d" % [sku, legIndex]
	var kind : String = str(line.get("kind", ""))
	if kind == "bundle":
		if not topLevel:
			errors.append("%s: bundle dentro de bundle" % label)
			return
		var contents : Variant = line.get("contents", null)
		if typeof(contents) != TYPE_ARRAY or (contents as Array).is_empty():
			errors.append("%s: bundle sem contents" % sku)
			return
		var legN : int = 0
		for leg in (contents as Array):
			legN += 1
			if typeof(leg) != TYPE_DICTIONARY:
				errors.append("%s: perna %d de bundle não é um objeto" % [sku, legN])
				continue
			_ValidateSkuLine(sku, leg, errors, cosmetics, false, legN)
		return
	if not GRANT_KINDS.has(kind):
		errors.append("%s: kind \"%s\" não é aplicável por _GrantApplyAndMark" % [label, kind])
		return
	var amount : Variant = line.get("amount", 0)
	if not (amount is int or amount is float) or int(amount) <= 0:
		errors.append("%s: amount ausente ou não-positivo" % label)
	if kind == "cosmetic" and not cosmetics.has(str(line.get("cosmetic_id", ""))):
		errors.append("%s: cosmetic_id fora do COSMETIC_CATALOG" % label)

# ------------------------------------------------------------------ catálogo base (fonte única)
#
# JUIZ ECONOMIA 2026-09-27 (nota 9.4, teto declarado na própria ficha): "os
# botões base são constants de código enquanto o catálogo pago já é dados E
# validado". `data/conf/economy_base_catalog.json` é o preço do baú, o teto de
# compra por vez e a fricção da troca direta; o regime é o MESMO de
# `ValidatePaidCatalog` — chave desconhecida, preço não-positivo e SKU que
# nenhum leitor conhece são erros de boot, e um arquivo com um número trocado
# em relação à referência congelada do código também é. A terceira regra é o
# ponto do corte: sem ela, "passar para dados" abre uma porta de rebalance
# silencioso (alguém edita o JSON no servidor e o baú passa de 120 para 60 gems
# sem um commit, sem review e sem harness). Não derruba o servidor: com erro,
# nada do arquivo entra e os números do código continuam valendo, com o desvio
# no log — exatamente a disciplina do catálogo pago acima.
const BaseCatalogPath : String = "res://data/conf/economy_base_catalog.json"

const BaseRootKeys : Array = ["_note", "_source", "knobs", "shop"]

const BaseShopKeys : Array = ["sku", "label", "price"]

# (de EconomyService.gd:739/740/782) — FATIA EM DADOS (JUIZ ECONOMIA
# 2026-09-27, nota 9.4 com o teto declarado: "os botões base são constants de
# código enquanto o catálogo pago já é dados"). O número que paga passa a ser
# lido de `data/conf/economy_base_catalog.json` (ver `BaseCatalogPath`, mais
# acima), validado fail-closed pelo MESMO regime de `ValidatePaidCatalog`.
# Estas linhas são a REFERÊNCIA CONGELADA que o validador amarra ao
# arquivo: mudar o preço exige mudar os dois lados no mesmo commit, e um
# arquivo editado à mão com um número trocado é erro de boot — nunca um
# rebalance silencioso. É mudança de representação, não de equilíbrio: os
# valores abaixo são, um a um, os mesmos de antes do corte.
const ChestCostGemsRef : int = 120

const MaxChestsPerPurchaseRef : int = 10

# Fricção de troca direta (eram `static var` em EconomyService.gd:208/209/212).
# Continuam sintonizáveis em runtime pelo EconomyService; o default passa a
# vir do catálogo validado, e o pin abaixo é o que garante que o número é o
# mesmo de antes do corte.
const TradeCooldownSecRef : int = 60

const TradeDailyCapRef : int = 20

const TradeDailyCapVIPRef : int = 40

# Os cinco números que o catálogo base substitui, num dicionário — é contra esta
# tabela que `ValidateBaseCatalog` confere o arquivo, linha por linha.
const BASE_KNOBS_REF : Dictionary = {
	"chest_cost_gems": ChestCostGemsRef,
	"max_chests_per_purchase": MaxChestsPerPurchaseRef,
	"trade_cooldown_sec": TradeCooldownSecRef,
	"trade_daily_cap": TradeDailyCapRef,
	"trade_daily_cap_vip": TradeDailyCapVIPRef,
}

const ShopCatalogRef : Array = [
	{"sku": "gems.550", "label": "550 gems", "price": 19.90},
	{"sku": "gems.1200", "label": "1200 gems", "price": 39.90},
	{"sku": "gems.3000", "label": "3000 gems", "price": 79.90},
	{"sku": "vip.1mo", "label": "VIP 30 days", "price": 24.90},
	{"sku": "vip.3mo", "label": "VIP 90 days", "price": 59.90},
	{"sku": "starter.pack", "label": "Starter: VIP 7d + 220 gems (D0–D3, one-time)", "price": 9.90},
	{"sku": "founder.pack", "label": "Founder: 1200 gems + VIP 30d + title", "price": 39.90},
	{"sku": "donate.support", "label": "Support: Apoiador title", "price": 4.90},
	# SOM-IDLE M3: faltava este — o botão do passe (Server.gd, tier "standard")
	# pede a intent com "pass.s1", que é cobrável no companion, e recebia
	# unknown_sku. O deluxe estava listado e o padrão (R$ 24,90, o SKU principal
	# da temporada) não. SuiteCatalogConsistency amarra as duas listas.
	{"sku": "pass.s1", "label": "Pass S1 Premium: trilha premium da temporada", "price": 24.90},
	{"sku": "pass.s1.deluxe", "label": "Pass S1 Deluxe: premium + 10 levels + gems", "price": 44.90},
]

static func ValidateBaseCatalog(raw : String) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("catálogo base ausente ou não é um objeto JSON")
		return errors
	var doc : Dictionary = parsed
	for rootKey in doc.keys():
		if not BaseRootKeys.has(String(rootKey)):
			errors.append("raiz: chave desconhecida \"%s\" — nenhum leitor no código, logo nenhum número aplicado" % String(rootKey))
	var knobsVar : Variant = doc.get("knobs")
	if typeof(knobsVar) != TYPE_DICTIONARY:
		errors.append("knobs: ausente ou não é um objeto")
	else:
		var knobs : Dictionary = knobsVar
		for knobKey in knobs.keys():
			var name : String = String(knobKey)
			if not BASE_KNOBS_REF.has(name):
				errors.append("knobs.%s: chave desconhecida (nenhum leitor no código)" % name)
				continue
			var value : Variant = knobs[knobKey]
			# `is int` NUNCA casa com o que o parser JSON devolve: número em JSON é
			# double, e um knob legítima como `60` chega como float. A régua certa é
			# "número, e sem parte fracionária" — que é exatamente o que ainda recusa
			# o 19.90 (preço de loja escrito no bloco de knobs) e aceita o 60.
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				errors.append("knobs.%s: tem que ser número inteiro, não %s" % [name, type_string(typeof(value))])
				continue
			if not is_equal_approx(float(value), float(int(value))):
				errors.append("knobs.%s: tem que ser inteiro (JSON lê 19.90 como float)" % name)
				continue
			if int(value) <= 0:
				errors.append("knobs.%s: %d não é positivo (zero fricção é faucet gratuito)" % [name, int(value)])
				continue
			if int(value) != int(BASE_KNOBS_REF[name]):
				errors.append("knobs.%s: o arquivo declara %d e o código %d — catálogo base é representação, não rebalance" % [name, int(value), int(BASE_KNOBS_REF[name])])
		for refKey in BASE_KNOBS_REF.keys():
			if not knobs.has(String(refKey)):
				errors.append("knobs.%s: sumiu do arquivo (o default do código mandaria sem ninguém declarar)" % String(refKey))
	var shopVar : Variant = doc.get("shop")
	if typeof(shopVar) != TYPE_ARRAY:
		errors.append("shop: ausente ou não é uma lista")
		return errors
	var shop : Array = shopVar
	var refPrices : Dictionary = {}
	for ref in ShopCatalogRef:
		var refLine : Dictionary = ref
		refPrices[str(refLine.get("sku", ""))] = float(refLine.get("price", 0.0))
	if shop.size() != ShopCatalogRef.size():
		errors.append("shop: %d linhas no arquivo, %d anunciadas no código" % [shop.size(), ShopCatalogRef.size()])
	var seen : Dictionary = {}
	for idx in shop.size():
		var lineVar : Variant = shop[idx]
		if typeof(lineVar) != TYPE_DICTIONARY:
			errors.append("shop[%d]: linha não é um objeto" % idx)
			continue
		var line : Dictionary = lineVar
		for fieldKey in line.keys():
			if not BaseShopKeys.has(String(fieldKey)):
				errors.append("shop[%d]: chave desconhecida \"%s\"" % [idx, String(fieldKey)])
		var sku : String = str(line.get("sku", ""))
		if sku.is_empty():
			errors.append("shop[%d]: sem sku" % idx)
			continue
		if seen.has(sku):
			errors.append("shop: sku %s repetida (duas linhas cobráveis, um botão na loja)" % sku)
		seen[sku] = true
		var chargeable : bool = refPrices.has(sku)
		if not chargeable:
			errors.append("shop[%d] %s: SKU fora do catálogo cobrável anunciado (intent viria unknown_sku)" % [idx, sku])
		var price : Variant = line.get("price", -1.0)
		if not (price is int or price is float) or float(price) <= 0.0:
			errors.append("shop[%d] %s: preço ausente ou não-positivo" % [idx, sku])
			continue
		if chargeable and absf(float(price) - float(refPrices[sku])) > 0.005:
			errors.append("shop %s: preço no arquivo %s != preço anunciado %s" % [sku, str(price), str(refPrices[sku])])
		if str(line.get("label", "")).strip_edges().is_empty():
			errors.append("shop[%d] %s: sem label (a loja mostraria a chave crua ao jogador)" % [idx, sku])
	for wantSku in refPrices.keys():
		if not seen.has(String(wantSku)):
			errors.append("shop: sku %s anunciada no código e ausente do arquivo" % String(wantSku))
	return errors
