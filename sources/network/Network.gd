# SOM-IDLE P4 / Passo 2: Network.gd reduzido para facade (dispatcher + transporte).
# Todos os RPCs foram fragmentados em módulos: NetworkAuth, NetworkSocial,
# NetworkCharacter, NetworkCombat, NetworkEconomy, NetworkGuild.
# Este arquivo mantém apenas: sinais, enum EChannel, transporte (Client/Server),
# CallServer/CallClient/Bulk, Notify* e modo. Nenhum @rpc permanece.
extends Node

#
signal peer_update
signal accounts_list_update
signal characters_list_update
signal online_accounts_update
signal online_characters_update
signal online_player_connected(playerName : String)
signal online_player_disconnected(playerName : String)

#
var Client = null
var WebRTCClient : NetClient = null
var ENetServer : NetServer = null
var WebSocketServer : NetServer = null
var WebRTCServer : NetServer = null
var webRTCActive : bool = false
var clientConnected : bool = false

enum EChannel
{
	CONNECT = 0,
	ACTION,
	MAP,
	MAP_UNRELIABLE,
	NAVIGATION,
	NAVIGATION_UNRELIABLE,
	ENTITY,
	ENTITY_UNRELIABLE,
	BULK,
	COUNT
}

# Service handling (transporte: ENet, WebSocket, WebRTC)
func Mode(isClient : bool, isServer : bool):
	var isOffline : bool = isClient and isServer
	if isClient:
		Client = NetClient.new(LauncherCommons.isWeb, false, isOffline, isOffline or NetworkCommons.IsLocal)
		if LauncherCommons.isWeb and NetworkCommons.UseWebRTC and not isOffline:
			WebRTCClient = NetClient.new(false, true, isOffline, isOffline or NetworkCommons.IsLocal)
	if isServer:
		if NetworkCommons.UseENet:
			ENetServer = NetServer.new(false, false, isOffline, NetworkCommons.IsLocal)
		if NetworkCommons.UseWebSocket and not isOffline:
			WebSocketServer = NetServer.new(true, false, isOffline, NetworkCommons.IsLocal)
		if NetworkCommons.UseWebRTC and not isOffline:
			WebRTCServer = NetServer.new(false, true, isOffline, NetworkCommons.IsLocal)

func _ready():
	# Fragmentos P4 são autoloads (singletons de engine); NetworkCommons/Util/
	# OnlineList são classes estáticas (class_name), não singletons.
	if Engine.has_singleton("NetworkAuth"):
		NetworkCommons.ProtocolVersion = NetworkCommons.ComputeProtocolVersion(self)

func _init():
	# Classes estáticas resolvem sempre (class_name); sem Engine.has_singleton.
	if NetworkCommons.RtcChannelsConfig.size() != EChannel.COUNT - 1:
		push_error("Mismatch RTC channel config count! Expected %d" % [EChannel.COUNT - 1])
	online_player_connected.connect(OnlineList.OnPlayerConnected)
	online_player_disconnected.connect(OnlineList.OnPlayerDisconnected)

func Destroy():
	webRTCActive = false
	clientConnected = false
	if Client:
		Client.Destroy()
		Client = null
	if WebRTCClient:
		WebRTCClient.Destroy()
		WebRTCClient = null
	if ENetServer:
		ENetServer.Destroy()
		ENetServer = null
	if WebSocketServer:
		WebSocketServer.Destroy()
		WebSocketServer = null
	if WebRTCServer:
		WebRTCServer.Destroy()
		WebRTCServer = null

# Peer calls (dispatcher — sem @rpc, apenas roteia para transporte)
func CallServer(methodName : StringName, args : Array, peerID : int, actionDelta : int = NetworkCommons.DelayDefault) -> bool:
	if not Peers.Footprint(peerID, methodName, actionDelta):
		return false
	if Client and not Client.isOffline:
		if webRTCActive and WebRTCClient:
			WebRTCClient.multiplayerAPI.rpc(NetworkCommons.PeerAuthorityID, self, methodName, args + [WebRTCClient.interfaceID])
		else:
			Client.multiplayerAPI.rpc(peerID, self, methodName, args + [Client.interfaceID])
	elif Peers.IsUsingWebRTC(peerID):
		WebRTCServer.callv.call_deferred(methodName, args + [peerID])
	elif Peers.IsUsingWebSocket(peerID):
		WebSocketServer.callv.call_deferred(methodName, args + [peerID])
	else:
		ENetServer.callv.call_deferred(methodName, args + [peerID])
	return true

