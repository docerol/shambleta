extends RefCounted
class_name Peers

#
static var DisconnectedAccount : AccountData = AccountData.new(NetworkCommons.PeerUnknownID, ActorCommons.Permission.NONE)

enum TransportType { OFFLINE, ENET, WEBSOCKET, WEBRTC }

#
class AccountData:
	extends RefCounted

	var accountID : int								= NetworkCommons.PeerUnknownID
	var permission : ActorCommons.Permission		= ActorCommons.Permission.NONE

	func _init(id : int, newPermission : ActorCommons.Permission):
		accountID = id
		permission = newPermission

class Peer:
	extends RefCounted

	var accountID : int								= NetworkCommons.PeerUnknownID
	var peerID : int								= NetworkCommons.PeerUnknownID
	var characterID : int							= NetworkCommons.PeerUnknownID
	var agentRID : int								= NetworkCommons.PeerUnknownID
	var permission : ActorCommons.Permission		= ActorCommons.Permission.NONE
	var accountData : AccountData					= null
	var transport : Peers.TransportType				= Peers.TransportType.OFFLINE
	var ipAddress : String							= ""
	var primaryConnected : bool						= false
	var rtcConnected : bool							= false
	var rpcDeltas : Dictionary[StringName, int]		= {}
	# SOM-IDLE S4: pending 2FA verification (stores accountName until token is validated).
	var pendingTwoFactorAccount : String			= ""
	# SOM-IDLE beta (T9): carimbo do desafio (expiração TwoFactorChallengeSec).
	var pendingTwoFactorAt : int				= 0

	func _init(id : int, peerTransport : Peers.TransportType):
		peerID = id
		transport = peerTransport

	func SetAccount(data : AccountData):
		if data and data.accountID != NetworkCommons.PeerUnknownID:
			var lastPeerID = Peers.accounts.get(data.accountID, NetworkCommons.PeerUnknownID)
			if lastPeerID != NetworkCommons.PeerUnknownID and Peers.GetAccount(lastPeerID) != NetworkCommons.PeerUnknownID:
				Network.DisconnectAccount(lastPeerID)
				if data.accountID == lastPeerID:
					Network.AuthError(NetworkCommons.AuthError.ERR_DUPLICATE_CONNECTION, lastPeerID)
			Peers.accounts[data.accountID] = NetworkCommons.PeerUnknownID
		if data:
			Peers.accounts[data.accountID] = peerID
			accountID = data.accountID
			permission = data.permission
		Network.online_accounts_update.emit()

	func SetCharacter(id : int):
		characterID = id
		Network.online_characters_update.emit()

	func SetAgent(id : int):
		agentRID = id

static var peers : Dictionary[int, Peer]			= {}
static var accounts : Dictionary[int, int]			= {}
static var bannedAccounts : Dictionary[int, int]	= {}
static var bannedIPRanges : Dictionary[String, String]	= {}

# Moderation
static func IsBanned(accountID : int) -> bool:
	var unbanTimestamp : int = bannedAccounts.get(accountID, 0)
	if unbanTimestamp > 0:
		if unbanTimestamp > int(Time.get_unix_time_from_system()):
			return true
		bannedAccounts.erase(accountID)
	return false

static func IsIPBanned(ip : String) -> bool:
	if ip.is_empty():
		return false
	for ipRange in bannedIPRanges:
		if NetworkCommons.IsIPInRange(ip, ipRange):
			return true
	return false

# Handling
static func AddPeer(peerID : int, transport : TransportType):
	if peerID not in peers:
		peers[peerID] = Peer.new(peerID, transport)
		Network.peer_update.emit()

static func SetTransport(peerID : int, transport : TransportType):
	var peer : Peers.Peer = GetPeer(peerID)
	if peer:
		peer.transport = transport

static func RemovePeer(peerID : int):
	var peer : Peers.Peer = GetPeer(peerID)
	if peer:
		peers.erase(peerID)
		Network.peer_update.emit()

static func Footprint(peerID : int, methodName : StringName, actionDelta : int) -> bool:
	var peer : Peers.Peer = GetPeer(peerID)
	if peer:
		var oldTick : int = 0
		if methodName in peers[peerID].rpcDeltas:
			oldTick = peers[peerID].rpcDeltas[methodName]

		var currentTick : int = Time.get_ticks_msec()
		if oldTick + actionDelta <= currentTick:
			peers[peerID].rpcDeltas[methodName] = currentTick
			return true

	return false

