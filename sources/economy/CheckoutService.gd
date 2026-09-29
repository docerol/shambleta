extends RefCounted
class_name CheckoutService

# SOM-IDLE Fatia 2 (ROADMAP_COMERCIAL S3): domínio de checkout extraído de
# EconomyService — grant queue idempotente (C1/companion), VIP por gems (F4),
# intenção de checkout (sandbox + gateway) e refund CDC art.49. Composição com
# back-reference (_eco): o serviço não tem transação nem mutex próprios — usa o
# MESMO settleMutex e os MESMOS helpers raw de EconomyService, então a
# semântica de locking é 100% idêntica à de antes da extração (nenhum risco
# novo de concorrência). Os wrappers públicos ficam em EconomyService
# (callers não mudam).

var _eco : EconomyService = null
# WorkOrder #88: deltas de ouro gravados por `_ApplyGrantRaw` na transação em
# aberto. Dicionário de MEMBRO e não parâmetro porque `_IdleTests` confere o
# literal `_ApplyGrantRaw(grant)` na chamada — o caminho único do gold não pode
# custar uma asserção de outra fatia. Limpado por `ProcessPendingGrants` antes de
# cada commit e espelhado no agente carregado depois dele.
var _grantGoldMoves : Dictionary = {}

# ------------------------------------------------------------------ F4: VIP checkout (MONETIZATION §2.2)

# Gems -> vip_until. Extends from the current window when still active.
# Fase B: registra o tier (cap offline 24h/36h) — upgrade nunca rebaixa.
# P1-10 (AUDITORIA_2026-09-27): débito + ledger + janela + tier num SÓ commit.
# Antes eram duas transações (AddGems faz a própria; SetVIPUntil/SetVIPTier
# autocomitam separadas) — crash entre elas deixava gem cobrada sem VIP (ou
# VIP grátis sem gem). Pattern é o vizinho correto: BuyChests/BuyDailyOffer
# (settleMutex + Transaction + ops raw; SetVIPUntil/SetVIPTier já são raw por
# natureza — auditoria A).
func PurchaseVIP(accountID : int, tier : int) -> bool:
	if tier != 1 and tier != 2:
		return false
	var cost : int = EconomyCatalog.VIP1CostGems if tier == 1 else EconomyCatalog.VIP2CostGems
	var now : int = SQLCommons.Timestamp()
	var currentUntil : int = Launcher.SQL.GetVIPUntil(accountID)
	var base : int = maxi(now, currentUntil)		# stack time when already VIP
	var until : int = base + EconomyCatalog.VIPDays * 86400
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -cost, balance - cost, "vip%d_purchase" % tier):
			return false
		if not sql.SetVIPUntil(accountID, until):
			return false
		if tier > sql.GetVIPTier(accountID) or currentUntil <= now:
			if not sql.SetVIPTier(accountID, tier):
				return false
		return true):
		ok = true
	_eco.settleMutex.unlock()
	return ok

# ------------------------------------------------------------------ starter offer / pending grants / checkout intent

