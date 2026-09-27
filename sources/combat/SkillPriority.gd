extends RefCounted
class_name SkillPriority

# SOM-GAMEPLAY G1 (AUDITORIA §"Core Gameplay"): o auto-combat do idle NÃO tinha
# instrumento de decisão — IdlePolicy._getSkill() sempre lia skillLoadout[0], a
# mesma skill do primeiro ao último golpe, independentemente de cooldown, alcance
# ou custo. O jogador não tinha nada para escolher, logo não havia gameplay.
#
# Este arquivo é o MODELO PURO da decisão (sem Engine, sem autoload, sem nós):
# entrada = ints/dicts, saída = um skill ID. É isso que o teste
# tests/gameplay_fix_test.gd consegue afirmar sem subir o mundo. A coleta dos
# fatos (aprendido? em cooldown? cabe no mana? alvo ao alcance?) continua em
# IdlePolicy, que é quem tem o agent na mão.
#
# Por que ordem e não "melhor skill": manter a declaração do jogador como fonte
# da verdade (ele disse "Fireball primeiro, depois Melee") é previsivel e
# auditável; um ranking automático seria balance invisível e brigaria com a
# intenção de quem configurou a carga.

# Sentinela: nada selecionável nesta avaliação de tick.
const NoSkill : int = -1

# Teto de uma carga de prioridade. O tick roda 4x/s por farmer e a seleção é
# O(candidatos); sem teto, /priority set com 40 IDs viraria custo de CPU por
# jogador online. 6 cobre 1 skill por botão da hotbar sem abrir espaço para spam.
const MaxPrioritySkills : int = 6

# ------------------------------------------------------------------ normalização

# Remove duplicatas e IDs não aprendidos, preservando a ordem DECLARADA.
# Skills aprendidas mas não declaradas ficam FORA de propósito: a carga atual do
# formation salva 1 só skill (Formation.gd), e injetar "tudo que o char sabe"
# mudaria o rate-limit de dano de todo farmer sem o jogador pedir.
static func Normalize(order : Array[int], owned : Array[int]) -> Array[int]:
	var clean : Array[int] = []
	for skillID : int in order:
		if skillID in owned and not (skillID in clean):
			clean.append(skillID)
	return clean

# Ordem efetiva de cast. Fallback explícito para o comportamento antigo:
#  - carga declarada mas nenhuma aprendida  -> usa o 1º declarado (como hoje);
#  - carga vazia                            -> melee (como hoje).
# Nunca retorna lista vazia: o chamador sempre tem um skill ID para tentar.
static func ResolveOrder(order : Array[int], owned : Array[int], fallbackID : int) -> Array[int]:
	var clean : Array[int] = Normalize(order, owned)
	if clean.is_empty() and not order.is_empty():
		clean.append(order[0])
	if clean.is_empty():
		clean.append(fallbackID)
	return clean

# Recorta/rejeita uma carga declarada pelo jogador (entrada de /priority).
# Retorna {"order": Array[int], "rejected": Array[int]} — rejeitados = desconhecidos,
# não aprendidos ou além do teto. O motivo exato é decidido pelo chamador (que tem
# o DB e o agent); aqui é só a política de tamanho/ordem/duplicata.
static func Trim(candidateOrder : Array[int], owned : Array[int]) -> Dictionary:
	var accepted : Array[int] = []
	var rejected : Array[int] = []
	for skillID : int in candidateOrder:
		if not (skillID in owned) or (skillID in accepted) or accepted.size() >= MaxPrioritySkills:
			rejected.append(skillID)
			continue
		accepted.append(skillID)
	return {"order" = accepted, "rejected" = rejected}

# ------------------------------------------------------------------ seleção

# blocked[id]   -> true quando a skill NÃO pode ser conjurada agora (cooldown,
#                  custo de mana/vida, trava de classe).
# reachable[id] -> true quando o alvo está dentro do alcance da skill agora.
# Regra: 1º livre E ao alcance (cast este tick); senão 1º livre (andar até o
# alcance dele); senão NoSkill (nada a fazer — o chamador mantém a skill
# primária e o ciclo de espera de hoje).
static func Select(candidates : Array[int], blocked : Dictionary, reachable : Dictionary) -> int:
	for skillID : int in candidates:
		if not bool(blocked.get(skillID, false)) and bool(reachable.get(skillID, false)):
			return skillID
	for skillID : int in candidates:
		if not bool(blocked.get(skillID, false)):
			return skillID
	return NoSkill

# ------------------------------------------------------------------ apresentação

# "1. Fireball  2. Melee" — nomes vêm de fora (Dictionary id->name), então a
# função continua pura e testável sem SkillsDB.
static func FormatOrder(order : Array[int], names : Dictionary) -> String:
	if order.is_empty():
		return "(none)"
	var parts : PackedStringArray = PackedStringArray()
	for position : int in order.size():
		var skillID : int = order[position]
		parts.append("%d. %s" % [position + 1, str(names.get(skillID, "skill %d" % skillID))])
	return "  ->  ".join(parts)
