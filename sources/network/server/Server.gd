extends NetInterface
class_name NetServer

# Auth
func CreateAccount(accountName : String, password : String, email : String, rememberMe : bool, platform : int, consentAccepted : bool, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		err = NetworkCommons.CheckAuthInformation(accountName, password)
		if err == NetworkCommons.AuthError.ERR_OK:
			err = NetworkCommons.CheckEmailInformation(email)
		# SOM-IDLE LGPD: aceite afirmativo obrigatório antes de criar a conta. O
		# booleano carrega as três cláusulas exibidas no painel (Termos, Privacidade
		# e a declaração de idade do §24-11) — gravadas por versão em AddAccount.
		if err == NetworkCommons.AuthError.ERR_OK and not consentAccepted:
			err = NetworkCommons.AuthError.ERR_CONSENT_REQUIRED
		if err == NetworkCommons.AuthError.ERR_OK:
			# SOM-IDLE F4 follow-up: name and email collisions get distinct errors —
			# "account name not available" for a taken EMAIL was misleading QA.
			if Launcher.SQL.HasAccount(accountName):
				err = NetworkCommons.AuthError.ERR_NAME_AVAILABLE
			elif Launcher.SQL.HasEmail(email):
				err = NetworkCommons.AuthError.ERR_EMAIL_TAKEN
			elif not Launcher.SQL.AddAccount(accountName, password, email, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion, Peers.GetPeerIP(peerID)):
				err = NetworkCommons.AuthError.ERR_NAME_AVAILABLE
			else:
				Network.accounts_list_update.emit()
				var accountData : Peers.AccountData = Launcher.SQL.ValidateAuthPassword(accountName, password)
				if accountData:
					err = Peers.FinalizeLogin(peer, accountName, accountData, platform, rememberMe)
	Network.AuthError(err, peerID)

# SOM-IDLE LGPD art.18: o próprio jogador (logado) exercita o direito ao
# esquecimento. Anonimiza a conta no servidor (mantendo o ledger financeiro) e
# derruba a sessão. Precisa de sessão autenticada — nunca por conta deslogada.
func DeleteAccount(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.AuthError(NetworkCommons.AuthError.ERR_NO_PEER_DATA, peerID)
		return
	var accountID : int = peer.accountID
	if not Launcher.SQL.EraseAccount(accountID):
		Network.AuthError(NetworkCommons.AuthError.ERR_AUTH, peerID)
		return
	Util.PrintLog("Auth", "LGPD: account %d erased (data anonymized, ledger retained)" % accountID)
	Network.AccountErased(peerID)
	DisconnectAccount(peerID)

# SOM-IDLE (1d) CDC art.49: reembolso de gem (dono logado). EconomyService decide
# (janela 7d / gems não gastas / já reembolsado) e reverte o saldo + ledger.
func RequestRefund(idempotencyKey : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.RefundResult({"ok" = false, "reason" = "not_authenticated"}, peerID)
		return
	var result : Dictionary = Launcher.Economy.RequestGemRefund(accountID, idempotencyKey)
	if result.get("ok", false):
		Util.PrintLog("Economy", "LGPD/CDC: refund granted account %d key %s amount %d" % [accountID, idempotencyKey, int(result.get("amount", 0))])
	Network.RefundResult(result, peerID)

func LoginWithPassword(accountName : String, password : String, rememberMe : bool, platform : int, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		err = NetworkCommons.CheckAuthInformation(accountName, password)
		if err == NetworkCommons.AuthError.ERR_OK:
			# SOM-IDLE A1: lockout responde genérico (anti-enumeration).
			var accountID : int = Launcher.SQL.GetAccountID(accountName)
			if accountID != NetworkCommons.PeerUnknownID and Launcher.SQL.IsLockedOut(accountID):
				err = NetworkCommons.AuthError.ERR_AUTH
			else:
				var accountData : Peers.AccountData = Launcher.SQL.ValidateAuthPassword(accountName, password)
				if not accountData:
					err = NetworkCommons.AuthError.ERR_AUTH
				elif not Launcher.SQL.IsConsentAccepted(accountData.accountID, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion):
					err = NetworkCommons.AuthError.ERR_CONSENT_REQUIRED
				elif Launcher.SQL.IsTwoFactorEnabled(accountData.accountID):
					peer.pendingTwoFactorAccount = accountName
					peer.pendingTwoFactorAt = int(Time.get_unix_time_from_system())
					err = NetworkCommons.AuthError.ERR_2FA_REQUIRED
				else:
					err = Peers.FinalizeLogin(peer, accountName, accountData, platform, rememberMe)
	Network.AuthError(err, peerID)

func LoginWithTwoFactor(accountName : String, token : String, platform : int, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	# SOM-IDLE beta (T9): decisão no helper testável (binding + expiração +
	# consumo); aqui só finaliza o login no sucesso.
	err = Peers.ValidateTwoFactorChallenge(peer, accountName, token)
	if err == NetworkCommons.AuthError.ERR_OK:
		var accountID : int = Launcher.SQL.GetAccountID(accountName)
		var accountData : Peers.AccountData = Peers.AccountData.new(accountID, Launcher.SQL.GetAccountPermission(accountID))
		err = Peers.FinalizeLogin(peer, accountName, accountData, platform, false)
	Network.AuthError(err, peerID)

# SOM-IDLE M1: os quatro handlers abaixo são o lado do servidor do setup de 2FA —
# o facade declarava os RPCs mas o servidor não os implementava, então o painel
# nunca recebia resposta. Regras: o segredo é gerado AQUI e fica PENDENTE
# (two_factor_enabled = 0) até o usuário provar o código; queimar o código na
# verificação usa o mesmo anti-replay do login; desligar re-autentica pela senha e
# derruba os tokens de sessão (como ChangePassword). O estado volta por
# TwoFactorState, que é o canal do painel — AuthError fica no fluxo de login.
func SetupTwoFactor(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.TwoFactorState(false, "no_session", peerID)
		return
	if Launcher.SQL.IsTwoFactorEnabled(peer.accountID):
		Network.TwoFactorState(true, "already_enabled", peerID)
		return
	var secret : String = TwoFactorAuth.GenerateSecret()
	if not Launcher.SQL.SetTwoFactorSecret(peer.accountID, secret):
		Network.TwoFactorState(false, "setup_failed", peerID)
		return
	Network.TwoFactorSetupResult(TwoFactorAuth.GetQRCodeURL(secret, Launcher.SQL.GetAccountName(peer.accountID)), peerID)

func GetTwoFactorState(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.TwoFactorState(false, "no_session", peerID)
		return
	Network.TwoFactorState(Launcher.SQL.IsTwoFactorEnabled(peer.accountID), "", peerID)

func VerifyTwoFactorSetup(token : String, peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.TwoFactorState(false, "no_session", peerID)
		return
	if Launcher.SQL.IsTwoFactorEnabled(peer.accountID):
		Network.TwoFactorState(true, "already_enabled", peerID)
		return
	var secret : String = Launcher.SQL.GetTwoFactorSecret(peer.accountID)
	if secret.is_empty():
		Network.TwoFactorState(false, "setup_missing", peerID)
		return
	if token.length() != 6 or not token.is_valid_int() or not TwoFactorAuth.VerifyTOTP(secret, token):
		Network.TwoFactorState(false, "verify_failed", peerID)
		return
	if not Launcher.SQL.ConsumeTwoFactorToken(peer.accountID, token):
		Network.TwoFactorState(false, "verify_failed", peerID)
		return
	if not Launcher.SQL.SetTwoFactorEnabled(peer.accountID, true):
		Network.TwoFactorState(false, "setup_failed", peerID)
		return
	Util.PrintLog("Auth", "2FA: account %d enabled two-factor" % peer.accountID)
	Network.TwoFactorState(true, "setup_ok", peerID)

func DisableTwoFactor(password : String, peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.TwoFactorState(false, "no_session", peerID)
		return
	if not Launcher.SQL.IsTwoFactorEnabled(peer.accountID):
		Network.TwoFactorState(false, "already_off", peerID)
		return
	if not Launcher.SQL.CheckAccountPassword(peer.accountID, password):
		Network.TwoFactorState(true, "wrong_password", peerID)
		return
	Launcher.SQL.SetTwoFactorEnabled(peer.accountID, false)
	Launcher.SQL.SetTwoFactorSecret(peer.accountID, "")
	Launcher.SQL.RemoveAllAuthTokens(peer.accountID)
	Util.PrintLog("Auth", "2FA: account %d disabled two-factor (sessions revoked)" % peer.accountID)
	Network.TwoFactorState(false, "disabled", peerID)

func LoginWithToken(accountName : String, token : String, platform : int, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		var accountID : int = Launcher.SQL.GetAccountID(accountName)
		if accountID == NetworkCommons.PeerUnknownID:
			err = NetworkCommons.AuthError.ERR_TOKEN
		else:
			var ipAddress : String = Peers.GetPeerIP(peerID)
			var tokenHash : String = Hasher.HashPassword(token)
			var accountData : Peers.AccountData = Launcher.SQL.ValidateAuthToken(accountID, tokenHash, ipAddress)
			if not accountData:
				err = NetworkCommons.AuthError.ERR_TOKEN
			elif not Launcher.SQL.IsConsentAccepted(accountData.accountID, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion):
				err = NetworkCommons.AuthError.ERR_CONSENT_REQUIRED
			else:
				err = Peers.FinalizeLogin(peer, accountName, accountData, platform, false)
				Launcher.SQL.RefreshAuthToken(peer.accountID, ipAddress)
	Network.AuthError(err, peerID)

# SOM-IDLE LGPD: re-acceptance after an agreements bump. Verifies a credential
# exactly like the login RPCs do (password — with the same lockout predicate —
# or a remember-me token) and only then persists the CURRENT versions with the
# audit timestamp/IP and completes the original login (the final ERR_OK drives
# the client FSM through its normal path). Consent is never granted on a bare
# accountName. SetConsentAccepted re-estampa também a declaração de idade, que é a
# terceira cláusula do mesmo aceite (§24-11) — por isso aqui só vivem duas versões
# passadas: a vigente de idade é const do predicate.
func AcceptConsent(accountName : String, password : String, token : String, rememberMe : bool, platform : int, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		var accountData : Peers.AccountData = null
		var ipAddress : String = Peers.GetPeerIP(peerID)
		if not password.is_empty():
			err = NetworkCommons.CheckAuthInformation(accountName, password)
			if err == NetworkCommons.AuthError.ERR_OK:
				var accountID : int = Launcher.SQL.GetAccountID(accountName)
				if accountID != NetworkCommons.PeerUnknownID and Launcher.SQL.IsLockedOut(accountID):
					err = NetworkCommons.AuthError.ERR_AUTH
				else:
					accountData = Launcher.SQL.ValidateAuthPassword(accountName, password)
					if not accountData:
						err = NetworkCommons.AuthError.ERR_AUTH
		elif not token.is_empty():
			accountData = Launcher.SQL.ValidateAuthToken(Launcher.SQL.GetAccountID(accountName), Hasher.HashPassword(token), ipAddress)
			if not accountData:
				err = NetworkCommons.AuthError.ERR_TOKEN
		else:
			err = NetworkCommons.AuthError.ERR_AUTH
		if err == NetworkCommons.AuthError.ERR_OK and accountData:
			if not Launcher.SQL.SetConsentAccepted(accountData.accountID, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion, ipAddress):
				err = NetworkCommons.AuthError.ERR_AUTH
			else:
				Util.PrintLog("Auth", "LGPD: account %d accepted agreements %s/%s + age %s" % [accountData.accountID, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion, NetworkCommons.AgreementAgeVersion])
				if not password.is_empty():
					err = Peers.FinalizeLogin(peer, accountName, accountData, platform, rememberMe)
				else:
					err = Peers.FinalizeLogin(peer, accountName, accountData, platform, false)
					Launcher.SQL.RefreshAuthToken(peer.accountID, ipAddress)
	Network.AuthError(err, peerID)

func RequestPasswordReset(accountName : String, peerID : int):
	if not Launcher.Email or not Launcher.Email.IsConfigured():
		Network.AuthError(NetworkCommons.AuthError.ERR_RESET_UNAVAILABLE, peerID)
		return

	var accountID : int = Launcher.SQL.GetAccountID(accountName)
	if accountID != NetworkCommons.PeerUnknownID:
		if not Launcher.Email.HasRecentReset(accountID):
			var email : String = Launcher.SQL.GetAccountEmail(accountID)
			if not email.is_empty():
				var code : String = Hasher.GenerateResetCode()
				var codeHash : String = Hasher.HashPassword(code)
				Launcher.Email.CreateReset(accountID, codeHash)
				Launcher.Email.SendPasswordResetEmail(email, code)

	Network.AuthError(NetworkCommons.AuthError.ERR_RESET_EMAIL_SENT, peerID)

func ConfirmPasswordReset(accountName : String, code : String, newPassword : String, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_RESET_INVALID_CODE

	var passwordErr : NetworkCommons.AuthError = NetworkCommons.CheckPasswordInformation(newPassword)
	if passwordErr == NetworkCommons.AuthError.ERR_OK and NetworkCommons.CheckResetCode(code):
		var accountID : int = Launcher.SQL.GetAccountID(accountName)
		if accountID != NetworkCommons.PeerUnknownID:
			var codeHash : String = Hasher.HashPassword(code)
			if Launcher.Email.ValidateReset(accountID, codeHash):
				if Launcher.SQL.Transaction(func() -> bool:
					Launcher.SQL.UpdateAccountPassword(accountID, newPassword)
					Launcher.Email.RemoveReset(accountID)
					Launcher.SQL.RemoveAllAuthTokens(accountID)
					return true):
					err = NetworkCommons.AuthError.ERR_RESET_PASSWORD_UPDATED

	Network.AuthError(err, peerID)

func ChangePassword(currentPassword : String, newPassword : String, peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer or peer.accountID == NetworkCommons.PeerUnknownID:
		Network.AuthError(NetworkCommons.AuthError.ERR_NO_PEER_DATA, peerID)
		return

	var passwordErr : NetworkCommons.AuthError = NetworkCommons.CheckPasswordInformation(newPassword)
	if passwordErr != NetworkCommons.AuthError.ERR_OK:
		Network.AuthError(NetworkCommons.AuthError.ERR_PASSWORD_CHANGE_WRONG, peerID)
		return

	if not Launcher.SQL.CheckAccountPassword(peer.accountID, currentPassword):
		Network.AuthError(NetworkCommons.AuthError.ERR_PASSWORD_CHANGE_WRONG, peerID)
		return

	Launcher.SQL.UpdateAccountPassword(peer.accountID, newPassword)
	Launcher.SQL.RemoveAllAuthTokens(peer.accountID)
	Network.AuthError(NetworkCommons.AuthError.ERR_PASSWORD_CHANGE_OK, peerID)

func DisconnectAccount(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer:
		if peer.accountID != NetworkCommons.PeerUnknownID:
			Launcher.SQL.UpdateAccount(peer.accountID)
			peer.SetAccount(Peers.DisconnectedAccount)
		if peer.characterID != NetworkCommons.PeerUnknownID:
			DisconnectCharacter(peerID)

# Character
func CreateCharacter(charName : String, traits : Dictionary, attributes : Dictionary, peerID : int):
	var err : NetworkCommons.CharacterError = NetworkCommons.CharacterError.ERR_OK
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		err = NetworkCommons.CharacterError.ERR_NO_ACCOUNT_ID
	else:
		traits.merge(ActorCommons.DefaultTraits)
		# Hero class viaja em traits (sem mudar a assinatura do RPC); sai do
		# dict antes do AddCharacter (tabela trait tem colunas fixas) e vai
		# para character.class_id (migration 035). Classe é obrigatória.
		var heroClass : String = str(traits.get("hero_class", ""))
		traits.erase("hero_class")
		# SOM-IDLE C1: CheckCharacterInformation só era chamada na GUI, i.e. um
		# cliente adaptado gravava nick de qualquer tamanho (o nick é renderizado
		# no chat de quem recebe). CreateAccount já valida no servidor; daqui
		# ninguém escapa.
		var nameErr : NetworkCommons.CharacterError = NetworkCommons.CheckCharacterInformation(charName)
		if nameErr != NetworkCommons.CharacterError.ERR_OK:
			err = nameErr
		elif Launcher.SQL.HasCharacter(charName):
			err = NetworkCommons.CharacterError.ERR_NAME_AVAILABLE
		elif Launcher.SQL.GetCharacters(accountID).size() >= ActorCommons.MaxCharacterCount:
			err = NetworkCommons.CharacterError.ERR_SLOT_AVAILABLE
		elif not ActorCommons.CheckTraits(traits) or not ActorCommons.CheckAttributes(attributes):
			err = NetworkCommons.CharacterError.ERR_MISSING_PARAMS
		elif not ClassBonus.IsValidClass(heroClass):
			err = NetworkCommons.CharacterError.ERR_MISSING_PARAMS
		elif not Launcher.SQL.AddCharacter(accountID, charName, ActorCommons.DefaultStats, traits, attributes):
			err = NetworkCommons.CharacterError.ERR_NAME_AVAILABLE
		else:
			var characterID : int = Launcher.SQL.GetCharacterID(accountID, charName)
			if characterID == NetworkCommons.PeerUnknownID:
				err = NetworkCommons.CharacterError.ERR_NO_CHARACTER_ID
			elif not Launcher.SQL.SetCharacterClass(characterID, heroClass):
				err = NetworkCommons.CharacterError.ERR_NO_CHARACTER_ID
			else:
				Network.characters_list_update.emit()
				for itemData in ActorCommons.DefaultInventory:
					Launcher.SQL.AddItem(characterID, itemData.get("item_id", DB.UnknownHash), itemData.get("customfield", ""), itemData.get("count", 1))
				for skillData in ActorCommons.DefaultSkills:
					Launcher.SQL.SetSkill(characterID, skillData.get("skill_id", DB.UnknownHash), skillData.get("level", 1))
				# Kit da classe: arma inicial + primeira skill exclusiva.
				var classEntry : Dictionary = ClassBonus.GetClass(heroClass)
				var starterWeapon : String = str(classEntry.get("starter_weapon", ""))
				if not starterWeapon.is_empty() and DB.HasCellHash(starterWeapon):
					Launcher.SQL.AddItem(characterID, DB.GetCellHash(starterWeapon), "", 1)
				var starterSkill : String = str(classEntry.get("starter_skill", ""))
				if not starterSkill.is_empty() and DB.HasCellHash(starterSkill):
					Launcher.SQL.SetSkill(characterID, DB.GetCellHash(starterSkill), 1)

				Network.CharacterInfo(Launcher.SQL.GetCharacterInfo(characterID), Launcher.SQL.GetEquipment(characterID), peerID)

	Network.CharacterError(err, peerID)
	return err

func DeleteCharacter(charName : String, peerID : int):
	var err : NetworkCommons.CharacterError = NetworkCommons.CharacterError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer.accountID == NetworkCommons.PeerUnknownID:
		err = NetworkCommons.CharacterError.ERR_NO_ACCOUNT_ID
	elif peer.characterID != NetworkCommons.PeerUnknownID:
		err = NetworkCommons.CharacterError.ERR_ALREADY_LOGGED_IN
	else:
		var charID : int = Launcher.SQL.GetCharacterID(peer.accountID, charName)
		if charID == NetworkCommons.PeerUnknownID:
			err = NetworkCommons.CharacterError.ERR_NAME_VALID
		elif not Launcher.SQL.RemoveCharacter(charID):
			err = NetworkCommons.CharacterError.ERR_NAME_AVAILABLE
		else:
			Network.characters_list_update.emit()

	Network.CharacterError(err, peerID)
	return err

func ConnectCharacter(nickname : String, peerID : int):
	var err : NetworkCommons.CharacterError = NetworkCommons.CharacterError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)

	if not peer:
		err = NetworkCommons.CharacterError.ERR_NO_PEER_DATA
	elif peer.accountID == NetworkCommons.PeerUnknownID:
		err = NetworkCommons.CharacterError.ERR_NO_ACCOUNT_ID
	else:
		if Peers.GetCharacter(peerID) != NetworkCommons.PeerUnknownID:
			err = NetworkCommons.CharacterError.ERR_ALREADY_LOGGED_IN
		else:
			peer.SetCharacter(Launcher.SQL.GetCharacterID(peer.accountID, nickname))
			if peer.characterID == NetworkCommons.PeerUnknownID:
				err = NetworkCommons.CharacterError.ERR_NO_CHARACTER_ID
			else:
				# SOM-IDLE: F2 — settle offline gains BEFORE reading charInfo so the
				# agent loads already including xp/gold/drops earned while away.
				OfflineSettle.SettlePending(peer.characterID)
				var charInfo : Dictionary = Launcher.SQL.GetCharacterInfo(peer.characterID)
				var spawnLocation : SpawnObject = PlayerAgent.GetSpawnFromData(charInfo)
				var agent : PlayerAgent = WorldAgent.CreateAgent(spawnLocation, 0, nickname)
				if agent:
					agent.peerID = peerID
					agent.lastActivityMsec = Time.get_ticks_msec()
					agent.tormentLevel = Launcher.SQL.GetTormentLevel(peer.characterID)
					peer.SetAgent(agent.get_rid().get_id())
					agent.SetCharacterInfo(charInfo, peer.characterID)
					Launcher.SQL.CharacterLogin(peer.characterID)
					# SOM-IDLE: F3 — seed the cached power score on every connect
					Launcher.SQL.UpdatePowerScore(peer.characterID, Formula.GetPowerScore(agent.stat))
					# SOM-IDLE idle-first: login é farmando — fresh char entra na
					# zona 1, char zonado retoma a sessão da zona salva.
					IdlePolicyService.AutoFarmOnLogin(peer.characterID, agent)

					var ip : String = Peers.GetPeerIP(peerID)
					Util.PrintLog("Server", "Player connected: %s (%d) via %s from %s" % [nickname, peerID, Peers.GetTransportName(Peers.GetTransport(peerID)), ip if not ip.is_empty() else "unavailable"])
					Network.online_player_connected.emit(nickname)

	Network.CharacterError(err, peerID)

func DisconnectCharacter(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer:
		var player : PlayerAgent = Peers.GetAgent(peerID)
		if player:
			var playerName : String = player.nick
			var ip : String = Peers.GetPeerIP(peerID)
			Util.PrintLog("Server", "Player disconnected: %s (%d) via %s from %s" % [playerName, peerID, Peers.GetTransportName(Peers.GetTransport(peerID)), ip if not ip.is_empty() else "unavailable"])

			# SOM-IDLE: F2 — persist session efficiency before the character row
			# is refreshed; the settle at next login converts it into gains.
			if player.idlePolicy:
				Launcher.SQL.PersistSessionEfficiency(peer.characterID, player.idlePolicy.ComputeSessionEfficiency())
				player.idlePolicy.Halt()
				player.idlePolicy = null

			# SOM-IDLE: F3 — cache the live power score for the offline leaderboard
			Launcher.SQL.UpdatePowerScore(peer.characterID, Formula.GetPowerScore(player.stat))

			Launcher.SQL.RefreshCharacter(player)
			WorldAgent.RemoveAgent(player)
			peer.SetAgent(NetworkCommons.PeerUnknownID)
			Network.online_player_disconnected.emit(playerName)
		peer.SetCharacter(NetworkCommons.PeerUnknownID)

func RequestOnlineList(peerID : int):
	Network.RefreshOnlineList(OnlineList.GetPlayerNames(), peerID)

# SOM-IDLE: F2 idle-spike handlers (TECH_SPEC_CORE §5)
func SetFormation(slot : int, charID : int, skillLoadout : PackedInt64Array, autoPotionPct : float, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID or slot < 0 or slot >= IdlePolicyService.MaxFormationSlots:
		Network.FarmZoneFeedback(0, false, "invalid_formation", peerID)
		return

	# A player may only register characters from its own account
	var ownerAccount : int = Launcher.SQL.GetAccountIDForCharacter(charID)
	if charID != 0 and ownerAccount != accountID:
		Network.FarmZoneFeedback(0, false, "not_owner", peerID)
		return

	var loadout : Array[int] = []
	for skillID in skillLoadout:
		loadout.append(int(skillID))
	var clampedPct : float = clampf(autoPotionPct, 0.0, 100.0)
	Launcher.SQL.SaveFormation(accountID, slot, charID, loadout, clampedPct)
	Network.FarmZoneFeedback(0, true, "formation_saved", peerID)

func SetFarmZone(zoneID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if charID == NetworkCommons.PeerUnknownID or player == null:
		Network.FarmZoneFeedback(zoneID, false, "not_logged_in", peerID)
		return

	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		Network.FarmZoneFeedback(zoneID, false, "zone_unavailable", peerID)
		return

	# Spike gate: zone 1 is open; deeper tiers require the power score (§2)
	if zone.tier > 1 and Formula.GetPowerScore(player.stat) < zone.minPower:
		Network.FarmZoneFeedback(zoneID, false, "power_too_low", peerID)
		return

	Launcher.SQL.SetCharacterFarmZone(charID, zoneID)
	IdlePolicyService.StartIdleSession(player, zoneID)
	Network.FarmZoneFeedback(zoneID, true, "farming", peerID)

func ClaimOfflineSettle(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.AFKReport({}, peerID)
		return
	if not Peers.Footprint(peerID, "claim_settle", 60):
		Network.AFKReport({}, peerID)
		return

	var report : Dictionary = OfflineSettle.SettlePending(charID)
	if report.is_empty():
		report = OfflineSettle.BuildReport(charID).to_dictionary()
	Network.AFKReport(report, peerID)

func GetAFKReport(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.AFKReport({}, peerID)
		return
	Network.AFKReport(OfflineSettle.BuildReport(charID).to_dictionary(), peerID)

func GetSeasonPass(peerID : int):
	# Fase C: estado real do passe (era stub fixo em {active:false}).
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.SeasonPassState({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.SeasonPassState(Launcher.Economy.GetSeasonPass(accountID), peerID)

func ClaimPassReward(level : int, track : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.PassFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.ClaimPassReward(accountID, charID, level, track)
	Network.PassFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.SeasonPassState(Launcher.Economy.GetSeasonPass(accountID), peerID)
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

# Fase C: compra do premium = intent do companion (sku pass.s1, R$ 24,90).
# Follow-up Deluxe (BATTLE_PASS_S1 §4): sku pass.s1.deluxe (R$ 44,90 —
# preço sugerido no doc, dono confirma).
func BuyPass(tier : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.PassFeedback(false, "not_logged_in", peerID)
		return
	if tier != "standard" and tier != "deluxe":
		Network.PassFeedback(false, "bad_tier", peerID)
		return
	Network.CheckoutIntent(Launcher.Economy.GetCheckoutIntent(accountID, "pass.s1" if tier == "standard" else "pass.s1.deluxe"), peerID)

func SkipPassLevel(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.PassFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.SkipPassLevel(accountID)
	Network.PassFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.SeasonPassState(Launcher.Economy.GetSeasonPass(accountID), peerID)
		var charID : int = Peers.GetCharacter(peerID)
		if charID != NetworkCommons.PeerUnknownID:
			Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func ClaimMission(missionID : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.PassFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.ClaimMission(accountID, missionID)
	Network.PassFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.SeasonPassState(Launcher.Economy.GetSeasonPass(accountID), peerID)

# Fase D (cosméticos): leitura, equipar/desequipar e compra avulsa em gems.
func GetCosmetics(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.Cosmetics({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.Cosmetics(Launcher.Economy.GetCosmetics(accountID), peerID)

func EquipCosmetic(cosmeticID : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CosmeticFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.EquipCosmetic(accountID, cosmeticID)
	Network.CosmeticFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.Cosmetics(Launcher.Economy.GetCosmetics(accountID), peerID)

func UnequipCosmetic(slot : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CosmeticFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.UnequipCosmetic(accountID, slot)
	Network.CosmeticFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.Cosmetics(Launcher.Economy.GetCosmetics(accountID), peerID)

func BuyCosmetic(cosmeticID : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.CosmeticFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyCosmetic(accountID, charID, cosmeticID)
	Network.CosmeticFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.Cosmetics(Launcher.Economy.GetCosmetics(accountID), peerID)
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

# Hub Atividades: mesmos backends dos comandos, resultados no chat + pushes.
func GetAchievements(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.AchievementsState([], peerID)
		return
	Network.AchievementsState(Launcher.Economy.GetAchievements(accountID), peerID)

func ClaimAchievement(achievementID : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Claim failed (not_logged_in)", peerID)
		return
	var result : Dictionary = Launcher.Economy.ClaimAchievement(accountID, achievementID)
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Claim failed (%s)" % str(result.get("reason", "?")), peerID)
		return
	var extra : String = " + %s" % EconomyService.CosmeticLabel(str(result.get("cosmetic", ""))) if not str(result.get("cosmetic", "")).is_empty() else ""
	Network.CommandFeedback("Achievement claimed: +%d gems%s!" % [int(result.get("gems", 0)), extra], peerID)
	Network.AchievementsState(Launcher.Economy.GetAchievements(accountID), peerID)
	if Peers.GetCharacter(peerID) != NetworkCommons.PeerUnknownID:
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, Peers.GetCharacter(peerID)), peerID)

func GetTorment(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.TormentState({}, peerID)
		return
	Network.TormentState(_TormentState(charID), peerID)

func _TormentState(charID : int) -> Dictionary:
	var level : int = Launcher.SQL.GetTormentLevel(charID)
	var tmax : int = Launcher.SQL.GetTormentMax(charID)
	return {"ok" = true, "level" = level, "max" = tmax,
		"reward" = Formula.TormentRewardMult(level), "mob_hp" = Formula.TormentMobHpFactor(level), "mob_dmg" = Formula.TormentMobDmgFactor(level)}

func SetTorment(level : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Torment failed (not_logged_in)", peerID)
		return
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var result : Dictionary = Launcher.Economy.SetTorment(charID, player, level)
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Torment locked (%s, max %d)" % [str(result.get("reason", "?")), Launcher.SQL.GetTormentMax(charID)], peerID)
		return
	Network.CommandFeedback("Torment %d active" % int(result.get("level", 0)), peerID)
	Network.TormentState(_TormentState(charID), peerID)

func RunBossRush(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Rush failed (not_logged_in)", peerID)
		return
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var result : Dictionary = Launcher.Economy.RunBossRush(charID, player)
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Rush failed (%s)" % str(result.get("reason", "?")), peerID)
		return
	Network.CommandFeedback("Rush: %d wins, +%d xp, +%d gold, %d chests" % [int(result.get("wins", 0)), int(result.get("xp", 0)), int(result.get("gold", 0)), int(result.get("chests", 0))], peerID)
	_pushPostFight(charID, peerID)

func BuyBossKey(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Key buy failed (not_logged_in)", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyBossKey(charID)
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Key buy failed (%s)" % str(result.get("reason", "?")), peerID)
		return
	Network.CommandFeedback("Boss key bought (%d keys)" % int(result.get("keys", 0)), peerID)
	_pushPostFight(charID, peerID)

func _pushPostFight(charID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if player:
		Network.BossState(Launcher.Economy.GetBossState(charID, player.stat.level), peerID)
	if accountID != NetworkCommons.PeerUnknownID:
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)
		var inv : PlayerAgent = Peers.GetAgent(peerID)
		if inv and inv.inventory:
			Network.RefreshInventory(inv.inventory.ExportInventory(), peerID)

func CorruptItem(itemID : int, peerID : int):
	_AltarAction("corrupt", itemID, peerID)

func CubeUpcycle(itemID : int, peerID : int):
	_AltarAction("cube", itemID, peerID)

func SalvageItem(itemID : int, peerID : int):
	_AltarAction("salvage", itemID, peerID)

func _AltarAction(kind : String, itemID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Altar failed (not_logged_in)", peerID)
		return
	var result : Dictionary = {}
	match kind:
		"corrupt":
			result = Launcher.Economy.CorruptItem(charID, itemID)
		"cube":
			result = Launcher.Economy.CubeUpcycle(charID, itemID)
		_:
			result = Launcher.Economy.SalvageItem(charID, itemID)
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Altar failed (%s)" % str(result.get("reason", "?")), peerID)
		return
	match kind:
		"corrupt":
			match str(result.get("outcome", "?")):
				"brick":
					Network.CommandFeedback("The altar consumes the item. Nothing remains.", peerID)
				"sealed":
					Network.CommandFeedback("Sealed: soulbound forever.", peerID)
				"blessed":
					Network.CommandFeedback("Blessed: +%d essence." % int(result.get("essence", 0)), peerID)
				_:
					Network.CommandFeedback("EXALTED: %s!" % str(result.get("prize_name", "?")), peerID)
		"cube":
			Network.CommandFeedback("Cubed into: %s!" % str(result.get("prize_name", "?")), peerID)
		_:
			if int(result.get("essence", 0)) > 0:
				Network.CommandFeedback("Salvaged: +%d gold, +%d essence." % [int(result.get("gold", 0)), int(result.get("essence", 0))], peerID)
			else:
				Network.CommandFeedback("Salvaged: +%d gold." % int(result.get("gold", 0)), peerID)
	_pushPostFight(charID, peerID)

# Fase E (rewarded ads): arma 2× do AFK, baú bônus, reroll grátis e chave de
# boss. Sucessos empurram o estado fresco da janela correspondente.
func WatchAd(placement : String, token : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.AdFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.WatchAd(accountID, charID, placement, token)
	Network.AdFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)) and placement == EconomyCatalog.AD_AFK2X:
		Network.AFKReport(OfflineSettle.BuildReport(charID).to_dictionary(), peerID)

func ClaimAdChest(token : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.AdFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.ClaimAdChest(accountID, charID, token)
	Network.AdFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func RerollDailyShopAd(token : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.AdFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.RerollDailyShopAd(accountID, token)
	Network.AdFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.DailyShop(result, peerID)

func ClaimAdBossKey(token : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.AdFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.ClaimAdBossKey(accountID, charID, token)
	Network.AdFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		var player : PlayerAgent = Peers.GetAgent(peerID)
		var level : int = player.stat.level if player != null else 1
		Network.BossState(Launcher.Economy.GetBossState(charID, level), peerID)

# Fase F (guild premium + torneios).
func GetGuildState(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.GuildState({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

func LevelUpGuildFast(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.LevelUpGuildFast(accountID, charID)
	Network.GuildFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func BuyVaultSlots(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyVaultSlots(accountID, charID)
	Network.GuildFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func GetTournaments(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.Tournaments({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.Tournaments(Launcher.Economy.GetTournaments(accountID), peerID)

func EnterTournament(tournamentID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.TournamentFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.EnterTournament(accountID, charID, tournamentID)
	Network.TournamentFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)):
		Network.Tournaments(Launcher.Economy.GetTournaments(accountID), peerID)

# SOM-IDLE: F3 — VIP window state for the requesting account
func GetVIPState(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.VIPState({"active": false, "until": 0}, peerID)
		return
	var until : int = Launcher.SQL.GetVIPUntil(accountID)
	var now : int = SQLCommons.Timestamp()
	Network.VIPState({"active": until > now, "until": until, "mods": OfflineSettle.VIPModFactor if until > now else 1.0}, peerID)

# SOM-IDLE: F3 — global power-score leaderboard (cached column, offline-friendly)
# Fase D: enriquece com o título equipado (rótulo via catálogo, sem query extra
# além do JOIN já embutido em SQL.GetLeaderboard).
func GetLeaderboard(peerID : int):
	var entries : Array = Launcher.SQL.GetLeaderboard(50)
	for e in entries:
		(e as Dictionary)["title"] = Launcher.Economy.CosmeticLabel(str((e as Dictionary).get("title_cosmetic", "")))
	Network.Leaderboard(entries, peerID)

# SOM-IDLE: F3 — active formation slot selector (0..MaxFormationSlots-1)
func SetFormationSlot(slot : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID or slot < 0 or slot >= IdlePolicyService.MaxFormationSlots:
		Network.FarmZoneFeedback(0, false, "invalid_formation_slot", peerID)
		return
	Launcher.SQL.SetCharacterFormationSlot(charID, slot)
	Network.FarmZoneFeedback(0, true, "formation_slot_saved", peerID)

# SOM-IDLE beta GUI — handlers das janelas de economia. Toda ação devolve
# EconomyState fresco depois de responder (ordem reliable: feedback → estado).
func GetEconomyState(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.EconomyState({}, peerID)
		return
	# Fase C: visita à loja alimenta a missão substituta do rewarded ad (D8).
	Launcher.Telemetry.Record("shop_visit", accountID, charID)
	Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func OpenChest(chestID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	var result : Dictionary = {}
	if charID != NetworkCommons.PeerUnknownID and accountID != NetworkCommons.PeerUnknownID:
		if not Peers.Footprint(peerID, "open_chest", 60):
			Network.ChestOpened({}, peerID)
			return
		result = Launcher.Economy.OpenChest(charID, chestID)
		if not result.is_empty():
			var cell : ItemCell = DB.ItemsDB.get(int(result["item_id"]), null)
			result["item_name"] = cell._name if cell != null else "?"
			Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)
	Network.ChestOpened(result, peerID)

func BuyChests(count : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.ShopFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyChests(accountID, charID, count)
	if result.is_empty():
		Network.ShopFeedback(false, "rejected (gems or count 1..%d)" % EconomyCatalog.MaxChestsPerPurchase, peerID)
		return
	Network.ShopFeedback(true, "%d chests for %d gems" % [int(result["count"]), int(result["cost"])], peerID)
	Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func PurchaseVIP(tier : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ShopFeedback(false, "not_logged_in", peerID)
		return
	if not Launcher.Economy.PurchaseVIP(accountID, tier):
		Network.ShopFeedback(false, "rejected (tier 1|2 or insufficient gems)", peerID)
		return
	var charID : int = Peers.GetCharacter(peerID)
	Network.ShopFeedback(true, "VIP tier %d purchased" % tier, peerID)
	if charID != NetworkCommons.PeerUnknownID:
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

# Fase A (checkout sandbox): intenção de compra p/ um SKU do catálogo.
func GetCheckoutIntent(sku : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CheckoutIntent({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.CheckoutIntent(Launcher.Economy.GetCheckoutIntent(accountID, sku), peerID)

# Fase B (loja diária): leitura, compra e reroll. Compras devolvem
# ShopFeedback + EconomyState fresco (mesmo padrão das demais ações).
func GetDailyShop(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.DailyShop({"ok": false, "reason": "not_logged_in"}, peerID)
		return
	Network.DailyShop(Launcher.Economy.GetDailyShop(accountID), peerID)

# R1 referral: conta sempre da sessão (anti cross-account, padrão do arquivo).
func GetReferralState(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ReferralState({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	Network.ReferralState(Launcher.Economy.GetReferralState(accountID), peerID)

func SetReferralCode(code : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ReferralState({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	Network.ReferralState(Launcher.Economy.SetReferralCode(accountID, code), peerID)

func BuyDailyOffer(offerID : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.ShopFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyDailyOffer(accountID, charID, offerID)
	if not bool(result.get("ok", false)):
		Network.ShopFeedback(false, "daily offer rejected (%s)" % str(result.get("reason", "?")), peerID)
		return
	Network.ShopFeedback(true, "daily offer %s for %d gems" % [offerID, int(result.get("cost", 0))], peerID)
	Network.DailyShop(Launcher.Economy.GetDailyShop(accountID), peerID)
	Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

# R2 vendor gold: conta/char sempre da sessão.
func BuyVendorOffer(offerID : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.ShopFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyVendorOffer(accountID, charID, offerID)
	if not bool(result.get("ok", false)):
		Network.ShopFeedback(false, "vendor rejected (%s)" % str(result.get("reason", "?")), peerID)
		return
	Network.ShopFeedback(true, "vendor %s for %d gold" % [offerID, int(result.get("cost", 0))], peerID)
	Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

# R3 live events: estado de eventos ativos (conta da sessão).
func GetActiveEvents(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ActiveEvents({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	Network.ActiveEvents(Launcher.Economy.GetActiveEventsState(accountID), peerID)

# R4 async arena: defesa salva pelo char da sessão.
func ArenaSetDefense(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.ArenaDefenseResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	var result : Dictionary = Launcher.Economy.ArenaSetDefense(charID)
	Network.ArenaDefenseResult(result, peerID)
	Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(accountID), peerID)

# R4 async arena: ataque por ticket (conta/char da sessão vs defensor).
func ArenaAttack(defenderAccountID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.ArenaAttackResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	if defenderAccountID == accountID:
		Network.ArenaAttackResult({"ok" = false, "reason" = "self_attack"}, peerID)
		return
	var result : Dictionary = Launcher.Economy.ArenaAttack(charID, defenderAccountID)
	Network.ArenaAttackResult(result, peerID)
	Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(accountID), peerID)
	if bool(result.get("ok", false)):
		var defenderAcct : int = defenderAccountID
		Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(defenderAcct), defenderAcct)

# R4 async arena: board da conta da sessão.
func ArenaBoard(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ArenaBoardResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(accountID), peerID)

func RerollDailyShop(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ShopFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.RerollDailyShop(accountID)
	if not bool(result.get("ok", false)):
		Network.ShopFeedback(false, "reroll rejected (%s)" % str(result.get("reason", "?")), peerID)
		return
	Network.DailyShop(result, peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if charID != NetworkCommons.PeerUnknownID:
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func GetSeasonBoards(peerID : int):
	Network.SeasonBoards(Launcher.Economy.GetSeasonBoardsState(10), peerID)

# SOM-IDLE: boss-key ladder handlers.
func GetBossState(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.BossState({}, peerID)
		return
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var level : int = player.stat.level if player != null else 1
	Network.BossState(Launcher.Economy.GetBossState(charID, level), peerID)

func ChallengeBoss(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.BossResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var result : Dictionary = Launcher.Economy.ChallengeBoss(charID, player)
	Network.BossResult(result, peerID)
	if bool(result.get("ok", false)):
		Network.BossState(Launcher.Economy.GetBossState(charID, player.stat.level), peerID)

# SOM-IDLE: toque do jogador na janela de interrupt do duelo (2026-09-23).
# Rate-limit já está no facade (200ms); sem sessão de duelo é no-op silencioso.
func BossInterrupt(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player == null or not is_instance_valid(player) or player.idlePolicy == null:
		return
	player.idlePolicy.RequestBossInterrupt()

# SOM-IDLE: rebirth (B+C). Estado/cache/mutação vivem em EconomyService; aqui só
# o roteamento peers→charID com o mesmo formato do ladder de bosses.
func GetRebirthState(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		return
	Network.RebirthState(Launcher.Economy.GetRebirthState(charID), peerID)

# SOM-IDLE Fase H: criação de itens — roteamento peers→charID/accountID para a
# camada de economia (validação de orçamento, taxa, nome, capa diária).
func SubmitCraft(slot : int, baseItemHash : int, name : String, modifiers : Dictionary, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.CraftSubmitFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.SubmitCraft(charID, accountID, slot, baseItemHash, name, modifiers)
	Network.CraftSubmitFeedback(bool(result.get("ok", false)), str(result.get("reason", "rejected")), peerID)
	if bool(result.get("ok", false)):
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func RebirthRequest(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.RebirthResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	var player : PlayerAgent = Peers.GetAgent(peerID)
	var result : Dictionary = Launcher.Economy.Rebirth(charID, player)
	Network.RebirthResult(result, peerID)
	if bool(result.get("ok", false)):
		Network.RebirthState(Launcher.Economy.GetRebirthState(charID), peerID)

func BuyRebirthUpgrade(upgradeID : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.RebirthResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyRebirthUpgrade(charID, upgradeID)
	Network.RebirthResult(result, peerID)
	Network.RebirthState(Launcher.Economy.GetRebirthState(charID), peerID)

func CharacterListing(peerID : int):
	var err : NetworkCommons.CharacterError = NetworkCommons.CharacterError.ERR_OK
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		err = NetworkCommons.CharacterError.ERR_NO_ACCOUNT_ID
	else:
		var characterIDs : PackedInt64Array = Launcher.SQL.GetCharacters(accountID)
		if characterIDs.is_empty():
			err = NetworkCommons.CharacterError.ERR_EMPTY_ACCOUNT
		else:
			for characterID in characterIDs:
				var charInfo : Dictionary = Launcher.SQL.GetCharacterInfo(characterID)
				var charEquipment : Dictionary = Launcher.SQL.GetEquipment(characterID)
				Network.CharacterInfo(charInfo, charEquipment, peerID)
	Network.CharacterError(err, peerID)

# Navigation
func SetClickPos(pos : Vector2, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player and not player.ownScript:
		IdlePolicyService.NoteActivity(player)
		player.SetRelativeMode(false, Vector2.ZERO)
		player.WalkToward(pos)

func SetMovePos(direction : Vector2, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player and not player.ownScript:
		IdlePolicyService.NoteActivity(player)
		player.SetRelativeMode(true, direction.normalized())

func ClearNavigation(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		IdlePolicyService.NoteActivity(player)
		player.SetRelativeMode(false, Vector2.ZERO)

func SetViewportSize(halfWidth : float, halfHeight : float, peerID : int):
	var agent : PlayerAgent = Peers.GetAgent(peerID)
	if agent:
		agent.visibilityHalfSize = Vector2(
			minf(halfWidth + NetworkCommons.VisibilityBorder, NetworkCommons.MaxVisibilityHalfWidth),
			minf(halfHeight + NetworkCommons.VisibilityBorder, NetworkCommons.MaxVisibilityHalfHeight)
		)

# Triggers
func TriggerSit(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		player.SetState(ActorCommons.State.SIT)

func TriggerRespawn(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player is PlayerAgent:
		player.Respawn()

func TriggerEmote(emoteID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player is PlayerAgent:
		Network.NotifyNeighbours(player, "Emote", [player.get_rid().get_id(), emoteID])

func TriggerChat(channelName : String, text : String, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		# SOM-IDLE C1: o texto segue pelo caminho de disseminação (vizinhos,
		# global, Discord, whisper) sem passar por nenhum cliente antes, então é
		# aqui que ele ganha teto de tamanho; vazio depois do corte não é frase.
		var message : String = NetworkCommons.ClipChat(text)
		if message.is_empty():
			return null
		# SOM-IDLE C1c: o mute é cobrado aqui, no envio. Filtrar no recebimento é
		# cosmético — quem recebe não é autoridade sobre si mesmo, e um cliente
		# modificado continua lendo (e falando) normalmente.
		var accountID : int = Peers.GetAccount(peerID)
		var silenced : String = ChatModeration.CanSpeak(accountID)
		if not silenced.is_empty():
			Network.ChatSystem(channelName, silenced, peerID)
			return null
		ChatModeration.Note(accountID, player.nick, channelName, message)
		if channelName == str(GUICommons.ChatChannel.LOCAL):
			Network.NotifyNeighbours(player, "ChatPlayer", [str(GUICommons.ChatChannel.LOCAL), player.nick, message, player.get_rid().get_id()])
		elif channelName == str(GUICommons.ChatChannel.GLOBAL):
			Network.NotifyGlobal("ChatPlayer", [str(GUICommons.ChatChannel.GLOBAL), player.nick, message, player.get_rid().get_id()])
			if Launcher.Discord:
				Launcher.Discord.SendToDiscord(player.nick, message)
		else:
			var target : PlayerAgent = Launcher.World.GetGlobalPlayer(channelName)
			if not target:
				Network.ChatSystem(channelName, "Player '%s' is no longer online" % channelName, peerID)
			else:
				Network.ChatPlayer(player.nick, player.nick, message, player.get_rid().get_id(), target.peerID)
				Network.ChatPlayer(target.nick, player.nick, message, player.get_rid().get_id(), player.peerID)

func TriggerChoice(choiceID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player and player.ownScript:
		player.ownScript.InteractChoice(choiceID)

func TriggerNextContext(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player and player.ownScript and player.ownScript.npc:
		player.ownScript.npc.Interact(player)

func TriggerCloseContext(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		NpcCommons.TryCloseContext(player)

func TriggerInteract(targetRID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		IdlePolicyService.NoteActivity(player)
		var target : BaseAgent = WorldAgent.GetAgent(targetRID)
		if target:
			target.Interact(player)

func TriggerExplore(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player is PlayerAgent:
		player.Explore()

func TriggerSkill(targetRID : int, skillID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player and DB.SkillsDB.has(skillID):
		IdlePolicyService.NoteActivity(player)
		var target : BaseAgent = WorldAgent.GetAgent(targetRID)
		Skill.Cast(player, target, DB.SkillsDB[skillID])

func TriggerSelect(targetRID : int, peerID : int):
	var target : BaseAgent = WorldAgent.GetAgent(targetRID)
	if target:
		Network.UpdatePublicStats(targetRID, target.stat.level, target.stat.health, target.stat.current.maxHealth, target.stat.hairstyle, target.stat.haircolor, target.stat.gender, target.stat.race, target.stat.skintone, target.stat.currentShape, peerID)
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		player.target_selected.emit(player, target)

# Stats
func SetAttributes(strength : int, vitality : int, agility : int, endurance : int, concentration : int, peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if peer and peer.characterID != NetworkCommons.PeerUnknownID and player and player.stat:
		player.stat.SetAttributes(strength, vitality, agility, endurance, concentration)
		Launcher.SQL.UpdateAttribute(peer.characterID, player.stat)

# Inventory
func UseItem(itemID : int, peerID : int):
	var cell : ItemCell = DB.GetItem(itemID)
	if cell and cell.usable:
		var player : PlayerAgent = Peers.GetAgent(peerID)
		if player and ActorCommons.IsAlive(player) and player.inventory:
			IdlePolicyService.NoteActivity(player)
			player.inventory.UseItem(cell)

func DropItem(itemID : int, customfield : StringName, itemCount : int, itemIndex : int, peerID : int):
	var cell : ItemCell = DB.GetItem(itemID, customfield)
	if cell:
		var player : PlayerAgent = Peers.GetAgent(peerID)
		if player and ActorCommons.IsAlive(player) and player.inventory:
			player.inventory.DropItem(cell, itemCount, itemIndex)

func EquipItem(itemID : int, customfield : StringName, itemIndex : int, peerID : int):
	var cell : ItemCell = DB.GetItem(itemID, customfield)
	if cell and cell.slot != ActorCommons.Slot.NONE:
		var player : PlayerAgent = Peers.GetAgent(peerID)
		if player and ActorCommons.IsAlive(player) and player.inventory:
			player.inventory.EquipItem(cell, itemIndex)

func UnequipItem(itemID : int, customfield : StringName, peerID : int):
	var cell : ItemCell = DB.GetItem(itemID, customfield)
	if cell and cell.slot != ActorCommons.Slot.NONE:
		var player : PlayerAgent = Peers.GetAgent(peerID)
		if player and ActorCommons.IsAlive(player) and player.inventory:
			player.inventory.UnequipItem(cell)

func PickupDrop(dropID : int, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		IdlePolicyService.NoteActivity(player)
		WorldDrop.PickupDrop(dropID, player)

func RetrieveCharacterInformation(peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		player.RequestStatsUpdate()
		if player.progress:
			Network.RefreshProgress(player.progress.skills, player.progress.quests, player.progress.bestiary, peerID)
		if player.inventory:
			Network.RefreshInventory(player.inventory.ExportInventory(), peerID)

# Commands
func TriggerCommand(command : String, peerID : int):
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		CommandManager.Handle(player, command)

# Peer handling
func ConnectPeer(peerID : int):
	var transportType : Peers.TransportType = Peers.TransportType.ENET
	if isOffline:
		transportType = Peers.TransportType.OFFLINE
	elif useWebSocket:
		transportType = Peers.TransportType.WEBSOCKET
	Util.PrintInfo("Server", "Peer connected: %d with %s" % [peerID, Peers.GetTransportName(transportType)])

	Peers.AddPeer(peerID, transportType)

	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer and not isOffline:
		peer.primaryConnected = true
		peer.ipAddress = Peers.ResolvePeerIP(peerID)
	bulks[peerID] = {}

	if currentPeer and currentPeer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		var clientPeer : PacketPeer = currentPeer.get_peer(peerID)
		if clientPeer and clientPeer is ENetPacketPeer:
			clientPeer.set_timeout(NetworkCommons.Timeout, NetworkCommons.TimeoutMin, NetworkCommons.TimeoutMax)

func DisconnectPeer(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		return
	peer.primaryConnected = false
	bulks.erase(peerID)
	if peer.rtcConnected:
		Util.PrintInfo("Server", "Primary transport dropped, peer stays on WebRTC: %d" % peerID)
		return
	FullyDisconnect(peerID)

func FullyDisconnect(peerID : int):
	Util.PrintInfo("Server", "Peer disconnected: %d" % peerID)
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer and peer.accountID != NetworkCommons.PeerUnknownID:
		DisconnectAccount(peerID)
	Peers.RemovePeer(peerID)

# WebRTC upgrade
func RequestRtcUpgrade(peerID : int):
	if Network.WebRTCServer:
		Network.WebRTCServer.StartRtcUpgrade(peerID)

func RtcAnswer(sdp : String, peerID : int):
	if Network.WebRTCServer:
		Network.WebRTCServer.HandleRtcAnswer(peerID, sdp)

func RtcCandidateToServer(media : String, index : int, candidateName : String, peerID : int):
	if Network.WebRTCServer:
		Network.WebRTCServer.AddRtcIceCandidate(peerID, media, index, candidateName)

func RtcReady(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if peer:
		peer.rtcConnected = true
	Peers.SetTransport(peerID, Peers.TransportType.WEBRTC)
	Util.PrintInfo("Server", "Peer upgraded to WebRTC: %d" % peerID)

func StartRtcUpgrade(peerID : int):
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		return

	Network.RtcConfig(NetworkCommons.IceServers, peerID)
	var connection : WebRTCPeerConnection = CreateRtcConnection(peerID)
	connection.create_offer()

func HandleRtcAnswer(peerID : int, sdp : String):
	var connection : WebRTCPeerConnection = rtcConnections.get(peerID, null)
	if connection:
		connection.set_remote_description("answer", sdp)

func _OnRtcPeerConnected(peerID : int):
	bulks[peerID] = {}
	Util.PrintInfo("Server", "WebRTC peer connected, awaiting ready: %d" % peerID)

func _OnRtcPeerDisconnected(peerID : int):
	bulks.erase(peerID)
	RemoveRtcConnection(peerID)

	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		return

	peer.rtcConnected = false
	if peer.primaryConnected:
		Peers.SetTransport(peerID, Peers.TransportType.WEBSOCKET)
		Util.PrintInfo("Server", "Peer WebRTC dropped, reverted to WebSocket: %d" % peerID)
	else:
		FullyDisconnect(peerID)

#
func _enter_tree():
	if isOffline:
		interfaceID = NetworkCommons.PeerAuthorityID
		ConnectPeer(interfaceID)
		return

	if useWebRTC:
		RtcMultiplayerPeer().create_server(NetworkCommons.RtcChannelsConfig)
		if not multiplayerAPI.peer_connected.is_connected(_OnRtcPeerConnected):
			multiplayerAPI.peer_connected.connect(_OnRtcPeerConnected)
		if not multiplayerAPI.peer_disconnected.is_connected(_OnRtcPeerDisconnected):
			multiplayerAPI.peer_disconnected.connect(_OnRtcPeerDisconnected)
		multiplayerAPI.multiplayer_peer = currentPeer
		interfaceID = multiplayerAPI.get_unique_id()
		Util.PrintLog("Server", "WebRTC transport initialized")
		return

	if not multiplayerAPI.peer_connected.is_connected(ConnectPeer):
		multiplayerAPI.peer_connected.connect(ConnectPeer)
	if not multiplayerAPI.peer_disconnected.is_connected(DisconnectPeer):
		multiplayerAPI.peer_disconnected.connect(DisconnectPeer)

	var serverPort : int = NetworkCommons.WebSocketPort if useWebSocket else NetworkCommons.ENetPort
	if LauncherCommons.IsTesting:
		serverPort = NetworkCommons.WebSocketPortTesting if useWebSocket else NetworkCommons.ENetPortTesting

	var tlsOptions : TLSOptions = null
	if ResourceLoader.exists(NetworkCommons.ServerCertPath) and ResourceLoader.exists(NetworkCommons.ServerKeyPath):
		var serverKey : CryptoKey = CryptoKey.new()
		var serverCert : X509Certificate = X509Certificate.new()
		serverKey.load(NetworkCommons.ServerKeyPath)
		serverCert.load(NetworkCommons.ServerCertPath)
		tlsOptions = TLSOptions.server(serverKey, serverCert)

	# SOM-IDLE A2: produção pública recusa bind inseguro (credenciais em claro).
	# SOM-IDLE beta deploy: com ProxyTLS o proxy reverso (Coolify) termina o
	# TLS — o bind plain é intencional e o proxy é a borda criptográfica.
	if NetworkCommons.RequiresTLS(LauncherCommons.IsTesting, isOffline, isLocal) and tlsOptions == null and not NetworkCommons.ProxyTLS:
		Util.PrintLog("Server", "FATAL: missing %s/%s — refusing insecure public bind" % [NetworkCommons.ServerCertPath, NetworkCommons.ServerKeyPath])
		push_error("TLS certificate required for public server (SOM-IDLE A2)")
		return
	if NetworkCommons.ProxyTLS:
		Util.PrintLog("Server", "TLS terminated upstream (reverse proxy) — binding plain WebSocket")

	multiplayerAPI.auth_callback = _ValidateAuth
	multiplayerAPI.auth_timeout = NetworkCommons.LoginAttemptTimeout

	var ret : Error = FAILED
	if useWebSocket:
		ret = currentPeer.create_server(serverPort, "*", tlsOptions)
	else:
		ret = currentPeer.create_server(serverPort, NetworkCommons.MaxPlayerCount)
		if ret == OK and tlsOptions:
			ret = currentPeer.host.dtls_server_setup(tlsOptions)

	if ret != OK:
		push_error("Server could not be created, please check if your port %d is valid" % serverPort)
		return
	if ret == OK:
		multiplayerAPI.multiplayer_peer = currentPeer
		interfaceID = multiplayerAPI.get_unique_id()

		Util.PrintLog("Server", "Initialized with: %s, %s, %s, %s" % [
			"WebSocket" if useWebSocket else "ENet",
			"Offline" if isOffline else "Online",
			"Local" if isLocal else "Public",
			"Testing" if LauncherCommons.IsTesting else "Release"
		])

func _ValidateAuth(peerID: int, data: PackedByteArray):
	if data.size() >= 8 and data.decode_s64(0) == NetworkCommons.ProtocolVersion:
		multiplayerAPI.send_auth(peerID, PackedByteArray([1]))
		multiplayerAPI.complete_auth(peerID)
	else:
		currentPeer.disconnect_peer(peerID)

func Destroy():
	if multiplayerAPI.peer_connected.is_connected(ConnectPeer):
		multiplayerAPI.peer_connected.disconnect(ConnectPeer)
	if multiplayerAPI.peer_disconnected.is_connected(DisconnectPeer):
		multiplayerAPI.peer_disconnected.disconnect(DisconnectPeer)

	for peerID in Peers.peers:
		DisconnectPeer(peerID)
	super.Destroy()
