extends NetInterface
class_name NetServer

# Auth
func CreateAccount(accountName : String, password : String, email : String, rememberMe : bool, platform : int, consentAccepted : bool, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		# SOM-IDLE AUTH-P0 (2026-10-04, frente 2): rate limit de criação de conta
		# por IP — 3 tentativas/h, a 3ª bloqueia 1h. Colisão de nome/email e
		# falha de AddAccount contam como tentativa (o spray não ganha throughput
		# de novo). Sucesso NÃO zera o counter: o abuser cria contas válidas para
		# depois usar, e a taxa é o sinal.
		var ipAddress : String = Peers.GetPeerIP(peerID)
		if SQLSecurity.IsBlocked(Launcher.SQL, SQLSecurity.KindCreateAccountIP, ipAddress):
			err = NetworkCommons.AuthError.ERR_CREATE_ACCOUNT_BLOCKED
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
				# SOM-IDLE AUTH-P1 (frente 2): decisão registrada — os dois códigos ficam
				# porque o `gui/Login.gd` RAMIFICA UX por eles (focar o campo e empurrar
				# para a recuperação). Cadastro sem colisão não pode responder uniforme
				# sem quebrar esse fluxo; o oráculo que importa (login/recuperação/2FA) é
				# uniforme nas outras rotas desta classe.
				if Launcher.SQL.HasAccount(accountName):
					err = NetworkCommons.AuthError.ERR_NAME_AVAILABLE
				elif Launcher.SQL.HasEmail(email):
					err = NetworkCommons.AuthError.ERR_EMAIL_TAKEN
				else:
					# P-1 (2026-10-06): o KDF do cadastro saiu do frame junto com o do login.
					# AddAccount deriva (210k) e a primeira verificação re-deriva (mais 210k);
					# as duas pernas viajam como uma unidade de intenção para o worker, com a
					# MESMA serialização por nome do login — o guarda de colisão continua
					# síncrono, então quem chega ao worker já é nome livre.
					var accountData : Peers.AccountData = await _CreateAccountOffThread(accountName, password, email, ipAddress)
					if accountData:
						Network.accounts_list_update.emit()
						# O await atravessou o relógio: sem sessão viva não há login final.
						if not Peers.GetPeer(peerID):
							err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
						else:
							err = Peers.FinalizeLogin(peer, accountName, accountData, platform, rememberMe)
					else:
						err = NetworkCommons.AuthError.ERR_NAME_AVAILABLE
			# Qualquer caminho de falha nesta janela conta como tentativa para o
			# rate-limit de criação — inclusive colisão, que o cliente mostra como "nome
			# indisponível" (não vaza existência: ERR_EMAIL_TAKEN vira ERR_NAME_AVAILABLE
			# de propósito no cliente, e o IP pagou a tentativa de qualquer forma).
			if err != NetworkCommons.AuthError.ERR_OK:
				SQLSecurity.NoteFailure(Launcher.SQL, SQLSecurity.KindCreateAccountIP, ipAddress, SQLSecurity.CreateAccountIPWindowSec, SQLSecurity.CreateAccountIPMaxFailures, SQLSecurity.CreateAccountIPBlockSec)
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

# SOM-IDLE (1d) CDC art.49: reembolso da compra à distância (dono logado), qualquer
# SKU. EconomyService decide (janela 7d / gems não gastas / já reembolsado), reverte
# o dinheiro na moeda do SKU e revoga o direito que a compra deu (VIP, premium do
# passe, posse de cosmético) — work order #97.
func RequestRefund(idempotencyKey : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.RefundResult({"ok" = false, "reason" = "not_authenticated"}, peerID)
		return
	var result : Dictionary = Launcher.Economy.RequestPurchaseRefund(accountID, idempotencyKey)
	if result.get("ok", false):
		Util.PrintLog("Economy", "LGPD/CDC: refund granted account %d key %s amount %d revoked %s" % [accountID, idempotencyKey, int(result.get("amount", 0)), str(result.get("revoked", []))])
	Network.RefundResult(result, peerID)

# C-1 (2026-10-06): a derivação de login — PBKDF2-HMAC-SHA256 de 210.000 iterações
# (a constante `PBKDF2Iterations` em `Hasher.gd:@PBKDF2Iterations`) — saiu do frame
# do servidor. O custo no main thread
# era o DoS: um spray de senhas erradas comprimia o tick inteiro dos ~200 jogadores
# num loop de CPU. A mudança é segura porque o funil transacional pega a `queryMutex`
# por STATEMENT, nunca por cima da derivação — a verificação inteira pode viver numa
# tarefa do `WorkerThreadPool` sem mover uma vírgula do que a mutex protege. O poll é
# `process_frame`, então o resultado volta ao main thread na borda do frame, onde a
# sessão, os sinais e o ledger vivem. O equalizador de nome-inexistente viaja no mesmo
# contêiner: `BurnKdfTime` parado no frame reabriria o oráculo de latência — "esse
# nome existe?" — de graça, sem nenhum CPU na vítima. O chamador precisa revalidar o
# peer depois do await: entre a entrega e a volta o par pode ter caído.
var _liveWorkerTasks : Dictionary = {}

func _AwaitOnWorker(work : Callable) -> Variant:
	var result : Array = [null]
	var taskID : int = WorkerThreadPool.add_task(func() -> void:
		result[0] = work.call())
	_liveWorkerTasks[taskID] = true
	while not WorkerThreadPool.is_task_completed(taskID):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(taskID)
	_liveWorkerTasks.erase(taskID)
	return result[0]

# Dreno de encerramento: um `quit()` com tarefa KDF em voo derruba o motor no
# meio do worker (double-free nos estáticos — o flake do `login_hardening` depois
# do C-1). O main loop já não emite frame aqui, então a espera é bloqueante: cada
# derivação é limitada por construção (210k iterações, não um laço aberto), e o
# `wait_for_task_completion` ainda devolve o id ao pool. Drenar na saída é o preço
# honesto de ter tirado o KDF do caminho do tick.
func _exit_tree():
	for taskIDV in _liveWorkerTasks.keys():
		WorkerThreadPool.wait_for_task_completion(int(taskIDV))
	_liveWorkerTasks.clear()

# C-1 (raça fechada na mesma fatia): o worker abriu um canal que o frame fechava
# por construção — duas tentativas simultâneas no MESMO nome liam o row antes da
# escrita vizinha e o `failed_attempts` perdia atualização (lockout atrasado é
# exatamente o contador que nenhum offload pode enfraquecer). Mesmo nome espera a
# vez; nomes diferentes continuam andando juntos — é ali que o alívio de CPU mora.
var _authValidationInFlight : Dictionary = {}

func _ValidateAuthPasswordOffThread(username : String, password : String) -> Peers.AccountData:
	while _authValidationInFlight.has(username):
		await get_tree().process_frame
	_authValidationInFlight[username] = true
	var data : Variant = await _AwaitOnWorker(func() -> Variant:
		return Launcher.SQL.ValidateAuthPassword(username, password))
	_authValidationInFlight.erase(username)
	return data as Peers.AccountData

# P-1 (2026-10-06): cadastro off-thread no mesmo contêiner do C-1 — a derivação
# de AddAccount e a verificação que a confere são um par indissociável e rodam na
# mesma tarefa do worker; o sinal de lista de contas e o FinalizeLogin continuam no
# main thread, na borda do frame. Serializa pelo MESMO espaço de nomes do login:
# criação e tentativa de login do mesmo nome nunca correm soltas uma contra a outra.
func _CreateAccountOffThread(accountName : String, password : String, email : String, ip : String) -> Peers.AccountData:
	while _authValidationInFlight.has(accountName):
		await get_tree().process_frame
	_authValidationInFlight[accountName] = true
	var data : Variant = await _AwaitOnWorker(func() -> Variant:
		if not Launcher.SQL.AddAccount(accountName, password, email, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion, ip):
			return null
		return Launcher.SQL.ValidateAuthPassword(accountName, password))
	_authValidationInFlight.erase(accountName)
	return data as Peers.AccountData

func _BurnKdfTimeOffThread(password : String) -> void:
	await _AwaitOnWorker(func() -> void:
		SQLSecurity.BurnKdfTime(password))

func LoginWithPassword(accountName : String, password : String, rememberMe : bool, platform : int, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_OK
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if not peer:
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	else:
		err = NetworkCommons.CheckAuthInformation(accountName, password)
		if err == NetworkCommons.AuthError.ERR_OK:
			# SOM-IDLE AUTH-P1 (frente 1): teto por IP na frente do backoff por conta.
			# Origem bloqueada cai no MESMO ERR_AUTH genérico sem tocar
			# `ValidateAuthPassword` — o spray de fonte queimada para de escalar o
			# contador da vítima. Decisão conta-vs-IP documentada em `SQLSecurity`.
			var ipAddress : String = Peers.GetPeerIP(peerID)
			var accountID : int = Launcher.SQL.GetAccountID(accountName)
			if SQLSecurity.IsBlocked(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress):
				err = NetworkCommons.AuthError.ERR_AUTH
			# SOM-IDLE A1: lockout responde genérico (anti-enumeration).
			elif accountID != NetworkCommons.PeerUnknownID and Launcher.SQL.IsLockedOut(accountID):
				err = NetworkCommons.AuthError.ERR_AUTH
				SQLSecurity.NoteFailure(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress, SQLSecurity.LoginIPWindowSec, SQLSecurity.LoginIPMaxFailures, SQLSecurity.LoginIPBlockSec)
			else:
				var accountData : Peers.AccountData = await _ValidateAuthPasswordOffThread(accountName, password)
				# C-1: o await atravessou o relógio do servidor — o par pode ter caído
				# no meio da derivação. Sem sessão viva não há desafio 2FA nem
				# FinalizeLogin: a tentativa desce no mesmo ramo da senha errada.
				if not Peers.GetPeer(peerID):
					accountData = null
				if not accountData:
					err = NetworkCommons.AuthError.ERR_AUTH
					var noted : Dictionary = SQLSecurity.NoteFailure(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress, SQLSecurity.LoginIPWindowSec, SQLSecurity.LoginIPMaxFailures, SQLSecurity.LoginIPBlockSec)
					if bool(noted.get("justBlocked", false)):
						SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventLoginIPBlock, accountID, JSON.stringify({"ip": ipAddress}))
					if accountID == NetworkCommons.PeerUnknownID:
						# Frente 2: sem esta linha, nome inexistente saía da verificação
						# sem pagar o KDF que nome existente paga — latência respondia
						# "esse nome existe?" sem erro nenhum na tela.
						await _BurnKdfTimeOffThread(password)
					elif Launcher.SQL.IsLockedOut(accountID):
						# Este ramo só alcança uma conta NÃO travada antes da tentativa:
						# travada agora = transição = um evento por episódio de lockout.
						SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventLoginLockout, accountID)
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
	# SOM-IDLE AUTH-P1 (frente 3): orçamento de tentativa TOTP PERSISTIDO por
	# CONTA — diferente do pending de reset (memória basta lá porque o restart
	# derruba o código), o segredo TOTP survive deploy, então a tentativa também
	# tem que sobreviver ou cada release devolve o budget cheio a quem já tem a
	# senha. Travado: queima o desafio do peer e responde o MESMO ERR_AUTH
	# genérico (sem código novo, sem oracle).
	var accountID : int = Launcher.SQL.GetAccountID(accountName)
	if accountID != NetworkCommons.PeerUnknownID and SQLSecurity.IsBlocked(Launcher.SQL, SQLSecurity.KindTotp, str(accountID)):
		if peer:
			peer.pendingTwoFactorAccount = ""
			peer.pendingTwoFactorAt = 0
		Network.AuthError(NetworkCommons.AuthError.ERR_AUTH, peerID)
		return
	var challengeAlive : bool = peer != null and not accountName.is_empty() and peer.pendingTwoFactorAccount == accountName
	# P0-1 (C-01): rejeita se o peer já tem uma conta vinculada que diverge do desafio.
	if peer != null and peer.accountID != NetworkCommons.PeerUnknownID and peer.accountID != accountID:
		err = NetworkCommons.AuthError.ERR_AUTH
		Network.AuthError(err, peerID)
		return
	# SOM-IDLE AUTH-P1 (frente 3): a decisão do desafio é feita AQUI, e não por
	# `Peers.ValidateTwoFactorChallenge`, porque aquele helper decide frescor por
	# `SQL.ConsumeTwoFactorToken` — cuja detecção `SELECT changes()` o pool de
	# leitura (ligado por padrão) roteia para uma conexão onde `changes()` é 0 e
	# então rejeitaria TODO código válido (DoS no 2FA). Consomo pela variante
	# roteável (`SQLSecurity.ConsumeTwoFactorTokenSafe`). As MESMAS regras são
	# preservadas: sem desafio → NO_PEER_DATA; dono ≠ conta → AUTH (código válido
	# p/ A nunca loga B); expirado → AUTH + queima o desafio; código errado → AUTH
	# (desafio vivo, retry rate-limited); replay (certo já consumido) → AUTH;
	# certo e inédito → OK + consome.
	if peer == null or peer.pendingTwoFactorAccount.is_empty():
		err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
	elif accountName != peer.pendingTwoFactorAccount:
		err = NetworkCommons.AuthError.ERR_AUTH
	elif peer.pendingTwoFactorAt > 0 and int(Time.get_unix_time_from_system()) - peer.pendingTwoFactorAt > NetworkCommons.TwoFactorChallengeSec:
		peer.pendingTwoFactorAccount = ""
		peer.pendingTwoFactorAt = 0
		err = NetworkCommons.AuthError.ERR_AUTH
	elif accountID == NetworkCommons.PeerUnknownID:
		err = NetworkCommons.AuthError.ERR_AUTH
	else:
		var secret : String = Launcher.SQL.GetTwoFactorSecret(accountID)
		if secret.is_empty() or not TwoFactorAuth.VerifyTOTP(secret, token):
			err = NetworkCommons.AuthError.ERR_AUTH
		elif not SQLSecurity.ConsumeTwoFactorTokenSafe(Launcher.SQL, accountID, token):
			err = NetworkCommons.AuthError.ERR_AUTH
		else:
			peer.pendingTwoFactorAccount = ""
			peer.pendingTwoFactorAt = 0
			err = NetworkCommons.AuthError.ERR_OK
	if err == NetworkCommons.AuthError.ERR_OK:
		SQLSecurity.ClearFailures(Launcher.SQL, SQLSecurity.KindTotp, str(accountID))
		var accountData : Peers.AccountData = Peers.AccountData.new(accountID, Launcher.SQL.GetAccountPermission(accountID))
		err = Peers.FinalizeLogin(peer, accountName, accountData, platform, false)
	elif err == NetworkCommons.AuthError.ERR_AUTH and challengeAlive:
		var secret : String = Launcher.SQL.GetTwoFactorSecret(accountID)
		if not secret.is_empty() and TwoFactorAuth.VerifyTOTP(secret, token) and SQLSecurity.IsTwoFactorTokenConsumed(Launcher.SQL, accountID, token):
			# Código CERTO para esta janela, já consumido antes: replay (frente 4).
			SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventTotpReplay, accountID)
		else:
			var budget : Dictionary = SQLSecurity.AttemptBudget(Launcher.SQL, SQLSecurity.KindTotp, str(accountID), SQLSecurity.TotpMaxFailures, SQLSecurity.TotpWindowSec)
			if bool(budget.get("justExhausted", false)):
				SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventTotpThrottle, accountID)
				if peer:
					peer.pendingTwoFactorAccount = ""
					peer.pendingTwoFactorAt = 0
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
			var tokenHash : String = Hasher.HashAuthToken(token)
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
				# SOM-IDLE AUTH-P1: este ramo confere senha exatamente como o login,
				# então paga o MESMO pedágio: teto por IP antes, e tentativa errada
				# carimbada no eixo IP depois (sem isso, o spray só mudava de RPC).
				if SQLSecurity.IsBlocked(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress):
					err = NetworkCommons.AuthError.ERR_AUTH
				elif accountID != NetworkCommons.PeerUnknownID and Launcher.SQL.IsLockedOut(accountID):
					err = NetworkCommons.AuthError.ERR_AUTH
					SQLSecurity.NoteFailure(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress, SQLSecurity.LoginIPWindowSec, SQLSecurity.LoginIPMaxFailures, SQLSecurity.LoginIPBlockSec)
				else:
					accountData = await _ValidateAuthPasswordOffThread(accountName, password)
					if not accountData:
						err = NetworkCommons.AuthError.ERR_AUTH
						var noted : Dictionary = SQLSecurity.NoteFailure(Launcher.SQL, SQLSecurity.KindLoginIP, ipAddress, SQLSecurity.LoginIPWindowSec, SQLSecurity.LoginIPMaxFailures, SQLSecurity.LoginIPBlockSec)
						if bool(noted.get("justBlocked", false)):
							SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventLoginIPBlock, accountID, JSON.stringify({"ip": ipAddress}))
						if accountID == NetworkCommons.PeerUnknownID:
							await _BurnKdfTimeOffThread(password)
						elif Launcher.SQL.IsLockedOut(accountID):
							SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventLoginLockout, accountID)
		elif not token.is_empty():
			accountData = Launcher.SQL.ValidateAuthToken(Launcher.SQL.GetAccountID(accountName), Hasher.HashAuthToken(token), ipAddress)
			if not accountData:
				err = NetworkCommons.AuthError.ERR_TOKEN
		else:
			err = NetworkCommons.AuthError.ERR_AUTH
		# C-1: o caminho da senha atravessou o relógio (await do KDF off-thread);
		# o par pode ter caído no meio. FinalizeLogin exige sessão viva.
		if err == NetworkCommons.AuthError.ERR_OK and accountData and not Peers.GetPeer(peerID):
			err = NetworkCommons.AuthError.ERR_NO_PEER_DATA
			accountData = null
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

