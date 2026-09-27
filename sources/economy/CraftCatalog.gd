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
