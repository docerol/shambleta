extends SceneTree

# SOM-IDLE #86 (auditoria 2026-09-29): o orçamento de RPC morava na porta errada.
# `Network.CallServer` chama `Peers.Footprint`, que é (a) um INTERVALO MÍNIMO por
# (peer, método) e não uma cota — a primeira chamada sempre passa e quem mantém 20/s para
# sempre mantém 20/s para sempre; (b) com `NetworkCommons.DelayInstant` (=0) devolve
# `true` sem condição nenhuma; e (c) fica a montante do handler, na porta por onde o
# chamador decide se passa. O handler do servidor é alcançável por dentro do processo —
# foi exatamente assim que `tests/guild_chat_fanout_test.gd` e `tests/social_graph_test.gd`
# sempre mediram chat, e é assim que este runner dispara: sem `CallServer`, sem
# `Footprint`, sem cliente.
#
# O que esta suíte prende, com mordida:
#
#   R1  COBERTURA, derivada do fonte (não de lista à mão): todo handler de `Server.gd`
#       cujo corpo difunde (`Network.NotifyNeighbours/NotifyGlobal/NotifyArea/
#       NotifyInstance`, `Network.ChatPlayer`, `FanoutGuildChat`) e todo handler alcançado
#       em `Network.gd` com `DelayInstant` precisa do guard `RateLimit.Charge` como
#       PRIMEIRA linha de código, cobrando o `peerID` do transporte com o próprio nome do
#       handler, e com cota nomeada na tabela. O controle arranca o guard do `TriggerChat`
#       em memória e confere que a régua passa a NÃO achá-lo: sem a correção ela vai a
#       VERMELHO, não a "verde por omissão".
#   R2  CORTE NO RECEBIMENTO: 200 `TriggerChat` endereçados direto ao handler, relógio
#       parado num único balde. Aceitas == cota; recusadas == 200 - cota; e — a parte que
#       não é contador — as ENTREGAS medidas no probe são exatamente a cota. Na mesma
#       passada, o contrafactual: as mesmas 200 linhas por `Network.NotifyGlobal` entregam
#       as 200, provando que nada mais no processo cortava e que o corte foi do guard.
#       O custo do cliente que inunda é impresso (linhas/s que o Footprint deixava passar,
#       fator do corte, pacotes de difusão evitados por balde).
#   R3  FOOTPRINT NÃO PARTICIPOU: `peer.rpcDeltas` não ganha a chave `TriggerChat` durante
#       a inundação — evidência MEDIDA de que o caminho não passou por `CallServer`.
#   R4  COTA POR SESSÃO, NÃO POR PACOTE: com A esgotada, B fala e é atendido; e inundar
#       trocando o `channelName` (whisper forjado, `guild:…`, local) não cria balde novo
#       nem poupa o agressor.
#   R5  JANELA, NÃO BANIMENTO: virado o balde, A volta a falar.
#   R6  DELAYINSTANT NA PRÁTICA: `SetMovePos` (1000 chamadas) e `SetViewportSize` (200)
#       cortados em números exatos, com o custo do corte medido em ms.
#   R7  O LIMITER NÃO ESCOLHE IDENTIDADE: `RateLimit.Charge` não lê characterID, accountID,
#       nick, canal nem `args`; o guard só recebe o mesmo inteiro que o handler já usa em
#       `Peers.GetAgent(peerID)`; a régua que guarda isso (`identidade nunca vem do
#       pacote`, em tests/run_rpc_identity_test.gd) continua no arquivo; e a queda de
#       sessão solta o balde (peerID é reciclado) — estrutural em `FullyDisconnect` e
#       comportamental no fim.
#
# Uso: bash scripts/test.sh one rpc_receive_budget_test 900
# Exit code: número de checks falhos. Última linha:
#   `== RPC RECEIVE BUDGET: N checks, M failures ==`.
#
# O controle negativo de R1 existe só em MEMÓRIA (texto mutado): nenhum arquivo do repo é
# tocado, nada vai a disco, não há artefato a remover depois.
#
# Como todo harness `-s`: nada de identificador de autoload ou class_name de projeto aqui
# — tudo via load()/get()/call().

