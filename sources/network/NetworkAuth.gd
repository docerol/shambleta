# SOM-IDLE P4 / Arquitetura: fragmentação de Network.gd (1011 linhas).
# Módulo de Autenticação — extraído de Network.gd conforme auditoria técnica.
# Objetivo: reduzir Network.gd para < 200 linhas por módulo; desbloquear testes E2E multiplayer.
# Referência: auditoria-tecnica-shambleta.md (§ Arquitetura 8/10 — fragmentação iniciada mas não concluída).
extends Node

# Auth RPCs — delegam diretamente ao transporte via facade (Network.gd) ou ao
# módulo server (Server.gd) conforme padrão existente. Durante a fragmentação,
# os handlers permanecem no server; o cliente apenas envia RPC.
# Os métodos abaixo são stubs de RPC para manter o protocolo; a lógica real
# está no server (sources/network/server/Server.gd).

@rpc("any_peer", "call_remote", "reliable", 0)  # EChannel.CONNECT
func CreateAccount(accountName: String, password: String, email: String, rememberMe: bool, consentAccepted: bool, platform: int = 0, peerID: int = 1) -> bool:
	# Delegação para facade Network (dispatcher) para manter compatibilidade.
	# O handler real está no server; este RPC apenas envia o pedido.
	return Network.CallServer("CreateAccount", [accountName, password, email, rememberMe, platform, consentAccepted], peerID, NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", 0)
func DeleteAccount(peerID: int = 1) -> bool:
	return Network.CallServer("DeleteAccount", [], peerID, NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", 0)
func AccountErased(peerID: int = -1):
	# Autoridade envia para cliente específico — usa facade CallClient se necessário,
	# mas como este é um módulo de cliente, apenas regista o sinal.
	Network.CallClient("AccountErased", [], peerID)

@rpc("any_peer", "call_remote", "reliable", 0)
func RequestRefund(idempotencyKey: String, peerID: int = 1) -> bool:
	return Network.CallServer("RequestRefund", [idempotencyKey], peerID, NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", 0)
func RefundResult(result: Dictionary, peerID: int = -1):
	Network.CallClient("RefundResult", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", 0)
func LoginWithPassword(accountName: String, password: String, rememberMe: bool, platform: int = 0, peerID: int = 1) -> bool:
	return Network.CallServer("LoginWithPassword", [accountName, password, rememberMe, platform], peerID, NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", 0)
func AuthError(err: int, peerID: int = -1):
	Network.CallClient("AuthError", [err], peerID)