# SOM-IDLE AUTH-P0 (auditoria 2026-09-27 §10/§22-P0-2). Este handler é o único
# ponto do fluxo que sabe se a conta existe; a resposta ao client é sempre a
# MESMA (`ERR_RESET_EMAIL_SENT`) nos quatro ramos — conta inexistente, e-mail
# vazio, budget da janela estourado e e-mail efetivamente enviado — então ele não
# serve de oráculo de enumeração nem de multiplicador de tentativa: o teto agora é
# por CONTA em janela rolante (`EmailService.BeginResetRequest`), não por peer.
func RequestPasswordReset(accountName : String, peerID : int):
	if not Launcher.Email or not Launcher.Email.IsConfigured():
		Network.AuthError(NetworkCommons.AuthError.ERR_RESET_UNAVAILABLE, peerID)
		return

	var accountID : int = Launcher.SQL.GetAccountID(accountName)
	if accountID != NetworkCommons.PeerUnknownID:
		# SOM-IDLE AUTH-P0 (2026-10-04, frente 2): reset de senha só para contas
		# com e-mail VERIFICADO. Um cadastro com e-mail não verificado não chegou
		# ao inbox de ninguém com intenção de controle — atacar o reset dele é
		# spray direto. A resposta ao client continua a mesma de sempre (não
		# vaza "existe mas não verificado" nem "não existe"), e o log de tentativa
		# em conta não-verificada usa um evento DISTINTO (EventResetOnUnverified)
		# para não confundir com esgotamento real de budget.
		if not Launcher.SQL.IsEmailVerified(accountID):
			SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventResetOnUnverified, accountID)
		elif Launcher.Email.BeginResetRequest(accountID):
			var email : String = Launcher.SQL.GetAccountEmail(accountID)
			if not email.is_empty():
				var code : String = Hasher.NormalizeResetCode(Hasher.GenerateResetCode())
				Launcher.Email.CreateReset(accountID, Hasher.HashResetCode(code, accountID))
				Launcher.Email.SendPasswordResetEmail(email, code)
		elif Launcher.SQL != null:
			# Frente 4: budget da janela estourado é negação de serviço ao chamador —
			# a resposta continua idêntica (anti-enumeration), mas o beta enxerga a
			# tentativa agregada em `sec_reset_request_limit`.
			SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventResetRequestLimit, accountID)

	Network.AuthError(NetworkCommons.AuthError.ERR_RESET_EMAIL_SENT, peerID)

