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
