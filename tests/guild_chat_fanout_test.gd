extends SceneTree

# SOM-IDLE social (juiz cego 2026-09-27, SOCIAL 5.5/10): o canal de guild era uma
# mentira. `ChatModeration.IsGuildChannel/ResolveGuildPeers` existiam com o
# comentário "o roteador chamaria isto", mas `Server.TriggerChat` não tinha ramo de
# guild: a linha caía no `else` de whisper, não reach NINGUÉM e o falante ainda lia
# "Player 'guild:Foo' is no longer online", enquanto o `GuildPanel` respondia
# "Sent to guild channel." no mesmo clique.
#
# Este harness fecha as pontas com EXECUÇÃO, não com leitura de texto:
#   1. um guildmate numa SEGUNDA sessão conectada RECEBE a linha (uma entrega
#      ChatPlayer endereçada ao peer dele, no canal e com o nick certos);
#   2. um account sem a guild não recebe nada, e o fan-out é exatamente a lista
#      resolvida (falante incluído — sem eco o jogador não vê a própria fala);
#   3. as guardas que já valiam a montante continuam valendo dentro do ramo: teto
#      de tamanho (ClipChat) e mute cobrado no envio;
#   4. o feedback do painel traz o número real de sessões e a frase falsa morreu;
#   5. `ResolveGuildPeers` tem chamador de produção (via FanoutGuildChat em
#      Server.TriggerChat) — réguas de caller no estilo de social_fix_test:191-205.
#
# A observação por sessão é legítima: no boot offline (client+server no mesmo
# processo, o modo deste gate) `Network.CallClient` entrega em
# `Client.callv.call_deferred(metodo, args + [peerID])`, e esse peerID é exatamente a
# chave com que o transporte endereça a sessão. O probe é SUBCLASSE do NetClient real
# (herda todos os handlers; só registra ChatPlayer/ChatSystem), montado no lugar de
# `Network.Client` durante a medição e devolvido no fim. A chegada no cliente REAL
# também é medida: a aba "guild:<nome>" nasce no ChatContainer do HUD com a linha.
#
# Uso: godot --headless --path . -s tests/guild_chat_fanout_test.gd
#       (XDG_DATA_HOME/XDG_CACHE_HOME próprios — ver scripts/test.sh.)
# Exit code: número de checks falhos. Última linha: `== RESULT: N checks, M failures ==`.
#
# Como todo harness `-s`: nada de identificador de autoload (Launcher/Network/Peers/
# ChatModeration/...) nem class_name de projeto em anotação de tipo — o main-loop é
# compilado antes deles existirem. Tudo via load()/get()/call().

const GUILD_NAME := "GuildChatTest Guild"