static func GetTransport(peerID : int) -> TransportType:
	var peer : Peers.Peer = GetPeer(peerID)
	return peer.transport if peer else TransportType.OFFLINE

static func GetTransportName(transport : TransportType) -> String:
	match transport:
		TransportType.WEBRTC:
			return "WebRTC"
		TransportType.WEBSOCKET:
			return "WebSocket"
		TransportType.ENET:
			return "ENet"
		_:
			return "Offline"

static func IsUsingWebSocket(peerID : int) -> bool:
	return GetTransport(peerID) == TransportType.WEBSOCKET

static func IsUsingWebRTC(peerID : int) -> bool:
	return GetTransport(peerID) == TransportType.WEBRTC

static func GetAssociatedNetServer(peerID : int) -> NetServer:
	if HasPeer(peerID):
		match GetTransport(peerID):
			TransportType.WEBRTC:
				return Network.WebRTCServer
			TransportType.WEBSOCKET:
				return Network.WebSocketServer
			_:
				return Network.ENetServer
	return null

static func GetPeerIP(peerID : int) -> String:
	var peer : Peers.Peer = GetPeer(peerID)
	return peer.ipAddress if peer else ""

static func ResolvePeerIP(peerID : int) -> String:
	var peer : Peers.Peer = GetPeer(peerID)
	if peer:
		match peer.transport:
			TransportType.WEBSOCKET:
				if Network.WebSocketServer and Network.WebSocketServer.currentPeer:
					var packetPeer : PacketPeer = Network.WebSocketServer.currentPeer.get_peer(peerID)
					if packetPeer and packetPeer is WebSocketPeer:
						return packetPeer.get_connected_host()
			TransportType.ENET:
				if Network.ENetServer and Network.ENetServer.currentPeer:
					var packetPeer : PacketPeer = Network.ENetServer.currentPeer.get_peer(peerID)
					if packetPeer and packetPeer is ENetPacketPeer:
						return packetPeer.get_remote_address()
			TransportType.OFFLINE:
				return NetworkCommons.LocalServerAddress
	return ""

# Info getters
static func HasPeer(peerID : int) -> bool:
	return peerID in Peers.peers

static func GetPeer(peerID : int) -> Peers.Peer:
	return Peers.peers.get(peerID, null)

static func GetAccount(peerID : int) -> int:
	var peer : Peers.Peer = GetPeer(peerID)
	return peer.accountID if peer else NetworkCommons.PeerUnknownID

static func GetCharacter(peerID : int) -> int:
	var peer : Peers.Peer = GetPeer(peerID)
	return peer.characterID if peer else NetworkCommons.PeerUnknownID

static func GetAgent(peerID : int) -> PlayerAgent:
	var peer : Peers.Peer = GetPeer(peerID)
	return WorldAgent.GetAgent(peer.agentRID) if peer else null

static func GetPermission(peerID : int) -> ActorCommons.Permission:
	var peer : Peers.Peer = GetPeer(peerID)
	return peer.permission if peer else ActorCommons.Permission.NONE

# SOM-IDLE beta (T9): valida o desafio 2FA vinculado ao peer. Retorna o
# AuthError; o SUCESSO não finaliza o login (o chamador faz FinalizeLogin).
# Regras: sem desafio → NO_PEER_DATA; accountName != dono do desafio → AUTH
# (código válido p/ A nunca autentica B); desafio expirado → AUTH + consome;
# código errado → AUTH (desafio segue p/ retry rate-limited); código certo →
# OK + consome (replay posterior cai em NO_PEER_DATA).
static func ValidateTwoFactorChallenge(peer : Peer, accountName : String, token : String) -> NetworkCommons.AuthError:
	if peer == null or peer.pendingTwoFactorAccount.is_empty():
		return NetworkCommons.AuthError.ERR_NO_PEER_DATA
	if accountName != peer.pendingTwoFactorAccount:
		return NetworkCommons.AuthError.ERR_AUTH
	if peer.pendingTwoFactorAt > 0 and int(Time.get_unix_time_from_system()) - peer.pendingTwoFactorAt > NetworkCommons.TwoFactorChallengeSec:
		peer.pendingTwoFactorAccount = ""
		peer.pendingTwoFactorAt = 0
		return NetworkCommons.AuthError.ERR_AUTH
	var accountID : int = Launcher.SQL.GetAccountID(accountName)
	if accountID == NetworkCommons.PeerUnknownID:
		return NetworkCommons.AuthError.ERR_AUTH
	var secret : String = Launcher.SQL.GetTwoFactorSecret(accountID)
	if secret.is_empty() or not TwoFactorAuth.VerifyTOTP(secret, token):
		return NetworkCommons.AuthError.ERR_AUTH
	if not Launcher.SQL.ConsumeTwoFactorToken(accountID, token):
		return NetworkCommons.AuthError.ERR_AUTH
	peer.pendingTwoFactorAccount = ""
	peer.pendingTwoFactorAt = 0
	return NetworkCommons.AuthError.ERR_OK

