extends RefCounted
class_name Experience

# SOM-IDLE: F2 idle progression — hardcoded table replaced by formula
# Contract: TECH_SPEC_CORE.md §1 + XP_PROGRESSION.md §4/§4.2
# THIS FILE IS ONLY THE XP-THRESHOLD TABLE. The curve, measured from
# GetNeededExperienceForNextLevel, is XP(L -> L+1) = round(8000 * 1.22^L) with
# XpBase=8000 and Growth=1.22, so L1->L2 = 9760 and clearing MAX_LEVEL=60 costs
# 5523999861 XP total. At/above MAX_LEVEL the table returns MAX_LEVEL_REACHED (0)
# and the level simply stops. This file computes no income, no zone saturation and
# no real-time pacing; the cap's XP->essence conversion is done by
# Stats.AddExperience (sources/actor/Stats.gd:244), not here. Cumulative to the cap
# of 60 is ~5.5e9, ~9 orders of magnitude below int64 max, so the cache is always
# int64-safe at the levels the cap allows.

const MAX_LEVEL_REACHED : int = 0

const MAX_LEVEL : int = 60
const XpBase : int = 8000
const Growth : float = 1.22

# Per-level and cumulative caches (computed lazily, deterministic)
static var _neededCache : Dictionary[int, int]	= {}
static var _totalCache : Dictionary[int, int]	= {}

#
static func GetNeededExperienceForNextLevel(currentLevel : int) -> int:
	if currentLevel < 1 or IsMaxLevel(currentLevel):
		return MAX_LEVEL_REACHED

	var cached : int = _neededCache.get(currentLevel, 0)
	if cached > 0:
		return cached

	# int64-safe: max value at L149 is ~5.9e16 (<< 9.2e18)
	var needed : int = roundi(XpBase * pow(Growth, currentLevel))
	_neededCache[currentLevel] = needed
	return needed

# Cumulative XP needed to reach `level` starting from level 1 (0 for level <= 1)
static func GetTotalExperienceForLevel(level : int) -> int:
	if level <= 1:
		return 0

	var cached : int = _totalCache.get(level, -1)
	if cached >= 0:
		return cached

	# Extend from the highest cached ancestor to keep amortized O(1)
	var start : int = 2
	var total : int = 0
	for probe in range(level, 1, -1):
		if _totalCache.has(probe):
			total = _totalCache[probe]
			start = probe + 1
			break

	for iter in range(start, level + 1):
		total += GetNeededExperienceForNextLevel(iter - 1)
		_totalCache[iter] = total
	return total

# 0.0..1.0 progress of `experience` towards `level`+1 (1.0 at max level) — used by the UI bar
static func GetLevelProgress(experience : int, level : int) -> float:
	if IsMaxLevel(level):
		return 1.0
	var needed : int = GetNeededExperienceForNextLevel(level)
	if needed == MAX_LEVEL_REACHED:
		return 1.0
	return clampf(float(experience) / float(needed), 0.0, 1.0)

static func IsMaxLevel(level : int) -> bool:
	return level >= MAX_LEVEL
