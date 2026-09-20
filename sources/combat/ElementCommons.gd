extends RefCounted
class_name ElementCommons

# SOM-IDLE: elemental combat (ELEMENTAL_COMBAT.md). Two independent mechanics:
#
#   1. Instant elemental damage (Fire/Ice/Lightning): a flat bonus added to a
#      hit's base value, mitigated by the target's matching *Resist %. Lives
#      on ActorStats.current (Formula.GetFireDamage/etc, wired in Stats.gd),
#      exactly like Attack/Defense — scales with gear, never with a formula
#      of its own in v1 (see doc §3 for why).
#
#   2. Damage-over-time procs (Poison/Bleed/Burn): weapon-only stats, read
#      straight off StatModifier at hit time (never cached in current — a
#      character has no "innate" DoT chance, only gear grants it). A proc
#      that lands starts a self-ticking timer on the TARGET. Burn is
#      mitigated by FireResist (no separate BurnResist).
#
# Refresh policy: a new proc of the same type always REPLACES the active one
# (fresh duration + fresh power), never stacks. Simpler to reason about and to
# balance than "keep whichever is stronger" — see doc §5 for the trade-off.

enum StatusType {
	Poison,
	Bleed,
	Burn,
}

const TickInterval : float			= 1.0	# seconds between DoT ticks
const TickCount : int				= 4		# ticks per application (duration = TickInterval * TickCount)

# ------------------------------------------------------------------ instant elemental damage
# Penetration (Modifier.Penetration, equipamento): reduz a resistência efetiva
# do alvo, com piso em 0 (sem resist negativa na v1). Lida uma vez por golpe.
static func EffectiveResist(resist : float, penetration : float) -> float:
	return clampf(resist - maxf(penetration, 0.0), 0.0, 1.0)

static func GetElementalDamage(agent : BaseAgent, target : BaseAgent) -> int:
	var penetration : float = float(agent.stat.modifiers.Get(CellCommons.Modifier.Penetration, true))
	var total : int = 0
	total += _MitigatedElement(agent.stat.current.fireDamage, EffectiveResist(target.stat.current.fireResist, penetration))
	total += _MitigatedElement(agent.stat.current.iceDamage, EffectiveResist(target.stat.current.iceResist, penetration))
	total += _MitigatedElement(agent.stat.current.lightningDamage, EffectiveResist(target.stat.current.lightningResist, penetration))
	return total

static func _MitigatedElement(rawDamage : int, resist : float) -> int:
	if rawDamage <= 0:
		return 0
	return maxi(0, floori(float(rawDamage) * (1.0 - resist)))

# ------------------------------------------------------------------ status procs (poison/bleed/burn)
# Called once per confirmed, non-dodged hit (Skill.Damaged). Rolls each of the
# three status types independently — a single hit can proc more than one.
static func RollStatusProcs(agent : BaseAgent, target : BaseAgent, rng : float) -> void:
	if not ActorCommons.IsAlive(target):
		return
	_RollOne(agent, target, StatusType.Poison, CellCommons.Modifier.PoisonChance, CellCommons.Modifier.PoisonPower, target.stat.current.poisonResist, rng)
	_RollOne(agent, target, StatusType.Bleed, CellCommons.Modifier.BleedChance, CellCommons.Modifier.BleedPower, target.stat.current.bleedResist, rng)
	_RollOne(agent, target, StatusType.Burn, CellCommons.Modifier.BurnChance, CellCommons.Modifier.BurnPower, target.stat.current.fireResist, rng)

static func _RollOne(agent : BaseAgent, target : BaseAgent, statusType : StatusType, chanceMod : CellCommons.Modifier, powerMod : CellCommons.Modifier, resist : float, rng : float) -> void:
	var baseChance : float = float(agent.stat.modifiers.Get(chanceMod, true))
	if baseChance <= 0.0:
		return	# attacker's weapon doesn't grant this proc at all — skip the roll entirely

	# Resist reduces proc chance proportionally, same curve as damage mitigation,
	# so a fully-resisted target (ResistCap, 75%) still has a small residual
	# chance rather than hard immunity (consistent with Formula.ResistCap intent).
	var effectiveChance : float = clampf(baseChance * (1.0 - resist), 0.0, 1.0)
	if rng > effectiveChance:
		return

	var basePower : int = int(agent.stat.modifiers.Get(powerMod, true))
	if basePower <= 0:
		return
	var mitigatedPower : int = maxi(1, floori(float(basePower) * (1.0 - resist)))
	Apply(agent, target, statusType, mitigatedPower)

# Starts (or replaces) a DoT on target. totalPower is the SUM of damage dealt
# across all TickCount ticks, already resist-mitigated — split evenly here.
static func Apply(agent : BaseAgent, target : BaseAgent, statusType : StatusType, totalPower : int) -> void:
	if not ActorCommons.IsAlive(target):
		return
	var generation : int = int(target.activeStatusEffects.get(statusType, 0)) + 1
	target.activeStatusEffects[statusType] = generation
	var perTick : int = maxi(1, ceili(float(totalPower) / float(TickCount)))
	var sourceRID : int = agent.get_rid().get_id() if agent else target.get_rid().get_id()
	_ScheduleTick(target, statusType, generation, TickCount, perTick, sourceRID)

static func _ScheduleTick(target : BaseAgent, statusType : StatusType, generation : int, remainingTicks : int, perTick : int, sourceRID : int) -> void:
	Callback.SelfDestructTimer(target, TickInterval, _Tick, [target, statusType, generation, remainingTicks, perTick, sourceRID])

static func _Tick(target : BaseAgent, statusType : StatusType, generation : int, remainingTicks : int, perTick : int, sourceRID : int) -> void:
	if not is_instance_valid(target) or not ActorCommons.IsAlive(target):
		return
	# A newer application of the same status superseded this one — this tick
	# is stale, do nothing (the newer chain owns activeStatusEffects[statusType] now).
	if int(target.activeStatusEffects.get(statusType, -1)) != generation:
		return

	var dmg : int = clampi(perTick, 0, target.stat.health)
	target.stat.SetHealth(-dmg)
	target.agent_damaged.emit(target, dmg)
	Network.NotifyNeighbours(target, "TargetAlteration", [sourceRID, target.get_rid().get_id(), dmg, _AlterationFor(statusType), DB.UnknownHash, true], true, true)

	var ticksLeft : int = remainingTicks - 1
	if ticksLeft > 0 and ActorCommons.IsAlive(target):
		_ScheduleTick(target, statusType, generation, ticksLeft, perTick, sourceRID)
	else:
		target.activeStatusEffects.erase(statusType)

static func _AlterationFor(statusType : StatusType) -> ActorCommons.Alteration:
	match statusType:
		StatusType.Poison:
			return ActorCommons.Alteration.POISON
		StatusType.Bleed:
			return ActorCommons.Alteration.BLEED
		StatusType.Burn:
			return ActorCommons.Alteration.BURN
	return ActorCommons.Alteration.UNKNOWN

# Called on death/revive/despawn — bumping the generation for every type is
# enough to invalidate any in-flight ticks without needing to hunt down and
# free their Timer nodes individually (they self-check and no-op, then
# self-destruct on their own next timeout via Callback.SelfDestructTimer).
static func ClearAllStatus(target : BaseAgent) -> void:
	if not target:
		return
	for statusType in target.activeStatusEffects.keys():
		target.activeStatusEffects[statusType] = int(target.activeStatusEffects[statusType]) + 1
	target.activeStatusEffects.clear()