const FLOOD : int			= 200
const MOVE_FLOOD : int			= 1000
const VIEW_FLOOD : int			= 200
const PEER_BASE : int			= 830000
const FIX_SEC : int			= 1750000000
const DB_BOOT_BUDGET_MS : int		= 30000

const PROBE_SOURCE := """
extends "res://sources/network/client/Client.gd"

var inbox : Array = []
var delivered : Dictionary = {}

func ChatPlayer(channelName : String, callerName : String, text : String, agentRID : int, peerID : int):
	inbox.append({"method": "ChatPlayer", "peer": peerID, "channel": channelName, "text": text, "rid": agentRID})
	delivered[text] = int(delivered.get(text, 0)) + 1

func ChatSystem(channelName : String, text : String, peerID : int):
	inbox.append({"method": "ChatSystem", "peer": peerID, "channel": channelName, "text": text})
"""

var checks : int				= 0
var failures : int				= 0
var frames : int				= 0
var launcher : Node				= null
var sql : Node				= null
var network : Node				= null
var serverNode : Node				= null
var peersScript : GDScript			= null
var rateScript : GDScript			= null
var commons : GDScript			= null
var guiCommons : GDScript			= null
var dbScript : GDScript			= null
var probe : Node				= null
var originalClient : Node			= null
var spawnedAgents : Array			= []
var sessionPeers : Array			= []
var serverText : String			= ""
var networkText : String			= ""
var rateText : String			= ""
var chatBudget : int				= 0
var windowSec : int				= 30
var waitingForBoot : bool			= false
var bootStartMs : int				= 0
var bootDeadlineMs : int			= 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	return Check(got == want, "%s (got %s, want %s)" % [label, str(got), str(want)])

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()

func _const(script : Object, name : String) -> Variant:
	return script.call("get_script_constant_map").get(name, null)

func _join(lines : Array) -> String:
	var out : String = ""
	for raw in lines:
		out += String(raw) + "\n"
	return out

# ------------------------------------------------------------------- parseadores de fonte
# nome da função declarada numa linha de topo, ou "" se a linha não declara função
func _funcName(line : String) -> String:
	var head : String = line
	if head.begins_with("static "):
		head = head.substr(7)
	if not head.begins_with("func "):
		return ""
	head = head.substr(5)
	var open : int = head.find("(")
	return "" if open < 0 else head.substr(0, open)

# corpo de todas as funções de topo: nome -> linhas (sem a linha `func`)
func _bodies(text : String) -> Dictionary:
	var out : Dictionary = {}
	var current : String = ""
	for raw in text.split("\n"):
		var line : String = String(raw)
		var declared : String = _funcName(line)
		if not declared.is_empty():
			current = declared
			out[current] = []
			continue
		if not current.is_empty():
			(out[current] as Array).append(line)
	return out

# primeira linha de CÓDIGO do corpo: comentário e linha em branco não contam — é o que
# impede um `return` cosmético acima do guard de virar a porta dos fundos
func _firstCodeLine(lines : Array) -> String:
	for raw in lines:
		var line : String = String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		return line
	return ""

var _reGuard : RegEx = RegEx.create_from_string("^if not RateLimit\\.Charge\\(\\s*([A-Za-z_]+)\\s*,\\s*\"([^\"]+)\"\\s*\\):\\s*return")
var _reCall : RegEx = RegEx.create_from_string("CallServer\\(\"([A-Za-z_]+)\"")

# Handlers que DIFFUNDEM: o efeito é trabalho POR DESTINATÁRIO, não por pacote.
func _diffusers(bodies : Dictionary) -> Array:
	var tokens : Array = ["Network.NotifyNeighbours(", "Network.NotifyGlobal(", "Network.NotifyArea(",
			"Network.NotifyInstance(", "Network.ChatPlayer(", "FanoutGuildChat("]
	var found : Array = []
	for name in bodies:
		for raw in (bodies[name] as Array):
			var line : String = String(raw)
			if line.strip_edges().begins_with("#"):
				continue
			for token in tokens:
				if line.contains(token):
					if not (name in found):
						found.append(name)
					break
	return found

