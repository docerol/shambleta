extends Resource
class_name QuestData

@export var id : int							= DB.UnknownHash
@export var name : String						= ""
@export_multiline var description : String		= ""
@export var giver : String						= ""
@export var giverLocation : String				= ""
@export var target : String						= ""
@export var targetLocation : String				= ""
@export var reward : String						= ""
# A linha acima é VITRINE: nenhum código do servidor a lê, e o texto nunca pôde
# ser fonte de pagamento — "Cactus Potion x10, 100 GP" (presets/quests/NinaHungry.tres)
# não tem como virar número de ledger por kind sem parsear prose e adivinhar o
# separador. Os dois campos abaixo são a recompensa DECLARADA, paga por
# NpcCommons.SetQuest na transição para ProgressCommons.CompletedProgress; o
# `reward` continua sendo o que o jogador lê na janela de quest.
@export var rewardGP : int						= 0
@export var rewardEXP : int						= 0

# Há recompensa declarada? Dos 17 presets atuais, 7 declaram número (os migra-
# dos do pagamento à mão) e 10 não declaram nada: é o caso NORMAL de quest que
# só dá item, karma ou texto. Sem este gate a chamada de pagamento iria até
# MoveGold(0), que o kernel recusa (EconomyKernel.gd:144), e o ledger ficaria
# sem linha nenhuma para diferenciar "esta quest não paga" de "o grant falhou".
# O censo dos 7 é régua em tests/quest_reward_test.gd (suíte 8), não prosa.
func HasDeclaredReward() -> bool:
	return rewardGP > 0 or rewardEXP > 0
