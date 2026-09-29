extends AIAgent
class_name MonsterAgent

# SOM-IDLE: boss-key ladder — quando >=0 este mob é o boss da escada (índice) e
# sua morte entrega a recompensa do desafio (via Formula.ApplyXp) em vez do xp de
# farm comum. É runtime-only (não persiste), resetado ao morrer.
var idleBossIndex : int = -1

#
static func GetActorType() -> ActorCommons.Type: return ActorCommons.Type.MONSTER

func Killed():
	super.Killed()
	Formula.ApplyXp(self)
	_RollDrops()

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(self)
	if inst and inst.timers:
		Callback.SelfDestructTimer(inst.timers, ActorCommons.DeathDelay, WorldAgent.RemoveAgent, [self])

# `EntityData._drops` é mesa de PROBABILIDADE por unidade — Salt Slime → Apple
# 0.7 (70% de uma maçã por kill), Sand Snake → pele 0.05, chave de boss 1.0
# (sempre). O roll acontece NA MORTE, um `randf()` por célula por kill — como o
# drop de chave ao vivo (`Formula.gd:226`). No desenho antigo a mesa era rolada no
# `AIAgent.SetData` e o resultado ficava guardado no inventário do mob, varrido
# para o chão aqui; medido hoje A/B contra `HEAD` no mesmo harness, os dois
# caminhos dão a mesma taxa (8 drops em 12 kills lá, 7 aqui, esperado 8.4), então
# isto NÃO conserta um mob que não derrubava nada — move o roll para o evento que
# a mesa descreve. A diferença é o resto: no caminho do spawn a quantidade
# derrubada era `item.count` (estado da pilha do mob) em vez da mesa, e o mob
# vivo passava a sessão segurando loot que ninguém ganhou. A régua (3) de
# `SuiteIdleLootPipeline` trava isso; DROP_DELAY/NO_DROP do mapa são carga do
# `WorldDrop.PushDrop`.
func _RollDrops():
	for cell : ItemCell in data._drops:
		if cell == null:
			continue
		var chance : float = float(data._drops[cell])
		if chance > 0.0 and randf() < chance:
			WorldDrop.PushDrop(Item.new(cell, 1), self)

func _ready():
	inventory = ActorInventory.new(self)
	super._ready()
	AddSkill(DB.SkillsDB[DB.GetCellHash(SkillCommons.SkillMeleeName)], 1.0)