const PROBE_SOURCE := """
extends "res://sources/network/client/Client.gd"

var inbox : Array = []
var byPeer : Dictionary = {}

func ChatPlayer(channelName : String, callerName : String, text : String, agentRID : int, peerID : int):
	var entry : Dictionary = {"method": "ChatPlayer", "peer": peerID, "channel": channelName, "caller": callerName, "text": text, "rid": agentRID}
	inbox.append(entry)
	if not byPeer.has(peerID):
		byPeer[peerID] = []
	(byPeer[peerID] as Array).append(entry)

func ChatSystem(channelName : String, text : String, peerID : int):
	var entry : Dictionary = {"method": "ChatSystem", "peer": peerID, "channel": channelName, "text": text}
	inbox.append(entry)
	if not byPeer.has(peerID):
		byPeer[peerID] = []
	(byPeer[peerID] as Array).append(entry)
"""

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null
var launcher : Node = null
var sql : Node = null
var economy : Node = null
var network : Node = null
var peersScript : GDScript = null
var chatScript : GDScript = null
var serverNode : Node = null
var commons : GDScript = null
var probe : Node = null
var originalClient : Node = null
var panel : Node = null
var spawnedAgents : Array = []
var _openMute : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(value : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	var same : bool = typeof(value) == typeof(expected) and value == expected
	if not same:
		failures += 1
		print("  [FAIL] %s (got %s, want %s)" % [label, str(value), str(expected)])
		return false
	print("  [ok] " + label)
	return true

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

# Mesmo parser das réguas que já existem (IdleTests._RawFuncBody): do `func nome(`
# ou `static func nome(` até a próxima função de topo. O `static` importa aqui
# porque ChatModeration é uma classe de estado global e todo ela é static.
func _funcBody(text : String, funcName : String) -> Array:
	var out : Array = []
	var plain : String = "func %s(" % funcName
	var static_ : String = "static func %s(" % funcName
	var capturing : bool = false
	for line in text.split("\n"):
		var raw : String = String(line)
		if not capturing:
			if raw.begins_with(plain) or raw.begins_with(static_):
				capturing = true
			continue
		if raw.begins_with("func ") or raw.begins_with("static func "):
			break
		out.append(raw)
	return out

func _joinLines(lines : Array) -> String:
	var joined : String = ""
	for line in lines:
		joined += String(line) + "\n"
	return joined

# Só o código: linhas de comentário fora (os comentários citam a frase velha para
# explicar o que mudou, e uma régua que prende comentário não falha regressão).
func _codeText(text : String) -> String:
	var out : String = ""
	for raw in text.split("\n"):
		var line : String = String(raw).strip_edges()
		if line.begins_with("#"):
			continue
		out += line + "\n"
	return out

func _initialize():
	_run()

func _run() -> void:
	print("== SOM-SOCIAL: fan-out real do chat de guild ==")
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

	# O preload threadado do DB tem que estar drenado antes de qualquer load()/quit()
	# (mesma espera de social_fix_test/hud_wiring_test; sources/db/DB.gd:232).
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

	economy = launcher.get("Economy")
	network = _autoload("Network")
	peersScript = load("res://sources/network/server/Peers.gd")
	chatScript = load("res://sources/network/server/ChatModeration.gd")
	commons = load("res://sources/network/NetworkCommons.gd")
	if not Check(sql != null and economy != null and network != null and peersScript != null and chatScript != null and commons != null,
			"SQL + Economy + Network + Peers + ChatModeration + NetworkCommons booteds"):
		_finish()
		return
	if economy.get("guildService") == null:
		economy.call("_post_launch")
	Check(economy.get("guildService") != null, "GuildService mounted on Economy")
	serverNode = network.get("ENetServer")
	if not Check(serverNode != null, "NetServer do boot offline vive (Network.ENetServer)"):
		_finish()
		return

	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()

	_guildJanitor()
	_fixtureJanitor()
	var charA : int = int(suites.call("CreateFixture", sql, "gchat_founder", "GChatFounder"))
	var charB : int = int(suites.call("CreateFixture", sql, "gchat_member", "GChatMember"))
	var charC : int = int(suites.call("CreateFixture", sql, "gchat_outsider", "GChatOutsider"))
	if not Check(charA != 0 and charB != 0 and charC != 0, "três fixtures (%d, %d, %d)" % [charA, charB, charC]):
		_finish()
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", charA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", charB))
	var acctC : int = int(sql.call("GetAccountIDForCharacter", charC))

	# Guild pelo painel (o caminho do botão, sem comando).
	var panelScript : GDScript = load("res://sources/gui/GuildPanel.gd")
	panel = panelScript.new()
	root.add_child(panel)
	panel.call("SetLocalIDs", acctA, charA)
	var guildID : int = int(panel.call("CreateGuildNamed", GUILD_NAME))
	if not Check(guildID > 0, "panel.CreateGuildNamed fundou a guild #%d" % guildID):
		_finish()
		return
	var found : Array = panel.call("SearchGuildsByName", "GuildChatTest")
	var listedID : int = int((found[0] as Dictionary).get("guild_id", 0)) if not found.is_empty() else 0
	panel.call("SetLocalIDs", acctB, charB)
	Check(bool(panel.call("JoinGuildByID", listedID)), "B entrou na guild pelo painel")
	panel.call("SetLocalIDs", acctA, charA)

	var pidA : int = _openSession(acctA, charA)
	var pidB : int = _openSession(acctB, charB)
	var pidC : int = _openSession(acctC, charC)
	if not Check(pidA > 0 and pidB > 0 and pidC > 0 and pidA != pidB and pidA != pidC,
			"três sessões vivas distintas (A=%d B=%d C=%d)" % [pidA, pidB, pidC]):
		_finish()
		return
	# O falante precisa de um PlayerAgent real: TriggerChat só fala com agente vivo.
	var agentA : Node = await _spawnAgent(charA, "GChatFounder")
	if not Check(agentA != null, "PlayerAgent real do falante A spawnado (TriggerChat exige agente)"):
		_finish()
		return
	var ridA : int = int(agentA.call("get_rid").get_id())
	var peerA : Object = peersScript.GetPeer(pidA)
	peerA.set("agentRID", ridA)
	var senderNick : String = str(agentA.get("nick"))

	var channel : String = str(chatScript.GuildChannelName(GUILD_NAME))
	Check(channel == "guild:" + GUILD_NAME, "canal montado == guild:<nome> (%s)" % channel)

	# ------------------------------------------------- 1) a lista de destinatários
	var resolved : Array = chatScript.ResolveGuildPeers(acctA)
	Check(pidA in resolved, "ResolveGuildPeers inclui o FALANTE (eco próprio, como whisper)")
	Check(pidB in resolved, "ResolveGuildPeers inclui o guildmate B (segunda sessão)")
	Check(not (pidC in resolved), "ResolveGuildPeers NÃO inclui o não-membro C")
	CheckEq(resolved.size(), 2, "dois destinatários resolvidos (A e B)")
	CheckEq(chatScript.ResolveGuildPeers(acctC).size(), 0, "account sem guild não resolve destinatário nenhum")

	# ------------------------------------------------- 2) a entrega real por sessão
	originalClient = network.get("Client")
	probe = _makeProbe()
	if not Check(probe != null, "probe de sessão instalado como Network.Client"):
		_finish()
		return
	network.set("Client", probe)

	var text : String = "raid at the scorpion mine, bring rope"
	serverNode.call("TriggerChat", channel, text, pidA)
	await create_timer(0.25).timeout
	var byPeer : Dictionary = probe.get("byPeer")
	var gotB : Array = byPeer.get(pidB, []) as Array
	var gotA : Array = byPeer.get(pidA, []) as Array
	var gotC : Array = byPeer.get(pidC, []) as Array
	Check(not gotB.is_empty(), "SEGUNDA SESSÃO (B) recebeu uma linha no canal de guild")
	var lineB : Dictionary = (gotB[0] as Dictionary) if not gotB.is_empty() else {}
	Check(str(lineB.get("method", "")) == "ChatPlayer", "a entrega a B foi ChatPlayer (o primitivo de sempre)")
	Check(str(lineB.get("channel", "")) == channel, "B leu a linha NO CANAL guild:<nome>")
	Check(str(lineB.get("text", "")) == text, "B leu o texto integral")
	Check(str(lineB.get("caller", "")) == senderNick, "B viu o nick do falante (%s)" % senderNick)
	CheckEq(gotA.size(), 1, "o falante A recebeu eco da própria linha")
	Check(str((gotA[0] as Dictionary).get("method", "")) == "ChatPlayer", "o eco do falante é ChatPlayer, não sistema")
	CheckEq(gotC.size(), 0, "não-membro C NÃO recebeu nada do canal de guild")
	var inbox : Array = probe.get("inbox")
	var peersDelivered : Array = []
	for entry in inbox:
		var lineEntry : Dictionary = entry as Dictionary
		if str(lineEntry.get("method", "")) != "ChatPlayer":
			continue
		var peerSeen : int = int(lineEntry.get("peer", -99))
		if not (peerSeen in peersDelivered):
			peersDelivered.append(peerSeen)
	CheckEq(peersDelivered.size(), resolved.size(), "fan-out = exatamente a lista resolvida (sem sobra, sem falta)")
	for deliveredPeer in peersDelivered:
		Check(int(deliveredPeer) in resolved, "toda sessão entregue (%d) está na lista resolvida" % int(deliveredPeer))
	var lies : String = ""
	for entry in inbox:
		var probeLine : String = str((entry as Dictionary).get("text", ""))
		if probeLine.contains("is no longer online"):
			lies += probeLine.left(60) + " "
	Check(lies.is_empty(), "o ramo de guild não cai mais no else de whisper (%s)" % lies.left(120))

	# ------------------------------------------------- 3) guardas a montante
	_probeClear()
	serverNode.call("TriggerChat", channel, "x".repeat(500), pidA)
	await create_timer(0.25).timeout
	var clippedSeen : Array = (probe.get("byPeer") as Dictionary).get(pidB, []) as Array
	CheckEq(clippedSeen.size(), 1, "linha acima do teto ainda entrega (uma vez, não truncada em duas)")
	CheckEq(str((clippedSeen[0] as Dictionary).get("text", "")).length(),
			int(commons.get_script_constant_map().get("ChatMaxSize", 240)),
			"teto de tamanho (ClipChat) vale no ramo de guild também")

	_probeClear()
	_openMute = acctA
	Check(bool(chatScript.Mute(acctA, int(Time.get_unix_time_from_system()) + 120, "spam probe", 0)),
			"mute aplicado ao falante")
	serverNode.call("TriggerChat", channel, "should not go anywhere", pidA)
	await create_timer(0.25).timeout
	var mutedInbox : Array = probe.get("inbox")
	CheckEq(mutedInbox.size(), 1, "mute: exatamente uma linha, e só para o próprio falante")
	var muteEntry : Dictionary = (mutedInbox[0] as Dictionary) if not mutedInbox.is_empty() else {}
	Check(str(muteEntry.get("method", "")) == "ChatSystem" and int(muteEntry.get("peer", -1)) == pidA,
			"mute: o fan-out de guild NÃO rodou (sanção no envio, nunca no recebimento)")
	Check(bool(chatScript.Unmute(acctA)), "mute levantado")
	_openMute = 0

	# ------------------------------------------------- 4) os outros ramos não são guild
	# LOCAL continua LOCAL: o ramo novo não sequestra o canal "0". (A entrega de
	# vizinhança do ramo antigo é outra régua, já coberta em social/IdleTests.)
	_probeClear()
	serverNode.call("TriggerChat", "0", "not a guild line", pidA)
	await create_timer(0.25).timeout
	var onGuildAfterLocal : int = 0
	for entry in (probe.get("inbox") as Array):
		if str((entry as Dictionary).get("channel", "")) == channel:
			onGuildAfterLocal += 1
	CheckEq(onGuildAfterLocal, 0, "ramo LOCAL não escreve nada no canal de guild")
	CheckEq(((probe.get("byPeer") as Dictionary).get(pidB, []) as Array).size(), 0, "LOCAL não alcança a sessão B pelo canal de guild")

	# Canal forjado: o NOME vem do estado autoritativo, não do pacote. Quem escreve
	# "guild:FakeRival" fala com a própria guild — e não fabrica aba de rival na tela
	# de ninguém.
	_probeClear()
	serverNode.call("TriggerChat", "guild:FakeRival", "forged channel attempt", pidA)
	await create_timer(0.25).timeout
	var forgedSeen : int = 0
	for entry in (probe.get("inbox") as Array):
		if str((entry as Dictionary).get("channel", "")) == "guild:FakeRival":
			forgedSeen += 1
	CheckEq(forgedSeen, 0, "nenhuma sessão recebe no canal forjado guild:FakeRival")
	var rerouted : Array = (probe.get("byPeer") as Dictionary).get(pidB, []) as Array
	CheckEq(rerouted.size(), 1, "a linha forjada caiu no canal CANÔNICO da guild de quem falou")
	Check(str((rerouted[0] as Dictionary).get("channel", "")) == channel, "o canal entregue é guild:<nome real>")
	CheckEq(((probe.get("byPeer") as Dictionary).get(pidC, []) as Array).size(), 0, "o não-membro continua de fora do ramo de guild")

	# ------------------------------------------------- 5) feedback honesto do painel
	panel.call("Refresh")
	var sessions : int = int(panel.call("OnlineMemberSessions"))
	CheckEq(sessions, resolved.size(), "painel conta as MESMAS sessões que o roteador vai tocar (%d)" % sessions)
	var feedback : Label = panel.get("feedbackLabel") as Label
	Check(feedback != null, "GuildPanel.feedbackLabel montado (UI construída em árvore)")
	if feedback != null:
		feedback.text = ""
		panel.call("SendGuildChat", "on the way")
		await create_timer(0.25).timeout
		var said : String = feedback.text
		Check(said.contains(str(sessions)), "feedback do painel traz o número REAL de sessões (%s)" % said.left(90))
		Check(not said.contains("Sent to guild channel."), "a frase \"Sent to guild channel.\" morreu (%s)" % said.left(60))
		peersScript.RemovePeer(pidB)
		panel.call("Refresh")
		CheckEq(int(panel.call("OnlineMemberSessions")), sessions - 1,
				"sessão que sai do ar some da contagem do painel (%d -> %d)" % [sessions, sessions - 1])
		feedback.text = ""
		panel.call("SendGuildChat", "solo line")
		await create_timer(0.25).timeout
		Check(feedback.text.contains(str(sessions - 1)),
				"o feedback seguiu o número real também depois da queda (%s)" % feedback.text.left(90))

	# ------------------------------------------------- 6) chegada no cliente REAL
	var gui : Node = launcher.get("GUI")
	var chatContainer : Node = gui.get("chatContainer") if gui != null else null
	if Check(chatContainer != null, "ChatContainer do HUD vive (chegada real no cliente)"):
		_probeRestore()
		serverNode.call("TriggerChat", channel, "real client tab probe", pidA)
		await create_timer(0.4).timeout
		var tabs : Dictionary = chatContainer.get("channelTabs")
		Check(tabs.has(channel), "o cliente abriu a aba do canal guild:<nome>")
		var tabIdx : int = int(tabs.get(channel, -1))
		var tabContainer : Node = chatContainer.get("tabContainer")
		var tabNode : Node = tabContainer.call("get_tab_control", tabIdx) if tabContainer != null else null
		var rendered : String = str(tabNode.get("text")) if tabNode != null else ""
		Check(rendered.contains("real client tab probe"), "a linha está escrita na aba do cliente (%s)" % rendered.left(90))
		Check(rendered.contains(senderNick), "com o nick de quem falou")

	# ------------------------------------------------- 7) caller de produção (source)
	var serverText : String = _repoFile("res://sources/network/server/Server.gd")
	var chatBodyLines : Array = _funcBody(serverText, "TriggerChat")
	if Check(not chatBodyLines.is_empty(), "servidor: corpo de TriggerChat localizado"):
		var bodyText : String = _joinLines(chatBodyLines)
		Check(bodyText.contains("ChatModeration.IsGuildChannel("), "servidor: TriggerChat reconhece o canal de guild")
		Check(bodyText.contains("ChatModeration.FanoutGuildChat("), "servidor: TriggerChat chama o fan-out (ResolveGuildPeers ganhou caller de produção)")
		Check(bodyText.contains("ChatModeration.CanSpeak("), "servidor: o mute continua a montante do ramo de guild")
		Check(bodyText.find("ChatModeration.CanSpeak(") < bodyText.find("ChatModeration.FanoutGuildChat("),
				"servidor: o mute é cobrado ANTES de qualquer difusão de guild")
		var disseminators : int = 0
		for raw in chatBodyLines:
			var line : String = String(raw)
			if line.contains("NotifyNeighbours") or line.contains("NotifyGlobal") or line.contains("Network.ChatPlayer"):
				disseminators += 1
		CheckEq(disseminators, 4, "servidor: local + global + 2 whispers (o ramo novo usa o helper, não um portal paralelo)")
		var branchLines : int = 0
		for raw in chatBodyLines:
			var line : String = String(raw)
			if line.contains("ChatModeration.IsGuildChannel(") or line.contains("FanoutGuildChat(") or line.contains("No guild member session"):
				branchLines += 1
		Check(branchLines <= 5, "servidor: o ramo novo são %d linha(s) — Server.gd está em allowlist de tamanho" % branchLines)
	var chatText : String = _repoFile("res://sources/network/server/ChatModeration.gd")
	var fanLines : Array = _funcBody(chatText, "FanoutGuildChat")
	if Check(not fanLines.is_empty(), "ChatModeration: corpo de FanoutGuildChat localizado"):
		var fanText : String = _joinLines(fanLines)
		Check(fanText.contains("ResolveGuildPeers("), "ChatModeration: FanoutGuildChat consome ResolveGuildPeers (caller real, não comentário)")
		Check(fanText.contains("Network.ChatPlayer("), "ChatModeration: a difusão é o primitivo existente (ChatPlayer por peer)")
	Check(_hasScriptMethod(chatScript, "FanoutGuildChat"), "ChatModeration.FanoutGuildChat exposto")
	Check(_hasScriptMethod(chatScript, "ResolveGuildPeers"), "ChatModeration.ResolveGuildPeers exposto")
	Check(not chatText.contains("if accID == senderAccount:"), "ResolveGuildPeers parou de excluir o falante")
	# GDScript não tem as_text(): a frase falsa é procurada no texto do arquivo,
	# e só no CÓDIGO — o comentário que explica a mudança cita a frase velha.
	var panelText : String = _repoFile("res://sources/gui/GuildPanel.gd")
	if Check(not panelText.is_empty(), "GuildPanel.gd lido do disco"):
		var panelCode : String = _codeText(panelText)
		Check(not panelCode.contains("Sent to guild channel."), "GuildPanel: a afirmação falsa saiu do código")
		Check(not panelCode.contains("ChatModeration"), "GuildPanel não toca a camada de moderação (fronteira que o gate prende)")
	Check(_hasScriptMethod(panelScript, "OnlineMemberSessions"), "GuildPanel.OnlineMemberSessions exposto (conta real de sessões)")

	_finish()