# Handlers alcançados por um `CallServer(..., NetworkCommons.DelayInstant)` no facade.
func _instantMethods(text : String) -> Array:
	var found : Array = []
	for raw in text.split("\n"):
		var line : String = String(raw)
		if line.strip_edges().begins_with("#") or not line.contains("DelayInstant"):
			continue
		var m : RegExMatch = _reCall.search(line)
		if m != null and not (m.get_string(1) in found):
			found.append(m.get_string(1))
	return found

# Guards vivos: handler -> {identity, method}
func _charged(bodies : Dictionary) -> Dictionary:
	var out : Dictionary = {}
	for name in bodies:
		var m : RegExMatch = _reGuard.search(_firstCodeLine(bodies[name] as Array))
		if m != null:
			out[name] = {"identity": m.get_string(1), "method": m.get_string(2)}
	return out

func _initialize():
	print("== SOM-#86: cota de RPC no caminho de RECEBIMENTO do servidor ==")
	serverText = _read("res://sources/network/server/Server.gd")
	networkText = _read("res://sources/network/Network.gd")
	rateText = _read("res://sources/network/server/RateLimit.gd")
	if not Check(serverText.length() > 400 and networkText.length() > 400 and rateText.length() > 400,
			"Server.gd, Network.gd e RateLimit.gd lidos do disco (%d/%d/%d B)" % [serverText.length(), networkText.length(), rateText.length()]):
		_finish(1)
		return
	_suiteCoverage()
	_suiteIdentityRules()
	_behaviour()

# ---------------------------------------------------------------- R1) cobertura estrutural
func _suiteCoverage() -> void:
	print("-- R1) quem difunde ou é DelayInstant tem guard na primeira linha de código")
	var bodies : Dictionary = _bodies(serverText)
	var charged : Dictionary = _charged(bodies)
	var diffuse : Array = _diffusers(bodies)
	var instant : Array = _instantMethods(networkText)
	print("  medido: %d handlers em Server.gd | %d difundem [%s] | %d com DelayInstant [%s] | %d com guard" % [bodies.size(), diffuse.size(), ", ".join(PackedStringArray(diffuse)), instant.size(), ", ".join(PackedStringArray(instant)), charged.size()])
	Check(diffuse.size() >= 2, "R1 a régua de difusão acha pelo menos chat e emote (%d achados)" % diffuse.size())
	Check(instant.size() >= 2, "R1 a régua DelayInstant acha SetMovePos e SetViewportSize (%d achados)" % instant.size())
	for name in diffuse:
		Check(charged.has(name), "R1 handler que difunde '%s' tem guard no recebimento" % String(name))
	for name in instant:
		Check(charged.has(name), "R1 handler chamado com DelayInstant '%s' tem guard no recebimento" % String(name))
	var table : String = _join(_bodies(rateText).get("BudgetFor", []))
	for name in charged:
		var entry : Dictionary = charged[name]
		CheckEq(String(entry["identity"]), "peerID", "R1 %s: o guard cobra o peerID do transporte, não um argumento do pacote" % String(name))
		CheckEq(String(entry["method"]), String(name), "R1 %s: a string cobrada é o nome do próprio handler (dígito errado não abre buraco)" % String(name))
		Check(table.contains("\"%s\"" % String(name)), "R1 %s tem cota nomeada na tabela de BudgetFor (não vive do default por acidente)" % String(name))

	# CONTROLE NEGATIVO (em memória): guard arrancado → a cobertura passa a faltar.
	var stripped : String = serverText.replace("\tif not RateLimit.Charge(peerID, \"TriggerChat\"): return null\t# #86: difusão comprada no recebimento\n", "")
	if Check(stripped != serverText, "R1 controle: a linha do guard de TriggerChat foi achada para ser arrancada"):
		var mutatedCharged : Dictionary = _charged(_bodies(stripped))
		Check(not mutatedCharged.has("TriggerChat"), "R1 controle NEGATIVO: sem o guard a régua não acha TriggerChat — com a correção ausente ela ia a VERMELHO, não a verde por omissão")
		var mutatedDiffuse : Array = _diffusers(_bodies(stripped))
		Check("TriggerChat" in mutatedDiffuse, "R1 controle: TriggerChat continua difundindo sem o guard (o efeito existe; só ficou sem cota)")
		Check(_charged(bodies).has("TriggerChat"), "R1 produto: a MESMA régua no texto do disco acha TriggerChat")

