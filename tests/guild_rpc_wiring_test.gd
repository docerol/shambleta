extends SceneTree

# GUILD RPC (brief 2026-09-27b) — as cinco ESCRITAS do painel de guild costuradas
# ponta a ponta: `sources/gui/GuildPanel.gd` → `@rpc` em
# `sources/network/Network.gd` → handler autoritativo em
# `sources/network/server/Server.gd` → `GuildFeedback`/`GuildState` de volta.
#
# O defeito que este harness fecha: o painel tinha perna de leitura (RPC) e perna de
# escrita SÓ in-process. Num cliente puro (`Launcher.Economy` é null — é o caso do
# export web) o botão existia, o jogador clicava e nada saía do processo. Ler o
# fonte não basta para provar o contrário: por isso aqui as três pontas são amarradas
# por NOME em texto (régua de fonte, corpo do método até o próximo `\nfunc`, nunca o
# arquivo inteiro — padrão `tests/web_delivery_test.gd:_bodyOf`) e depois EXECUTADAS
# contra o servidor e o cliente reais deste boot.
#
# Blocos:
#   A) tabela fechada — todo alvo de escrita tem braço literal no painel, `@rpc` no
#      Network e handler no Server; o pacote do client NÃO nomeia conta nem
#      personagem, em nenhum dos cinco;
#   B) identidade — quem age é o PEER. Um peer sem sessão não move nada; um painel
#      que SE DECLARA outra conta (override de `SetLocalIDs`) não move a conta
#      declarada, e sim a do peer;
#   C) cliente puro — com `Launcher.Economy` ausente no momento do clique, as cinco
#      ações saem pelo facade e o serviço as executa no servidor (fundar, entrar,
#      sair, depositar, retirar);
#   D) o oficial no web — teto por ação e a 4ª retirada da janela são recusados
#      PELO SERVIDOR, por chamada direta ao handler, sem nenhuma UI no caminho;
#   E) o veredito volta — `Client.GuildFeedback` chega ao painel e o motivo cru do
#      servidor não vai à tela sem passar pelo catálogo de toasts (§13).
#
# Uso:   godot --headless --path . -s tests/guild_rpc_wiring_test.gd
#        (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Exit code = nº de checks falhos. Última linha:
#        == GUILD RPC: N checks, M failures ==
#
# Como os irmãos (`run_idle_tests.gd:1`, `social_fix_test.gd:14`): um main-loop `-s`
# compila antes de autoloads e `class_name` existirem — nada de identificador de
# autoload aqui; tudo via `load()`/`get()`/`call()`.

const GUILD_NAME : String = "Guild Rpc Test"
const FIXTURES : Array[String] = ["grpc_founder|GrpcFounder", "grpc_member|GrpcMember"]
const GHOST_PEER : int = 918888
const POLL_FRAMES : int = 12

# Os cinco alvos, e as três assinaturas exatas que cada um tem que ter no fonte.
const Targets : Array[String] = ["CreateGuild", "JoinGuild", "LeaveGuild",
	"DepositToVault", "WithdrawFromVault"]
const NetSigs : Array[String] = [
	"func CreateGuild(guildName : String, peerID : int = NetworkCommons.PeerAuthorityID):",
	"func JoinGuild(guildID : int, peerID : int = NetworkCommons.PeerAuthorityID):",
	"func LeaveGuild(peerID : int = NetworkCommons.PeerAuthorityID):",
	"func DepositToVault(itemID : int, count : int, peerID : int = NetworkCommons.PeerAuthorityID):",
	"func WithdrawFromVault(itemID : int, count : int, peerID : int = NetworkCommons.PeerAuthorityID):"]
const SrvSigs : Array[String] = [
	"func CreateGuild(guildName : String, peerID : int):",
	"func JoinGuild(guildID : int, peerID : int):",
	"func LeaveGuild(peerID : int):",
	"func DepositToVault(itemID : int, count : int, peerID : int):",
	"func WithdrawFromVault(itemID : int, count : int, peerID : int):"]
