extends SceneTree

# AUDITORIA 2026-09-28 — GOVERNANÇA de guilda (promote/demote/kick + teto de roster +
# trilha de auditoria). Harness do SERVIDOR: prova que a decisão de quem pode mudar o
# roster é tomada a partir do account autenticado e do RANK LIDO DO BANCO — nunca de um
# role declarado pelo cliente — e que cada ação ACEITA fica reviewável em
# `guild_governance_log` (migration 062), na forma append-only do `guild_vault_log`.
#
# Blocos:
#   1. fonte única do teto (const MaxMembers, lida do map E do arquivo; service não redeclara);
#   2. promote por NÃO-líder RECUSADO (server-side) e sem rastro;
#   3. promote pelo LÍDER passa: B vira officer no banco + rastro "promote"; oficial convida;
#   4. demote passa: B volta a member + rastro "demote";
#   5. kick pelo LÍDER remove: C perde a guild no SERVIDOR + rastro "kick";
#   6. kick por PAR não reconhecido recusado: ator que não é líder, alvo de fora da guild,
#      account inexistente, e um não-membro agindo — tudo cai em not_leader/not_member;
#   7. invariantes de liderança: ninguém se chuta (self_kick) e o caminho de escrita
#      `RemoveMember` NÃO remove o líder (0 mudanças);
#   8. TETO: guild limpa cheia até MaxMembers e o (N+1)-ésimo join é RECUSADO, com
#      JoinReason == roster_full, sem estourar a contagem;
#   9. args inválidos recusados (bad_args), sem rastro novo.
#   10. o mapa de frases: todo token que os verbos produzem tem braço em `Feedback`,
#       todo braço corresponde a um token produzido, e cada um tem linha no catálogo.
#
# Uso: godot --headless --path . -s tests/guild_governance_test.gd
# Exit code = checks falhos. Última linha: `== GUILD GOVERNANCE: N checks, M failures ==`.
#
# Regra dos harnesses `-s` (guild_vault_gate_test.gd:30, social_graph_test.gd:249): o
# main-loop compila antes de autoloads e class_names existirem — nada de identificador de
# autoload ou `class_name` em anotação de tipo; tudo via load()/get()/call(). Os verbos são
# `static func` em GuildRoster e são chamados pelo objeto do script carregado (idêntico a
# `sg.call("CanMessage", ...)` em social_graph_test).

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null

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

func _reason(res : Dictionary) -> String:
	return str(res.get("reason", ""))

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_runTests()