# ------------------------------------------------- R7) identidade continua no transporte
func _suiteIdentityRules() -> void:
	print("-- R7) o limiter não virou o lugar onde o pacote escolhe identidade")
	var charge : String = _join(_bodies(rateText).get("Charge", []))
	var forbidden : Array = ["GetCharacter(", "GetAccount(", "GetPeer(", "GetAgent(", "characterID", "accountID", "nick", "channelName", "args", "text", "direction"]
	for token in forbidden:
		Check(not charge.contains(token), "R7 Charge() não lê '%s' — a chave é peerID + nome do método e mais nada" % token)
	Check(charge.contains("peerID"), "R7 Charge() usa o peerID que recebeu (o mesmo inteiro do handler)")
	var disconnect : String = _join(_bodies(serverText).get("FullyDisconnect", []))
	Check(disconnect.contains("RateLimit.Forget(peerID)"), "R7 queda de sessão solta o balde (peerID reciclado: a cota do antecessor não passa adiante)")
	var identityRuler : String = _read("res://tests/run_rpc_identity_test.gd")
	Check(identityRuler.contains("identidade nunca vem do pacote"), "R7 a régua de identidade que já existia continua no lugar (não foi enfraquecida)")
	Check(_bodies(rateText).has("Charge") and _bodies(rateText).has("Forget") and _bodies(rateText).has("Prune"), "R7 RateLimit expõe Charge/Forget/Prune (nada de limiter invisível)")
	Check(not rateText.contains("multiplayerAPI"), "R7 RateLimit não toca transporte: não há como escolher sender por aqui")

