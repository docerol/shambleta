extends RefCounted
class_name Hasher

const TokenHmacKeyEnv : String = "SHAMBLETA_TOKEN_SIGNING_KEY"
const DefaultTokenHmacKey : String = "shambleta-dev-insecure-signing-key"

# SOM-IDLE P0-4 (auditoria 2026-10-04, §P0-4): a chave default vive neste fonte
# e o fonte é público — num repo open source ela é uma credencial de mentira. O
# defecto era o fallback INCONDICIONAL: um deploy novo (compose marca
# `SHAMBLETA_PRODUCTION=1`) assinava sessão de "lembrar-me" com a chave que
# qualquer leitor do binário conhece, i.e. qualquer um forjava token a partir do
# repositório. Agora o fallback vale só onde a chave é segredo de verdade do
# ambiente: dev/editor/testes (`LauncherCommons.IsTesting`, o mesmo default que
# decide live.db vs testing.db). Em produção sem env o canal devolve VAZIO —
# `IssueAuthToken` não emite, `ValidateAuthToken` não casa, e o login por senha
# (que não passa por aqui) continua funcionando. Fail-closed, não boot-crash:
# a régua acusa (`check_secrets` + `.env.example`), o `up` não recusa.
static func _TokenSigningKey() -> String:
	var env : String = OS.get_environment(TokenHmacKeyEnv)
	if not env.is_empty():
		return env
	if not LauncherCommons.IsTesting:
		return ""
	return DefaultTokenHmacKey


static func HashAuthToken(token : String) -> String:
	if token.is_empty():
		return ""
	var key : String = _TokenSigningKey()
	if key.is_empty():
		return ""
	var crypto : Crypto = Crypto.new()
	var digest : PackedByteArray = crypto.hmac_digest(HashingContext.HASH_SHA256, key.to_utf8_buffer(), token.to_utf8_buffer())
	return digest.hex_encode()

# P1-F (auditoria 2026-10-06): o provably-fair do baú precisa de segredo do
# servidor na semente. `id:created_at:shambleta` era recomputável por quem
# lesse duas colunas públicas da própria tabela — salt fixo não é segredo, e
# o jogador abria o baú sabendo o resultado. O seal herdado do MESMO regime
# da chave de sessão (env em produção, dev fallback só em teste), com
# separação de domínio pelo prefixo; sem chave não há seal, e quem abre recusa
# o baú — roll previsível custa mais que uma abertura negada.
static func ChestSeal(chestID : int, createdAt : int) -> String:
	var key : String = _TokenSigningKey()
	if key.is_empty():
		return ""
	var crypto : Crypto = Crypto.new()
	var digest : PackedByteArray = crypto.hmac_digest(HashingContext.HASH_SHA256, key.to_utf8_buffer(), ("chest-seal:%d:%d" % [chestID, createdAt]).to_utf8_buffer())
	return digest.hex_encode()

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
# ver 1 = KDF_ITERATIONS(12000) x SHA-256(prev + salt). New accounts always ver 1.
# ver 2 = PBKDF2-HMAC-SHA256, PBKDF2_ITERATIONS(210000), 32-byte salt. Novas contas
# usam ver 2 direto; ver < 2 é re-hasheado em login (transparent upgrade).
# NOTA (2026-10-04): Godot 4.7 não expõe `Crypto.pbkdf2_hmac` (proposta
# godot-proposals#3293 nunca foi aceita), então a PBKDF2 é implementada em GDScript
# sobre `Crypto.hmac_digest`. 210k ≈ 680 ms de login (610k ≈ 2s; o GDScript roda
# ~60× mais devagar que C, mas 210k ainda é ~17× mais caro que o antigo 12k
# single-SHA-256 contra um atacante offline reimplementando em C). O formato
# armazenado é `pbkdf2_sha256$<iters>$<salt_hex>$<hash_hex>` — padrão, portanto um
# atacante com dump reimplementa a PBKDF2 em C normalmente; o que o upgrade garante
# é que não há atalho no algoritmo e o custo por tentativa sobe ~17× → 18×. O login
# on-line também sofre lockout exponencial (`SQLSecurity`), defesa primária.
const KdfIterations : int = 12000
const PBKDF2Iterations : int = 210000
const HashVersion : int = 2

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

# SOM-IDLE A1 §ver 2 (2026-10-04): PBKDF2-HMAC-SHA256. Godot 4.7 não expõe
# `Crypto.pbkdf2_hmac`, então a iteração é feita sobre `Crypto.hmac_digest`. O salt
# é gerado aqui (CSPRNG) e embutido no hash — não vem mais do caller — e o
# formato `pbkdf2_sha256$<iters>$<salt_hex>$<hash_hex>` carrega os parâmetros,
# portanto `VerifyPassword` lê de onde está. Verificação usa early-exit da iteração
# quando a senha bate de qualquer forma (o custo já foi pago). Um atacante com o dump
# reimplementa em C; a defesa on-line continua sendo o lockout exponencial.
static func HashPasswordV2(password : String, salt : String = "", iterations : int = PBKDF2Iterations) -> String:
	var realSalt : String = salt if not salt.is_empty() else GenerateSalt(16)
	var key : PackedByteArray = _Pbkdf2HmacSha256(password.to_utf8_buffer(), realSalt.to_utf8_buffer(), iterations, 32)
	return "pbkdf2_sha256$%d$%s$%s" % [iterations, realSalt, key.hex_encode()]

