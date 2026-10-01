extends SceneTree

# admission_gate_test.gd — harness da PORTA DE ENTRADA do servidor e da cerca do
# God Mode (auditoria de 2026-09-28, três buracos no mesmo ponto).
#
# Uso:    ./scripts/test.sh fixation   (descoberto pelo glob `tests/*_test.gd`)
# Saída:  "== ADMISSION: <n> checks, <m> failures =="   (exit code = <m>)
#
# O que ele apura, na ordem:
#   S1 TETO ÚNICO — os dois transportes abertos pelo mesmo caminho (`Admission.
#     OpenTransport`) e o número que CADA UM efetivamente aplicado comparado com o
#     accessor vivo. ENet recebe o teto no `create_server`; o WebSocket recebe o
#     endereço de bind no slot 2 (a API do motor não expõe contagem de clientes) e
#     carrega o teto na porta de entrada. A comparação é entre os dois números
#     observados, com uma cópia mutada em memória provando que a régua não é tautologia.
#   S2 ORÇAMENTO PRÉ-AUTH — janela com relógio injetado (`ClockOverride`, o seam do
#     repo): cota por endereço, balde que rola na fronteira exata, endereço vizinho
#     intacto, contador e reason próprios. Nenhum `Time` real é lido, então nada aqui
#     flutua com o relógio da máquina.
#   S3 TRANSPORTE REAL — sockets WebSocket de verdade contra o gate real: abrir
#     N+1 conexões e RECEBER recusa. A contagem vem dos contadores do gate
#     (`Attempts`/`Admissions`/`Refusals`) e do byte que o client lê, nunca do log.
#     Inclui o recuso do ceiling pelo mesmo caminho, porque é exatamente ali que o
#     web entrava sem teto nenhum, e a perna do schema parado depois dele (o motivo
#     tem que vir ANTES do teto no socket real, não só na função pura).
#   S4 GOD MODE — assert de máquina: varre `deploy/**` (composes, Dockerfiles,
#     runbooks, COOLIFY.md) e `.github/**` e reprova se o nome da env do GM aparece.
#     O controle negativo é em memória (arquivo de deploy inventado, nada escrito no
#     disco do repo), e a régua é conferida contra o `.env.example`, onde o nome tem
#     que continuar existindo com o motivo e o "nunca em produção" escritos.
#   S5 ESQUEMA PARADO — a quarta razão da porta: migração que estoura no boot fechava
#     nada, o cliente autenticava e morria na primeira RPC sem tabela. Confere a função
#     pura de estado (`SQL.MigrationBlockedState`, três entradas, cada uma capaz de
#     sozinha virar o veredito), a superfície de saúde (`MetricsServer.ServingFor`), a
#     precedência sobre o teto, o contador próprio, a compatibilidade da assinatura
#     antiga e a fiação viva em `Server._ValidateAuth`. O S3 percorre o mesmo flag por
#     socket de verdade, depois do teto.
#
# Como os outros harnesses de `-s`: nada de identificador global (`Admission`,
# `NetworkCommons`, `Peers`…) em tempo de compilação — tudo via load()/call()/const map.

const AdmissionPath : String			= "res://sources/network/server/Admission.gd"
const ServerPath : String				= "res://sources/network/server/Server.gd"
const CommonsPath : String				= "res://sources/network/NetworkCommons.gd"
const CommandManagerPath : String		= "res://sources/debug/CommandManager.gd"
const EnvTemplatePath : String			= "res://.env.example"
const SQLPath : String					= "res://sources/sql/SQL.gd"
const MetricsPath : String				= "res://sources/system/MetricsServer.gd"

# Os lugares onde a env do God Mode NUNCA pode aparecer, e o nome que ela carrega.
const GMScanRoots : PackedStringArray	= ["res://deploy", "res://.github"]
const GMEnvToken : String				= "SHAMBLETA_GM_MODE"
# Arquivos que têm que estar dentro da varredura — sem isso, um walk que não andou
# nada também devolveria "zero violações".
const GMRequiredFiles : PackedStringArray = [
	"res://deploy/docker-compose.yml",
	"res://deploy/docker-compose.staging.yml",
	"res://deploy/server/Dockerfile",
	"res://deploy/COOLIFY.md",
	"res://.github/workflows/godot-ci.yml",
]

# Porta própria: dividir a 6118 com `run_rpc_identity_test` mistura os dois runs no
# mesmo listener (os gates de harnesses diferentes rodam em paralelo).
const TestPortStart : int				= 6121
const TestPortTries : int				= 12

# Cota sintética do S3: pequena para a prova pontual custar 5 conexões, não 33. O
# VALOR de produção é o que S2/S1 conferem, não o que S3 usa.
const SocketBudget : int				= 3
# Âncora do relógio injetado. `baseClock` é a âncora ALINHADA ao balde de
# `PreAuthWindowSec`: sem o alinhamento a "fronteira da janela" cairia no meio de
# um balde e a prova dos dois lados da borda mentiria (o balde rola sozinho).
const ClockAnchor : int					= 1_700_000_000
var baseClock : int						= 0

var checks : int = 0
var failures : int = 0

var adm : GDScript = null
var commons : GDScript = null
# Boot do catálogo: `_dbScript` é o script lido em runtime (nada de nome global —
# ver o bloco em `_initialize`) e `_bootReady` só acende depois que as suites
# síncronas rodaram, porque `_process` já gira enquanto o `await` do boot espera.
var _dbScript : GDScript = null
var _bootReady : bool = false
var reasons : Dictionary = {}
var ceiling : int = 0
var perAddress : int = 0
var windowSec : int = 0
var protocol : int = 0

