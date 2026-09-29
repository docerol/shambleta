extends RefCounted
class_name GuildRoster

# AUDITORIA 2026-09-28 — escopo "ADMINISTRAÇÃO DE GUILDA NA MÃO DO JOGADOR NÃO
# EXISTE". Antes deste arquivo a guilda tinha fundação, entrada, saída e vault, e não
# tinha nenhuma das três coisas que fazem de uma guilda uma instituição: um teto, um
# dono e um caminho para o posto de oficial.
#
#  - `JoinGuild` entrava por ID numérico sem teto e sem aprovação: `/guild create`
#    custa 5000 gold (um clique de farm) e a UI oferecia "Join" de clique único na
#    lista de busca. Sem teto, uma guilda é um amplificador — cada linha de chat do
#    canal custa UM pacote `ChatPlayer` reliable por sessão de membro (`ChatModeration.
#    FanoutGuildChat`), e o painel paga duas consultas por membro em cada
#    `GetGuildState`.
#  - `PromoteMember` estava escrito e não tinha NENHUM chamador em `sources/` (só a
#    definição em `GuildService.gd` e a fachada em `EconomyService.gd`). Consequência
#    direta: o rank `officer`, exigido por `WithdrawFromVault`, era inalcançável no
#    produto — quem saca do vault era só o líder, e a régua da migration 060 ("oficial
#    saca, com janela e rastro") não tinha caminho legítimo. Este arquivo é o chamador:
#    `Promote` delega a escrita a `PromoteMember`, que deixa de ser código morto.
#  - Não havia remoção de roster: `/guild` não tinha kick, e `/kick` é sessão de
#    moderador (`WorldCommands.gd`), não guilda.
#
# DECISÕES DE PRODUTO DECLARADAS AQUI (não são segredo de `if`):
#
#  1. TETO. `MaxMembers`, abaixo. A recusa sai com reason próprio (`roster_full`), que
#     é token do catálogo `data/i18n/ui.csv` — o motivo cru nunca é frase na tela (§13;
#     `tests/reason_toast_test.gd` enumera os tokens que `sources/` emite por
#     atribuição (`result["reason"] = "x"`) e reprova qualquer um sem linha nos dois
#     idiomas; `tests/guild_governance_test.gd` varre o que sai daqui por `return` nu
#     (`JoinReason`/`RefusalFor`), forma que aquele varredor não enxerga, e amarra
#     o censo dos dois lados ao mapa de `Feedback` e ao catálogo).
#  2. QUEM MANDA. Só o LÍDER promove, rebaixa e chuta. O oficial mantém o que a casa
#     já lhe dava (vault com janela, level-up, slot) e ganha o convite. Não existe
#     "oficial chuta o líder": oficial não chuta ninguém, e líder não pode ser chutado
#     porque o único que poderia fazê-lo é ele mesmo — e ninguém se chuta a si mesmo
#     (`self_kick`). Sair sozinho da própria guilda é `/guild leave`, que já tem regra
#     própria.
#  3. GUILDA ÓRFÃ. Impossível por kick, e é decisão, não coincidência: o líder é o
#     único que chuta e ninguém se chuta; a única forma de o líder sair é
#     `LeaveGuild`, que (a) promove o membro mais antigo quando sobra gente e (b)
#     DISSOLVE a guilda quando ele é o último, exigindo vault vazio — sem perda de
#     item. Nenhum caminho novo precisa decidir "e agora, quem manda?"; por isso
#     `Kick` recusa o líder ANTES de encostar no banco, em vez de inventar sucessão.
#  4. CONVITE != FILA DE APROVAÇÃO. `Invite` é admissão autorizada por posto: líder ou
#     oficial põem um account nomeado na guilda pelo MESMO choke point do join aberto
#     (`EconomyService.JoinGuild`), e portanto sob o MESMO teto e as MESMAS regras de
#     "já tem guilda". O join aberto continua existindo — descobrir e entrar numa
#     guilda pública é o produto de hoje, tem harness congelado em cima (`SuiteGuilds`),
#     e o que a auditoria cobrava era o teto, não o fim da descoberta. Fila de convite
#     durável (pending aceite pelo convidado) é follow-up com migration própria, não
#     meia implementação aqui.
#  5. EFEITO NA ENTREGA. Kick de membro online vale na hora em que a mensagem sai do
#     servidor, não quando o cliente redesenha: a cobrança está no único ponto por onde
#     uma linha de jogador chega a UMA sessão (`Network.ChatPlayer`, o mesmo lugar onde
#     `ignore` é cobrado), via `ChatModeration.GuildDeliveryAllowed`. Filtrar no
#     recebimento do cliente seria decoração — cliente modado ignora o próprio filtro.
#
# Por que mora aqui e não em `Server.gd`: o arquivo do servidor está no teto do gate
# anti-god-node (ratchet por arquivo, `scripts/check_god_nodes.sh`) e a política de
# guilda inteira não cabe em duas linhas de folga. É a mesma conta que o `SocialGraph`
# fez: os verbos entram pela ROTA DE COMANDO (`/guild kick|promote|demote|invite` em
# `WorldCommands.gd`, disparada por `Network.TriggerCommand` — o mesmo funil que
# `/friend` e a `Social.gd` já usam), a política vive inteira neste arquivo, e a
# cobrança no hot path é UMA chamada em `Network.ChatPlayer`. `Launcher.Economy` é
# alcançado daqui, mas NENHUMA chamada daqui escreve fora do serviço dono da tabela:
# posto vem de `PromoteMember`/`DemoteMember` e remoção vem de `RemoveMember`
# (`GuildService`), e a ADMISSÃO vem de `JoinGuild` — para o teto ter um único ponto de
# verdade no sistema, conferível por quem lê o SQL do service e nada mais.

