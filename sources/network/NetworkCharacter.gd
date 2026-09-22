# SOM-IDLE P4 / Passo 2: módulo de personagem — autocontido.
# Todos os RPCs delegam diretamente ao transporte (facade Network.gd) via CallServer/CallClient.
# Nenhum método removido de Network.gd original; agora o módulo é fonte única.
extends Node

@rpc("authority", "call_remote", "reliable", 0)  # EChannel.CONNECT
func CharacterInfo(info: Dictionary, equipment: Dictionary, peerID: int = 1):
	Network.CallClient("CharacterInfo", [info, equipment], peerID)

@rpc("any_peer", "call_remote", "reliable", 0)
func CreateCharacter(charName: String, traits: Dictionary, attributes: Dictionary, peerID: int = 1) -> bool:
	return Network.CallServer("CreateCharacter", [charName, traits, attributes], peerID, NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", 0)
func DeleteCharacter(charName: String, peerID: int = 1) -> bool:
	return Network.CallServer("DeleteCharacter", [charName], peerID, NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", 0)
func ConnectCharacter(nickname: String, peerID: int = 1) -> bool:
	return Network.CallServer("ConnectCharacter", [nickname], peerID, NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", 0)
func CharacterError(err: int, peerID: int = -1):
	Network.CallClient("CharacterError", [err], peerID)

@rpc("any_peer", "call_remote", "reliable", 0)
func DisconnectCharacter(peerID: int = 1):
	Network.CallServer("DisconnectCharacter", [], peerID)

@rpc("any_peer", "call_remote", "reliable", 0)
func CharacterListing(peerID: int = 1):
	Network.CallServer("CharacterListing", [], peerID)
