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
		if Launcher.SQL.Transaction(_GrantApplyAndMark.bind(row, grantID)):
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
		# fecha a porta do art.49 para este payment (RequestGemRefund consulta
		# `clawback:<payment>` antes de devolver de novo) e é ela que torna a
		# redelivery idempotente por payment, não por tentativa de débito.
		return _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -debit, clawBal - debit, "clawback:" + paymentID)
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
		var gp : int = int(statRows[0].get("gp", 0)) if statRows[0].get("gp", null) != null else 0
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp + amount}):
			return false
		return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, amount, gp + amount, "grant:%s" % str(grant["idempotency_key"]))
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

# ------------------------------------------------------------------ CDC art.49 — direito de arrependimento
# Compra à distância: o consumidor desiste em 7 dias. "Não consumida" é medido na
# coluna de origem, não no saldo: `wallet.gems_paid` (migration 049) é a parte do
# saldo que ainda é dinheiro entregue, e é ela que tem de cobrir o montante
# comprado. Saldo total não prova nada — com faucet F2P o número se repõe de
# graça e o bem já foi gasto. Regras (na ordem):
#   not_found / window_expired / already_refunded / charged_back /
#   gems_consumed / not_paid.
# O estorno do DINHEIRO cabe ao companion/provedor (onboarding pendente — handoff);
# aqui o jogo reverte as gems + grava no ledger (prova de auditoria, append-only).

func RequestGemRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	if idempotencyKey.is_empty():
		return {"ok" = false, "reason" = "bad_request"}
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	# (1) a compra original: linha de ledger gems criada por grant:<key>
	var buys : Array[Dictionary] = sql.QueryBindings(
		"SELECT id, amount, created_at FROM ledger_transaction WHERE account_id = ? AND kind = ? AND reason = ? ORDER BY id LIMIT 1;",
		[accountID, EconomyCatalog.LedgerKindGems, "grant:" + idempotencyKey])
	if buys.is_empty():
		return {"ok" = false, "reason" = "not_found"}
	var amount : int = int(buys[0]["amount"])
	if amount <= 0:
		return {"ok" = false, "reason" = "not_found"}
	# (2) janela de 7 dias
	if now - int(buys[0]["created_at"]) > EconomyCatalog.RefundWindowSeconds:
		return {"ok" = false, "reason" = "window_expired"}
	# (3) já reembolsada? (linha refund:<key>)
	if not sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, "refund:" + idempotencyKey]).is_empty():
		return {"ok" = false, "reason" = "already_refunded"}
	# (3b) P1-6: este payment já sofreu clawback de chargeback — o dinheiro foi
	# tomado pelo provedor e o débito já saiu do saldo. Deixar o art.49 rodar por
	# cima pagaria o jogador duas vezes pela mesma compra (as gems de OUTRA
	# transação cobrem `gems_paid`, que é por conta, não por compra).
	if not sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, "clawback:" + idempotencyKey]).is_empty():
		return {"ok" = false, "reason" = "charged_back"}
	# (4) gems não consumidas: saldo atual >= montante comprado
	if sql.GetGems(accountID) < amount:
		return {"ok" = false, "reason" = "gems_consumed"}
	# (5) B (auditoria 2026-09-24): a prova é na coluna certa. Saldo total não
	# diz nada sobre ORIGEM — com o faucet F2P (anúncio, passe, settle, loja
	# diária) dá para gastar as gems pagas e repor o número de graça, e o item
	# comprado fica de pé com o dinheiro devolvido. `gems_paid` é o que ainda é
	# dinheiro; conta antiga (pré-049) tem 0 e cai aqui, fail-closed: o operador
	# devolve à mão com o recibo, pelo companion.
	if sql.GetGemsPaid(accountID) < amount:
		return {"ok" = false, "reason" = "not_paid"}
	# aplica o estorno de forma atômica (re-verifica o saldo sob o lock)
	# K1: o valor em centavos mora na fila, não no ledger. Sem lê-lo aqui o evento
	# de reverso não abate receita nenhuma e o ARPU continua contando a venda que
	# foi devolvida.
	var paidRows : Array[Dictionary] = sql.QueryBindings("SELECT price_paid, currency FROM grant_queue WHERE idempotency_key = ? AND account_id = ?;", [idempotencyKey, accountID])
	var pricePaid : int = int(paidRows[0].get("price_paid", 0)) if not paidRows.is_empty() else 0
	var currency : String = str(paidRows[0].get("currency", "")) if not paidRows.is_empty() else ""
	var applied : bool = false
	_eco.settleMutex.lock()
	if sql.Transaction(func() -> bool:
		var current : int = sql.GetGemsRaw(accountID)
		if current < amount or sql.GetGemsPaidRaw(accountID) < amount:
			return false
		if not sql.SetGemsRaw(accountID, current - amount):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -amount, current - amount, "refund:" + idempotencyKey):
			return false
		sql.db.query_with_bindings("UPDATE grant_queue SET status = 'refunded', processed_at = ? WHERE idempotency_key = ? AND account_id = ?;", [now, idempotencyKey, accountID])
		return true):
		applied = true
	_eco.settleMutex.unlock()
	if not applied:
		return {"ok" = false, "reason" = "gems_consumed"}
	if Launcher.Telemetry != null:
		Launcher.Telemetry.RecordMoney("refund", accountID, 0, JSON.stringify({
			"key" = idempotencyKey, "amount" = amount,
			"price_paid" = pricePaid, "currency" = currency}))
	return {"ok" = true, "reason" = "refunded", "amount" = amount}
