extends SceneTree

# SOM-IDLE social (AUDITORIA_2026-09-27 §14 SOCIAL): régua do grafo social — arestas,
# tetos, direção da entrega e plano de acesso.
#
# O subsistema (`sources/social/SocialGraph.gd` + migration 061 + os cinco verbos em
# `WorldCommands.gd` + o corte em `Network.ChatPlayer`) landed sem nenhum harness. Este
# arquivo é a régua que faltava, bloco a bloco:
#
#  0/0b. forma do módulo, migration aplicada, tabela e os três índices.
#  1. fixtures: contas REAIS (o teto é conferido com alvos que existem de verdade).
#  2. amizade é par: um clique escreve as DUAS arestas e um `/unfriend` tira as duas.
#     Lido no SQL cru, não só no `Has` do módulo — é a convenção (b) da migration 061.
#  3. auto-relacionamento recusado nos dois tipos, sem tocar no banco.
#  4. segunda adição do mesmo alvo recusada (`already`), contagem de linhas inalterada.
#  5. bloqueio é unilateral: uma linha, sem espelho — e a tabela de verdade de
#     `IsIgnored`/`CanMessage` conferida nos dois sentidos.
#  6. tetos na BORDA exata: o 64º amigo passa e o 65º não; o lado do ALVO também é
#     conferido (`social_cap_target`), senão um segundo clique estoura o teto pela
#     metade; bloquear é o dobro de amigos (128/129); a recusa não escreve; e tirar um
#     libera o 65º (o teto é do estado atual, não um carimbo).
#  7. recusas de forma (kind inválido, conta zero/negativa, id que não existe) não
#     criam linha — e `Add` para id inexistente morre em `unknown_target`, que é o que
#     impede a conta reciclada de um DELETE de virar "eu ignoro o jogador novo".
#  8. todo token de recusa que o módulo produz tem exatamente uma frase, as frases são
#     distintas, nenhuma cai no genérico, e nenhum token com `_` chega cru à tela.
#  9. `List`/`DescribeLists`: ordem estável por nick, `since` preenchido, tamanho
#     batendo com `Count`, teto no rótulo, e palavra errada não devolve a lista do
#     tipo errado.
# 10. o `EXPLAIN QUERY PLAN` das três consultas do hot path, montadas a partir do TEXTO
#     SQL QUE ESTÁ NO PRODUTO (não de uma cópia minha): SEARCH + INDEX e NUNCA SCAN. É a
#     única coisa que prova que a checagem por linha entregue é barata — e a régua se
#     contra-prova na mesma suíte: sem a chave primária o plano vira SCAN (mutação desfeita
#     ali mesmo).
# 11. custo real de N checagens de ignore (teto folgado: pega catástrofe, não flake).
# 12. A DIREÇÃO da entrega, medida no `Network.ChatPlayer` e no `Server.TriggerChat`
#     reais, com sessão viva e agente real em instância: A ignora B → a linha de B não
#     chega em A, a de A chega em B, o eco/NPC/peer-sem-conta continuam passando.
# 13. a rota de comando no runtime real (`/friend`, `/unfriend`, `/ignore`, `/unignore`,
#     `/social`, inclusive via `CommandManager.Handle`, que é o caminho do botão): a conta
#     de quem age sai do PEER, nunca do payload.
# 14. a porta GM MEDIDA no despacho: recusa por permissão, execução para ADMIN, bypass por
#     `SHAMBLETA_GM_MODE=1` e o retorno da recusa quando a env se apaga — `gm_gate_fix_test.gd`
#     confere o fonte; este prova o comportamento na árvore viva.
#
# Uso: godot --headless --path . -s tests/social_graph_test.gd
#       (XDG_DATA_HOME/XDG_CACHE_HOME próprios — ver scripts/test.sh.)
# Exit code: número de checks falhos. Última linha: == SOCIAL GRAPH: N checks, M failures ==
#
# Regra dos harnesses `-s` (run_idle_tests.gd:1, social_fix_test.gd:14): o main-loop é
# compilado ANTES de autoloads e `class_name` existirem — nada de identificador de
# autoload (Launcher/Network/Peers/...) nem `class_name` de projeto em anotação de tipo
# neste arquivo. Os autoloads EXISTEM em runtime (medido: `root.get_node_or_null` achou
# Launcher e Network), mas mesmo assim tudo aqui é load()/get()/call().

const PROBE_SOURCE := """
extends "res://sources/network/client/Client.gd"

var inbox : Array = []
var byPeer : Dictionary = {}

func _record(methodName : String, peerID : int, payload : Dictionary):
	payload["method"] = methodName
	payload["peer"] = peerID
	inbox.append(payload)
	if not byPeer.has(peerID):
		byPeer[peerID] = []
	(byPeer[peerID] as Array).append(payload)

func ChatPlayer(channelName : String, callerName : String, text : String, agentRID : int, peerID : int):
	_record("ChatPlayer", peerID, {"channel": channelName, "caller": callerName, "text": text, "rid": agentRID})

func ChatSystem(channelName : String, text : String, peerID : int):
	_record("ChatSystem", peerID, {"channel": channelName, "text": text})

func CommandFeedback(feedback : String, peerID : int):
	_record("CommandFeedback", peerID, {"text": feedback})
"""

const FixturePass : String = "senha-do-social-graph-123"
const PeerBase : int = 830000			# longe dos 820000 do guild_chat_fanout
const RidBase : int = 930001			# RIDs sintéticos do WorldAgent.agents
const UnknownAccount : int = 999999		# id que não existe em `account`
const GhostPeer : int = 899999			# peer vivo sem conta

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null
var launcher : Node = null
var sql : Node = null
var network : Node = null
var sg : GDScript = null
var peersScript : GDScript = null
var worldAgentScript : GDScript = null
var playerAgentScript : GDScript = null
var baseAgentScript : GDScript = null
var cmdScript : GDScript = null
var chatScript : GDScript = null
var guiCommons : GDScript = null
var sgSource : String = ""
var probe : Node = null
var originalClient : Node = null

var _names : Array = []
var _accounts : Array = []
var _syntheticRIDs : Array = []
var _syntheticPeers : Array = []
var _spawnedAgents : Array = []
var _farmMap : RefCounted = null
var _serverNode : Node = null
var _farmInstID : int = 0
var _tableMutated : bool = false
var _friendCap : int = 64
var _ignoreCap : int = 128
var _kindFriend : String = "friend"
var _kindIgnore : String = "ignore"

# ------------------------------------------------------------------ machinery
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

func CheckB(value : bool, expected : bool, label : String) -> bool:
	return Check(value == expected, "%s (got %s, want %s)" % [label, str(value), str(expected)])