# ------------------------------------------- boot do jogo + suítes comportamentais (R2..R6)
func _behaviour() -> void:
	launcher = root.get_node_or_null(NodePath("Launcher"))
	if not Check(launcher != null, "Launcher autoload presente"):
		_finish(2)
		return
	var waited : int = 0
	while waited < 45000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and worldNode != null and bool(worldNode.get("isInitialized")):
			break
	print("== boot wait done (%d ms) ==" % waited)
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()/quit()"):
		_finish(3)
		return
	network = root.get_node_or_null(NodePath("Network"))
	peersScript = load("res://sources/network/server/Peers.gd")
	rateScript = load("res://sources/network/server/RateLimit.gd")
	commons = load("res://sources/network/NetworkCommons.gd")
	guiCommons = load("res://sources/gui/GUICommons.gd")
	serverNode = network.get("ENetServer")
	if not Check(serverNode != null and rateScript != null and guiCommons != null and peersScript != null,
			"NetServer do boot offline + RateLimit + Peers + GUICommons carregados"):
		_finish(4)
		return
	windowSec = int(_const(rateScript, "WindowSec"))
	chatBudget = int(rateScript.BudgetFor("TriggerChat"))
	Check(windowSec > 0 and chatBudget > 0, "números lidos do produto: balde=%ds, cota de chat=%d linhas" % [windowSec, chatBudget])

	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	_janitor()
	var charA : int = int(suites.call("CreateFixture", sql, "rlimit_a", "RLimitA"))
	var charB : int = int(suites.call("CreateFixture", sql, "rlimit_b", "RLimitB"))
	if not Check(charA != 0 and charB != 0, "dois fixtures criados (%d, %d)" % [charA, charB]):
		_finish(5)
		return
	var pidA : int = _openSession(int(sql.call("GetAccountIDForCharacter", charA)), charA)
	var pidB : int = _openSession(int(sql.call("GetAccountIDForCharacter", charB)), charB)
	if not Check(pidA > 0 and pidB > 0 and pidA != pidB, "duas sessões vivas (A=%d, B=%d)" % [pidA, pidB]):
		_finish(6)
		return
	var agentA : Node = await _spawnAgent(charA, "RLimitA")
	var agentB : Node = await _spawnAgent(charB, "RLimitB")
	if not Check(agentA != null and agentB != null, "dois PlayerAgent reais spawnados, A=%s B=%s (TriggerChat só fala com agente vivo)" % [str(agentA != null), str(agentB != null)]):
		_finish(7)
		return
	(peersScript.GetPeer(pidA) as Object).set("agentRID", int(agentA.call("get_rid").get_id()))
	(peersScript.GetPeer(pidB) as Object).set("agentRID", int(agentB.call("get_rid").get_id()))
	# O outro lado do par: `NotifyInstance` só entrega a quem tem `peerID` no AGENTE
	# (sources/network/server/Server.gd:527 é onde o produto escreve isso na entrada do
	# mundo). Sem este par o `TriggerChat` global difunde para ninguém e a régua de
	# "corte no efeito" mede 0 entregas por motivo de montagem, não de cota — medido em
	# 2026-09-29, com o R2 contrafactual (Network.ChatPlayer direto, que passa o peerID
	# como argumento) entregando os 200 enquanto o handler entregava zero.
	agentA.set("peerID", pidA)
	agentB.set("peerID", pidB)

	originalClient = network.get("Client")
	probe = _makeProbe()
	if not Check(probe != null, "probe de cliente instalado (entrega medida, não contador inferido)"):
		_finish(8)
		return
	network.set("Client", probe)

	var globalChannel : String = str(guiCommons.ChatChannel.GLOBAL)
	rateScript.Reset()
	rateScript.SetClock(FIX_SEC)

	# -------------------------------------------------- R2/R3/R4: 200 disparos no handler
	print("-- R2/R3/R4) %d TriggerChat direto no handler, sem CallServer" % FLOOD)
	var peerA : Object = peersScript.GetPeer(pidA)
	var deltasBefore : int = (peerA.get("rpcDeltas") as Dictionary).size()
	_clearProbe()
	var t0 : int = Time.get_ticks_msec()
	for i in range(FLOOD):
		serverNode.call("TriggerChat", globalChannel, "flood %d" % i, pidA)
	var elapsed : int = Time.get_ticks_msec() - t0
	await create_timer(0.8).timeout
	var allowed : int = int(rateScript.AllowedCount("TriggerChat"))
	var refused : int = int(rateScript.RefusalCount("TriggerChat"))
	var delivered : int = _distinctDelivered()
	print("  produto: %d chamadas em %d ms | aceitas=%d (cota %d por balde de %ds) | recusadas=%d | linhas ENTREGUES medidas=%d" % [FLOOD, elapsed, allowed, chatBudget, windowSec, refused, delivered])
	CheckEq(allowed, chatBudget, "R2 o que passou é exatamente a cota do balde")
	CheckEq(refused, FLOOD - chatBudget, "R2 o resto foi cortado no recebimento")
	CheckEq(delivered, chatBudget, "R2 as entregas medidas no cliente são a cota — o corte é no efeito, não só no contador")
	var delayMs : int = int(_const(commons, "DelayDefault"))
	var perWindow : int = int(float(windowSec) * 1000.0 / float(maxi(delayMs, 1)))
	print("  custo do cliente que inunda: o Footprint de %d ms deixava passar %d linhas por balde de %ds; com a cota do servidor são %d (corte de %.1fx) = %d pacotes de difusão evitados por balde" % [delayMs, perWindow, windowSec, chatBudget, float(perWindow) / float(maxi(chatBudget, 1)), perWindow - chatBudget])
	Check(chatBudget <= 24, "R2 a cota é de fato aperta (%d linhas por %d s <= 24)" % [chatBudget, windowSec])
	Check(allowed < FLOOD, "R2 a inundação não passou inteira")

	# R3: o orçamento do cliente nunca viu este caminho.
	var deltasAfter : int = (peerA.get("rpcDeltas") as Dictionary).size()
	var sawChat : bool = (peerA.get("rpcDeltas") as Dictionary).has(&"TriggerChat")
	print("  Footprint: |rpcDeltas| antes=%d depois=%d; chave 'TriggerChat' vista=%s" % [deltasBefore, deltasAfter, str(sawChat)])
	CheckEq(deltasAfter, deltasBefore, "R3 a inundação não tocou o orçamento do cliente — o corte veio do servidor")
	Check(not sawChat, "R3 'TriggerChat' nunca entrou em rpcDeltas: CallServer foi de fato contornado")

	# Contrafactual: o primitivo, sem guard, entrega tudo.
	_clearProbe()
	for i in range(FLOOD):
		network.call("ChatPlayer", globalChannel, "contrafactual", "counterfactual %d" % i, 0, pidA)
	await create_timer(0.8).timeout
	var cf : int = _distinctDelivered()
	print("  contrafactual (Network.ChatPlayer direto, mesmo primitivo do handler): %d de %d linhas entregues" % [cf, FLOOD])
	CheckEq(cf, FLOOD, "R2 contrafactual: nada mais no processo cortava a difusão — quem cortou foi o guard")

	# R4: com A esgotada, B fala e é atendido.
	_clearProbe()
	for i in range(3):
		serverNode.call("TriggerChat", globalChannel, "B fala %d" % i, pidB)
	await create_timer(0.6).timeout
	CheckEq(_distinctDelivered(), 3, "R4 B não paga pela inundação de A (cota por sessão)")
	Check(int(rateScript.LedgerSize()) <= 8, "R4 o ledger cresce por (sessão, método), não por pacote (%d chaves)" % int(rateScript.LedgerSize()))
	# forjar canal não cria balde novo nem poupa o agressor
	_clearProbe()
	for i in range(50):
		serverNode.call("TriggerChat", "RLimitB", "forja %d" % i, pidA)
	await create_timer(0.6).timeout
	CheckEq(_distinctDelivered(), 0, "R4 trocar o channelName (whisper forjado de B) não abre balde novo: A segue cortada no mesmo balde")

	# ------------------------------------------------------------------ R5: virou o balde
	print("-- R5) janela, não banimento")
	rateScript.SetClock(FIX_SEC + windowSec)
	_clearProbe()
	serverNode.call("TriggerChat", globalChannel, "depois da janela", pidA)
	await create_timer(0.6).timeout
	CheckEq(_distinctDelivered(), 1, "R5 o balde novo reabre a cota (1 linha entregue depois de A estar esgotada)")

	# ------------------------------------------------------- R6: os dois DelayInstant
	print("-- R6) SetMovePos / SetViewportSize: DelayInstant virou cota contável")
	rateScript.SetClock(FIX_SEC + windowSec * 2)
	var moveBudget : int = int(rateScript.BudgetFor("SetMovePos"))
	var viewBudget : int = int(rateScript.BudgetFor("SetViewportSize"))
	var t1 : int = Time.get_ticks_msec()
	for i in range(MOVE_FLOOD):
		serverNode.call("SetMovePos", Vector2.RIGHT, pidA)
	var moveMs : int = Time.get_ticks_msec() - t1
	CheckEq(int(rateScript.AllowedCount("SetMovePos")), moveBudget, "R6 SetMovePos: aceitas == cota (%d) de %d chamadas" % [moveBudget, MOVE_FLOOD])
	CheckEq(int(rateScript.RefusalCount("SetMovePos")), MOVE_FLOOD - moveBudget, "R6 SetMovePos: %d cortadas (%d ms de trabalho do servidor economizados)" % [MOVE_FLOOD - moveBudget, moveMs])
	for i in range(VIEW_FLOOD):
		serverNode.call("SetViewportSize", 640.0, 360.0, pidA)
	CheckEq(int(rateScript.AllowedCount("SetViewportSize")), viewBudget, "R6 SetViewportSize: aceitas == cota (%d)" % viewBudget)
	CheckEq(int(rateScript.RefusalCount("SetViewportSize")), VIEW_FLOOD - viewBudget, "R6 SetViewportSize: %d cortadas" % [VIEW_FLOOD - viewBudget])
	Check(int(rateScript.PrunePasses) > 0, "R6 a poda de balde rodou (PrunePasses=%d) — o ledger não é um segundo #85" % int(rateScript.PrunePasses))
	Check(int(rateScript.LedgerSize()) <= int(_const(rateScript, "MaxBuckets")), "R6 o ledger respeita o próprio teto (%d <= %d)" % [int(rateScript.LedgerSize()), int(_const(rateScript, "MaxBuckets"))])

	# ------------------------------------------------------- R7b: Forget solta o balde
	print("-- R7b) Forget: peerID reciclado não herda cota")
	rateScript.SetClock(FIX_SEC + windowSec * 3)
	for i in range(chatBudget + 2):
		serverNode.call("TriggerChat", globalChannel, "esquece %d" % i, pidA)
	var exhausted : int = int(rateScript.RefusalCount("TriggerChat"))
	var before : int = int(rateScript.LedgerSize())
	rateScript.Forget(pidA)
	var after : int = int(rateScript.LedgerSize())
	var forgotten : int = before - after
	print("  Forget(%d) tirou %d chaves | ledger %d -> %d" % [pidA, forgotten, before, after])
	Check(forgotten >= 1, "R7b Forget tira do ledger as chaves do peer que cai (tirou %d)" % forgotten)
	Check(after < before, "R7b o ledger encolheu com a queda da sessão (%d -> %d)" % [before, after])
	var allowedBefore : int = int(rateScript.AllowedCount("TriggerChat"))
	serverNode.call("TriggerChat", globalChannel, "novo dono do id", pidA)
	CheckEq(int(rateScript.AllowedCount("TriggerChat")), allowedBefore + 1, "R7b o próximo dono do peerID começa com cota inteira (não herda o esgotamento do antecessor: refusals em %d)" % exhausted)

	rateScript.SetClock(0)
	rateScript.Reset()
	_finish(0)