func _runTests():
	print("== guild governance: promote/demote/kick + teto + trilha ==")
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
	print("== boot wait done (%d ms) ==" % waited)

	# SQL+World prontos NÃO implicam o preload threadado do DB drenado; load()/quit() no
	# meio dos parses derruba o processo com os checks verdes (mesmo probe do vault gate).
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	Check(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit")

	var sql : Node = launcher.get("SQL")
	var economy : Node = launcher.get("Economy")
	if not Check(sql != null and economy != null, "SQL + Economy booteds") or sql == null or economy == null:
		_finish()
		return
	if economy.get("guildService") == null:
		economy.call("_post_launch")
	if not Check(economy.get("guildService") != null, "GuildService mounted on Economy"):
		_finish()
		return

	# A tabela só existe se a migration 062 foi APLICADA (não apenas criada no disco):
	# o carimbo anda junto com o schema, patch a patch.
	Check(int(sql.call("GetVersion")) >= 62, "base alcançou a migration 062 (db_version >= 62)")

	var roster : GDScript = load("res://sources/economy/GuildRoster.gd")
	var consts : Dictionary = roster.get_script_constant_map()
	var maxMembers : int = int(consts.get("MaxMembers", -1))

	# ---------------------------------------------------------------- 1. fonte única do teto
	CheckEq(maxMembers, 20, "GuildRoster declara MaxMembers = 20 (fonte do teto)")
	var rosterSrc : String = FileAccess.get_file_as_string("res://sources/economy/GuildRoster.gd")
	CheckEq(_occurrences(rosterSrc, "const MaxMembers : int ="), 1, "o teto é declarado UMA única vez (sem literal por call site)")
	Check(rosterSrc.contains("Count(guildID) >= MaxMembers") and rosterSrc.contains("IsFull(guildID)"), "admissão e recusa leem o MESMO MaxMembers (IsFull/JoinReason)")
	Check(not FileAccess.get_file_as_string("res://sources/economy/GuildService.gd").contains("MaxMembers : int ="), "o service não redeclara o teto (fonte única em GuildRoster)")
	if maxMembers != 20:
		_finish()
		return

	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()

	var guildName : String = "Gov Governance Guild"
	var capName : String = "Gov Cap Guild"
	# Idempotência: um run que morreu no meio deixa contas/fila; limpa antes de criar.
	_janitor(sql, guildName)
	_janitor(sql, capName)
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'GldGov%' OR nickname LIKE 'GldCap%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'gldgov\\_%' OR username LIKE 'gldcap\\_%';", [])

	# fixtures: A líder, B e C membros, D de fora (convidável).
	var charA : int = int(suites.call("CreateFixture", sql, "gldgov_a", "GldGovA"))
	var charB : int = int(suites.call("CreateFixture", sql, "gldgov_b", "GldGovB"))
	var charC : int = int(suites.call("CreateFixture", sql, "gldgov_c", "GldGovC"))
	var charD : int = int(suites.call("CreateFixture", sql, "gldgov_d", "GldGovD"))
	if not Check(charA != 0 and charB != 0 and charC != 0 and charD != 0, "fixtures criados (%d/%d/%d/%d)" % [charA, charB, charC, charD]):
		_finish()
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", charA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", charB))
	var acctC : int = int(sql.call("GetAccountIDForCharacter", charC))
	var acctD : int = int(sql.call("GetAccountIDForCharacter", charD))
	var guildID : int = int(economy.call("CreateGuild", acctA, charA, guildName))
	Check(guildID > 0, "A fundou a guild #%d como leader" % guildID)
	Check(bool(economy.call("JoinGuild", acctB, guildID)), "B entrou")
	Check(bool(economy.call("JoinGuild", acctC, guildID)), "C entrou")

	# ---------------------------------------------------------------- 2. não-líder promote RECUSADO
	CheckEq(_govCount(sql, guildID, "promote"), 0, "começa com zero rastro de promote")
	var badPromote : Dictionary = roster.call("Promote", acctB, acctC)
	Check(not bool(badPromote.get("ok", false)), "promote por membro (B) é RECUSADO")
	Check(_reason(badPromote) == "not_leader", "a recusa traz o token not_leader (got %s)" % _reason(badPromote))
	Check(_rankOf(sql, acctC) == "member", "o alvo não mudou de posto (recusa não escreve)")
	CheckEq(_govCount(sql, guildID, "promote"), 0, "recusa NÃO deixa rastro (trilha só de ação aceita)")

	# ---------------------------------------------------------------- 3. líder promote PASSA
	var goodPromote : Dictionary = roster.call("Promote", acctA, acctB)
	Check(bool(goodPromote.get("ok", false)), "promote pelo LÍDER passa")
	Check(_rankOf(sql, acctB) == "officer", "B virou officer no banco (posto alcançável no produto)")
	CheckEq(_govCount(sql, guildID, "promote"), 1, "promote aceito escreve UMA linha de rastro")
	# Oficial tem escopo de convite (não de kick): D entra por B.
	var inviteByOfficer : Dictionary = roster.call("Invite", acctB, acctD)
	Check(bool(inviteByOfficer.get("ok", false)), "oficial B convidou D (posto com escopo de convite)")

	# ---------------------------------------------------------------- 4. demote PASSA
	var demote : Dictionary = roster.call("Demote", acctA, acctB)
	Check(bool(demote.get("ok", false)), "demote pelo LÍDER passa")
	Check(_rankOf(sql, acctB) == "member", "B voltou a member (promover não é depósito eterno)")
	CheckEq(_govCount(sql, guildID, "demote"), 1, "demote aceito escreve rastro")

	# ---------------------------------------------------------------- 5. líder kick REMOVE no servidor
	var kick : Dictionary = roster.call("Kick", acctA, acctC)
	Check(bool(kick.get("ok", false)), "kick pelo LÍDER passa")
	CheckEq(_memberOf(sql, acctC), 0, "C perdeu a guild no SERVIDOR (não só na tela)")
	CheckEq(_govCount(sql, guildID, "kick"), 1, "kick aceito escreve rastro")

	# ---------------------------------------------------------------- 6. kick de par não reconhecido
	var peerKick : Dictionary = roster.call("Kick", acctB, acctA)
	Check(not bool(peerKick.get("ok", false)), "membro B não consegue chutar o líder")
	Check(_reason(peerKick) == "not_leader", "recusa traz not_leader (só o líder chuta)")
	var strangerTarget : Dictionary = roster.call("Kick", acctA, 987654)
	Check(not bool(strangerTarget.get("ok", false)), "kick de um account que a guild NÃO conhece é recusado")
	Check(_reason(strangerTarget) == "not_member", "recusa traz not_member (alvo de fora da guild)")
	var outsiderKick : Dictionary = roster.call("Kick", 876543, acctB)
	Check(not bool(outsiderKick.get("ok", false)), "um não-membro (rank inexistente) não consegue chutar")
	Check(_reason(outsiderKick) == "not_leader", "não-membro cai em not_leader (autorização vem do rank do banco)")

	# ---------------------------------------------------------------- 7. invariantes de liderança
	var selfKick : Dictionary = roster.call("Kick", acctA, acctA)
	Check(not bool(selfKick.get("ok", false)), "ninguém se chuta (self_kick)")
	Check(_reason(selfKick) == "self_kick", "recusa traz self_kick")
	Check(not bool(economy.call("RemoveMember", guildID, acctA)), "o caminho de escrita NÃO remove o líder (WHERE rank<>leader => 0 mudanças)")
	CheckEq(_memberOf(sql, acctA), guildID, "líder segue na guild (sem guilda órfã)")

	# ---------------------------------------------------------------- 8. TETO de roster
	var capLeader : int = int(suites.call("CreateFixture", sql, "gldcap_lead", "GldCapLead"))
	var capLeadAcct : int = int(sql.call("GetAccountIDForCharacter", capLeader))
	var capGuild : int = int(economy.call("CreateGuild", capLeadAcct, capLeader, capName))
	Check(capGuild > 0, "guild de teto fundada (#%d)" % capGuild)
	var fillerIdx : int = 1
	while fillerIdx < maxMembers:
		var fx : int = int(suites.call("CreateFixture", sql, "gldcap_%d" % fillerIdx, "GldCapNick%d" % fillerIdx))
		if fx == 0:
			break
		var fa : int = int(sql.call("GetAccountIDForCharacter", fx))
		economy.call("JoinGuild", fa, capGuild)
		fillerIdx += 1
	CheckEq(_countMembers(sql, capGuild), maxMembers, "fileira chegou exatamente ao teto (%d)" % maxMembers)
	var extra : int = int(suites.call("CreateFixture", sql, "gldcap_extra", "GldCapExtra"))
	var extraAcct : int = int(sql.call("GetAccountIDForCharacter", extra))
	var joinReason : String = str(roster.call("JoinReason", extraAcct, capGuild))
	Check(not bool(economy.call("JoinGuild", extraAcct, capGuild)), "o (N+1)-ésimo join é RECUSADO pelo teto")
	Check(joinReason == "roster_full", "JoinReason traz roster_full (got %s)" % joinReason)
	CheckEq(_countMembers(sql, capGuild), maxMembers, "a recusa manteve a fileira no teto (sem estouro)")

	# ---------------------------------------------------------------- 9. args inválidos
	var zeroKick : Dictionary = roster.call("Kick", 0, 0)
	Check(not bool(zeroKick.get("ok", false)) and _reason(zeroKick) == "bad_args", "Kick(0,0) = bad_args")
	CheckEq(_govCount(sql, guildID, "kick"), 1, "recusa por args não escreveu rastro novo")

	# ------------------------------------------------ 10. o mapa de frases do jogador
	_suiteFeedback(roster)

	# ---------------------------------------------------------------- limpeza
	_janitor(sql, guildName)
	_janitor(sql, capName)
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'GldGov%' OR nickname LIKE 'GldCap%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'gldgov\\_%' OR username LIKE 'gldcap\\_%';", [])
	_finish()

