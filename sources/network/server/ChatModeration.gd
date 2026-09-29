extends RefCounted
class_name ChatModeration

# SOM-IDLE C1c (AUDITORIA_INDEPENDENTE §16 SOCIAL: "sem qualquer ferramenta de
# denúncia ou mute para o jogador"): estado de moderação do canal de chat, no servidor.
#
# O mute é cobrado no ENVIO, não no recebimento. Um cliente que recebe não é
# autoridade sobre si mesmo — "mute" aplicado no cliente é cosmético: o assediador
# continua falando para qualquer um com o jogo modificado. Expiração segue a regra
# do ban: sem timer nem trabalho periódico, o registro vence na primeira consulta
# depois do prazo.
#
# O buffer circular é o que transforma "ele me xingou" em algo conferível: a
# denúncia grava a linha que o SERVIDOR viu aquele account dizer, não o texto que
# o denunciante digitou. Ele é volátil de propósito — linha de chat é efêmera, e
# persistir tudo seria vigilância. O que sobrevive ao restart é a denúncia.

const LogMax : int			= 500
const ReportWindowSec : int = 600
const ReasonMax : int		= 200
const ExcerptMax : int		= 240

# SOM-IDLE social (auditoria 2026-09-27 §SOCIAL "chat sem canal de guild"): o
# canal de guild é um namespace no MESMO canal por string que LOCAL/GLOBAL/whisper
# já usam no cliente (Chat.gd cria aba para qualquer nome além dos fixos). Um canal
# de guild é "guild:<nome-da-guild>". Aqui vive a decisão de roteamento (reconhecer
# o prefixo, extrair o nome, enumerar e FANAR); `Server.TriggerChat` tem a linha que
# chama FanoutGuildChat, porque Server é o único chamador do primitivo de envio.
# Antes dessa linha o ramo não existia: a mensagem caía no `else` de whisper, não
# reach ninguém e o painel ainda dizia "Sent to guild channel." — um canal mentiroso.
const GuildChannelPrefix : String	= "guild:"

# É canal de guild? O roteador do Server usa isto antes de tratar o nome como
# LOCAL/GLOBAL/whisper.
static func IsGuildChannel(channel : String) -> bool:
	return channel.begins_with(GuildChannelPrefix)

# Nome da guild embutido no canal ("guild:Foo" → "Foo"); vazio se não for guild.
static func GuildNameOf(channel : String) -> String:
	if not IsGuildChannel(channel):
		return ""
	return channel.substr(GuildChannelPrefix.length())

# Monta o canal a partir do nome da guild (lado do painel/botão).
static func GuildChannelName(guildName : String) -> String:
	return GuildChannelPrefix + guildName.strip_edges()

# Destinatários de um chat de guild: os peers conectados dos membros da guild de
# quem fala, INCLUINDO o próprio falante — quem escreve precisa ver a própria linha
# no canal (é o comportamento do ramo de whisper, que ecoa para os dois lados).
# `Server.TriggerChat` chama FanoutGuildChat abaixo, que consome esta lista.
# Devolve [] se o falante não tem guild, se a Economy não montou ou se nenhuma
# sessão dos membros está viva.
static func ResolveGuildPeers(senderAccount : int) -> Array:
	var peers : Array = []
	if senderAccount <= 0:
		return peers
	var economy : EconomyService = Launcher.Economy if Launcher != null else null
	if economy == null:
		return peers
	var guildID : int = economy.GetGuildForAccount(senderAccount)
	if guildID == 0:
		return peers
	for memberAccount in economy.guildService.GetMemberAccounts(guildID):
		var accID : int = int(memberAccount)
		var peerID : int = int(Peers.accounts.get(accID, NetworkCommons.PeerUnknownID))
		if peerID != NetworkCommons.PeerUnknownID and Peers.peers.has(peerID):
			peers.append(peerID)
	return peers

# Nome REAL da guild do account (estado autoritativo — nunca o que veio no pacote).
static func GuildNameForAccount(accountID : int) -> String:
	if accountID <= 0:
		return ""
	var economy : EconomyService = Launcher.Economy if Launcher != null else null
	if economy == null:
		return ""
	var guildID : int = economy.GetGuildForAccount(accountID)
	if guildID == 0:
		return ""
	return str(economy.GetGuild(guildID).get("name", ""))

