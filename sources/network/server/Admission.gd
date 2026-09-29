extends RefCounted
class_name Admission

# Porta de entrada do servidor: tudo que decide se um handshake vira sessão ANTES
# de `complete_auth`. A auditoria de 2026-09-28 mediu três buracos no mesmo ponto
# (`Server._ValidateAuth` só comparava `ProtocolVersion` e aprovava de imediato):
# nenhum teto no transporte por onde o web entra, nenhum custo por tentativa de
# autenticação, nenhuma régua de máquina dizendo que o God Mode não chega à
# produção. Os dois primeiros moram aqui; o TERCEIRO é medido de fato, na suíte S4
# (`_SuiteGodModeGate`) de tests/admission_gate_test.gd, que (a) varre `deploy/**` e
# `.github/**` e reprova se `SHAMBLETA_GM_MODE` aparecer em qualquer arquivo deles,
# (b) exige que o nome continue existindo só no `.env.example`, com o "nunca em
# produção" escrito junto, e (c) confere em `sources/debug/CommandManager.gd` que
# essa env é a única alavanca do bypass de permissão — `Handle` recusa em
# `not GMModeEnabled() and command._permission > playerPermission` — e que nada
# chama `set_environment` para ela. A régua tem mordida: o controle negativo injeta
# deploy falso EM MEMÓRIA (compose, Dockerfile, env de job, interpolação, runbook) e
# exige que cada um desses caminhos seja pego.
#
# 1) TETO. `NetworkCommons.ConnectionCeiling()` é o único número, lido pelos dois
#    transportes no MESMO lugar (`OpenTransport`, um caminho abaixo do outro). ENet
#    recebe o teto no próprio `create_server`; o WebSocket não tem onde cobrá-lo no
#    transporte — `create_server(port, bind_address, tls)` expõe endereço de bind,
#    não contagem de clientes — então o mesmo número vira a régua desta porta. É a
#    divergência 128/x que era o bug. Medido por S1 (o número que CADA transporte
#    recebeu, comparado ao accessor vivo) e por S3 (recusa real sobre socket).
# 2) ORÇAMENTO PRÉ-AUTH POR ENDEREÇO. Cada handshake cobra o endereço num balde fixo
#    de `PreAuthWindowSec` segundos, antes de qualquer credencial. Quem aceita a
#    conexão e não autentica segura um slot até `LoginAttemptTimeout` (15 s) e um
#    objeto no motor; sem cota, o custo de martelar a porta era zero.
# 3) REASON ESTÁVEL. Recusa tem código e contador próprios (`Refusals`), medidos por
#    teste — o log não é evidência. S1 confere o reason do teto, S2 um contador por
#    reason (orçamento e protocolo não dividem balde) e S3 o contador do gate lido
#    depois de handshake de verdade, com o recusado recebendo byte 0.
# 4) ESQUEMA PARADO. migração que estoura no boot deixava o processo de pé e atendendo
#    handshake: o cliente autenticava e morria na primeira RPC que tocava tabela
#    ausente. `SQL.MigrationBlocked()` é a única alavanca, `ReasonSchema` recusa antes
#    do teto (banco sem as tabelas daquela versão não tem o que oferecer), e o motivo
#    tem contador próprio — medido em S5 de tests/admission_gate_test.gd, que confere
#    os dois lados do flag e a fiação viva em `Server._ValidateAuth`.
#
# Relógio: `ClockOverride` é o seam do harness, no mesmo formato de
# `EmailService.nowOverride` — 0 = relógio real, >0 = segundo fixo. Nada aqui lê
# `Time` por outro caminho, então a janela é determinística (nenhum teste depende de
# wall-clock e por isso nenhum teste flutua).

const ReasonAdmitted : String			= "admitted"
const ReasonSchema : String				= "schema_blocked"
const ReasonCeiling : String			= "connection_ceiling"
const ReasonProtocol : String			= "protocol_mismatch"
const ReasonAddressBudget : String		= "preauth_address_budget"

# Quando o endereço não resolve (peer que já sumiu do transporte entre o poll e o
# callback) a tentativa NÃO é aceita às cegas nem recusa o jogador: ela cai num balde
# compartilhado. O teto de conexões continua valendo, o que se perde é a
# discriminação por endereço — falha fechada em volume, aberta em identidade.
const UnresolvedAddress : String		= "unresolved"

# Seam do harness (mesmo formato de `EmailService.nowOverride`): 0 = relógio real;
# >0 = segundo fixo, para provar a janela sem depender de wall-clock.
var ClockOverride : int					= 0

# O que o bind decidiu (`BindError` é o `Error` do motor) e o que esta porta cobra.
var BindError : int						= OK
var Ceiling : int						= 0
var PerAddress : int					= 0
var WindowSec : int						= NetworkCommons.PreAuthWindowSec

var Attempts : int						= 0
var Admissions : int					= 0
var Refusals : Dictionary				= {}
var windows : Dictionary				= {}	# address -> [bucket, count]

func NowSec() -> int:
	return ClockOverride if ClockOverride > 0 else int(Time.get_unix_time_from_system())

# Cota por endereço. Atrás do proxy reverso (`ProxyTLS`, o bind plain do Coolify)
# TODOS os jogadores chegam com o endereço do proxy: uma cota pequena seria um
# auto-DoS da casa inteira, então ela sobe para o teto de conexões e continua
# segurando o spray de handshakes que nunca autenticam. Direto (ENet, desktop, dev)
# a cota é a pequena, que é onde ela discrimina atacante de jogador.
static func BudgetFor(proxyTLS : bool, ceiling : int) -> int:
	return ceiling if proxyTLS else NetworkCommons.PreAuthPerAddress