# Estado do S3 (transporte real, máquina de estados por frame).
var frames : int = 0
var step : int = 0
var srvApi : SceneMultiplayer = null
var srvPeer : WebSocketMultiplayerPeer = null
var gate : Object = null
var clientNodes : Array = []
var clientApis : Array = []
var clientSeen : Array = []
var boundPort : int = -1
# Perna do S3 que reproduz o boot com migração parada: o flag que `Server._ValidateAuth`
# lê de `SQL.MigrationBlocked()`, aqui ligado à mão para o socket contar a recusa.
var schemaBlockedNow : bool = false

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if condition:
		print("  [ok] " + label)
	else:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _const(script : GDScript, name : String) -> Variant:
	return script.get_script_constant_map().get(name, null)

# `ProtocolVersion` é `static var` (hash do config RPC, escrito no `_ready` do
# autoload `Network`), então não vive no constant map. Lê o valor vivo pelo script e,
# se a leitura não vier, cai no MESMO cálculo que o produto faz.
func _LiveProtocol() -> int:
	var read : Variant = commons.get("ProtocolVersion")
	if read != null and int(read) != 0:
		return int(read)
	var net : Node = root.get_node_or_null(^"Network")
	if net != null:
		var computed : Variant = commons.call("ComputeProtocolVersion", net)
		if computed != null and int(computed) != 0:
			return int(computed)
	return int(read) if read != null else 0

# Fixa a versão que o gate lê, para as suites sem socket dependerem de um número
# nosso em vez do hash do momento.
func _PinProtocol(value : int) -> bool:
	commons.set("ProtocolVersion", value)
	var read : Variant = commons.get("ProtocolVersion")
	return read != null and int(read) == value

# O trabalho acontece em `_initialize()`, não em `_init`: no construtor a árvore
# ainda não tem os autoload (`Network`, `Launcher`), então todo script que os cita
# por nome falha a compilar aqui dentro (`Identifier not found`) — mesma razão pela
# qual `tests/deploy_ops_test.gd` e os outros harnesses de `-s` começam no callback
# do motor. O S3 continua em `_process` porque precisa de poll de socket real.
func _initialize() -> void:
	adm = load(AdmissionPath) as GDScript
	commons = load(CommonsPath) as GDScript
	if adm == null or commons == null:
		print("FATAL: Admission/NetworkCommons não carregaram")
		quit(1)
		return
	# O catálogo de conteúdo NÃO sobe junto com o boot dos autoloads: `DB.Preload()`
	# empilha os `load_threaded_request` de `Preload` (`sources/db/DB.gd:@Preload`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Este harness não esperava por nada:
	# rodava as suites e caía no `quit()` com o catálogo pelo caminho, então o MESMO
	# run valia ~30 objetos aqui e ~1700 num runner mais lento (mesma classe da régua
	# de wall-clock). O check nomeado é o ponto — boot leve é vermelho visível, não
	# medição parcial silenciosa. Padrão de tests/content_hygiene_test.gd.
	_dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 80:
		if _dbScript != null and bool(_dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "DB initialized (entities/maps/items carregados)"):
		_finish()
		return
	reasons = {
		"admitted": _const(adm, "ReasonAdmitted"),
		"ceiling": _const(adm, "ReasonCeiling"),
		"protocol": _const(adm, "ReasonProtocol"),
		"budget": _const(adm, "ReasonAddressBudget"),
		"schema": _const(adm, "ReasonSchema"),
		"unresolved": _const(adm, "UnresolvedAddress"),
	}
	ceiling = int(commons.call("ConnectionCeiling"))
	perAddress = int(_const(commons, "PreAuthPerAddress"))
	windowSec = int(_const(commons, "PreAuthWindowSec"))
	protocol = _LiveProtocol()
	var pinnedOnFirst : bool = _PinProtocol(9021)
	var pinnedBack : int = _LiveProtocol()
	Check(pinnedOnFirst and pinnedBack == 9021,
		"o harness consegue fixar a versão de protocolo que o gate lê (pin=%s, vivo=%d)" % [str(pinnedOnFirst), pinnedBack])
	if pinnedOnFirst:
		protocol = 9021
	baseClock = int(ClockAnchor / maxi(windowSec, 1)) * maxi(windowSec, 1)

	_SuiteCeilingUnico()
	_SuiteOrcamentoPreAuth()
	_SuiteGodModeGate()
	_SuiteSchemaDoor()
	# S3 precisa de frames (poll de socket de verdade); roda em `_process`.
	# A liberação vem SÓ aqui: `_process` começa a girar no instante em que
	# `_initialize()` suspende no `await` do boot, e sem esta guarda o S3 abriria o
	# socket antes das suites acima — e `frames` contaria os frames da espera,
	# estourando o timeout da própria máquina de estados num boot lento.
	_bootReady = true

# --- S1 — um teto, dois transportes, mesma leitura -------------------------

# Transporte falso que REGISTRA o que recebeu: é a única forma de comparar o número
# que o ENet ganhou com o número que o WebSocket vai cobrar.
class FakeHost:
	extends RefCounted
	var setups : int = 0
	func dtls_server_setup(_tls):
		setups += 1
		return 0

class FakePeer:
	extends RefCounted
	var calls : Array = []
	var host : FakeHost = FakeHost.new()
	func create_server(port, second, tls = null) -> int:
		calls.append([port, second, tls])
		return 0

