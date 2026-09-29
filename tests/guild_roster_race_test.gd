extends SceneTree

# AUDITORIA rodada 3 (SOCIAL) — corrida no roster da guilda.
#
# O defeito medido, antes desta passada, caractere por caractere (as duas linhas
# velhas continuam aqui de propósito: são o CONTROLE PLANTADO do bloco 3, e é este
# texto que a régua tem que acusar — a mesma régua que teria vermelho na revisão em
# que o código entrou, não depois do conserto):
#
#   GuildService.gd (velha :94-97)  `JoinGuild` = `GuildRoster.JoinReason(...)` (→
#     `Count`, `QueryBindings`, lock próprio) + `ExecuteBindings("INSERT INTO
#     guild_member ...")` (outro lock próprio) — dois joins concorrentes liam o mesmo
#     19 e escreviam 21 acima do teto.
#   GuildService.gd (velha :263-300) `PromoteMember`/`DemoteMember`/`RemoveMember` =
#     `GetMemberRank`/`GetGuildForAccount` (4 leituras, 4 locks) + um
#     `ExecuteBindings` de escrita; `RemoveMember` ainda lia `SELECT changes()` DEPOIS
#     de soltar a escrita, e `changes()` é por CONEXÃO: o DELETE de um thread respondia
#     pelo do outro (kick que diz "removi" sem remover nada, e "nada" para quem removeu).
#   GuildRoster.gd (velha :103-110) `Count`/`IsFull` — a pergunta do teto respondida
#     fora de qualquer funil, de um jeito que não pode ser chamada dentro de
#     `Transaction()` (por isso o funil ganhou `CountLocked`/`IsFullLocked`, que lêem
#     pelo handle cru da transação e consultam o MESMO `MaxMembers`).
#
# O fecho reusa o padrão que o arquivo já tem (`_eco.settleMutex.lock()` +
# `Launcher.SQL.Transaction`, o funil de `CreateGuild`/`LeaveGuild`/`DepositToVault`
# e o `_MoveGoldLocked` do kernel). Nada de segundo lock.
#
# Blocos:
#   1. censo do funil no fonte: toda mutação de `guild_member` do dono da tabela está
#      dentro do funil serializado (e o censo ACHA as mutações — verde por inanição
#      não é verde);
#   2. ordem do lock (settleMutex antes de Transaction) — sem inversão com o resto do
#      arquivo, que é o que transforma funil em deadlock;
#   3. CONTROLES PLANTADOS no mesmo predicado: corpo fora do funil (exige acusação) e
#      corpo dentro do funil (exige zero);
#   4. corrida REAL com duas threads: promote + kick concorrentes, duas removendo o
#      MESMO alvo, dois joins no buraco embaixo do teto — o resultado tem que ser um
#      dos estados serializáveis, nunca merge perdido nem teto estourado;
#   5. o teto continua valendo depois do fecho (recusa no N+1, sem estouro).
#
# Uso: godot --headless --path . -s tests/guild_roster_race_test.gd
# Exit code = checks falhos. Última linha: `== GUILD ROSTER RACE: N checks, M failures ==`.
#
# Regra dos harnesses `-s` (guild_governance_test.gd:31): nada de identificador de
# autoload ou `class_name` em anotação de tipo — tudo via load()/get()/call().

const RosterFile : String = "res://sources/economy/GuildService.gd"
const PolicyFile : String = "res://sources/economy/GuildRoster.gd"

var checks : int = 0
var failures : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _autoload(name : String) -> Node:
	return root.get_node_or_null(NodePath(name))

# ------------------------------------------------------------------ o predicado
# Uma função é MUTADORA DE ROSTER se o corpo escreve em `guild_member`. Ela está no
# FUNIL SERIALIZADO se o mesmo corpo pega o lock do shard e abre a transação na ordem
# certa, sem escrever pela porta que trava sozinha (`ExecuteBindings`/`QueryBindings`).
# É UM predicado só: o censo do fonte (bloco 1) e os controles plantados (bloco 3)
# chamam esta mesma função com entradas diferentes.
static func WritesRoster(body : String) -> bool:
	for marker in ["INSERT INTO guild_member", "UPDATE guild_member", "DELETE FROM guild_member",
		"UpdateRowsRaw(\"guild_member\"", "DeleteRowsRaw(\"guild_member\"", "insert_row(\"guild_member\"",
		"update_rows(\"guild_member\"", "delete_rows(\"guild_member\""]:
		if body.contains(marker):
			return true
	return false

