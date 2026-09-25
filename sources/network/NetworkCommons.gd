extends RefCounted
class_name NetworkCommons

# Server
const WebSocketPortTesting : int		= 6118
const ENetPortTesting : int				= 6119
const ServerAddressTesting : String		= "som.manasource.org"

# SOM-IDLE beta deploy: endpoint público configurável em runtime — o deploy
# (Coolify) sobrescreve via conf [Network] Server-Address / Server-Port
# (Launcher._ready), então o mesmo binário serve dev e produção.
static var WebSocketPort : int			= 6108
static var ENetPort : int				= 6109
static var ServerAddress : String		= "som.manasource.org"

# SOM-IDLE beta (fronteira do dinheiro): base HTTP do companion, o serviço que
# recebe webhook de pagamento e cria a preferência de checkout. Browser não tem
# variável de ambiente, e o default histórico (loopback) só faz sentido em
# desktop/dev — no export web ele apontava para a máquina do jogador, então
# nenhum POST de checkout chegava ao companion. Quem resolve é `Launcher._ready`
# (uma vez, junto com Server-Address) escrevendo em `CompanionURL`; o client lê.
const CompanionPort : int				= 8901
const CompanionLocalDev : String	= "http://127.0.0.1:%d" % CompanionPort
static var CompanionURL : String	= CompanionLocalDev

# Pura de propósito (mesmo formato de LauncherCommons.ResolveIsTesting): as três
# fontes entram por parâmetro, então o harness cobre o ramo web sem browser.
# Ordem: env (desktop/dev) > conf [Network] Companion-Base (baked no build) >
# origem da página (web; é o proxy same-origin do nginx) > loopback de dev.
static func ResolveCompanionURL(envValue : String, confValue : String, pageOrigin : String) -> String:
	for candidate : String in [envValue, confValue, pageOrigin]:
		var url : String = candidate.strip_edges().trim_suffix("/")
		if not url.is_empty():
			return url
	return CompanionLocalDev

# SOM-IDLE beta deploy: TLS terminado no proxy reverso (Coolify/Traefik). O
# server binda ws:// plain porque o proxy expõe wss:// ao cliente — nunca
# ativar em binds públicos diretos. Lido de SHAMBLETA_PROXY_TLS=1.
static var ProxyTLS : bool				= OS.get_environment("SHAMBLETA_PROXY_TLS").strip_edges() == "1"

const LocalServerAddress : String		= "127.0.0.1"
const MaxPlayerCount : int				= 128

# Visibility
const VisibilityBorder : float			= 64.0
const MaxVisibilityHalfWidth : float	= 2560 / 2.0
const MaxVisibilityHalfHeight : float	= 1440 / 2.0

static func IsAlwaysVisible(agent : BaseAgent):
	return agent and agent is AIAgent and agent.spawnInfo and agent.spawnInfo.is_always_visible

static func IsVisible(fromPos : Vector2, toPos : Vector2, halfSize : Vector2) -> bool:
	var diff : Vector2 = (toPos - fromPos).abs()
	return diff.x <= halfSize.x and diff.y <= halfSize.y

# Bulk
const BulkMinSize : int					= 3

# Frame sequencing
static func FrameID() -> int:
	return Engine.get_physics_frames()

static func IsFrameNewer(frameID : int, lastFrameID : int) -> bool:
	# Track the last received server frame to drop old rpc calls in the client on different network channels
	return lastFrameID < 0 or frameID > lastFrameID

# Navigation
const NavigationSpawnTry : int			= 10

# Guardband
const StartGuardbandDistSquared : float	= 6.0 * 6.0
const MaxGuardbandDistSquared : float	= 64.0 * 64.0

# Connection
const PeerUnknownID : int				= -2
const PeerOfflineID : int				= -1
const PeerAuthorityID : int				= 1

const DelayInstant : int				= 0
const DelayShort : int					= 16
const DelayDefault : int				= 50
const DelayLogin : int					= 1000
# SOM-IDLE: F2 idle-spike rate limits — 5/min config actions, 1/min minute-tier
const DelayConfig : int					= 12000
const DelayMinute : int					= 60000

const Timeout : int						= 1000
const TimeoutMin : int					= 30000
const TimeoutMax : int					= 60000