func GetStarterOfferState(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT created_timestamp FROM account WHERE account_id = ?;", [accountID])
	if rows.is_empty():
		return {"eligible": false, "reason": "unknown_account", "expires_at": 0}
	var now : int = SQLCommons.Timestamp()
	var created : int = int(rows[0].get("created_timestamp", 0))
	if created <= 0:
		created = now
	var prior : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM grant_queue WHERE account_id = ? AND payload LIKE ? AND status IN ('pending', 'processed');", [accountID, '%"sku": "' + EconomyCatalog.STARTER_SKU + '"%'])
	if not prior.is_empty() and int(prior[0].get("n", 0)) > 0:
		return {"eligible": false, "reason": "already_claimed", "expires_at": 0}
	var expiresAt : int = created + EconomyCatalog.STARTER_MAX_AGE_SEC
	if now > expiresAt:
		return {"eligible": false, "reason": "expired", "expires_at": expiresAt}
	return {"eligible": true, "reason": "ok", "expires_at": expiresAt}

func GetPendingGrants(accountID : int) -> Array:
	var out : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT idempotency_key, payload, created_at FROM grant_queue WHERE account_id = ? AND status = 'pending' ORDER BY id LIMIT 10;", [accountID]):
		var sku : String = "?"
		var parsed : Variant = JSON.parse_string(str(row.get("payload", "")))
		if parsed is Dictionary:
			sku = str((parsed as Dictionary).get("sku", "?"))
		out.append({"key": str(row.get("idempotency_key", "")), "sku": sku, "created_at": int(row.get("created_at", 0))})
	return out

# Intenção de checkout (Fase A sandbox + P1 gateway real):
# Fase A (sandbox): retorna external_reference, label, preço (BRL).
# Fase P1 (Mercado Pago / Stripe): external_reference usado para webhook.
# A comunidade idle RPG (r/incremental_games) aceita monetização se:
# - F2P pode obter tudo jogando (mesmo que lento) — Wami / NGU Idle model.
# - VIP = Quality of Life (offline cap, velocidade) — não power direto.
func GetCheckoutIntent(accountID : int, sku : String) -> Dictionary:
	# §24-11 (Lei 15.211/2025): sem a declaração maior de idade vigente não existe
	# checkout — nem preço. O gate de login (`IsConsentAccepted` em Server.gd) barra
	# a entrada, mas dinheiro é decidido aqui, e um client que pule o diálogo de
	# re-aceite não pode pular isto.
	if not Launcher.SQL.IsConsentAccepted(accountID, NetworkCommons.AgreementTosVersion, NetworkCommons.AgreementPrivacyVersion):
		return {"ok": false, "reason": "consent_required"}
	var entry : Dictionary = {}
	for e in EconomyCatalog.SHOP_CATALOG:
		if str(e.get("sku", "")) == sku:
			entry = e
			break
	if entry.is_empty():
		return {"ok": false, "reason": "unknown_sku"}
	if sku == EconomyCatalog.STARTER_SKU:
		var offer : Dictionary = GetStarterOfferState(accountID)
		if not bool(offer.get("eligible", false)):
			return {"ok": false, "reason": str(offer.get("reason", "ineligible")), "starter_offer": offer}
	var intent : Dictionary = {"ok": true, "account_id": accountID, "sku": sku,
		"external_reference": "%d:%s" % [accountID, sku],
		"label": str(entry.get("label", sku)), "price": float(entry.get("price", 0.0)),
		"currency": "BRL",
		# Saída de gate de dinheiro: `gateway_ready`, `f2p_friendly` e
		# `webhook_verified` saíram desta payload em 2026-09-24. Eram três `true`
		# literais que este processo não pode atestar — ele não expõe endpoint de
		# webhook, não valida assinatura nenhuma e não conhece a configuração do
		# gateway. Quem valida é o companion (`companion/server.py`: HMAC do
		# provedor + re-fetch autoritativo na API, fail-closed, cobertura em
		# `companion/test_security.py`), e publicar a afirmação como fato bastou
		# para cinco documentos a citarem como evidência de "economia pronta"
		# (`archive/AUDITORIA_INDEPENDENTE_2026-09-24.md` §24). O que sobrou é o que
		# este servidor garante e a suíte mede: `grant_queue` é idempotente pela
		# chave, então a reentrega do webhook não credita duas vezes.
		"grant_queue_idempotent": true}
	# K1: `checkout_intent` = a pessoa viu o preço e abriu o checkout. Sem este
	# evento só existe o lado da entrega, e a razão entre os dois é o que diz se o
	# preço/offer está errado — antes da compra, essa diferença é invisível.
	if Launcher.Telemetry != null:
		Launcher.Telemetry.RecordMoney("checkout_intent", accountID, 0, JSON.stringify({
			"sku" = sku, "price" = float(entry.get("price", 0.0)), "currency" = "BRL"}))
	return intent

# O SKU base do passe à venda AGORA, resolvido pela linha ativa do banco — nunca
# por literal em código de transporte. "" = não há passe: sem temporada ativa, ou
# com `rules_frozen` ilegível (ver `SeasonConfig.PremiumSkuOfRow`).
func ActivePassSku() -> String:
	return SeasonConfig.PremiumSkuOfRow(_eco.ActiveSeason())

# Intent do botão do passe (`Server.BuyPass`). O defeito que aqui se fecha: o
# transport escolhia o SKU por termo de condicional — `"pass.s1" if standard else
# "pass.s1.deluxe"` — e com a sucessora agendada no ar o botão passava a pedir o
# passe de OUTRA temporada: SKU cobrável nos quatro catálogos, preço certo, e um
# grant que escreve premium na temporada ativa. A temporada decide o SKU; a porta
# do dinheiro continua sendo `GetCheckoutIntent`, então um deluxe que o catálogo
# não declara (hoje: `pass.s2.deluxe`) morre em `unknown_sku` antes de cobrar.
func GetPassCheckoutIntent(accountID : int, tier : String) -> Dictionary:
	var base : String = ActivePassSku()
	if base.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sku : String = "%s.deluxe" % base if tier == "deluxe" else base
	return GetCheckoutIntent(accountID, sku)

# ------------------------------------------------------------------ C1: companion grants (grant queue)

# Kinds aceitos (outros → failed, sem parcial). gold exige
# {"char_id": N} no payload, e o char deve pertencer à conta.

# Fase B: tier carregado por grants vip_days (payload sku). Trial/companion
# entram como tier 1; só vip.3mo sobe a 2. Nunca rebaixa tier ativo.

# Enfileira um grant (idempotente pela chave: duplicada NA MESMA CONTA = já na
# fila, sem erro). A idempotência é a única coisa que torna a reentrega do webhook
# inofensiva, e ela só vale para a conta que recebeu o payment: a UNIQUE de
# `idempotency_key` é global, então conferir só a chave devolvia `true` — "está na
# fila" — para uma linha de OUTRA conta, e o INSERT nunca acontecia. O dinheiro
# sumia com resposta de sucesso, que é a pior combinação possível nesta fronteira.
func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}", pricePaid : int = 0, currency : String = "") -> bool:
	if idempotencyKey.is_empty() or amount <= 0 or not EconomyCatalog.GrantKinds.has(kind):
		return false
	var sql : SQLService = Launcher.SQL
	var keyed : Array = sql.QueryBindings("SELECT account_id FROM grant_queue WHERE idempotency_key = ?;", [idempotencyKey])
	if not keyed.is_empty():
		# Mesmo dono = reentrega do mesmo payment: é onde a idempotência protege, e ela
		# devolve true sem inserir de novo. Dono DIFERENTE = colisão de chave (payment
		# reusado por engano por quem opera a fila, ou external_reference forjado);
		# recusar é o único veredito honesto, e deixa a fila intacta para correção.
		return int((keyed[0] as Dictionary).get("account_id", -1)) == accountID
	if sql.QueryBindings("SELECT account_id FROM account WHERE account_id = ?;", [accountID]).is_empty():
		return false
	# B (auditoria 2026-09-24): `pricePaid` é o que o provedor cobrou (centavos),
	# não o que o jogo concedeu — a coluna é de 044 e é ela que separa dinheiro
	# de sandbox. Um grant com price 0 entra como unidade de jogo e o estorno do
	# art.49 não tem o que devolver.
	return sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at, price_paid, currency) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?);", [idempotencyKey, accountID, kind, amount, payload, SQLCommons.Timestamp(), pricePaid, currency])

# Consome a fila: cada grant na própria transação (um ruim não trava os outros).
# Retorna {"processed": N, "failed": M}.
func ProcessPendingGrants(limit : int = 50) -> Dictionary:
	var done : Dictionary = {"processed" = 0, "failed" = 0}
	_eco.settleMutex.lock()
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, idempotency_key, account_id, kind, amount, payload, price_paid, currency FROM grant_queue WHERE status = 'pending' ORDER BY id LIMIT ?;", [limit])
	for row in rows:
		var grantID : int = int(row["id"])
		_grantGoldMoves.clear()
		if Launcher.SQL.Transaction(_GrantApplyAndMark.bind(row, grantID)):
			# WorkOrder #88: o ouro que o commit gravou no banco só chega ao agente
			# depois dele — aplicado antes, um rollback deixaria gold no jogador que
			# o provedor não pagou.
			_eco.kernel.ApplyGoldMoves(_grantGoldMoves)
			done["processed"] = int(done["processed"]) + 1
			_RecordPurchase(row)
			# O rombo do clawback é medido DEPOIS do commit e relendo o ledger:
			# dentro do lambda seria lock recursivo num queryMutex não-recursivo
			# (mesma regra documentada em _RecordPurchase) e um veredito guardado em
			# local não sobreviveria ao closure — GDScript captura por valor. Reler o
			# que de fato commitou é a única fonte honesta do "quanto foi tomado".
			if str(row.get("kind", "")) == "chargeback":
				_FlagChargebackShortfall(row)
		else:
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'failed', error = 'apply_failed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["failed"] = int(done["failed"]) + 1
	_eco.settleMutex.unlock()
	return done

