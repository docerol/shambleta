extends RefCounted
class_name SocialGraph

# SOM-IDLE social (AUDITORIA_2026-09-27 §14 SOCIAL, 4/10): "amizades, lista de
# ignorados, denúncias: inexistente ou decorativo". Não havia nem tabela nem código —
# este módulo é o único dono das duas arestas (`friend` e `ignore`) sobre
# `social_graph` (migration 061), e a única coisa que o servidor consulta para
# decidir "esta linha chega nesta sessão?".
#
# Por que mora aqui e não em `Server.gd`: o arquivo do servidor está no teto do gate
# anti-god-node e não cabe um handler, quanto mais a política — Sobe a régua quem
# fatia, não quem estica o teto (ver o cabeçalho de `scripts/check_god_nodes.sh`, que
# é quem mede e publica os números desta rodada). A conta fechou assim: os verbos
# entram pela ROTA DE COMANDO (`/friend`, `/unfriend`, `/ignore`, `/unignore`,
# `/social` em `WorldCommands.gd`, disparados por `Network.TriggerCommand` como
# `OnNewTextSubmitted` (`Chat.gd:@OnNewTextSubmitted`) já faz), a política vive inteira neste arquivo (fora do ratchet) e a
# cobrança no hot path é UMA chamada em `Network.ChatPlayer` — o único ponto por onde
# toda linha de jogador sai para uma sessão (local, global, guild e os dois ecos de
# whisper passam por ele; medido em `tests/social_graph_test.gd`).
#
# ignore é cobrado na ENTREGA, e a entrega é autoridade do servidor. Um filtro de
# cliente seria decoração: client modado ignora o filtro e continua lendo. É a mesma
# decisão do mute (`ChatModeration` cobra no envio, `IdleTests` prende a fronteira de
# que nada de moderação mora em `sources/gui`/`sources/network/client`) — só que aqui
# a sanção é do receptor contra o emissor, então o lugar correto é o último instante
# antes do pacote ir para AQUELE peer, não o envio.
#
# Identidade nunca vem do pacote: quem chama `Add`/`Remove`/`List` passa ids já
# resolvidos pelo SERVIDOR (`Peers.GetAccount(peerID)` para quem age,
# `WorldCommands.GetAccountID(nick)` para o alvo). Uma UI modada que escrevesse
# `target_account_id` no payload estaria escrevendo na caixa de outra pessoa.

# Amizade é par: um clique escreve as duas arestas. Bloqueio é unilateral.
const KindFriend : String	= "friend"
const KindIgnore : String	= "ignore"

# Tetos. O número é decisão, e a decisão é registrada aqui em vez de morar num
# `if` solto:
#  - `MaxFriends` = 64: a lista é lida num clique e desenhada na aba do `Social`, e
#    cada adição custa duas INSERTs simétricas na mesma transação. 64 é o piso em que
#    "quem eu sigo" ainda cabe numa tela sem inventar paginação e o teto em que a
#    escrita simétrica continua um custo constante e pequeno. Sem teto, a lista de
#    amigos é o vetor de spam de contato (adicionar 5.000 gente custa 10.000 linhas).
#  - `MaxIgnores` = 128: o dobro, porque bloquear é a sanção defensiva do próprio
#    jogador — quem precisa bloquear não pode ser obrigado a desempedrar a lista antes,
#    e um teto apertado aqui desincentiva justamente o uso que protege. O custo por
#    linha entregue não depende do tamanho da lista (é uma chave primária, ver o
#    `EXPLAIN QUERY PLAN` medido no cabeçalho da migration 061), então o teto é
#    superfície de abuso, não performance.
const MaxFriends : int		= 64
const MaxIgnores : int		= 128

# ------------------------------------------------------------------ escrita