# ---------------------------------------------------------------- 10. o mapa de frases
# `Feedback` é o lado que o jogador lê. O cabeçalho dele promete as duas metades do vínculo,
# e nenhuma das duas era medida antes:
#   (a) todo token que os verbos produzem tem braço no mapa — um token sem braço cai na
#       linha genérica final, que é exatamente o vazamento que a AUDITORIA §13 nomeou;
#   (b) o mapa não é decoração: cada braço corresponde a um token que alguém produz.
# Os tokens são LIDOS do fonte, nas duas formas que a árvore escreve um motivo: a atribuição
# (`result["reason"] = "x"`, que o varredor de `reason_toast_test.gd` já olha) e o `return`
# nu de `JoinReason`/`RefusalFor` — a forma que aquele varredor NÃO enxerga, e por isso o
# cabeçalho de `GuildRoster` diz que ela precisa de cobertura própria. O corpo varrido é o
# das duas funções, não o arquivo inteiro: `return "officer"` de um rank não é token de
# razão, e contá-lo como tal inflaria o censo e fingiria mordida.
func _suiteFeedback(roster : Object) -> void:
	var rosterSrc : String = FileAccess.get_file_as_string("res://sources/economy/GuildRoster.gd")
	if not Check(not rosterSrc.is_empty(), "`GuildRoster.gd` foi lido — sem fonte não há censo"):
		return
	var produced : Dictionary = {}
	var assign : RegEx = RegEx.new()
	var bare : RegEx = RegEx.new()
	if assign.compile("result\\[\"reason\"\\][[:space:]]*=[[:space:]]*\"([a-z][a-z0-9_]{2,40})\"") != OK \
			or bare.compile("return[[:space:]]+\"([a-z][a-z0-9_]{2,40})\"") != OK:
		Check(false, "os dois padrões de varredura de motivo compilam")
		return
	for m : RegExMatch in assign.search_all(rosterSrc):
		produced[str(m.get_string(1))] = "atribuição"
	for fname : String in ["static func JoinReason(", "static func RefusalFor("]:
		for m : RegExMatch in bare.search_all(_funcText(rosterSrc, fname)):
			produced[str(m.get_string(1))] = "return nu"

	# As armas do mapa: só os rótulos do `match reason:`, porque o `match verb:` do ramo
	# feliz mora na mesma função e na mesma indentação.
	var fb : String = _funcText(rosterSrc, "static func Feedback(")
	if not Check(not fb.is_empty(), "`Feedback` existe no fonte de `GuildRoster`"):
		return
	var reasonBlock : String = fb.substr(fb.find("match reason:"))
	var arm : RegEx = RegEx.new()
	if arm.compile("(?m)^[[:space:]]+\"([a-z][a-z0-9_]{2,40})\":[[:space:]]*$") != OK:
		Check(false, "o padrão de braço de `match` compila")
		return
	var arms : Dictionary = {}
	for m : RegExMatch in arm.search_all(reasonBlock):
		arms[str(m.get_string(1))] = true

	var uncobertas : Array[String] = []
	for token : String in produced:
		if not arms.has(token):
			uncobertas.append(token)
	var decorativas : Array[String] = []
	for token : String in arms:
		if not produced.has(token):
			decorativas.append(token)
	Check(produced.size() >= 12 and arms.size() >= 12,
			"o censo é uma superfície real: %d tokens produzidos e %d braços no mapa" % [produced.size(), arms.size()])
	Check(produced.has("roster_full") and produced.has("not_leader"),
			"o varredor achou os dois tokens que o cabeçalho nomeia (`roster_full` por return, `not_leader` por atribuição)")
	CheckEq(uncobertas.size(), 0, "nenhum token produzido cai na linha genérica (%s)" % " | ".join(uncobertas))
	CheckEq(decorativas.size(), 0, "nenhum braço do mapa é decoração: todo braço tem produtor (%s)" % " | ".join(decorativas))

	# A linha genérica é LIDA do fonte, não copiada para cá: copiar faria deste check um
	# espelho do teste, e o que se quer saber é se o fonte ainda joga para algum lugar.
	var generic : String = _lastReturnString(fb)
	Check(not generic.is_empty(), "a linha final genérica de `Feedback` tem string (%s)" % generic)
	var frases : Dictionary = {}
	var cruas : Array[String] = []
	var repetidas : Array[String] = []
	for token : String in produced:
		var phrase : String = String(roster.call("Feedback", "kick", {"ok": false, "reason": token}, "Alvo"))
		if phrase == generic or phrase.is_empty():
			cruas.append(token)
		if frases.has(phrase):
			repetidas.append("%s==%s" % [token, str(frases[phrase])])
		else:
			frases[phrase] = token
	CheckEq(cruas.size(), 0, "cada token produzido devolve frase própria, não a genérica (%s)" % " | ".join(cruas))
	CheckEq(repetidas.size(), 0, "duas razões diferentes não podem dizer a mesma coisa (%s)" % " | ".join(repetidas))
	# Controle da outra metade: um token que ninguém produz tem de cair na genérica. Sem
	# isto, "0 na genérica" acima pode ser um `match` que devolve algo para qualquer coisa.
	var bogus : String = String(roster.call("Feedback", "kick", {"ok": false, "reason": "token_que_ninguem_produz_aqui"}, "Alvo"))
	Check(bogus == generic, "um token fora do mapa cai na genérica — é o caminho que a régua acima prova existir (%s)" % bogus)

	# O catálogo: frase no mapa sem linha em `data/i18n/ui.csv` é inglês cru na tela em
	# pt-BR. Os nomes são os que `PlayerReasons` procura (`reason/<token>`).
	var catalog : String = FileAccess.get_file_as_string("res://data/i18n/ui.csv")
	if not Check(catalog.length() > 100, "o catálogo i18n foi lido (%d bytes)" % catalog.length()):
		return
	var semLinha : Array[String] = []
	for token : String in produced:
		if not catalog.contains("\"reason/" + token + "\""):
			semLinha.append(token)
	CheckEq(semLinha.size(), 0, "todo motivo do roster tem linha no catálogo (%s)" % " | ".join(semLinha))

