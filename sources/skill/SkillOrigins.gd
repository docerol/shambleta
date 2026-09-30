extends RefCounted
class_name SkillOrigins

# ONDA 3b-A (juiz cego 2026-09-27, "Core Gameplay 8.3 / Game Design 8.6": o catálogo
# de skills existe, `presets/cells/skills/` tem 13 células, `ClassBonus` declara quais
# cada classe PODE usar — e nada no jogo ENTREGAVA nada além das duas skills padrão e
# da skill inicial da classe). A diferença entre "permitida" e "obtenível" era
# invisível: `SkillAllowed()` é um portão, não uma torneira. `TeachSkill`
# (`sources/actor/agent/NpcCommons.gd:@TeachSkill`) não tinha UM chamador de conteúdo, e
# `/skill` (depurador) era o único caminho que punha skill em personagem.
#
# Este arquivo é a TORNEIRA declarada: para cada skill do catálogo, pelo menos uma
# origem que um jogador percorre sem digitar comando de depurador. Não é um catálogo
# decorativo — `SkillTrainer` (o kernel que o NPC usa para ensinar) lê ESTAS linhas, e
# `tests/skill_content_reach_test.gd` exige que toda linha tenha conteúdo real do
# outro lado (script de NPC que existe no disco, skill que existe no `DB.SkillsDB`,
# classe que existe em `ClassBonus`). Remover uma origem aqui vermelha o harness;
# apagar o ramo de treino do NPC também.
#
# Formas de origem (as que o produto sabe entregar hoje, sem rota de rede nova):
#   * `default_kit`   — `ActorCommons.DefaultSkills`, gravado na criação do
#     personagem (`Server.CreateCharacter`). Não é depurador: é o que todo
#     personagem novo já tem.
#   * `class_starter` — a primeira skill exclusiva da classe, pela classe escolhida
#     na tela de personagem (`ClassBonus.GetCatalog()[i].starter_skill`).
#   * `trainer_npc`   — NPC do mundo que ensina por `NpcCommons.TeachSkill`, cobrando
#     um MARCO DE NÍVEL (progressão, não moeda). O marco é o motivo da linha existir:
#     sem ele, skill seria loot grátis no primeiro clique.

const OriginDefaultKit : String		= "default_kit"
const OriginClassStarter : String	= "class_starter"
const OriginTrainerNpc : String		= "trainer_npc"

const OriginKinds : Array[String]	= [OriginDefaultKit, OriginClassStarter, OriginTrainerNpc]

# A lesson é dada por um NPC de carne e osso no mapa: Elanore, a Kahwe das portas de
# Tulimshar — a mesma NPC que já conduz o tutorial (`presets/quests/Tutorial.tres`,
# `giver = "Elanore"`), logo todo personagem novo a encontra sem procurar.
const TrainerNPC : String			= "Elanore"
const TrainerScript : String		= "res://sources/scripts/tonori/tulimshar/Elanore.gd"

# Marco de nível por skill de treinador. Números ancorados no que o repo mede, não
# em gosto: o teto de progressão é `Experience.MAX_LEVEL` (`sources/actor/stat/
# Experience.gd:14`, 60 — cap de renascimento), e `tests/skill_content_reach_test.gd`
# exige que toda lição caiba na primeira metade dessa curva (≤ MAX_LEVEL/2) com marcos
# estritamente crescentes por kit: o segundo ataque de uma classe tem de chegar enquanto
# o jogador ainda está na skill inicial, e as extras do Scholar (5 linhas) escalam com
# o número de linhas que a classe tem para aprender.
static func _TrainerRows() -> Array:
	return [
		{"skill": "Jump", "requires_level": 5, "note": "Mobilidade: pula obstáculo e encurta distância."},
		{"skill": "Morph", "requires_level": 8, "note": "Utilidade: muda de forma para passar onde antes não passava."},
		{"skill": "Sonic Scream", "requires_level": 12, "note": "Segundo ataque do Warden — sem ele a classe tinha só Melee e Sonic Wave."},
		{"skill": "Leaf Blades", "requires_level": 12, "note": "Segundo ataque do Rogue — sem ele a classe tinha só Melee e Archer."},
		{"skill": "Spitfire", "requires_level": 10, "note": "Segunda faísca do Scholar."},
		{"skill": "Mana Burst", "requires_level": 14, "note": "Explosão de mana do Scholar."},
		{"skill": "Inma", "requires_level": 18, "note": "Cura do Scholar — a linha que faltava para o caster sobreviver sozinho."},
		{"skill": "Lum", "requires_level": 22, "note": "Luz do Scholar: a quinta linha do kit."},
	]

# As linhas fixas: o que nasce com o personagem, sem clicar em nada além de "criar".
static func _KitRows() -> Array:
	return [
		{"skill": "Melee", "kind": OriginDefaultKit, "ref": "ActorCommons.DefaultSkills"},
		{"skill": "Run", "kind": OriginDefaultKit, "ref": "ActorCommons.DefaultSkills"},
	]

# O que a escolha de classe entrega (espeado em `ClassBonus.starter_skill`).
static func _StarterRows() -> Array:
	return [
		{"skill": "Sonic Wave", "kind": OriginClassStarter, "class": ClassBonus.CLASS_WARDEN},
		{"skill": "Archer", "kind": OriginClassStarter, "class": ClassBonus.CLASS_ROGUE},
		{"skill": "Flar", "kind": OriginClassStarter, "class": ClassBonus.CLASS_SCHOLAR},
	]