# Abre o transporte e devolve a porta de entrada já configurada com o MESMO teto.
# `peer` é `Object` de propósito: os dois ramos chamam `create_server` por `call()`,
# então o harness consegue registrar com um falso transporte o número que cada
# transporte recebeu — que é a única forma de pegar divergência entre eles.
static func OpenTransport(peer : Object, useWebSocket : bool, port : int, tlsOptions : TLSOptions) -> Admission:
	var gate : Admission = Admission.new()
	gate.Ceiling = NetworkCommons.ConnectionCeiling()
	gate.PerAddress = BudgetFor(NetworkCommons.ProxyTLS, gate.Ceiling)
	if useWebSocket:
		# 2º argumento do motor é o ENDEREÇO de bind ("*"), não contagem: o teto do
		# web não pode morar aqui, por isso mora em `gate.Ceiling`.
		gate.BindError = int(peer.call("create_server", port, "*", tlsOptions))
	else:
		gate.BindError = int(peer.call("create_server", port, gate.Ceiling))
		if gate.BindError == OK and tlsOptions != null:
			var host : Object = peer.get("host")
			if host != null:
				gate.BindError = int(host.call("dtls_server_setup", tlsOptions))
	return gate

# Endereço do peer no momento do handshake. `Peers.ResolvePeerIP` não serve aqui:
# ele parte do registro de sessão (`Peers.AddPeer`), e o que esta porta decide
# acontece exatamente antes de existir sessão.
static func AddressOf(peer : MultiplayerPeer, peerID : int) -> String:
	if peer == null:
		return UnresolvedAddress
	var packet : PacketPeer = peer.get_peer(peerID)
	if packet is WebSocketPeer:
		return (packet as WebSocketPeer).get_connected_host()
	if packet is ENetPacketPeer:
		return (packet as ENetPacketPeer).get_remote_address()
	return UnresolvedAddress

# Slots ocupados: sessão autenticada + o que está no meio do handshake. O peer que
# pergunta já está contado (`authenticating_peers`), por isso a régua é `>`.
static func LiveSessions(api : SceneMultiplayer) -> int:
	if api == null:
		return 0
	return api.get_peers().size() + int(api.call("get_authenticating_peers").size())

func AttemptsFor(address : String) -> int:
	var state : Array = windows.get(address, [0, 0])
	return int(state[1])

func RefusalCount(reason : String) -> int:
	return int(Refusals.get(reason, 0))

# Decide e CONTABILIZA. Chamado separadamente do transporte para o orçamento ser
# provável com relógio injetado e sem socket nenhum.
func Verdict(address : String, liveSessions : int, protocol : int, nowSec : int, schemaBlocked : bool = false) -> String:
	Attempts += 1
	var bucket : int = int(maxi(nowSec, 0) / maxi(WindowSec, 1))
	var state : Array = windows.get(address, [bucket, 0])
	if int(state[0]) != bucket:
		state = [bucket, 0]
	state[1] = int(state[1]) + 1
	windows[address] = state

	var verdict : String = ReasonAdmitted
	if schemaBlocked:
		verdict = ReasonSchema
	elif liveSessions > Ceiling:
		verdict = ReasonCeiling
	elif protocol != NetworkCommons.ProtocolVersion:
		verdict = ReasonProtocol
	elif int(state[1]) > PerAddress:
		verdict = ReasonAddressBudget
	if verdict != ReasonAdmitted:
		Refusals[verdict] = int(Refusals.get(verdict, 0)) + 1
	else:
		Admissions += 1
	return verdict

# A porta em si: `api`/`peer` são os objetos vivos do transporte. Recusa manda `[0]`
# e NUNCA chama `complete_auth` — depois daqui só entra quem passou.
func CheckAuth(api : SceneMultiplayer, peer : MultiplayerPeer, peerID : int, data : PackedByteArray, schemaBlocked : bool = false) -> String:
	var protocol : int = int(data.decode_s64(0)) if data.size() >= 8 else -1
	var verdict : String = Verdict(AddressOf(peer, peerID), LiveSessions(api), protocol, NowSec(), schemaBlocked)
	if verdict == ReasonAdmitted:
		# `Admissions` já foi somado dentro de `Verdict`: a contagem é da decisão, não
		# do transporte, senão o mesmo handshake seria contado duas vezes.
		api.send_auth(peerID, PackedByteArray([1]))
		api.complete_auth(peerID)
	else:
		# O `[0]` é o motivo que o client lê. Medido no harness (`tests/admission_gate_
		# test.gd`, S3): derrubar o peer dentro do mesmo callback — `disconnect_peer`
		# do `SceneMultiplayer`, do transporte, ou `close()` do `WebSocketPeer` — joga
		# fora o pacote que ainda está na fila de saída, então o client só ver a conexão
		# sumir. A porta manda o `[0]` e não fecha: o recusado nunca vira sessão e o
		# `auth_timeout` do motor (`LoginAttemptTimeout`, em `Server.gd`) é quem recolhe.
		# O custo de segurar esse slot é limitado pelo próprio orçamento por endereço
		# (32 tentativas por janela), não por spray livre.
		api.send_auth(peerID, PackedByteArray([0]))
	return verdict