# O que o painel manda pelo facade (braço LITERAL, não um dispatch por nome).
const PanelSigs : Array[String] = [
	"func CreateGuildNamed(guildName : String) -> int:",
	"func JoinGuildByID(guildID : int) -> bool:",
	"func LeaveCurrentGuild() -> bool:",
	"func DepositItem(itemID : int, count : int) -> bool:",
	"func WithdrawItem(itemID : int, count : int) -> bool:"]
const RpcCalls : Array[String] = ["Network.CreateGuild(guildName)", "Network.JoinGuild(guildID)",
	"Network.LeaveGuild()", "Network.DepositToVault(itemID, count)", "Network.WithdrawFromVault(itemID, count)"]
const InProcessCalls : Array[String] = ["eco.CreateGuild(accountID, charID, guildName)",
	"eco.JoinGuild(accountID, guildID)", "eco.LeaveGuild(accountID)",
	"eco.DepositToVault(accountID, charID, itemID, count)",
	"eco.WithdrawFromVault(accountID, charID, itemID, count)"]

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null

var launcher : Node = null
var sql : Node = null
var eco : Node = null
var network : Node = null
var netServer : Node = null
var netClient : Object = null
var gui : Node = null
var panel : Object = null
var panelGuiBackup : Variant = null
var peersScript : GDScript = null
var commons : GDScript = null
var limits : GDScript = null
var suites : RefCounted = null
var apple : int = 0
var authPeer : int = 1
var charA : int = 0
var charB : int = 0
var acctA : int = 0
var acctB : int = 0
var guildID : int = 0
var perAction : int = 10
var windowMax : int = 3
var windowSec : int = 300

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

func CheckHas(hay : String, needle : String, label : String) -> bool:
	return Check(hay.contains(needle), "%s — falta '%s'" % [label, needle])

func CheckNotHas(hay : String, needle : String, label : String) -> bool:
	return Check(not hay.contains(needle), "%s — acha '%s' onde não podia haver" % [label, needle])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_runTests()

func _runTests():
	print("== GUILD RPC: painel -> Network -> Server, pelas três pontas ==")
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
		var world : Node = launcher.get("World")
		if sql != null and sql.get("isInitialized") and world != null and world.get("isInitialized"):
			break
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "DB.isInitialized drenado antes de load()/quit (sem estojo de thread solto)"):
		_finish()
		return
	eco = launcher.get("Economy")
	network = _autoload("Network")
	if not Check(sql != null and eco != null and network != null, "SQL + Economy + Network booteds"):
		_finish()
		return
	if eco.get("guildService") == null:
		eco.call("_post_launch")
	Check(eco.get("guildService") != null, "GuildService montado no Economy (o handler delega a ele)")
	netServer = network.get("ENetServer")
	if not Check(netServer != null, "NetServer do boot offline vive (Network.ENetServer)"):
		_finish()
		return
	netClient = network.get("Client")
	peersScript = load("res://sources/network/server/Peers.gd")
	commons = load("res://sources/network/NetworkCommons.gd")
	limits = load("res://sources/economy/GuildVaultLimits.gd")
	authPeer = int((commons.get_script_constant_map() as Dictionary).get("PeerAuthorityID", 1))
	perAction = int((limits.get_script_constant_map() as Dictionary).get("MaxWithdrawPerAction", 10))
	windowMax = int((limits.get_script_constant_map() as Dictionary).get("MaxWithdrawActionsInWindow", 3))
	windowSec = int((limits.get_script_constant_map() as Dictionary).get("WindowSec", 300))
	if not Check(peersScript != null and commons != null and limits != null,
			"Peers + NetworkCommons + GuildVaultLimits carregam"):
		_finish()
		return
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	apple = int(farmScript.get_script_constant_map().get("DefaultDropItemHash", 215387671))
	suites = (load("res://tests/IdleTests.gd") as GDScript).new()

	_janitor()
	charA = int(suites.call("CreateFixture", sql, FIXTURES[0].split("|")[0], FIXTURES[0].split("|")[1]))
	charB = int(suites.call("CreateFixture", sql, FIXTURES[1].split("|")[0], FIXTURES[1].split("|")[1]))
	if not Check(charA != 0 and charB != 0, "dois fixtures de conta/personagem (%d, %d)" % [charA, charB]):
		_finish()
		return
	acctA = int(sql.call("GetAccountIDForCharacter", charA))
	acctB = int(sql.call("GetAccountIDForCharacter", charB))
	Check(acctA != 0 and acctB != 0 and acctA != acctB, "as duas contas existem e são diferentes")

	_suiteSource()
	await _suiteServerIdentity()
	await _suitePureClient()
	await _suiteServerCaps()
	await _suiteFeedbackRoute()
	_finish()