static func _Pbkdf2HmacSha256(password : PackedByteArray, salt : PackedByteArray, iterations : int, outLen : int) -> PackedByteArray:
	var crypto : Crypto = Crypto.new()
	var hashLen : int = crypto.hmac_digest(HashingContext.HASH_SHA256, password, salt).size()
	var blocks : int = (outLen + hashLen - 1) / hashLen
	var out : PackedByteArray = PackedByteArray()
	var i : int = 1
	while i <= blocks:
		var saltBlock : PackedByteArray = salt.duplicate()
		saltBlock.append_array([(i >> 24) & 0xFF, (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF])
		var u : PackedByteArray = crypto.hmac_digest(HashingContext.HASH_SHA256, password, saltBlock)
		var f : PackedByteArray = u.duplicate()
		var k : int = 1
		while k < iterations:
			u = crypto.hmac_digest(HashingContext.HASH_SHA256, password, u)
			for j in u.size():
				f[j] ^= u[j]
			k += 1
		out.append_array(f)
		i += 1
	return out.slice(0, outLen)

# Parseia o formato `pbkdf2_sha256$<iters>$<salt_hex>$<hash_hex>` em dicionário
# {algorithm, iterations, salt, hash}. Salt vem em hex — `GenerateSalt` já retorna
# hex, e `HashPasswordV2` o grava assim. Usado só por `VerifyPassword` (ver 2).
static func HashPasswordV2_Parse(stored : String) -> Dictionary:
	var parts : PackedStringArray = stored.split("$")
	if parts.size() != 4 or parts[0] != "pbkdf2_sha256":
		return {}
	return {
		"algorithm" = "pbkdf2_sha256",
		"iterations" = int(parts[1]),
		"salt" = parts[2],
		"hash" = parts[3],
	}

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
		# ver 2: PBKDF2-HMAC-SHA256. O custo é LIDO do registro (a promessa da
		# linha 100 deste arquivo — "VerifyPassword lê de onde está"), não da
		# constante: subir `PBKDF2Iterations` no código deixaria toda conta
		# ver-2 presa para sempre se a verificação recalcular no número novo.
		var parsed : Dictionary = HashPasswordV2_Parse(storedHash)
		if parsed.is_empty():
			return false
		var iters : int = int(parsed.get("iterations", 0))
		if iters <= 0:
			return false
		var storedSalt : String = str(parsed.get("salt", ""))
		var storedHex : String = str(parsed.get("hash", ""))
		var key : PackedByteArray = _Pbkdf2HmacSha256(password.to_utf8_buffer(), storedSalt.to_utf8_buffer(), iters, 32)
		# Rama de comprimento: a primeira geração do ver-2 guardava 62 hex — o
		# `slice(0, outLen - 1)` que devolvia 31 bytes. A derivação é a MESMA;
		# o que mudou é quanto do output entrava no registro. Escolher pela
		# forma do stored hash (dado do banco, não segredo) custa um PBKDF2 só,
		# em vez de dois — e os três ramos do veredito seguem no MESMO
		# SecureEquals, um por ramo, que é a régua de `password_timing_path_test`.
		var candidate : String = ""
		if storedHex.length() == 62:
			candidate = "pbkdf2_sha256$%d$%s$%s" % [iters, storedSalt, key.slice(0, 31).hex_encode()]
		else:
			candidate = "pbkdf2_sha256$%d$%s$%s" % [iters, storedSalt, key.hex_encode()]
		return SecureEquals(candidate, storedHash)
	elif hashVer == 1:
		return SecureEquals(HashPasswordV1(password, salt), storedHash)
	return SecureEquals(HashPassword(password, salt), storedHash)

# A conta pede hash novo quando: a versão é antiga (0/1 sobem para a corrente),
# o registro ver-2 confessa um custo diferente do corrente, ou o hash é da
# primeira geração de 62 hex (o slice truncado). `SQL.ValidateAuthPassword`
# chama isto DEPOIS de a verificação passar — o re-hash é pago uma vez de vida,
# nunca de novo, e é o único caminho pelo qual a rama legada do ver-2 some do
# banco sem migração e sem lockdown.
static func NeedsRehash(storedHash : String, hashVer : int) -> bool:
	if hashVer < HashVersion:
		return true
	if hashVer > HashVersion:
		return false
	var parsed : Dictionary = HashPasswordV2_Parse(storedHash)
	if parsed.is_empty():
		return true
	if int(parsed.get("iterations", 0)) != PBKDF2Iterations:
		return true
	return str(parsed.get("hash", "")).length() != 64

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
