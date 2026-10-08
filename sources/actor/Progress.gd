extends RefCounted
class_name ActorProgress

#
var bestiary : Dictionary[int, int]			= {}
var quests : Dictionary[int, int]			= {}
var skills : Dictionary[int, int]			= {}
# M-7 (2026-10-07): o XP dentro do nível atual de cada skill. Vive ao lado de
# `skills` e desce para o banco pelo MESMO `UpdateProgress` (coluna `xp` da
# migração 074) — nenhum dono novo entrou no funil.
var skillXp : Dictionary[int, int]			= {}

var actor : Actor							= null

var questMutex : Mutex						= null
var bestiaryMutex : Mutex					= null

# Quest progress
func SetQuest(questID : int, state : int):
	questMutex.lock()
	quests[questID] = state
	questMutex.unlock()

	if actor is PlayerAgent and actor.peerID != NetworkCommons.PeerUnknownID:
		var charID : int = Peers.GetCharacter(actor.peerID)
		if charID != NetworkCommons.PeerUnknownID:
			Launcher.SQL.SetQuest(charID, questID, state)
		Network.UpdateQuest(questID, state, actor.peerID)

func GetQuest(questID : int) -> int:
	var state : int = ProgressCommons.UnknownProgress
	if questID in quests:
		questMutex.lock()
		state = quests[questID]
		questMutex.unlock()
	return state

# Bestiary progress
func AddBestiary(entityID : int, killedCount : int = 1):
	var totalCount : int = killedCount
	bestiaryMutex.lock()
	if entityID in bestiary:
		totalCount += bestiary[entityID]
	bestiary[entityID] = totalCount
	bestiaryMutex.unlock()

	if actor is PlayerAgent and actor.peerID != NetworkCommons.PeerUnknownID:
		Network.UpdateBestiary(entityID, totalCount, actor.peerID)

func GetBestiary(monsterID : int) -> int:
	var count : int = 0
	if monsterID in bestiary:
		bestiaryMutex.lock()
		count = bestiary[monsterID]
		bestiaryMutex.unlock()
	return count

#
func HasSkill(cell : SkillCell, level : int = 1) -> bool:
	if cell == null:
		push_error("Provided skill cell is null")
		return false
	return skills.get(cell.id, 0) >= level

func AddSkill(cell : SkillCell, level : int):
	if cell == null:
		push_error("Provided skill cell is null")
		return

	if skills.get(cell.id, 0) == level:
		return

	if skills.get(cell.id, 0) == level:
		return

	skills[cell.id] = level

	if actor is PlayerAgent and actor.peerID != NetworkCommons.PeerUnknownID:
		Network.UpdateSkill(cell.id, level, actor.peerID)

func GetSkillLevel(cell : SkillCell) -> int:
	return skills.get(cell.id, 0) if cell else 0

func GetSkillXp(cell : SkillCell) -> int:
	return skillXp.get(cell.id, 0) if cell else 0

func SetSkillXp(cell : SkillCell, value : int):
	if cell == null:
		push_error("Provided skill cell is null")
		return
	skillXp[cell.id] = value

func RemoveSkill(cell : SkillCell):
	if cell == null:
		push_error("Provided skill cell is null")
		return

	skills.erase(cell.id)
	skillXp.erase(cell.id)

	if actor is PlayerAgent and actor.peerID != NetworkCommons.PeerUnknownID:
		Network.UpdateSkill(cell.id, 0, actor.peerID)

#
func ImportProgress(charID : int):
	for entry in Launcher.SQL.GetSkills(charID):
		var skill : SkillCell = DB.GetSkill(entry.get("skill_id", DB.UnknownHash))
		if skill:
			AddSkill(skill, entry.get("level", 1))
			skillXp[skill.id] = int(entry.get("xp", 0))
	for entry in Launcher.SQL.GetQuests(charID):
		SetQuest(entry.get("quest_id", DB.UnknownHash), entry.get("state", 0))
	for entry in Launcher.SQL.GetBestiaries(charID):
		AddBestiary(entry.get("mob_id", DB.UnknownHash), entry.get("killed_count", 0))

#
func _init(actorNode : Actor, isManaged : bool):
	if isManaged:
		actor = actorNode
		questMutex = Mutex.new()
		bestiaryMutex = Mutex.new()
