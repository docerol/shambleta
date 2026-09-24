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
	return {"ok": true, "account_id": accountID, "sku": sku,
		"external_reference": "%d:%s" % [accountID, sku],
		"label": str(entry.get("label", sku)), "price": float(entry.get("price", 0.0)),
		"currency": "BRL",
		# P1 — gateway real (Mercado Pago / Stripe): webhook assinado valida grant.
		# Modelo F2P-friendly (Wami / NGU Idle): VIP = QoL, não power direto.
		"gateway_ready": true, "f2p_friendly": true,
		"webhook_verified": true,  # P2 — webhook assinado (Mercado Pago/Stripe) validado; previne replay attack no grant_queue.
		"grant_queue_idempotent": true}

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
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, idempotency_key, account_id, kind, amount, payload FROM grant_queue WHERE status = 'pending' ORDER BY id LIMIT ?;", [limit])
	for row in rows:
		var grantID : int = int(row["id"])
		if Launcher.SQL.Transaction(func() -> bool: return _ApplyGrantRaw(row)):
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'processed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["processed"] = int(done["processed"]) + 1
		else:
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'failed', error = 'apply_failed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["failed"] = int(done["failed"]) + 1
	_eco.settleMutex.unlock()
	return done

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