# Adiciona a aresta `fromAccount -> targetAccount` do tipo `kind`.
# `friend` escreve os DOIS lados na mesma transação (convenção (b) da migration 061):
# se a metade espelhada falha, a primeira volta — "amigo" nunca é estado assimétrico.
# Recusa auto-relacionamento antes de encostar no banco: o `target` vem de um nick que
# o jogador escreveu, e "eu sou meu amigo" é a linha que a UI não sabe mostrar.
static func Add(kind : String, fromAccount : int, targetAccount : int) -> Dictionary:
	var shape : Dictionary = _Validate(kind, fromAccount, targetAccount)
	if not bool(shape.get("ok", false)):
		return shape
	if Has(kind, fromAccount, targetAccount):
		return _Fail("already")
	var cap : int = MaxFriends if kind == KindFriend else MaxIgnores
	if Count(kind, fromAccount) >= cap:
		return _Fail("social_cap")
	# Os dois lados do mesmo `kind`, SEMPRE conferidos antes de escrever: um teto que
	# só olha quem pede é um teto que um segundo clique estoura pela metade.
	if kind == KindFriend and Count(kind, targetAccount) >= cap:
		return _Fail("social_cap_target")
	# Alvo tem que ser conta de verdade: `target_account_id` chega resolvido de um nick
	# pelo servidor, mas `Add` também é chamada direto (harness, caminho futuro de
	# API) e uma aresta para um id que não existe é a conta reciclada de um `DELETE`
	# virando "eu ignoro o jogador novo" mais tarde.
	if Launcher.SQL.GetAccountName(fromAccount).is_empty() or Launcher.SQL.GetAccountName(targetAccount).is_empty():
		return _Fail("unknown_target")

	var now : int = SQLCommons.Timestamp()
	var mirror : bool = kind == KindFriend
	var sql : SQLService = Launcher.SQL
	if not sql.Transaction(func() -> bool:
		if not sql.ExecuteBindings("INSERT INTO social_graph(account_id, target_account_id, kind, created_at) VALUES (?, ?, ?, ?);", [fromAccount, targetAccount, kind, now]):
			return false
		if mirror and not sql.ExecuteBindings("INSERT INTO social_graph(account_id, target_account_id, kind, created_at) VALUES (?, ?, ?, ?);", [targetAccount, fromAccount, kind, now]):
			return false
		return true):
		return _Fail("storage_failed")
	return {"ok": true, "kind": kind, "account_id": fromAccount, "target_account_id": targetAccount}

# Remove a aresta. `friend` cai nos dois lados (a simetria é da escrita, então a
# saída também é); `ignore` cai só de quem bloqueou — desbloquear não é conversa.
# Remover o que não existe não é sucesso: quem chama precisa saber distinguir
# "tirei" de "não tinha" (o painel mostra um, o log do operador vê o outro).
static func Remove(kind : String, fromAccount : int, targetAccount : int) -> Dictionary:
	var shape : Dictionary = _Validate(kind, fromAccount, targetAccount)
	if not bool(shape.get("ok", false)):
		return shape
	if not Has(kind, fromAccount, targetAccount):
		return _Fail("missing")

	var mirror : bool = kind == KindFriend
	var sql : SQLService = Launcher.SQL
	if not sql.Transaction(func() -> bool:
		if not sql.ExecuteBindings("DELETE FROM social_graph WHERE account_id = ? AND target_account_id = ? AND kind = ?;", [fromAccount, targetAccount, kind]):
			return false
		if mirror and not sql.ExecuteBindings("DELETE FROM social_graph WHERE account_id = ? AND target_account_id = ? AND kind = ?;", [targetAccount, fromAccount, kind]):
			return false
		return true):
		return _Fail("storage_failed")
	return {"ok": true, "kind": kind, "account_id": fromAccount, "target_account_id": targetAccount}

# ------------------------------------------------------------------ leitura

# Uma checagem por entrega de mensagem, e é ela que o `EXPLAIN QUERY PLAN` da
# migration 061 mede: igualdade-tripla servida pelo índice da própria chave
# primária (`SEARCH ... USING COVERING INDEX`, nunca `SCAN`). Ler direto o banco em
# vez de um cache em memória é decisão, não acidente: o cache precisaria de
# invalidação no `Add`/`Remove` e de carga no boot para não virar "ignore que esquece
# quando o processo reinicia" — estado de sanção que se esquece é sanção decorativa.
static func IsIgnored(fromAccount : int, targetAccount : int) -> bool:
	return Has(KindIgnore, targetAccount, fromAccount)