func CheckS(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _hasScriptMethod(script : Object, methodName : String) -> bool:
	if script == null:
		return false
	for entry in script.get_script_method_list():
		if str(entry.get("name", "")) == methodName:
			return true
	return false

func _repoFile(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()

# Só o corpo do método (precedente: guild_vault_gate_test.gd:299, web_delivery_test.gd:387).
# Régua que lê o arquivo inteiro fica verde quando o código some e a frase sobrevive no
# comentário que explicava o código.
func _bodyOf(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var rest : String = src.substr(at)
	var next : int = rest.find("\nfunc ", 1)
	return rest.substr(0, next) if next > 0 else rest

func _acct(index : int) -> int:
	return int(_accounts[index]) if index >= 0 and index < _accounts.size() else 0

# ------------------------------------------------------------------ SocialGraph by hand
func _add(kind : String, fromAccount : int, targetAccount : int) -> Dictionary:
	return Dictionary(sg.call("Add", kind, fromAccount, targetAccount))

func _remove(kind : String, fromAccount : int, targetAccount : int) -> Dictionary:
	return Dictionary(sg.call("Remove", kind, fromAccount, targetAccount))

func _has(kind : String, accountID : int, targetID : int) -> bool:
	return bool(sg.call("Has", kind, accountID, targetID))

func _count(kind : String, accountID : int) -> int:
	return int(sg.call("Count", kind, accountID))

func _list(kind : String, accountID : int) -> Array:
	return sg.call("List", kind, accountID) as Array

func _isIgnored(fromAccount : int, targetAccount : int) -> bool:
	return bool(sg.call("IsIgnored", fromAccount, targetAccount))

func _canMessage(fromAccount : int, targetAccount : int) -> bool:
	return bool(sg.call("CanMessage", fromAccount, targetAccount))

func _blocked(senderRID : int, peerID : int) -> bool:
	return bool(sg.call("DeliveryBlocked", senderRID, peerID))

func _reason(result : Dictionary) -> String:
	return str(result.get("reason", ""))

func _message(result : Dictionary, kind : String, add : bool, nick : String, accountID : int = 0) -> String:
	return str(sg.call("Message", result, kind, add, nick, accountID))

# ------------------------------------------------------------------ SQL cru
func _countSql(query : String, params : Array) -> int:
	var rows : Array = sql.call("QueryBindings", query, params)
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _edgeRows(fromAccount : int, targetAccount : int, kind : String) -> int:
	return _countSql("SELECT COUNT(*) AS n FROM social_graph WHERE account_id = ? AND target_account_id = ? AND kind = ?;", [fromAccount, targetAccount, kind])

func _kindRows(accountID : int, kind : String) -> int:
	return _countSql("SELECT COUNT(*) AS n FROM social_graph WHERE account_id = ? AND kind = ?;", [accountID, kind])

func _touchingRows(accountID : int) -> int:
	return _countSql("SELECT COUNT(*) AS n FROM social_graph WHERE account_id = ? OR target_account_id = ?;", [accountID, accountID])

func _totalRows() -> int:
	return _countSql("SELECT COUNT(*) AS n FROM social_graph;", [])

func _kindTotal(kind : String) -> int:
	return _countSql("SELECT COUNT(*) AS n FROM social_graph WHERE kind = ?;", [kind])

func _initialize():
	_runTests()

func _runTests() -> void:
	print("== SOM-SOCIAL: grafo, tetos, direção da entrega e plano de acesso ==")
	launcher = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and worldNode != null and bool(worldNode.get("isInitialized")):
			break
	print("== boot wait done (%d ms) ==" % waited)

	# O preload threadado do DB precisa estar drenado antes de qualquer load()/quit()
	# (sources/db/DB.gd:232; mesma espera de social_fix_test.gd:86).
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()/quit()"):
		_finish()
		return

	network = _autoload("Network")
	_serverNode = network.get("ENetServer") as Node
	sg = load("res://sources/social/SocialGraph.gd")
	peersScript = load("res://sources/network/server/Peers.gd")
	worldAgentScript = load("res://sources/world/WorldAgent.gd")
	playerAgentScript = load("res://sources/actor/agent/variants/PlayerAgent.gd")
	baseAgentScript = load("res://sources/actor/agent/BaseAgent.gd")
	cmdScript = load("res://sources/debug/CommandManager.gd")
	chatScript = load("res://sources/network/server/ChatModeration.gd")
	guiCommons = load("res://sources/gui/GUICommons.gd")
	sgSource = _repoFile("res://sources/social/SocialGraph.gd")
	if not Check(sql != null and network != null and sg != null and peersScript != null and worldAgentScript != null
			and playerAgentScript != null and baseAgentScript != null and cmdScript != null and chatScript != null
			and guiCommons != null and not sgSource.is_empty(),
			"booteds + SocialGraph/Peers/WorldAgent/PlayerAgent/BaseAgent/CommandManager/ChatModeration/GUICommons carregados"):
		_finish()
		return

	_moduleShape()
	if not _migrationBlock():
		_finish()
		return
	_fixtures()
	if _accounts.size() < 2 * (_friendCap + 2):
		print("FATAL: fixtures insuficientes para as seções de teto (%d)" % _accounts.size())
		_finish()
		return
	_symmetryBlock()
	_selfRefusalBlock()
	_duplicateBlock()
	_ignoreBlock()
	_capsBlock()
	_malformedBlock()
	_messagesBlock()
	_listsBlock()
	_plansBlock()
	_costBlock()
	await _deliveryBlock()
	await _commandBlock()
	await _gmGateBlock()
	_finish()

# ------------------------------------------------------------------ 0. forma do módulo
func _moduleShape() -> void:
	print("== bloco 0: API e constantes do módulo ==")
	var consts : Dictionary = sg.get_script_constant_map()
	_kindFriend = str(consts.get("KindFriend", ""))
	_kindIgnore = str(consts.get("KindIgnore", ""))
	CheckS(_kindFriend, "friend", "KindFriend == friend")
	CheckS(_kindIgnore, "ignore", "KindIgnore == ignore")
	_friendCap = int(consts.get("MaxFriends", -1))
	_ignoreCap = int(consts.get("MaxIgnores", -1))
	CheckEq(_friendCap, 64, "MaxFriends declarado")
	CheckEq(_ignoreCap, 128, "MaxIgnores declarado (o dobro de amigos)")
	CheckEq(_ignoreCap, 2 * _friendCap, "o dobro é a regra escrita, não um número solto")
	for methodName in ["Add", "Remove", "IsIgnored", "CanMessage", "DeliveryBlocked", "Has", "Count", "List",
			"CommandName", "ListName", "VerbName", "Message", "DescribeLists"]:
		Check(_hasScriptMethod(sg, methodName), "SocialGraph.%s exposto" % methodName)
	# Política sem estado: nada aqui é variável de instância, e é por isso que não há
	# cache a invalidar quando alguém bloqueia/desbloqueia no meio de uma sessão. A régua
	# lê a FONTE: sob `-s`, `GDScript.get_script_property_list()` devolve a própria linha
	# do recurso (1 entrada), então contar ali não mediria nada.
	Check(not sgSource.contains("static var"), "SocialGraph não tem estado estático compartilhado")
	var stateLines : Array[String] = []
	for raw in sgSource.split("\n"):
		var line : String = String(raw)
		# Coluna 0 = estado do módulo; linha indentada é variável local de função.
		if line.begins_with("var ") or line.begins_with("@export") or line.begins_with("onready var "):
			stateLines.append(line.strip_edges())
	Check(stateLines.is_empty(), "SocialGraph não declara variável de instância (%s)" % str(stateLines))

# ------------------------------------------------------------------ 0b. migration/tabela
func _migrationBlock() -> bool:
	print("== bloco 0b: migration 061, tabela e índices ==")
	if not Check(int(sql.call("GetVersion")) >= 61, "base alcançou a migration 061 (db_version >= 61)"):
		return false
	var tables : Array = sql.call("Query", "SELECT name FROM sqlite_master WHERE type='table' AND name='social_graph';")
	if not Check(not tables.is_empty(), "tabela social_graph existe"):
		return false
	var indexes : Array = sql.call("Query", "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='social_graph';")
	var indexNames : Array = []
	for row in indexes:
		indexNames.append(str((row as Dictionary).get("name", "")))
	Check("idx_social_graph_owner" in indexNames, "índice idx_social_graph_owner aplicado (%s)" % str(indexNames))
	Check("idx_social_graph_target" in indexNames, "índice idx_social_graph_target aplicado (%s)" % str(indexNames))
	Check("sqlite_autoindex_social_graph_1" in indexNames, "autoindex da chave primária existe (%s)" % str(indexNames))
	var migText : String = _repoFile("res://data/conf/migrations/061_social_graph.sql")
	Check(not migText.is_empty(), "arquivo da migration 061 lido")
	Check(migText.contains("PRIMARY KEY (account_id, target_account_id, kind)"), "migration: chave primária tripla (a aresta duplicada não nasce)")
	Check(migText.contains("CREATE INDEX IF NOT EXISTS idx_social_graph_owner ON social_graph(account_id, kind, target_account_id);"), "migration: índice da lista do dono")
	Check(migText.contains("CREATE INDEX IF NOT EXISTS idx_social_graph_target ON social_graph(target_account_id, kind, account_id);"), "migration: índice do lado do alvo")
	Check(migText.contains("USING COVERING INDEX sqlite_autoindex_social_graph_1"), "migration promete o plano medido do hot path (SEARCH pela PRIMARY KEY)")
	return true

# ------------------------------------------------------------------ 1. fixtures
func _fixtures() -> void:
	print("== bloco 1: contas de fixture ==")
	_janitor()
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	var tag : int = int(Time.get_unix_time_from_system())
	var wanted : int = 2 * (_friendCap + 2)
	var created : int = 0
	for i in wanted:
		var userName : String = "socg_%d_%d" % [tag, i]
		if not bool(sql.call("AddAccount", userName, FixturePass, userName + "@socialgraph.test.local",
				consts.get("AgreementTosVersion"), consts.get("AgreementPrivacyVersion"), "203.0.113.9")):
			continue
		_names.append(userName)
		_accounts.append(int(sql.call("GetAccountID", userName)))
		created += 1
	CheckEq(created, wanted, "contas de fixture criadas (%d de %d)" % [created, wanted])
	CheckEq(_accounts.size(), wanted, "todos os ids de conta resolvidos")
	# Partir do zero é o que transforma "a recusa não escreveu nada" em asserção e não
	# em delta: resto de execução abortada aparece aqui.
	var leftovers : int = 0
	for accountID in _accounts:
		leftovers += _touchingRows(int(accountID))
	CheckEq(leftovers, 0, "nenhuma aresta de execução anterior sobrou (o janitor funcionou)")
	Check(_totalRows() >= 0, "a tabela é legível")

func _janitor() -> void:
	sql.call("ExecuteBindings", "DELETE FROM social_graph WHERE account_id IN (SELECT account_id FROM account WHERE username LIKE 'socg%');", [])
	sql.call("ExecuteBindings", "DELETE FROM social_graph WHERE target_account_id IN (SELECT account_id FROM account WHERE username LIKE 'socg%');", [])
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE 'SocGraph%';", [])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE 'socg%';", [])

# Papéis nos dois pools de conta (ver o cabeçalho de `_capsBlock`).
func _aOwner() -> int:
	return _acct(0)

func _aTargetAt(offset : int) -> int:
	# 0.._friendCap-1 são os alvos do teto; _friendCap é o "(teto+1)-ésimo".
	return _acct(1 + offset)

func _bHub() -> int:
	return _acct(_friendCap + 2)

func _bFillerAt(offset : int) -> int:
	return _acct(_friendCap + 3 + offset)

func _bOutsider() -> int:
	return _acct(2 * _friendCap + 3)

# ------------------------------------------------------------------ 2. simetria da amizade
func _symmetryBlock() -> void:
	print("== bloco 2: amizade é par ==")
	var kind : String = _kindFriend
	var a : int = _aOwner()
	var b : int = _aTargetAt(0)
	var before : int = _totalRows()
	var added : Dictionary = _add(kind, a, b)
	Check(bool(added.get("ok", false)), "Add(friend, A, B) aceito (%s)" % _reason(added))
	CheckEq(_edgeRows(a, b, kind), 1, "aresta A -> B escrita")
	CheckEq(_edgeRows(b, a, kind), 1, "aresta B -> A escrita (a simetria é do banco, não do Has)")
	CheckEq(_totalRows() - before, 2, "um clique escreveu exatamente DUAS linhas")
	CheckB(_has(kind, a, b), true, "Has(A, B) verdadeiro")
	CheckB(_has(kind, b, a), true, "Has(B, A) verdadeiro sem ninguém ter pedido")
	CheckEq(_count(kind, a), 1, "Count(A) == 1")
	CheckEq(_count(kind, b), 1, "Count(B) == 1 (o espelho conta para o dono do outro lado)")
	CheckEq(int(added.get("account_id", 0)), a, "o resultado devolve a conta de quem agiu")
	CheckEq(int(added.get("target_account_id", 0)), b, "e a do alvo")
	var removed : Dictionary = _remove(kind, a, b)
	Check(bool(removed.get("ok", false)), "Remove(friend, A, B) aceito")
	CheckEq(_edgeRows(a, b, kind), 0, "aresta A -> B removida")
	CheckEq(_edgeRows(b, a, kind), 0, "aresta B -> A removida junto")
	CheckEq(_touchingRows(a), 0, "A voltou a zero arestas de amigo")
	CheckEq(_touchingRows(b), 0, "B voltou a zero arestas de amigo")
	_add(kind, a, b)
	CheckEq(_edgeRows(a, b, kind), 1, "re-adicionar não duplica a linha (PRIMARY KEY tripla)")
	CheckEq(_edgeRows(b, a, kind), 1, "nem o espelho")
	_remove(kind, a, b)
	CheckEq(_touchingRows(a), 0, "limpo de novo")

# ------------------------------------------------------------------ 3. auto-relacionamento
func _selfRefusalBlock() -> void:
	print("== bloco 3: auto-relacionamento recusado ==")
	var a : int = _aOwner()
	var before : int = _totalRows()
	for kind in [_kindFriend, _kindIgnore]:
		var result : Dictionary = _add(kind, a, a)
		Check(not bool(result.get("ok", false)), "Add(%s, A, A) recusado" % kind)
		CheckS(_reason(result), "self_relation", "motivo de Add(%s, A, A)" % kind)
		CheckS(_message(result, kind, true, "eu"), "You cannot /%s yourself" % str(sg.call("CommandName", kind, true)),
				"frase de self_relation para %s" % kind)
	CheckEq(_totalRows() - before, 0, "auto-relacionamento não escreveu nenhuma linha")
	CheckS(_reason(_remove(_kindFriend, a, a)), "self_relation", "Remove de si mesmo também recusa")
	CheckS(_reason(_remove(_kindIgnore, a, a)), "self_relation", "e no ignore também")
	CheckEq(_touchingRows(a), 0, "A continua sem aresta nenhuma")
	CheckB(_has(_kindFriend, 0, 0), false, "Has(0, 0) é falso, não um SELECT sem WHERE")
	CheckEq(_count(_kindFriend, 0), 0, "Count(0) == 0")
	CheckB(_isIgnored(0, 0), false, "IsIgnored(0, 0) falso")
	CheckB(_canMessage(0, 0), true, "CanMessage com id <= 0 deixa passar (sem conta não há sanção)")

# ------------------------------------------------------------------ 4. duplicidade
func _duplicateBlock() -> void:
	print("== bloco 4: segunda adição ==")
	var a : int = _aOwner()
	var b : int = _aTargetAt(0)
	Check(bool(_add(_kindFriend, a, b).get("ok", false)), "primeira adição aceita")
	var second : Dictionary = _add(_kindFriend, a, b)
	Check(not bool(second.get("ok", false)), "segunda adição do mesmo alvo recusada")
	CheckS(_reason(second), "already", "motivo == already")
	CheckEq(_edgeRows(a, b, _kindFriend), 1, "o lado pedido continua com UMA linha")
	CheckEq(_edgeRows(b, a, _kindFriend), 1, "e o espelho também (a recusa não desfez nada)")
	CheckEq(_count(_kindFriend, a), 1, "Count não mudou com a recusa")
	Check(bool(_add(_kindIgnore, a, b).get("ok", false)), "bloquear quem já é amigo é aceito (as duas arestas são independentes)")
	CheckEq(_kindRows(a, _kindFriend), 1, "a amizade não foi tocada pelo bloqueio")
	CheckEq(_kindRows(a, _kindIgnore), 1, "nem o bloqueio pela amizade")
	_remove(_kindFriend, a, b)
	_remove(_kindIgnore, a, b)

# ------------------------------------------------------------------ 5. ignore unilateral
func _ignoreBlock() -> void:
	print("== bloco 5: bloqueio é unilateral ==")
	var a : int = _aOwner()
	var b : int = _aTargetAt(0)
	var before : int = _totalRows()
	Check(bool(_add(_kindIgnore, a, b).get("ok", false)), "Add(ignore, A, B) aceito")
	CheckEq(_totalRows() - before, 1, "um clique de bloqueio escreveu UMA linha (não duas)")
	CheckEq(_edgeRows(a, b, _kindIgnore), 1, "aresta A -> B existe")
	CheckEq(_edgeRows(b, a, _kindIgnore), 0, "B NÃO passou a ignorar A de graça")
	CheckB(_has(_kindIgnore, a, b), true, "Has(ignore, A, B)")
	CheckB(_has(_kindIgnore, b, a), false, "Has(ignore, B, A) falso")
	# Tabela de verdade da direção: `IsIgnored(from, to)` responde "a linha de `from`
	# chega em `to`?" — quem cala a entrega é a aresta de QUEM RECEBE.
	CheckB(_isIgnored(a, b), false, "IsIgnored(A, B) falso: a linha de A chega em B")
	CheckB(_isIgnored(b, a), true, "IsIgnored(B, A) verdadeiro: a linha de B não chega em A")
	CheckB(_canMessage(a, b), true, "CanMessage(A, B): A fala, B ouve")
	CheckB(_canMessage(b, a), false, "CanMessage(B, A): B fala, A não ouve")
	CheckB(_isIgnored(a, a), false, "IsIgnored(x, x) falso (sem aresta própria)")
	CheckB(_canMessage(b, b), true, "CanMessage(x, x) verdadeiro (eco nunca é sanção)")
	# A definição declarada no produto é a espelhada: IsIgnored(f,t) == Has(ignore,t,f).
	for pair in [[a, b], [b, a], [a, a]]:
		CheckB(_isIgnored(int(pair[0]), int(pair[1])), _has(_kindIgnore, int(pair[1]), int(pair[0])),
				"IsIgnored(%d, %d) == Has(ignore, %d, %d)" % [int(pair[0]), int(pair[1]), int(pair[1]), int(pair[0])])
	var removed : Dictionary = _remove(_kindIgnore, a, b)
	Check(bool(removed.get("ok", false)), "Remove(ignore, A, B) aceito")
	CheckEq(_kindRows(a, _kindIgnore), 0, "a aresta do dono caiu")
	CheckEq(_kindRows(b, _kindIgnore), 0, "e não havia espelho a cair")
	CheckB(_isIgnored(b, a), false, "depois do /unignore a linha de B chega de novo")

# ------------------------------------------------------------------ 6. tetos
func _capsBlock() -> void:
	print("== bloco 6: tetos na borda (amigos %d, bloqueios %d) ==" % [_friendCap, _ignoreCap])
	var a : int = _aOwner()
	var filled : int = 0
	for i in _friendCap:
		if bool(_add(_kindFriend, a, _aTargetAt(i)).get("ok", false)):
			filled += 1
	CheckEq(filled, _friendCap, "%d amizades seguidas aceitas" % _friendCap)
	CheckEq(_count(_kindFriend, a), _friendCap, "Count(friend, A) == MaxFriends")
	CheckEq(_kindRows(a, _kindFriend), _friendCap, "e o banco tem exatamente essas linhas")
	CheckEq(_kindTotal(_kindFriend), _friendCap * 2, "cada uma delas tem o espelho (%d linhas no total)" % (_friendCap * 2))
	var over : Dictionary = _add(_kindFriend, a, _aTargetAt(_friendCap))
	Check(not bool(over.get("ok", false)), "o %dº amigo é recusado" % (_friendCap + 1))
	CheckS(_reason(over), "social_cap", "motivo == social_cap")
	CheckEq(_count(_kindFriend, a), _friendCap, "a recusa não estourou o teto")
	CheckEq(_kindTotal(_kindFriend), _friendCap * 2, "e não escreveu linha nenhuma, de nenhum lado")
	CheckB(_has(_kindFriend, a, _aTargetAt(_friendCap)), false, "o %dº alvo não virou amigo" % (_friendCap + 1))
	Check(bool(_remove(_kindFriend, a, _aTargetAt(0)).get("ok", false)), "remover um amigo libera uma vaga")
	CheckEq(_count(_kindFriend, a), _friendCap - 1, "Count caiu para %d" % (_friendCap - 1))
	Check(bool(_add(_kindFriend, a, _aTargetAt(_friendCap)).get("ok", false)), "com a vaga livre, o antigo %dº entra" % (_friendCap + 1))
	CheckEq(_count(_kindFriend, a), _friendCap, "voltou ao teto")
	# Lado do ALVO: um hub cheio não pode ser adicionado por fora — um teto que só olha
	# quem pede é um teto que o segundo clique estoura pela metade.
	var hub : int = _bHub()
	var hubFilled : int = 0
	for i in _friendCap:
		if bool(_add(_kindFriend, hub, _bFillerAt(i)).get("ok", false)):
			hubFilled += 1
	CheckEq(hubFilled, _friendCap, "hub montado com %d amigos" % _friendCap)
	var outsider : int = _bOutsider()
	CheckEq(_count(_kindFriend, outsider), 0, "o forasteiro está zerado")
	var targetFull : Dictionary = _add(_kindFriend, outsider, hub)
	Check(not bool(targetFull.get("ok", false)), "adicionar quem já está no teto é recusado pelo lado do ALVO")
	CheckS(_reason(targetFull), "social_cap_target", "motivo == social_cap_target")
	CheckS(_message(targetFull, _kindFriend, true, "hub"), "'hub' already has %d friends and cannot add more" % _friendCap,
			"a frase do lado do alvo diz o teto do outro")
	CheckEq(_touchingRows(outsider), 0, "a recusa não escreveu nada do forasteiro")
	CheckEq(_count(_kindFriend, hub), _friendCap, "e o hub continua no teto, não em %d" % (_friendCap + 1))
	# Bloqueios: o teto é o dobro, conferido na borda exata.
	var ignoreOwner : int = _bOutsider()
	var ignored : int = 0
	for i in _ignoreCap:
		if bool(_add(_kindIgnore, ignoreOwner, _acct(i)).get("ok", false)):
			ignored += 1
	CheckEq(ignored, _ignoreCap, "%d bloqueios seguidos aceitos" % _ignoreCap)
	CheckEq(_count(_kindIgnore, ignoreOwner), _ignoreCap, "Count(ignore) == MaxIgnores")
	CheckEq(_kindTotal(_kindIgnore), _ignoreCap, "e o total de arestas de ignore é exatamente esse (bloqueio não espelha)")
	var overIgnore : Dictionary = _add(_kindIgnore, ignoreOwner, _acct(_ignoreCap))
	Check(not bool(overIgnore.get("ok", false)), "o %dº bloqueio é recusado" % (_ignoreCap + 1))
	CheckS(_reason(overIgnore), "social_cap", "motivo == social_cap também no ignore")
	CheckEq(_count(_kindIgnore, ignoreOwner), _ignoreCap, "o teto de ignore não foi furado")
	CheckEq(_kindRows(_acct(0), _kindIgnore), 0, "quem foi bloqueado não ganhou aresta de bloqueio")
	CheckB(_isIgnored(ignoreOwner, _acct(0)), false, "nem passou a bloquear de volta")
	Check(bool(_remove(_kindIgnore, ignoreOwner, _acct(0)).get("ok", false)), "liberar um bloqueio aceita")
	Check(bool(_add(_kindIgnore, ignoreOwner, _acct(0)).get("ok", false)), "e a vaga liberada re-aceita no teto")
	Check(_message(over, _kindFriend, true, "t").contains(str(_friendCap)), "a frase do teto de amigos traz o número")
	Check(_message(overIgnore, _kindIgnore, true, "t").contains(str(_ignoreCap)), "a frase do teto de bloqueios traz o dele")

# ------------------------------------------------------------------ 7. recusas de forma
func _malformedBlock() -> void:
	print("== bloco 7: forma, alvo inexistente e login ==")
	var a : int = _aOwner()
	var before : int = _totalRows()
	for kind in ["", "friend ", "block", "FRIEND", "report", "friends"]:
		CheckS(_reason(_add(kind, a, _aTargetAt(0))), "bad_kind", "Add('%s') recusado por kind inválido" % kind)
	CheckS(_reason(_remove("amigo", a, _aTargetAt(0))), "bad_kind", "Remove também valida kind")
	CheckS(_reason(_add(_kindFriend, 0, _aTargetAt(0))), "not_logged_in", "Add de quem não tem conta")
	CheckS(_reason(_add(_kindFriend, -3, _aTargetAt(0))), "not_logged_in", "id negativo também")
	CheckS(_reason(_add(_kindFriend, a, 0)), "not_logged_in", "alvo zero é forma, não 'unknown_target'")
	CheckS(_reason(_add(_kindFriend, a, UnknownAccount)), "social_cap",
			"com a própria lista cheia, o teto do ator vem antes da existência do alvo")
	CheckS(_reason(_add(_kindFriend, _bOutsider(), UnknownAccount)), "unknown_target",
			"id que não existe em account (dono com vaga) é 'unknown_target'")
	CheckS(_reason(_add(_kindIgnore, a, UnknownAccount)), "unknown_target", "e no ignore também")
	CheckS(_reason(_remove(_kindFriend, a, UnknownAccount)), "missing", "remover aresta que não existe é 'missing', não sucesso")
	CheckEq(_totalRows() - before, 0, "nenhuma das recusas de forma escreveu linha (%d -> %d)" % [before, _totalRows()])
	CheckB(_has(_kindFriend, a, UnknownAccount), false, "Has de id inexistente é falso")
	CheckEq(_count(_kindFriend, UnknownAccount), 0, "Count de id inexistente é zero")
	Check(_list(_kindFriend, UnknownAccount).is_empty(), "List de id inexistente é vazia")
	CheckB(_blocked(UnknownAccount, UnknownAccount), false, "DeliveryBlocked com dados inexistentes deixa passar")

# ------------------------------------------------------------------ 8. frases
func _messagesBlock() -> void:
	print("== bloco 8: todo token de recusa tem exatamente uma frase ==")
	var tokens : Array = []
	for token in _failTokens(sgSource):
		if not (token in tokens):
			tokens.append(token)
	Check(not tokens.is_empty(), "a fonte declara tokens de recusa (%s)" % str(tokens))
	Check("self_relation" in tokens and "social_cap" in tokens and "social_cap_target" in tokens,
			"os tokens novos estão na lista lida da fonte")
	var arms : Array = []
	for arm in _matchArms(_bodyOf(sgSource, "static func Message(")):
		if not (arm in arms):
			arms.append(arm)
	Check(not arms.is_empty(), "Message tem o bloco match com as frases mapeadas (%s)" % str(arms))
	# Fechar o círculo nos dois sentidos: token sem frase é razão crua na tela; frase sem
	# token é decoração que ninguém produz.
	for token in tokens:
		Check(token in arms, "token '%s' tem frase em Message" % token)
	for arm in arms:
		Check(arm in tokens or arm == "usage", "frase '%s' corresponde a um token real (usage vem de WorldCommands)" % arm)
	CheckEq(arms.size(), tokens.size() + 1, "%d tokens + usage == %d frases mapeadas" % [tokens.size(), arms.size()])
	var phrases : Dictionary = {}
	for token in tokens:
		var phrase : String = _message({"ok": false, "reason": token}, _kindFriend, true, "Target")
		Check(not phrase.is_empty(), "frase de '%s' não é vazia" % token)
		Check(phrase != "Social action failed", "frase de '%s' tem texto próprio, não o genérico ('%s')" % [token, phrase])
		if phrases.has(phrase):
			Check(false, "frases de '%s' e '%s' são a mesma ('%s')" % [str(phrases.get(phrase, "")), token, phrase])
		phrases[phrase] = token
		if token.find("_") >= 0:
			Check(not phrase.contains(token), "nenhum token cru ('%s') chega à tela: '%s'" % [token, phrase])
	CheckEq(phrases.size(), tokens.size(), "%d tokens -> %d frases distintas" % [tokens.size(), phrases.size()])
	CheckS(_message({"ok": false}, _kindFriend, true, "Target"), "Social action failed", "razão ausente cai no genérico")
	CheckS(_message({"ok": false, "reason": "razao_nova_esquecida"}, _kindFriend, true, "T"), "Social action failed",
			"razão nova esquecida no match não vira texto cru")
	CheckS(_message({"ok": false, "reason": "usage"}, _kindIgnore, false, "T"), "Usage: /unignore <player>",
			"usage cita o verbo do tipo e da ação")
	CheckS(_message({"ok": false, "reason": "missing"}, _kindIgnore, false, "T"), "'T' was not on your ignored list",
			"missing nomeia a lista certa")
	CheckS(_message({"ok": true, "reason": ""}, _kindIgnore, false, "T"), "T no longer ignored", "sucesso de remoção fala do tipo certo")
	CheckS(str(sg.call("ListName", _kindFriend)), "friends", "ListName de friend")
	CheckS(str(sg.call("ListName", _kindIgnore)), "ignored", "ListName de ignore")
	for pair in [[_kindFriend, true, "friend"], [_kindFriend, false, "unfriend"], [_kindIgnore, true, "ignore"], [_kindIgnore, false, "unignore"]]:
		CheckS(str(sg.call("CommandName", str(pair[0]), bool(pair[1]))), str(pair[2]), "CommandName(%s, %s)" % [str(pair[0]), str(pair[1])])

# ------------------------------------------------------------------ 9. listas
func _listsBlock() -> void:
	print("== bloco 9: List e DescribeLists ==")
	var a : int = _aOwner()
	var listed : Array = _list(_kindFriend, a)
	CheckEq(listed.size(), _count(_kindFriend, a), "List bate com Count (%d)" % listed.size())
	Check(not listed.is_empty(), "a lista do dono não está vazia")
	var nicks : Array = []
	var unsorted : bool = false
	var missingSince : int = 0
	for row in listed:
		var entry : Dictionary = row as Dictionary
		var nick : String = str(entry.get("nick", ""))
		if int(entry.get("since", 0)) <= 0:
			missingSince += 1
		if not nicks.is_empty() and str(nicks[nicks.size() - 1]) > nick:
			unsorted = true
		nicks.append(nick)
	CheckEq(missingSince, 0, "toda linha da lista traz created_at > 0")
	CheckB(unsorted, false, "ordem por nick é ASC e estável (a aba não pisca de lugar)")
	var raw : Array = sql.call("QueryBindings", "SELECT a.username AS nick FROM social_graph s JOIN account a ON a.account_id = s.target_account_id WHERE s.account_id = ? AND s.kind = 'friend' ORDER BY a.username ASC;", [a])
	CheckEq(raw.size(), listed.size(), "o que a lista devolve é o que o SQL devolve (%d linhas)" % raw.size())
	if not raw.is_empty() and not listed.is_empty():
		CheckS(str((raw[0] as Dictionary).get("nick", "")), str((listed[0] as Dictionary).get("nick", "")),
				"o primeiro nick da lista é o primeiro do ORDER BY")
		CheckS(str((raw[raw.size() - 1] as Dictionary).get("nick", "")), str((listed[listed.size() - 1] as Dictionary).get("nick", "")),
				"e o último também")
	Check(_list(_kindFriend, 0).is_empty(), "List(0) é vazia, não um SELECT sem WHERE")
	Check(_list("bogus", a).is_empty(), "List de kind inválido é vazia (a consulta é parametrizada)")
	var both : Dictionary = Dictionary(sg.call("DescribeLists", a, ""))
	Check(bool(both.get("ok", false)), "DescribeLists('') devolve as duas listas")
	Check(str(both.get("text", "")).contains("Friends ("), "texto traz o cabeçalho de friends")
	Check(str(both.get("text", "")).contains("Ignored ("), "e o de ignored")
	Check(str(both.get("text", "")).contains("/%d)" % _friendCap), "o teto de amigos aparece no rótulo")
	Check(str(both.get("text", "")).contains("/%d)" % _ignoreCap), "e o teto de bloqueios")
	CheckEq((both.get("friends") as Array).size(), _count(_kindFriend, a), "friends[] == Count(friend)")
	CheckEq((both.get("ignored") as Array).size(), _count(_kindIgnore, a), "ignored[] == Count(ignore)")
	Check(str(both.get("text", "")).split("\n", false).size() == 2, "as duas listas são duas linhas")
	for want in ["friend", "friends"]:
		var onlyFriends : Dictionary = Dictionary(sg.call("DescribeLists", a, want))
		Check(bool(onlyFriends.get("ok", false)), "DescribeLists('%s') aceito" % want)
		Check(str(onlyFriends.get("text", "")).contains("Friends ("), "'%s' mostra friends" % want)
		Check(not str(onlyFriends.get("text", "")).contains("Ignored ("), "'%s' NÃO vaza a lista de bloqueios" % want)
	for want in ["ignore", "ignores", "ignored"]:
		var onlyIgnores : Dictionary = Dictionary(sg.call("DescribeLists", a, want))
		Check(bool(onlyIgnores.get("ok", false)), "DescribeLists('%s') aceito" % want)
		Check(str(onlyIgnores.get("text", "")).contains("Ignored ("), "'%s' mostra ignored" % want)
		Check(not str(onlyIgnores.get("text", "")).contains("Friends ("), "'%s' NÃO vaza a lista de amigos" % want)
	var badWord : Dictionary = Dictionary(sg.call("DescribeLists", a, "amigos"))
	Check(not bool(badWord.get("ok", false)), "palavra fora do vocabulário é recusada")
	CheckS(str(badWord.get("reason", "")), "bad_kind", "motivo da palavra errada é bad_kind")
	Check(str(badWord.get("text", "")).contains("friends") and str(badWord.get("text", "")).contains("ignored"),
			"a recusa ensina o vocabulário (%s)" % str(badWord.get("text", "")))
	var offline : Dictionary = Dictionary(sg.call("DescribeLists", 0, ""))
	Check(not bool(offline.get("ok", false)), "conta sem sessão não recebe lista")
	Check(not str(offline.get("text", "")).is_empty(), "e recebe uma frase, não string vazia")
	CheckS(str(offline.get("reason", "")), "not_logged_in", "com o motivo certo")
	# Lista vazia tem palavra própria (o painel não mostra vazio).
	var emptyOnes : Dictionary = Dictionary(sg.call("DescribeLists", _bOutsider(), "friends"))
	Check(str(emptyOnes.get("text", "")).contains("none"), "lista sem arestas diz 'none' (%s)" % str(emptyOnes.get("text", "")))

# ------------------------------------------------------------------ 10. EXPLAIN QUERY PLAN
func _plansBlock() -> void:
	print("== bloco 10: EXPLAIN QUERY PLAN do hot path (SEARCH, nunca SCAN) ==")
	var hasQuery : String = _sqlOf(_bodyOf(sgSource, "static func Has("))
	var countQuery : String = _sqlOf(_bodyOf(sgSource, "static func Count("))
	var listQuery : String = _sqlOf(_bodyOf(sgSource, "static func List("))
	Check(hasQuery.contains("FROM social_graph") and hasQuery.contains("account_id = ?")
			and hasQuery.contains("target_account_id = ?") and hasQuery.contains("kind = ?"),
			"Has lê a aresta pela chave tripla (texto lido do produto)")
	Check(countQuery.contains("COUNT(*)") and countQuery.contains("account_id = ?") and countQuery.contains("kind = ?"),
			"Count agrega por dono + tipo")
	Check(listQuery.contains("FROM social_graph s") and listQuery.contains("JOIN account") and listQuery.contains("ORDER BY a.username ASC"),
			"List ordena por nick no SQL")
	if hasQuery.is_empty() or countQuery.is_empty() or listQuery.is_empty():
		Check(false, "as três consultas foram localizadas na fonte")
		return
	var hasPlan : String = _planOf(_withLiterals(hasQuery, [1, 2, "'ignore'"]))
	var countPlan : String = _planOf(_withLiterals(countQuery, [1, "'ignore'"]))
	var listPlan : String = _planOf(_withLiterals(listQuery, [1, "'friend'"]))
	Check(_planIsIndexSearch(hasPlan), "Has (a checagem por linha entregue): SEARCH ... USING INDEX, nunca SCAN (%s)" % hasPlan.strip_edges())
	Check(hasPlan.contains("sqlite_autoindex_social_graph_1"), "Has usa o autoindex da PRIMARY KEY (%s)" % hasPlan.strip_edges())
	Check(hasPlan.contains("account_id=?") and hasPlan.contains("target_account_id=?") and hasPlan.contains("kind=?"),
			"Has resolve as TRÊS colunas no seek (%s)" % hasPlan.strip_edges())
	Check(_planIsIndexSearch(countPlan), "Count (o teto de cada lista): SEARCH ... USING INDEX, nunca SCAN (%s)" % countPlan.strip_edges())
	Check(countPlan.contains("idx_social_graph_owner"), "Count usa idx_social_graph_owner (%s)" % countPlan.strip_edges())
	Check(_planIsIndexSearch(listPlan), "List (a aba do painel): SEARCH ... USING INDEX, nunca SCAN (%s)" % listPlan.strip_edges())
	Check(listPlan.contains("idx_social_graph_owner"), "List usa idx_social_graph_owner (%s)" % listPlan.strip_edges())
	Check(listPlan.contains("INTEGER PRIMARY KEY") or listPlan.contains("rowid"),
			"o JOIN com account é lookup por rowid, não varredura (%s)" % listPlan.strip_edges())
	# A régua tem que distinguir: sem a chave primária o MESMO texto vira SCAN. É a prova
	# de que "SEARCH ... USING INDEX" não é verde por inércia.
	_mutateTableAway()
	var brokenPlan : String = _planOf(_withLiterals(hasQuery, [1, 2, "'ignore'"]))
	Check(brokenPlan.contains("SCAN"), "contra-prova: sem a PK o plano do mesmo SELECT é SCAN (%s)" % brokenPlan.strip_edges())
	Check(not brokenPlan.contains("INDEX"), "e nenhum índice sobra na tabela nua (%s)" % brokenPlan.strip_edges())
	Check(not _planIsIndexSearch(brokenPlan),
			"a asserção de SEARCH pegaria esta regressão de plano (%s)" % brokenPlan.strip_edges())
	_restoreTable()
	var fixedPlan : String = _planOf(_withLiterals(hasQuery, [1, 2, "'ignore'"]))
	Check(fixedPlan.contains("SEARCH") and fixedPlan.contains("sqlite_autoindex_social_graph_1"),
			"restaurada a tabela, o plano volta a ser SEARCH pelo autoindex (%s)" % fixedPlan.strip_edges())
	var restoredIndexes : Array = sql.call("Query", "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='social_graph';")
	CheckEq(restoredIndexes.size(), 3, "os três índices sobreviveram ao rename/drop (%d)" % restoredIndexes.size())
	var a : int = _aOwner()
	var b : int = _aTargetAt(0)
	_add(_kindIgnore, a, b)
	CheckB(_isIgnored(b, a), true, "a leitura do produto continua servida pela chave depois da mutação")
	_remove(_kindIgnore, a, b)

func _planIsIndexSearch(detail : String) -> bool:
	return detail.find("SEARCH") >= 0 and detail.find("INDEX") >= 0 and detail.find("SCAN") < 0

func _sqlOf(body : String) -> String:
	var at : int = body.find("\"SELECT")
	if at < 0:
		return ""
	var end : int = body.find("\"", at + 1)
	return body.substr(at + 1, end - at - 1) if end > at else ""

func _withLiterals(query : String, values : Array) -> String:
	var out : String = ""
	var cursor : int = 0
	var used : int = 0
	while true:
		var at : int = query.find("?", cursor)
		if at < 0:
			break
		out += query.substr(cursor, at - cursor)
		out += str(values[used]) if used < values.size() else "1"
		used += 1
		cursor = at + 1
	out += query.substr(cursor)
	return out

func _planOf(query : String) -> String:
	var rows : Array = sql.call("Query", "EXPLAIN QUERY PLAN " + query)
	var detail : String = ""
	for row in rows:
		detail += str((row as Dictionary).get("detail", "")) + " | "
	return detail

# Tira a chave primária e os índices do caminho SEM perder as linhas: é a mutação que
# mostra que a asserção acima não é decoração (precedente: guild_vault_gate_test.gd:244).
func _mutateTableAway() -> void:
	sql.call("Query", "ALTER TABLE social_graph RENAME TO social_graph_socbak;")
	_tableMutated = true
	sql.call("Query", "CREATE TABLE social_graph AS SELECT * FROM social_graph_socbak WHERE 0;")

func _restoreTable() -> void:
	sql.call("Query", "DROP TABLE IF EXISTS social_graph;")
	sql.call("Query", "ALTER TABLE social_graph_socbak RENAME TO social_graph;")
	_tableMutated = false

# ------------------------------------------------------------------ 11. custo
func _costBlock() -> void:
	print("== bloco 11: custo da checagem por linha ==")
	var a : int = _aOwner()
	var b : int = _aTargetAt(0)
	_add(_kindIgnore, a, b)
	var t0 : int = Time.get_ticks_msec()
	for i in 2000:
		_isIgnored(b, a)
	var elapsed : int = Time.get_ticks_msec() - t0
	print("  [info] 2000 checagens de ignore em %d ms (%.1f us cada)" % [elapsed, float(elapsed) * 1000.0 / 2000.0])
	Check(elapsed < 10000, "2000 checagens de ignore ficam abaixo de 10 s (%d ms)" % elapsed)
	CheckB(_isIgnored(b, a), true, "e continuam respondendo certo depois do loop")
	_remove(_kindIgnore, a, b)

# ------------------------------------------------------------------ 12. entrega
func _deliveryBlock() -> void:
	print("== bloco 12: direção da ENTREGA (runtime, sessão viva + agente real) ==")
	var serverNode : Node = network.get("ENetServer")
	if not Check(serverNode != null, "NetServer do boot offline vive (Network.ENetServer)"):
		return
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var realA : int = int(suites.call("CreateFixture", sql, "socg_real_a", "SocGraphA"))
	var realB : int = int(suites.call("CreateFixture", sql, "socg_real_b", "SocGraphB"))
	if not Check(realA != 0 and realB != 0, "dois personagens reais de fixture (%d, %d)" % [realA, realB]):
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", realA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", realB))
	var pidA : int = _openSession(acctA)
	var pidB : int = _openSession(acctB)
	if not Check(pidA > 0 and pidB > 0 and pidA != pidB, "duas sessões vivas (A=%d, B=%d)" % [pidA, pidB]):
		return
	if not await _warmFarmInstance():
		Check(false, "instância de farm aquecida (sem isto não há vizinhança nem área para medir)")
		return
	var agentA : Node = _spawnRealAgent(realA, "SocGraphA")
	var agentB : Node = _spawnRealAgent(realB, "SocGraphB")
	if not Check(agentA != null and agentB != null, "dois PlayerAgent reais na MESMA instância"):
		return
	var ridA : int = int(agentA.call("get_rid").get_id())
	var ridB : int = int(agentB.call("get_rid").get_id())
	Check(ridA > 0 and ridB > 0 and ridA != ridB, "RIDs reais e distintos (%d, %d)" % [ridA, ridB])
	agentA.set("peerID", pidA)
	agentB.set("peerID", pidB)
	(peersScript.call("GetPeer", pidA)).set("agentRID", ridA)
	(peersScript.call("GetPeer", pidB)).set("agentRID", ridB)
	var nickA : String = str(agentA.get("nick"))
	var nickB : String = str(agentB.get("nick"))
	CheckS(nickA, "SocGraphA", "o agente A fala pelo nick de fixture")
	CheckS(nickB, "SocGraphB", "e o B também")
	var localChannel : String = str(guiCommons.ChatChannel.LOCAL)
	var globalChannel : String = str(guiCommons.ChatChannel.GLOBAL)
	CheckS(localChannel, "0", "o canal LOCAL é o texto '0' (Server.gd compara com str(enum))")
	CheckS(globalChannel, "1", "e o GLOBAL é '1'")

	# --- A ignora B: a verdade do módulo.
	Check(bool(_add(_kindIgnore, acctA, acctB).get("ok", false)), "A bloqueou B pelo módulo")
	CheckB(_blocked(ridB, pidA), true, "DeliveryBlocked(ridB, pidA): a linha de B não entra na sessão de A")
	CheckB(_blocked(ridA, pidB), false, "DeliveryBlocked(ridA, pidB): o sentido inverso está intacto")
	CheckB(_blocked(ridA, pidA), false, "DeliveryBlocked(ridA, pidA): o falante sempre vê a própria fala")
	CheckB(_blocked(ridB, pidB), false, "DeliveryBlocked(ridB, pidB): idem para B")
	var ghost : int = _openGhostSession(GhostPeer)
	CheckB(_blocked(ridB, ghost), false, "peer sem conta não é filtrado (não há quem tenha bloqueado)")
	CheckB(_blocked(UnknownAccount, pidA), false, "RID que não é agente não bloqueia nada")
	var npcStub : Node = baseAgentScript.new() as Node
	var npcRID : int = RidBase + 500
	_syntheticRIDs.append(npcRID)
	(worldAgentScript.get("agents") as Dictionary)[npcRID] = npcStub
	CheckB(_blocked(npcRID, pidA), false, "falante que não é PlayerAgent (NPC) nunca é bloqueado")
	(worldAgentScript.get("agents") as Dictionary).erase(npcRID)
	npcStub.free()

	# --- O primitivo de entrega, end-to-end, com probe no lugar do cliente.
	originalClient = network.get("Client")
	probe = _makeProbe()
	if not Check(probe != null, "probe de sessão instalado como Network.Client"):
		return
	network.set("Client", probe)
	_probeClear()
	network.call("ChatPlayer", globalChannel, nickB, "linha de B para A", ridB, pidA)
	network.call("ChatPlayer", globalChannel, nickB, "linha de B para o fantasma", ridB, ghost)
	network.call("ChatPlayer", globalChannel, nickA, "linha de A para B", ridA, pidB)
	network.call("ChatPlayer", globalChannel, nickA, "eco de A", ridA, pidA)
	await create_timer(0.5).timeout
	CheckEq(_peerCount(pidA), 1, "A recebeu exatamente uma linha: o próprio eco")
	CheckS(_peerText(pidA, 0), "eco de A", "a linha que chegou em A é a de A mesma")
	CheckEq(_peerCount(pidB), 1, "B recebeu a linha de A (bloqueio não é mão dupla)")
	CheckS(_peerText(pidB, 0), "linha de A para B", "e é a linha certa")
	CheckEq(_peerCount(ghost), 1, "peer sem conta recebe normalmente (não é ali que a sanção mora)")
	CheckEq(_countOf("ChatPlayer"), 3, "três entregas dos quatro pacotes endereçados")

	# --- Os canais reais, por Server.TriggerChat (o caminho do jogador).
	_probeClear()
	serverNode.call("TriggerChat", globalChannel, "global de B", pidB)
	await create_timer(0.5).timeout
	CheckEq(_countWithText("global de B", pidA), 0, "GLOBAL: a linha de B NÃO chega em A (A ignora B)")
	CheckEq(_countWithText("global de B", pidB), 1, "GLOBAL: B recebeu a própria (o zero acima não é 'ninguém recebeu')")

	_probeClear()
	serverNode.call("TriggerChat", localChannel, "local de B", pidB)
	await create_timer(0.5).timeout
	CheckEq(_countWithText("local de B", pidA), 0, "LOCAL: a linha de B NÃO chega em A (A ignora B)")
	CheckEq(_countWithText("local de B", pidB), 1, "LOCAL: o eco do falante existe")

	_probeClear()
	serverNode.call("TriggerChat", nickA, "whisper de B", pidB)
	await create_timer(0.5).timeout
	CheckEq(_countWithText("whisper de B", pidA), 0, "WHISPER: a linha de B NÃO chega em A")
	CheckEq(_countWithText("whisper de B", pidB), 1, "WHISPER: o eco chega em B")

	var economy : Node = launcher.get("Economy")
	if Check(economy != null, "Economy booteds (para o canal de guild)"):
		if economy.get("guildService") == null:
			economy.call("_post_launch")
		var guildName : String = "SocGraph Guild"
		_guildJanitor(guildName)
		economy.call("MoveGold", realA, 200000, "social_graph_fixture")
		var guildID : int = int(economy.call("CreateGuild", acctA, realA, guildName))
		Check(guildID > 0, "A fundou a guild #%d para medir o canal de guild" % guildID)
		Check(bool(economy.call("JoinGuild", acctB, guildID)), "B entrou na guild")
		var channel : String = str(chatScript.call("GuildChannelName", guildName))
		_probeClear()
		serverNode.call("TriggerChat", channel, "guild de B", pidB)
		await create_timer(0.5).timeout
		CheckEq(_countWithText("guild de B", pidA), 0, "GUILD: a linha de B NÃO chega em A")
		CheckEq(_countWithText("guild de B", pidB), 1, "GUILD: o eco chega em B")
		_guildJanitor(guildName)

	# --- Desbloquear reabre, e reabre só o sentido certo.
	Check(bool(_remove(_kindIgnore, acctA, acctB).get("ok", false)), "A desbloqueou B")
	CheckB(_blocked(ridB, pidA), false, "DeliveryBlocked liberado")
	_probeClear()
	network.call("ChatPlayer", globalChannel, nickB, "de novo", ridB, pidA)
	await create_timer(0.5).timeout
	CheckEq(_countWithText("de novo", pidA), 1, "a linha de B volta a chegar em A")
	CheckEq(_countWithText("de novo", pidB), 0, "e nada foi entregue em B por causa disso")
	Check(bool(_add(_kindIgnore, acctA, acctB).get("ok", false)), "re-bloquear aceita")
	CheckB(_blocked(ridB, pidA), true, "e vale no mesmo instante (não há cache a invalidar)")
	_remove(_kindIgnore, acctA, acctB)
	CheckB(_blocked(ridB, pidA), false, "estado final entre A e B: sem sanção")