func ConfirmPasswordReset(accountName : String, code : String, newPassword : String, peerID : int):
	var err : NetworkCommons.AuthError = NetworkCommons.AuthError.ERR_RESET_INVALID_CODE

	# Normaliza ANTES de validar e antes de hashar: o storage guarda o hash do texto
	# normalizado, então comparar o cru recusaria o código correto digitado em
	# minúsculo (e-mail copiado no celular).
	var normalized : String = Hasher.NormalizeResetCode(code)
	var passwordErr : NetworkCommons.AuthError = NetworkCommons.CheckPasswordInformation(newPassword)
	if passwordErr == NetworkCommons.AuthError.ERR_OK and NetworkCommons.CheckResetCode(normalized):
		var accountID : int = Launcher.SQL.GetAccountID(accountName)
		if accountID != NetworkCommons.PeerUnknownID:
			var codeHash : String = Hasher.HashResetCode(normalized, accountID)
			# `ValidateReset` conta a tentativa errada aqui em baixo (consumo em
			# `EmailService`); o acerto não consome — quem apaga o pending é este
			# handler, e só depois do commit.
			var hadPending : bool = Launcher.Email.HasPendingReset(accountID)
			if Launcher.Email.ValidateReset(accountID, codeHash):
				# Os dois writers são raw (`ExecuteBindings`), então cabem na
				# transação; e o resultado deles agora É o veredito — antes o lambda
				# devolvia `true` com o UPDATE falho e o player recebia
				# "senha atualizada" sem senha atualizada (auditoria §5, disciplina
				# transacional).
				if Launcher.SQL.Transaction(func() -> bool:
					var updated : bool = Launcher.SQL.UpdateAccountPassword(accountID, newPassword)
					var revoked : bool = Launcher.SQL.RemoveAllAuthTokens(accountID)
					return updated and revoked):
					Launcher.Email.RemoveReset(accountID)
					err = NetworkCommons.AuthError.ERR_RESET_PASSWORD_UPDATED
			# O gancho de esgotamento é do ramo ERRADO: numa tentativa certa o
			# pending continua vivo (quem apaga é o commit acima), então é aqui
			# — depois de `ValidateReset` devolver false — que se enxerga a
			# diferença entre "só errou" e "bateu no teto e comeu o pending".
			# Não recalculamos a aritmética do teto (é do `EmailService`, dono do
			# pending, e uma tentativa a mais/menos ali mudaria o número sem mudar
			# o sentido do sinal): basta "havia pending, a tentativa errada o
			# sumiu". Isso é exatamente o esgotamento (ou o vencimento no mesmo
			# golpe) — nunca um simples erro, que deixa o pending vivo.
			elif hadPending and not Launcher.Email.HasPendingReset(accountID):
				# Frente 4: pending CONSUMIDO pela tentativa errada que bateu no
				# teto (a disciplina é do `EmailService`, nada duplicado aqui) — o
				# sinal distingue "adivinho zerou o pending" de "só estava errado".
				SQLSecurity.LogSecurityEvent(Launcher.SQL, SQLSecurity.EventResetExhausted, accountID)

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
					# §12 (AUDITORIA_2026-09-27): a metade durável da presença — o que um
					# segundo processo, ou este depois de um restart, consegue consultar.
					# A zona sai da política recém-criada porque é `AutoFarmOnLogin` quem
					# decide a zona do login (a coluna salva ainda pode estar em 0).
					Presence.Report(Launcher.SQL, peer.characterID, peer.accountID, nickname, agent.idlePolicy.zoneID if agent.idlePolicy else int(charInfo.get("farm_zone", 0)), SQLCommons.Timestamp())

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
			# §12: a linha durável sai junto com o índice em memória. Sem isto o
			# "quem está online" do outro processo mentiria até o TTL vencer.
			Presence.Forget(Launcher.SQL, peer.characterID)
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
	# §12 (AUDITORIA_2026-09-27): a zona vai junto na presença durável porque é o
	# "online em que zona" que o OUTRO processo lê — este é o único ponto onde a zona
	# muda numa sessão viva, então é aqui que a cauda do banco é re-estampada.
	Presence.Report(Launcher.SQL, charID, maxi(0, Peers.GetAccount(peerID)), player.nick, zoneID, SQLCommons.Timestamp())
	IdlePolicyService.StartIdleSession(player, zoneID)
	Network.FarmZoneFeedback(zoneID, true, "farming", peerID)