static func InFunnel(body : String) -> bool:
	var lockAt : int = body.find("settleMutex.lock()")
	if lockAt < 0:
		lockAt = body.find("queryMutex.lock()")
	var txAt : int = body.find("SQL.Transaction(")
	if lockAt < 0 or txAt < 0:
		return false
	return lockAt < txAt

static func LoneDoorWrite(body : String) -> bool:
	return body.contains("ExecuteBindings(\"INSERT INTO guild_member") \
		or body.contains("ExecuteBindings(\"UPDATE guild_member") \
		or body.contains("ExecuteBindings(\"DELETE FROM guild_member") \
		or body.contains("ExecuteBindings(\"SELECT changes()")

static func UnfunneledRosterMutations(entries : Array) -> Array[String]:
	# `entries` = [{"where","body"}, ...]. Devolve "onde: motivo" para cada mutação de
	# roster fora do funil. Vazio com corpo sem mutação é o caso normal, não a falha.
	var out : Array[String] = []
	for e in entries:
		var body : String = str(e.get("body", ""))
		if not WritesRoster(body):
			continue
		var where : String = str(e.get("where", "?"))
		if not InFunnel(body):
			out.append(where + ": escreve guild_member sem `settleMutex.lock()` + `SQL.Transaction(` antes (leitura-modificação-escrita sem funil)")
		elif LoneDoorWrite(body):
			out.append(where + ": escreve guild_member por `ExecuteBindings`, que trava sozinha e solta entre a leitura e a escrita")
	return out

# Divide um arquivo GDScript em corpos de função (na ordem em que aparecem).
static func SplitFunctions(source : String) -> Array:
	var lines : PackedStringArray = source.split("\n")
	var out : Array = []
	var name : String = ""
	var body : String = ""
	for line in lines:
		var m := RegEx.create_from_string("^\\s*(?:static\\s+)?func\\s+([A-Za-z_]\\w*)").search(line)
		if m != null:
			if not name.is_empty():
				out.append({"where": name, "body": body})
			name = m.get_string(1)
			body = line + "\n"
		elif not name.is_empty():
			body += line + "\n"
	if not name.is_empty():
		out.append({"where": name, "body": body})
	return out

# ------------------------------------------------------------------ helpers de banco
func _sqlRow(sql : Node, query : String, params : Array) -> Dictionary:
	var rows : Array = sql.callv("QueryBindings", [query, params])
	return {} if rows.is_empty() else rows[0]