const LoginAttemptTimeout : float		= 15
const CharSelectionTimeout : float		= 15

# Protocol
static var ProtocolVersion : int		= 0

static func ComputeProtocolVersion(network : Node) -> int:
	# RPCs vivem TODOS na facade Network (autoload alvo do multiplayerAPI.rpc);
	# fragmentar em autoloads separados quebra o dispatch do motor (P4 revertido
	# 2026-09-23). O hash abaixo é a assinatura client/server: qualquer mudança
	# de assinatura RPC deve ser acompanhada de bump de versão de pacote.
	var rpcConfig : Dictionary = network.get_script().get_rpc_config()
	var methods : Array = []
	for method in rpcConfig.keys():
		methods.append(str(method))
	methods.sort()

	var serialized : String = ""
	for method in methods:
		var config : Dictionary = rpcConfig[StringName(method)]
		var keys : Array = config.keys()
		keys.sort()
		serialized += method
		for key in keys:
			serialized += ",%s:%s" % [key, config[key]]
		serialized += "\n"

	return hash(serialized)

# Peer
const UseENet : bool					= true
const UseWebSocket : bool				= true
const UseWebRTC : bool					= true
static var IsLocal : bool				= false

# WebRTC signaling
const IceServers : Array[Dictionary]	= [{ "urls": "stun:stun.l.google.com:19302" }]

# One entry per EChannel above the default channel 0 triad, in EChannel order
const RtcChannelsConfig : Array			= [
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
	MultiplayerPeer.TRANSFER_MODE_RELIABLE,
]

const ServerKeyPath : String			= "user://server.key"
const ServerCertPath : String			= "user://server.crt"

# Auth
const PlayerNameMinSize : int			= 3
const PlayerNameMaxSize : int			= 30
const PasswordMinSize : int				= 6
const PasswordMaxSize : int				= 30
const EntryValidRegex : String			= "^[\\w#!@%&:;<>,\\$\\^*\\(\\)_+=\\{\\}\\[\\]\\.?/-]+$"
const EmailValidRegex : String			= "^[\\w\\.\\+\\-]+@[a-zA-Z0-9\\.\\-]+\\.[a-zA-Z]{2,}$"

# Token
const TokenExpirySec : int				= 30 * 24 * 60 * 60
# SOM-IDLE beta (T9): janela do desafio 2FA pós-senha (pendingTwoFactorAccount).
const TwoFactorChallengeSec : int			= 5 * 60

# Password Reset
const ResetCodeExpiryMinutes : int		= 15
const ResetCodeCooldownMinutes : int	= 5
const ResetCodeSize : int				= 6

# Auth hardening (SOM-IDLE A1: anti-bruteforce backoff)
const MaxLoginAttempts : int			= 5
const BaseLockoutSec : int				= 300
const MaxLockoutSec : int				= 7200

# SOM-IDLE C1: cota de tamanho do chat. Vale onde nenhum cliente manda — o
# NotifyGlobal/NotifyNeighbours repete cada linha para a sala inteira, então um
# texto de megabytes de um peer vira banda e layout quebrado para todos.
const ChatMaxSize : int					= 240

# SOM-IDLE A2: produção pública exige TLS (WSS/DTLS). Dev/test/offline/local
# estão isentos (loopback ou sem rede). WebRTC não passa por aqui e já é
# sempre cifrado pelo próprio protocolo (DTLS-SRTP mandatório).
static func RequiresTLS(isTesting : bool, isOffline : bool, isLocal : bool) -> bool:
	return not isTesting and not isOffline and not isLocal

