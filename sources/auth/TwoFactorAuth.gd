extends RefCounted
class_name TwoFactorAuth

# SOM-IDLE S4: TOTP-based two-factor authentication for admin/GM accounts.
# Implements RFC 6238 (TOTP) and RFC 3548 (Base32).

const BASE32_ALPHABET: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
const TOTP_STEP_SECONDS: int = 30
const TOTP_DIGITS: int = 6
const TOTP_DRIFT_WINDOWS: int = 1

static func GenerateSecret(length: int = 20) -> String:
	if length <= 0:
		push_error("TwoFactorAuth: secret length must be positive")
		return ""
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(length)
	if bytes.size() != length:
		push_error("TwoFactorAuth: CSPRNG failed")
		return ""
	return Base32Encode(bytes)

static func Base32Encode(data: PackedByteArray) -> String:
	var bits: int = 0
	var value: int = 0
	var output: String = ""
	for byte in data:
		value = (value << 8) | byte
		bits += 8
		while bits >= 5:
			output += BASE32_ALPHABET[(value >> (bits - 5)) & 31]
			bits -= 5
	if bits > 0:
		output += BASE32_ALPHABET[(value << (5 - bits)) & 31]
	while output.length() % 8 != 0:
		output += "="
	return output

static func Base32Decode(encoded: String) -> PackedByteArray:
	encoded = encoded.to_upper().replace("=", "")
	var bits: int = 0
	var value: int = 0
	var output: PackedByteArray = []
	for char in encoded:
		var index: int = BASE32_ALPHABET.find(char)
		if index < 0:
			continue
		value = (value << 5) | index
		bits += 5
		if bits >= 8:
			output.append((value >> (bits - 8)) & 255)
			bits -= 8
	return output

static func GetTOTPCounter(timestamp: int = -1) -> int:
	if timestamp < 0:
		timestamp = int(Time.get_unix_time_from_system())
	return timestamp / TOTP_STEP_SECONDS

static func GenerateTOTP(secret: String, timestamp: int = -1) -> String:
	var counter: int = GetTOTPCounter(timestamp)
	var key: PackedByteArray = Base32Decode(secret)
	if key.is_empty():
		return ""
	var counterBytes: PackedByteArray = PackedByteArray([
		(counter >> 56) & 255,
		(counter >> 48) & 255,
		(counter >> 40) & 255,
		(counter >> 32) & 255,
		(counter >> 24) & 255,
		(counter >> 16) & 255,
		(counter >> 8) & 255,
		counter & 255,
	])
	var hmac: HMACContext = HMACContext.new()
	hmac.start(HashingContext.HASH_SHA1, key)
	hmac.update(counterBytes)
	var hash: PackedByteArray = hmac.finish()
	var offset: int = hash[hash.size() - 1] & 0xf
	var binary: int = ((hash[offset] & 0x7f) << 24) | ((hash[offset + 1] & 0xff) << 16) | ((hash[offset + 2] & 0xff) << 8) | (hash[offset + 3] & 0xff)
	var otp: int = binary % 1000000
	return str(otp).pad_zeros(TOTP_DIGITS)

static func HashToken(token: String) -> String:
	var hashContext := HashingContext.new()
	hashContext.start(HashingContext.HASH_SHA256)
	hashContext.update(token.to_utf8_buffer())
	return hashContext.finish().hex_encode()

static func _constant_time_equals(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff: int = 0
	var aBytes: PackedByteArray = a.to_utf8_buffer()
	var bBytes: PackedByteArray = b.to_utf8_buffer()
	for i in aBytes.size():
		diff = diff | (int(aBytes[i]) ^ int(bBytes[i]))
	return diff == 0

static func VerifyTOTP(secret: String, token: String, timestamp: int = -1) -> bool:
	if token.length() != TOTP_DIGITS or not token.is_valid_int():
		return false
	var baseCounter: int = GetTOTPCounter(timestamp)
	var matchMask: int = 0
	for drift in range(-TOTP_DRIFT_WINDOWS, TOTP_DRIFT_WINDOWS + 1):
		var candidateCounter: int = baseCounter + drift * TOTP_STEP_SECONDS
		var candidate: String = GenerateTOTP(secret, candidateCounter * TOTP_STEP_SECONDS)
		if _constant_time_equals(candidate, token):
			matchMask = matchMask | (1 << (drift + TOTP_DRIFT_WINDOWS))
	return matchMask != 0

static func GetQRCodeURL(secret: String, accountName: String, issuer: String = "Shambleta") -> String:
	var encodedAccount: String = "%s:%s" % [issuer, accountName]
	return "otpauth://totp/%s?secret=%s&issuer=%s&digits=%d&period=%d" % [encodedAccount.replace(":", "%3A"), secret, issuer.replace(":", "%3A"), TOTP_DIGITS, TOTP_STEP_SECONDS]