# ------------------------------------------------------------------------------ fixtures
func _openSession(accountID : int, charID : int) -> int:
	var candidate : int = PEER_BASE + accountID
	while bool(peersScript.HasPeer(candidate)):
		candidate += 1
	# A sessão entra pelo funil real de conexão, não por `Peers.AddPeer` direto:
	# `Network.Bulk` rota para `ENetServer` todo peer que não está marcado WebRTC/WebSocket
	# (sources/network/Network.gd:@Bulk), e `NetInterface.Bulk` faz get em `bulks[peerID]`
	# (sources/network/Interface.gd:@Bulk). A linha dessa tabela só `ConnectPeer` escreve
	# (sources/network/server/Server.gd:@ConnectPeer), e o boot offline auto-conecta a sua
	# (sources/network/server/Server.gd:1890) — na produção ela portanto sempre existe, e
	# só um registro fora do funil a pula. Medido em 2026-09-29: com `AddPeer` puro o run
	# teve 145 "Out of bounds get index" e ficou vermelho por SCRIPT ERROR com 72 checks
	# verdes: o portão não aceita SCRIPT ERROR mesmo quando nenhum check falha.
	serverNode.call("ConnectPeer", candidate)
	var peer : Object = peersScript.GetPeer(candidate)
	if peer == null:
		return 0
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(peersScript.accounts as Dictionary)[accountID] = candidate
	sessionPeers.append(candidate)
	return candidate