# ------------------------------------------------------------------ réguas de fonte
# Corpo do método até o próximo `\nfunc ` de topo — nunca o arquivo inteiro. Uma
# frase em comentário não sustenta um check verde (padrão `tests/web_delivery_test.gd`).
func _bodyOf(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var rest : String = src.substr(at)
	var next : int = rest.find("\nfunc ", 1)
	return rest.substr(0, next) if next > 0 else rest

# O `@rpc` que ANTECEDE a assinatura: canal e modos de permissão são decisão de
# protocolo e estão na linha de cima.
func _annotationOf(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var before : String = src.substr(0, at)
	var last : int = before.rfind("@rpc")
	return before.substr(last) if last >= 0 else ""

func _fileText(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text : String = f.get_as_text()
	f.close()
	return text

func _suiteSource() -> void:
	print("-- A) as três pontas fecham por nome, e o pacote não nomeia ninguém")
	var panelSrc : String = _fileText("res://sources/gui/GuildPanel.gd")
	var netSrc : String = _fileText("res://sources/network/Network.gd")
	var srvSrc : String = _fileText("res://sources/network/server/Server.gd")
	var clientSrc : String = _fileText("res://sources/network/client/Client.gd")
	Check(not panelSrc.is_empty() and not netSrc.is_empty() and not srvSrc.is_empty()
			and not clientSrc.is_empty(), "os quatro elos da corrente têm fonte legível")
	for i in Targets.size():
		var target : String = Targets[i]
		var netSig : String = NetSigs[i]
		var srvSig : String = SrvSigs[i]
		Check(panelSrc.contains(RpcCalls[i]), "'%s': o painel tem braço literal '%s'" % [target, RpcCalls[i]])
		var panelBody : String = _bodyOf(panelSrc, PanelSigs[i])
		Check(not panelBody.is_empty(), "'%s': corpo de '%s' lido até o próximo func" % [target, PanelSigs[i]])
		CheckHas(panelBody, "eco == null", "'%s': a perna in-process ainda existe e a ausência dela é o gatilho do RPC" % target)
		CheckHas(panelBody, InProcessCalls[i], "'%s': a perna de processo único (service direto) não regrediu" % target)
		CheckHas(panelBody, RpcCalls[i], "'%s': o corpo do método dispara o facade, não só o arquivo" % target)
		CheckNotHas(panelBody, "no local session", "'%s': o beco-sem-saída 'no local session' saiu do corpo" % target)
		Check(netSrc.contains(netSig), "'%s': Network declara o wrapper com a assinatura exata" % target)
		Check(srvSrc.contains(srvSig), "'%s': Server declara o handler com a MESMA assinatura (sem peerID de default)" % target)
		var netBody : String = _bodyOf(netSrc, netSig)
		CheckHas(netBody, "CallServer(\"%s\", [" % target, "'%s': o wrapper chama o servidor por este nome" % target)
		CheckHas(netBody, "AuthPeerID(peerID)", "'%s': o wrapper passa pela borda AuthPeerID" % target)
		CheckHas(netBody, "NetworkCommons.DelayConfig", "'%s': o wrapper usa o rate-limit de ação do facade" % target)
		Check(_annotationOf(netSrc, netSig).contains("@rpc(\"any_peer\", \"call_remote\", \"reliable\", EChannel.ACTION)"),
				"'%s': @rpc any_peer/call_remote/reliable no canal ACTION (escrita de jogador, não de autoridade)" % target)
		Check(netBody.find("accountID") < 0 and netBody.find("charID") < 0,
				"'%s': o client não manda conta nem personagem" % target)
		var srvBody : String = _bodyOf(srvSrc, srvSig)
		Check(srvBody.contains("Peers.GetAccount(peerID)"), "'%s': o handler tira a CONTA do peer" % target)
		CheckNotHas(srvSig.replace("func ", ""), "accountID", "'%s': a assinatura do handler não aceita conta do pacote" % target)
		CheckNotHas(srvSig.replace("func ", ""), "charID", "'%s': a assinatura do handler não aceita personagem do pacote" % target)
		CheckHas(srvBody, "not_logged_in", "'%s': peer sem sessão recusa curto, sem tocar o service" % target)
		CheckHas(srvBody, "Launcher.Economy.%s(" % target, "'%s': o handler delega ao mesmo service da perna local" % target)
		var fbAt : int = srvBody.find("Network.GuildFeedback(")
		var stAt : int = srvBody.find("Network.GuildState(")
		Check(fbAt >= 0 and stAt > fbAt, "'%s': veredito em GuildFeedback e DEPOIS GuildState (ordem reliable)" % target)
		Check(not srvBody.contains("if ok:\n\t\tNetwork.GuildState"),
				"'%s': o estado volta também na recusa (a tela lê a verdade, não o último snapshot)" % target)
	# O reason do servidor tem que ser token do catálogo, não texto inventado: os
	# usados aqui existem nos dois idiomas (`data/i18n/ui.csv`).
	var srvTokens : Array[String] = ["not_logged_in", "rejected", "no_guild", "bad_args", "ok"]
	for token : String in srvTokens:
		Check(srvSrc.contains("\"%s\"" % token), "'%s' é motivo emitido por handler de guild" % token)
	CheckNotHas(srvSrc, "\"guild_whatever\"", "nenhum motivo cru de guild sai fora dos tokens do catálogo")
	var writeHelper : String = _bodyOf(panelSrc, "func _WriteOverNetwork(label : String, send : Callable) -> void:")
	Check(not writeHelper.is_empty() and writeHelper.contains("send.call()"),
			"a segunda perna do painel tem UM ponto de envio (_WriteOverNetwork → send.call())")
	Check(writeHelper.find("Refresh()") < 0, "o envio não relê estado local: quem pinta o estado é o push do servidor")
	var feedbackLeg : String = _bodyOf(panelSrc, "func ShowNetworkFeedback(ok : bool, reason : String) -> void:")
	CheckHas(feedbackLeg, "PlayerReasons.ToToast", "o veredito assíncrono passa pelo catálogo de toasts (§13)")
	var clientFeedback : String = _bodyOf(clientSrc, "func GuildFeedback(ok : bool, reason : String, _peerID : int):")
	CheckHas(clientFeedback, "ShowNetworkFeedback", "Client.GuildFeedback empurra o veredito para o painel de guild")

# ------------------------------------------------------------------ helpers de sessão
func _openSession(accountID : int, charID : int, peerID : int) -> bool:
	if not bool(peersScript.call("HasPeer", peerID)):
		peersScript.call("AddPeer", peerID, 0)
	var peer : Object = peersScript.call("GetPeer", peerID)
	if peer == null:
		return false
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(peersScript.accounts as Dictionary)[accountID] = peerID
	return true

# O gate de pegada (`Peers.Footprint`, 12 s por método por peer) é do produto; aqui
# ele só precisaria derrubar o segundo clique do harness, que não é o que estou
# medindo. Zerar o carimbo é o equivalente a esperar a janela passar.
func _clearFootprint(peerID : int) -> void:
	var peer : Object = peersScript.call("GetPeer", peerID)
	if peer != null:
		(peer.get("rpcDeltas") as Dictionary).clear()

func _settle() -> void:
	for frame in POLL_FRAMES:
		await create_timer(0.05).timeout

# ------------------------------------------------------------------ B) identidade
func _suiteServerIdentity() -> void:
	print("-- B) quem age é o PEER, nunca o que o pacote declara")
	# Peer fantasma: nenhum dos cinco move nada, e o servidor não cai.
	for i in Targets.size():
		# `LeaveGuild` de um peer sem sessão não pode dissolver guilda de ninguém.
		match i:
			0:
				netServer.call("CreateGuild", GUILD_NAME, GHOST_PEER)
			1:
				netServer.call("JoinGuild", 12345, GHOST_PEER)
			2:
				netServer.call("LeaveGuild", GHOST_PEER)
			3:
				netServer.call("DepositToVault", apple, 1, GHOST_PEER)
			4:
				netServer.call("WithdrawFromVault", apple, 1, GHOST_PEER)
	await _settle()
	CheckEq(_guildRowByName().size(), 0, "peer sem sessão não fundiu guilda nenhuma (nem uma linha em `guild`)")
	CheckEq(_count("SELECT COUNT(*) AS n FROM guild_member WHERE account_id = ?;", [acctB]), 0,
			"e nenhum membro foi escrito por peer desconhecido")
	# Sessão real na porta da autoridade: o handler resolve conta e personagem DALI.
	if not Check(_openSession(acctA, charA, authPeer), "sessão de A aberta no peer da autoridade (%d)" % authPeer):
		return
	netServer.call("CreateGuild", GUILD_NAME, authPeer)
	await _settle()
	var row : Dictionary = _guildRowByName()
	guildID = int(row.get("guild_id", 0))
	Check(guildID > 0, "o handler do peer A fundou a guild #%d" % guildID)
	CheckEq(int(row.get("leader_account", -1)), acctA, "leader_account é a CONTA DO PEER, não um número do pacote")
	CheckEq(_memberRank(guildID, acctA), 1, "A entrou como líder (1 linha de membro com rank leader)")
	# B tem a MESMA guild no pacote e outra sessão: quem decide é o peer.
	Check(_openSession(acctB, charB, authPeer), "sessão de B passa a ocupar o mesmo peer (troca de conexão)")
	CheckEq(int(peersScript.call("GetAccount", authPeer)), acctB,
			"feita a troca, o MESMO peer resolve a conta B (sem isto a régua abaixo não mede autoridade, mede o acaso)")
	netServer.call("JoinGuild", guildID, authPeer)
	await _settle()
	CheckEq(_memberRow(guildID, acctB), 1, "quem entrou foi a conta do PEER (B)")
	CheckEq(_memberRow(guildID, acctA), 1, "e A continua com exatamente uma linha (nada duplicado)")
	var panelScript : GDScript = load("res://sources/gui/GuildPanel.gd")
	panel = panelScript.new()
	root.add_child(panel)
	Check(panel.get("feedbackLabel") != null, "painel montado na árvore tem feedbackLabel (o que o jogador lê)")
	gui = launcher.get("GUI")
	if gui != null:
		panelGuiBackup = gui.get("guildWindow")
		gui.set("guildWindow", panel)
	# FORJA: o painel SE DECLARA A (`SetLocalIDs`), mas o peer é B. O pacote não tem
	# campo para dizer isso, então a declaração morre no cliente e o banco só vê B.
	_backdate(0, 0)
	Callable(panel, "SetLocalIDs").call(acctA, charA)
	var membersBefore : int = _count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID])
	await _driveOnClient("LeaveCurrentGuild", [])
	CheckEq(_count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ? AND account_id = ?;", [guildID, acctB]), 0,
			"o peer B saiu da guild — a ação seguiu o PEER")
	CheckEq(_count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ? AND account_id = ?;", [guildID, acctA]), 1,
			"e A, declarado pelo cliente forjado, não se moveu um milímetro")
	CheckEq(_count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ?;", [guildID]), membersBefore - 1,
			"a guilda perdeu exatamente um membro: quem saiu foi B, e a declaração forjada não levou A junto")

# ------------------------------------------------------------------ C) cliente puro
func _suitePureClient() -> void:
	print("-- C) sem Launcher.Economy neste processo, as cinco escritas acontecem no servidor")
	if guildID <= 0 or panel == null:
		Check(false, "guilda da suíte anterior disponível para o caminho de cliente puro")
		return
	Callable(panel, "SetLocalIDs").call(0, 0)
	# B re-entra PELO SERVIDOR antes das pernas do painel. Não é enfeite: com um único
	# membro, o `LeaveGuild` do produto DISSOLVE a guilda (`GuildService.gd:124`) e as
	# quatro pernas seguintes estariam medindo um cadáver — reentrar numa guilda apagada
	# dá `false` pelo motivo errado.
	_openSession(acctB, charB, authPeer)
	netServer.call("JoinGuild", guildID, authPeer)
	await _settle()
	CheckEq(_memberRow(guildID, acctB), 1, "dois membros no banco: a guilda sobrevive à saída medida abaixo")
	# Fundar: quem já tem guilda ouve a recusa do servidor. O caminho de SUCESSO deste
	# mesmo handler foi aferido na suíte B (peer A) — aqui o que importa é que a recusa
	# também atravessa o facade, e não fica presa no `return 0` do painel.
	await _driveOnClient("CreateGuildNamed", ["Guild Rpc Second"])
	Check(_guildRowByNameNamed("Guild Rpc Second").is_empty(),
			"o create de quem já está em guilda é recusado no servidor (nenhuma linha nova)")
	await _driveOnClient("LeaveCurrentGuild", [])
	CheckEq(_memberRow(guildID, acctB), 0, "cliente puro: LeaveCurrentGuild esvaziou a fileira de B")
	CheckEq(_memberRow(guildID, acctA), 1, "e o líder A não se moveu um milímetro (a saída seguiu o peer)")
	CheckEq(_count("SELECT COUNT(*) AS n FROM guild WHERE guild_id = ?;", [guildID]), 1,
			"a guilda continua de pé: dois membros, saiu um — sem dissolução")
	await _driveOnClient("JoinGuildByID", [guildID])
	CheckEq(_memberRow(guildID, acctB), 1, "cliente puro: JoinGuildByID re-entra B na guild")
	Check(int(eco.call("GetGuildForAccount", acctB)) == guildID, "e o service confirma a filiação no banco")
	# Depósito e saque na pessoa do LÍDER: `WithdrawFromVault` exige `leader|officer`
	# (`GuildService.gd:196`), e um member comum sacando aqui mediria a exceção de rank,
	# não a perna de escrita que este bloco promete.
	_openSession(acctA, charA, authPeer)
	suites.call("_SetInventory", sql, charA, apple, 40)
	var before : int = _vaultCount(guildID, apple)
	await _driveOnClient("DepositItem", [apple, 5])
	CheckEq(_vaultCount(guildID, apple), before + 5, "cliente puro: DepositItem entrou no vault do servidor")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 35, "e o inventário debitou os 5")
	await _driveOnClient("WithdrawItem", [apple, 4])
	CheckEq(_vaultCount(guildID, apple), before + 1, "cliente puro: WithdrawItem saiu do vault")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 39, "e o inventário creditou os 4")
	var state : Dictionary = NetClientState()
	Check(bool(state.get("ok", false)), "o estado empurrado por GuildState chegou ao client (NetClient.LastGuildState)")
	var mine : Dictionary = state.get("my_guild", {})
	Check(str(mine.get("name", "")) == GUILD_NAME, "e o snapshot é da guild do peer, não de outro")