# -------------------------------------------------------------------------- helpers

# Sessão viva: o que Peers.SetAccount escreve num login real (peer na tabela,
# conta→peer no índice inverso, personagem carimbado).
func _openSession(accountID : int, charID : int) -> int:
	var candidate : int = 820000 + accountID
	while bool(peersScript.HasPeer(candidate)):
		candidate += 1
	peersScript.AddPeer(candidate, 0)
	var peer : Object = peersScript.GetPeer(candidate)
	if peer == null:
		return 0
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(peersScript.accounts as Dictionary)[accountID] = candidate
	return candidate

func _makeProbe() -> Node:
	var script : GDScript = GDScript.new()
	script.source_code = PROBE_SOURCE
	# `reload()` devolve um Error (0 = OK), não bool — inverter isso era o probe
	# "não compilar" mesmo compilando.
	if int(script.reload()) != 0:
		print("FATAL: probe de cliente não compilou")
		return null
	# `NetInterface._init` já se pendura em Launcher.Root com call_deferred e cria o
	# próprio multiplayer peer: daqui é exatamente um NetClient offline, só que com
	# ChatPlayer/ChatSystem gravados. Não add_child de novo — o filho já tem dono.
	var node : Node = script.new(false, false, true, true) as Node
	if node == null:
		return null
	node.set_name("GuildChatProbe")
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

