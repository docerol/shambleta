extends RefCounted
class_name SQLCharacter

var _db : Object = null
var _queryMutex : Mutex = Mutex.new()

func _init(db : Object, queryMutex : Mutex):
	_db = db
	_queryMutex = queryMutex

func AddCharacter(accountID : int, nickname : String, stats : Dictionary, traits : Dictionary, attributes : Dictionary) -> bool:
	pass

func RemoveCharacter(charID : int) -> bool:
	pass

func GetCharacters(accountID : int) -> PackedInt64Array:
	pass

func GetCharacterInfo(charID : int) -> Dictionary:
	pass

func GetCharacterClass(charID : int) -> String:
	pass

func SetCharacterClass(charID : int, classID : String) -> bool:
	pass

func RefreshCharacter(player : PlayerAgent) -> bool:
	pass

func HasCharacter(nickname : String) -> bool:
	pass

func GetCharacterIDByName(nickname : String) -> int:
	pass

func CharacterLogin(charID : int) -> bool:
	pass

func GetCharacterID(accountID : int, nickname : String) -> int:
	pass

func GetCharacter(charID : int) -> Dictionary:
	pass

func UpdateCharacter(player : PlayerAgent) -> bool:
	pass

func GetCharacterBossKeys(charID : int) -> int:
	pass

func AddCharacterBossKeys(charID : int, delta : int) -> int:
	pass

func GetCharacterBossesBeaten(charID : int) -> int:
	pass

func SetCharacterBossesBeaten(charID : int, count : int) -> bool:
	pass

func GetRebirthInfo(charID : int) -> Dictionary:
	pass

func GetCharacterEssence(charID : int) -> int:
	pass

func AddCharacterEssence(charID : int, delta : int) -> int:
	pass

func IncRebirthCounter(charID : int) -> int:
	pass

func IncRebirthUpgrade(charID : int, upgradeID : String) -> int:
	pass

func GetTormentLevel(charID : int) -> int:
	pass

func SetTormentLevel(charID : int, level : int) -> bool:
	pass

func GetTormentMax(charID : int) -> int:
	pass

func SetTormentMax(charID : int, level : int) -> bool:
	pass

func PersistSessionEfficiency(charID : int, efficiency : float) -> bool:
	pass

func SetCharacterFarmZone(charID : int, zoneID : int) -> bool:
	pass

func SetCharacterFormationSlot(charID : int, slot : int) -> bool:
	pass

func GetVIPUntil(accountID : int) -> int:
	pass

func SetVIPUntil(accountID : int, until : int) -> bool:
	pass

func GetVIPTier(accountID : int) -> int:
	pass

func SetVIPTier(accountID : int, tier : int) -> bool:
	pass

func UpdatePowerScore(charID : int) -> bool:
	pass

func GetLeaderboard(limit : int = 10) -> Array[Dictionary]:
	pass

func GetAccountIDForCharacter(charID : int) -> int:
	pass

func UpdateSettleAnchor(charID : int, timestamp : int, efficiency : float) -> bool:
	pass