func _peerCount(peerID : int) -> int:
	if probe == null:
		return -1
	return ((probe.get("byPeer") as Dictionary).get(peerID, []) as Array).size()

func _peerText(peerID : int, index : int) -> String:
	if probe == null:
		return ""
	var lines : Array = (probe.get("byPeer") as Dictionary).get(peerID, []) as Array
	return str((lines[index] as Dictionary).get("text", "")) if index < lines.size() else ""

func _countOf(methodName : String) -> int:
	if probe == null:
		return -1
	var total : int = 0
	for entry in (probe.get("inbox") as Array):
		if str((entry as Dictionary).get("method", "")) == methodName:
			total += 1
	return total

func _countWithText(text : String, peerID : int) -> int:
	if probe == null:
		return -1
	var total : int = 0
	for entry in (probe.get("inbox") as Array):
		var line : Dictionary = entry as Dictionary
		if str(line.get("method", "")) != "ChatPlayer":
			continue
		if str(line.get("text", "")) == text and int(line.get("peer", -1)) == peerID:
			total += 1
	return total

func _feedbackCount(peerID : int) -> int:
	if probe == null:
		return -1
	var total : int = 0
	for entry in (probe.get("inbox") as Array):
		var line : Dictionary = entry as Dictionary
		if str(line.get("method", "")) == "CommandFeedback" and int(line.get("peer", -1)) == peerID:
			total += 1
	return total