func _SuiteCeilingUnico():
	print("== S1 teto único dos dois transportes ==")
	var wsPeer : FakePeer = FakePeer.new()
	var enetPeer : FakePeer = FakePeer.new()
	var wsGate : Object = adm.call("OpenTransport", wsPeer, true, 6108, null)
	var enetGate : Object = adm.call("OpenTransport", enetPeer, false, 6109, null)
	Check(wsGate != null and enetGate != null, "OpenTransport devolve o gate dos dois lados")
	Check(wsPeer.calls.size() == 1 and enetPeer.calls.size() == 1,
		"cada transporte deu exatamente um create_server")

	var wsApplied : int = int(wsGate.get("Ceiling"))
	var enetApplied : int = int(enetGate.get("Ceiling"))
	# O que o ENet recebeu no argumento de clientes, e o que o WS leva para a porta.
	var enetArg : Variant = enetPeer.calls[0][1]
	var wsArg : Variant = wsPeer.calls[0][1]
	Check(int(enetArg) == ceiling,
		"ENet recebeu o teto do accessor no create_server (%s != %d)" % [str(enetArg), ceiling])
	Check(str(wsArg) == "*",
		"o slot 2 do create_server do WebSocket é o endereço de bind, não um teto (%s)" % str(wsArg))
	Check(wsApplied == enetApplied,
		"os DOIS transportes aplicam o MESMO número (%d vs %d)" % [wsApplied, enetApplied])
	Check(wsApplied == ceiling and enetApplied == ceiling,
		"o número dos dois é NetworkCommons.ConnectionCeiling() = %d" % ceiling)
	# Controle negativo: a comparação acima não é tautologia — um teto divergente é pego.
	var mutated : int = wsApplied + 1
	Check(not (mutated == enetApplied),
		"cópia mutada do teto (%d) NÃO bate com o número aplicado — a régua morde" % mutated)
	Check(int(wsGate.get("BindError")) == OK and int(enetGate.get("BindError")) == OK,
		"o bind dos dois transportes foi chamado sem erro sintético")

	# O ceiling cobrado na porta, no número real do produto: N sessões entram, N+1 não.
	var budgetless : Object = adm.new()
	budgetless.set("Ceiling", ceiling)
	budgetless.set("PerAddress", ceiling * 100)
	budgetless.set("WindowSec", windowSec)
	var atCeiling : String = String(budgetless.call("Verdict", "10.0.0.1", ceiling, protocol, baseClock))
	var overCeiling : String = String(budgetless.call("Verdict", "10.0.0.2", ceiling + 1, protocol, baseClock))
	Check(atCeiling == String(reasons["admitted"]),
		"na casa do teto (%d sessões vivas) a porta ainda autentica" % ceiling)
	Check(overCeiling == String(reasons["ceiling"]),
		"uma sessão acima do teto é recusada com o reason do teto, não em silêncio")

	# Fiação no Server.gd: o bind único e a delegação do auth. Sem `complete_auth`
	# solto no servidor, a porta é o único caminho para virar sessão.
	var srvBinds : Array = _CallLines(ServerPath, "create_server")
	Check(srvBinds.size() == 1 and String(srvBinds[0]).contains("RtcMultiplayerPeer"),
		"Server.gd não abre mais o transporte dos jogadores por conta própria (sobrou: %s)" % str(srvBinds))
	Check(_CallLines(ServerPath, "complete_auth").is_empty(),
		"complete_auth não acontece mais fora do gate (Server.gd é só chamado)")
	var srvSrc : String = _read(ServerPath)
	Check(srvSrc.contains("Admission.OpenTransport("), "Server.gd abre os dois transportes pelo mesmo caminho")
	Check(srvSrc.contains("admission.CheckAuth("), "Server.gd delega o handshake ao gate")
	Check(srvSrc.contains("multiplayerAPI.auth_callback = _ValidateAuth"),
		"a porta continua pendurada no auth_callback do motor, não num hook opcional")
	var gateBinds : Array = _CallLines(AdmissionPath, "create_server")
	Check(gateBinds.size() == 2,
		"exatamente dois create_server na árvore da porta (um por transporte): %d" % gateBinds.size())
	var commonsSrc : String = _read(CommonsPath)
	Check(commonsSrc.count("MaxPlayerCount") == 2,
		"o teto é declarado uma vez e lido por um accessor, sem segundo leitor: %d" % commonsSrc.count("MaxPlayerCount"))
	Check(commonsSrc.contains("static func ConnectionCeiling() -> int:"),
		"o leitor único existe como função, não como duas leituras da constante")

# --- S2 — orçamento pré-auth por endereço, relógio injetado ----------------

func _newGate(budget : int, cap : int) -> Object:
	var g : Object = adm.new()
	g.set("Ceiling", cap)
	g.set("PerAddress", budget)
	g.set("WindowSec", windowSec)
	g.set("ClockOverride", baseClock)
	return g