# PlayerAgent real na farm instance da zona 1 — mesmo mecanismo de
# economy_design_fix_test._spawnLiveAgent / IdleTests._SpawnSimAgent.
func _spawnAgent(charID : int, nickname : String) -> Node:
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var zone : Object = farmScript.GetZone(1)
	if zone == null:
		return null
	var map : Object = launcher.get("World").call("GetMap", int(zone.get("mapID")))
	if map == null:
		return null
	var policy : GDScript = load("res://sources/idle/IdlePolicyService.gd")
	var instID : int = int(policy.GetFarmInstanceID(1))
	var instances : Dictionary = map.get("instances")
	var stale : Object = instances.get(instID, null)
	if stale != null:
		stale.call("Destroy")
		instances.erase(instID)
	map.call("CreateInstance", instID)
	var warm : bool = false
	for i in 200:
		var candidate : Object = policy.GetFarmInstance(1)
		var navID : int = int(NavigationServer2D.map_get_iteration_id(map.get("mapRID")))
		if candidate != null and bool(candidate.call("is_node_ready")) and navID > 0:
			warm = true
			break
		await process_frame
	if not warm:
		return null
	var actorCommons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var spawnScript : GDScript = load("res://addons/tiled_importer/SpawnObject.gd")
	var spawnPoint : Object = spawnScript.new()
	spawnPoint.set("map", map)
	spawnPoint.set("type", int(actorCommons.Type.PLAYER))
	spawnPoint.set("id", int(dbScript.PlayerHash))
	spawnPoint.set("is_global", false)
	var anchor : Object = null
	for spawn in (map.get("spawns") as Array):
		if spawn != null and int(spawn.get("type")) == int(actorCommons.Type.MONSTER):
			anchor = spawn
			break
	spawnPoint.set("spawn_position", anchor.get("spawn_position") if anchor != null else Vector2i.ZERO)
	var worldAgent : GDScript = load("res://sources/world/WorldAgent.gd")
	var agent : Node = worldAgent.CreateAgent(spawnPoint, instID, nickname) as Node
	if agent == null:
		return null
	agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
	spawnedAgents.append(agent)
	return agent

