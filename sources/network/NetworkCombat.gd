# SOM-IDLE P4 / Passo 2: módulo de combate — autocontido.
# Delegações removidas; usa facade (CallServer/CallClient) diretamente.
extends Node

@rpc("any_peer", "call_remote", "reliable", 1)  # EChannel.ACTION
func TriggerSkill(targetRID: int, skillID: int, peerID: int = 1):
	Network.CallServer("TriggerSkill", [targetRID, skillID], peerID, NetworkCommons.DelayShort)

@rpc("authority", "call_remote", "reliable", 1)
func TargetAlteration(agentRID: int, targetRID: int, value: int, alteration: int, skillID: int, hasFeedback: bool, peerID: int = -1):
	Network.CallClient("TargetAlteration", [agentRID, targetRID, value, alteration, skillID, hasFeedback], peerID)

@rpc("authority", "call_remote", "reliable", 1)
func Casted(agentRID: int, skillID: int, cooldown: float, peerID: int = -1):
	Network.CallClient("Casted", [agentRID, skillID, cooldown], peerID)

@rpc("authority", "call_remote", "reliable", 1)
func ThrowProjectile(agentRID: int, targetPos: Vector2, skillID: int, peerID: int = -1):
	Network.CallClient("ThrowProjectile", [agentRID, targetPos, skillID], peerID)

@rpc("authority", "call_remote", "reliable", 1)
func Morphed(agentRID: int, morphID: int, notifyMorphing: bool, peerID: int = -1):
	Network.CallClient("Morphed", [agentRID, morphID, notifyMorphing], peerID)

@rpc("authority", "call_remote", "reliable", 1)
func Express(agentRID: int, text: String, peerID: int = -1):
	Network.CallClient("Express", [agentRID, text], peerID)

@rpc("any_peer", "call_remote", "reliable", 1)
func TriggerChat(channelName: String, text: String, peerID: int = 1):
	Network.CallServer("TriggerChat", [channelName, text], peerID)

@rpc("authority", "call_remote", "reliable", 1)
func ChatQuery(channelName: String, peerID: int = -1):
	Network.CallClient("ChatQuery", [channelName], peerID)
