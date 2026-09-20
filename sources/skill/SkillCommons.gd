extends RefCounted
class_name SkillCommons

# Constants
const SkillMeleeName : String			= "Melee"
const SkillRunName : String				= "Run"
const PerspectiveIncrease : Vector2		= Vector2(1.0, 1.42)

# Actions
static func TryConsume(agent : BaseAgent, modifier : CellCommons.Modifier, skill : SkillCell) -> bool:
	if agent is not PlayerAgent:
		return true

	match modifier:
		CellCommons.Modifier.Health:
			var exhaust : int = skill.modifiers.Get(modifier)
			if agent.stat.health >= -exhaust:
				agent.stat.SetHealth(exhaust)
				return true
		CellCommons.Modifier.Mana:
			var exhaust : int = skill.modifiers.Get(modifier)
			if agent.stat.mana >= -exhaust:
				agent.stat.SetMana(exhaust)
				return true
		CellCommons.Modifier.Stamina:
			var exhaust : int = skill.modifiers.Get(modifier)
			if agent.stat.stamina >= -exhaust:
				agent.stat.SetStamina(exhaust)
				return true
	return false

static func GetDamage(agent : BaseAgent, target : BaseAgent, skill : SkillCell, rng : float) -> Skill.AlterationInfo:
	var info : Skill.AlterationInfo = Skill.AlterationInfo.new()
	var skillValue : int = skill.modifiers.Get(CellCommons.Modifier.MAttack)
	if skillValue > 0:
		info.value = max(1, agent.stat.current.mattack + skillValue - target.stat.current.mdefense)
	else:
		skillValue = skill.modifiers.Get(CellCommons.Modifier.Attack)
		info.value = max(1, agent.stat.current.attack + skillValue - target.stat.current.defense)
	# SOM-IDLE: farm damage floor. Mobos de aventura têm defesa errática (Croc
	# def 41, Turtle 38) que, contra o auto-combat de skill única do idle, vira
	# 1 dano/golpe e derruba a taxa de kill para ~11/h. Para quem está FARMANDO
	# (player com idlePolicy ativo) garantimos um piso de dano relativo ao HP do
	# alvo, então nenhuma zona ficaeffective-unkillable. O caminho de aventura
	# (sem idlePolicy) é 100% intacto. Dodge continua zerando (o piso é aplicado
	# antes do crit/dodge, mas o branch DODGE o zera depois).
	var floorDmg : int = FarmDamageFloor(agent, target)
	if floorDmg > info.value:
		info.value = floorDmg

	# Tormento (D2): mobs ficam mais duros e batem mais forte contra chars em
	# tormento. Antes do elemental/crit para escalar junto com o resto do golpe.
	var tormentOut : int = 0
	if agent is PlayerAgent:
		tormentOut = (agent as PlayerAgent).tormentLevel
	var tormentIn : int = 0
	if target is PlayerAgent:
		tormentIn = (target as PlayerAgent).tormentLevel
	if tormentOut > 0 and not (target is PlayerAgent):
		info.value = maxi(1, ceili(float(info.value) / Formula.TormentMobHpFactor(tormentOut)))
	if tormentIn > 0 and not (agent is PlayerAgent):
		info.value = maxi(1, ceili(float(info.value) * Formula.TormentMobDmgFactor(tormentIn)))

	# SOM-IDLE: elemental combat (ELEMENTAL_COMBAT.md) — flat Fire/Ice/Lightning
	# bonus, already resist-mitigated, added before crit/dodge so it scales with
	# both like the rest of the hit (a crit multiplies total damage, elemental
	# included; a dodge zeroes it out same as physical).
	info.value += ElementCommons.GetElementalDamage(agent, target)

	var critMaster : bool = agent.stat.current.critRate > target.stat.current.dodgeRate
	if critMaster and rng > 1.0 - agent.stat.current.critRate:
		info.type = ActorCommons.Alteration.CRIT
		info.value *= 2
	elif not critMaster and rng > 1.0 - target.stat.current.dodgeRate:
		info.type = ActorCommons.Alteration.DODGE
		info.value = 0
	else:
		info.type = ActorCommons.Alteration.HIT
		info.value = ceili(info.value * rng)

	# D2-depth: deadly strike — chance só-de-equipamento de dobrar um HIT que
	# não foi crit (roll independente, como no D2; nunca quadruplica com crit).
	if info.type == ActorCommons.Alteration.HIT:
		var deadly : float = clampf(float(agent.stat.modifiers.Get(CellCommons.Modifier.DeadlyChance, true)), 0.0, DeadlyCap)
		if deadly > 0.0 and randf() < deadly:
			info.type = ActorCommons.Alteration.DEADLY
			info.value *= 2

	if info.value <= 0:
		info.type = ActorCommons.Alteration.DODGE

	return info

# D2-depth: teto do deadly strike (evita 100% determinístico via stacking).
const DeadlyCap : float = 0.5

# SOM-IDLE: piso de dano do idle — FarmMinDamagePct do HP máximo do alvo, só
# para jogadores em sessão de farm. Retorna 0 fora desse contexto.
const FarmMinDamagePct : float = 0.035
static func FarmDamageFloor(agent : BaseAgent, target : BaseAgent) -> int:
	if agent is PlayerAgent and (agent as PlayerAgent).idlePolicy != null:
		return ceili(target.stat.current.maxHealth * FarmMinDamagePct)
	return 0