func _guildJanitor() -> void:
	if sql == null:
		return
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [GUILD_NAME])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [GUILD_NAME])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [GUILD_NAME])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [GUILD_NAME])

# Regressão sofrida nesta suíte: uma execução abortada no meio deixa os três
# fixtures no testing.db e a execução seguinte derruba o processo. Limpar antes
# de criar custa quatro linhas e torna a régua idempotente.
func _fixtureJanitor() -> void:
	if sql == null:
		return
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ? OR nickname = ? OR nickname = ?;",
			["GChatFounder", "GChatMember", "GChatOutsider"])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ? OR username = ? OR username = ?;",
			["gchat_founder", "gchat_member", "gchat_outsider"])

func _finish() -> void:
	_probeRestore()
	if chatScript != null and _openMute > 0:
		chatScript.Unmute(_openMute)
		_openMute = 0
	if panel != null and is_instance_valid(panel):
		_guildJanitor()
		sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ? OR nickname = ? OR nickname = ?;",
				["GChatFounder", "GChatMember", "GChatOutsider"])
		sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ? OR username = ? OR username = ?;",
				["gchat_founder", "gchat_member", "gchat_outsider"])
		for agent in spawnedAgents:
			var node : Node = agent as Node
			if node != null and is_instance_valid(node):
				node.queue_free()
		if peersScript != null:
			for pid in (peersScript.peers as Dictionary).keys():
				if int(pid) >= 820000:
					peersScript.RemovePeer(int(pid))
		panel.get_parent().remove_child(panel)
		panel.free()
		panel = null
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