# ------------------------------------------------------------------ P1-6b: rombo do clawback
# O provedor toma o DINHEIRO e não diz quanto ainda existe de gem paga no jogo:
# `amount` do chargeback vem do CATÁLOGO (companion), nunca do saldo. Então a
# dívida pode ser maior do que o tomável, e um débito parcial silencioso é
# prejuízo que ninguém vê. Duas saídas, as duas lidas por gente:
#   1. a coluna `error` da PRÓPRIA linha da fila, com o token de motivo (o
#      operador acha por `grant_queue`, ao lado do payment que originou);
#   2. uma flag na fila de revisão antifraude, pela API do detector
#      (FraudeReview.ChargebackShortfall) — nunca INSERT daqui, o guard
#      tests/fraud_test.gd S-G prende quem escreve em fraud_flag por fora.
# O valor que faltou fica no `detail`/`evidence` da flag junto do payment, do
# pedido e do tomado: sem isso a conta fecha no buraco e ninguém sabe o buraco.
func _FlagChargebackShortfall(grant : Dictionary) -> void:
	var sql : SQLService = Launcher.SQL
	var accountID : int = int(grant["account_id"])
	var paymentID : String = _PaymentIDOf(grant)
	if paymentID.is_empty():
		return
	# Relê o próprio commit (não o closure): o que importa é o débito que virou
	# linha de ledger, inclusive quando a pré-checagem de idempotência devolveu
	# 'true' sem debitar nada — aí a linha lida é a da primeira entrega.
	var clawRows : Array[Dictionary] = sql.QueryBindings("SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason = ? ORDER BY id DESC LIMIT 1;", [accountID, "clawback:" + paymentID])
	if clawRows.is_empty():
		return
	var taken : int = maxi(0, -int(clawRows[0]["amount"]))
	var owed : int = maxi(0, int(grant["amount"]))
	if taken >= owed:
		return
	var sku : String = ""
	var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
	if parsed is Dictionary:
		sku = str((parsed as Dictionary).get("sku", ""))
	# Token de motivo legal para ReasonCodes (minúsculas + underscore): é o que o
	# toast/fila mostram quando alguém traduzir; sem tradução ele volta cru de
	# propósito (ver o cabeçalho de sources/ops/ReasonCodes.gd — a tabela de texto
	# mora em data/i18n/ui.csv e não neste arquivo).
	var reason : String = ReasonCodes.ChargebackShortfall
	# `error` é coluna de diagnóstico da fila (o único outro escritor hoje é
	# 'apply_failed'), e o status continua 'processed': a linha foi aplicada, o
	# que não coube nela é dívida visível, não falha de aplicação.
	if not sql.ExecuteBindings("UPDATE grant_queue SET error = ? WHERE id = ? AND status = 'processed';", [reason, int(grant["id"])]):
		return
	# O rombo já está visível na fila de grants; a flag de revisão é o que põe a
	# conta na fila onde o operador entra todo dia. Comunidade nula (boot parcial)
	# não pode derrubar o flush da fila — o UPDATE acima já é o registro mínimo.
	if _eco.communityService != null:
		_eco.communityService.ChargebackShortfall(accountID, paymentID, owed, taken, sku, int(grant["id"]))

# SOM-IDLE E3: o crédito e a marcação da fila são o MESMO commit. Marcar
# 'processed' depois do Transaction() fechar deixava uma janela: derrubar o
# processo entre o COMMIT do saldo e o UPDATE mantinha a linha 'pending' e o
# próximo tick creditava de novo — ledger_transaction não tem UNIQUE em reason,
# então nada barrava o segundo lançamento (dinheiro falso).
#
# Dentro do commit: (1) reivindicar a linha, (2) creditar, (3) fechar. Qualquer
# passo que falhe faz ROLLBACK dos três. ExecuteBindings devolve true também
# quando o UPDATE não altera linha nenhuma, por isso a releitura — sem ela uma
# linha já consumida seria creditada de novo.
func _GrantApplyAndMark(grant : Dictionary, grantID : int) -> bool:
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	if not sql.ExecuteBindings("UPDATE grant_queue SET status = 'processing', processed_at = ? WHERE id = ? AND status = 'pending';", [now, grantID]):
		return false
	var claimed : Array = sql.QueryBindings("SELECT status FROM grant_queue WHERE id = ?;", [grantID])
	if claimed.is_empty() or str((claimed[0] as Dictionary).get("status", "")) != "processing":
		return false
	if not _ApplyGrantRaw(grant):
		return false
	return sql.ExecuteBindings("UPDATE grant_queue SET status = 'processed', processed_at = ? WHERE id = ?;", [now, grantID])

# K1: `purchase` = dinheiro ENTREGUE (não "autorizado"). Emitido depois do COMMIT
# do grant e nunca dentro dele: o flush da telemetria abre a própria transação e
# `SQLService.Transaction` pega o queryMutex — chamar de dentro de um lambda seria
# lock recursivo numa Mutex não-recursiva. `price_paid` é o que o provedor cobrou
# (migration 044; bundle só paga na primeira perna), então somar a coluna separa
# receita de grant de sandbox/GM, que chega com 0.
func _RecordPurchase(grant : Dictionary) -> void:
	if Launcher.Telemetry == null:
		return
	var sku : String = "?"
	var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
	if parsed is Dictionary:
		sku = str((parsed as Dictionary).get("sku", "?"))
	# O clawback tem price_paid do payment original no payload (foi assim que o
	# provedor cobrou). Registrar a linha como "purchase" faria a receita somar
	# justamente na linha que a tirou.
	var eventKind : String = "chargeback" if str(grant["kind"]) == "chargeback" else "purchase"
	Launcher.Telemetry.RecordMoney(eventKind, int(grant["account_id"]), 0, JSON.stringify({
		"sku" = sku, "kind" = str(grant["kind"]), "amount" = int(grant["amount"]),
		"price_paid" = int(grant.get("price_paid", 0)), "currency" = str(grant.get("currency", ""))}))

# payment_id é o que sobrevive entre a linha original e o clawback: o companion usa
# o id do payment como chave do grant e '<id>:chargeback' como chave do clawback, e
# grava o id no payload. O recorte da chave é o fallback de um grant criado à mão
# pelo operador, que pode trazer a chave sem o payload completo.
func _PaymentIDOf(grant : Dictionary) -> String:
	var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
	if parsed is Dictionary:
		var pid : String = str((parsed as Dictionary).get("payment_id", ""))
		if not pid.is_empty():
			return pid
	var key : String = str(grant.get("idempotency_key", ""))
	if key.ends_with(":chargeback"):
		return key.substr(0, key.length() - len(":chargeback"))
	return key

