extends RefCounted
class_name SkillProgress

# M-7 (2026-10-07): skill leveling POR USO, com teto declarado. Cada conjuração
# que landed (`Skill.Casted` — o ponto único onde manual e rotação do idle
# se encontram) credita `XpPerCast`; a curva é `NeededForLevel`, e o
# `MaxLevel` é o TETO: quem chega nele para de ganhar XP (o excedente morre na
# porta, não vira inflação de contador).
#
# Porque o teto mora AQUI e não numa CHECK: a subida é decisão de produto
# medida pela suíte `SuiteSkillXp` (`tests/IdleTestsFrontier.gd:@SuiteSkillXp`); o banco só guarda o
# instante (nível + xp residual) pelo snapshot que já existia — nenhum writer
# novo entrou no funil por este item.
#
# O crédito só acontece no servidor (`IsServerSide`): o cliente replica o Cast
# para responsiveness e uma contagem dos dois lados seria double-bubble — é o
# mesmo contrato do XP do personagem, que `Formula.ApplyXp` só corre no dono.

const XpPerCast : int = 2
const MaxLevel : int = 10

# XP necessário para saltar de `level` para `level + 1`. Linear com degrau
# 100: 1→2 custa 200, 9→10 custa 1000; o inteiro da escada é 44 casts×... e é
# MEDIDO, não decorativo (`SuiteSkillXp` confere a soma da escada cheia).
static func NeededForLevel(level : int) -> int:
	return 100 * (level + 1)

# A função pura que DECIDE: dado nível e xp atuais (em memória, do agente) e o
# ganho de um cast, devolve [nível novo, xp novo]. No teto: nada se move, nada
# se acumula.
static func Credit(level : int, xp : int, gain : int) -> Array[int]:
	var outLevel : int = level
	var outXp : int = xp
	if outLevel >= MaxLevel or gain <= 0:
		return [outLevel, outXp]
	outXp += gain
	while outLevel < MaxLevel and outXp >= NeededForLevel(outLevel):
		outXp -= NeededForLevel(outLevel)
		outLevel += 1
	if outLevel >= MaxLevel:
		outXp = 0
	return [outLevel, outXp]

static func NoteCast(agent : BaseAgent, skill : SkillCell) -> void:
	if not IdlePolicyService.IsServerSide() or skill == null:
		return
	if not (agent is PlayerAgent) or not is_instance_valid(agent):
		return
	var prog : ActorProgress = agent.progress
	if prog == null:
		return
	var level : int = prog.GetSkillLevel(skill)
	if level <= 0:
		return
	var next : Array[int] = Credit(level, prog.GetSkillXp(skill), XpPerCast)
	prog.SetSkillXp(skill, next[1])
	if next[0] != level:
		prog.AddSkill(skill, next[0])