func _lastFeedback(peerID : int) -> String:
	if probe == null:
		return ""
	var lines : Array = (probe.get("byPeer") as Dictionary).get(peerID, []) as Array
	for i in range(lines.size() - 1, -1, -1):
		var entry : Dictionary = lines[i] as Dictionary
		if str(entry.get("method", "")) == "CommandFeedback":
			return str(entry.get("text", ""))
	return ""

# A casa fala em duas peças: a frase do comando e, depois, o tail genérico do
# CommandManager. `_lastFeedback` só enxerga a última, então para conferir a
# PRIMEIRA é preciso varrer a janela inteira do peer — foi por isto que as três
# chamadas abaixo nasceram antes de existir, e o preflight pegou.
func _hasFeedback(peerID : int, text : String) -> bool:
	if probe == null:
		return false
	for entry in ((probe.get("byPeer") as Dictionary).get(peerID, []) as Array):
		var line : Dictionary = entry as Dictionary
		if str(line.get("method", "")) != "CommandFeedback":
			continue
		if str(line.get("text", "")).contains(text):
			return true
	return false

# ------------------------------------------------------------------ 13. rota de comando
func _commandBlock() -> void:
	print("== bloco 13: /friend /unfriend /ignore /unignore /social no runtime ==")
	var world : Node = launcher.get("World")
	var worldCommands : Object = world.get("commands") if world != null else null
	if not Check(worldCommands != null, "WorldCommands do boot vive (Launcher.World.commands)"):
		return
	var registered : Dictionary = cmdScript.get("commands")
	for verb in ["friend", "unfriend", "ignore", "unignore", "social", "report"]:
		Check(registered.has(StringName(verb)), "comando '/%s' registrado no CommandManager" % verb)
	var friendCmd : Object = registered.get(StringName("friend"), null)
	if Check(friendCmd != null, "o registro de '/friend' é legível"):
		CheckEq(int(friendCmd.get("_permission")), 0, "'/friend' é permissão NONE (instrumento do jogador comum)")
		Check(str(friendCmd.get("_description")).contains("<player>"), "a descrição ensina o argumento ('%s')" % str(friendCmd.get("_description")))
	if probe == null or not is_instance_valid(probe):
		Check(false, "probe do bloco anterior segue instalado (sem ele não há como ler o feedback)")
		return
	var agentA : Node = _agentByNick("SocGraphA")
	var agentB : Node = _agentByNick("SocGraphB")
	if not Check(agentA != null and agentB != null, "os dois agentes reais do bloco 12 seguem vivos"):
		return
	var pidA : int = int(agentA.get("peerID"))
	var pidB : int = int(agentB.get("peerID"))
	var acctA : int = int(peersScript.call("GetAccount", pidA))
	var acctB : int = int(peersScript.call("GetAccount", pidB))
	var ridA : int = int(agentA.call("get_rid").get_id())
	var ridB : int = int(agentB.call("get_rid").get_id())
	Check(acctA > 0 and acctB > 0 and acctA != acctB, "as duas sessões têm contas distintas (%d, %d)" % [acctA, acctB])
	for kind in [_kindFriend, _kindIgnore]:
		_remove(kind, acctA, acctB)
		_remove(kind, acctB, acctA)
	CheckEq(_touchingRows(acctA), 0, "estado limpo entre A e B antes dos comandos")

	# --- /friend escreve o par e responde SÓ para quem pediu.
	_probeClear()
	CheckB(bool(worldCommands.call("CommandFriend", agentA, "SocGraphB")), true, "/friend SocGraphB devolve true")
	await create_timer(0.25).timeout
	CheckEq(_edgeRows(acctA, acctB, _kindFriend), 1, "a aresta de A existe")
	CheckEq(_edgeRows(acctB, acctA, _kindFriend), 1, "e a de B também (o comando escreve o par)")
	CheckEq(_feedbackCount(pidA), 1, "A recebeu exatamente um feedback")
	CheckS(_lastFeedback(pidA), "SocGraphB added as a friend (1/%d)" % _friendCap, "o feedback traz o verbo e a conta pessoal de A")
	CheckEq(_feedbackCount(pidB), 0, "B NÃO recebeu nada: quem agiu foi A")

	# --- /unfriend desfaz o par inteiro; sem aresta, 'missing'.
	_probeClear()
	CheckB(bool(worldCommands.call("CommandUnfriend", agentA, "SocGraphB")), true, "/unfriend devolve true")
	await create_timer(0.25).timeout
	CheckEq(_touchingRows(acctA), 0, "A voltou a zero arestas")
	CheckEq(_touchingRows(acctB), 0, "B idem (a metade espelhada caiu junto)")
	CheckS(_lastFeedback(pidA), "SocGraphB removed from your friends", "feedback de remoção")
	CheckB(bool(worldCommands.call("CommandUnfriend", agentA, "SocGraphB")), false, "/unfriend sem aresta devolve false")
	await create_timer(0.25).timeout
	CheckS(_lastFeedback(pidA), "'SocGraphB' was not on your friends list", "'não tinha' é dito como 'não tinha'")

	# --- /ignore: comando -> entrega, na direção certa.
	_probeClear()
	CheckB(bool(worldCommands.call("CommandIgnore", agentA, "SocGraphB")), true, "/ignore SocGraphB aceito")
	await create_timer(0.25).timeout
	CheckEq(_kindRows(acctA, _kindIgnore), 1, "uma aresta de bloqueio (o comando não espelha)")
	CheckEq(_kindRows(acctB, _kindIgnore), 0, "B não bloqueou ninguém")
	CheckB(_blocked(ridB, pidA), true, "e a entrega de B para A cai na mesma hora")
	CheckS(_lastFeedback(pidA), "SocGraphB ignored (1/%d)" % _ignoreCap, "feedback de bloqueio com a conta de A")
	_probeClear()
	network.call("ChatPlayer", globalChannelStatic(), "SocGraphB", "nao me ouve", ridB, pidA)
	await create_timer(0.5).timeout
	CheckEq(_countWithText("nao me ouve", pidA), 0, "a linha não chega (comando -> entrega medida)")
	_probeClear()
	CheckB(bool(worldCommands.call("CommandUnignore", agentA, "SocGraphB")), true, "/unignore aceito")
	await create_timer(0.25).timeout
	CheckB(_blocked(ridB, pidA), false, "e a entrega volta")

	# --- O caminho do BOTÃO, pelo dispatcher: a UI só sabe escrever o texto.
	_probeClear()
	cmdScript.call("Handle", agentA, "friend SocGraphB")
	await create_timer(0.25).timeout
	CheckEq(_edgeRows(acctA, acctB, _kindFriend), 1, "Handle('friend ...') escreveu a aresta")
	CheckEq(_edgeRows(acctB, acctA, _kindFriend), 1, "nos dois lados")
	Check(str(_lastFeedback(pidA)).contains("added as a friend"), "e respondeu por /friend (%s)" % _lastFeedback(pidA))
	cmdScript.call("Handle", agentA, "friend")
	await create_timer(0.25).timeout
	Check(_hasFeedback(pidA, "Usage: /friend <player>"), "sem argumento: a frase de usage sai pelo dispatcher")
	CheckS(_lastFeedback(pidA), "Command 'friend' could not be called due to incorrect arguments",
			"e o tail do CommandManager vem depois da frase (convenção da casa, conferida em /openchest)")
	cmdScript.call("Handle", agentA, "unfriend SocGraphB")
	await create_timer(0.25).timeout
	CheckEq(_touchingRows(acctA), 0, "Handle('unfriend ...') desfez")
	_probeClear()
	cmdScript.call("Handle", agentA, "social")
	await create_timer(0.25).timeout
	var socialText : String = _lastFeedback(pidA)
	Check(socialText.contains("Friends (") and socialText.contains("Ignored ("), "/social devolve as duas listas na resposta (%s)" % socialText.replace("\n", " / ").left(90))
	Check(socialText.contains("0/%d)" % _friendCap), "e conta zero amigos neste instante (%s)" % socialText.replace("\n", " / ").left(60))
	cmdScript.call("Handle", agentA, "social amigos")
	await create_timer(0.25).timeout
	Check(_hasFeedback(pidA, "Use /social [friends|ignored]"), "palavra fora do vocabulário é recusada com o vocabulário")
	CheckS(_lastFeedback(pidA), "Command 'social' could not be called due to incorrect arguments",
			"o mesmo tail genérico aparece em /social")
	_probeClear()
	cmdScript.call("Handle", agentA, "openchest")
	await create_timer(0.25).timeout
	Check(_hasFeedback(pidA, "Usage: /openchest"), "referência NÃO-social: /openchest também manda a própria frase de usage")
	CheckS(_lastFeedback(pidA), "Command 'openchest' could not be called due to incorrect arguments",
			"o tail genérico é do CommandManager (Handle:52), não do SocialGraph — quem muda um, muda todos")

	# --- Identidade sai do PEER, nunca do payload.
	_probeClear()
	CheckB(bool(worldCommands.call("CommandFriend", agentA, str(UnknownAccount))), false, "/friend %d (id forjado no argumento) é recusado" % UnknownAccount)
	await create_timer(0.25).timeout
	CheckEq(_countSql("SELECT COUNT(*) AS n FROM social_graph WHERE target_account_id = ?;", [UnknownAccount]), 0,
			"nenhuma aresta nasceu para a conta forjada")
	CheckS(_lastFeedback(pidA), "Player '%d' not found" % UnknownAccount, "a resposta diz que o alvo não existe")
	CheckEq(_touchingRows(acctA), 0, "e A não ganhou nada")
	CheckB(bool(worldCommands.call("CommandIgnore", agentA, "-7")), false, "/ignore -7 recusado")
	CheckB(bool(worldCommands.call("CommandFriend", agentA, "  ")), false, "/friend com só espaço recusado")
	await create_timer(0.25).timeout
	CheckS(_lastFeedback(pidA), "Usage: /friend <player>", "argumento vazio vem usage, não stack trace")
	CheckEq(_touchingRows(acctA), 0, "nenhuma das tentativas escreveu linha")
	# Caller sem conta: o peer é o único provedor de identidade, e sem ele nada é escrito.
	var orphanAgent : Node = playerAgentScript.new() as Node
	var orphanRID : int = RidBase + 600
	_syntheticRIDs.append(orphanRID)
	(worldAgentScript.get("agents") as Dictionary)[orphanRID] = orphanAgent
	orphanAgent.set("nick", "SocGraphOrphan")
	orphanAgent.set("peerID", GhostPeer)
	_probeClear()
	CheckB(bool(worldCommands.call("CommandFriend", orphanAgent, "SocGraphA")), false, "caller sem conta não consegue amizade")
	await create_timer(0.25).timeout
	CheckS(_lastFeedback(GhostPeer), "Not logged in", "e a resposta é 'not logged in'")
	CheckEq(_kindRows(acctA, _kindFriend), 0, "a conta da VÍTIMA não recebeu aresta nenhuma")
	CheckEq(_touchingRows(acctB), 0, "nem a de quem ela conhece")
	(worldAgentScript.get("agents") as Dictionary).erase(orphanRID)
	orphanAgent.free()
	CheckB(_blocked(ridB, pidA), false, "estado final: sem sanção entre A e B")
	CheckB(_blocked(ridA, pidB), false, "nem no outro sentido")