func _countMembers(sql : Node, guildID : int) -> int:
	return int(_sqlRow(sql, "SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID]).get("n", -1))

func _rankOf(sql : Node, accountID : int) -> String:
	return str(_sqlRow(sql, "SELECT rank FROM guild_member WHERE account_id = ?;", [accountID]).get("rank", "?"))

func _guildOf(sql : Node, accountID : int) -> int:
	return int(_sqlRow(sql, "SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID]).get("guild_id", 0))

# ------------------------------------------------------------------ worker da corrida
class RosterWorker extends RefCounted:
	var economy : Node = null
	var verb : String = ""
	var argA : int = 0
	var argB : int = 0
	var result : bool = false
	var ready : bool = false

	func Run() -> void:
		# As duas threads largam juntas deste flag: sem ele o intervalo de agendamento
		# do SO decide a corrida e o harness vira flaky (o que se mede é o INTERLEAVE
		# das duas mutações, não qual thread saiu na frente).
		while not ready:
			pass
		if verb == "promote":
			result = bool(economy.callv("PromoteMember", [argA, argB]))
		elif verb == "kick":
			result = bool(economy.callv("RemoveMember", [argA, argB]))
		elif verb == "join":
			result = bool(economy.callv("JoinGuild", [argA, argB]))

func _race(economy : Node, pairs : Array) -> Array[bool]:
	var workers : Array = []
	var threads : Array = []
	for p in pairs:
		var w : RosterWorker = RosterWorker.new()
		w.economy = economy
		w.verb = str(p[0])
		w.argA = int(p[1])
		w.argB = int(p[2])
		workers.append(w)
		var t : Thread = Thread.new()
		threads.append(t)
		t.start(Callable(w, "Run"))
	# Todas no portão; um `await` aqui seria espera com o main loop rodando o tick do
	# próprio worker — `ready` é declarado por elas, então é delay cru mesmo.
	OS.delay_msec(60)
	for w in workers:
		w.ready = true
	var out : Array[bool] = []
	for t in threads:
		t.wait_to_finish()
	for w in workers:
		out.append(bool(w.result))
	OS.delay_msec(120)
	return out

func _initialize():
	_runTests()

func _runTests():
	print("== guild roster race: funil serializado + duas mutações concorrentes ==")
	var launcher : Node = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	Check(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit (%d ms de boot)" % waited)
	var sql : Node = launcher.get("SQL")
	var economy : Node = launcher.get("Economy")
	if not Check(sql != null and economy != null, "SQL + Economy booteds"):
		_finish()
		return
	if economy.get("guildService") == null:
		economy.call("_post_launch")

	# ------------------------------------------------ 1. censo do funil no fonte real
	var serviceSrc : String = FileAccess.get_file_as_string(RosterFile)
	var policySrc : String = FileAccess.get_file_as_string(PolicyFile)
	Check(not serviceSrc.is_empty() and not policySrc.is_empty(), "os dois arquivos do roster foram lidos")
	var entries : Array = SplitFunctions(serviceSrc)
	entries.append_array(SplitFunctions(policySrc))
	var mutations : Array = []
	for e in entries:
		if WritesRoster(str(e.get("body", ""))):
			mutations.append(e)
	CheckEq(mutations.size(), 5, "o censo ACHA as mutações de roster do fonte (5: Join/Create/Leave/_SetMemberRank/Remove) — verde por inanição não é verde")
	var accused : Array[String] = UnfunneledRosterMutations(entries)
	for a in accused:
		print("  [acuso] " + a)
	CheckEq(accused.size(), 0, "nenhuma mutação de roster fora do funil serializado no fonte")
	for m in mutations:
		Check(InFunnel(str(m.get("body", ""))), "%s está dentro de settleMutex + Transaction" % str(m.get("where", "")))
		Check(not LoneDoorWrite(str(m.get("body", ""))), "%s não escreve o roster pela porta que trava sozinha" % str(m.get("where", "")))
	# O teto continua sendo de uma boca só, agora também dentro do funil.
	Check(policySrc.contains("Count(guildID) >= MaxMembers"), "o teto de fora continua em `Count(guildID) >= MaxMembers`")
	Check(policySrc.contains("CountLocked(sql, guildID) >= MaxMembers"), "o teto de dentro do funil consulta o MESMO MaxMembers (`CountLocked`)")
	Check(not serviceSrc.contains("MaxMembers : int ="), "o service não redeclara o teto")

	# --------------------------------------------- 2. ordem do lock (sem inversão)
	for m in mutations:
		var body : String = str(m.get("body", ""))
		Check(body.find("settleMutex.lock()") < body.find("SQL.Transaction("), "%s pega o lock ANTES de abrir a transação (mesma ordem do resto do arquivo)" % str(m.get("where", "")))

	# -------------------------------------------------- 3. controles plantados
	# (a) a forma VELHA, copiada caractere por caractere do `JoinGuild` pré-fecho:
	#     leitura pela porta de cima, escrita por `ExecuteBindings`, nenhum funil.
	var oldJoin : String = "func JoinGuild(accountID : int, guildID : int) -> bool:\n" \
		+ "\tif GuildRoster.JoinReason(accountID, guildID) != GuildRoster.ReasonOk:\n\t\treturn false\n" \
		+ "\treturn Launcher.SQL.ExecuteBindings(\"INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);\", [guildID, accountID, SQLCommons.Timestamp()])\n"
	var controlAccused : Array[String] = UnfunneledRosterMutations([{"where": "CONTROL-OUTRO-FUNIL#JoinGuild", "body": oldJoin}])
	CheckEq(controlAccused.size(), 1, "CONTROLE: duas escritas concorrentes fora do funil são ACUSADAS pelo mesmo predicado do caso real")
	Check(controlAccused.size() == 1 and controlAccused[0].contains("CONTROL-OUTRO-FUNIL"), "CONTROLE: a acusação nomeia o corpo injetado (%s)" % str(controlAccused))
	# (b) a MESMA escrita, agora dentro do funil: exige zero.
	var fixedJoin : String = "func JoinGuild(accountID : int, guildID : int) -> bool:\n" \
		+ "\tvar joined : bool = false\n\t_eco.settleMutex.lock()\n\tif Launcher.SQL.Transaction(func() -> bool:\n" \
		+ "\t\tif GuildRoster.IsFullLocked(sql, guildID): return false\n" \
		+ "\t\treturn bool(sql.db.query_with_bindings(\"INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);\", [guildID, accountID, 0]))\n" \
		+ "\t): joined = true\n\t_eco.settleMutex.unlock()\n\treturn joined\n"
	CheckEq(UnfunneledRosterMutations([{"where": "CONTROL-DENTRO-FUNIL#JoinGuild", "body": fixedJoin}]).size(), 0, "CONTROLE: a mesma mutação dentro do funil devolve ZERO acusação")
	# (c) escrita serializada que ainda assim solta a contagem para fora da transação
	# (o `SELECT changes()` do `RemoveMember` velho) — outra forma de merge perdido.
	var oldRemove : String = "func RemoveMember(guildID : int, targetAccount : int) -> bool:\n" \
		+ "\tif not Launcher.SQL.ExecuteBindings(\"DELETE FROM guild_member WHERE guild_id = ? AND account_id = ? AND rank <> 'leader';\", [guildID, targetAccount]):\n\t\treturn false\n" \
		+ "\tvar changed : Array = Launcher.SQL.QueryBindings(\"SELECT changes() AS c;\", [])\n\treturn changed[0].get(\"c\", 0) > 0\n"
	var removeAccused : Array[String] = UnfunneledRosterMutations([{"where": "CONTROL-CHANGES-FORA#RemoveMember", "body": oldRemove}])
	CheckEq(removeAccused.size(), 1, "CONTROLE: DELETE sem funil + `changes()` lida depois é acusado (%s)" % str(removeAccused))

	# --------------------------------------------------------- 4. a corrida real
	var guildName : String = "Race Guild A"
	sql.call("ExecuteBindings", "DELETE FROM guild_governance_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'GldRace%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'gldrace\\_%';", [])
	var suites : GDScript = load("res://tests/IdleTests.gd")
	var fixtures : RefCounted = suites.new()
	var acctLeader : int = 0
	var chars : Array = []
	for i in range(0, 5):
		var charID : int = int(fixtures.call("CreateFixture", sql, "gldrace_%d" % i, "GldRaceNick%d" % i))
		chars.append(charID)
		Check(charID != 0, "fixture %d criado" % i)
	if chars.has(0):
		_finish()
		return
	acctLeader = int(sql.call("GetAccountIDForCharacter", int(chars[0])))
	var guildID : int = int(economy.call("CreateGuild", acctLeader, int(chars[0]), guildName))
	if not Check(guildID > 0, "líder fundou a guild #%d" % guildID):
		_finish()
		return
	var accts : Array = []
	for i in range(0, 5):
		accts.append(int(sql.call("GetAccountIDForCharacter", int(chars[i]))))
	for i in range(1, 4):
		Check(bool(economy.call("JoinGuild", accts[i], guildID)), "membro %d entrou pelo funil" % i)

	# (A) promote || kick, alvos diferentes: os dois têm que sobreviver. Antes do
	#     fecho era este o merge perdido — o UPDATE do promote e o DELETE do kick
	#     escreviam sem nada segurando o par leitura→escrita.
	var raceA : Array[bool] = _race(economy, [["promote", accts[0], accts[1]], ["kick", guildID, accts[2]]])
	CheckEq(_countMembers(sql, guildID), 3, "corrida promote||kick: fileira 4→3, sem entrada perdida nem fantasma")
	CheckEq(_guildOf(sql, accts[2]), 0, "corrida promote||kick: o chutado saiu")
	Check(_rankOf(sql, accts[1]) == "officer", "corrida promote||kick: o promovido ficou officer (posto não evapou): %s" % _rankOf(sql, accts[1]))
	Check(bool(raceA[0]) and bool(raceA[1]), "corrida promote||kick: as duas mutações reportaram sucesso (%s)" % str(raceA))

	# (B) dois kicks do MESMO alvo: num mundo serializável exatamente um remove e o
	#     outro vê 0 linhas. Dois "true" seria `changes()` respondendo pela escrita
	#     alheia; nenhum "true" com a linha fora é a inversão do mesmo defeito.
	var raceB : Array[bool] = _race(economy, [["kick", guildID, accts[1]], ["kick", guildID, accts[1]]])
	var truthies : int = (1 if raceB[0] else 0) + (1 if raceB[1] else 0)
	CheckEq(truthies, 1, "dois kicks concorrentes do mesmo alvo: exatamente um afirma ter removido (%s)" % str(raceB))
	CheckEq(_guildOf(sql, accts[1]), 0, "dois kicks concorrentes: o alvo está fora (nenhum estado intermediário)")
	CheckEq(_countMembers(sql, guildID), 2, "dois kicks concorrentes: fileira = 2 (líder + D), sem dupla remoção")

	# (C) teto no ponto exato em que ele é disputado: fileira em cap-1 e DOIS joins
	#     simultâneos. O único estado serializável é entrar um e o outro ouvir
	#     `roster_full`; a leitura-modificação-escrita velha deixava os dois lerem
	#     cap-1 e escreverem cap+1.
	var reg := RegEx.create_from_string("const MaxMembers : int = (\\d+)")
	var cap : int = int(reg.search(policySrc).get_string(1)) if reg.search(policySrc) != null else -1
	CheckEq(cap, 20, "teto lido do fonte pelo harness (MaxMembers)")
	var fillFrom : int = 0
	var filled : int = _countMembers(sql, guildID)
	var pool : int = 4
	for i in range(0, pool):
		var extra : int = int(fixtures.call("CreateFixture", sql, "gldrace_x%d" % i, "GldRaceX%d" % i))
		Check(extra != 0, "concorrente de convite %d criado" % i)
		accts.append(int(sql.call("GetAccountIDForCharacter", extra)))
	while filled < cap - 1:
		var fx : int = int(fixtures.call("CreateFixture", sql, "gldrace_f%d" % fillFrom, "GldRaceF%d" % fillFrom))
		if fx == 0:
			break
		economy.call("JoinGuild", int(sql.call("GetAccountIDForCharacter", fx)), guildID)
		filled = _countMembers(sql, guildID)
		fillFrom += 1
	CheckEq(filled, cap - 1, "fileira pré-carregada até cap-1 (%d de %d) para a disputa" % [filled, cap])
	var twoA : int = int(accts[accts.size() - 2])
	var twoB : int = int(accts[accts.size() - 1])
	var raceC : Array[bool] = _race(economy, [["join", twoA, guildID], ["join", twoB, guildID]])
	var joinedCount : int = (1 if raceC[0] else 0) + (1 if raceC[1] else 0)
	CheckEq(_countMembers(sql, guildID), cap, "dois joins concorrentes em cap-1: a fileira PARA no teto, nunca acima (%d)" % _countMembers(sql, guildID))
	CheckEq(joinedCount, 1, "dois joins concorrentes em cap-1: exatamente um entrou e o outro foi recusado (%s)" % str(raceC))
	CheckEq(_countMembers(sql, guildID), filled + joinedCount, "dois joins concorrentes: contagem == cap-1 + quem afirmou ter entrado (nenhuma entrada perdida nem fantasma)")

	# ----------------------------------------------------- 5. o teto continua valendo
	Check(not bool(economy.call("JoinGuild", accts[accts.size() - 1], guildID)) or _countMembers(sql, guildID) <= cap, "join além do teto não estoura a fileira")
	var over : int = int(fixtures.call("CreateFixture", sql, "gldrace_over", "GldRaceOver"))
	var overAcct : int = int(sql.call("GetAccountIDForCharacter", over))
	var reason : String = str(load("res://sources/economy/GuildRoster.gd").call("JoinReason", overAcct, guildID))
	var refused : bool = not bool(economy.call("JoinGuild", overAcct, guildID))
	CheckEq(_countMembers(sql, guildID), cap, "fileira exatamente no teto (%d) antes da recusa final" % cap)
	Check(refused and reason == "roster_full", "(cap+1)-ésimo join recusado com roster_full (recusado=%s reason=%s)" % [str(refused), reason])
	_finish()

func _finish() -> void:
	print("== GUILD ROSTER RACE: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)
