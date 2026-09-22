extends RefCounted
class_name SQLAccount

# Account, auth, consent, 2FA, LGPD erase

func AddAccount(username : String, password : String, email : String, tosVersion : String = "", privacyVersion : String = "", consentIp : String = "") -> bool:
	pass

func RemoveAccount(accountID : int) -> bool:
	pass

func GetCharacterIDsForAccount(accountID : int) -> Array:
	pass

func EraseAccount(accountID : int) -> bool:
	pass

func HasAccount(username : String) -> bool:
	pass

func ValidateAuthPassword(username : String, triedPassword : String) -> Peers.AccountData:
	pass

func RecordFailedLogin(accountID : int, prevAttempts : int) -> void:
	pass

func ResetFailedLogins(accountID : int) -> void:
	pass

func IsLockedOut(accountID : int) -> bool:
	pass

func HasEmail(email : String) -> bool:
	pass

func GetAccountIDByEmail(email : String) -> int:
	pass

func IsEmailVerified(accountID : int) -> bool:
	pass

func IsEmailVerifiedRaw(accountID : int) -> bool:
	pass

func SetEmailVerified(accountID : int, verified : bool = true) -> bool:
	pass

func DeleteAccountData(accountID : int) -> bool:
	pass

func UpdateAccount(accountID : int, platform : int = NetworkCommons.Platform.UNKNOWN) -> bool:
	pass

func IsConsentAccepted(accountID : int, tosVersion : String, privacyVersion : String) -> bool:
	pass

func SetConsentAccepted(accountID : int, tosVersion : String, privacyVersion : String, ip : String) -> bool:
	pass

func AddAuthToken(accountID : int, token : String, expiresAt : int) -> bool:
	pass

func ValidateAuthToken(token : String) -> Peers.AccountData:
	pass

func RefreshAuthToken(token : String, newExpiresAt : int) -> bool:
	pass

func RemoveAuthToken(token : String) -> bool:
	pass

func CleanExpiredTokens() -> int:
	pass

func GetAccountPermission(accountID : int) -> int:
	pass

func GetAccountEmail(accountID : int) -> String:
	pass

func CheckAccountPassword(accountID : int, password : String) -> bool:
	pass

func UpdateAccountPassword(accountID : int, newPassword : String) -> bool:
	pass

func RemoveAllAuthTokens(accountID : int) -> bool:
	pass

func GetTwoFactorSecret(accountID : int) -> String:
	pass

func IsTwoFactorEnabled(accountID : int) -> bool:
	pass

func SetTwoFactorSecret(accountID : int, secret : String) -> bool:
	pass

func SetTwoFactorEnabled(accountID : int, enabled : bool) -> bool:
	pass

func ConsumeTwoFactorToken(accountID : int, token : String) -> bool:
	pass

func CleanExpiredTwoFactorTokens() -> int:
	pass

func GetAccountID(username : String) -> int:
	pass

func GetAccountName(accountID : int) -> String:
	pass

func SetPermission(accountID : int, permission : int) -> bool:
	pass

func LogConsent(accountID : int, version : String, kind : String, ip : String) -> bool:
	pass

func GetConsent(accountID : int, kind : String) -> Dictionary:
	pass