# ------------------------------------------------------------------ 14. porta GM medida
func _gmGateBlock() -> void:
	print("== bloco 14: a gate de permissão do CommandManager, conferida no despacho real ==")
	if probe == null or not is_instance_valid(probe):
		Check(false, "probe instalado (sem ele o feedback de recusa não é legível)")
		return
	var agentA : Node = _agentByNick("SocGraphA")
	if not Check(agentA != null, "agente real do bloco 13 vivo para o despacho"):
		return
	var pidA : int = int(agentA.get("peerID"))
	var peerA : Object = peersScript.call("GetPeer", pidA)
	if not Check(peerA != null, "o peer do agente está vivo (a permissão sai dele, não do payload)"):
		return
	# NONE/ADMIN lidos do enum vivo — um literal dedado aqui seria exatamente a
	# confusão que a auditoria cobrou: a gate compara números que ninguém provou serem a escada.
	var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var perms : Dictionary = actorCommons.get_script_constant_map().get("Permission", {}) as Dictionary
	var permNone : int = int(perms.get("NONE", -1))
	var permAdmin : int = int(perms.get("ADMIN", -2))
	if not Check(permNone >= 0 and permAdmin > permNone, "Permission.NONE/ADMIN legíveis do enum (%d/%d)" % [permNone, permAdmin]):
		return
	var sink : Dictionary = {"n": 0}
	var probeCallable : Callable = func(_caller, _arg := "") -> bool:
		sink["n"] = int(sink["n"]) + 1
		return true
	var commands : Dictionary = cmdScript.get("commands")
	Check(not commands.has(StringName("gmprobe")), "'gmprobe' é nome do harness, livre no registro vivo")
	cmdScript.call("Register", StringName("gmprobe"), probeCallable, permAdmin, "gmprobe (harness)")
	if not Check(commands.has(StringName("gmprobe")), "comando ADMIN de teste registrado"):
		return
	OS.set_environment("SHAMBLETA_GM_MODE", "")
	peerA.set("permission", permNone)
	# (a) player comum, comando ADMIN, env desligada: NADA roda, e a resposta é a frase.
	_probeClear()
	cmdScript.call("Handle", agentA, "gmprobe")
	await create_timer(0.25).timeout
	CheckEq(int(sink["n"]), 0, "recusa medida no despacho: comum chamando ADMIN não executa (0 hits)")
	Check(_hasFeedback(pidA, "unmet permissions"), "a recusa responde 'unmet permissions' (%s)" % _lastFeedback(pidA))
	# (b) cmd desconhecido recusa como desconhecido, não como permissão.
	_probeClear()
	cmdScript.call("Handle", agentA, "gmnosuch")
	await create_timer(0.25).timeout
	Check(_hasFeedback(pidA, "is not registered"), "cmd inexistente responde 'not registered' (a gate não engole o ramo)")
	# (c) ADMIN de verdade executa: a gate compara permissão, não recusa tudo.
	_probeClear()
	peerA.set("permission", permAdmin)
	cmdScript.call("Handle", agentA, "gmprobe")
	await create_timer(0.25).timeout
	CheckEq(int(sink["n"]), 1, "ADMIN no peer executa o mesmo comando (1 hit)")
	CheckEq(_feedbackCount(pidA), 0, "sucesso não dispara feedback (o caminho é execução, não recusa)")
	# (d) o bypass existe e é lido por chamada: env=1 abre para comum…
	_probeClear()
	peerA.set("permission", permNone)
	OS.set_environment("SHAMBLETA_GM_MODE", "1")
	cmdScript.call("Handle", agentA, "gmprobe")
	await create_timer(0.25).timeout
	CheckEq(int(sink["n"]), 2, "SHAMBLETA_GM_MODE=1 abre a porta para player comum (bypass do operador, medido)")
	# (e) …e não é pegajoso: desligada a env, a mesma chamada volta a ser recusada.
	_probeClear()
	OS.set_environment("SHAMBLETA_GM_MODE", "")
	cmdScript.call("Handle", agentA, "gmprobe")
	await create_timer(0.25).timeout
	CheckEq(int(sink["n"]), 2, "env desligada volta a recusar na hora (2 hits: nenhum a mais que o bypass)")
	Check(_hasFeedback(pidA, "unmet permissions"), "a frase de recusa volta integralmente com a env fora")
	# teardown: registro, peer e env voltam como estavam.
	cmdScript.call("Unregister", StringName("gmprobe"))
	peerA.set("permission", permNone)
	OS.set_environment("SHAMBLETA_GM_MODE", "")
	Check(not commands.has(StringName("gmprobe")), "teardown: /gmprobe não existe fora do bloco")