func _makeProbe() -> Node:
	var script : GDScript = GDScript.new()
	script.source_code = PROBE_SOURCE
	if int(script.reload()) != 0:
		print("FATAL: probe de cliente não compilou")
		return null
	var node : Node = script.new(false, false, true, true) as Node
	if node == null:
		return null
	node.set_name("RpcReceiveBudgetProbe")
	return node

func _clearProbe() -> void:
	if probe == null or not is_instance_valid(probe):
		return
	(probe.get("inbox") as Array).clear()
	(probe.get("delivered") as Dictionary).clear()

func _distinctDelivered() -> int:
	if probe == null or not is_instance_valid(probe):
		return -1
	return (probe.get("delivered") as Dictionary).size()

func _spawnAgent(charID : int, nickname : String) -> Node:
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var zone : Object = farmScript.GetZone(1)
	if zone == null:
		print("  [spawn bail] FarmZoneData.GetZone(1) = null")
		return null
	var map : Object = launcher.get("World").call("GetMap", int(zone.get("mapID")))
	if map == null:
		print("  [spawn bail] World.GetMap(%d) = null" % int(zone.get("mapID")))
		return null
	var policy : GDScript = load("res://sources/idle/IdlePolicyService.gd")
	var instID : int = int(policy.GetFarmInstanceID(1))
	var instances : Dictionary = map.get("instances")
	# O segundo agente entra na MESMA instância. Esquentar a zona de novo chama
	# `CreateInstance` outra vez, e ela apenas troca a entrada da tabela por um
	# `WorldInstance` novo (sources/world/WorldMap.gd:40): a instância onde o primeiro
	# agente está fica órfã, e o `agentA` que o check seguinte consulta passa a ser um
	# objeto liberado — que em GDScript é `== null`, sem nenhuma linha de diagnóstico.
	# Reproduzido 2/2 em 2026-09-29 no estado pré-correção: 49 checks, perna falsa, e
	# NENHUM SCRIPT ERROR no run — este defeito é independente do do `bulks` acima.
	if not instances.has(instID):
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
		print("  [spawn bail] zona 1 não esquentou: instance=%s navIter=%d em 200 quadros" % [str(policy.GetFarmInstance(1) != null), int(NavigationServer2D.map_get_iteration_id(map.get("mapRID")))])
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
		print("  [spawn bail] WorldAgent.CreateAgent(inst=%d, nick=%s) = null" % [instID, nickname])
		return null
	agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
	spawnedAgents.append(agent)
	return agent