# Tetos. O número é decisão, e a decisão é registrada aqui em vez de morar num `if`
# solto — foi exatamente assim que `GuildVaultLimits` resolveu o mesmo problema do
# vault (servidor e painel lendo o MESMO número, sem um literal de cada lado):
#  - `MaxMembers` = 20: o chat de guild é fan-out por sessão (`ChatModeration.
#    ResolveGuildPeers` → um `Network.ChatPlayer` reliable por membro vivo) e o painel
#    custa duas consultas por membro em cada `GetGuildState`; 20 é o maior roster com
#    que UMA frase de chat continua um broadcast pequeno e a fileira do painel continua
#    uma lista rolável, sem inventar paginação. Crescer isso é decisão de produto com
#    régua própria (escalonar por nível, como faz `EconomyCatalog.GUILD_VAULT_PER_LEVEL`
#    no vault, é o caminho natural) — o que não pode voltar é a ausência de teto, que é
#    o que transformava `/guild create` em amplificador.
#    Conhecido e aceito: o teto é conferido ANTES do INSERT (contagem por
#    `COUNT(*)`, sem CHECK possível numa linha por membro), então duas admissões
#    simultâneas podem deixar a fileira em 21. Um teto de custo de broadcast fora por
#    uma unidade é irrilevante; um teto inexistente não é. A alternativa (tabela de
#    convite + transação por admissão) é a fila durável do item 4, não um lock aqui.
#  - Sem teto de convites por ator de propósito: quem convida já está preso ao teto da
#    guilda e ao próprio posto; um segundo teto por ator seria burocracia sobre um
#    caminho que já é pequeno.
const MaxMembers : int = 20

const RankLeader : String = "leader"
const RankOfficer : String = "officer"
const RankMember : String = "member"
# O motivo de sucesso, na mesma forma que o serviço já devolve (`{"reason": "ok"}`).
# Existe para `JoinReason` poder ser a ÚNICA pergunta do caminho: quem perguntou não
# precisa saber se recusa é ausência de reason ou reason diferente de "ok".
const ReasonOk : String = "ok"

# Quantos accounts estão na fileira. É a pergunta do teto e a que o painel mostra
# ("3/20"), lida do banco a cada chamada — o roster muda por kick/invite/leave sem
# nenhum cache para envelhecer.
static func Count(guildID : int) -> int:
	if guildID <= 0:
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

static func IsFull(guildID : int) -> bool:
	return guildID > 0 and Count(guildID) >= MaxMembers

