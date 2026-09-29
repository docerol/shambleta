extends RefCounted
class_name CraftCatalog

# Fatia de tuning do forjeiro (itens criados por jogador), extraída de
# `EconomyCatalog.gd` em 2026-09-27. O critério do corte não é tamanho: é que
# estas constantes e estes puros respondem todos pela MESMA regra de jogo —
# orçamento de budget por (tier, slot), bandas de raridade, taxa de submissão e
# a comparação de nome que fecha a duplicata por golpe de teclado. Ninguém
# precisa saber o cap de baú de guilda para mexer aqui, e nada aqui lê o resto
# do catálogo: a dependência é de um lado só (ItemForgeService → CraftCatalog).
#
# O teto de 800 linhas do gate anti-god-node é o sintoma, não a doença:
# `EconomyCatalog.gd` tinha 812 e era um arquivo onde um ajuste de peso de DoT
# brigava por contexto com janela de reembolso, cap de anúncio e custo de
# vault. A regra de fatiamento deste diretório é por dono de decisão.

# Orçamento de budget por (tier, slot) — 0 = slot não liberado naquele tier.
const BUDGET_CAP : Dictionary = {
	1: [20, 20, 15, 15, 5, 0, 20, 20],
	2: [30, 0, 0, 0, 0, 0, 0, 0],
	3: [0, 0, 0, 0, 0, 0, 66, 0],
	4: [0, 0, 0, 0, 0, 0, 95, 0],
	5: [0, 0, 0, 0, 0, 0, 146, 0],
	6: [0, 0, 0, 0, 0, 0, 0, 0],
	7: [0, 0, 0, 0, 0, 0, 0, 0],
	8: [0, 0, 0, 0, 0, 0, 0, 0],
}

const SLOT_NAMES : Array[String] = ["CHEST", "LEGS", "FEET", "HANDS", "HEAD", "NECK", "WEAPON", "SHIELD"]

# P1-4 (AUDITORIA_2026-09-27): a tabela parava em 22 (índice de `Invisible`) e
# os modifiers 23..38 — elementais, resistências, DoTs, Penetration e
# DeadlyChance — caíam em peso 0 no budget de forja (ItemForgeService.gd:261,
# `else 0.0`): era item lendário de graça, só trocando o nome do efeito no
# payload. A tabela agora cobre o enum inteiro (CellCommons.Modifier, índice
# 0 = None). Bandas:
#   1.0 — stats que entram no hit direto (dano/defesa plana, crit, ataque) e
#         os seus análogos elementais instantâneos (FireDamage/Ice/Lightning =
#         dano plano como Attack; *Resist = defesa plana como Defense;
#         Penetration espelha a banda de resist; DeadlyChance é dobrar-o-hit,
#         análogo de CritRate/DodgeRate, que já valem 1.0).
#   0.5 — banda própria de DoT (Poison/Bleed/Burn, chance/power/resist): o
#         dano só existe se o proc jogar E o alvo sobreviver aos ticks; o valor
#         esperado por ponto de stat é estritamente menor que o do dano plano,
#         então o preço de budget é metade — coerente com a curva (proc-gated ≈
#         ½ × instantâneo), não um favor: 40 de PoisonPower custam 20 de
#         budget, o teto exato de uma arma tier 1.
const MOD_WEIGHTS : Array[float] = [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0, 1.0]

const RARITY_BANDS : Array = [[40, "Comum"], [65, "Incomum"], [85, "Raro"], [97, "Épico"], [101, "Lendário"]]

const RARITY_WEIGHT : Dictionary = {"Comum": 100, "Incomum": 60, "Raro": 30, "Épico": 12, "Lendário": 5}

const SUBMIT_FEE_BASE : int = 500

# SOM-CRAFT (economia, 2026-09-28): a matéria-prima da faixa existia como OFERTA
# (`FarmZoneData.BandMaterialNames` cai do drop com `MaterialDropSharePPM`) sem
# DEMANDA nenhuma — `craft_authority_test.gd` tinha "zero material no inventário e
# a forja aceita" como asserção verde, que é a forma mais honesta de dizer que o
# segundo eixo não existia: um faucet sem sink é um contador, não uma atividade.
# Aqui nasce a demanda. A unidade é TEMPO DE FAZENDA, derivado das três constantes
# da oferta no mesmo arquivo que a declara: zona 1 faz `3600 / ParBaseSeconds` =
# 150 kills/h, `DefaultDropRatePPM` = 0,7 drop por kill, `MaterialDropSharePPM` =
# 6% disso → ~6,3 unidades/h. Um craft de tier 1 custa 12 unidades ≈ 1,9 h de farm
# da própria faixa. Linear em tier, e não tier² como o ouro, porque a oferta já é
# mais lenta no tier alto: `parKillsPerHour = 3600 / (ParBaseSeconds +
# ParPerZoneSeconds × (zona − 1))` cai ~2× entre a zona 1 e a 22 (tier 8), então
# 96 unidades no tier 8 são ~27 h de farm, não ~4×1,9 h. A régua
# (`tests/craft_authority_test.gd`, suíte C2) recomputa a taxa a partir das três
# constantes e exige que o tier 1 caiba entre 1 e 3 horas de farm: mexer na oferta
# ou na demanda move os dois lados e quem decide é o harness, não esta prosa.
const MATERIAL_UNITS_PER_TIER : int = 12