static func GetAccountName(accountID : int) -> String:
	return Launcher.SQL.GetAccountEmail(accountID) if accountID != NetworkCommons.PeerUnknownID else ""

# Auth validation
static func FinalizeLogin(peer : Peer, accountName : String, accountData : AccountData, platform : int, rememberMe : bool) -> NetworkCommons.AuthError:
	if IsBanned(accountData.accountID):
		return NetworkCommons.AuthError.ERR_BANNED

	if IsIPBanned(GetPeerIP(peer.peerID)):
		return NetworkCommons.AuthError.ERR_BANNED

	peer.SetAccount(accountData)
	# SOM-IDLE S5: multi-account heuristic (best-effort, never fails login).
	# Checks for duplicate fingerprint hashes across accounts in telemetry.
	if Launcher.Telemetry:
		var fp : Dictionary = DeviceFingerprint.Collect()
		var fp_hash : String = str(fp.get("hash", ""))
		if not fp_hash.is_empty():
			Launcher.Telemetry.Record("login", accountData.accountID, 0, 1, "{}", fp)
		# S5: heurística multi-account (fail-safe: nunca falha o login; abre flag
		# na fila de revisão manual via EconomyService.FlagMultiAccount — o mesmo
		# fraud_flag das outras heurísticas, sem ban automático por design).
		# Sem try/except (GDScript não tem exceções): guards explícitos; a
		# heurística é best-effort e nunca bloqueia o login.
		var fp_for_heuristic : String = fp_hash if not fp_hash.is_empty() else str(fp.get("hash", ""))
		if not fp_for_heuristic.is_empty() and Launcher.SQL != null:
			var duplicate_rows : Array = Launcher.SQL.QueryBindings(
				"SELECT DISTINCT account_id FROM telemetry_event WHERE fingerprint LIKE ? AND account_id != ? AND created_at > ?;",
				["%\"hash\":\"" + fp_for_heuristic + "%", accountData.accountID, int(Time.get_unix_time_from_system()) - 86400 * 7])
			if duplicate_rows.size() > 1:
				push_warning("[S5 MultiAccount] Fingerprint hash=%s encontrado com %d outras contas (últimos 7d)" % [fp_for_heuristic, duplicate_rows.size()])
				if Launcher.Economy != null and Launcher.Economy.has_method("FlagMultiAccount"):
					var detail : String = "shared_fp:%s" % fp_for_heuristic
					Launcher.Economy.FlagMultiAccount(accountData.accountID, detail)
					var flagged : int = 0
					for dup in duplicate_rows:
						if flagged >= 10:
							break
						if dup is Dictionary and Launcher.Economy.FlagMultiAccount(int((dup as Dictionary).get("account_id", 0)), detail):
							flagged += 1
	if platform < 0 or platform >= NetworkCommons.Platform.COUNT:
		platform = NetworkCommons.Platform.UNKNOWN
	Launcher.SQL.UpdateAccount(peer.accountID, platform)

	if rememberMe:
		IssueAuthToken(peer, accountName)

	return NetworkCommons.AuthError.ERR_OK

static func IssueAuthToken(peer : Peer, accountName : String) -> void:
	var ipAddress : String = GetPeerIP(peer.peerID)
	var token : String = Hasher.GenerateSalt(Hasher.DefaultTokenSize)
	var tokenHash : String = Hasher.HashPassword(token)
	Launcher.SQL.AddAuthToken(peer.accountID, tokenHash, ipAddress)
	Network.AuthTokenResult(accountName, token, peer.peerID)