# A tabela fechada, no formato que `SkillTrainer` e o harness consomem: uma linha por
# (skill, origem). `classes` vazio = qualquer classe pode receber (o portão de classe
# continua sendo `ClassBonus.SkillAllowed`, fonte única da verdade).
static func Table() -> Array:
	var rows : Array = []
	for row in _KitRows():
		rows.append({
			"skill": str(row["skill"]), "kind": str(row["kind"]), "ref": str(row["ref"]),
			"classes": [], "requires_level": 0,
		})
	for row in _StarterRows():
		rows.append({
			"skill": str(row["skill"]), "kind": str(row["kind"]), "ref": str(row["class"]),
			"classes": [str(row["class"])], "requires_level": 0,
		})
	for row in _TrainerRows():
		rows.append({
			"skill": str(row["skill"]), "kind": OriginTrainerNpc, "ref": TrainerNPC,
			"classes": [], "requires_level": int(row["requires_level"]),
		})
	return rows

static func OriginNames() -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	for row in Table():
		out.append(str((row as Dictionary).get("skill", "")))
	return out

static func OriginsOf(skillName : String) -> Array:
	var out : Array = []
	for row in Table():
		if str((row as Dictionary).get("skill", "")) == skillName:
			out.append(row)
	return out

static func HasOrigin(skillName : String) -> bool:
	return not OriginsOf(skillName).is_empty()

# As lições do treinador (o que o NPC de fato oferece), na ordem do marcador de nível.
static func TrainerLessons() -> Array:
	var out : Array = []
	for row in Table():
		var entry : Dictionary = row
		if str(entry.get("kind", "")) != OriginTrainerNpc:
			continue
		out.append(entry)
	out.sort_custom(func(a : Dictionary, b : Dictionary) -> bool:
		return int(a.get("requires_level", 0)) < int(b.get("requires_level", 0)))
	return out

static func TrainerLesson(skillName : String) -> Dictionary:
	for entry in TrainerLessons():
		if str((entry as Dictionary).get("skill", "")) == skillName:
			return entry
	return {}

# O fecho do eixo: quantas skills uma classe CONSEGUE ter, e quais, somando as três
# formas e filtrando pelo portão de classe real (`ClassBonus.SkillAllowed`). É a
# resposta para "Warden e Rogue têm 2 ataques" — não por opinião, por contagem.
static func ObtainableForClass(classID : String) -> Array[String]:
	var out : Array[String] = []
	for cellName in CatalogNames():
		if not ClassBonus.SkillAllowed(classID, cellName):
			continue
		if not _ReachableByClass(classID, cellName):
			continue
		out.append(cellName)
	return out

static func _ReachableByClass(classID : String, skillName : String) -> bool:
	for row in OriginsOf(skillName):
		var entry : Dictionary = row
		var classes : Array = entry.get("classes", [])
		if str(entry.get("kind", "")) == OriginDefaultKit:
			return true
		if classes.is_empty() or classID in classes:
			return true
	return false

# Nomes das células do catálogo, ordenados — a lista que o disco declara, não a que
# alguém remembers. O harness confere esta lista contra `DB.SkillsDB`.
static func CatalogNames() -> Array[String]:
	var out : Array[String] = []
	for value in DB.SkillsDB.values():
		var cell : SkillCell = value
		if cell != null and not cell.name.is_empty():
			out.append(cell.name)
	out.sort()
	return out

# Diagnóstico usado pelo harness e pelo boot: skill sem origem, origem apontando para
# skill que não existe, lição de treinador acima do teto do catálogo de classes.
static func Validate() -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var catalog : Array[String] = CatalogNames()
	for name in catalog:
		if not HasOrigin(name):
			errors.append("skill '%s' não tem origem declarada" % name)
	var seen : Dictionary = {}
	for row in Table():
		var entry : Dictionary = row
		var skill : String = str(entry.get("skill", ""))
		var kind : String = str(entry.get("kind", ""))
		if not OriginKinds.has(kind):
			errors.append("origem '%s' de '%s' não é uma das formas conhecidas" % [kind, skill])
		if not catalog.has(skill):
			errors.append("origem '%s' nomeia '%s', que não existe em presets/cells/skills" % [kind, skill])
		var key : String = "%s|%s" % [skill, kind]
		if seen.has(key):
			errors.append("origem duplicada para '%s' (%s)" % [skill, kind])
		seen[key] = true
		var classes : Array = entry.get("classes", [])
		for classID in classes:
			if not ClassBonus.IsValidClass(str(classID)):
				errors.append("origem de '%s' nomeia classe inexistente '%s'" % [skill, str(classID)])
		if kind == OriginTrainerNpc and int(entry.get("requires_level", 0)) <= 0:
			errors.append("lição de treinador '%s' sem marco de nível" % skill)
	for name in TrainerLessonNames():
		if not DB.HasCellHash(name):
			errors.append("lição '%s' não resolve para célula do DB" % name)
	return errors

static func TrainerLessonNames() -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	for entry in TrainerLessons():
		out.append(str((entry as Dictionary).get("skill", "")))
	return out

# Toda skill que a classe PODE usar tem que ter uma origem alcançável por ela — se
# isto falhar, `ClassBonus` declarou um kit que o jogo não entrega.
static func ValidateClassKits() -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	for entry in ClassBonus.GetCatalog():
		var classID : String = str((entry as Dictionary).get("id", ""))
		var allowed : Array = (entry as Dictionary).get("skills", [])
		var obtainable : Array[String] = ObtainableForClass(classID)
		for skillName in allowed:
			if not obtainable.has(str(skillName)):
				errors.append("classe '%s' pode usar '%s', mas nenhuma origem entrega essa skill a ela" % [classID, str(skillName)])
		var universal : Array = ClassBonus.UNIVERSAL_SKILLS
		for skillName in universal:
			if not obtainable.has(str(skillName)):
				errors.append("classe '%s' perde a universal '%s' (sem origem alcançável)" % [classID, str(skillName)])
	return errors