static func GetHeal(agent : BaseAgent, target : BaseAgent, skill : SkillCell, rng : float) -> int:
	var skillValue : int = skill.modifiers.Get(CellCommons.Modifier.Health)
	var healValue : int = int(agent.stat.concentration + skillValue * rng)
	healValue = min(healValue, target.stat.current.maxHealth - target.stat.health)
	return healValue

static func GetZoneTargets(instance : WorldInstance, zonePos : Vector2, skill : SkillCell) -> Array[BaseAgent]:
	var targets : Array[BaseAgent] = []

	if skill.modifiers.Get(CellCommons.Modifier.Attack) != 0 or skill.modifiers.Get(CellCommons.Modifier.MAttack) != 0:
		for neighbour in instance.mobs:
			var filteredRange : float = skill.skillRange + neighbour.data._radius
			if ActorCommons.IsAlive(neighbour) and Util.IsReachableSquared(neighbour.position, zonePos, filteredRange * filteredRange):
				targets.append(neighbour)
	if skill.modifiers.Get(CellCommons.Modifier.Health) != 0:
		for neighbour in instance.players:
			var filteredRange : float = skill.skillRange + neighbour.data._radius
			if ActorCommons.IsAlive(neighbour) and Util.IsReachableSquared(neighbour.position, zonePos, filteredRange * filteredRange):
				targets.append(neighbour)

	return targets

static func GetSurroundingTargets(agent : BaseAgent, skill : SkillCell) -> Array[BaseAgent]:
	var targets : Array[BaseAgent] = []
	var instance : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)

	if instance:
		if skill.modifiers.Get(CellCommons.Modifier.Attack) != 0 or skill.modifiers.Get(CellCommons.Modifier.MAttack) != 0:
			for neighbour in instance.mobs:
				if IsAttackable(agent, neighbour, skill):
					targets.append(neighbour)
		if skill.modifiers.Get(CellCommons.Modifier.Health) != 0:
			for neighbour in instance.players:
				if IsAttackable(agent, neighbour, skill):
					targets.append(neighbour)

	return targets

static func GetRNG(hasStamina : bool) -> float:
	return randf_range(0.9 if hasStamina else 0.1, 1.0)

# Checks
static func IsNear(agent : BaseAgent, target : BaseAgent, skillRange : int) -> bool:
	var filteredRange : float = skillRange + agent.data._radius + target.data._radius
	var distanceSquared : float = 0.0
	if not target.agent:
		distanceSquared = ActorCommons.GetDistanceSquared(agent, target.position)
	else:
		distanceSquared = WorldNavigation.GetDistanceSquaredSafe(agent, target.position)
	return distanceSquared <= filteredRange * filteredRange

static func IsSameMap(agent : BaseAgent, target : BaseAgent) -> bool:
	return WorldAgent.GetMapFromAgent(agent) == WorldAgent.GetMapFromAgent(target)

static func IsSameInstance(agent : BaseAgent, target : BaseAgent) -> bool:
	return WorldAgent.GetInstanceFromAgent(agent) == WorldAgent.GetInstanceFromAgent(target)

static func IsAttackable(agent : BaseAgent, target : BaseAgent, skill : SkillCell) -> bool:
	return IsInteractable(agent, target) and IsNear(agent, target, ActorCommons.GetSkillRange(agent, skill))

static func IsTargetable(agent : BaseAgent, target : BaseAgent) -> bool:
	return IsInteractable(agent, target) and IsNear(agent, target, ActorCommons.TargetMaxDistance)

static func IsInteractable(agent : BaseAgent, target : BaseAgent) -> bool:
	return not ActorCommons.IsSameActor(agent, target) and ActorCommons.IsAlive(target) and IsSameInstance(agent, target)

static func IsStaticCasting(agent : BaseAgent) -> bool:
	return agent.currentSkillID != DB.UnknownHash and not DB.SkillsDB[agent.currentSkillID].castWalk

static func IsCasting(agent : BaseAgent, skill : SkillCell = null) -> bool:
	return (agent.currentSkillID == skill.id) if skill else DB.SkillsDB.has(agent.currentSkillID)

static func IsCoolingDown(agent : BaseAgent, skill : SkillCell) -> bool:
	return agent.cooldownTimers.get(skill.id, false)

static func GetCooldown(actor : Actor, skill : SkillCell) -> float:
	return actor.stat.current.cooldownAttackDelay + skill.cooldownTime

static func IsDelayed(skill : SkillCell) -> bool:
	return skill.projectilePreset != null

static func HasSkill(agent : BaseAgent, skill : SkillCell) -> bool:
	if agent.progress:
		return agent.progress.HasSkill(skill)
	if agent is AIAgent:
		return skill != null and skill.id in agent.aiSkills
	return false

static func IsInstantAbility(skill : SkillCell) -> bool:
	return skill.category == SkillCell.Category.ABILITY and not skill.modifiers.HasAny() and skill.castTime == 0.0 and skill.cooldownTime == 0.0

static func HasAnyActionInProgress(agent : BaseAgent) -> bool:
	return agent.currentSkillID != DB.UnknownHash or not agent.actionTimer.is_stopped()
