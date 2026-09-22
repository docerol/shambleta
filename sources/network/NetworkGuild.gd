# SOM-IDLE P4 / Passo 2: módulo guild — autocontido.
extends Node

@rpc("any_peer", "call_remote", "reliable", 1)
func GetGuildState(peerID: int = 1) -> void:
	Network.CallServer("GetGuildState", [], peerID, NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", 1)
func GuildState(state: Dictionary, peerID: int = -1) -> void:
	Network.CallClient("GuildState", [state], peerID)

func GuildFeedback(ok: bool, reason: String, peerID: int = -1) -> void:
	Network.CallClient("GuildFeedback", [ok, reason], peerID)

@rpc("any_peer", "call_remote", "reliable", 1)
func LevelUpGuildFast(peerID: int = 1) -> bool:
	return Network.CallServer("LevelUpGuildFast", [], peerID, NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", 1)
func BuyVaultSlots(peerID: int = 1) -> bool:
	return Network.CallServer("BuyVaultSlots", [], peerID, NetworkCommons.DelayConfig)