func _SuiteOrcamentoPreAuth():
	print("== S2 orcamento pre-auth por endereco ==")
	Check(perAddress > 0 and windowSec > 0,
		"a cota e a janela existem e são positivas (%d em %ds)" % [perAddress, windowSec])

	# A cota é a régua: o teto é elevado de propósito para não atrapalhar.
	var cap : int = ceiling * 100
	var g : Object = _newGate(perAddress, cap)
	var admitted : int = 0
	for i in range(perAddress):
		if String(g.call("Verdict", "203.0.113.9", 1, protocol, baseClock + i)) == String(reasons["admitted"]):
			admitted += 1
	Check(admitted == perAddress,
		"as primeiras %d tentativas do endereço entram todas (admitted=%d)" % [perAddress, admitted])
	var refused : String = String(g.call("Verdict", "203.0.113.9", 1, protocol, baseClock + perAddress))
	Check(refused == String(reasons["budget"]),
		"a tentativa %d do MESMO endereço é recusada antes de autenticar" % (perAddress + 1))
	Check(int(g.call("RefusalCount", reasons["budget"])) == 1,
		"o contador do reason próprio marcou exatamente 1 recusa por orçamento")
	Check(int(g.get("Attempts")) == perAddress + 1 and int(g.get("Admissions")) == perAddress,
		"tentativas e admissões contadas à parte do motivo (%d tentativas)" % int(g.get("Attempts")))
	Check(int(g.call("AttemptsFor", "203.0.113.9")) == perAddress + 1,
		"o balde é por endereço, com a contagem cheia do endereço")
	Check(String(g.call("Verdict", "198.51.100.4", 1, protocol, baseClock)) == String(reasons["admitted"]),
		"endereço vizinho não paga pelo spray (cada um tem o próprio balde)")

	# Fronteira da janela, nos dois lados, no relógio injetado.
	var lastOfWindow : int = baseClock + (windowSec - 1)
	Check(String(g.call("Verdict", "203.0.113.9", 1, protocol, lastOfWindow)) == String(reasons["budget"]),
		"um segundo antes do balde virar a recusa continua (%d s)" % (windowSec - 1))
	var nextWindow : int = baseClock + windowSec
	Check(String(g.call("Verdict", "203.0.113.9", 1, protocol, nextWindow)) == String(reasons["admitted"]),
		"no segundo em que o balde rola o endereço volta a autenticar")
	Check(int(g.call("AttemptsFor", "203.0.113.9")) == 1,
		"o balde novo recomeça em 1, não acumula a janela anterior")

	# Recusa não é só motivo: protocolo errado também tem reason, e conta tentativa.
	var badProto : String = String(g.call("Verdict", "203.0.113.33", 1, protocol + 1, nextWindow))
	Check(badProto == String(reasons["protocol"]), "handshake com protocolo errado sai com reason próprio")
	Check(int(g.call("RefusalCount", reasons["protocol"])) == 1,
		"o motivo do protocolo tem o próprio contador (não divide com o orçamento)")
	var shortPacket : Object = _newGate(1, cap)
	Check(String(shortPacket.call("Verdict", "203.0.113.50", 1, -1, baseClock)) == String(reasons["protocol"]),
		"pacote de auth curto é protocol_mismatch, não crack de decode")

	# Atrás do proxy reverso todo mundo chega com o endereço do proxy: a cota sobe
	# para o teto (senão é auto-DoS da casa inteira) e continua sendo UM número.
	Check(int(adm.call("BudgetFor", false, ceiling)) == perAddress,
		"bind direto cobra a cota por endereço (%d)" % perAddress)
	Check(int(adm.call("BudgetFor", true, ceiling)) == ceiling,
		"atrás do proxy a cota por endereço é o teto de conexões (%d)" % ceiling)
	var proxyGate : Object = _newGate(int(adm.call("BudgetFor", true, ceiling)), ceiling)
	Check(int(proxyGate.get("PerAddress")) == ceiling,
		"a cota aplicada no gate do proxy é o teto, não um número solto")
	Check(not String(reasons["unresolved"]).is_empty(),
		"endereço não resolvido cai em balde compartilhado (fail-closed em volume)")

# --- S3 — transporte real: N+1 conexões, recusa contada --------------------

func _process(_delta):
	# Nada de máquina de estados antes do boot fechar (ver `_initialize`): o
	# contador `frames` é o relógio dos timeouts do S3, e contaria a espera do
	# catálogo se esta guarda não existisse.
	if not _bootReady:
		return false
	frames += 1
	if srvApi != null:
		srvApi.poll()
	for api in clientApis:
		api.poll()
	match step:
		0:
			if frames < 4:
				return false
			_StartRealServer()
			return false
		1:
			if int(gate.get("Attempts")) < SocketBudget + 1:
				if frames > 900:
					Check(false, "S3: o gate nunca viu os handshakes reais (tentativas=%d)" % int(gate.get("Attempts")))
					_TeardownReal()
					return _finish()
				return false
			_AssertRealRefusals()
			_RollWindow()
			step = 2
			return false
		2:
			if int(gate.get("Attempts")) < SocketBudget + 2:
				if frames > 1500:
					Check(false, "S3: a tentativa pós-janela não chegou ao gate")
					_TeardownReal()
					return _finish()
				return false
			_AssertRolledWindow()
			_PushCeiling()
			step = 3
			return false
		3:
			if int(gate.get("Attempts")) < SocketBudget + 3:
				if frames > 2100:
					Check(false, "S3: a tentativa do ceiling não chegou ao gate")
					_TeardownReal()
					return _finish()
				return false
			_AssertCeilingRefused()
			_PushSchema()
			step = 4
			return false
		4:
			if int(gate.get("Attempts")) < SocketBudget + 4:
				if frames > 2700:
					Check(false, "S3: a tentativa com o schema parado não chegou ao gate")
					_TeardownReal()
					return _finish()
				return false
			_AssertSchemaRefused()
			_TeardownReal()
			return _finish()
		_:
			# Sem transporte bindado (toda porta ocupada) o run fecha com o failure
			# já registrado, em vez de girar até estourar o timeout do gate.
			_TeardownReal()
			return _finish()
	return false