# SOM-IDLE beta (V7): as opções TLS do CLIENTE, com a verificação de certificado
# LIGADA. `TLSOptions.client_unsafe()` desliga cadeia e hostname no canal por onde
# viajam senha, token de "lembrar" e o código 2FA dos RPCs de auth — um MITM na rota
# respondia com qualquer certificado e colhia credencial antes de repassar o tráfego
# ao servidor real. O hostname conferido não é argumento daqui: o transporte o deriva
# do URL (`create_client` em wss://host) ou do endereço do `dtls_client_setup`.
#
# A âncora é a store de CA do sistema entregue explicitamente, e isso não é preciosismo:
# medido com este engine (Godot 4.7.2, Linux/mbedtls, WebSocket em loopback contra
# certificado autoassinado), `TLSOptions.client()` sem argumento morre na inicialização
# do contexto — "SSL module failed to initialize!" (-0x6C00) — e o handshake nem
# acontece, ou seja, derrubaria o login do desktop. O mesmo PEM lido do sistema e
# passado como CA funciona: recusa cadeia não confiável (-0x2700 / -0x7180) e aceita
# quando a âncora bate. Sem store legível o fallback é o caminho interno do engine
# (verificado também); `client_unsafe` não é fallback de nada.
static func ClientTLSOptions() -> TLSOptions:
	# Web: não há store de âncoras para o wasm consultar, e a tentativa de ler uma
	# despejava um `ERROR: Error parsing X509 certificates: -8576` (INVALID_FORMAT) no
	# console de cada jogador — medido no navegador em 2026-09-25, com o mesmo engine
	# respondendo OK para um PEM de 185.307 chars no desktop (`OS` base devolve string
	# vazia na plataforma, sem nenhuma implementação de certificado no glue web).
	# Não é regressão da verificação acima: no browser quem faz o handshake do `wss://`
	# é o próprio navegador (a tentativa de conexão cai na camada de rede dele, com
	# erro `net::`), então o Godot não termina TLS aqui e estas opções são inertes. O
	# caminho que verifica certificado vale onde o engine termina o TLS — desktop.
	if LauncherCommons.isWeb:
		return TLSOptions.client()
	var systemAnchors : X509Certificate = X509Certificate.new()
	if systemAnchors.load_from_string(OS.get_system_ca_certificates()) == OK:
		return TLSOptions.client(systemAnchors)
	return TLSOptions.client()

# Tools
const OnlineListPath : String			= ""

enum Platform {
	UNKNOWN = 0,
	WINDOWS,
	LINUX,
	MACOS,
	ANDROID,
	IOS,
	WEB,
	FREEBSD,
	NETBSD,
	OPENBSD,
	COUNT
}

static func GetPlatform() -> Platform:
	match OS.get_name():
		"Windows": return Platform.WINDOWS
		"Linux": return Platform.LINUX
		"macOS": return Platform.MACOS
		"Android": return Platform.ANDROID
		"iOS": return Platform.IOS
		"Web": return Platform.WEB
		"FreeBSD": return Platform.FREEBSD
		"NetBSD": return Platform.NETBSD
		"OpenBSD": return Platform.OPENBSD
	return Platform.UNKNOWN

enum AuthError {
	ERR_OK = 0,
	ERR_NO_PEER_DATA,
	ERR_TIMEOUT,
	ERR_SERVER_UNREACHABLE,
	ERR_RPC_MISMATCH,
	ERR_AUTH,
	ERR_PASSWORD_VALID,
	ERR_PASSWORD_SIZE,
	ERR_NAME_AVAILABLE,
	ERR_NAME_VALID,
	ERR_NAME_SIZE,
	ERR_EMAIL_VALID,
	ERR_DUPLICATE_CONNECTION,
	ERR_BANNED,
	ERR_TOKEN,
	ERR_RESET_UNAVAILABLE,
	ERR_RESET_EMAIL_SENT,
	ERR_RESET_INVALID_CODE,
	ERR_RESET_PASSWORD_UPDATED,
	ERR_PASSWORD_MISMATCH,
	ERR_PASSWORD_CHANGE_OK,
	ERR_PASSWORD_CHANGE_WRONG,
	# SOM-IDLE LGPD: cadastro exige aceite afirmativo dos termos.
	ERR_CONSENT_REQUIRED,
	# SOM-IDLE F4 follow-up: email já cadastrado não é "nome indisponível".
	ERR_EMAIL_TAKEN,
	# SOM-IDLE S4: 2FA required for admin/GM accounts.
	ERR_2FA_REQUIRED,
}

# SOM-IDLE LGPD: status da conta para o direito ao esquecimento (art. 18).
enum AccountStatus {
	ACTIVE = 0,
	DELETION_SCHEDULED = 1,
	DELETED = 2,
}