# Aplica um grant DENTRO de Transaction() — só ops raw (db direto, sem mutex).
func _ApplyGrantRaw(grant : Dictionary) -> bool:
	var sql : SQLService = Launcher.SQL
	var dbNode : SQLite = sql.db
	var accountID : int = int(grant["account_id"])
	var kind : String = str(grant["kind"])
	var amount : int = int(grant["amount"])
	var now : int = SQLCommons.Timestamp()
	if dbNode.select_rows("account", "account_id = %d" % accountID, ["account_id"]).is_empty():
		return false
	# P1-6 (auditoria 2026-09-27): chargeback não é grant, é o reverso. O companion
	# enfileira kind='chargeback' quando o webhook chega 'charged_back' — evento
	# que nenhum webhook nosso precede, então sem consumo o jogador ficava com as
	# gems e o prejuízo morava só no provedor.
	#
	# Idempotência em duas camadas: a UNIQUE do companion ('<payment>:chargeback')
	# e a pré-checagem de ledger abaixo, que é o que vale se o operador
	# re-enfileirar o mesmo payment sob outra chave.
	if kind == "chargeback":
		var paymentID : String = _PaymentIDOf(grant)
		if paymentID.is_empty():
			return false
		if not sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, "clawback:" + paymentID]).is_empty():
			return true
		var clawBal : int = sql.GetGemsRaw(accountID)
		# P1-6b: o teto do débito é a parte PAGA do saldo (`gems_paid`), nunca o
		# saldo inteiro. O débito antigo era `min(gems, amount)` e isso punia a
		# pessoa errada: gasto as 550 gems compradas, o faucet F2P me dá 200 de
		# anúncio, chega o chargeback e o jogo toma 200 gems que eu NUNCA paguei —
		# gem grátis queimada por um débito de gem paga. É o inverso exato do portão
		# do art.49, que exige `gems_paid >= amount` (gate `not_paid` em
		# RequestGemRefund) precisamente porque saldo total não prova ORIGEM. O
		# mesmo raciocínio vale na reversão: só se toma o que ainda é dinheiro.
		#
		# `clampi(..., 0, clawBal)` não é superstição: `gems_paid <= gems` é
		# invariante do SetGemsRaw, e um wallet acima disso (escrita fora do caminho
		# único) não pode autorizar débito maior do que existe — nunca negativo.
		#
		# Débito parcial/zero NÃO é falha: 'failed' entupiria a fila para sempre e
		# gem negativa atravessada no portão de origem seria o mesmo dano de antes.
		# O que muda é que o rombo deixa de morar só na cabeça de quem escreveu o
		# código: _FlagChargebackShortfall(), chamado depois do commit, grava o
		# motivo na própria linha da fila e abre a fila de revisão.
		# LIMITAÇÃO assumida — é por isso que o rombo vira fila e não asserção:
		# `gems_paid` é por CONTA, não por compra. Se o provedor abrir chargeback de
		# um payment que nunca foi entregue nesta conta (external_reference errado,
		# payment re-usado, fraude), o teto acima ainda pode tomar gem paga de OUTRA
		# compra do mesmo jogador. Fechar isso de vez passaria por exigir o
		# `grant:<payment>` no ledger antes de debitar — mas aí o chargeback que
		# chega ANTES do grant original ser processado (aprovado→contestado entre
		# dois ticks, e o grant continua 'pending' na fila) seria jogado fora e o
		# prejuízo voltaria a morar só no provedor. Escolha: tomar até o teto pago e
		# DENUNCIAR a diferença (payment, pedido, tomado e faltando na flag), que é
		# o que um operador consegue conferir; gem grátis continua intocável.
		var owed : int = maxi(0, amount)
		var debit : int = mini(owed, clampi(sql.GetGemsPaidRaw(accountID), 0, clawBal))
		if debit > 0 and not sql.SetGemsRaw(accountID, clawBal - debit):
			return false
		# A linha de ledger nasce mesmo com débito 0, e isso é deliberado: é ela que
		# fecha a porta do art.49 para este payment (RequestPurchaseRefund consulta
		# `clawback:<payment>` antes de devolver de novo) e é ela que torna a
		# redelivery idempotente por payment, não por tentativa de débito.
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -debit, clawBal - debit, "clawback:" + paymentID):
			return false
		# work order #97: até aqui o chargeback tomava o dinheiro e DEIXAVA O BEM.
		# O `amount` da linha vem do catálogo e só existia débito de gem, então
		# `pass.s2` contestado continuava premium e `vip.1mo` contestado
		# continuava com a janela. Revogam-se as pernas do payment original, na
		# MESMA transação do clawback; as gems NÃO são debitadas de novo aqui
		# (`takeGems` = false) porque o débito acima já é a perna de dinheiro —
		# tomá-la duas vezes seria o rombo do jogador pagando pelo prejuízo do
		# provedor. Idempotência: a pré-checagem de `clawback:` acima devolve true
		# numa redelivery, então esta revogação roda uma vez por payment.
		var cbLegs : Array[Dictionary] = _PurchaseLegs(accountID, paymentID)
		if not cbLegs.is_empty():
			# O delta de ouro entra no MESMO dict da linha da fila, que
			# `ProcessPendingGrants` aplica logo depois do commit (WorkOrder #88).
			var cbRes : Dictionary = _RevokePurchaseRaw(accountID, cbLegs, "revoke", now, false, _grantGoldMoves)
			if not bool(cbRes.get("ok", false)):
				return false
		return true
	if kind == "gems":
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + amount):
			return false
		# B (auditoria 2026-09-24): dinheiro entregue vira saldo pago; grant de
		# sandbox/GM (price 0, K1) é unidade de jogo e não tem o que estornar.
		if int(grant.get("price_paid", 0)) > 0 and not sql.AddGemsPaidRaw(accountID, amount):
			return false
		return _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, amount, balance + amount, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "gold":
		var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
		if not (parsed is Dictionary):
			return false
		var charID : int = int((parsed as Dictionary).get("char_id", 0))
		if charID <= 0 or _eco._AccountIDForCharacterRaw(charID) != accountID:
			return false
		var statRows : Array = dbNode.select_rows("stat", "char_id = %d" % charID, ["gp"])
		if statRows.is_empty():
			return false
		# WorkOrder #88: o crédito de um grant pago passa pelo caminho único do
		# kernel (`EconomyKernel._MoveGoldLocked`): lê o saldo no banco, grava
		# `stat.gp`, espelha no ledger e acumula o delta em `_grantGoldMoves` para o
		# agente carregado. A escrita crua de `stat` aqui era apagada na direção
		# oposta à do vendor: o jogador recebia o ouro do provedor e o snapshot de
		# 600 s devolvia o valor antigo, que é dinheiro real desaparecendo.
		return _eco.kernel._MoveGoldLocked(sql, charID, accountID, amount, "grant:%s" % str(grant["idempotency_key"]), _grantGoldMoves)
	if kind == "vip_days":
		var vipRows : Array = dbNode.select_rows("account", "account_id = %d" % accountID, ["vip_until", "vip_tier"])
		var current : int = int(vipRows[0].get("vip_until", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_until", null) != null else 0
		var until : int = maxi(now, current) + amount * 86400
		if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_until" = until}):
			return false
		# Fase B: grants carregam tier pelo SKU (trial/companion nunca rebaixa).
		var grantedTier : int = 1
		var parsedSku : Variant = JSON.parse_string(str(grant.get("payload", "")))
		if parsedSku is Dictionary:
			grantedTier = int(EconomyCatalog.VIP_GRANT_TIERS.get(str((parsedSku as Dictionary).get("sku", "")), 1))
		var curTier : int = int(vipRows[0].get("vip_tier", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_tier", null) != null else 0
		if grantedTier > curTier or current <= now:
			if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_tier" = grantedTier}):
				return false
		return _eco._LedgerAppendLocked(accountID, 0, "vip", amount, until, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "pass_premium":
		# Fase C: premium do passe (companion sku pass.s1). Aplica na temporada
		# do payload ou na ativa; sem temporada ativa → failed (venda só
		# durante a temporada, calendário live-ops). Idempotente por linha.
		# Follow-up Deluxe (BATTLE_PASS_S1 §4): tier deluxe soma 10 níveis
		# (PT até L10), emote Coroa do Sol e 150 gems — preço no catálogo.
		var parsedPass : Variant = JSON.parse_string(str(grant.get("payload", "")))
		var sid : int = 0
		var tier : String = "standard"
		if parsedPass is Dictionary:
			if int((parsedPass as Dictionary).get("season_id", 0)) > 0:
				sid = int((parsedPass as Dictionary)["season_id"])
			if str((parsedPass as Dictionary).get("tier", "")) == "deluxe":
				tier = "deluxe"
		if sid <= 0:
			var active : Dictionary = _eco.ActiveSeason()
			if active.is_empty():
				return false
			sid = int(active.get("season_id", 0))
		if sid <= 0:
			return false
		var st : Dictionary = _eco._PassStateRaw(accountID, sid)
		if int(st.get("premium", 0)) == 0:
			if not sql.ExecuteBindings("UPDATE season_account_state SET premium = 1 WHERE account_id = ? AND season_id = ?;", [accountID, sid]):
				return false
		if not _eco._LedgerAppendLocked(accountID, 0, "pass", 1, 1, "grant:%s" % str(grant["idempotency_key"])):
			return false
		if tier == "deluxe":
			var maxPT : int = int((EconomyCatalog.PassThresholds() as Array).back())
			var boosted : int = mini(maxi(int(st.get("pt", 0)), 1000), maxPT)
			if not sql.ExecuteBindings("UPDATE season_account_state SET pt = ? WHERE account_id = ? AND season_id = ?;", [boosted, accountID, sid]):
				return false
			if not sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, 'emote_coroa', ?, ?);", [accountID, "grant:%s" % str(grant["idempotency_key"]), now]):
				return false
			var gbal : int = sql.GetGemsRaw(accountID)
			if not sql.SetGemsRaw(accountID, gbal + 150):
				return false
			# B: as 150 do deluxe são dinheiro se esta linha carregou preço — o
			# bundle põe o preço numa só perna (044), então nas demais elas entram
			# como unidade de jogo e o estorno da perna fica com o operador.
			if int(grant.get("price_paid", 0)) > 0 and not sql.AddGemsPaidRaw(accountID, 150):
				return false
			if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, 150, gbal + 150, "grant:%s" % str(grant["idempotency_key"])):
				return false
		return true
	if kind == "cosmetic":
		# Fase F: cosmético direto (doação "apoiar" → título Apoiador; futuro:
		# presentes). O cosmetic_id vem do payload (catálogo do companion).
		var parsedCos : Variant = JSON.parse_string(str(grant.get("payload", "")))
		var cid : String = str((parsedCos as Dictionary).get("cosmetic_id", "")) if parsedCos is Dictionary else ""
		if cid.is_empty() or not EconomyCatalog.COSMETIC_CATALOG.has(cid):
			return false
		if not sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, cid, "grant:%s" % str(grant["idempotency_key"]), now]):
			return false
		return _eco._LedgerAppendLocked(accountID, 0, "cosmetic", 1, 1, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "item":
		# Item de crafting (criado pelo jogador, aprovado pelo GM).
		# O payload contém item_id (hash) e o item precisa existir no DB
		# para ser aplicado ao inventário do char vinculado à conta.
		var parsedItem : Variant = JSON.parse_string(str(grant.get("payload", "")))
		var itemHash : int = 0
		var charRef : int = 0
		if parsedItem is Dictionary:
			itemHash = int((parsedItem as Dictionary).get("item_id", 0))
			charRef = int((parsedItem as Dictionary).get("char_id", 0))
		if itemHash <= 0:
			return false
		if charRef > 0 and _eco._AccountIDForCharacterRaw(charRef) != accountID:
			return false
		var itemCount : int = amount
		var appliedItem : bool = false
		if Launcher.SQL.Transaction(func() -> bool:
			var sqlItem : SQLService = Launcher.SQL
			var itemRows : Array = sqlItem.db.select_rows("item", "item_id = %d" % itemHash, ["item_id"])
			if itemRows.is_empty():
				sqlItem.db.insert_row("item", {"item_id" = itemHash, "char_id" = charRef, "count" = 0, "storage" = 0, "customfield" = ""})
			var existingInv : Array = sqlItem.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, charRef], ["count"])
			if existingInv.is_empty():
				if not sqlItem.db.insert_row("item", {"item_id" = itemHash, "char_id" = charRef, "count" = itemCount, "storage" = 0, "customfield" = ""}):
					return false
			else:
				var currentCount : int = int(existingInv[0]["count"]) if existingInv[0].get("count", null) != null else 0
				if not sqlItem.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, charRef], {"count" = currentCount + itemCount}):
					return false
			return _eco._LedgerAppendLocked(accountID, charRef, EconomyCatalog.LedgerKindItem, itemCount, 0, "grant:%s" % str(grant["idempotency_key"]))):
			appliedItem = true
		if not appliedItem:
			return false
		return true
	return false