func _StartRealServer():
	print("== S3 websocket real: N+1 conexoes ==")
	# O bind é FEITO PELO GATE (mesmo caminho do produto): uma porta por tentativa,
	# o `BindError` de `OpenTransport` é o que diz se a porta ficou livre.
	for i in range(TestPortTries):
		var peer : WebSocketMultiplayerPeer = WebSocketMultiplayerPeer.new()
		var candidate : Object = adm.call("OpenTransport", peer, true, TestPortStart + i, null)
		if int(candidate.get("BindError")) == OK:
			srvPeer = peer
			gate = candidate
			boundPort = TestPortStart + i
			break
	Check(boundPort > 0, "websocket real subiu numa porta livre pela porta de entrada (%d)" % boundPort)
	if boundPort <= 0:
		step = 9
		return
	srvApi = MultiplayerAPI.create_default_interface() as SceneMultiplayer
	srvApi.auth_timeout = 3.0
	# A porta pendurada no auth_callback, exatamente como Server.gd faz. Sem isso o
	# motor aceitaria todos os handshakes e o teste não pegaria nada.
	srvApi.auth_callback = _ServerAuthViaGate
	srvApi.set_root_path(root.get_path())
	srvApi.set_multiplayer_peer(srvPeer)
	Check(int(gate.get("Ceiling")) == ceiling,
		"o gate aberto sobre o transporte real carrega o teto do produto (%d)" % ceiling)
	gate.set("PerAddress", SocketBudget)
	gate.set("ClockOverride", baseClock)
	Check(int(gate.call("LiveSessions", srvApi)) == 0,
		"sem client conectado o transporte reporta zero sessões vivas")
	# `ProtocolVersion` é uma `static var` calculada no `_ready` do autoload `Network`,
	# não um literal: o client tem que mandar o valor VIVO, senão tudo morre em
	# protocol_mismatch e a recusa do orçamento nunca aparece.
	protocol = _LiveProtocol()
	for i in range(SocketBudget + 1):
		_AddClient()
	step = 1

func _ServerAuthViaGate(peerID : int, data : PackedByteArray) -> void:
	# Exatamente o que `Server._ValidateAuth` faz: delegar a decisão inteira à porta,
	# com o flag do schema vindo do mesmo estado que o produto lê.
	gate.call("CheckAuth", srvApi, srvPeer, peerID, data, schemaBlockedNow)

func _AddClient():
	# O índice (um `int`) é o que vai no `bind`, nunca a `api`: bindar a própria API
	# no callback dela cria ciclo de referência que vaza no fim do run.
	var idx : int = clientApis.size()
	var node : Node = Node.new()
	node.name = "cli%d" % idx
	root.add_child(node)
	var peer : WebSocketMultiplayerPeer = WebSocketMultiplayerPeer.new()
	peer.create_client("ws://127.0.0.1:%d" % boundPort)
	var api : SceneMultiplayer = MultiplayerAPI.create_default_interface() as SceneMultiplayer
	api.set_root_path(node.get_path())
	api.peer_authenticating.connect(_ClientSendsProtocol.bind(idx))
	api.auth_callback = _ClientReadsVerdict.bind(idx)
	api.set_multiplayer_peer(peer)
	clientNodes.append(node)
	clientApis.append(api)
	clientSeen.append(-1)

func _ClientSendsProtocol(peerID : int, idx : int) -> void:
	var api : SceneMultiplayer = clientApis[idx] as SceneMultiplayer
	var authData : PackedByteArray = PackedByteArray()
	authData.resize(8)
	authData.encode_s64(0, protocol)
	api.send_auth(peerID, authData)

func _ClientReadsVerdict(peerID : int, data : PackedByteArray, idx : int) -> void:
	if idx < clientSeen.size() and data.size() >= 1:
		clientSeen[idx] = int(data[0])
	# O client real só vira sessão depois do OK do servidor — exatamente o que o
	# gate decide; `[0]` nunca é completado.
	if data.size() >= 1 and int(data[0]) == 1:
		var api : SceneMultiplayer = clientApis[idx] as SceneMultiplayer
		api.complete_auth(peerID)

func _AssertRealRefusals():
	Check(int(gate.get("Attempts")) >= SocketBudget + 1,
		"os %d handshakes reais chegaram ao gate (tentativas=%d)" % [SocketBudget + 1, int(gate.get("Attempts"))])
	Check(int(gate.get("Admissions")) == SocketBudget,
		"só as %d primeiras conexões reais autenticaram (admitidas=%d)" % [SocketBudget, int(gate.get("Admissions"))])
	Check(int(gate.call("RefusalCount", reasons["budget"])) == 1,
		"a recusa do orçamento foi CONTADA no gate, não lida de log")
	Check(not (gate.get("windows") as Dictionary).has(String(reasons["unresolved"])),
		"nenhum endereço ficou não resolvido no transporte WebSocket real")
	Check(int(gate.call("AttemptsFor", "127.0.0.1")) >= SocketBudget + 1,
		"as tentativas caíram no balde do endereço real do peer")
	Check(int(clientSeen[SocketBudget]) == 0,
		"a conexão N+1 recebeu recusa explícita no auth (byte 0), não timeout")
	Check(int(clientSeen[0]) == 1, "a primeira conexão real recebeu OK (byte 1)")
	Check(srvApi.get_peers().size() == SocketBudget,
		"o transporte tem exatamente %d sessões autenticadas" % SocketBudget)

func _RollWindow():
	# Relógio injetado: a janela vira sem esperar 60 s de parede.
	gate.set("ClockOverride", baseClock + windowSec)
	_AddClient()

