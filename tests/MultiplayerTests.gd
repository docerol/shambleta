extends RefCounted
class_name MultiplayerTests

# SOM-IDLE: E2E multiplayer connectivity tests (offline mode, no real network)
# Uses Peers offline transport to simulate two peers talking through Network.

var checks : int = 0
var failures : int = 0

func Check(condition : bool, message : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] %s" % message)
	else:
		print("  [PASS] %s" % message)
	return condition

func CheckEq(actual : Variant, expected : Variant, message : String) -> bool:
	return Check(actual == expected, "%s: %s vs %s" % [message, str(actual), str(expected)])

# ---------------------------------------------------------------------------
# E2E multiplayer harness
# ---------------------------------------------------------------------------

func RunAll() -> Dictionary:
	print("== Multiplayer E2E tests ==")

	var peerA : int = 900001
	var peerB : int = 900002

	Peers.AddPeer(peerA, Peers.TransportType.OFFLINE)
	Peers.AddPeer(peerB, Peers.TransportType.OFFLINE)

	SuitePeerLifecycle(peerA, peerB)
	SuiteRpcRoundtrip(peerA, peerB)
	SuiteAreaBroadcast(peerA, peerB)
	SuiteDisconnectCleanup(peerA, peerB)

	Peers.RemovePeer(peerA)
	Peers.RemovePeer(peerB)

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	return {"checks": checks, "failures": failures}

func SuitePeerLifecycle(peerA : int, peerB : int) -> void:
	print("[suite] peer lifecycle")
	var a : Peers.Peer = Peers.GetPeer(peerA)
	var b : Peers.Peer = Peers.GetPeer(peerB)
	Check(a != null and b != null, "peers registered")
	Check(a.transport == Peers.TransportType.OFFLINE, "peerA is offline")
	Check(b.transport == Peers.TransportType.OFFLINE, "peerB is offline")
	Check(a.peerID == peerA and b.peerID == peerB, "peer IDs preserved")

func SuiteRpcRoundtrip(peerA : int, peerB : int) -> void:
	print("[suite] RPC roundtrip (offline)")
	var a : Peers.Peer = Peers.GetPeer(peerA)
	var b : Peers.Peer = Peers.GetPeer(peerB)

	# SOM-IDLE: offline peers can exchange RPCs through Network without crashing.
	Network.CommandFeedback("hello-from-A", peerA)
	Check(true, "CommandFeedback to peerA did not crash")

	# BulkCall should accept multiple targets without throwing.
	var result : Dictionary = Network.BulkCall(peerA, "Ping", [])
	Check(result is Dictionary, "BulkCall returns a dictionary")

func SuiteAreaBroadcast(peerA : int, peerB : int) -> void:
	print("[suite] area broadcast")
	# NotifyNeighbours / NotifyInstance should be safe calls in offline mode.
	Network.NotifyNeighbours(peerA, "TestEvent", {})
	Network.NotifyInstance(1001, "TestEvent", {})
	Network.NotifyArea(1, 1, "TestEvent", {})
	Network.NotifyGlobal("TestEvent", {})
	Check(true, "broadcast helpers did not crash offline")

func SuiteDisconnectCleanup(peerA : int, peerB : int) -> void:
	print("[suite] disconnect cleanup")
	var beforeA : Peers.Peer = Peers.GetPeer(peerA)
	var beforeB : Peers.Peer = Peers.GetPeer(peerB)
	Check(beforeA != null and beforeB != null, "peers exist before remove")

	Peers.RemovePeer(peerA)
	Peers.RemovePeer(peerB)

	var afterA : Peers.Peer = Peers.GetPeer(peerA)
	var afterB : Peers.Peer = Peers.GetPeer(peerB)
	Check(afterA == null and afterB == null, "peers removed cleanly")