func ClaimOfflineSettle(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.AFKReport({}, peerID)
		return
	if not Peers.Footprint(peerID, "claim_settle", NetworkCommons.FootprintGateMs):
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

# Fase C: compra do premium = intent do companion (R$ 24,90; deluxe R$ 44,90).
# O SKU não é decidido aqui: `GetPassCheckoutIntent` resolve o passe da temporada
# ativa (OPS-2) — um literal neste transport venderia o passe da S1 com a S2 no ar.
func BuyPass(tier : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.PassFeedback(false, "not_logged_in", peerID)
		return
	if tier != "standard" and tier != "deluxe":
		Network.PassFeedback(false, "bad_tier", peerID)
		return
	Network.CheckoutIntent(Launcher.Economy.GetPassCheckoutIntent(accountID, tier), peerID)

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

# SOM-IDLE retenção: leitura do streak de login para a superfície do jogador. Só
# LE — o estado é o que `StreakService.RecordLogin` escreveu no login (dia decidido
# pelo relógio do servidor), e a escada vem do código que paga. Cliente não manda
# número nenhum: sem esta linha o streak continuaria invisível.
func GetStreak(peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		Network.StreakState({}, peerID)
		return
	Network.StreakState(StreakService.View(charID), peerID)

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

# Fase E (rewarded ads): hora de offline, baú bônus, reroll grátis e chave de
# boss. Sucessos empurram o estado fresco da janela correspondente.

# C2 (auditoria 2026-09-24): a exibição de um anúncio custa uma autorização
# mintada aqui. O client não constrói token — ele pede, e o que volta é um nonce
# de uso único vinculado a esta conta e a este placement (ou vazio, com o motivo).
func RequestAdSlot(placement : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.AdSlot(placement, "", "not_logged_in", peerID)
		return
	var minted : Dictionary = Launcher.Economy.MintAdSlot(accountID, placement)
	Network.AdSlot(placement, str(minted.get("token", "")), str(minted.get("reason", "db_error")), peerID)

func WatchAd(placement : String, token : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		Network.AdFeedback(false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.WatchAd(accountID, charID, placement, token)
	Network.AdFeedback(bool(result.get("ok", false)), str(result.get("reason", "?")), peerID)
	if bool(result.get("ok", false)) and placement == EconomyCatalog.AD_AFKHOURS:
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

# As cinco ESCRITAS de guild do painel: identidade do peer, regra de vault do service (§14).
func CreateGuild(guildName : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if accountID == NetworkCommons.PeerUnknownID or charID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var guildID : int = Launcher.Economy.CreateGuild(accountID, charID, guildName)
	Network.GuildFeedback(guildID > 0, "ok" if guildID > 0 else "rejected", peerID)
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

func JoinGuild(guildID : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var ok : bool = Launcher.Economy.JoinGuild(accountID, guildID)
	Network.GuildFeedback(ok, "ok" if ok else GuildRoster.RefusalFor(accountID, guildID), peerID)
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

func LeaveGuild(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var ok : bool = Launcher.Economy.LeaveGuild(accountID)
	Network.GuildFeedback(ok, "ok" if ok else "no_guild", peerID)
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

func DepositToVault(itemID : int, count : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if accountID == NetworkCommons.PeerUnknownID or charID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var ok : bool = Launcher.Economy.DepositToVault(accountID, charID, itemID, count)
	Network.GuildFeedback(ok, "ok" if ok else "rejected", peerID)
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

func WithdrawFromVault(itemID : int, count : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if accountID == NetworkCommons.PeerUnknownID or charID == NetworkCommons.PeerUnknownID:
		Network.GuildFeedback(false, "not_logged_in", peerID)
		return
	var ok : bool = Launcher.Economy.WithdrawFromVault(accountID, charID, itemID, count)
	Network.GuildFeedback(ok, "ok" if ok else ("bad_args" if count > GuildVaultLimits.MaxWithdrawPerAction else "rejected"), peerID)
	Network.GuildState(Launcher.Economy.GetGuildState(accountID), peerID)

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
		if not Peers.Footprint(peerID, "open_chest", NetworkCommons.FootprintGateMs):
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

# SOM-W5 (peça 6): registro da subscription de web push. A conta é SEMPRE a do
# peer — o payload traz material opaco do navegador (endpoint, chaves), e uma
# conta nele seria o jogador escrevendo na caixa de correio de outro. A validação
# do material (teto de tamanho, base64url, https) é do serviço
# `WebPushSubscription.Register`, e a resposta ao jogador sai por
# `CommandFeedback` com o RÓTULO do motivo, nunca com o endpoint (a URL do
# provedor é credencial: quem tem ela + as chaves manda notificação).
func RegisterPushSubscription(endpoint : String, p256dh : String, auth : String, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("push subscription refused (not_logged_in)", peerID)
		return
	WebPushSubscription.RegisterAndReport(accountID, endpoint, p256dh, auth, peerID)

func UnregisterPushSubscription(peerID : int):
	WebPushSubscription.ReportUnregister(Peers.GetAccount(peerID), peerID)

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
		# O board pós-ataque vai para a SESSÃO do defensor, não para a conta dele:
		# ArenaBoardResult termina em CallClient, cujo peerID é destino de transporte.
		# Conta desconectada não tem peer — sem o gate, o rpc iria para -2.
		var defenderPeer : int = Peers.GetAccountPeer(defenderAccountID)
		if defenderPeer != NetworkCommons.PeerUnknownID:
			Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(defenderAccountID), defenderPeer)

# R4 async arena: board da conta da sessão.
func ArenaBoard(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.ArenaBoardResult({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	Network.ArenaBoardResult(Launcher.Economy.ArenaBoard(accountID), peerID)

# ------------------------------------------------------------------ P1-1/P1-2: Auction House para a janela
# O `/ah` de WorldCommands continua vivo (mesmo serviço, mesma sessão); estes
# handlers dão à UI o mesmo acesso com payload estruturado. Nada aqui decide
# preço, taxa ou saldo: `AuctionHouseService` move ouro/itens/gems, o handler só
# autentica pelo transporte e devolve o estado REAL depois do movimento.
# 059(b) (JUIZ MARKETPLACE): `BrowseListings` ganhou OFFSET no serviço, então a
# janela de 40 linhas deixou de ser um recorte de leitura e passou a ser PÁGINA,
# com filtro de preço e de item aplicados no SQL do servidor. O `limit` antigo
# continua aceito (`GetAuctionListings` = página 0) para não partir o `/ah`.
const AHMaxBrowseWindow : int = 40

func GetAuctionListings(limit : int, peerID : int):
	_AuctionWindow(clampi(limit, 1, EconomyCatalog.AHBrowsePageSize), 0, 0, 0, peerID)

# Página pedida pelo painel: offset + filtro, resposta no MESMO payload de
# `AuctionListings` (a forma da resposta é o estado da janela, não o modo de
# busca — nada de um segundo canal para a mesma tela).
func GetAuctionPage(offset : int, maxPrice : int, itemID : int, peerID : int):
	_AuctionWindow(EconomyCatalog.AHBrowsePageSize, maxi(0, offset), maxi(0, maxPrice), maxi(0, itemID), peerID)

func _AuctionWindow(limit : int, offset : int, maxPrice : int, itemID : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if accountID == NetworkCommons.PeerUnknownID or charID == NetworkCommons.PeerUnknownID:
		Network.AuctionListings({"ok" = false, "reason" = "not_logged_in"}, peerID)
		return
	var page : Dictionary = Launcher.Economy.BrowseListingsPage(limit, offset, maxPrice, itemID)
	var listings : Array = []
	var sellers : Array = []
	for row in page.get("listings", []):
		var sellerChar : int = int(row.get("seller_char", 0))
		if not sellers.has(sellerChar):
			sellers.append(sellerChar)
		listings.append({
			"id" = int(row.get("id", 0)),
			"seller_char" = sellerChar,
			"item_id" = int(row.get("item_id", 0)),
			"count" = int(row.get("count", 1)),
			"price_gold" = int(row.get("price_gold", 0)),
			"highlight" = int(row.get("highlight", 0)),
			"created_at" = int(row.get("created_at", 0)),
			# "mine" habilita Cancel/Highlight no painel. O serviço já recusa
			# cancelamento de anúncio alheio; a UI apenas esconde o impossível.
			"mine" = sellerChar == charID,
		})
	var names : Dictionary = _AHSellerNames(sellers)
	for entry in listings:
		entry["seller"] = str(names.get(int(entry["seller_char"]), "?"))
	var cap : int = Launcher.Economy.AHOpenCap(accountID)
	Network.AuctionListings({
		"ok" = true,
		"listings" = listings,
		# Tudo que a confirmação de gasto precisa mostrar ANTES do clique.
		"gold" = _AHCharGold(charID),
		"gems" = Launcher.Economy.GetGems(accountID),
		"open" = _AHOpenCount(accountID),
		"cap" = cap,
		"list_fee_gems" = EconomyCatalog.AHListFeeGems,
		"highlight_fee_gems" = EconomyCatalog.AHHighlightFeeGems,
		# Custo do PRÓXIMO slot (a fórmula base × (extra+1) é do serviço, não da UI).
		"slot_cost_gems" = EconomyCatalog.AHSlotBaseCost * (maxi(0, cap - EconomyCatalog.AHMaxOpenPerAccount) + 1),
		"creator_fee_pct" = CraftCatalog.CREATOR_FEE_PCT,
		# 059(b): paginação do lado do servidor — o painel não recorta mais.
		"total" = int(page.get("total", 0)),
		"offset" = int(page.get("offset", 0)),
		"page_size" = int(page.get("page_size", limit)),
		"max_page" = int(page.get("max_page", 0)),
		# 059(a): preço realizado no servidor, lido de `ah_price_history`. O
		# histórico deixa de ser memória de sessão: duas contas abertas na mesma
		# hora veem o mesmo número, e ele sobrevive a fechar a janela.
		"sold" = Launcher.Economy.RecentSoldSummary(itemID, EconomyCatalog.AHSoldHistoryWindow),
		"sold_recent" = Launcher.Economy.RecentSoldPrices(itemID, EconomyCatalog.AHSoldHistoryWindow),
		# 059(c): as ordens de compra em pé desta conta (gold em escrow).
		"orders" = Launcher.Economy.BuyOrdersFor(charID, 8),
		"bid_cap" = EconomyCatalog.AHMaxBuyOrdersPerAccount,
		"bid_max_quantity" = EconomyCatalog.AHMaxBidQuantity,
	}, peerID)

func AuctionBuy(listingID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID == NetworkCommons.PeerUnknownID or accountID == NetworkCommons.PeerUnknownID:
		_AuctionResult("buy", listingID, false, "not_logged_in", peerID)
		return
	# Pré-leitura só refina o motivo visível; o veredito continua sendo do serviço,
	# que faz tudo numa transação sob settleMutex (não há TOCTOU a explorar aqui).
	var row : Dictionary = _AHListingRow(listingID)
	if row.is_empty():
		_AuctionResult("buy", listingID, false, "not_found", peerID)
		return
	if int(row.get("seller_account", 0)) == accountID:
		_AuctionResult("buy", listingID, false, "own_listing", peerID)
		return
	var price : int = int(row.get("price_gold", 0))
	if _AHCharGold(charID) < price:
		_AuctionResult("buy", listingID, false, "insufficient_gold", peerID)
		return
	var ok : bool = Launcher.Economy.BuyListing(charID, listingID)
	_AuctionResult("buy", listingID, ok, "ok" if ok else "rejected", peerID)
	if ok:
		_AuctionRefresh(peerID)

func AuctionCancel(listingID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		_AuctionResult("cancel", listingID, false, "not_logged_in", peerID)
		return
	if not Launcher.Economy.CancelListing(charID, listingID):
		_AuctionResult("cancel", listingID, false, "rejected", peerID)
		return
	# A taxa de anúncio em gems é queimada e não volta (decisão do serviço).
	_AuctionResult("cancel", listingID, true, "ok", peerID)
	_AuctionRefresh(peerID)

func AuctionList(itemID : int, count : int, priceGold : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		_AuctionResult("list", 0, false, "not_logged_in", peerID)
		return
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		_AuctionResult("list", 0, false, "bad_args", peerID)
		return
	var listing : int = Launcher.Economy.ListItemForSale(charID, itemID, count, priceGold)
	_AuctionResult("list", listing, listing > 0, "ok" if listing > 0 else "rejected", peerID)
	if listing > 0:
		_AuctionRefresh(peerID)

func AuctionHighlight(listingID : int, peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		_AuctionResult("highlight", listingID, false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.HighlightListing(accountID, listingID)
	var ok : bool = bool(result.get("ok", false))
	_AuctionResult("highlight", listingID, ok, str(result.get("reason", "rejected")), peerID)
	if ok:
		_AuctionRefresh(peerID)

# 059(c): ordem de compra. O ouro sai da carteira para o escrow DENTRO da
# transação do serviço (`PlaceBuyOrder`); este handler autentica pelo transporte,
# repassa e devolve o estado real — a mesma disciplina de `AuctionList` do lado
# da oferta, e os mesmos `reason` estáveis (nada de token novo sem linha no
# catálogo i18n: `rejected` cobre cap de ordens, saldo insuficiente e args
# inválidos, que é o que o jogador precisa saber).
# No resultado, `listing` é o id da ORDEM para as duas ações novas — a UI imprime
# o id que o servidor devolveu, nunca inventa um.
func AuctionBid(itemID : int, count : int, unitPrice : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		_AuctionResult("bid", 0, false, "not_logged_in", peerID)
		return
	if itemID <= 0 or count <= 0 or unitPrice <= 0:
		_AuctionResult("bid", 0, false, "bad_args", peerID)
		return
	var order : int = Launcher.Economy.PlaceBuyOrder(charID, itemID, count, unitPrice)
	var placed : bool = order > 0
	_AuctionResult("bid", order, placed, "ok" if placed else "rejected", peerID)
	if placed:
		_AuctionRefresh(peerID)

func AuctionBidCancel(orderID : int, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	if charID == NetworkCommons.PeerUnknownID:
		_AuctionResult("bid_cancel", orderID, false, "not_logged_in", peerID)
		return
	if not Launcher.Economy.CancelBuyOrder(charID, orderID):
		_AuctionResult("bid_cancel", orderID, false, "rejected", peerID)
		return
	_AuctionResult("bid_cancel", orderID, true, "ok", peerID)
	_AuctionRefresh(peerID)

func AuctionBuySlot(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		_AuctionResult("slot", 0, false, "not_logged_in", peerID)
		return
	var result : Dictionary = Launcher.Economy.BuyAHSlot(accountID)
	var ok : bool = bool(result.get("ok", false))
	_AuctionResult("slot", 0, ok, str(result.get("reason", "rejected")), peerID)
	if ok:
		_AuctionRefresh(peerID)

# Veredito + saldo depois do movimento. O painel mostra ESTES números (e a
# prévia de custo usa os campos que GetAuctionListings entregou), então a UI
# nunca afirma um gasto que o servidor não confirmou.
func _AuctionResult(action : String, listingID : int, ok : bool, reason : String, peerID : int):
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	Network.AuctionTradeResult({
		"action" = action,
		"listing" = listingID,
		"ok" = ok,
		"reason" = reason,
		"gold" = _AHCharGold(charID) if charID != NetworkCommons.PeerUnknownID else 0,
		"gems" = Launcher.Economy.GetGems(accountID) if accountID != NetworkCommons.PeerUnknownID else 0,
	}, peerID)

# Pós-trade: re-puxa a janela de anúncios (o item saiu/entrou do mercado) e o
# estado de economia, mesmo formato das ações pagas de Shop/Chests.
func _AuctionRefresh(peerID : int):
	GetAuctionListings(AHMaxBrowseWindow, peerID)
	var charID : int = Peers.GetCharacter(peerID)
	var accountID : int = Peers.GetAccount(peerID)
	if charID != NetworkCommons.PeerUnknownID and accountID != NetworkCommons.PeerUnknownID:
		Network.EconomyState(Launcher.Economy.GetEconomyState(accountID, charID), peerID)

func _AHCharGold(charID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT gp FROM stat WHERE char_id = ?;", [charID])
	return int(rows[0].get("gp", 0)) if not rows.is_empty() else 0

func _AHOpenCount(accountID : int) -> int:
	# Mesmo contador do guard de ListItemForSale (`seller_account`, não char).
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM auction_listing WHERE seller_account = ? AND status = 'open';", [accountID])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func _AHListingRow(listingID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, seller_account, item_id, count, price_gold FROM auction_listing WHERE id = ? AND status = 'open';", [listingID])
	return {} if rows.is_empty() else rows[0]

# Um único IN parametrizado para a janela toda (nada de uma query por anúncio).
func _AHSellerNames(charIDs : Array) -> Dictionary:
	var out : Dictionary = {}
	var placeholders : PackedStringArray = PackedStringArray()
	var params : Array = []
	for raw in charIDs:
		var id : int = int(raw)
		if id <= 0:
			continue
		placeholders.append("?")
		params.append(id)
	if placeholders.is_empty():
		return out
	for row in Launcher.SQL.QueryBindings("SELECT char_id, nickname FROM character WHERE char_id IN (%s);" % ", ".join(placeholders), params):
		out[int(row.get("char_id", 0))] = str(row.get("nickname", "?"))
	return out

# ROADMAP_COMERCIAL S1 / P1-7: funil onboarding_done no caminho com Telemetria.
# `Launcher.Telemetry` só existe no processo servidor (`Launcher.Server()`), então
# o emit em `Onboarding.Stop()` não gravava nada no build web (cliente puro) — o
# funil comercial perdia exatamente a última etapa do funil. O rpc chega a quem tem
# o serviço e carimba conta/personagem DA SESSÃO, nunca do corpo do pacote.
# Persistência: linha em `telemetry_event` com kind = "onboarding_done" (já existe
# em TelemetryService.FUNNEL_KINDS) — nenhuma migration foi necessária.
func OnboardingDone(peerID : int):
	var accountID : int = Peers.GetAccount(peerID)
	var charID : int = Peers.GetCharacter(peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		return
	if Launcher.get("Telemetry") != null and Launcher.Telemetry.has_method("RecordFunnel"):
		Launcher.Telemetry.RecordFunnel("onboarding_done", accountID, charID)

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
	if not RateLimit.Charge(peerID, "SetMovePos"): return	# #86: `DelayInstant` não é "sem cota"
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
	if not RateLimit.Charge(peerID, "SetViewportSize"): return	# #86: recálculo de visibilidade também se compra
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
	if not RateLimit.Charge(peerID, "TriggerEmote"): return	# #86: cota no recebimento, não no cliente
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player is PlayerAgent:
		Network.NotifyNeighbours(player, "Emote", [player.get_rid().get_id(), emoteID])

func TriggerChat(channelName : String, text : String, peerID : int):
	if not RateLimit.Charge(peerID, "TriggerChat"): return null	# #86: difusão comprada no recebimento
	var player : PlayerAgent = Peers.GetAgent(peerID)
	if player:
		# SOM-IDLE C1: o texto segue pelo caminho de disseminação (vizinhos,
		# global, whisper) sem passar por nenhum cliente antes, então é
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
		if ChatModeration.IsGuildChannel(channelName):
			# SOM-IDLE social (auditoria 2026-09-27 §SOCIAL): sem este ramo a linha
			# caía no `else` de whisper, não reach ninguém e o falante lia "'guild:Foo'
			# is no longer online". Quem recebe é decisão de moderação; aqui só o
			# primitivo de envio e o aviso de entrega quando ela não aconteceu.
			var delivered : int = ChatModeration.FanoutGuildChat(accountID, player.nick, channelName, player.get_rid().get_id(), message)
			if delivered <= 0:
				Network.ChatSystem(channelName, "No guild member session is online to receive this", peerID)
			return null
		elif channelName == str(GUICommons.ChatChannel.LOCAL):
			Network.NotifyNeighbours(player, "ChatPlayer", [str(GUICommons.ChatChannel.LOCAL), player.nick, message, player.get_rid().get_id()])
		elif channelName == str(GUICommons.ChatChannel.GLOBAL):
			Network.NotifyGlobal("ChatPlayer", [str(GUICommons.ChatChannel.GLOBAL), player.nick, message, player.get_rid().get_id()])
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
	if CellCommons.IsEquippable(cell):
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
	if not RateLimit.Charge(peerID, "TriggerCommand"): return	# #86: comando é trabalho no servidor
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
	RateLimit.Forget(peerID)	# #86: peerID é reciclado; a cota do antecessor não passa adiante
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

	# SOM-IDLE ADMISSION: os dois transportes saem do mesmo teto, lido uma única vez
	# dentro de `Admission.OpenTransport`. O WebSocket não tem onde receber o número
	# no transporte (o 2º argumento do motor é o endereço de bind), então ele vira a
	# régua da porta de entrada — fecha a divergência 128/sem-teto.
	admission = Admission.OpenTransport(currentPeer, useWebSocket, serverPort, tlsOptions)
	var ret : int = admission.BindError
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

# Porta de entrada pré-auth: teto único dos dois transportes + orçamento por endereço.
var admission : Admission = null

func _ValidateAuth(peerID: int, data: PackedByteArray):
	# A decisão deixou de ser "o protocolo bate": `complete_auth` só vem depois do
	# veredito de `Admission` (motivo e contagem de recusas vivem naquele módulo).
	admission.CheckAuth(multiplayerAPI, currentPeer, peerID, data,
		Launcher.SQL != null and Launcher.SQL.MigrationBlocked())

func Destroy():
	if multiplayerAPI.peer_connected.is_connected(ConnectPeer):
		multiplayerAPI.peer_connected.disconnect(ConnectPeer)
	if multiplayerAPI.peer_disconnected.is_connected(DisconnectPeer):
		multiplayerAPI.peer_disconnected.disconnect(DisconnectPeer)

	for peerID in Peers.peers:
		DisconnectPeer(peerID)
	super.Destroy()