func globalChannelStatic() -> String:
	return str(guiCommons.ChatChannel.GLOBAL)

func _agentByNick(nickname : String) -> Node:
	for agent in _spawnedAgents:
		var node : Node = agent as Node
		if node != null and is_instance_valid(node) and str(node.get("nick")) == nickname:
			return node
	return null

# ------------------------------------------------------------------ helpers de runtime
func _sessionServer() -> Node:
	if _serverNode == null or not is_instance_valid(_serverNode):
		_serverNode = (network.get("ENetServer") as Node) if network != null else null
	return _serverNode

func _openSession(accountID : int) -> int:
	var candidate : int = PeerBase + accountID
	while bool(peersScript.call("HasPeer", candidate)):
		candidate += 1
	# Caminho REAL de conexão: `ConnectPeer` faz Peers.AddPeer + bulks[peerID] = {}.
	# Criar o peer na mão deixa o dicionário tipado de NetInterface vazio para a
	# chave e todo Network.Bulk daquele peer morre em "Out of bounds get index".
	var server : Node = _sessionServer()
	if server != null:
		server.call("ConnectPeer", candidate)
	else:
		peersScript.call("AddPeer", candidate, 0)
	var peer : Object = peersScript.call("GetPeer", candidate)
	if peer == null:
		return 0
	peer.set("accountID", accountID)
	(peersScript.get("accounts") as Dictionary)[accountID] = candidate
	_syntheticPeers.append(candidate)
	return candidate

