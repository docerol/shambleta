extends NpcScript

# Quest ID
const questID : int = ProgressCommons.Quest.SNAKE_PIT_THIEF

# Reward items
var scimitarID : int = DB.GetCellHash("Scimitar")

# Required items
var thiefsKeyID : int = DB.GetCellHash("Thief's Key")

#
func OnStart():
	match GetQuest(questID):
		ProgressCommons.SNAKE_PIT_THIEF.RIDDLE_SOLVED: OnTryOpen()
		ProgressCommons.SNAKE_PIT_THIEF.REWARDS_WITHDREW: OnEmpty()
		_: OnLocked()

func OnTryOpen():
	if not HasItem(thiefsKeyID):
		OnLocked()
		return

	if not IsTriggering():
		Trigger()

	SetQuest(questID, ProgressCommons.SNAKE_PIT_THIEF.REWARDS_WITHDREW)

	RemoveItem(thiefsKeyID, 1)
	# Os 200 GP e os 50 EXP saíram daqui (crus, sem ledger) para `rewardGP` e
	# `rewardEXP` em `presets/quests/SnakePitThief.tres`, pagos pelo `SetQuest`
	# acima. O scimitar e o karma ficam neste script: o dado da quest declara
	# dinheiro e experiência, não item nem karma.
	AddItem(scimitarID, 1)
	AddKarma(2)

func OnEmpty():
	Chat("This chest is empty.")

func OnLocked():
	Chat("This chest is locked. You need a key.")
