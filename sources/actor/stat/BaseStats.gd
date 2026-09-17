extends RefCounted
class_name BaseStats

# Base Stats
var weightCapacity : float				= 10.0
var walkSpeed : float					= 100.0

var attack : int						= 10
var defense : int						= 5
var mattack : int						= 10
var mdefense : int						= 5
var attackRange : int					= 32
var critRate : float					= 0.01
var dodgeRate : float					= 0.01
var castAttackDelay : float				= 0.7
var cooldownAttackDelay : float			= 0.5

var maxHealth : int						= 100
var maxStamina : int					= 50
var maxMana : int						= 50

var regenHealth : int					= 1
var regenStamina : int					= 1
var regenMana : int						= 1

# SOM-IDLE: elemental combat (ELEMENTAL_COMBAT.md). Flat elemental damage and
# resist %, mirror attack/defense (base value + gear, via Formula.Get*).
# Poison/Bleed/Burn chance+power live on equipment only, read straight off
# StatModifier at hit time — not cached here (see CellCommons.Modifier).
var fireDamage : int						= 0
var iceDamage : int						= 0
var lightningDamage : int				= 0
var fireResist : float					= 0.0
var iceResist : float					= 0.0
var lightningResist : float				= 0.0
var poisonResist : float					= 0.0
var bleedResist : float					= 0.0