# Texto do corpo de uma função: do cabeçalho até a próxima função de topo.
func _funcText(src : String, header : String) -> String:
	var at : int = src.find(header)
	if at < 0:
		return ""
	var rest : String = src.substr(at + header.length())
	var nextStatic : int = rest.find("\nstatic func ")
	var nextPlain : int = rest.find("\nfunc ")
	var cut : int = nextStatic
	if nextPlain >= 0 and (cut < 0 or nextPlain < cut):
		cut = nextPlain
	return rest.substr(0, cut) if cut >= 0 else rest

# A última string de `return` de um corpo — é a linha de fallback, e lê-la do fonte evita
# que a régua compare o programa com uma cópia que o teste carrega por engano.
func _lastReturnString(body : String) -> String:
	var at : int = body.rfind("return \"")
	if at < 0:
		return ""
	var tail : String = body.substr(at + 8)
	var stop : int = tail.find("\"")
	return tail.substr(0, stop) if stop > 0 else ""


# todas caem no MESMO banco que o servidor escreveu, não num cache do cliente).
func _rankOf(sql : Node, accountID : int) -> String:
	var rows : Array = sql.call("QueryBindings", "SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str((rows[0] as Dictionary).get("rank", "")) if not rows.is_empty() else ""

func _memberOf(sql : Node, accountID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int((rows[0] as Dictionary).get("guild_id", 0)) if not rows.is_empty() else 0

func _countMembers(sql : Node, guildID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID])
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _govCount(sql : Node, guildID : int, action : String) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM guild_governance_log WHERE guild_id = ? AND action = ?;", [guildID, action])
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _occurrences(hay : String, needle : String) -> int:
	var n : int = 0
	var i : int = hay.find(needle)
	while i >= 0:
		n += 1
		i = hay.find(needle, i + needle.length())
	return n

func _janitor(sql : Node, guildName : String) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_governance_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])

func _finish():
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== GUILD GOVERNANCE: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