# O que `NetClient` guarda do último push de guilda (static var lida pelo script).
func NetClientState() -> Dictionary:
	if netClient == null:
		return {}
	var value : Variant = netClient.get("LastGuildState")
	return value if value is Dictionary else {}

# Clique de verdade com o service AUSENTE neste processo: é exatamente o estado do
# export web. `Launcher.Economy` volta antes do `call_deferred` do facade rodar — no
# produto quem não tem economia é o cliente, e o servidor sempre teve.
func _driveOnClient(methodName : String, args : Array) -> void:
	_clearFootprint(authPeer)
	# O clique só é "de cliente" se o service NÃO estiver neste processo: é este o
	# estado do export web, e sem esconder `Launcher.Economy` o painel tomaria a perna
	# in-process e a régua mediria o servidor com o servidor dentro do bolso.
	var economyWas : Variant = launcher.get("Economy")
	launcher.set("Economy", null)
	Callable(panel, methodName).callv(args)
	launcher.set("Economy", economyWas)
	await _settle()

# ------------------------------------------------------------------ D) teto do servidor
func _suiteServerCaps() -> void:
	print("-- D) no web é o SERVIDOR que segura o oficial: teto por ação e a 4ª da janela")
	if guildID <= 0:
		Check(false, "guilda para aferir o teto do servidor")
		return
	_openSession(acctA, charA, authPeer)
	_backdate(acctA, windowSec + 5)
	_openSession(acctB, charB, GHOST_PEER + 1)
	# O vault é reabastecido PELO SERVIDOR (peer A), não escrevendo a linha na tabela:
	# plantar `guild_vault` à mão faria o teto de saque ser medido contra um vault que o
	# próprio produto não sabe construir.
	var needed : int = perAction * (windowMax + 1)
	suites.call("_SetInventory", sql, charA, apple, needed)
	netServer.call("DepositToVault", apple, needed, authPeer)
	await _settle()
	suites.call("_SetInventory", sql, charA, apple, 0)
	var vaultNow : int = _vaultCount(guildID, apple)
	Check(vaultNow >= perAction * (windowMax + 1),
			"vault reabastecido para os tetes do servidor (%d unidades)" % vaultNow)
	# 1) acima do teto por ação: recusa ANTES de transação, sem linha no rastro.
	var inventoryBefore : int = int(suites.call("_CountItem", sql, charA, apple))
	var trailBefore : int = _withdrawRows(acctA)
	netServer.call("WithdrawFromVault", apple, perAction + 1, authPeer)
	await _settle()
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), inventoryBefore,
			"saque de %d acima do teto (%d) não credita nada" % [perAction + 1, perAction])
	CheckEq(_withdrawRows(acctA), trailBefore, "e não deixa rastro no ledger do vault")
	CheckEq(_vaultCount(guildID, apple), vaultNow, "nem mexeu no vault")
	# 2) rank: B é member comum; o servidor recusa sem a UI no meio.
	var bBefore : int = int(suites.call("_CountItem", sql, charB, apple))
	netServer.call("WithdrawFromVault", apple, perAction, GHOST_PEER + 1)
	await _settle()
	CheckEq(int(suites.call("_CountItem", sql, charB, apple)), bBefore, "member comum não saca (recusa do service)")
	CheckEq(_withdrawRows(acctB), 0, "e a recusa por rank não gastou crédito de janela de B")
	# 3) a janela: três ações passam, a quarta é o SERVIDOR que para.
	var pulled : int = 0
	for attempt in windowMax + 1:
		netServer.call("WithdrawFromVault", apple, perAction, authPeer)
		await _settle()
		pulled = int(suites.call("_CountItem", sql, charA, apple))
	CheckEq(pulled, perAction * windowMax,
			"o handler parou em %d ações de %d, nem uma a mais" % [windowMax, perAction])
	CheckEq(_withdrawRows(acctA) - trailBefore, windowMax, "e o rastro tem exatamente as mesmas 3 linhas")
	# Prova de que a recusa veio do banco/janela e não do portão do painel: o painel
	# desta suíte NUNCA foi chamado aqui — só `netServer`.
	Check(not _panelWasDriven, "nenhum dos recusas acima passou pela UI (o painel ficou quieto)")

