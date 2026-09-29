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
# 2026-09-28 (corte da auditoria "data-driven que não move número"): o parágrafo
# acima vale para a FATIA de moving. Desde então há exatamente duas mudanças de
# comportamento, ambas intencionais e documentadas onde rodam. (1) A igualdade do
# knob contra o const — "catálogo base é representação, não rebalance" — virou
# FAIXA DECLARADA em `_knob_ranges`. (2) Afrouxar a igualdade abriu uma classe de
# defeito que a jaula escondia: dois knobs podem cada um estar dentro da própria
# banda e ainda assim inverter a ordem de valor (VIP com cap diário MENOR que o
# cap de quem não paga), então entrou a régua de pares `KnobOrderings`.
# Nenhuma outra comparação do catálogo pago nem do espelho da loja mudou: o que
# saiu da jaula foram os cinco knobs.
#
# Por que ESTE corte, e não uma fatia arbitrária: `EconomyCatalog.gd` voltou a
# estourar o teto porque a rodada do juiz economia acrescentou aqui o catálogo
# base — o DEFAULT documentado de cada botão (`BASE_KNOBS_REF`) e o espelho da
# loja (`ShopCatalogRef`), os knobs que substituíram os `const` dos botões e o
# validador fail-closed. Validar um
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
# nenhum leitor conhece são erros de boot. O que MUDOU aqui, e é o ponto deste
# corte, é a terceira regra. Ela era IGUALDADE contra o const: a antiga linha 243
# deste arquivo, `if int(value) != int(BASE_KNOBS_REF[name])`, com a própria frase
# "catálogo base é representação, não rebalance". Essa jaula deixava o JSON uma
# cópia dos consts — nenhum número do arquivo movia nada, e rebalance seguia
# sendo editar código e shippar build (a lacuna que a auditoria apontou: "data-
# driven que não consegue mover um número"). Agora cada knob traz sua FAIXA
# aceita em `_knob_ranges` e o validador cobra a faixa, não a igualdade: dentro
# dela um valor diferente do default É aceito (o rebalance que faltava); fora
# dela, ou sem banda declarada, é erro de boot. O teto virou dado — afrouxar a
# própria banda também não exige mais tocar o código. Não derruba o servidor:
# com erro nada do arquivo entra e o default do código (agora apenas fallback
# documentado) continua valendo, com o desvio no log — a disciplina do catálogo
# pago, menos a igualdade que engessava o número.
const BaseCatalogPath : String = "res://data/conf/economy_base_catalog.json"

# `_knob_ranges` entrou junto da FAIXA DECLARADA dos knobs (substituiu a jaula
# de igualdade — ver o comentário de `_ParseKnobBands`). Ela é raiz legítima:
# sem entrar em `BaseRootKeys` o próprio validador a chamaria de chave
# desconhecida e derrubaria o boot, exatamente o fail-closed que queremos evitar
# contra um arquivo que declara a banda de propósito.
const BaseRootKeys : Array = ["_note", "_source", "_knob_ranges", "knobs", "shop"]

const BaseShopKeys : Array = ["sku", "label", "price"]

# As duas chaves de uma banda de knob. É a MESMA forma `min`/`max` que o resto do
# repo usa para faixa — `LiveOpsCalendar` declara `MinBonusValue`/`MaxBonusValue`
# e `FarmZoneData` amarra respawn/drop em banda [min,max] — com a diferença de
# que aqui o par de números mora no arquivo, não no código: é isso que libera o
# rebalance sem rebuild.
const BaseRangeKeys : Array = ["min", "max"]

# (de EconomyService.gd, antes da divisao) — FATIA EM DADOS (JUIZ ECONOMIA
# 2026-09-27, nota 9.4 com o teto declarado: "os botões base são constants de
# código enquanto o catálogo pago já é dados"). O número que paga passa a ser
# lido de `data/conf/economy_base_catalog.json` (ver `BaseCatalogPath`, mais
# acima), validado fail-closed pelo MESMO regime de `ValidatePaidCatalog`.
# Estas linhas DEIXARAM de ser a autoridade. São o DEFAULT DOCUMENTADO: o número
# que fica de pé quando o arquivo não entra (ausente ou inválido), e o centro da
# banda que o arquivo declara em `_knob_ranges`. O que confere o arquivo agora é
# a faixa, não a igualdade contra este const — ver `_ParseKnobBands` e o laço de
# knobs em `ValidateBaseCatalog`. Os valores abaixo permanecem, um a um, os
# mesmos de antes do corte; o que se move é o arquivo, dentro da banda.
const ChestCostGemsRef : int = 120