func _AssertRolledWindow():
	Check(int(gate.get("Admissions")) == SocketBudget + 1,
		"passada a janela o mesmo endereço volta a autenticar (admitidas=%d)" % int(gate.get("Admissions")))
	Check(int(clientSeen[SocketBudget + 1]) == 1,
		"a conexão nova, depois da janela, entrou de verdade")

func _PushCeiling():
	# O teto cobrado no WebSocket — o transporte que não tinha nenhum. Ceiling é
	# rebaixado para as sessões vivas: a próxima passa de N e tem que ser recusada.
	var live : int = int(gate.call("LiveSessions", srvApi))
	gate.set("ClockOverride", baseClock + windowSec * 2)
	gate.set("Ceiling", live)
	_AddClient()

func _AssertCeilingRefused():
	Check(int(gate.call("RefusalCount", reasons["ceiling"])) == 1,
		"a sessão acima do teto foi recusada com o reason do teto")
	Check(int(clientSeen[clientSeen.size() - 1]) == 0,
		"o client real leu a recusa do ceiling no auth (byte 0)")
	Check(srvApi.get_peers().size() == int(gate.get("Admissions")),
		"sessão no transporte é sempre exatamente o que a porta admitiu (%d vs %d)" % [srvApi.get_peers().size(), int(gate.get("Admissions"))])
	Check(int(gate.get("Admissions")) == SocketBudget + 1,
		"o ceiling não admitiu ninguém de novo (admitidas=%d)" % int(gate.get("Admissions")))

func _PushSchema():
	# O mesmo endereço, com o flag que o boot parado acende. O teto continua estourado
	# de propósito: o que se prova no socket é a PRECEDÊNCIA, não só o motivo.
	gate.set("ClockOverride", baseClock + windowSec * 3)
	schemaBlockedNow = true
	_AddClient()

func _AssertSchemaRefused():
	Check(int(gate.call("RefusalCount", reasons["schema"])) == 1,
		"a recusa do schema parado foi CONTADA no gate, sobre socket real")
	Check(int(gate.call("RefusalCount", reasons["ceiling"])) == 1,
		"o ceiling não ganhou recusa nova: com o schema ligado a mesma casa cai no motivo do teto (%d)" % int(gate.call("RefusalCount", reasons["ceiling"])))
	Check(int(clientSeen[clientSeen.size() - 1]) == 0,
		"o client real leu recusa (byte 0) com o schema parado, em vez de virar sessão quebrada")
	Check(srvApi.get_peers().size() == SocketBudget + 1,
		"nenhuma sessão nova entrou com o schema parado (%d no transporte)" % srvApi.get_peers().size())
	Check(int(gate.get("Admissions")) == SocketBudget + 1,
		"a porta parada não admitiu ninguém (%d admitidas)" % int(gate.get("Admissions")))

func _TeardownReal():
	schemaBlockedNow = false
	for item in clientApis:
		var capi : SceneMultiplayer = item as SceneMultiplayer
		capi.auth_callback = Callable()
		capi.set_multiplayer_peer(null)
	for nodeItem in clientNodes:
		var node : Node = nodeItem as Node
		root.remove_child(node)
		node.free()
	if srvApi != null:
		srvApi.auth_callback = Callable()
		srvApi.set_multiplayer_peer(null)
	clientApis.clear()
	clientNodes.clear()
	srvApi = null
	srvPeer = null
	gate = null