# ------------------------------------------------------------------ E) o veredito na tela
var _panelWasDriven : bool = false

func _suiteFeedbackRoute() -> void:
	print("-- E) o veredito do servidor volta para a tela, sem motivo cru")
	if panel == null:
		Check(false, "painel vivo para aferir o veredito")
		return
	var feedbackBody : String = _bodyOf(_fileText("res://sources/network/client/Client.gd"),
			"func GuildFeedback(ok : bool, reason : String, _peerID : int):")
	Check(not feedbackBody.is_empty(), "Client.GuildFeedback é lido por corpo, não por arquivo inteiro")
	# Recusa com token do catálogo: a tela lê frase, nunca o token.
	Callable(panel, "ShowNetworkFeedback").call(false, "bad_args")
	var text : String = str((panel.get("feedbackLabel") as Label).get("text"))
	Check(not text.contains("bad_args"), "o token 'bad_args' não chega cru à linha de feedback (%s)" % text)
	Check(not text.is_empty(), "e a linha não ficou muda")
	Callable(panel, "ShowNetworkFeedback").call(true, "ok")
	Check(str((panel.get("feedbackLabel") as Label).get("text")).contains("done"),
			"veredito positivo pinta feito (não 'enviado')")
	# A rota inteira, com o servidor real recusando por sessão: peer sem login →
	# `not_logged_in` → painel. Sem UI no meio do caminho.
	_openSession(NetworkUnknownAccount(), NetworkUnknownAccount(), authPeer)
	_clearFootprint(authPeer)
	_panelWasDriven = true
	Callable(panel, "SetLocalIDs").call(acctA, charA)
	launcher.set("Economy", null)
	Callable(panel, "DepositItem").call(apple, 1)
	launcher.set("Economy", eco)
	await _settle()
	_panelWasDriven = false
	var refused : String = str((panel.get("feedbackLabel") as Label).get("text"))
	Check(not refused.contains("not_logged_in"), "a recusa de sessão não vaza o token na tela (%s)" % refused)
	Check(not refused.contains("sent to the server"),
			"e o 'enviado' foi substituído pelo veredito real do servidor (%s)" % refused)