# Peer vivo sem conta (o caso "cliente puro recebendo o broadcast do servidor").
func _openGhostSession(peerID : int) -> int:
	if _serverNode != null and is_instance_valid(_serverNode):
		_serverNode.call("ConnectPeer", peerID)
	else:
		peersScript.call("AddPeer", peerID, 0)
	_syntheticPeers.append(peerID)
	return peerID

func _makeProbe() -> Node:
	var script : GDScript = GDScript.new()
	script.source_code = PROBE_SOURCE
	# `reload()` devolve Error (0 = OK), não bool — inverter isto era um probe que
	# "não compilava" mesmo compilando (guild_chat_fanout_test.gd:451).
	if int(script.reload()) != 0:
		print("FATAL: probe de cliente não compilou")
		return null
	var node : Node = script.new(false, false, true, true) as Node
	if node == null:
		return null
	node.set_name("SocialGraphProbe")
	return node

func _probeClear() -> void:
	if probe == null or not is_instance_valid(probe):
		return
	(probe.get("inbox") as Array).clear()
	(probe.get("byPeer") as Dictionary).clear()

func _probeRestore() -> void:
	if network != null and originalClient != null and probe != null:
		network.set("Client", originalClient)
	originalClient = null
	if probe != null and is_instance_valid(probe):
		if probe.get_parent() != null:
			probe.get_parent().remove_child(probe)
		probe.free()
	probe = null

