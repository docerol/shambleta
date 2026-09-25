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
var Client							= null
var WebRTCClient : NetClient		= null
var ENetServer : NetServer			= null
var WebSocketServer : NetServer		= null
var WebRTCServer : NetServer		= null
var webRTCActive : bool				= false
var clientConnected : bool			= false

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

# Auth
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func CreateAccount(accountName : String, password : String, email : String, rememberMe : bool, consentAccepted : bool, platform : int = NetworkCommons.Platform.UNKNOWN, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("CreateAccount", [accountName, password, email, rememberMe, platform, consentAccepted], AuthPeerID(peerID), NetworkCommons.DelayLogin)

# SOM-IDLE LGPD: pedido de exclusão de conta (direito ao esquecimento) — só com
# sessão ativa. Server anonimiza os dados e derruba a conexão.
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func DeleteAccount(peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("DeleteAccount", [], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func AccountErased(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AccountErased", [], peerID)

# SOM-IDLE (1d) CDC art.49: pedido de reembolso de uma compra (chave de
# idempotência recebida no ato da compra). Só com sessão ativa (dono da conta).
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RequestRefund(idempotencyKey : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("RequestRefund", [idempotencyKey], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RefundResult(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RefundResult", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func LoginWithPassword(accountName : String, password : String, rememberMe : bool, platform : int = NetworkCommons.Platform.UNKNOWN, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("LoginWithPassword", [accountName, password, rememberMe, platform], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func TwoFactorSetupResult(qrURL : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TwoFactorSetupResult", [qrURL], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func TwoFactorRequired(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TwoFactorRequired", [], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func AuthError(err : NetworkCommons.AuthError, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AuthError", [err], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func LoginWithToken(accountName : String, token : String, platform : int = NetworkCommons.Platform.UNKNOWN, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("LoginWithToken", [accountName, token, platform], AuthPeerID(peerID), NetworkCommons.DelayLogin)

# SOM-IDLE S4: 2FA login step (after password validation).
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func LoginWithTwoFactor(accountName : String, token : String, platform : int = NetworkCommons.Platform.UNKNOWN, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("LoginWithTwoFactor", [accountName, token, platform], AuthPeerID(peerID), NetworkCommons.DelayLogin)

# SOM-IDLE S4: 2FA setup for admin/GM accounts.
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func SetupTwoFactor(peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("SetupTwoFactor", [], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func VerifyTwoFactorSetup(token : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("VerifyTwoFactorSetup", [token], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func DisableTwoFactor(password : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("DisableTwoFactor", [password], AuthPeerID(peerID), NetworkCommons.DelayLogin)

# SOM-IDLE M1: canal de estado do painel de 2FA (o cliente não lê o SQLite
# local para saber se a própria conta tem 2FA — o servidor responde). `note` é
# uma chave estável ("setup_ok", "wrong_password", ...) traduzida no GUI.
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func GetTwoFactorState(peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("GetTwoFactorState", [], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func TwoFactorState(enabled : bool, note : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TwoFactorState", [enabled, note], peerID)

# SOM-IDLE LGPD: re-accept updated agreements at login (server re-verifies).
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func AcceptConsent(accountName : String, password : String, token : String, rememberMe : bool, platform : int = NetworkCommons.Platform.UNKNOWN, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("AcceptConsent", [accountName, password, token, rememberMe, platform], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func AuthTokenResult(accountName : String, token : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AuthTokenResult", [accountName, token], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RequestPasswordReset(accountName : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("RequestPasswordReset", [accountName], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func ConfirmPasswordReset(accountName : String, code : String, newPassword : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("ConfirmPasswordReset", [accountName, code, newPassword], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func ChangePassword(currentPassword : String, newPassword : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("ChangePassword", [currentPassword, newPassword], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func DisconnectAccount(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("DisconnectAccount", [], AuthPeerID(peerID))

# Character
@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func CharacterInfo(info : Dictionary, equipment : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CharacterInfo", [info, equipment], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func CreateCharacter(charName : String, traits : Dictionary, attributes : Dictionary, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("CreateCharacter", [charName, traits, attributes], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func DeleteCharacter(charName : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("DeleteCharacter", [charName], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func ConnectCharacter(nickname : String, peerID : int = NetworkCommons.PeerAuthorityID) -> bool:
	return CallServer("ConnectCharacter", [nickname], AuthPeerID(peerID), NetworkCommons.DelayLogin)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func CharacterError(err : NetworkCommons.CharacterError, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CharacterError", [err], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func DisconnectCharacter(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("DisconnectCharacter", [], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func CharacterListing(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("CharacterListing", [], AuthPeerID(peerID))

# Online list
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RequestOnlineList(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RequestOnlineList", [], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RefreshOnlineList(players : PackedStringArray, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RefreshOnlineList", [players], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func AddOnlinePlayer(playerName : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AddOnlinePlayer", [playerName], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RemoveOnlinePlayer(playerName : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RemoveOnlinePlayer", [playerName], peerID)

# WebRTC signaling
@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RequestRtcUpgrade(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RequestRtcUpgrade", [], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RtcConfig(iceServers : Array, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RtcConfig", [iceServers], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RtcOffer(sdp : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RtcOffer", [sdp], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RtcAnswer(sdp : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RtcAnswer", [sdp], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.CONNECT)
func RtcCandidateToClient(media : String, index : int, candidateName : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RtcCandidateToClient", [media, index, candidateName], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RtcCandidateToServer(media : String, index : int, candidateName : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RtcCandidateToServer", [media, index, candidateName], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.CONNECT)
func RtcReady(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RtcReady", [], AuthPeerID(peerID))

# Respawn
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerRespawn(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerRespawn", [], AuthPeerID(peerID))

# Warp
@rpc("authority", "call_remote", "reliable", EChannel.MAP)
func WarpPlayer(mapID : int, playerPos : Vector2, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("WarpPlayer", [mapID, playerPos], peerID)

# Entities
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func PreloadEntity(agentRID : int, actorType : ActorCommons.Type, currentShape : int, nick : String, defaultState : ActorCommons.State, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("PreloadEntity", [agentRID, actorType, currentShape, nick, defaultState], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func PreloadPlayer(agentRID : int, spirit : int, currentShape : int, nick : String, level : int, health : int, hairstyle : int, haircolor : int, gender : ActorCommons.Gender, race : int, skintone : int, equipment : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("PreloadPlayer", [agentRID, spirit, currentShape, nick, level, health, hairstyle, haircolor, gender, race, skintone, equipment], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func RemoveEntity(agentRID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RemoveEntity", [agentRID], peerID)

# Tracker
@rpc("authority", "call_remote", "reliable", EChannel.MAP)
func DisplayProgressionTracker(label : String, value : int, maxValue : int, unit : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("DisplayProgressionTracker", [label, value, maxValue, unit], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.MAP)
func ClearProgressionTracker(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ClearProgressionTracker", [], peerID)

# Controls
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func DisplayActions(actions : PackedStringArray, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("DisplayActions", [actions], peerID)

# Notification
# authority: empurrão server→client. Como o corpo carrega o peerID de destino,
# qualquer client com "any_peer" faria o servidor entregar notificação arbitrária
# a qualquer outra sessão.
@rpc("authority", "call_remote", "unreliable_ordered", EChannel.MAP_UNRELIABLE)
func PushNotification(notif : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("PushNotification", [notif], peerID)

# Navigation
@rpc("any_peer", "call_remote", "unreliable_ordered", EChannel.NAVIGATION_UNRELIABLE)
func SetClickPos(pos : Vector2, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetClickPos", [pos], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.NAVIGATION)
func SetMovePos(pos : Vector2, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetMovePos", [pos], AuthPeerID(peerID), NetworkCommons.DelayInstant)

@rpc("authority", "call_remote", "unreliable_ordered", EChannel.ENTITY_UNRELIABLE)
func UpdateEntity(agentRID : int, velocity : Vector2, position : Vector2, frameID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdateEntity", [agentRID, velocity, position, frameID], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func FullUpdateEntity(agentRID : int, velocity : Vector2, position : Vector2, orientation : Vector2, agentState : ActorCommons.State, skillCastID : int, isRunning : bool, frameID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("FullUpdateEntity", [agentRID, velocity, position, orientation, agentState, skillCastID, isRunning, frameID], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.NAVIGATION)
func ClearNavigation(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClearNavigation", [], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func SetViewportSize(halfWidth : float, halfHeight : float, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetViewportSize", [halfWidth, halfHeight], AuthPeerID(peerID), NetworkCommons.DelayInstant)

# Emote
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerEmote(emoteID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerEmote", [emoteID], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.ACTION) 
func Emote(senderagentRID : int, emoteID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Emote", [senderagentRID, emoteID], peerID)

# Sit
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerSit(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerSit", [], AuthPeerID(peerID))

# Chat
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Express(agentRID : int, text : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Express", [agentRID, text], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerChat(channelName : String, text : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerChat", [channelName, text], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ChatQuery(channelName : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ChatQuery", [channelName], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ChatPlayer(channelName : String, callerName : String, text : String, agentRID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ChatPlayer", [channelName, callerName, text, agentRID], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ChatSystem(channelName : String, text : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ChatSystem", [channelName, text], peerID)

# Context
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ToggleContext(enable : bool, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ToggleContext", [enable], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ContextText(author : String, text : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ContextText", [author, text], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ContextThink(author : String, text : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ContextThink", [author, text], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ContextContinue(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ContextContinue", [], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ContextClose(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ContextClose", [], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ContextChoice(texts : PackedStringArray, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ContextChoice", [texts], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerChoice(choiceID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerChoice", [choiceID], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerCloseContext(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerCloseContext", [], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerNextContext(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerNextContext", [], AuthPeerID(peerID))

# Tutorial
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func HighlightUI(target : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("HighlightUI", [target], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func OpenUI(target : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("OpenUI", [target], peerID)

# Camera
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func CameraLookAt(pos : Vector2, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CameraLookAt", [pos], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func CameraReset(peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CameraReset", [], peerID)

# Interact
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerInteract(targetRID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerInteract", [targetRID], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerExplore(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerExplore", [], AuthPeerID(peerID))

# Combat
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func TriggerSkill(targetRID : int, skillID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerSkill", [targetRID, skillID], AuthPeerID(peerID), NetworkCommons.DelayShort)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func TargetAlteration(agentRID : int, targetRID : int, value : int, alteration : ActorCommons.Alteration, skillID : int, hasFeedback : bool, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TargetAlteration", [agentRID, targetRID, value, alteration, skillID, hasFeedback], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Casted(agentRID : int, skillID: int, cooldown : float, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Casted", [agentRID, skillID, cooldown], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ThrowProjectile(agentRID : int, targetPos : Vector2, skillID: int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ThrowProjectile", [agentRID, targetPos, skillID], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Morphed(agentRID : int, morphID : int, notifyMorphing : bool, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Morphed", [agentRID, morphID, notifyMorphing], peerID)

# Stats
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdatePublicStats(agentRID : int, level : int, health : int, maxHealth : int, hairstyle : int, haircolor : int, gender : ActorCommons.Gender, race : int, skintone : int, currentShape : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdatePublicStats", [agentRID, level, health, maxHealth, hairstyle, haircolor, gender, race, skintone, currentShape], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdatePrivateStats(experience : int, gp : int, mana : int, stamina : int, karma : int, weight : float, shape : int, spirit : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdatePrivateStats", [experience, gp, mana, stamina, karma, weight, shape, spirit], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdateAttributes(strength : int, vitality : int, agility : int, endurance : int, concentration : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdateAttributes", [strength, vitality, agility, endurance, concentration], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func TriggerSelect(agentRID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerSelect", [agentRID], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func SetAttributes(strength : int, vitality : int, agility : int, endurance : int, concentration : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetAttributes", [strength, vitality, agility, endurance, concentration], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func LevelUp(agentRID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("LevelUp", [agentRID], peerID)

# SOM-IDLE: F2 idle-spike RPCs (TECH_SPEC_CORE §5)
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SetFormation(slot : int, charID : int, skillLoadout : PackedInt64Array, autoPotionPct : float, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetFormation", [slot, charID, skillLoadout, autoPotionPct], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SetFarmZone(zoneID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetFarmZone", [zoneID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimOfflineSettle(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimOfflineSettle", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetAFKReport(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetAFKReport", [], AuthPeerID(peerID), NetworkCommons.DelayMinute)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetSeasonPass(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetSeasonPass", [], AuthPeerID(peerID), NetworkCommons.DelayMinute)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func AFKReport(report : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AFKReport", [report], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func FarmZoneFeedback(zoneID : int, ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("FarmZoneFeedback", [zoneID, ok, reason], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func SeasonPassState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("SeasonPassState", [state], peerID)

# SOM-IDLE: F3 — VIP state, power leaderboard, formation slot selector
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetVIPState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetVIPState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func VIPState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("VIPState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetLeaderboard(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetLeaderboard", [], AuthPeerID(peerID), NetworkCommons.DelayMinute)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Leaderboard(entries : Array, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Leaderboard", [entries], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SetFormationSlot(slot : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetFormationSlot", [slot], AuthPeerID(peerID), NetworkCommons.DelayConfig)

# SOM-IDLE beta GUI — janelas de economia (Shop/Chests/Leaderboard). Toda ação
# devolve EconomyState fresco: as janelas se atualizam sem re-poll.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetEconomyState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetEconomyState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func EconomyState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("EconomyState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func OpenChest(chestID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	# Burst de abertura é o fluxo normal (baús acumulam no settle) — delta curto.
	CallServer("OpenChest", [chestID], AuthPeerID(peerID), 1500)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ChestOpened(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ChestOpened", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyChests(count : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyChests", [count], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func PurchaseVIP(tier : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("PurchaseVIP", [tier], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ShopFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ShopFeedback", [ok, reason], peerID)

# Fase A (checkout sandbox): a loja pede a intenção p/ um SKU e recebe o
# external_reference + preço. O pagamento (sandbox simulate / MP prod) usa
# essa referência; o grant entra pelo grant_queue.
# Fase B (loja diária): rotação do dia + reroll pago + ofertas one-time.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetDailyShop(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetDailyShop", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func DailyShop(shop : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("DailyShop", [shop], peerID)

# R1 referral: estado do código + vínculo (conta da sessão; 72h p/ informar).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetReferralState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetReferralState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ReferralState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ReferralState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SetReferralCode(code : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetReferralCode", [code], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyDailyOffer(offerID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyDailyOffer", [offerID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

# R2 vendor gold: consumíveis por gold (preço e estoque server-side).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyVendorOffer(offerID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyVendorOffer", [offerID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

# R3 live events: estado de eventos ativos (banner + modificadores).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetActiveEvents(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetActiveEvents", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ActiveEvents(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ActiveEvents", [state], peerID)

# R4 async arena: defesa salva + ataque por ticket + board.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ArenaSetDefense(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ArenaSetDefense", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ArenaDefenseResult(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ArenaDefenseResult", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ArenaAttack(defenderAccountID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ArenaAttack", [defenderAccountID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ArenaAttackResult(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ArenaAttackResult", [result], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ArenaBoard(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ArenaBoard", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func ArenaBoardResult(board : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ArenaBoardResult", [board], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func RerollDailyShop(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RerollDailyShop", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

# Fase C (passe S1, BATTLE_PASS_S1 §7): estado, claim de recompensa/missão,
# compra do premium via intent do companion e skip de nível.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimPassReward(level : int, track : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimPassReward", [level, track], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyPass(tier : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyPass", [tier], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SkipPassLevel(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SkipPassLevel", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimMission(missionID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimMission", [missionID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func PassFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("PassFeedback", [ok, reason], peerID)

# Fase D (cosméticos, MONETIZATION §2.4/§2.7): coleção, equipar e vitrine.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetCosmetics(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetCosmetics", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Cosmetics(data : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Cosmetics", [data], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func EquipCosmetic(cosmeticID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("EquipCosmetic", [cosmeticID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func UnequipCosmetic(slot : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("UnequipCosmetic", [slot], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyCosmetic(cosmeticID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyCosmetic", [cosmeticID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func CosmeticFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CosmeticFeedback", [ok, reason], peerID)

# Hub Atividades (GUI sem fricção; mesmos backends dos comandos /ach /torment
# /rush /corrupt /cube /salvage — resultados saem no chat + pushes de estado).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetAchievements(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetAchievements", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func AchievementsState(state : Array, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AchievementsState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimAchievement(achievementID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimAchievement", [achievementID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetTorment(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetTorment", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func TormentState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TormentState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SetTorment(level : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SetTorment", [level], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func RunBossRush(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RunBossRush", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyBossKey(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyBossKey", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func CorruptItem(itemID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("CorruptItem", [itemID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func CubeUpcycle(itemID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("CubeUpcycle", [itemID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SalvageItem(itemID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SalvageItem", [itemID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

# Fase E (rewarded ads, MONETIZATION §2.5): 4 placements opt-in. O token vem
# do AdProvider (stub agora, SDK depois); o servidor valida e credita.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func WatchAd(placement : String, token : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("WatchAd", [placement, token], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimAdChest(token : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimAdChest", [token], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func RerollDailyShopAd(token : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RerollDailyShopAd", [token], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ClaimAdBossKey(token : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("ClaimAdBossKey", [token], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func AdFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("AdFeedback", [ok, reason], peerID)

# Fase F (guild premium + torneios): estado da guild, level-up fast, vault
# slots, copas semanais.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetGuildState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetGuildState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func GuildState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("GuildState", [state], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func GuildFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("GuildFeedback", [ok, reason], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func LevelUpGuildFast(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("LevelUpGuildFast", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyVaultSlots(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyVaultSlots", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetTournaments(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetTournaments", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func Tournaments(data : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("Tournaments", [data], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func EnterTournament(tournamentID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("EnterTournament", [tournamentID], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func TournamentFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("TournamentFeedback", [ok, reason], peerID)
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetCheckoutIntent(sku : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetCheckoutIntent", [sku], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func CheckoutIntent(intent : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CheckoutIntent", [intent], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetSeasonBoards(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetSeasonBoards", [], AuthPeerID(peerID), NetworkCommons.DelayMinute)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func SeasonBoards(data : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("SeasonBoards", [data], peerID)

# SOM-IDLE: boss-key ladder (janela Boss). ChallengeBoss devolve BossResult e
# depois BossState fresco (chaves/progresso mudam a cada tentativa).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetBossState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetBossState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func BossState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("BossState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func ChallengeBoss(peerID : int = NetworkCommons.PeerAuthorityID):
	# Sem burst: o desafio gasta uma chave e resolve a luta numa tacada.
	CallServer("ChallengeBoss", [], AuthPeerID(peerID), 1500)

# SOM-IDLE: mecânica ativa do duelo (2026-09-23). Toque do jogador na janela de
# interrupt; a resolução (janela aberta? dano?) acontece server-side no tick.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BossInterrupt(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BossInterrupt", [], AuthPeerID(peerID), 200)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func BossInterruptWindow(open : bool, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("BossInterruptWindow", [open], peerID)

# SOM-IDLE: veredito do toque (quality perfect/good/miss + mult) p/ o banner.
@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func BossInterruptFeedback(quality : String, mult : float, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("BossInterruptFeedback", [quality, mult], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func BossResult(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("BossResult", [result], peerID)

# SOM-IDLE: rebirth (híbrido B+C). Painel pede estado ao abrir; RebirthNow/Buy
# devolvem RebirthResult e depois RebirthState fresco (essência/custos mudam).
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func GetRebirthState(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("GetRebirthState", [], AuthPeerID(peerID), NetworkCommons.DelayConfig)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func RebirthState(state : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RebirthState", [state], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func RebirthNow(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RebirthRequest", [], AuthPeerID(peerID), 1500)

@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func BuyRebirthUpgrade(upgradeID : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("BuyRebirthUpgrade", [upgradeID], AuthPeerID(peerID), 1500)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func RebirthResult(result : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RebirthResult", [result], peerID)

# SOM-IDLE Fase H: criação de itens (ITEM_CRAFTING.md §2). Cliente submette o
# item + nome + modifiers; o servidor valida orçamento, taxa em gold, nome e
# daily cap, grava a submissão como pending. Aprovação/rejeição é feita por GM
# (WorldCommands SubmitCraftReview) — fora do escopo deste RPC.
@rpc("any_peer", "call_remote", "reliable", EChannel.ACTION)
func SubmitCraft(slot : int, baseItemHash : int, name : String, modifiers : Dictionary, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("SubmitCraft", [slot, baseItemHash, name, modifiers], AuthPeerID(peerID), 1500)

@rpc("authority", "call_remote", "reliable", EChannel.ACTION)
func CraftSubmitFeedback(ok : bool, reason : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CraftSubmitFeedback", [ok, reason], peerID)

# Inventory
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func ItemAdded(itemID : int, customfield : StringName, count : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ItemAdded", [itemID, customfield, count], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func ItemRemoved(itemID : int, customfield : StringName, count : int, itemIndex : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ItemRemoved", [itemID, customfield, count, itemIndex], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func ItemEquiped(agentRID : int, itemID : int, customfield : StringName, state : bool, itemIndex : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("ItemEquiped", [agentRID, itemID, customfield, state, itemIndex], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func UseItem(itemID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("UseItem", [itemID], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func DropItem(itemID : int, customfield : StringName, itemCount : int, itemIndex : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("DropItem", [itemID, customfield, itemCount, itemIndex], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func EquipItem(itemID : int, customfield : StringName, itemIndex : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("EquipItem", [itemID, customfield, itemIndex], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func UnequipItem(itemID : int, customfield : StringName, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("UnequipItem", [itemID, customfield], AuthPeerID(peerID))

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func RetrieveInventory(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RetrieveInventory", [], AuthPeerID(peerID))

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func RefreshInventory(cells : Array[Dictionary], peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RefreshInventory", [cells], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func RefreshEquipment(agentRID : int, equipment : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RefreshEquipment", [agentRID, equipment], peerID)

# Drop
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func DropAdded(dropID : int, itemID : int, customfield : StringName, pos : Vector2, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("DropAdded", [dropID, itemID, customfield, pos], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func DropRemoved(dropID : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("DropRemoved", [dropID], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func PickupDrop(dropID : int, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("PickupDrop", [dropID], AuthPeerID(peerID))

# Progress
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdateSkill(skillID : int, level : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdateSkill", [skillID, level], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdateBestiary(mobID : int, count : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdateBestiary", [mobID, count], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func UpdateQuest(questID : int, state : int, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("UpdateQuest", [questID, state], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func RefreshProgress(skills : Dictionary, quests : Dictionary, bestiary : Dictionary, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("RefreshProgress", [skills, quests, bestiary], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func RetrieveCharacterInformation(peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("RetrieveCharacterInformation", [], AuthPeerID(peerID))

# Commands
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func CommandFeedback(feedback : String, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CommandFeedback", [feedback], peerID)

@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
func CommandModifier(effect : CellCommons.Modifier, value : float, peerID : int = NetworkCommons.PeerOfflineID):
	CallClient("CommandModifier", [effect, value], peerID)

@rpc("any_peer", "call_remote", "reliable", EChannel.ENTITY)
func TriggerCommand(command : String, peerID : int = NetworkCommons.PeerAuthorityID):
	CallServer("TriggerCommand", [command], AuthPeerID(peerID))

# Bulk RPC calls
@rpc("authority", "call_remote", "reliable", EChannel.ENTITY)
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

# Notify peers
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

# Peer calls
# S1: identidade do chamador NUNCA vem do corpo do pacote — quem escreve o
# pacote escolhe o peerID. Dentro do processamento de um RPC recebido, exatamente
# uma interface de servidor reporta o sender real do transporte; as outras e
# qualquer chamada fora desse contexto reportam 0. Sem borda de rede (offline /
# servidor local) não há o que falsificar: o valor informado fica.
func TransportSenderID() -> int:
	for iface : NetServer in [WebRTCServer, WebSocketServer, ENetServer]:
		if iface and iface.multiplayerAPI and iface.multiplayerAPI.has_multiplayer_peer():
			var sender : int = iface.multiplayerAPI.get_remote_sender_id()
			if sender != 0:
				return sender
	return NetworkCommons.PeerUnknownID

func AuthPeerID(declared : int) -> int:
	var sender : int = TransportSenderID()
	return declared if sender == NetworkCommons.PeerUnknownID else sender

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

# Service handling
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
	NetworkCommons.ProtocolVersion = NetworkCommons.ComputeProtocolVersion(self)

func _init():
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