# ------------------------------------------------------------------ reversão por SKU (work order #97)
#
# A unidade da reversão passou a ser a COMPRA (as pernas que o ledger registrou
# sob `grant:<chave>`), não o `kind` do ledger. O defeito fechado: a reversão
# conhecia só gemas — `SELECT ... kind = 'gems' AND reason = 'grant:<key>'` —
# então para os 8 SKUs não-gemas de `data/conf/paid_catalog.json` (`vip.1mo`,
# `vip.3mo`, `pass.s1`, `pass.s1.deluxe`, `pass.s2`, `donate.support`,
# `starter.pack`, `founder.pack`) o art.49 respondia `not_found`: o dinheiro
# voltava no provedor e nada voltava no jogo. `pass.s1.deluxe` era o pior caso —
# a perna de 150 gems aparecia, o `premium` da temporada não. No chargeback, o
# `amount` vem do catálogo e só existia débito de gem: passe/VIP ficavam de pé.
#
# O que cada SKU dá (lido de `_ApplyGrantRaw`, e é exatamente isso que se toma):
#   gems          -> saldo + `gems_paid`                (perna kind 'gems')
#   vip_days      -> `account.vip_until` (e `vip_tier`) (perna kind 'vip')
#   pass_premium  -> `season_account_state.premium`; deluxe soma ainda chão de
#                    1000 PT, o emote 'emote_coroa' e 150 gems (pernas 'pass' e
#                    'gems' na MESMA chave)
#   cosmetic      -> `cosmetic_grant` com source `grant:<chave>`
#   bundle        -> N pernas com chaves derivadas `<payment>:<i>:<kind>`
# Itens: `EconomyCatalog.GrantKinds` não declara 'item' e nenhum SKU pago dá
# item, então o ramo 'item' de `_ApplyGrantRaw` é inalcançável por dinheiro — não
# existe lote de `starter.pack`/`founder.pack` a revogar. É a régua do harness
# (`tests/refund_revocation_test.gd`) que mede isso no catálogo, não esta linha.
#
# REGRA DE REVOGAÇÃO: TOTAL, nunca pro-rata por tempo decorrido.
#  - o art.49 do CDC é arrependimento INTEGRAL: o preço volta inteiro e o bem
#    volta inteiro. Descontar o que já se "usou" é outro regime (rescisão /
#    decomposição parcial de serviço) e não é o direito exercido aqui;
#  - a granularidade do bem é o DIA (`vip_until` em dias, premium em bit,
#    cosmético em posse) e a janela é de 7 DIAS: pro-ratar daria 27/30 ou 3/30
#    conforme a hora do pedido e devolveria dinheiro por dias que continuariam
#    no ar. O que se subtrai é o `amount` que o grant CONCEDEU, com chão no
#    mínimo natural do estado (`vip_until` >= 0, `premium` = 0, posse removida);
#  - o que NÃO se toma: `season_account_state.pt` e os prêmios já CLAIMED. `pt`
#    é contador compartilhado com a trilha grátis (subtraí-lo tiraria progresso
#    JOGADO, não comprado) e o claim premium escreve `cosmetic_grant` com source
#    própria (`pass:<...>`), não `grant:<chave>` — a posse revogada é só a que
#    este payment deu. A porta do bem comprado é o bit `premium`: sem ele nada
#    mais é claimável na trilha paga, e o chão de 1000 PT do deluxe perde o
#    efeito. Limitação assumida, e o harness afirma justamente que pt não muda.
#
# Append-only: nenhuma linha de ledger é UPDATEada nem apagada (trigger
# `ledger_transaction_no_update`, migration 009). A revogação é SEMPRE linha nova
# com valor negativo e reason do family `refund:` (art.49) / `revoke:`
# (chargeback) — que é também o que a torna idempotente: a segunda passada vê a
# linha e não revoga duas vezes. `cosmetic_grant`/`premium`/`vip_until` são
# projeção do estado e por isso se escrevem.