# `JoinReason` é o choke point de admissão: a pergunta que o `GuildService.JoinGuild`
# faz a si mesmo antes do INSERT, e que o servidor e o painel refazem para DEVOLVER O
# MOTIVO ao jogador. Devolve "ok" quando o account pode entrar; senão, o token do
# catálogo (§13), nunca uma frase. Um só ponto respondendo "esta guilda aceita mais
# gente?" é o que faz as duas pernas do produto — quem clica "Join" na lista de busca e
# quem digita `/guild join <id>` — obedecerem ao mesmo teto sem que ninguém precise
# lembrar de conferi-lo.
static func JoinReason(accountID : int, guildID : int) -> String:
	if accountID <= 0 or guildID <= 0:
		return "bad_args"
	if Launcher.Economy.GetGuildForAccount(accountID) != 0:
		return "already_in_guild"
	if Launcher.Economy.GetGuild(guildID).is_empty():
		return "no_guild"
	if IsFull(guildID):
		return "roster_full"
	return ReasonOk

# O reason de uma recusa que JÁ aconteceu, para quem só tem em mãos um `false` do
# serviço. Readmitido hoje, o motivo continua sendo o do catálogo; se a recusa veio de
# uma falha de banco (nada que `JoinReason` saiba dizer), o jogador ouve `rejected`, que
# também tem linha — nunca a string vazia, que no painel seria "Guild rejected: " mudo.
static func RefusalFor(accountID : int, guildID : int) -> String:
	var reason : String = JoinReason(accountID, guildID)
	return reason if reason != ReasonOk else "rejected"

static func RankOf(accountID : int) -> String:
	return Launcher.Economy.GetMemberRank(accountID) if accountID > 0 else ""

static func GuildOf(accountID : int) -> int:
	return Launcher.Economy.GetGuildForAccount(accountID) if accountID > 0 else 0

# ------------------------------------------------------------------ os quatro verbos
# Todos devolvem o MESMO formato ({ok, reason, target, ...}) porque os quatro saem pela
# mesma boca: `Run` → `Command`, que traduz o reason para a frase do jogador e empurra
# o estado fresco. Os reasons são tokens do catálogo, escritos na forma
# `result["reason"] = "<token>"` — exatamente a que `tests/reason_toast_test.gd` varre
# em `sources/`, para o catálogo ser cobrado por régua alheia e não pela minha memória.
# A ESCRITA é sempre do serviço dono da tabela (`GuildService`), nunca daqui: o roster
# tem UM dono e este arquivo é a política em cima dele, não um segundo escriba.

# Remove `targetAccount` da guilda de `actorAccount`. Só o líder, nunca a si mesmo.
static func Kick(actorAccount : int, targetAccount : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "target": targetAccount}
	if actorAccount <= 0 or targetAccount <= 0:
		result["reason"] = "bad_args"
		return result
	if RankOf(actorAccount) != RankLeader:
		result["reason"] = "not_leader"
		return result
	var guildID : int = GuildOf(actorAccount)
	if guildID == 0 or GuildOf(targetAccount) != guildID:
		result["reason"] = "not_member"
		return result
	if actorAccount == targetAccount:
		result["reason"] = "self_kick"
		return result
	if RankOf(targetAccount) == RankLeader:
		# Invariante, não cortesia: há um só líder por guilda e só o líder chuta, então
		# este ramo é alcançável apenas por banco corrompido. Recusar aqui é mais barato
		# que dissolver a guilda de uma pessoa por um dado inconsistente.
		result["reason"] = "self_kick"
		return result
	if not Launcher.Economy.RemoveMember(guildID, targetAccount):
		result["reason"] = "rejected"
		return result
	result["ok"] = true
	result["reason"] = ReasonOk
	result["guild"] = guildID
	# Rastro reviewável (item 3): autorizamos CONTRA O RANK DO BANCO, agimos, e agora
	# registramos quem (actorAccount autenticado) chutou quem. A escrita é do dono da
	# tabela (`GuildService.LogGovernance`), alcançada por `guildService` como faz
	# `ChatModeration`; best-effort — o kick já está aplicado e o rastro não o reverte.
	Launcher.Economy.guildService.LogGovernance(guildID, actorAccount, targetAccount, "kick")
	return result

