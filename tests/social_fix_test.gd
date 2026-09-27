extends SceneTree

# SOM-IDLE social (auditoria 2026-09-27 §SOCIAL): harness autocontido que prova que
# a camada social deixou de ser "só servidor" — o painel de guild expõe os botões, e
# o caminho painel → GuildService → vault faz o round-trip real (cria → segundo
# account entra → deposita → o vault reflete), com roteamento de canal de chat de
# guild e presença O(1).
#
# Uso: godot --headless --path . -s tests/social_fix_test.gd
#       (rode com XDG_DATA_HOME / XDG_CACHE_HOME apontando para /tmp próprio, para
#        não escrever no user:// compartilhado — ver scripts/test.sh.)
# Exit code: número de checks falhos (0 = verde). Última linha: `== RESULT: N checks, M failures ==`.
#
# Igual a run_idle_tests/run_rpc_identity: o main-loop `-s` compila ANTES dos
# autoloads/class_names existirem, então nada de identificador de autoload
# (Launcher/Network/Peers/NetClient/...) nem class_name em anotação de tipo neste
# arquivo — tudo via load()/get()/call(). Os helpers de fixture (CreateFixture,
# _SetInventory, _CountItem) são reusados de IdleTests.gd, carregado pós-boot, que é
# exatamente como run_idle_tests roda as suítes de guild.

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

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _has_script_method(script : Object, methodName : String) -> bool:
	if script == null:
		return false
	for entry in script.get_script_method_list():
		if str(entry.get("name", "")) == methodName:
			return true
	return false

func _initialize():
	_runTests()

