extends RefCounted
class_name Hasher

#
const DefaultSaltSize : int				= 16
const DefaultTokenSize : int			= 32
const DefaultResetCodeLength : int		= 6
# SOM-IDLE AUTH-P0 (auditoria 2026-09-27 §10/§22): o código de reset era
# `int(byte) % 10` em 6 posições, i.e. 10^6 = 20 bits de entropia — espaço que
# ~1.100 conexões cobriam em menos de 15 min e sem contador de tentativas. O
# alfabeto abaixo é o Crockford-style base32 (32 símbolos, sem 0/O/1/I, que são
# os pares que um humano confunde ao digitar de um e-mail). 256 % 32 == 0, então
# `byte % 32` é EXATAMENTE uniforme: sem viés e sem rejeição de bytes. Formato
# declarado: 6 caracteres maiúsculos de [2-9A-Z sem I/O] = 32^6 = 30 bits
# (~1.073.741.824), comparado case-insensitive via NormalizeResetCode.
const ResetCodeAlphabet : String		= "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

# Password
# SOM-IDLE A1: KDF stretching (iterated SHA-256) + CSPRNG salts.
# ver 0 = legacy single SHA-256(salt + password) — verify-only, upgraded on login.
# ver 1 = KDF_ITERATIONS x SHA-256(prev + salt). New accounts always ver 1.
const KdfIterations : int = 12000
const HashVersion : int = 1

static func GenerateSalt(length : int = DefaultSaltSize) -> String:
	var crypto : Crypto = Crypto.new()
	var bytes : PackedByteArray = crypto.generate_random_bytes(length)
	if bytes.size() == length:
		return bytes.hex_encode().substr(0, length * 2)
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var salt : String = ""
	for i in length:
		salt += char(rng.randi_range(33, 126))
	return salt

static func _sha256_hex(data : PackedByteArray) -> String:
	var hashContext : HashingContext = HashingContext.new()
	hashContext.start(HashingContext.HASH_SHA256)
	hashContext.update(data)
	return hashContext.finish().hex_encode()

static func HashPassword(password : String, salt : String = "") -> String:
	return _sha256_hex((salt + password).to_utf8_buffer())

static func HashPasswordV1(password : String, salt : String) -> String:
	var hex : String = _sha256_hex((salt + password).to_utf8_buffer())
	for i in range(1, KdfIterations):
		hex = _sha256_hex((hex + salt).to_utf8_buffer())
	return hex

static func VerifyPassword(password : String, salt : String, storedHash : String, hashVer : int = 0) -> bool:
	# SOM-IDLE A1 (revisado na auditoria de 2026-09-27, §10): a comparação era `==`.
	# Os dois lados têm 64 hex e um `==` GDScript sai no primeiro byte diferente,
	# então a latência da rota de login carrega informação sobre o prefixo do hash
	# — e prefixo de hash de senha É segredo para quem já tem o dump do banco. O
	# rodapé deste arquivo tinha a primitiva certa (`SecureEquals`) e o comentário
	# dela confessava que só o caminho de reset a usava: agora usa aqui também, e
	# os dois ramos de versão (legado ver 0 e KDF ver 1) convergem para o MESMO
	# comparador — foi justamente o ramo de baixo, o mais velho, que ficou de fora
	# na primeira passada. Quem abre um terceiro ramo paga a mesma régua.
	if hashVer >= HashVersion:
		return SecureEquals(HashPasswordV1(password, salt), storedHash)
	return SecureEquals(HashPassword(password, salt), storedHash)

# Reset Code
# Alta entropia: um símbolo por byte criptográfico do `Crypto` do engine (AES-CTR
# backed), mapeado sem viés sobre ResetCodeAlphabet. O fallback (Crypto indisponível)
# continua no MESMO alfabeto e no MESMO comprimento usando `RandomNumberGenerator`
# semeado — entropia pior, formato idêntico, e nunca volta para os 10 dígitos.
static func GenerateResetCode(length : int = DefaultResetCodeLength) -> String:
	var crypto : Crypto = Crypto.new()
	var bytes : PackedByteArray = crypto.generate_random_bytes(length)
	var code : String = ""
	if bytes.size() == length:
		for b in bytes:
			code += ResetCodeAlphabet[int(b) % ResetCodeAlphabet.length()]
		return code
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	for i in length:
		code += ResetCodeAlphabet[rng.randi_range(0, ResetCodeAlphabet.length() - 1)]
	return code

# O código viaja e é armazenado normalizado: o usuário pode digitar minúsculas,
# com espaço ou hífen (e-mail quebrado em duas linhas no cliente de webmail), e
# o hash guardado em `pendingResets` é sempre do texto normalizado.
static func NormalizeResetCode(code : String) -> String:
	return code.strip_edges().replace(" ", "").replace("-", "").replace("\n", "").replace("\r", "").to_upper()

# Validador do formato declarado: comprimento fixo e só símbolos do alfabeto.
static func IsValidResetCode(code : String) -> bool:
	if code.length() != DefaultResetCodeLength:
		return false
	for i in code.length():
		if ResetCodeAlphabet.find(code[i]) < 0:
			return false
	return true

# SOM-IDLE AUTH-P2: comparação em tempo constante. `==` em GDScript curto-circuita
# no primeiro byte diferente e devolve o hash de 64 hex; localmente isso é um canal
# de timing (o auditório §10 lista `==` em hash de reset/senha/TOTP). Hoje os dois
# consumidores do canal usam isto: `ConfirmPasswordReset` (via hash de código) e
# `VerifyPassword` (login/2FA/checkout), que é o caminho que o banco inteiro aponta
# para uma conta. O `Hasher` é autoload e não tem estado, então isto é estático puro.
static func SecureEquals(left : String, right : String) -> bool:
	var a : PackedByteArray = left.to_utf8_buffer()
	var b : PackedByteArray = right.to_utf8_buffer()
	var diff : int = a.size() ^ b.size()
	var n : int = maxi(a.size(), b.size())
	# Percorre até o MAIOR comprimento, com zeros além do fim do menor: sair no
	# primeiro byte quando os tamanhos diferem entrega 1 bit por caminho de código
	# (é barato aqui — hash tem tamanho fixo — mas a primitiva é pública e um TOTP
	# ou token de 6 dígitos digitados a mais cairia nela).
	for i in n:
		var ca : int = a[i] if i < a.size() else 0
		var cb : int = b[i] if i < b.size() else 0
		diff |= ca ^ cb
	return diff == 0