# Promove a `officer`. A ESCRITA é `PromoteMember`, o serviço dono da tabela — é assim
# que o posto de oficial passa a ter um chamador real neste produto (e, com ele, que
# `WithdrawFromVault` deixa de ser regra de um rank que ninguém consegue).
static func Promote(actorAccount : int, targetAccount : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "target": targetAccount}
	if actorAccount <= 0 or targetAccount <= 0:
		result["reason"] = "bad_args"
		return result
	if RankOf(actorAccount) != RankLeader:
		result["reason"] = "not_leader"
		return result
	var guildID : int = GuildOf(actorAccount)
	if guildID == 0 or GuildOf(targetAccount) != guildID:
		result["reason"] = "not_member"
		return result
	var targetRank : String = RankOf(targetAccount)
	if targetRank == RankLeader:
		result["reason"] = "already_leader"
		return result
	if targetRank == RankOfficer:
		result["reason"] = "already_officer"
		return result
	if not Launcher.Economy.PromoteMember(actorAccount, targetAccount):
		result["reason"] = "rejected"
		return result
	result["ok"] = true
	result["reason"] = ReasonOk
	result["rank"] = RankOfficer
	# Item 3: promoção registrada na trilha de governança (mesma boca do kick). O actor é
	# o líder autenticado; o posto novo é `officer` — é isto que torna o rank finalmente
	# alcançável e, com ele, `WithdrawFromVault` uma regra com caminho legítimo.
	Launcher.Economy.guildService.LogGovernance(guildID, actorAccount, targetAccount, "promote")
	return result

# Rebaixa a `member`. É o verbo que falta para a promoção ser uma decisão e não um
# depósito: sem ele, um posto errado fica errado para sempre.
static func Demote(actorAccount : int, targetAccount : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "target": targetAccount}
	if actorAccount <= 0 or targetAccount <= 0:
		result["reason"] = "bad_args"
		return result
	if RankOf(actorAccount) != RankLeader:
		result["reason"] = "not_leader"
		return result
	var guildID : int = GuildOf(actorAccount)
	if guildID == 0 or GuildOf(targetAccount) != guildID:
		result["reason"] = "not_member"
		return result
	if RankOf(targetAccount) != RankOfficer:
		result["reason"] = "not_officer"
		return result
	if not Launcher.Economy.DemoteMember(actorAccount, targetAccount):
		result["reason"] = "rejected"
		return result
	result["ok"] = true
	result["reason"] = ReasonOk
	result["rank"] = RankMember
	# Item 3: rebaixamento registrado — sem rastro, promover seria um depósito invisível.
	Launcher.Economy.guildService.LogGovernance(guildID, actorAccount, targetAccount, "demote")
	return result

# Admite `targetAccount` na guilda de quem convida (líder ou oficial). Não duplica a
# regra de entrada: passa pelo MESMO `JoinGuild`, então teto de roster, "já tem guilda"
# e "guilda existe" valem daqui exatamente como valem para quem clica "Join".
static func Invite(actorAccount : int, targetAccount : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "target": targetAccount}
	if actorAccount <= 0 or targetAccount <= 0:
		result["reason"] = "bad_args"
		return result
	var actorRank : String = RankOf(actorAccount)
	if actorRank != RankLeader and actorRank != RankOfficer:
		result["reason"] = "not_officer"
		return result
	var guildID : int = GuildOf(actorAccount)
	var reason : String = JoinReason(targetAccount, guildID)
	if reason != ReasonOk:
		result["reason"] = reason
		return result
	if not Launcher.Economy.JoinGuild(targetAccount, guildID):
		result["reason"] = "rejected"
		return result
	result["ok"] = true
	result["reason"] = ReasonOk
	result["guild"] = guildID
	return result

static func Run(verb : String, actorAccount : int, targetAccount : int) -> Dictionary:
	match verb:
		"kick":
			return Kick(actorAccount, targetAccount)
		"promote":
			return Promote(actorAccount, targetAccount)
		"demote":
			return Demote(actorAccount, targetAccount)
		"invite":
			return Invite(actorAccount, targetAccount)
		_:
			var result : Dictionary = {"ok": false}
			result["reason"] = "bad_args"
			return result

