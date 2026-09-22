# SOM-IDLE P4 / Passo 2: módulo de economia — autocontido.
# Delegações removidas; usa facade (CallServer/CallClient) diretamente.
extends Node

@rpc("any_peer", "call_remote", "reliable", 1)
func GetEconomyState(peerID: int = 1):
	Network.CallServer("GetEconomyState", [], peerID, NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", 1)
func EconomyState(state: Dictionary, peerID: int = -1):
	Network.CallClient("EconomyState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", 1)
func OpenChest(chestID: int, peerID: int = 1):
	Network.CallServer("OpenChest", [chestID], peerID, 1500)

@rpc("authority", "call_remote", "reliable", 1)
func ChestOpened(result: Dictionary, peerID: int = -1):
	Network.CallClient("ChestOpened", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", 1)
func BuyChests(count: int, peerID: int = 1):
	Network.CallServer("BuyChests", [count], peerID, NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", 1)
func PurchaseVIP(tier: int, peerID: int = 1):
	Network.CallServer("PurchaseVIP", [tier], peerID, NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", 1)
func GetGuildState(peerID: int = 1):
	Network.CallServer("GetGuildState", [], peerID, NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", 1)
func GuildState(state: Dictionary, peerID: int = -1):
	Network.CallClient("GuildState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", 1)
func LevelUpGuildFast(peerID: int = 1):
	Network.CallServer("LevelUpGuildFast", [], peerID, NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", 1)
func GetAchievements(peerID: int = 1):
	Network.CallServer("GetAchievements", [], peerID, NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", 1)
func AchievementsState(state: Array, peerID: int = -1):
	Network.CallClient("AchievementsState", [state], peerID)