# Versões dos textos legais que o cliente está exibindo/aceitando. bump a cada
# revisão jurídica — força re-aceite dos ativos (handoff: sincronizar com o
# conteúdo de data/db/agreement.json e a política de privacidade publicada).
const AgreementTosVersion : String = "2026-09-c"		# bumped: canal de suporte do aceite (era Discord/IRC do upstream)
const AgreementPrivacyVersion : String = "2026-09-b"
# Gate de idade (§21/§24-11): terceira cláusula do mesmo aceite afirmativo — o
# jogador declara ter 18+. Bump aqui força re-afirmação dos ativos, como os dois
# acima. A fonte do texto é `data/db/agreement.json`
# ("Age and Paid Randomized Content"); o predicate é version-aware em SQL.
const AgreementAgeVersion : String = "2026-09-a"

static func CheckSize(entry : String, minSize : int, maxSize : int) -> bool:
	var currentSize : int = entry.length()
	return (currentSize >= minSize and currentSize <= maxSize)

static func CheckValid(entry : String, validRegex : String) -> bool:
	var regex = RegEx.new()
	regex.compile(validRegex)
	var result = regex.search(entry)
	return result != null

static func CheckAuthInformation(nameText : String, passwordText : String) -> AuthError:
	if not CheckSize(nameText, PlayerNameMinSize, PlayerNameMaxSize):
		return AuthError.ERR_NAME_SIZE
	elif not CheckValid(nameText, EntryValidRegex):
		return AuthError.ERR_NAME_VALID
	return CheckPasswordInformation(passwordText)

static func CheckPasswordInformation(passwordText : String) -> AuthError:
	if not CheckSize(passwordText, PasswordMinSize, PasswordMaxSize):
		return AuthError.ERR_PASSWORD_SIZE
	elif not CheckValid(passwordText, EntryValidRegex):
		return AuthError.ERR_PASSWORD_VALID
	return AuthError.ERR_OK

static func CheckEmailInformation(emailText : String) -> AuthError:
	return AuthError.ERR_OK if CheckValid(emailText, EmailValidRegex) else AuthError.ERR_EMAIL_VALID

static func CheckResetCode(code : String) -> bool:
	return code.length() == ResetCodeSize and code.is_valid_int()

# SOM-IDLE C1: normaliza a linha de chat no servidor — corta no teto e remove a
# sobra de espaço/quebra de linha, de modo que texto só-espaço vazio "" e o
# chamador descarte. Sempre devolve no máximo ChatMaxSize caracteres.
static func ClipChat(text : String) -> String:
	return text.substr(0, ChatMaxSize).strip_edges()

# IP ranges with wildcards support
static func IsValidIPRange(ipRange : String) -> bool:
	var chunks : PackedStringArray = ipRange.split(".")
	if chunks.size() != 4:
		return false

	for chunk in chunks:
		if chunk == "*":
			continue
		if not chunk.is_valid_int():
			return false
		var value : int = chunk.to_int()
		if value < 0 or value > 255:
			return false
	return true

static func IsIPInRange(ip : String, ipRange : String) -> bool:
	if ip.is_empty():
		return false

	var ipOctets : PackedStringArray = ip.split(".")
	var rangeOctets : PackedStringArray = ipRange.split(".")
	if ipOctets.size() != 4 or rangeOctets.size() != 4:
		return false

	for chunk in 4:
		if rangeOctets[chunk] != "*" and rangeOctets[chunk] != ipOctets[chunk]:
			return false
	return true

# Character
enum CharacterError {
	ERR_OK = 0,
	ERR_ALREADY_LOGGED_IN,
	ERR_NO_PEER_DATA,
	ERR_NO_CHARACTER_ID,
	ERR_NO_ACCOUNT_ID,
	ERR_TIMEOUT,
	ERR_MISSING_PARAMS,
	ERR_NAME_AVAILABLE,
	ERR_NAME_VALID,
	ERR_NAME_SIZE,
	ERR_SLOT_AVAILABLE,
	ERR_EMPTY_ACCOUNT,
}

static func CheckCharacterInformation(nickText : String) -> CharacterError:
	if not CheckSize(nickText, PlayerNameMinSize, PlayerNameMaxSize):
		return CharacterError.ERR_NAME_SIZE
	elif not CheckValid(nickText, EntryValidRegex):
		return CharacterError.ERR_NAME_VALID
	return CharacterError.ERR_OK