const MaxChestsPerPurchaseRef : int = 10

# Fricção de troca direta. O assento em runtime são os três `static var` de
# `EconomyService.gd:177/178/181`.
# Continuam sintonizáveis em runtime pelo EconomyService; o assento lê o valor
# do catálogo validado (`ApplyVelocityKnobs`), e o default abaixo é só o
# fallback de quando o arquivo não entra.
const TradeCooldownSecRef : int = 60

const TradeDailyCapRef : int = 20

const TradeDailyCapVIPRef : int = 40

# Os cinco números que o catálogo base parametriza, num dicionário — é o DEFAULT
# (fallback) de cada knob. A FAIXA aceita mora no arquivo (`_knob_ranges`), e é
# contra ela que `ValidateBaseCatalog` confere; este dict serve para (a) saber
# quais nomes têm leitor e (b) dar o valor de reserva quando o arquivo falha.
const BASE_KNOBS_REF : Dictionary = {
	"chest_cost_gems": ChestCostGemsRef,
	"max_chests_per_purchase": MaxChestsPerPurchaseRef,
	"trade_cooldown_sec": TradeCooldownSecRef,
	"trade_daily_cap": TradeDailyCapRef,
	"trade_daily_cap_vip": TradeDailyCapVIPRef,
}

# Ordem ENTRE knobs, e esta regra entrou porque a faixa declarada abriu a porta:
# enquanto o arquivo era obrigado a bater igual ao const, `trade_daily_cap_vip` (40)
# ser maior que `trade_daily_cap` (20) era automático — ninguém conseguia escrever o
# contrário. Com banda, o operador sobe o teto do gratuito para 100 dentro da faixa
# e esquece o do VIP em 40: o pagante passa a ter MENOS troca por dia que o grátis,
# que é o produto ao avesso e nenhum validador de faixa isolada enxerga. Cada entrada
# é `{o que tem de ser >= : o piso}`. A régua lê o VALOR EFETIVO do arquivo, não a
# banda — banda larga não prova ordem nenhuma, só torna a desordem possível.
const KnobOrderings : Dictionary = {
	"trade_daily_cap_vip": "trade_daily_cap",
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
	# OPS-2 (S2 agendada em `data/conf/seasons.json`): o `premium_sku` da temporada
	# tem que ser cobrável no dia em que ela abre, senão a estreia é recusada no
	# boot pela mesma régua que pegou o M3. Mesmo preço e mesmo `kind` do passe
	# padrão — o que muda de uma temporada para outra é a trilha, não a tarifa.
	{"sku": "pass.s2", "label": "Pass S2 Premium: trilha premium da temporada", "price": 24.90},
]