func _warmFarmInstance() -> bool:
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var zone : Object = farmScript.call("GetZone", 1)
	if zone == null:
		return false
	_farmMap = launcher.get("World").call("GetMap", int(zone.get("mapID")))
	if _farmMap == null:
		return false
	var policy : GDScript = load("res://sources/idle/IdlePolicyService.gd")
	_farmInstID = int(policy.call("GetFarmInstanceID", 1))
	var instances : Dictionary = _farmMap.get("instances")
	var stale : Object = instances.get(_farmInstID, null)
	if stale != null:
		stale.call("Destroy")
		instances.erase(_farmInstID)
	_farmMap.call("CreateInstance", _farmInstID)
	for i in 200:
		var candidate : Object = policy.call("GetFarmInstance", 1)
		var navID : int = int(NavigationServer2D.map_get_iteration_id(_farmMap.get("mapRID")))
		if candidate != null and bool(candidate.call("is_node_ready")) and navID > 0:
			return true
		await process_frame
	return false

func _spawnRealAgent(charID : int, nickname : String) -> Node:
	var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var spawnScript : GDScript = load("res://addons/tiled_importer/SpawnObject.gd")
	var spawnPoint : Object = spawnScript.new()
	spawnPoint.set("map", _farmMap)
	spawnPoint.set("type", int(actorCommons.Type.PLAYER))
	spawnPoint.set("id", int(dbScript.PlayerHash))
	spawnPoint.set("is_global", false)
	var anchor : Object = null
	for spawn in (_farmMap.get("spawns") as Array):
		if spawn != null and int(spawn.get("type")) == int(actorCommons.Type.MONSTER):
			anchor = spawn
			break
	spawnPoint.set("spawn_position", anchor.get("spawn_position") if anchor != null else Vector2i.ZERO)
	var agent : Node = worldAgentScript.call("CreateAgent", spawnPoint, _farmInstID, nickname) as Node
	if agent == null:
		return null
	agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
	_spawnedAgents.append(agent)
	return agent

func _guildJanitor(guildName : String) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])

# ------------------------------------------------------------------ parsing de fonte
func _failTokens(src : String) -> Array:
	var out : Array = []
	var cursor : int = 0
	while true:
		var at : int = src.find("_Fail(\"", cursor)
		if at < 0:
			break
		var open : int = at + len("_Fail(\"")
		var end : int = src.find("\")", open)
		if end < 0:
			break
		out.append(src.substr(open, end - open))
		cursor = end + 2
	return out

func _matchArms(body : String) -> Array:
	var out : Array = []
	var matchAt : int = body.find("match str(result.get(\"reason\"")
	if matchAt < 0:
		return out
	var rest : String = body.substr(matchAt)
	for raw in rest.split("\n"):
		var line : String = String(raw).strip_edges()
		if line.begins_with("\"") and line.ends_with("\":"):
			out.append(line.substr(1, line.length() - 3))
	return out

# ------------------------------------------------------------------ fim
func _finish() -> void:
	if _tableMutated:
		print("WARN: tabela estava mutada no fim — restaurando")
		_restoreTable()
	_probeRestore()
	if worldAgentScript != null:
		for rid in _syntheticRIDs:
			(worldAgentScript.get("agents") as Dictionary).erase(int(rid))
	if peersScript != null:
		for pid in _syntheticPeers:
			# `bulks` é montado por NetServer.ConnectPeer (Server.gd:1800) e lido por
			# NetInterface.Bulk (Interface.gd:22) com dicionário TIPIADO: sobrar uma
			# chave aqui faz o próximo run de harness estourar "Out of bounds".
			if _serverNode != null and is_instance_valid(_serverNode):
				(_serverNode.get("bulks") as Dictionary).erase(int(pid))
			peersScript.call("RemovePeer", int(pid))
	for agent in _spawnedAgents:
		var node : Node = agent as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	if sql != null:
		_guildJanitor("SocGraph Guild")
		_janitor()
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== SOCIAL GRAPH: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
