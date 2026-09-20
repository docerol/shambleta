extends RefCounted
class_name ClassBonus

# Hero classes (D2-like): afinidade de stats (multiplicativa, aplicada no fim
# de RefreshEntityStats), skills exclusivas e equipamentos de classe.
# classID vazio = classless (veteranos anteriores às classes, irrestrito).

const CLASS_WARDEN : String = "warden"
const CLASS_ROGUE : String = "rogue"
const CLASS_SCHOLAR : String = "scholar"
const CLASSLESS : String = ""

# Skills universais (mobilidade/utilidade) — nomes como no .tres.
const UNIVERSAL_SKILLS : Array = ["Melee", "Run", "Jump", "Morph"]

static func GetCatalog() -> Array:
	return [
		{
			"id": CLASS_WARDEN, "label": "Warden",
			"desc": "Melee tank: HP e ataque altos, magia fraca.",
			"mults": {"attack": 1.10, "defense": 1.05, "maxHealth": 1.15, "mattack": 0.90, "maxMana": 0.95},
			"skills": ["Sonic Wave", "Sonic Scream"],
			"starter_skill": "Sonic Wave", "starter_weapon": "Warden Blade",
		},
		{
			"id": CLASS_ROGUE, "label": "Rogue",
			"desc": "Skirmisher: crit e dodge altos, frágil.",
			"mults": {"attack": 1.05, "critRate": 1.50, "dodgeRate": 1.25, "maxHealth": 0.95, "defense": 0.95},
			"skills": ["Archer", "Leaf Blades"],
			"starter_skill": "Archer", "starter_weapon": "Rogue Shiv",
		},
		{
			"id": CLASS_SCHOLAR, "label": "Scholar",
			"desc": "Caster elemental: mattack e mana altos, físico frágil.",
			"mults": {"mattack": 1.20, "maxMana": 1.15, "attack": 0.90, "defense": 0.95, "maxHealth": 0.95},
			"skills": ["Flar", "Spitfire", "Mana Burst", "Inma", "Lum"],
			"starter_skill": "Flar", "starter_weapon": "Scholar Focus",
		},
	]

static func GetClass(classID : String) -> Dictionary:
	for entry in GetCatalog():
		if str(entry.get("id", "")) == classID:
			return entry
	return {}

static func IsValidClass(classID : String) -> bool:
	return not GetClass(classID).is_empty()

# Resolve a classe de um ator: PlayerAgent (server) via character; resto ''.
static func ResolveClassID(actor : Actor) -> String:
	if actor == null:
		return CLASSLESS
	if actor is PlayerAgent:
		if Launcher.SQL == null:
			return CLASSLESS
		var charID : int = (actor as PlayerAgent).GetCharacterID()
		return Launcher.SQL.GetCharacterClass(charID) if charID > 0 else CLASSLESS
	return CLASSLESS

# Aplica os multiplicadores no current (puro e testável). Campos int
# arredondam com piso 1; floats com piso 0.
static func ApplyClassMults(current : BaseStats, classID : String) -> void:
	var entry : Dictionary = GetClass(classID)
	if entry.is_empty():
		return
	var mults : Dictionary = entry.get("mults", {})
	for key in mults.keys():
		var m : float = float(mults[key])
		var v : Variant = current.get(key)
		if v is int:
			current.set(key, maxi(1, int(roundf(float(v) * m))))
		elif v is float:
			current.set(key, maxf(0.0, float(v) * m))

# Gate de skill (puro): universal ou da lista da classe; classless pode tudo.
static func SkillAllowed(classID : String, skillName : String) -> bool:
	if classID.is_empty():
		return true
	if skillName in UNIVERSAL_SKILLS:
		return true
	var entry : Dictionary = GetClass(classID)
	return skillName in entry.get("skills", [])

static func CanUseSkill(agent : BaseAgent, skill : SkillCell) -> bool:
	if agent == null or skill == null:
		return false
	return SkillAllowed(ResolveClassID(agent), skill.name)

# Gate de equipamento (puro): classReq vazio = universal; classless pode tudo.
static func EquipAllowed(classID : String, classReq : String) -> bool:
	if classReq.is_empty() or classID.is_empty():
		return true
	return classReq == classID

static func CanEquip(actor : Actor, cell : ItemCell) -> bool:
	if cell == null:
		return false
	return EquipAllowed(ResolveClassID(actor), str(cell.classReq))