# Número inteiro "de verdade" na leitura JSON: o parser devolve double, então a
# régua é "é número E não tem parte fracionária" (a mesma do laço de knobs). Vale
# para o valor do knob e para o `min`/`max` da banda.
static func _IsWholeNumber(value : Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_equal_approx(float(value), float(int(value)))

# Lê as bandas aceitas de `_knob_ranges`: nome do knob -> {min, max}. É contra
# esta tabela que o laço de knobs confere o arquivo, no lugar da igualdade contra
# `BASE_KNOBS_REF` (a jaula da antiga linha 243). Cada knob que o código conhece
# precisa de uma banda aqui; sem banda o validador não tem como distinguir um
# rebalance autorizado de um dedo no teclado, então recusamos (fail-closed) — no
# laço de knobs, não aqui, para a mensagem sair junto do valor que falhou. Uma
# banda só é aceita se for objeto {min,max} de inteiros, min <= max e min > 0
# (o mesmo piso de faucet gratuito que a igualdade já garantia). Retorna só as
# bandas válidas; os erros vão em `errors`.
static func _ParseKnobBands(doc : Dictionary, errors : PackedStringArray) -> Dictionary:
	var bands : Dictionary = {}
	var rangesVar : Variant = doc.get("_knob_ranges")
	if typeof(rangesVar) != TYPE_DICTIONARY:
		if rangesVar != null:
			errors.append("_knob_ranges: presente mas não é um objeto — nenhuma banda declarada, todo knob fica sem faixa")
		return bands
	var ranges : Dictionary = rangesVar
	for rkey in ranges.keys():
		var rname : String = String(rkey)
		if not BASE_KNOBS_REF.has(rname):
			errors.append("knob_ranges.%s: banda declarada para um knob que nenhum leitor conhece (typo, ou o knob saiu de BASE_KNOBS_REF)" % rname)
			continue
		var bandVar : Variant = ranges[rkey]
		if typeof(bandVar) != TYPE_DICTIONARY:
			errors.append("knob_ranges.%s: a banda tem que ser um objeto {min,max}" % rname)
			continue
		var band : Dictionary = bandVar
		for fk in band.keys():
			if not BaseRangeKeys.has(String(fk)):
				errors.append("knob_ranges.%s: chave desconhecida \"%s\" na banda (só min/max)" % [rname, String(fk)])
		var minVar : Variant = band.get("min")
		var maxVar : Variant = band.get("max")
		if not band.has("min") or not _IsWholeNumber(minVar):
			errors.append("knob_ranges.%s: \"min\" ausente ou não é número inteiro" % rname)
			continue
		if not band.has("max") or not _IsWholeNumber(maxVar):
			errors.append("knob_ranges.%s: \"max\" ausente ou não é número inteiro" % rname)
			continue
		var lo : int = int(minVar)
		var hi : int = int(maxVar)
		if lo > hi:
			errors.append("knob_ranges.%s: min (%d) acima de max (%d) — banda vazia" % [rname, lo, hi])
			continue
		if lo <= 0:
			errors.append("knob_ranges.%s: min (%d) não é positivo (zero fricção é faucet gratuito)" % [rname, lo])
			continue
		bands[rname] = {"min": lo, "max": hi}
	return bands

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
	# As bandas são lidas antes dos knobs: é elas, não o const, que mandam no
	# laço abaixo. Malformação de banda já sai daqui com nome e motivo.
	var bands : Dictionary = _ParseKnobBands(doc, errors)
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
			# Aqui era a igualdade `if int(value) != int(BASE_KNOBS_REF[name])`
			# (linha 243 auditada: "catálogo base é representação, não rebalance"),
			# que tornava o arquivo uma cópia dos consts. Virou FAIXA DECLARADA: o
			# que manda é a banda de `_knob_ranges`. Sem banda declarada não há como
			# saber se o número é rebalance ou erro de digitação — recusamos. Dentro
			# dela, um valor diferente do default é aceito: é exatamente isto que
			# libera o rebalance sem editar código nem shippar build.
			if not bands.has(name):
				errors.append("knobs.%s: sem banda declarada em _knob_ranges — o validador não adivinha o teto de um rebalance" % name)
				continue
			var band : Dictionary = bands[name]
			var lo : int = int(band.get("min", 0))
			var hi : int = int(band.get("max", 0))
			if int(value) < lo or int(value) > hi:
				errors.append("knobs.%s: %d fora da banda declarada [%d, %d] (o default do código é %d) — fora da faixa é rebalance não autorizado" % [name, int(value), lo, hi, int(BASE_KNOBS_REF[name])])
		for refKey in BASE_KNOBS_REF.keys():
			if not knobs.has(String(refKey)):
				errors.append("knobs.%s: sumiu do arquivo (o default do código mandaria sem ninguém declarar)" % String(refKey))
		# Ordem entre knobs, depois da faixa: os dois nomes acima podem estar cada um
		# no lugar certo e o par ainda estar invertido. Só confere quando AMBOS os nomes
		# do par chegaram ao validador como número inteiro — se um deles já caiu em
		# "fora da banda" ou "não é inteiro", o erro daquele knob é a mensagem útil,
		# e empilhar um segundo erro derivado dele é o ruído que faz o operator
		# desligar o gate.
		for upperKey in KnobOrderings.keys():
			var upper : String = String(upperKey)
			var lower : String = String(KnobOrderings[upperKey])
			# A tabela de pares é código, e código apodrece: um nome digitado errado
			# aqui desligaria a régua em silêncio, exatamente o defeito que este gate
			# caça nos outros. Os dois lados têm de ser knobs conhecidos.
			if not BASE_KNOBS_REF.has(upper) or not BASE_KNOBS_REF.has(lower):
				errors.append("KnobOrderings.%s → %s: um dos nomes não é knob do catálogo (par morto: a régua de ordem não tem como rodar)" % [upper, lower])
				continue
			if not knobs.has(upper) or not knobs.has(lower):
				continue
			var upperVar : Variant = knobs[upper]
			var lowerVar : Variant = knobs[lower]
			if not _IsWholeNumber(upperVar) or not _IsWholeNumber(lowerVar):
				continue
			if int(upperVar) < int(lowerVar):
				errors.append("knobs.%s: %d abaixo de knobs.%s = %d — quem paga recebe MENOS troca por dia que quem não paga (%s é o piso declarado)" % [upper, int(upperVar), lower, int(lowerVar), lower])
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