func NetworkUnknownAccount() -> int:
	return int((commons.get_script_constant_map() as Dictionary).get("PeerUnknownID", -2))

# ------------------------------------------------------------------ leituras de banco
func _count(query : String, params : Array) -> int:
	var rows : Array = sql.call("QueryBindings", query, params)
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _guildRowByName() -> Dictionary:
	return _guildRowByNameNamed(GUILD_NAME)

func _guildRowByNameNamed(guildName : String) -> Dictionary:
	var rows : Array = sql.call("QueryBindings", "SELECT * FROM guild WHERE name = ?;", [guildName])
	return (rows[0] as Dictionary) if not rows.is_empty() else {}

func _memberRank(gid : int, accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ? AND account_id = ? AND rank = 'leader';", [gid, accountID])

# Quem entrou na guilda entrou como `member`; a régua acima só enxerga o líder, então
# "existe linha de filiação" precisa da própria pergunta, não de um 1 que só o líder dá.
func _memberRow(gid : int, accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM guild_member WHERE guild_id = ? AND account_id = ?;", [gid, accountID])

func _vaultCount(gid : int, itemID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT count FROM guild_vault WHERE guild_id = ? AND item_id = ?;", [gid, itemID])
	return int((rows[0] as Dictionary).get("count", 0)) if not rows.is_empty() else 0

func _withdrawRows(accountID : int) -> int:
	return _count("SELECT COUNT(*) AS n FROM guild_vault_log WHERE account_id = ? AND kind = 'withdraw';", [accountID])

func _backdate(accountID : int, seconds : int) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE kind = 'withdraw';", [])
	if accountID > 0 and seconds > 0:
		sql.call("ExecuteBindings", "UPDATE guild_vault_log SET created_at = created_at - ? WHERE account_id = ? AND kind = 'withdraw';",
				[seconds, accountID])

func _janitor() -> void:
	if sql == null:
		return
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ? OR name = ?);",
			[GUILD_NAME, "Guild Rpc Second"])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ? OR name = ?);",
			[GUILD_NAME, "Guild Rpc Second"])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ? OR name = ?);",
			[GUILD_NAME, "Guild Rpc Second"])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ? OR name = ?;", [GUILD_NAME, "Guild Rpc Second"])
	for entry in FIXTURES:
		var parts : PackedStringArray = entry.split("|")
		sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ?;", [parts[1]])
		sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ?;", [parts[0]])

func _finish() -> void:
	_janitor()
	if gui != null and panelGuiBackup != null:
		gui.set("guildWindow", panelGuiBackup)
	if panel != null and is_instance_valid(panel):
		panel.get_parent().remove_child(panel)
		panel.free()
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== GUILD RPC: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