const MAX_PER_DAY : int = 3

const RESUB_MAX : int = 3

const RESUB_DAYS : int = 7

# Percentual do preço pago por quem comprou o design, creditado ao criador.
const CREATOR_FEE_PCT : int = 1

# SOM-IDLE Fase H: validação + gravação de submissão de item criado.
# ITEM_CRAFTING.md §2: paga taxa de gold sink, valida orçamento, nome e capa
# diária; grava como 'pending'. GM aprova depois (WorldCommands).
#
# Validações (server-autorizado):
# - slot válido (0–7), baseItemHash > 0, name não-vazio
# - budget: soma ponderada de modifiers <= BudgetCap(tier, slot) (0 = bloqueado)
# - matéria-prima: MaterialPerCraft(tier) unidades da matéria-prima da faixa, com
#   débito espelhado no ledger (`craft_material:<hash>`)
# - taxa: player tem gp >= SubmitFee(tier); burnt + ledger mirror
# - nome: não vazio, tamanho 3–30, não na blocklist, não duplicata (edit-distance < 2)
# - daily cap: MAX_PER_DAY submissões hoje
# - email verificado (D3 auth gate)
#
# Retorna {ok: bool, reason: String}.

static func BudgetCap(tier : int, slot : int) -> int:
	if not BUDGET_CAP.has(tier) or slot < 0 or slot > 7:
		return 0
	return int((BUDGET_CAP[tier] as Array)[slot])

static func RarityForUsage(pct : float) -> String:
	for band in RARITY_BANDS:
		if pct < float((band as Array)[0]):
			return str((band as Array)[1])
	return "Lendário"

# Taxa de submissão em gold: 500 × tier² (proposta; confirmar após o beta).
static func SubmitFee(tier : int) -> int:
	return SUBMIT_FEE_BASE * tier * tier

# Preço em matéria-prima da faixa do tier (ver MATERIAL_UNITS_PER_TIER: a unidade
# é hora de fazenda, não unidade solta). tier < 1 não tem faixa declarada e custa 0
# por acidente de entrada — quem chama valida o tier antes (`invalid_tier`).
static func MaterialPerCraft(tier : int) -> int:
	return MATERIAL_UNITS_PER_TIER * maxi(tier, 0)

# Normaliza nome p/ checagens (pré-filtro + duplicata).
static func NormName(name : String) -> String:
	return name.strip_edges().to_lower()

# Distância de edição simples (golpe tipo Gladiu5 vs Gladius). O(n*m), nomes
# curtos — sem problema de performance no volume de submissões.
static func EditDistance(a : String, b : String) -> int:
	var prev : Array = []
	for j in b.length() + 1:
		prev.append(j)
	for i in range(1, a.length() + 1):
		var cur : Array = [i]
		for j in range(1, b.length() + 1):
			cur.append(mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (0 if a[i - 1] == b[j - 1] else 1)))
		prev = cur
	return int(prev[b.length()])

# P1-4 (AUDITORIA_2026-09-27): validação fail-closed da tabela de pesos contra o
# enum CellCommons.Modifier. Peso 0/ausente em qualquer índice 1..Count-1 é
# modifier gratuito no budget (o bug histórico: a tabela parava em 22 e
# elementais/DoT/pen/trailing entravam de graça — ItemForgeService caía em
# `else 0.0`). Roda no boot (ItemForgeService._init) e o forja recusa QUALQUER
# submissão enquanto houver erro — catálogo quebrado não imprime item lendário.
# `table` parametrizável para teste da própria validação; a chamada de boot usa
# a tabela real.
static func ValidateModWeights(weights : Array[float] = MOD_WEIGHTS) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var count : int = CellCommons.Modifier.Count
	if weights.size() != count:
		errors.append("MOD_WEIGHTS: %d entradas para um enum Modifier de %d (Count)" % [weights.size(), count])
	for i in range(1, mini(weights.size(), count)):
		if weights[i] <= 0.0:
			errors.append("MOD_WEIGHTS: índice %d com peso %f — modifier gratuito no budget de forja" % [i, weights[i]])
	return errors
