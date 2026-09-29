extends RefCounted
class_name SkillTrainer

# ONDA 3b-A (juiz cego 2026-09-27): `TeachSkill` existia em `NpcCommons` e em
# `NpcScript` e NÃO tinha um único chamador de conteúdo — ou seja, o jogo declarava
# um treinador e não treinava ninguém. O outro lado da mesa é `SkillOrigins`, a
# tabela de origens. Este arquivo é o KERNEL que liga as duas pontas: quem pode
# ensinar o quê, a partir de que marco de nível, e o que acontece quando o jogador
# escolhe a lição.
#
# Por que um kernel e não um `if` dentro do NPC: a mesma régua precisa valer para
# qualquer NPC que um dia ensine (e para o harness), e o ramo de diálogo do NPC tem
# de ficar legível. `SkillOrigins` diz O QUE existe; aqui mora a DECISÃO de quem
# recebe. Nada neste arquivo toca rede nova: a entrega é `NpcCommons.TeachSkill`, a
# mesma função que o passo de ação do próprio `NpcScript` invocava
# (`sources/actor/agent/NpcScript.gd:353`), mais a gravação em `SQL.SetSkill` — sem
# ela a lição morria no relog (medido: só `Server.CreateCharacter` gravava skill).

# As lições que a classe PODE receber neste nível, na ordem do marco de nível.
static func LessonsFor(classID : String, level : int) -> Array:
	var out : Array = []
	for entry in SkillOrigins.TrainerLessons():
		var row : Dictionary = entry
		var skill : String = str(row.get("skill", ""))
		if not ClassBonus.SkillAllowed(classID, skill):
			continue
		if level < int(row.get("requires_level", 0)):
			continue
		out.append(row)
	return out

# O que ainda está bloqueado por nível — a linha que impede o NPC de fingir que
# "não tem nada a oferecer" quando o jogador é baixo demais.
static func LockedFor(classID : String, level : int) -> Array:
	var out : Array = []
	for entry in SkillOrigins.TrainerLessons():
		var row : Dictionary = entry
		var skill : String = str(row.get("skill", ""))
		if not ClassBonus.SkillAllowed(classID, skill):
			continue
		if level >= int(row.get("requires_level", 0)):
			continue
		out.append(row)
	return out

# O que o treinador oferece AGORA: marco atingido, classe liberada e o personagem
# ainda não tem a skill (ensinar de novo não é progresso).
static func Offerings(own : BaseAgent) -> Array:
	var out : Array = []
	if own == null:
		return out
	var classID : String = ClassBonus.ResolveClassID(own)
	var level : int = own.stat.level if own.stat != null else 0
	for row in LessonsFor(classID, level):
		var skill : String = str(row.get("skill", ""))
		if HasLesson(own, skill):
			continue
		out.append(row)
	return out

# Hash da célula só quando ela existe: `DB.GetCellHash` de nome desconhecido faz
# `push_error` no servidor, e lição inexistente é entrada de jogador, não bug.
static func _HashOf(skillName : String) -> int:
	return DB.GetCellHash(skillName) if DB.HasCellHash(skillName) else DB.UnknownHash

static func HasLesson(own : BaseAgent, skillName : String) -> bool:
	if own == null or own.progress == null:
		return false
	var skillHash : int = _HashOf(skillName)
	if skillHash == DB.UnknownHash:
		return false
	var cell : SkillCell = DB.GetSkill(skillHash)
	return cell != null and own.progress.HasSkill(cell)

static func CanTeach(classID : String, level : int, skillName : String) -> bool:
	for row in SkillOrigins.TrainerLessons():
		var entry : Dictionary = row
		if str(entry.get("skill", "")) != skillName:
			continue
		if not ClassBonus.SkillAllowed(classID, skillName):
			return false
		return level >= int(entry.get("requires_level", 0))
	return false

# A reason legível da recusa (sem token cru de servidor na tela — régua de
# `tests/reason_toast_test.gd`).
static func BlockedReason(own : BaseAgent, skillName : String) -> String:
	if own == null or not (own is PlayerAgent):
		return "I can only teach an adventurer who is standing here."
	var cell : SkillCell = DB.GetSkill(DB.GetCellHash(skillName))
	if cell == null:
		return "That form is not written in our books."
	var lesson : Dictionary = SkillOrigins.TrainerLesson(skillName)
	if lesson.is_empty():
		return "I have no lesson prepared for that form."
	if not ClassBonus.SkillAllowed(ClassBonus.ResolveClassID(own), skillName):
		return "Your class does not carry that form."
	if own.stat != null and own.stat.level < int(lesson.get("requires_level", 0)):
		return "You are not strong enough yet: reach level %d first." % int(lesson.get("requires_level", 0))
	if HasLesson(own, skillName):
		return "You already know this form."
	return ""

# Ensina a lição pelo caminho do produto: NpcCommons.TeachSkill (que faz
# Progress.AddSkill e sincroniza a skill com o cliente) + a gravação em SQL, para
# que a lição atravesse o relog. Devolve {"ok", "message", "skill"}.
static func Teach(npc : Object, skillName : String) -> Dictionary:
	var result : Dictionary = {"ok": false, "skill": skillName, "message": "", "reason": ""}
	if npc == null:
		result["message"] = "I am not able to teach that to you."
		return result
	var rawOwn : Variant = npc.get("own")
	if not (rawOwn is BaseAgent):
		result["message"] = "I am not able to teach that to you."
		result["reason"] = "no_student"
		return result
	var own : BaseAgent = rawOwn
	var blocked : String = BlockedReason(own, skillName)
	if not blocked.is_empty():
		result["message"] = blocked
		result["reason"] = "blocked"
		return result
	var skillHash : int = DB.GetCellHash(skillName)
	if not NpcCommons.TeachSkill(own, skillHash, 1):
		result["message"] = "Something went wrong while teaching that form."
		result["reason"] = "teach_failed"
		return result
	# Durabilidade: a lição gravada no mesmo formato que a criação de personagem usa
	# (`Server.CreateCharacter` → `SQL.SetSkill`); sem isto a skill morria no relog.
	var charID : int = (own as PlayerAgent).GetCharacterID() if own is PlayerAgent else 0
	if charID > 0 and Launcher.SQL != null:
		Launcher.SQL.SetSkill(charID, skillHash, 1)
	var lesson : Dictionary = SkillOrigins.TrainerLesson(skillName)
	result["ok"] = true
	result["reason"] = "taught"
	result["message"] = "Then carry this form: %s. It opens at level %d for your class." % [
		skillName, int(lesson.get("requires_level", 0)),
	]
	return result

# A próxima promessa, para o NPC não devolver um beco sem saída.
static func NextHint(own : BaseAgent) -> String:
	if own == null or own.stat == null:
		return ""
	var locked : Array = LockedFor(ClassBonus.ResolveClassID(own), own.stat.level)
	if locked.is_empty():
		return "You have learned every form I keep."
	var row : Dictionary = locked[0]
	return "Come back at level %d and I will teach you %s." % [int(row.get("requires_level", 0)), str(row.get("skill", ""))]
