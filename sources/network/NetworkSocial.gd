# SOM-IDLE P4 / Arquitetura — Fragmentação de Network.gd (1011 linhas).
# Módulo Social / Guild — extraído de Network.gd conforme auditoria técnica.
# Objetivo: reduzir Network.gd; desbloquear testes multiplayer E2E; subir Arquitetura para >9.
extends Node

# Guild / Social RPCs (ex-Network.gd linhas 677-700+).
# Referência: sources/network/Network.gd (GetGuildState, GuildState, GuildFeedback, LevelUpGuildFast).
@rpc("any_peer", "call_remote", "reliable", 0)
func GetGuildState(peerID: int = 1) -> void:
	Network.CallServer("GetGuildState", [], peerID, NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", 0)
func GuildState(state: Dictionary, peerID: int = -1) -> void:
	# Autoridade envia para cliente; delega ao transporte.
	Network.CallClient("GuildState", [state], peerID)

func GuildFeedback(ok: bool, reason: String, peerID: int = -1) -> void:
	Network.CallClient("GuildFeedback", [ok, reason], peerID)

func LevelUpGuildFast(peerID: int = 1) -> bool:
	return Network.CallServer("LevelUpGuildFast", [], peerID, NetworkCommons.DelayConfig)