func _janitor() -> void:
	if sql == null:
		return
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ? OR nickname = ?;", ["RLimitA", "RLimitB"])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ? OR username = ?;", ["rlimit_a", "rlimit_b"])

func _finish(code : int) -> void:
	if network != null and originalClient != null:
		network.set("Client", originalClient)
		originalClient = null
	if probe != null and is_instance_valid(probe):
		if probe.get_parent() != null:
			probe.get_parent().remove_child(probe)
		probe.free()
	probe = null
	if serverNode != null and peersScript != null:
		# Simetria com a porta de entrada: as sessões entraram por `ConnectPeer`, que escreve a
		# linha de `bulks` (sources/network/server/Server.gd:1807). Soltá-las por
		# `DisconnectPeer` é o que a apaga (`bulks.erase` em
		# sources/network/server/Server.gd:@DisconnectPeer), e o `FullyDisconnect` que ele chama solta o
		# balde (`RateLimit.Forget` em sources/network/server/Server.gd:1989) e tira o agente do
		# mundo (`WorldAgent.RemoveAgent` em sources/network/server/Server.gd:690) — antes de
		# qualquer `queue_free`, para que quem remova o agente seja o caminho real, não o
		# escombro.
		for pid in (peersScript.peers as Dictionary).keys():
			if int(pid) >= PEER_BASE:
				serverNode.call("DisconnectPeer", int(pid))
	for agent in spawnedAgents:
		# O `as Node` numa referência já liberada é o "SCRIPT ERROR: Trying to cast a
		# freed object" que fecha o gate §24-8 antes de qualquer check — medido no gate
		# de 2026-09-29, onde o `_finish` da rota de aborto esfolou exatamente aqui e o
		# run inteiro morreu em `exit=124`. Valida antes de converter, sempre.
		if agent == null or not is_instance_valid(agent):
			continue
		var node : Node = agent as Node
		if node != null:
			node.queue_free()
	if sql != null:
		_janitor()
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	waitingForBoot = true
	bootStartMs = int(Time.get_ticks_msec())
	bootDeadlineMs = bootStartMs + DB_BOOT_BUDGET_MS
	if code != 0:
		print("== RPC RECEIVE BUDGET: %d checks, %d failures ==" % [checks, failures])
		quit(code)

func _process(_delta):
	frames += 1
	if not waitingForBoot:
		return false
	if dbScript != null and bool(dbScript.get("isInitialized")):
		Check(true, "boot do DB fechado antes do quit (%d ms, %d frames)" % [int(Time.get_ticks_msec()) - bootStartMs, frames])
	elif int(Time.get_ticks_msec()) >= bootDeadlineMs:
		Check(false, "DB.isInitialized seguiu false por %d ms: o veredito seria lido no meio do preload" % DB_BOOT_BUDGET_MS)
	else:
		return false
	if dbScript != null:
		dbScript.call("DrainPendingPreloads")
	print("== RPC RECEIVE BUDGET: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
	return true