# Difusão do chat de guild: UMA chamada `ChatPlayer` por sessão resolvida — o mesmo
# primitivo do ramo de whisper, com o mesmo `channel` para todos, para que a aba do
# canal seja a mesma em cada cliente. O teto de tamanho (ClipChat) e o mute são
# cobrados ANTES, no roteador do Server, e valem daqui: quem passa por aqui já é uma
# linha autorizada. Devolve quantas sessões receberam; 0 é falha real de entrega
# (ninguém da guild online), não sucesso silencioso. O canal entregue é sempre o
# canônico da guild de quem fala: um cliente que escreve "guild:Rival" não fabrica
# aba de outra guild na tela dos outros — o namespace vem do estado autoritativo.
static func FanoutGuildChat(senderAccount : int, senderNick : String, channel : String, senderRID : int, text : String) -> int:
	var guildName : String = GuildNameForAccount(senderAccount)
	if guildName.is_empty():
		return 0
	var canonical : String = GuildChannelName(guildName)
	var delivered : int = 0
	for entry in ResolveGuildPeers(senderAccount):
		Network.ChatPlayer(canonical, senderNick, text, senderRID, int(entry))
		delivered += 1
	return delivered

# AUDITORIA 2026-09-28 (administração de guilda, decisão nº 5): o canal de guild é
# filiação, e filiação muda — um kick tira alguém da fileira com o chat já em voo. Esta
# é a cobrança na ENTREGA, chamada por `Network.ChatPlayer` (o único ponto por onde uma
# linha de jogador chega a uma sessão) ao lado de `SocialGraph.DeliveryBlocked`.
#
# Por que aqui e não só no fan-out: `ResolveGuildPeers` já desenha a lista de quem deve
# receber, e um kick anterior à chamada já a deixaria correta. O que esta função fecha é
# outra coisa — qualquer caminho que entregue num canal `guild:` (o fan-out de hoje, um
# push futuro de histórico, um reenvio de sistema) obedece à fileira atual, sem precisar
# lembrar de consultar `GetGuildForAccount`. É a mesma lição do mute: sanção aplicada só
# no caminho bonito é sanção decorativa.
#
# Fail-open por construção, com o mesmo criteriozinho do ignore: canal que não é de
# guild, falante que não é PlayerAgent (NPC), ponta sem conta (cliente puro, onde `Peers`
# não é populated — filtrar ali seria filtrar no cliente) e o eco do próprio falante todos
# passam. Um `false` aqui só acontece quando as duas contas existem e NÃO dividem guilda,
# ou quando quem recebe já não está na guilda que o canal nomeia.
static func GuildDeliveryAllowed(channel : String, senderRID : int, peerID : int) -> bool:
	if not IsGuildChannel(channel) or Launcher.Economy == null:
		return true
	var speaker : BaseAgent = WorldAgent.GetAgent(senderRID)
	if speaker == null or not (speaker is PlayerAgent):
		return true
	var senderAccount : int = Peers.GetAccount((speaker as PlayerAgent).peerID)
	var recipientAccount : int = Peers.GetAccount(peerID)
	if senderAccount <= 0 or recipientAccount <= 0 or senderAccount == recipientAccount:
		return true
	var senderGuild : int = Launcher.Economy.GetGuildForAccount(senderAccount)
	if senderGuild <= 0:
		# O falante saiu/foi chutado depois de a linha nascer: continua vendo a própria
		# fala (o eco é regra), mas canal de guild de quem não tem guild não entrega em
		# ninguém.
		return false
	return senderGuild == Launcher.Economy.GetGuildForAccount(recipientAccount)

static var muted : Dictionary[int, int] = {}
static var log : Array[Dictionary] = []

# Chamado pelo SQLService depois das migrations: o cache é o estado do processo,
# o banco é a memória durável.
static func Reset(newMutes : Dictionary[int, int]) -> void:
	muted = newMutes
	log.clear()