func _finish():
	print("== ADMISSION: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
	return true

# --- S4 — God Mode nunca em produção (assert de máquina) -------------------

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text : String = f.get_as_text()
	f.close()
	return text

# Linhas de CÓDIGO (comentário fora) que citam `token`. As justificações dos arquivos
# cerados escrevem `create_server`/`complete_auth` em prosa de propósito: contar a
# prosa faria a régua medir documentação em vez de chamada.
func _CallLines(path : String, token : String) -> Array:
	var found : Array = []
	for line in String(_read(path)).split("\n"):
		var text : String = String(line).strip_edges()
		if text.is_empty() or text.begins_with("#"):
			continue
		if text.count(token) > 0:
			found.append(text)
	return found

# Varredura pura: recebe [(path, texto)] e devolve "arquivo:linha" de cada exposição.
# É função separada do walk de propósito — o controle negativo injeta deploy falso
# em memória sem escrever nada no disco do repo.
func _GMViolations(entries : Array) -> Array:
	var found : Array = []
	for entry in entries:
		var path : String = String(entry["path"])
		var lines : PackedStringArray = String(entry["text"]).split("\n")
		for i in range(lines.size()):
			if String(lines[i]).contains(GMEnvToken):
				found.append("%s:%d" % [path, i + 1])
	return found

func _CollectTree(dirPath : String, out : Array) -> void:
	var dir : DirAccess = DirAccess.open(dirPath)
	if dir == null:
		return
	dir.list_dir_begin()
	var name : String = dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full : String = dirPath.path_join(name)
			if dir.current_is_dir():
				_CollectTree(full, out)
			else:
				out.append({"path": full, "text": _read(full)})
		name = dir.get_next()
	dir.list_dir_end()

func _SuiteGodModeGate():
	print("== S4 god mode fora do deploy ==")
	var entries : Array = []
	for rootPath in GMScanRoots:
		_CollectTree(rootPath, entries)
	var paths : Array = []
	for entry in entries:
		paths.append(String(entry["path"]))
	Check(entries.size() >= 20, "a varredura achou arquivos de deploy/CI de verdade (%d)" % entries.size())
	var missing : int = 0
	for wanted in GMRequiredFiles:
		if not wanted in paths:
			missing += 1
	Check(missing == 0, "compose, Dockerfile, COOLIFY.md e o workflow estão todos na varredura (%d faltando)" % missing)

	var hits : Array = _GMViolations(entries)
	Check(hits.is_empty(),
		"nenhum arquivo de deploy ou job de CI expõe a env do God Mode (%s)" % str(hits))

	# Controle negativo: a mesma régua aplicada a deploy inventado EM MEMÓRIA. Cada
	# linha é uma forma real de a env chegar lá (compose, Dockerfile, env do job,
	# interpolação do compose, painel documentado no runbook).
	var fakes : Array = [
		{"path": "res://deploy/inventado-compose.yml", "text": "    environment:\n      - %s=1\n" % GMEnvToken},
		{"path": "res://deploy/inventado-Dockerfile", "text": "FROM x\nENV %s 1\n" % GMEnvToken},
		{"path": "res://.github/workflows/inventado.yml", "text": "    env:\n      %s: \"1\"\n" % GMEnvToken},
		{"path": "res://deploy/inventado-staging.yml", "text": "      - %s=${%s}\n" % [GMEnvToken, GMEnvToken]},
		{"path": "res://deploy/inventado-COOLIFY.md", "text": "No painel, adicione a variavel:\n\n%s=1\n" % GMEnvToken},
	]
	var fakeHits : Array = _GMViolations(fakes)
	Check(fakeHits.size() == fakes.size(),
		"deploy falso em memória é pego em cada uma das %d formas (%d achados)" % [fakes.size(), fakeHits.size()])
	Check(_GMViolations([{"path": "res://deploy/inventado-limpo.yml", "text": "services:\n  game:\n    environment:\n      - SHAMBLETA_PROXY_TLS=1\n"}]).is_empty(),
		"a régua não reprova qualquer environment: só a env do GM")

	# E o lugar onde o nome tem que continuar existindo: o template, com o motivo.
	var tpl : String = _read(EnvTemplatePath)
	Check(tpl.contains("\n%s=" % GMEnvToken),
		".env.example declara a env do GM (é o único lugar do repo onde ela pode viver)")
	var tplBlock : String = tpl.substr(0, tpl.find("\n%s=" % GMEnvToken) + 400)
	Check(tplBlock.to_lower().contains("nunca em produ") or tplBlock.to_lower().contains("never in production"),
		"o template escreve o nunca-em-producao junto do nome")
	Check(tplBlock.to_lower().contains("dev/staging") or tplBlock.to_lower().contains("comando"),
		"o template diz o que a env liga e onde ela é permitida")

	# A chave continua sendo a env nomeada, lida por um único caminho — sem isso a
	# varredura acima não estaria cerando nada.
	var cmd : String = _read(CommandManagerPath)
	Check(cmd.contains('const GM_MODE_ENV : String = "%s"' % GMEnvToken),
		"o nome cerado é exatamente o que o CommandManager declara")
	Check(cmd.contains("OS.get_environment(GM_MODE_ENV)") and cmd.contains("not GMModeEnabled() and command._permission"),
		"a env continua sendo a única alavanca do bypass de comando")
	var setters : int = cmd.count("set_environment")
	Check(setters == 0, "nada no módulo escreve a env que o libera (%d)" % setters)

# --- S5 — esquema parado: a porta fecha antes do teto -----------------------

# Corpo de função lido do texto-fonte: a régua de fiação precisa ver o que a função
# FAZ, não apenas que o nome dela existe em algum lugar do arquivo.
func _BodyOf(source : String, signature : String) -> String:
	var start : int = source.find(signature)
	if start < 0:
		return ""
	var rest : String = source.substr(start)
	var next : int = rest.find("\nfunc ", 1)
	return rest if next < 0 else rest.substr(0, next)

# Régua posicional PURA: o flag do schema tem que decidir antes do teto. Separada do
# assert para o controle negativo poder comer um corpo trocado em memória, sem escrever
# nada no disco do repo.
func _SchemaBeforeCeiling(body : String) -> bool:
	var schema : int = body.find("schemaBlocked")
	var cap : int = body.find("liveSessions > Ceiling")
	return schema >= 0 and cap >= 0 and schema < cap

func _Blocked(sql : GDScript, plan : String, patches : int, version : int) -> bool:
	return bool(sql.call("MigrationBlockedState", plan, patches, version))

func _SuiteSchemaDoor():
	print("== S5 schema parado fecha a porta ==")
	var schemaReason : Variant = reasons.get("schema", null)
	Check(schemaReason != null and String(schemaReason) == "schema_blocked",
		"o reason do schema existe e é estável (%s)" % str(schemaReason))
	var sql : GDScript = load(SQLPath) as GDScript
	var metrics : GDScript = load(MetricsPath) as GDScript
	if not Check(sql != null and metrics != null, "SQL.gd e MetricsServer.gd carregam no harness"):
		return

	# As quatro causas de boot parado, e as três entradas capazes cada uma de sozinha
	# virar o veredito — é o que prova que a função lê o estado, não um literal.
	var causes : Array = [["failed", 3, 3], ["empty", 0, 0], ["stale", 2, 5], ["uptodate", 5, 4]]
	var missed : String = ""
	for row in causes:
		if not _Blocked(sql, String(row[0]), int(row[1]), int(row[2])):
			missed += str(row) + " "
	Check(missed.is_empty(), "as %d causas de esquema parado bloqueiam (%s)" % [causes.size(), missed.strip_edges()])
	Check(not _Blocked(sql, "uptodate", 4, 4), "esquema no ponto abre a porta (o único estado não bloqueado)")
	Check(_Blocked(sql, "failed", 4, 4) and not _Blocked(sql, "uptodate", 4, 4),
		"trocar só o PLAN muda o veredito (plan é lido, não decorado)")
	Check(_Blocked(sql, "uptodate", 5, 4) and not _Blocked(sql, "uptodate", 4, 4),
		"trocar só a CONTAGEM de patches muda o veredito")
	Check(_Blocked(sql, "uptodate", 4, 3) and not _Blocked(sql, "uptodate", 4, 4),
		"trocar só a VERSÃO carimbada muda o veredito")
	var sqlBody : String = _BodyOf(_read(SQLPath), "func MigrationBlocked() -> bool:")
	Check(sqlBody.contains("MigrationBlockedState(migrationPlanState, migrationPatchCount, migrationSchemaVersion)"),
		"SQL.MigrationBlocked() consulta o estado vivo do serviço, não um número copiado")
	var statsBody : String = _BodyOf(_read(SQLPath), "func MigrationStats() -> Dictionary:")
	Check(statsBody.contains("var stalled : bool = MigrationBlocked()"),
		"o gauge `stalled` é a MESMA função que a porta usa (um estado, dois leitores)")

	# A superfície de saúde: três requisitos, cada um derruba o 200 sozinho.
	Check(bool(metrics.call("ServingFor", true, true, false)), "inicializado + transporte + schema limpo = /healthz 200")
	var drops : Array = [[false, true, false], [true, false, false], [true, true, true]]
	var stillServing : String = ""
	for row in drops:
		if bool(metrics.call("ServingFor", row[0], row[1], row[2])):
			stillServing += str(row) + " "
	Check(stillServing.is_empty(), "os %d requisitos faltando derrubam o /healthz (%s)" % [drops.size(), stillServing.strip_edges()])
	var servingBody : String = _BodyOf(_read(MetricsPath), "static func ServingFor(")
	Check(not servingBody.contains("Launcher") and not servingBody.contains("Network."),
		"ServingFor é pura: decide sem depender do autoload estar de pé")
	var isServing : String = _BodyOf(_read(MetricsPath), "func IsServing() -> bool:")
	Check(isServing.contains("ServingFor(") and isServing.contains("MigrationBlocked()"),
		"IsServing() delega e leva o flag vivo do schema para o /healthz")

	# A porta, nos dois lados do flag, com contador próprio.
	var g : Object = _newGate(perAddress, ceiling)
	var admittedBefore : int = int(g.get("Admissions"))
	var blockedVerdict : String = String(g.call("Verdict", "203.0.113.70", 1, protocol, baseClock, true))
	Check(blockedVerdict == String(schemaReason), "com o schema parado a porta recusa com o reason do schema (%s)" % blockedVerdict)
	Check(int(g.call("RefusalCount", String(schemaReason))) == 1, "o motivo do schema tem contador próprio, não divide balde")
	Check(int(g.get("Admissions")) == admittedBefore, "a recusa do schema não admitiu ninguém")
	Check(String(g.call("Verdict", "203.0.113.71", 1, protocol, baseClock, false)) == String(reasons["admitted"]),
		"com o flag falso a mesma porta autentica (recusa é do estado, não do código)")
	Check(String(g.call("Verdict", "203.0.113.72", 1, protocol, baseClock)) == String(reasons["admitted"]),
		"a assinatura de quatro argumentos continua valendo: o default é aberto, nenhum caller quebrou")

	# Precedência: teto estourado E schema parado — o jogador não pode ler "lotado"
	# quando o que falta é tabela no banco.
	var both : Object = _newGate(perAddress, 0)
	Check(String(both.call("Verdict", "203.0.113.73", 99, protocol, baseClock, true)) == String(schemaReason),
		"schema parado vem ANTES do teto")
	Check(String(both.call("Verdict", "203.0.113.73", 99, protocol, baseClock, false)) == String(reasons["ceiling"]),
		"com o schema limpo a mesma casa cai no teto (as duas réguas seguem vivas)")
	Check(int(both.call("RefusalCount", String(schemaReason))) == 1 and int(both.call("RefusalCount", reasons["ceiling"])) == 1,
		"os dois motivos contaram a própria recusa, sem canibalizar o anterior")

	# Fiação viva: quem chama passa o estado, e a ordem do código é a ordem da decisão.
	var validate : String = _BodyOf(_read(ServerPath), "func _ValidateAuth(")
	Check(validate.contains("CheckAuth(") and validate.contains("MigrationBlocked()"),
		"Server._ValidateAuth lê SQL.MigrationBlocked() e entrega à porta")
	var verdictBody : String = _BodyOf(_read(AdmissionPath), "func Verdict(")
	Check(_SchemaBeforeCeiling(verdictBody), "no código da porta o flag do schema decide antes do teto")
	Check(not _SchemaBeforeCeiling("if liveSessions > Ceiling: verdict = ReasonCeiling\nelif schemaBlocked: verdict = ReasonSchema"),
		"corpo sintético com o teto primeiro é REPROVADO pela régua posicional (mordida medida)")
	Check(not _SchemaBeforeCeiling("if liveSessions > Ceiling: verdict = ReasonCeiling"),
		"corpo sem o flag do schema é reprovado, não passa de raspão")
	var checkAuth : String = _BodyOf(_read(AdmissionPath), "func CheckAuth(")
	Check(checkAuth.contains("schemaBlocked"), "CheckAuth atravessa o flag até o Verdict (não é enfeite na assinatura)")
	var gateUses : int = _read(SQLPath).count("MigrationBlocked()")
	Check(gateUses >= 2, "MigrationBlocked() tem leitores reais no próprio módulo (%d)" % gateUses)