# A linha de `from` pode chegar a `to`? `to` precisa existir na sessão dele para
# receber, então a única aresta que cala é a de quem recebe: `to` ignorou `from`.
static func CanMessage(fromAccount : int, targetAccount : int) -> bool:
	if fromAccount <= 0 or targetAccount <= 0:
		return true
	return not IsIgnored(fromAccount, targetAccount)

# O ponto único de decisão da entrega, chamado por `Network.ChatPlayer` com o que o
# primitivo já tem em mãos: o RID de quem falou e o peer de quem vai receber. Devolve
# true quando ESTA entrega a este peer não pode acontecer. As três saídas baratas
# antes de qualquer consulta são o que mantém o hot path barato: destinatário sem
# conta (cliente puro recebendo o próprio broadcast do servidor, onde `Peers` não é
# populated — filtrar ali seria filtrar no cliente), falante sem conta (NPC, que não
# é account e não tem o que ser ignorado) e o eco do próprio falante (quem fala precisa
# ver a própria linha — sem eco o whisper já era mudo, ver `guild_chat_fanout_test`).
static func DeliveryBlocked(senderRID : int, peerID : int) -> bool:
	var recipient : int = Peers.GetAccount(peerID)
	if recipient <= 0:
		return false
	var speaker : BaseAgent = WorldAgent.GetAgent(senderRID)
	if speaker == null or not (speaker is PlayerAgent):
		return false
	var sender : int = Peers.GetAccount((speaker as PlayerAgent).peerID)
	if sender <= 0 or sender == recipient:
		return false
	return IsIgnored(sender, recipient)

static func Has(kind : String, accountID : int, targetAccountID : int) -> bool:
	if accountID <= 0 or targetAccountID <= 0:
		return false
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT 1 FROM social_graph WHERE account_id = ? AND target_account_id = ? AND kind = ?;", [accountID, targetAccountID, kind])
	return not rows.is_empty()

static func Count(kind : String, accountID : int) -> int:
	if accountID <= 0:
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM social_graph WHERE account_id = ? AND kind = ?;", [accountID, kind])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

# A lista do painel/comando: nick do alvo e quando a aresta nasceu, em ordem de nick.
# Ordem estável é o que impede a lista de piscar de lugar entre dois empurrações da
# aba; `created_at` viaja junto para o painel poder dizer "amigo desde ...".
static func List(kind : String, accountID : int) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	if accountID <= 0:
		return out
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT a.username AS nick, s.created_at AS since FROM social_graph s JOIN account a ON a.account_id = s.target_account_id WHERE s.account_id = ? AND s.kind = ? ORDER BY a.username ASC;", [accountID, kind])
	for row : Dictionary in rows:
		out.append({"nick": str(row.get("nick", "")), "since": int(row.get("since", 0))})
	return out

# ------------------------------------------------------------------ frases

# Nome do verbo de comando. Uma única fonte para a string do comando: `WorldCommands`
# registra `/friend` e a UI escreve `/friend`; se os dois lados divergirem, o harness
# compara esta função com o que está registrado no arquivo do comando.
static func CommandName(kind : String, add : bool) -> String:
	if kind == KindIgnore:
		return "ignore" if add else "unignore"
	return "friend" if add else "unfriend"

# Nome da lista como o jogador lê.
static func ListName(kind : String) -> String:
	return "friends" if kind == KindFriend else "ignored"

# Nome da aresta como o jogador lê. Vive aqui e não no chamador porque comando e UI
# precisam dizer a mesma coisa, e "added" sem o tipo da aresta não informa nada.
static func VerbName(kind : String, add : bool) -> String:
	if kind == KindIgnore:
		return "ignored" if add else "no longer ignored"
	return "added as a friend" if add else "removed from your friends"