# Uma perna = uma linha de ledger `grant:<chave>` com valor positivo. O ledger
# (append-only) é a única prova do que FOI entregue; `grant_queue` empresta o
# payload (sku/tier/cosmetic_id) e o preço, que são contexto, não verdade.
func _PurchaseLegs(accountID : int, key : String) -> Array[Dictionary]:
	var sql : SQLService = Launcher.SQL
	var rows : Array[Dictionary] = sql.QueryBindings(
		"SELECT kind, amount, char_id, reason, created_at FROM ledger_transaction WHERE account_id = ? AND reason = ? ORDER BY id;",
		[accountID, "grant:" + key])
	if rows.is_empty() and _IsBundleParentKey(key):
		# bundle: o companion deriva as pernas como `<payment>:<i>:<kind>`
		# (`companion/server.py::_enqueue_items`), então a chave do payment nunca
		# aparece sozinha no ledger. O prefixo só é expandido para chave que não
		# pode ser curingua de LIKE — a mesma regra do lookup do companion.
		rows = sql.QueryBindings(
			"SELECT kind, amount, char_id, reason, created_at FROM ledger_transaction WHERE account_id = ? AND reason LIKE ? ORDER BY id;",
			[accountID, "grant:" + key + ":%"])
	var out : Array[Dictionary] = []
	for r in rows:
		var reason : String = str(r.get("reason", ""))
		var amount : int = int(r.get("amount", 0))
		if amount <= 0 or not reason.begins_with("grant:"):
			continue
		out.append({"kind" = str(r.get("kind", "")), "amount" = amount,
			"char_id" = int(r.get("char_id", 0)), "key" = reason.substr(len("grant:")),
			"created_at" = int(r.get("created_at", 0))})
	return out

# Payment id do Mercado Pago é texto de dígitos; chave de fila de operador não é.
# `%`/`_` dentro de um `LIKE` de consulta de dinheiro seria curinga solto (romperia
# a conta de outra pessoa), e `-`/espaço passariam em `is_valid_int` mesmo sem
# serem payment id. Exigir os dois é o que faz a expansão de prefixo ser exata.
func _IsBundleParentKey(key : String) -> bool:
	return not key.is_empty() and key.length() <= 32 and key.find("%") < 0 \
		and key.find("_") < 0 and key.is_valid_int() and int(key) >= 0

# Razões que marcam uma perna como já revertida. A perna de gem usa a forma
# simples (`refund:<chave>`, exatamente como antes deste work order — a linha de
# dinheiro é uma por perna) e as pernas de direito usam o sufixo de kind, porque
# `pass.s1.deluxe` tem DUAS pernas na mesma chave.
func _LegReversalReasons(legKey : String, kind : String) -> Array:
	if kind == EconomyCatalog.LedgerKindGems:
		return ["refund:" + legKey, "revoke:" + legKey,
			"refund:%s:%s" % [legKey, kind], "revoke:%s:%s" % [legKey, kind]]
	return ["refund:%s:%s" % [legKey, kind], "revoke:%s:%s" % [legKey, kind]]

func _LegRevoked(accountID : int, legKey : String, kind : String) -> bool:
	var reasons : Array = _LegReversalReasons(legKey, kind)
	var args : Array = [accountID]
	var marks : String = ""
	for i in range(reasons.size()):
		args.append(str(reasons[i]))
		marks += "(?)" if i == 0 else ", (?)"
	return not Launcher.SQL.QueryBindings(
		"SELECT id FROM ledger_transaction WHERE account_id = ? AND reason IN (%s) LIMIT 1;" % marks,
		args).is_empty()

# Contexto do grant (payload + o que o provedor cobrou) da perna. `price_paid` é
# por linha da fila e o bundle põe o preço só na primeira perna (migration 044),
# então o total da compra é a soma sobre chaves DISTINTAS.
func _GrantContextOf(accountID : int, legKey : String) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT payload, price_paid, currency FROM grant_queue WHERE account_id = ? AND idempotency_key = ? LIMIT 1;",
		[accountID, legKey])
	if rows.is_empty():
		return {"payload" = {}, "price_paid" = 0, "currency" = ""}
	var parsed : Variant = JSON.parse_string(str(rows[0].get("payload", "")))
	var payload : Dictionary = {}
	if parsed is Dictionary:
		payload = parsed
	return {"payload" = payload, "price_paid" = int(rows[0].get("price_paid", 0)),
		"currency" = str(rows[0].get("currency", ""))}

# A temporada do passe: o payload do companion hoje NÃO traz `season_id`
# (`_enqueue_items` grava sku/provider/kind/tier), e o grant escreveu na temporada
# ativa à época. Revogar na temporada ativa AGORA puniria a sucessora — um
# arrependimento de `pass.s1` depois de aberto o S2 tiraria o passe de quem
# comprou o S2. A ordem é: o que o payload declarar, depois a temporada cujas
# regras congeladas declaram exatamente este SKU, depois a ativa (com o SKU
# desconhecido, que é o estado pré-OPS-2).
func _SeasonIDForPass(payload : Dictionary) -> int:
	var sid : int = int(payload.get("season_id", 0))
	if sid > 0:
		return sid
	var sku : String = str(payload.get("sku", ""))
	if not sku.is_empty():
		for row in Launcher.SQL.QueryBindings(
				"SELECT season_id, rules_frozen, status FROM season ORDER BY season_id DESC LIMIT 16;", []):
			if SeasonConfig.PremiumSkuOfRow(row) == sku:
				return int(row.get("season_id", 0))
	var active : Dictionary = _eco.ActiveSeason()
	return int(active.get("season_id", 0))