func _runTests():
	print("== SOM-SOCIAL fix test ==")
	var launcher : Node = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	# Espera o boot dos serviços offline (mesma espera de run_idle_tests).
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	print("== boot wait done (%d ms) ==" % waited)

	# O boot do Launcher dispara `DB.Preload()` (sources/db/DB.gd:218), que pede
	# ~330 presets ao `ResourceLoader.load_threaded_request()` e só se encerra quando
	# `PreloadUpdate` juntar cada um — o marcador é `DB.isInitialized`. SQL+World
	# inicializados NÃO implicam isso: sem esperar aqui, os `load()` de script deste
	# próprio harness (IdleTests.gd, GuildPanel.gd, OnlineList.gd, ChatModeration.gd,
	# abaixo) e o `quit()` caem no meio dos parses que rodam em thread de trabalho.
	# É literalmente a corrida documentada duas vezes no produto: sources/db/DB.gd:232
	# ("An unjoined threaded load is not a benign leak: the engine destroys the worker
	# while it is still parsing, under a script cache that teardown is already
	# freeing") e sources/launcher/Launcher.gd:254. Por isso o gate era vermelho em
	# máquina carregada (os threads do pool perdiam CPU para o resto dos gates) com
	# os 46 checks verdes e SIGABRT no teardown, e verde em máquina ociosa.
	#
	# Mesmo probe dos harnesses que saem limpos (run_idle_tests.gd:85,
	# gameplay_fix_test.gd:126): `DB` é classe estática, não autoload, então é
	# `load()` pós-boot + leitura do static var — nada de identificador em parse.
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

	# GuildService é montado em EconomyService._post_launch; garante que existe antes
	# de chamar qualquer wrapper de guild.
	if economy.get("guildService") == null:
		economy.call("_post_launch")
	Check(economy.get("guildService") != null, "GuildService mounted on Economy")

	# Fixtures: reusa o mecanismo idêntico ao SuiteGuilds (pós-boot, tipos ok).
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var apple : int = int(farmScript.get_script_constant_map().get("DefaultDropItemHash", 215387671))

	_guildJanitor(sql, "Social Fix Guild")
	var charA : int = int(suites.call("CreateFixture", sql, "social_fix_a", "SocialFixA"))
	var charB : int = int(suites.call("CreateFixture", sql, "social_fix_b", "SocialFixB"))
	if not Check(charA != 0 and charB != 0, "fixtures created (%d, %d)" % [charA, charB]):
		_finish()
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", charA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", charB))
	suites.call("_SetInventory", sql, charA, apple, 10)

	# ---------------------------------------------------------------- GuildPanel (UI)
	var panelScript : GDScript = load("res://sources/gui/GuildPanel.gd")
	Check(panelScript != null, "GuildPanel.gd loads")
	var panel : Object = panelScript.new()
	Check(panel.has_method("CreateGuildNamed"), "GuildPanel: CreateGuildNamed exposto")
	Check(panel.has_method("JoinGuildByID"), "GuildPanel: JoinGuildByID exposto")
	Check(panel.has_method("SearchGuildsByName"), "GuildPanel: SearchGuildsByName exposto")
	Check(panel.has_method("DepositItem"), "GuildPanel: DepositItem exposto")
	Check(panel.has_method("WithdrawItem"), "GuildPanel: WithdrawItem exposto")
	Check(panel.has_method("LeaveCurrentGuild"), "GuildPanel: LeaveCurrentGuild exposto")
	Check(panel.has_method("SendGuildChat"), "GuildPanel: SendGuildChat exposto")
	Check(panel.has_method("GuildChannelName"), "GuildPanel: GuildChannelName exposto")
	Check(panel.has_method("SetLocalIDs"), "GuildPanel: SetLocalIDs exposto")
	Check(panel.has_method("FetchState"), "GuildPanel: FetchState exposto")
	Check(panel.has_method("RenderState"), "GuildPanel: RenderState exposto")
	Check(panel.has_method("LocalPlayerIDs"), "GuildPanel: LocalPlayerIDs exposto")

	# ---------------------------------------------------------------- round-trip via o PAINEL
	# Fundador cria a guild clicando no botão (sem digitar comando).
	panel.call("SetLocalIDs", acctA, charA)
	var guildID : int = int(panel.call("CreateGuildNamed", "Social Fix Guild"))
	Check(guildID > 0, "panel.CreateGuildNamed founded guild #%d" % guildID)
	CheckEq(int(economy.call("GetGuildForAccount", acctA)), guildID, "founder membership via service")

	# Segundo account entra pela busca por nome → botão Join, tudo via painel.
	var found : Array = panel.call("SearchGuildsByName", "Social Fix")
	Check(not found.is_empty(), "panel.SearchGuildsByName found the guild")
	var listedID : int = int((found[0] as Dictionary).get("guild_id", 0))
	CheckEq(listedID, guildID, "search returns the same guild id")
	panel.call("SetLocalIDs", acctB, charB)
	Check(bool(panel.call("JoinGuildByID", listedID)), "panel.JoinGuildByID: B joined")
	CheckEq(int(economy.call("GetGuildForAccount", acctB)), guildID, "B membership via service")

	# Fundador deposita no vault; o estado lido pelo painel reflete.
	panel.call("SetLocalIDs", acctA, charA)
	Check(bool(panel.call("DepositItem", apple, 3)), "panel.DepositItem moved 3 to vault")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 7, "char inventory debited")
	var state : Dictionary = economy.call("GetGuildState", acctA)
	Check(bool(state.get("ok", false)), "GetGuildState ok")
	var mine : Dictionary = state.get("my_guild", {})
	var vault : Dictionary = mine.get("vault", {})
	CheckEq(int(vault.get("used", 0)), 1, "vault used-stacks reflects deposit")
	var stacks : Array = mine.get("vault_stacks", [])
	Check(not stacks.is_empty(), "vault_stacks exposed for withdraw UI")
	CheckEq(int((stacks[0] as Dictionary).get("count", 0)), 3, "vault stack count = 3")
	CheckEq(int(mine.get("members", []).size()), 2, "two members visible")
	Check(str(mine.get("my_rank", "")) == "leader", "founder rank is leader")

	# Retirada pelo líder (regra officer+) — devolve ao inventário.
	Check(bool(panel.call("WithdrawItem", apple, 1)), "panel.WithdrawItem pulled 1 back")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 8, "char inventory credited back")

	# B (member comum) não pode retirar.
	panel.call("SetLocalIDs", acctB, charB)
	Check(not bool(panel.call("WithdrawItem", apple, 1)), "member withdraw denied (rank gate)")

	# ---------------------------------------------------------------- presença O(1) (OnlineList)
	var onlineScript : GDScript = load("res://sources/network/server/OnlineList.gd")
	Check(_has_script_method(onlineScript, "IsPlayerOnline"), "OnlineList.IsPlayerOnline exposto")
	Check(not bool(onlineScript.IsPlayerOnline("nobody_here_42")), "unknown nick is offline")
	# prova que é um índice real (não sempre-falso): injeta um nick e reconsulta O(1).
	onlineScript.byNick["PresenceGhost"] = true
	Check(bool(onlineScript.IsPlayerOnline("PresenceGhost")), "seeded nick reads online (O(1) index)")
	onlineScript.byNick.erase("PresenceGhost")
	Check(not bool(onlineScript.IsPlayerOnline("PresenceGhost")), "erased nick offline again")

	# ---------------------------------------------------------------- canal de chat de guild (roteamento próprio)
	var chatScript : GDScript = load("res://sources/network/server/ChatModeration.gd")
	Check(_has_script_method(chatScript, "IsGuildChannel"), "ChatModeration.IsGuildChannel exposto")
	Check(_has_script_method(chatScript, "GuildNameOf"), "ChatModeration.GuildNameOf exposto")
	Check(_has_script_method(chatScript, "ResolveGuildPeers"), "ChatModeration.ResolveGuildPeers exposto")
	Check(bool(chatScript.IsGuildChannel("guild:Social Fix Guild")), "guild: prefix reconhecido")
	Check(not bool(chatScript.IsGuildChannel("Global")), "GLOBAL não é tratado como guild")
	Check(str(chatScript.GuildNameOf("guild:Social Fix Guild")) == "Social Fix Guild", "GuildNameOf extrai o nome")
	# Prefixo do painel bate com o do servidor (mesmo namespace de canal).
	panel.call("SetLocalIDs", acctA, charA)
	panel.call("Refresh")
	var chan : String = str(panel.call("GuildChannelName"))
	Check(chan == "guild:Social Fix Guild", "panel.GuildChannelName == guild:<nome>")
	Check(str(chatScript.GuildNameOf(chan)) == "Social Fix Guild", "servidor resolve o canal que o painel montou")
	# Sem sessão viva de rede, o fanout devolve lista vazia sem estourar (hook Server pendente).
	var peers : Array = chatScript.ResolveGuildPeers(acctA)
	Check(peers is Array, "ResolveGuildPeers devolve um Array sem erro")

	# ---------------------------------------------------------------- limpeza do testing.db
	_guildJanitor(sql, "Social Fix Guild")
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ? OR nickname = ?;", ["SocialFixA", "SocialFixB"])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ? OR username = ?;", ["social_fix_a", "social_fix_b"])
	panel.free()

	_finish()

func _guildJanitor(sql : Node, guildName : String) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])

func _finish():
	# Última linha de defesa contra a mesma corrida: se o teto do wait acima estourar
	# (boot lento demais nesta máquina), os threaded loads ainda em voo são juntados
	# AQUI, com a árvore e o cache de script vivos, em vez de deixar o `join` cair
	# dentro de `Launcher._exit_tree()` no meio do teardown — o ponto que travava o
	# processo com os 46 checks verdes. Normal da corrida: `preloadPaths` já está
	# vazio e isto é no-op.
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