static func IsMuted(accountID : int) -> bool:
	if accountID <= 0:
		return false
	var untilTS : int = int(muted.get(accountID, 0))
	if untilTS <= 0:
		return false
	if untilTS > SQLCommons.Timestamp():
		return true
	muted.erase(accountID)
	return false

static func MuteRemaining(accountID : int) -> int:
	var remaining : int = int(muted.get(accountID, 0)) - SQLCommons.Timestamp()
	return remaining if remaining > 0 else 0

# Os dois caminhos de saída de texto — o RPC de chat (Server.TriggerChat) e o
# /whisper — consultam isto antes de disseminar. Sanção com dois portais é
# decoração para quem sabe digitar "/w". Devolve a mensagem de feedback, vazio
# quando pode falar.
static func CanSpeak(accountID : int) -> String:
	if not IsMuted(accountID):
		return ""
	return "You are muted for %s" % Util.FormatDuration(MuteRemaining(accountID))

# Mute novo (ou substituição do vigente — sanção mais longa sempre vence). Recusar
# prazo no passado aqui, e não no SQL, é o que impede um "/mute nick 0" silencioso.
static func Mute(accountID : int, untilTS : int, reason : String, mutedBy : int) -> bool:
	if accountID <= 0 or untilTS <= SQLCommons.Timestamp():
		return false
	if not Launcher.SQL.MuteAccount(accountID, untilTS, reason, mutedBy):
		return false
	muted[accountID] = untilTS
	return true

static func Unmute(accountID : int) -> bool:
	if accountID <= 0:
		return false
	if not Launcher.SQL.UnmuteAccount(accountID):
		return false
	muted.erase(accountID)
	return true

# Toda linha que o servidor aceitou passa por aqui (Server.TriggerChat), inclusive
# as de quem está calado depois — o buffer é a prova, não um filtro.
static func Note(accountID : int, nick : String, channel : String, text : String) -> void:
	log.append({"account_id": accountID, "nick": nick, "channel": channel, "text": text, "ts": SQLCommons.Timestamp()})
	while log.size() > LogMax:
		log.pop_front()

# Últimas linhas de um account em um canal (canal vazio = qualquer um), dentro da
# janela de denúncia, mais recentes primeiro.
static func RecentFor(accountID : int, channel : String, limit : int = 5) -> Array[Dictionary]:
	var found : Array[Dictionary] = []
	var now : int = SQLCommons.Timestamp()
	for i in range(log.size() - 1, -1, -1):
		if found.size() >= limit:
			break
		var line : Dictionary = log[i]
		if int(line.get("account_id", 0)) != accountID:
			continue
		if not channel.is_empty() and String(line.get("channel", "")) != channel:
			continue
		if now - int(line.get("ts", 0)) > ReportWindowSec:
			continue
		found.append(line)
	return found

static func ClipReason(reason : String) -> String:
	var clipped : String = reason.strip_edges()
	return clipped.left(ReasonMax)

# Denúncia de um jogador. Não exige permissão (é o caminho legal para o
# moderador existir), mas não pode virar metralhadora: uma open por par
# denunciante→denunciado.
static func Report(reporterAccount : int, reportedAccount : int, channel : String, reason : String) -> Dictionary:
	if reporterAccount <= 0 or reportedAccount <= 0:
		return {"ok": false, "reason": "not_logged_in"}
	if reporterAccount == reportedAccount:
		return {"ok": false, "reason": "self_report"}
	var clipped : String = ClipReason(reason)
	if clipped.is_empty():
		return {"ok": false, "reason": "empty_reason"}
	if Launcher.SQL.CountOpenReports(reporterAccount, reportedAccount) > 0:
		return {"ok": false, "reason": "already_reported"}
	var recent : Array[Dictionary] = RecentFor(reportedAccount, channel, 1)
	var excerpt : String = ""
	if not recent.is_empty():
		excerpt = String(recent[0].get("text", "")).left(ExcerptMax)
	var reportID : int = Launcher.SQL.AddChatReport(reporterAccount, reportedAccount, channel, clipped, excerpt, not excerpt.is_empty())
	if reportID <= 0:
		return {"ok": false, "reason": "storage_failed"}
	return {"ok": true, "report_id": reportID, "excerpt": excerpt, "verified": not excerpt.is_empty()}
