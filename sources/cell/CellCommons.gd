extends RefCounted
class_name CellCommons

enum Type
{
	ITEM = 0,
	EMOTE,
	SKILL,
	COUNT
}

#
static func CompareCell(cell : BaseCell, id : int, customfield : String) -> bool:
	return cell and \
	cell.id == id and \
	(
		cell is not ItemCell or \
		cell.customfield == customfield \
	)

static func IsSameItem(cell : BaseCell, item : Item) -> bool:
	return item and CompareCell(cell, item.cellID, item.cellCustomfield)

static func IsSameCell(cellA : BaseCell, cellB : BaseCell) -> bool:
	return cellB and CompareCell(cellA, cellB.id, cellB.customfield if cellB is ItemCell else "")

static func IsEquipment(cell : ItemCell) -> bool:
	return cell.slot >= ActorCommons.Slot.FIRST_EQUIPMENT and cell.slot < ActorCommons.Slot.LAST_EQUIPMENT

static func IsEquipped(cell : BaseCell) -> bool:
	return cell and cell is ItemCell and IsEquipment(cell) and \
	Launcher.Player and Launcher.Player.inventory and Launcher.Player.inventory.equipment and \
	IsSameItem(cell, Launcher.Player.inventory.equipment[cell.slot])

enum Modifier {
	None = 0,
	Health,
	Mana,
	Stamina,
	MaxMana,
	RegenMana,
	CritRate,
	MAttack,
	MDefense,
	MaxStamina,
	RegenStamina,
	CooldownDelay,
	MaxHealth,
	RegenHealth,
	Defense,
	CastDelay,
	DodgeRate,
	AttackRange,
	WalkSpeed,
	WeightCapacity,
	Attack,
	Hide,
	Invisible,
	# SOM-IDLE: elemental combat (ELEMENTAL_COMBAT.md). Instant elemental damage
	# adds to a hit (Skill.GetDamage), mitigated by the matching *Resist on the
	# target. Poison/Bleed/Burn are damage-over-time procs: *Chance/*Power are
	# weapon-only stats (read straight off equipment modifiers, never cached in
	# BaseStats.current — see ElementCommons.RollStatusProcs); Burn is mitigated
	# by FireResist (it IS fire's DoT, no separate BurnResist).
	FireDamage,
	IceDamage,
	LightningDamage,
	FireResist,
	IceResist,
	LightningResist,
	PoisonChance,
	PoisonPower,
	PoisonResist,
	BleedChance,
	BleedPower,
	BleedResist,
	BurnChance,
	BurnPower,
	# D2-depth stats (community roadmap): elemental penetration (counter-stat
	# de resist, lido do equipamento no hit) e deadly strike (chance de
	# dobrar o golpe, só-equipamento, roll independente do crit).
	Penetration,
	DeadlyChance,
	Count
}

static func GetModifierDisplayName(effect : Modifier) -> String:
	match effect:
		Modifier.Health:		return "Health"
		Modifier.Mana:			return "Mana"
		Modifier.Stamina:		return "Stamina"
		Modifier.MaxHealth:		return "Max Health"
		Modifier.MaxMana:		return "Max Mana"
		Modifier.MaxStamina:	return "Max Stamina"
		Modifier.Attack:		return "Attack"
		Modifier.Defense:		return "Defense"
		Modifier.MAttack:		return "M. Attack"
		Modifier.MDefense:		return "M. Defense"
		Modifier.AttackRange:	return "Atk Range"
		Modifier.CritRate:		return "Crit Rate"
		Modifier.DodgeRate:		return "Dodge Rate"
		Modifier.CastDelay:		return "Cast Delay"
		Modifier.CooldownDelay:	return "Cooldown"
		Modifier.RegenHealth:	return "HP Regen"
		Modifier.RegenMana:		return "MP Regen"
		Modifier.RegenStamina:	return "SP Regen"
		Modifier.WalkSpeed:		return "Walk Speed"
		Modifier.WeightCapacity: return "Carry Weight"
		Modifier.FireDamage:		return "Fire Damage"
		Modifier.IceDamage:		return "Ice Damage"
		Modifier.LightningDamage: return "Lightning Damage"
		Modifier.FireResist:		return "Fire Resist"
		Modifier.IceResist:		return "Ice Resist"
		Modifier.LightningResist: return "Lightning Resist"
		Modifier.PoisonChance:	return "Poison Chance"
		Modifier.PoisonPower:	return "Poison Power"
		Modifier.PoisonResist:	return "Poison Resist"
		Modifier.BleedChance:	return "Bleed Chance"
		Modifier.BleedPower:	return "Bleed Power"
		Modifier.BleedResist:	return "Bleed Resist"
		Modifier.BurnChance:	return "Burn Chance"
		Modifier.BurnPower:	return "Burn Power"
		Modifier.Penetration:	return "Elemental Penetration"
		Modifier.DeadlyChance:	return "Deadly Chance"
		_:						return "Unknown"

static func IsInverseModifier(effect : Modifier) -> bool:
	return effect == Modifier.CastDelay or effect == Modifier.CooldownDelay

static func GetModifierColor(effect : Modifier, value : Variant) -> Color:
	var val : float = -float(value) if IsInverseModifier(effect) else float(value)
	if val > 0.0:
		return UICommons.ModifierPositiveColor
	elif val < 0.0:
		return UICommons.ModifierNegativeColor
	return UICommons.LightTextColor

static func GetModifierDiffBBCode(effect : Modifier, diff : Variant) -> String:
	if float(diff) == 0.0:
		return ""
	var diffColor : String = "#" + GetModifierColor(effect, diff).to_html(false)
	var arrow : String = "↑" if float(diff) > 0.0 else "↓"
	return " [color=%s](%s %s)[/color]" % [diffColor, FormatModifierValue(effect, diff), arrow]

static func GetPercentDiffBBCode(diffPercent : float, inverse : bool = false) -> String:
	if diffPercent == 0.0:
		return ""
	var isGood : bool = diffPercent < 0.0 if inverse else diffPercent > 0.0
	var diffColor : String = "#" + (UICommons.ModifierPositiveColor.to_html(false) if isGood else UICommons.ModifierNegativeColor.to_html(false))
	var arrow : String = "↑" if diffPercent > 0.0 else "↓"
	return " [color=%s](%s%.2f%% %s)[/color]" % [diffColor, ("+" if diffPercent > 0.0 else ""), diffPercent, arrow]

static func FormatModifierValue(effect : Modifier, value : Variant) -> String:
	match effect:
		Modifier.CritRate, Modifier.DodgeRate, Modifier.Penetration, Modifier.DeadlyChance:
			var floatVal : float = float(value) * 100.0
			return ("+" if floatVal >= 0.0 else "") + ("%.2f" % floatVal) + "%"
		Modifier.CastDelay, Modifier.CooldownDelay:
			var floatVal : float = float(value)
			return ("+" if floatVal >= 0.0 else "") + ("%.2f" % floatVal) + "s"
		_:
			var intVal : int = int(value)
			return ("+" if intVal >= 0 else "") + str(intVal)