# A frase vista pelo jogador, ao lado do token que a produziu (precedente:
# `ChatModeration.CanSpeak` devolve mensagem, não código). Nenhum token cru chega à
# tela: cada razão que `Add`/`Remove` produzem tem exatamente uma frase abaixo, e uma
# razão nova esquecida no `match` cai na linha final genérica — nunca em `social_cap`
# escrito nu no chat. `tests/social_graph_test.gd` amarra os dois lados (as razões que
# o próprio arquivo declara vs. as razões mapeadas aqui), que é o que impede o mapa de
# virar decoração.
static func Message(result : Dictionary, kind : String, add : bool, nick : String, accountID : int = 0) -> String:
	var verb : String = VerbName(kind, add)
	if bool(result.get("ok", false)):
		var cap : int = MaxFriends if kind == KindFriend else MaxIgnores
		var mine : int = Count(kind, accountID) if accountID > 0 else 0
		return "%s %s (%d/%d)" % [nick, verb, mine, cap] if add else "%s %s" % [nick, verb]
	match str(result.get("reason", "")):
		"usage":
			return "Usage: /%s <player>" % CommandName(kind, add)
		"unknown_target":
			return "Player '%s' not found" % nick
		"already":
			return "'%s' is already %s" % [nick, verb]
		"missing":
			return "'%s' was not on your %s list" % [nick, ListName(kind)]
		"social_cap":
			return "Your %s list is full (limit %d) — remove someone first" % [ListName(kind), MaxFriends if kind == KindFriend else MaxIgnores]
		"social_cap_target":
			return "'%s' already has %d friends and cannot add more" % [nick, MaxFriends]
		"self_relation":
			return "You cannot /%s yourself" % CommandName(kind, add)
		"not_logged_in":
			return "Not logged in"
		"bad_kind":
			return "Unknown social list"
		"storage_failed":
			return "Could not save your social list, try again"
	return "Social action failed"

# As duas listas do jogador, lidas do banco pelo mesmo caminho do painel: é o que
# responde "o que eu tenho com fulano?" sem nenhum estado local no cliente. `want`
# aceita o nome da lista (`friend`/`ignore`, singular ou plural, como a UI e o comando
# já escrevem) e qualquer outra coisa vira recusa com o vocabulário na frase — uma
# palavra errada não pode devolver a lista do tipo errado.
static func DescribeLists(accountID : int, want : String) -> Dictionary:
	if accountID <= 0:
		return {"ok": false, "reason": "not_logged_in", "text": Message(_Fail("not_logged_in"), KindFriend, true, "")}
	var both : bool = want.is_empty() or want == "all" or want == "both"
	var friendList : Array[Dictionary] = []
	var ignoreList : Array[Dictionary] = []
	var lines : Array[String] = []
	if both or want == KindFriend or want == "friends":
		friendList = List(KindFriend, accountID)
		lines.append("Friends (%d/%d): %s" % [friendList.size(), MaxFriends, _JoinNicks(friendList)])
	if both or want == KindIgnore or want == "ignores" or want == "ignored":
		ignoreList = List(KindIgnore, accountID)
		lines.append("Ignored (%d/%d): %s" % [ignoreList.size(), MaxIgnores, _JoinNicks(ignoreList)])
	if lines.is_empty():
		return {"ok": false, "reason": "bad_kind", "text": "Use /social [friends|ignored]"}
	return {"ok": true, "text": "\n".join(lines), "friends": friendList, "ignored": ignoreList}

static func _JoinNicks(rows : Array[Dictionary]) -> String:
	if rows.is_empty():
		return "none"
	var nicks : Array[String] = []
	for row : Dictionary in rows:
		nicks.append(str(row.get("nick", "")))
	return ", ".join(nicks)

# ------------------------------------------------------------------ util

# Shape do verbo: tipo conhecido e duas contas distintas. Auto-relacionamento é recusado
# aqui e não no chamador: `Add` é chamada pelo comando e por qualquer harness, e o
# motivo tem que ser o mesmo nos dois caminhos (token estabilizado, nunca texto cru).
static func _Validate(kind : String, fromAccount : int, targetAccount : int) -> Dictionary:
	if kind != KindFriend and kind != KindIgnore:
		return _Fail("bad_kind")
	if fromAccount <= 0 or targetAccount <= 0:
		return _Fail("not_logged_in")
	if fromAccount == targetAccount:
		return _Fail("self_relation")
	return {"ok": true}

static func _Fail(reason : String) -> Dictionary:
	return {"ok": false, "reason": reason}
