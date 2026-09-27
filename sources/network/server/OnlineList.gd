extends RefCounted
class_name OnlineList

#
const JSONFileName : String				= "online.json"

# SOM-IDLE social (auditoria 2026-09-27 §SOCIAL "presença barata"): índice de
# presença em memória keyed por nick, atualizado incrementalmente nos mesmos dois
# eventos que já disparam o push global. Sem isto, "fulano da guild está online?"
# exigia varrer Peers.peers e reconstruir o array inteiro por membro — O(membros ×
# online). Com o dicionário, a consulta é O(1) e o painel de guild responde por
# linha sem varredura. É estado de processo: nasce vazio no boot e se preenche na
# primeira leva de conexões (OnPlayerConnected é chamado pelo fluxo de login).
static var byNick : Dictionary[String, bool] = {}

#
static func GetPlayerNames() -> PackedStringArray:
	var players : Array[String] = []
	for peerID in Peers.peers:
		var agent : PlayerAgent = Peers.GetAgent(peerID)
		if agent:
			players.append(agent.nick)
	return players

# Consulta O(1) de presença para o painel de guild/social. Não varre Peers nem
# reconstrói a lista — só bate no índice mantido pelos eventos de conexão.
static func IsPlayerOnline(playerName : String) -> bool:
	return byNick.has(playerName)

static func OnlineCount() -> int:
	return byNick.size()

static func UpdateJson(players : PackedStringArray):
	if not NetworkCommons.OnlineListPath.is_empty():
		FileSystem.SaveFile(NetworkCommons.OnlineListPath + "/" + JSONFileName, JSON.stringify(players))

static func OnPlayerConnected(playerName : String):
	byNick[playerName] = true
	UpdateJson(GetPlayerNames())
	Network.NotifyGlobal("AddOnlinePlayer", [playerName])

static func OnPlayerDisconnected(playerName : String):
	byNick.erase(playerName)
	UpdateJson(GetPlayerNames())
	Network.NotifyGlobal("RemoveOnlinePlayer", [playerName])