# Retira a posse dada por ESTA perna (`cosmetic_grant.source = 'grant:<chave>'`) e
# desequipa o que saiu: `cosmetic_equip` não tem FK (migration 024) e a listagem
# de posse lê o equip direto, então um row órfão continuaria equipado com a
# posse revogada.
func _RevokeCosmeticsRaw(accountID : int, sourceKey : String) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	var rows : Array[Dictionary] = sql.QueryBindings(
		"SELECT id, cosmetic_id FROM cosmetic_grant WHERE account_id = ? AND source = ? ORDER BY id;",
		[accountID, "grant:" + sourceKey])
	if rows.is_empty():
		return {"ok" = true, "removed" = 0}
	var removed : int = 0
	for r in rows:
		if not sql.ExecuteBindings("DELETE FROM cosmetic_grant WHERE id = ? AND account_id = ?;", [int(r["id"]), accountID]):
			return {"ok" = false, "removed" = removed}
		if not sql.ExecuteBindings("DELETE FROM cosmetic_equip WHERE account_id = ? AND cosmetic_id = ?;", [accountID, str(r.get("cosmetic_id", ""))]):
			return {"ok" = false, "removed" = removed}
		removed += 1
	return {"ok" = true, "removed" = removed}

# Executa a revogação DENTRO do Transaction() do chamador — só ops raw, nenhuma
# mutex própria (mesma regra do resto do arquivo). `prefix` é 'refund' (art.49,
# com o dinheiro voltando) ou 'revoke' (chargeback: o provedor já tomou o
# dinheiro pela linha `clawback:<payment>`, então `takeGems` é false e a perna de
# gem não é debitada de novo). Idempotente por perna: perna com linha do family
# correspondente é pulada.
func _RevokePurchaseRaw(accountID : int, legs : Array, prefix : String, now : int, takeGems : bool, goldMoves : Dictionary) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	var revoked : Array = []
	var gemsReversed : int = 0
	for leg in legs:
		var legDict : Dictionary = leg
		var lk : String = str(legDict["key"])
		var kind : String = str(legDict["kind"])
		var amount : int = int(legDict["amount"])
		if _LegRevoked(accountID, lk, kind):
			continue
		if kind == EconomyCatalog.LedgerKindGems:
			if not takeGems:
				continue
			# O dinheiro volta exatamente como voltava hoje: débito no saldo com
			# `gems_paid` drenado por `SetGemsRaw` e linha negativa no ledger.
			var current : int = sql.GetGemsRaw(accountID)
			if current < amount or sql.GetGemsPaidRaw(accountID) < amount:
				return {"ok" = false, "reason" = "gems_consumed", "revoked" = revoked, "gems_reversed" = 0}
			if not sql.SetGemsRaw(accountID, current - amount):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = 0}
			if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -amount, current - amount, "%s:%s" % [prefix, lk]):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = 0}
			gemsReversed += amount
			revoked.append(kind)
			continue
		if kind == "vip":
			var vipRows : Array = sql.db.select_rows("account", "account_id = %d" % accountID, ["vip_until"])
			var until : int = int(vipRows[0].get("vip_until", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_until", null) != null else 0
			# REGRA: subtrai o DIA que o grant concedeu, chão em 0 — nunca
			# proporcional ao que passou.
			var newUntil : int = maxi(0, until - amount * 86400)
			if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_until" = newUntil}):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			# Tier é o cap de QoL da janela; sem janela ativa não há cap comprado.
			# Não rebaixa quem ainda tem dias de outra compra não revertida.
			if newUntil <= now and not sql.SetVIPTier(accountID, 0):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			if not _eco._LedgerAppendLocked(accountID, 0, kind, -amount, newUntil, "%s:%s:vip" % [prefix, lk]):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			revoked.append(kind)
			continue
		if kind == "pass":
			var passCtx : Dictionary = _GrantContextOf(accountID, lk)
			var passPayload : Variant = passCtx.get("payload", {})
			var passDict : Dictionary = passPayload if passPayload is Dictionary else {}
			var sid : int = _SeasonIDForPass(passDict)
			if sid > 0 and not sql.ExecuteBindings("UPDATE season_account_state SET premium = 0 WHERE account_id = ? AND season_id = ?;", [accountID, sid]):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			if not _eco._LedgerAppendLocked(accountID, 0, kind, -amount, 0, "%s:%s:pass" % [prefix, lk]):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			revoked.append(kind)
			# deluxe: o emote Coroa do Sol foi dado por ESTA perna (source comum)
			var passCos : Dictionary = _RevokeCosmeticsRaw(accountID, lk)
			if not bool(passCos.get("ok", false)):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			if int(passCos.get("removed", 0)) > 0:
				if not _eco._LedgerAppendLocked(accountID, 0, "cosmetic", -int(passCos.get("removed", 0)), 0, "%s:%s:cosmetic" % [prefix, lk]):
					return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
				revoked.append("cosmetic")
			continue
		if kind == "cosmetic":
			var cos : Dictionary = _RevokeCosmeticsRaw(accountID, lk)
			if not bool(cos.get("ok", false)):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			if not _eco._LedgerAppendLocked(accountID, 0, kind, -int(cos.get("removed", 0)), 0, "%s:%s:cosmetic" % [prefix, lk]):
				return {"ok" = false, "reason" = "apply_failed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			revoked.append(kind)
			continue
		if kind == EconomyCatalog.LedgerKindGold:
			var charID : int = int(legDict.get("char_id", 0))
			if charID <= 0:
				continue
			# WorkOrder #88 é o caminho único do ouro: `_MoveGoldLocked` lê o banco,
			# grava `stat.gp`, espelha no ledger e acumula o delta no dict que o
			# chamador aplica DEPOIS do commit. Revogar por fora (escrita crua em
			# `stat`) seria o mesmo defeito do lado inverso. Gold a menos que o
			# pedido é recusa (fail-closed), não débito parcial: `next < 0` no kernel.
			if not _eco.kernel._MoveGoldLocked(sql, charID, accountID, -amount, "%s:%s:gold" % [prefix, lk], goldMoves):
				return {"ok" = false, "reason" = "gold_consumed", "revoked" = revoked, "gems_reversed" = gemsReversed}
			revoked.append(kind)
	return {"ok" = true, "reason" = "", "revoked" = revoked, "gems_reversed" = gemsReversed}

# O que de fato virou linha de ledger, relido DEPOIS do commit (mesma doutrina de
# `_FlagChargebackShortfall`: o veredito é o que o banco tem, não o que o closure
# guardou — GDScript captura por valor).
func _RevokedKindsOf(accountID : int, legs : Array) -> Array:
	var args : Array = [accountID]
	var marks : String = ""
	var first : bool = true
	for leg in legs:
		var legDict : Dictionary = leg
		for reason in _LegReversalReasons(str(legDict["key"]), str(legDict["kind"])):
			args.append(str(reason))
			marks += "(?)" if first else ", (?)"
			first = false
	if first:
		return []
	var out : Array = []
	for row in Launcher.SQL.QueryBindings(
			"SELECT DISTINCT kind FROM ledger_transaction WHERE account_id = ? AND reason IN (%s) ORDER BY kind;" % marks, args):
		out.append(str(row.get("kind", "")))
	return out

# ------------------------------------------------------------------ CDC art.49 — direito de arrependimento
# Compra à distância: o consumidor desiste em 7 dias. "Não consumida" é medido na
# coluna de origem, não no saldo: `wallet.gems_paid` (migration 049) é a parte do
# saldo que ainda é dinheiro entregue, e é ela que tem de cobrir o montante
# comprado. Saldo total não prova nada — com faucet F2P o número se repõe de
# graça e o bem já foi gasto. Regras (na ordem):
#   not_found / window_expired / charged_back / already_refunded /
#   gems_consumed / not_paid.
# O estorno do DINHEIRO cabe ao companion/provedor (o sweep lê `grant_queue.status
# = 'refunded'`); aqui a reversão é integral: devolve-se ao jogo o que o SKU deu —
# as gems na mesma moeda de antes (débito de saldo + `gems_paid` + linha negativa)
# e o DIREITO (janela de VIP, bit premium, posse do cosmético) revogado por perna,
# não por `kind` (work order #97). A recusa continua toda-ou-nada: um
# `founder.pack` com as gems gastas não perde só o VIP — nada muda, porque meia
# reversão de uma compra desfeita é o mesmo rombo visto do outro lado.

func RequestPurchaseRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	if idempotencyKey.is_empty():
		return {"ok" = false, "reason" = "bad_request"}
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	# (1) a compra: TODAS as pernas do ledger sob `grant:<chave>`, qualquer kind
	var legs : Array[Dictionary] = _PurchaseLegs(accountID, idempotencyKey)
	if legs.is_empty():
		return {"ok" = false, "reason" = "not_found"}
	var gemsTotal : int = 0
	var createdAt : int = 0
	for leg in legs:
		var legDict : Dictionary = leg
		if str(legDict["kind"]) == EconomyCatalog.LedgerKindGems:
			gemsTotal += int(legDict["amount"])
		var at : int = int(legDict["created_at"])
		if createdAt == 0 or at < createdAt:
			createdAt = at
	# (2) janela de 7 dias, medida na perna mais antiga da compra
	if now - createdAt > EconomyCatalog.RefundWindowSeconds:
		return {"ok" = false, "reason" = "window_expired"}
	# (3) P1-6: este payment já sofreu clawback — o dinheiro foi tomado pelo
	# provedor e a revogação do chargeback já roda na mesma chave. A checagem vem
	# ANTES do 'already', porque o `revoke:` do chargeback é linha do mesmo family
	# e o motivo honesto aqui é 'charged_back' (régua de IdleTests/fraud_test).
	if not sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, "clawback:" + idempotencyKey]).is_empty():
		return {"ok" = false, "reason" = "charged_back"}
	# (4) já revertida? qualquer perna com linha `refund:`/`revoke:`
	for leg in legs:
		var legDictB : Dictionary = leg
		if _LegRevoked(accountID, str(legDictB["key"]), str(legDictB["kind"])):
			return {"ok" = false, "reason" = "already_refunded"}
	# (5) preço e rótulo: soma sobre chaves DISTINTAS (deluxe tem duas pernas na
	# mesma linha da fila; contar duas vezes inflaria o centavo devolvido)
	var pricePaid : int = 0
	var currency : String = ""
	var sku : String = "?"
	var legKeys : Array = []
	for leg in legs:
		var legDictC : Dictionary = leg
		var lk : String = str(legDictC["key"])
		if legKeys.has(lk):
			continue
		legKeys.append(lk)
		var ctx : Dictionary = _GrantContextOf(accountID, lk)
		pricePaid += int(ctx.get("price_paid", 0))
		if str(ctx.get("currency", "")) != "":
			currency = str(ctx.get("currency", ""))
		var payload : Dictionary = ctx.get("payload", {})
		if str(payload.get("sku", "")) != "":
			sku = str(payload.get("sku", sku))
	# (6) gems não consumidas + prova de origem, só quando há gem a tomar (SKU de
	# tempo/passe não tem saldo a drenar — a porta dele é a revogação do direito)
	if gemsTotal > 0:
		if sql.GetGems(accountID) < gemsTotal:
			return {"ok" = false, "reason" = "gems_consumed"}
		if sql.GetGemsPaid(accountID) < gemsTotal:
			return {"ok" = false, "reason" = "not_paid"}
	# (7) B (auditoria 2026-09-24): o que se devolve tem de ser dinheiro. Grant de
	# sandbox/GM (price 0) não é estornável, nem quando o bem é VIP em vez de gem.
	if pricePaid <= 0:
		return {"ok" = false, "reason" = "not_paid"}
	# aplica a reversão de forma atômica (re-verifica saldo sob o lock)
	var applied : bool = false
	# Dicionário por referência: o que a transição acumula aqui é lido DEPOIS do
	# commit (o bind copia o vínculo, o conteúdo é o mesmo objeto — é por isso que
	# `ProcessPendingGrants` faz `bind(row, grantID)` em vez de fechar por local).
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if sql.Transaction(func() -> bool:
		var res : Dictionary = _RevokePurchaseRaw(accountID, legs, "refund", now, true, goldMoves)
		if not bool(res.get("ok", false)):
			return false
		# Marca a fila: é `status = 'refunded'` que o sweep do companion lê para
		# estornar o dinheiro no provedor, então toda perna da compra sai da
		# fila de entrega, não só a que carregou o preço.
		for key in legKeys:
			if not sql.ExecuteBindings("UPDATE grant_queue SET status = 'refunded', processed_at = ? WHERE account_id = ? AND idempotency_key = ?;", [now, accountID, str(key)]):
				return false
		return true):
		applied = true
	_eco.settleMutex.unlock()
	if not applied:
		return {"ok" = false, "reason" = "gems_consumed"}
	# WorkOrder #88: o espelho em memória do agente só anda depois do commit.
	_eco.kernel.ApplyGoldMoves(goldMoves)
	var revoked : Array = _RevokedKindsOf(accountID, legs)
	if Launcher.Telemetry != null:
		Launcher.Telemetry.RecordMoney("refund", accountID, 0, JSON.stringify({
			"key" = idempotencyKey, "amount" = gemsTotal, "sku" = sku,
			"price_paid" = pricePaid, "currency" = currency, "revoked" = revoked}))
	return {"ok" = true, "reason" = "refunded", "amount" = gemsTotal, "sku" = sku, "revoked" = revoked}

# Nome histórico da reversão (era "gem" porque só gemas eram vistas; work order
# #97). Mantido como alias fino: `deploy/LAUNCH_HANDOFF.md` e a suíte antiga
# citam este nome, e um portão de dinheiro que passa a existir por dois caminhos
# é pior que um nome velho — o caminho é um só, `RequestPurchaseRefund`.
func RequestGemRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	return RequestPurchaseRefund(accountID, idempotencyKey)