# ------------------------------------------------------------------ a boca dos verbos
# Chamada pelo comando (`/guild <verb> <nick>`, com o alvo já resolvido pelo servidor) e
# pela UI (`GuildPanel`), com a mesma assinatura. Existe para os dois caminhos não
# reinventarem o que vem depois da escrita: a frase que o jogador lê e o estado fresco
# que as duas telas precisam ver. `nick` é só para a frase — nada aqui aceita id de
# alvo vindo de pacote: quem resolve nick → conta é `WorldCommands.GetAccountID`, e quem
# resolve quem age é o peer.
static func Command(verb : String, actorAccount : int, targetAccount : int, nick : String) -> Dictionary:
	var result : Dictionary = Run(verb, actorAccount, targetAccount)
	if targetAccount <= 0 and actorAccount > 0:
		# O nick não bateu em ninguém. Recusa de forma, não de posto: dito antes de
		# `Run` porque um alvo 0 daria `bad_args`, que é a palavra errada para "não
		# encontrei fulano".
		result["reason"] = "unknown_target"
	result["text"] = Feedback(verb, result, nick, actorAccount)
	if bool(result.get("ok", false)):
		PushState(actorAccount, targetAccount)
	return result

# A frase vista pelo jogador, ao lado do token que a produziu (precedente:
# `ChatModeration.CanSpeak` e `SocialGraph.Message`). Todo token que os verbos acima
# produzem tem uma linha aqui; um token novo esquecido cai na linha final genérica, que
# é feia mas nunca crua. `tests/guild_governance_test.gd` amarra os dois lados — ele
# conta os tokens que este arquivo produz (atribuição E `return` nu), exige braço no
# mapa para cada um, exige que nenhum braço exista sem produtor, que cada token
# devolva frase própria e diferente dos irmãos, e que cada um tenha linha no catálogo
# — o que impede o mapa de virar decoração.
static func Feedback(verb : String, result : Dictionary, nick : String, actorAccount : int = 0) -> String:
	var reason : String = str(result.get("reason", ""))
	if bool(result.get("ok", false)):
		match verb:
			"kick":
				return "%s was removed from the guild" % nick
			"promote":
				return "%s is now an officer (officers can withdraw from the vault)" % nick
			"demote":
				return "%s is a member again" % nick
			"invite":
				return "%s joined the guild (%d/%d)" % [nick, Count(GuildOf(actorAccount)), MaxMembers]
		return "Guild: done."
	match reason:
		"unknown_target":
			return "Player '%s' not found" % nick
		"roster_full":
			return "The guild is full (limit %d) — remove someone first" % MaxMembers
		"already_in_guild":
			return "%s is already in a guild" % nick
		"no_guild":
			return "You are not in a guild"
		"not_leader":
			return "Only the guild leader can %s someone" % verb
		"not_officer":
			return "Officer rank required to invite" if verb == "invite" else "%s is not an officer" % nick
		"not_member":
			return "%s is not in your guild" % nick
		"self_kick":
			return "You cannot kick yourself — leave with /guild leave"
		"already_officer":
			return "%s is already an officer" % nick
		"already_leader":
			return "%s is the leader" % nick
		"bad_args":
			return "Usage: /guild %s <player>" % verb
		"rejected":
			return "Guild action failed (the server refused it)"
	return "Guild action failed"

# Empurra o estado fresco para as duas telas que mudaram: a de quem agiu e a de quem foi
# alvo. É isso que faz um kick ser visível sem F5 — e, no kick, a tela do chutado passa
# a dizer "sem guilda" porque o estado que ele recebe já vem vazio do serviço. Sem
# sessão viva não há para quem empurrar: `Peers.accounts` é o registro do servidor, e um
# account ausente dele simplesmente não recebe nada (nunca um push para peer inventado).
static func PushState(actorAccount : int, targetAccount : int) -> void:
	if Launcher.Economy == null:
		return
	for accountID in [actorAccount, targetAccount]:
		var peerID : int = int(Peers.accounts.get(accountID, NetworkCommons.PeerUnknownID))
		if accountID <= 0 or peerID == NetworkCommons.PeerUnknownID or not Peers.peers.has(peerID):
			continue
		Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)