func CallClient(methodName : StringName, args : Array, peerID : int):
	if WebRTCServer and not WebRTCServer.isOffline and Peers.IsUsingWebRTC(peerID):
		WebRTCServer.multiplayerAPI.rpc(peerID, self, methodName, args + [peerID])
	elif WebSocketServer and not WebSocketServer.isOffline and Peers.IsUsingWebSocket(peerID):
		WebSocketServer.multiplayerAPI.rpc(peerID, self, methodName, args + [peerID])
	elif ENetServer and not ENetServer.isOffline:
		ENetServer.multiplayerAPI.rpc(peerID, self, methodName, args + [peerID])
	elif Client:
		Client.callv.call_deferred(methodName, args + [peerID])

# Bulk RPC dispatcher
func BulkCall(methodName : StringName, bulkedArgs : Array, peerID : int = NetworkCommons.PeerOfflineID):
	if WebRTCServer and not WebRTCServer.isOffline and Peers.IsUsingWebRTC(peerID):
		WebRTCServer.multiplayerAPI.rpc(peerID, self, "BulkCall", [methodName, bulkedArgs])
	elif WebSocketServer and not WebSocketServer.isOffline and Peers.IsUsingWebSocket(peerID):
		WebSocketServer.multiplayerAPI.rpc(peerID, self, "BulkCall", [methodName, bulkedArgs])
	elif ENetServer and not ENetServer.isOffline:
		ENetServer.multiplayerAPI.rpc(peerID, self, "BulkCall", [methodName, bulkedArgs])
	else:
		for args in bulkedArgs:
			Client.callv.call_deferred(methodName, args + [peerID])

func Bulk(methodName : StringName, args : Array, peerID : int):
	if WebRTCServer and not WebRTCServer.isOffline and Peers.IsUsingWebRTC(peerID):
		WebRTCServer.Bulk(methodName, args, peerID)
	elif WebSocketServer and not WebSocketServer.isOffline and Peers.IsUsingWebSocket(peerID):
		WebSocketServer.Bulk(methodName, args, peerID)
	elif ENetServer:
		ENetServer.Bulk(methodName, args, peerID)

# Notificações de vizinhança / instância / área / global
func NotifyNeighbours(agent : BaseAgent, callbackName : StringName, args : Array, inclusive : bool = true, bulk : bool = false):
	if not agent:
		push_error("Agent is misintantiated, could not notify instance players with " + callbackName)
		return
	var currentagentRID : int = agent.get_rid().get_id()
	if inclusive and agent is PlayerAgent:
		Network.callv(callbackName, args + [agent.peerID])
	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
	if inst:
		for player in inst.players:
			if player != null and player != agent and player.peerID != NetworkCommons.PeerUnknownID:
				if ActorCommons.IsInvisibleToPlayers(agent):
					if player.visibleAgents.has(currentagentRID):
						player.visibleAgents.erase(currentagentRID)
						Network.Bulk("RemoveEntity", [currentagentRID], player.peerID)
					continue
				if NetworkCommons.IsAlwaysVisible(agent) or NetworkCommons.IsVisible(player.position, agent.position, player.visibilityHalfSize):
					if not player.visibleAgents.has(currentagentRID):
						player.visibleAgents[currentagentRID] = true
						Network.Bulk("FullUpdateEntity", [currentagentRID, agent.velocity, agent.position, agent.currentOrientation, agent.state, agent.currentSkillID, agent.stat.isRunning, NetworkCommons.FrameID()], player.peerID)
					if bulk:
						Network.Bulk(callbackName, args, player.peerID)
					else:
						Network.callv(callbackName, args + [player.peerID])
				elif player.visibleAgents.has(currentagentRID):
					player.visibleAgents.erase(currentagentRID)
					Network.Bulk("RemoveEntity", [currentagentRID], player.peerID)

func NotifyInstance(inst : WorldInstance, callbackName : StringName, args : Array, exclude : BaseAgent = null):
	if not inst:
		push_error("World instance is missing, could not notify instance players with " + callbackName)
		return
	for player in inst.players:
		if player != null and player != exclude:
			if player.peerID != NetworkCommons.PeerUnknownID:
				Network.callv(callbackName, args + [player.peerID])

func NotifyArea(area : WorldMap, callbackName : StringName, args : Array):
	for inst in area.instances.values():
		NotifyInstance(inst, callbackName, args)

func NotifyGlobal(callbackName : StringName, args : Array):
	for areaIdx in Launcher.World.areas:
		var area = Launcher.World.areas[areaIdx]
		NotifyArea(area, callbackName, args)
