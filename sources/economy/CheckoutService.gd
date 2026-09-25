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
func PurchaseVIP(accountID : int, tier : int) -> bool:
	if tier != 1 and tier != 2:
		return false
	var cost : int = EconomyCatalog.VIP1CostGems if tier == 1 else EconomyCatalog.VIP2CostGems
	var now : int = SQLCommons.Timestamp()
	var currentUntil : int = Launcher.SQL.GetVIPUntil(accountID)
	var base : int = maxi(now, currentUntil)		# stack time when already VIP
	var until : int = base + EconomyCatalog.VIPDays * 86400
	if not _eco.AddGems(accountID, -cost, "vip%d_purchase" % tier):
		return false
	if not Launcher.SQL.SetVIPUntil(accountID, until):
		return false
	if tier > Launcher.SQL.GetVIPTier(accountID) or currentUntil <= now:
		Launcher.SQL.SetVIPTier(accountID, tier)
	return true

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
		# (AUDITORIA_INDEPENDENTE_2026-09-24.md §24). Sobrou o que este servidor
		# garante e a suíte mede: `grant_queue` é idempotente pela chave, então a
		# reentrega do webhook não credita duas vezes.
		"grant_queue_idempotent": true}
	# K1: `checkout_intent` = a pessoa viu o preço e abriu o checkout. Sem este
	# evento só existe o lado da entrega, e a razão entre os dois é o que diz se o
	# preço/offer está errado — antes da compra, essa diferença é invisível.
	if Launcher.Telemetry != null:
		Launcher.Telemetry.RecordMoney("checkout_intent", accountID, 0, JSON.stringify({
			"sku" = sku, "price" = float(entry.get("price", 0.0)), "currency" = "BRL"}))
	return intent

# ------------------------------------------------------------------ C1: companion grants (grant queue)

# Kinds aceitos (outros → failed, sem parcial). gold exige
# {"char_id": N} no payload, e o char deve pertencer à conta.

# Fase B: tier carregado por grants vip_days (payload sku). Trial/companion
# entram como tier 1; só vip.3mo sobe a 2. Nunca rebaixa tier ativo.

# Enfileira um grant (idempotente pela chave: duplicada = já na fila, sem erro).
func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}") -> bool:
	if idempotencyKey.is_empty() or amount <= 0 or not EconomyCatalog.GrantKinds.has(kind):
		return false
	var sql : SQLService = Launcher.SQL
	if sql.QueryBindings("SELECT id FROM grant_queue WHERE idempotency_key = ?;", [idempotencyKey]).size() > 0:
		return true
	if sql.QueryBindings("SELECT account_id FROM account WHERE account_id = ?;", [accountID]).is_empty():
		return false
	return sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?);", [idempotencyKey, accountID, kind, amount, payload, SQLCommons.Timestamp()])

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
		else:
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'failed', error = 'apply_failed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["failed"] = int(done["failed"]) + 1
	_eco.settleMutex.unlock()
	return done

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
	Launcher.Telemetry.RecordMoney("purchase", int(grant["account_id"]), 0, JSON.stringify({
		"sku" = sku, "kind" = str(grant["kind"]), "amount" = int(grant["amount"]),
		"price_paid" = int(grant.get("price_paid", 0)), "currency" = str(grant.get("currency", ""))}))

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
	if kind == "gems":
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + amount):
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
# Compra à distância: o consumidor desiste em 7 dias. Como gems são fungíveis,
# "não consumidas" = o saldo atual cobre o montante comprado. Regras (na ordem):
#   não_found / window_expired / already_refunded / gems_consumed.
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
	# (4) gems não consumidas: saldo atual >= montante comprado
	if sql.GetGems(accountID) < amount:
		return {"ok" = false, "reason" = "gems_consumed"}
	# aplica o estorno de forma atômica (re-verifica o saldo sob o lock)
	var applied : bool = false
	_eco.settleMutex.lock()
	if sql.Transaction(func() -> bool:
		var current : int = sql.GetGemsRaw(accountID)
		if current < amount:
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
	return {"ok" = true, "reason" = "refunded", "amount" = amount}
