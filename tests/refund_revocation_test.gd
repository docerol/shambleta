extends SceneTree

# Work order #97 (P0, auditor cego): a reversão de dinheiro só conhecia GEMAS.
# `RequestGemRefund` procurava a compra com `kind = 'gems' AND reason =
# 'grant:<key>'` e o chargeback só debitava gem — então estornar ou contestar
# qualquer SKU não-gem devolvia o dinheiro e DEIXAVA o bem de pé. Este harness
# mede o caminho real (`EnqueueGrant` → `ProcessPendingGrants` →
# `RequestPurchaseRefund` / `kind='chargeback'`) sobre o banco do boot, e a régua
# é o ESTADO que o SKU deu: `season_account_state.premium`,
# `account.vip_until`/`vip_tier`, `cosmetic_grant` (+ `cosmetic_equip`),
# `wallet.gems`/`gems_paid`, mais o ledger append-only que prova a reversão.
#
# A regra de revogação (TOTAL, não pro-rata) é medida, não gravada: a suíte C2
# planta uma compra de VIP com 3 DIAS de história (perna de ledger, linha de
# fila e janela como estariam há 3 dias) e afirma que a janela encolhe exatamente
# `amount * 86400` — o que o grant concedeu — e não `amount - elapsed`. Uma
# implementação pro-rata fica vermelha aqui, e ficar se a chamada de revogação
# for removida de `RequestPurchaseRefund`/`_ApplyGrantRaw` (controle negativo).
#
# Uso: bash scripts/test.sh one refund_revocation_test
# Régua do gate: a última linha `== RESULT: N checks, M failures ==`; exit code
# = número de falhas.
#
# Igual aos outros harness `-s`: este arquivo compila ANTES dos class_name do
# projeto, então nada de identificador de projeto em tempo de parse — as classes
# entram por load() e o que vem delas é chamado por call()/get().

const FixDay : int = 86400
const CatalogPath : String = "res://data/conf/paid_catalog.json"

var checks : int = 0
var failures : int = 0
var baseNow : int = 0
var tag : int = 0

var _launcher : Node = null
var _sql = null
var _eco = null
var _nc = null
var _catalog = null
var _sc = null
var _seasonID : int = 0

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
		return false
	print("  [ok] " + label)
	return true

func _checkEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	if got != want:
		failures += 1
		print("  [FAIL] %s (got %s, want %s)" % [label, str(got), str(want)])
		return false
	print("  [ok] " + label)
	return true

func _initialize():
	_run()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _now() -> int:
	return int(_sc.call("Timestamp")) if _sc != null else int(Time.get_unix_time_from_system())

func _bootReady() -> bool:
	var l : Node = root.get_node_or_null(NodePath("Launcher"))
	if l == null:
		return false
	var sql : Variant = l.get("SQL")
	var world : Variant = l.get("World")
	var eco : Variant = l.get("Economy")
	return sql != null and bool(sql.isInitialized) and world != null and eco != null and bool(eco.isInitialized)

func _run() -> void:
	print("== SOM-IDLE refund revocation harness (work order #97) ==")
	var waited : int = 0
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	while _launcher != null and not _bootReady() and waited < 30000:
		await create_timer(0.1).timeout
		waited += 100
	if not _bootReady():
		_check(false, "boot: Launcher.SQL/World/Economy prontos (waited %d ms)" % waited)
		_finish()
		return
	_sql = _launcher.SQL
	_eco = _launcher.Economy
	_nc = load("res://sources/network/NetworkCommons.gd")
	_sc = load("res://sources/sql/SQLCommons.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	baseNow = _now()
	tag = baseNow % 100000000
	if not _check(_mkSeason(), "temporada ativa plantada com premium_sku = pass.s2"):
		_finish()
		return
	_suiteCatalog()
	_suitePass()
	_suiteVIP()
	_suiteProrataControl()
	_suiteSandbox()
	_suiteBundle()
	_suiteCosmetic()
	_suiteChargeback()
	_suiteAlias()
	_finish()

# ------------------------------------------------------------------ fixtures

func _mkAccount(prefix : String) -> int:
	var name : String = "%s_%d" % [prefix, tag]
	if bool(_sql.HasAccount(name)):
		return int(_sql.GetAccountID(name))
	if not bool(_sql.AddAccount(name, "senha-de-teste-1", name + "@rrv.test.local",
			_nc.get("AgreementTosVersion"), _nc.get("AgreementPrivacyVersion"), "203.0.113.9")):
		return -1
	return int(_sql.GetAccountID(name))

# Uma temporada ativa por run (id máximo = `ActiveSeason()`), com o SKU declarado
# nas regras congeladas — é como o companion escreve a linha hoje.
func _mkSeason() -> bool:
	_sql.ExecuteBindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, '{\"premium_sku\": \"pass.s2\"}', 'active');",
		[baseNow - FixDay, baseNow + 30 * FixDay])
	_seasonID = int(_sql.call("LastInsertRowIDRaw"))
	if _seasonID <= 0:
		return false
	var active : Dictionary = _eco.call("ActiveSeason")
	return int(active.get("season_id", 0)) == _seasonID

func _grant(accountID : int, kind : String, amount : int, key : String, payload : String, price : int) -> bool:
	return bool(_eco.call("EnqueueGrant", accountID, kind, amount, key, payload, price, "BRL"))

# O companion NÃO passa por `EnqueueGrant` para o clawback: ele escreve a linha
# direto na fila (`companion/server.py::_chargeback_clawback`), que é justamente
# por que um chargeback de SKU sem gem (amount 0) existe. O fixture imita o autor
# real da linha.
func _grantRowRaw(accountID : int, kind : String, amount : int, key : String, payload : String) -> bool:
	return bool(_sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at, price_paid, currency) VALUES (?, ?, ?, ?, ?, 'pending', ?, 0, '');",
		[key, accountID, kind, amount, payload, _now()]))

func _flushQueue() -> void:
	_eco.call("ProcessPendingGrants", 200)

func _refund(accountID : int, key : String) -> Dictionary:
	return _eco.call("RequestPurchaseRefund", accountID, key)

func _premiumOf(accountID : int) -> int:
	var rows : Array = _sql.QueryBindings("SELECT premium FROM season_account_state WHERE account_id = ? AND season_id = ?;", [accountID, _seasonID])
	return int(rows[0].get("premium", 0)) if not rows.is_empty() else -1

func _ptOf(accountID : int) -> int:
	var rows : Array = _sql.QueryBindings("SELECT pt FROM season_account_state WHERE account_id = ? AND season_id = ?;", [accountID, _seasonID])
	return int(rows[0].get("pt", 0)) if not rows.is_empty() else -1

func _vipUntil(accountID : int) -> int:
	return int(_sql.GetVIPUntil(accountID))

func _ledgerAmount(accountID : int, reason : String) -> int:
	var rows : Array = _sql.QueryBindings("SELECT COALESCE(SUM(amount), 0) AS s FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, reason])
	return int(rows[0].get("s", 0)) if not rows.is_empty() else 0

func _reasonCount(accountID : int, reason : String) -> int:
	var rows : Array = _sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, reason])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func _legAmount(accountID : int, reason : String) -> int:
	var rows : Array = _sql.QueryBindings("SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason = ? AND amount > 0 ORDER BY id LIMIT 1;", [accountID, reason])
	return int(rows[0].get("amount", 0)) if not rows.is_empty() else 0

func _queueStatus(key : String) -> String:
	var rows : Array = _sql.QueryBindings("SELECT status FROM grant_queue WHERE idempotency_key = ?;", [key])
	return str(rows[0].get("status", "")) if not rows.is_empty() else "missing"

func _cosmeticCount(accountID : int, cid : String) -> int:
	var rows : Array = _sql.QueryBindings("SELECT COUNT(*) AS n FROM cosmetic_grant WHERE account_id = ? AND cosmetic_id = ?;", [accountID, cid])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

# ------------------------------------------------------------------ A. o que o catálogo dá, medido

func _suiteCatalog() -> void:
	print("[suite A] catálogo pago: quais SKUs não são gem")
	var raw : Variant = JSON.parse_string(FileAccess.get_file_as_string(CatalogPath))
	if not _check(raw is Dictionary, "data/conf/paid_catalog.json lê como Dictionary"):
		return
	var table : Dictionary = raw
	var total : int = 0
	var nonGem : Array = []
	for sku in table.keys():
		var entry : Variant = table[sku]
		if not (entry is Dictionary) or str(sku).begins_with("_"):
			continue
		total += 1
		if str((entry as Dictionary).get("kind", "")) != "gems":
			nonGem.append(str(sku))
	_checkEq(total, 11, "o catálogo tem 11 SKUs cobráveis")
	_checkEq(nonGem.size(), 8, "8 SKUs não são gem — e eram invisíveis ao art.49 antigo")
	for want in ["vip.1mo", "vip.3mo", "pass.s1", "pass.s1.deluxe", "pass.s2", "donate.support", "starter.pack", "founder.pack"]:
		_check(nonGem.has(want), "%s é SKU não-gem" % want)
	# A raiz do defeito, medida no banco e não no comentário: estes SKUs escrevem
	# ledger com kind != 'gems' (o `vip`/`pass`/`cosmetic` de `_ApplyGrantRaw`),
	# e a lookup antiga filtrava por kind = 'gems'.
	var kinds : Variant = _catalog.get("GrantKinds")
	_check(not (kinds as Array).has("item"), "GrantKinds não declara 'item' → nenhum lote de item comprado em starter/founder a revogar")
	var bundleLegKinds : Array = []
	for name in ["starter.pack", "founder.pack"]:
		for c in ((table.get(name, {}) as Dictionary).get("contents", []) as Array):
			bundleLegKinds.append(str((c as Dictionary).get("kind", "")))
	_checkEq(bundleLegKinds.count("item"), 0, "os bundles do catálogo não dão item (%s)" % str(bundleLegKinds))
	_checkEq(_catalog.get("RefundWindowSeconds"), 7 * FixDay, "a janela do arrependimento é de 7 dias (a mesma escala do dia de VIP)")

# ------------------------------------------------------------------ B. pass.s2: dinheiro volta, premium tem de sair

func _suitePass() -> void:
	print("[suite B] pass.s2 comprado → estornado → premium revogado")
	var accountID : int = _mkAccount("rrv_pass")
	if not _check(accountID > 0, "conta de passe criada"):
		return
	var key : String = "rrv-pass-%d" % tag
	var gemsBefore : int = int(_sql.GetGems(accountID))
	if not _check(_grant(accountID, "pass_premium", 1, key, '{"sku": "pass.s2"}', 2490), "grant pass.s2 enfileirado com preço"):
		return
	_flushQueue()
	_checkEq(_premiumOf(accountID), 1, "compra dá premium = 1 na temporada ativa")
	var r : Dictionary = _refund(accountID, key)
	_checkEq(str(r.get("reason", "")), "refunded", "art.49 do passe é aceito (era not_found)")
	_checkEq(_premiumOf(accountID), 0, "premium revogado: o bem volta com o dinheiro")
	_checkEq(int(_sql.GetGems(accountID)), gemsBefore, "passe padrão não mexe no saldo de gem")
	_checkEq(_ledgerAmount(accountID, "grant:" + key), 1, "perna concedida soma +1 no ledger")
	_checkEq(_ledgerAmount(accountID, "refund:" + key + ":pass"), -1, "revogação entra como linha nova negativa (append-only)")
	_checkEq(_ledgerAmount(accountID, "grant:" + key) + _ledgerAmount(accountID, "refund:" + key + ":pass"), 0, "o ledger fecha em zero para o passe")
	_checkEq(_queueStatus(key), "refunded", "fila marcada refunded (é isso que o sweep do companion lê)")
	var r2 : Dictionary = _refund(accountID, key)
	_checkEq(str(r2.get("reason", "")), "already_refunded", "segundo estorno do mesmo payment é recusado")
	_checkEq(_reasonCount(accountID, "refund:" + key + ":pass"), 1, "a revogação não foi escrita duas vezes")
	_checkEq(_premiumOf(accountID), 0, "e nada foi revogado de novo")
	# reentrega do webhook depois da revogação: a chave já está na fila → não re-granta
	_check(bool(_eco.call("EnqueueGrant", accountID, "pass_premium", 1, key, '{"sku": "pass.s2"}', 2490, "BRL")), "reentrega do mesmo payment é aceita como duplicata")
	_flushQueue()
	_checkEq(_premiumOf(accountID), 0, "reentrega do webhook não re-grant premium")
	_checkEq(_queueStatus(key), "refunded", "a linha continua fora da fila de entrega")
	# deluxe: perna de gem embutida + emote saem juntos, PT fica
	var dkey : String = "rrv-dlx-%d" % tag
	var dGems : int = int(_sql.GetGems(accountID))
	_check(_grant(accountID, "pass_premium", 1, dkey, '{"sku": "pass.s1.deluxe", "tier": "deluxe"}', 4490), "grant deluxe enfileirado")
	_flushQueue()
	_checkEq(_premiumOf(accountID), 1, "deluxe dá premium")
	_checkEq(_cosmeticCount(accountID, "emote_coroa"), 1, "deluxe dá o emote Coroa do Sol")
	_checkEq(int(_sql.GetGems(accountID)), dGems + 150, "deluxe dá as 150 gems")
	_checkEq(int(_sql.GetGemsPaid(accountID)), 150, "as 150 do deluxe entram como gem PAGA")
	var ptBefore : int = _ptOf(accountID)
	var dr : Dictionary = _refund(accountID, dkey)
	_checkEq(str(dr.get("reason", "")), "refunded", "estorno do deluxe aceito")
	_checkEq(_premiumOf(accountID), 0, "premium do deluxe revogado")
	_checkEq(_cosmeticCount(accountID, "emote_coroa"), 0, "emote do deluxe sai junto (é posse comprada por esta chave)")
	_checkEq(int(_sql.GetGems(accountID)), dGems, "as 150 gems do deluxe voltam como dinheiro")
	_checkEq(_ptOf(accountID), ptBefore, "PT NÃO é tocado pela revogação (limitação documentada: é contador da trilha grátis também)")
	_checkEq(str(_refund(accountID, dkey).get("reason", "")), "already_refunded", "deluxe estornado não estorna de novo")

# ------------------------------------------------------------------ C. vip.1mo: janela e tier

func _suiteVIP() -> void:
	print("[suite C] vip.1mo comprado → estornado → janela e tier voltam")
	var accountID : int = _mkAccount("rrv_vip")
	if not _check(accountID > 0, "conta de VIP criada"):
		return
	var key : String = "rrv-vip-%d" % tag
	var before : int = _vipUntil(accountID)
	var t0 : int = _now()
	_check(_grant(accountID, "vip_days", 30, key, '{"sku": "vip.1mo"}', 2490), "grant vip.1mo enfileirado com preço")
	_flushQueue()
	var granted : int = _legAmount(accountID, "grant:" + key)
	_checkEq(granted, 30, "a perna de ledger registra 30 dias concedidos")
	# `vip_until` é timestamp ABSOLUTO e o grant empilha em `max(now, atual)`: a
	# régua é relativa a essa âncora, lida do banco, não a um número gravado.
	_check(_vipUntil(accountID) >= maxi(before, t0) + granted * FixDay - 120, "a janela comprada entrou no estado (vip_until >= max(antes, agora) + 30 dias)")
	_checkEq(int(_sql.GetVIPTier(accountID)), 1, "vip.1mo sobe o tier para 1")
	var untilBefore : int = _vipUntil(accountID)
	var r : Dictionary = _refund(accountID, key)
	_checkEq(str(r.get("reason", "")), "refunded", "art.49 do VIP é aceito (era not_found)")
	_checkEq(_vipUntil(accountID), maxi(0, untilBefore - granted * FixDay), "janela revogada: saem os dias CONCEDIDOS, com chão 0 (regra TOTAL)")
	_check(untilBefore - _vipUntil(accountID) == granted * FixDay, "a janela encolheu exatamente amount * 86400")
	_check(_vipUntil(accountID) <= _now(), "sem dia pago sobrando, a janela não cobre o amanhã")
	_checkEq(int(_sql.GetVIPTier(accountID)), 0, "sem janela comprada, o tier comprado cai a 0")
	_checkEq(_ledgerAmount(accountID, "grant:" + key) + _ledgerAmount(accountID, "refund:" + key + ":vip"), 0, "o ledger do VIP fecha em zero (+30/-30)")
	_checkEq(int(_sql.GetGems(accountID)), 0, "estorno de VIP não inventa débito de gem")
	_checkEq(str(_refund(accountID, key).get("reason", "")), "already_refunded", "segundo estorno de VIP recusado")

# ------------------------------------------------------------------ C2. a regra: total, não pro-rata

# Compra com 3 DIAS de história: perna de ledger, linha de fila e janela estão
# como estariam há 3 dias (o ledger é append-only e NÃO envelhece por UPDATE —
# triggers `ledger_transaction_no_update`/`_no_delete`, migration 009 — então a
# idade é plantada no INSERT, mesma técnica de `SuiteRefund`). Pro-rata tiraria
# 27 dias; a regra é TOTAL: tiram-se os 30 concedidos.
func _suiteProrataControl() -> void:
	print("[suite C2] revogação é TOTAL, não pro-rata (elapsed = 3 dias)")
	var accountID : int = _mkAccount("rrv_old")
	if not _check(accountID > 0, "conta envelhecida criada"):
		return
	var key : String = "rrv-old-%d" % tag
	var age : int = 3 * FixDay
	var days : int = 30
	var plantedAt : int = baseNow - age
	var plantedUntil : int = plantedAt + days * FixDay
	_checkEq(baseNow - plantedAt, age, "a compra plantada tem %d dias de uso, dentro da janela de 7" % int(age / FixDay))
	_sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at, price_paid, currency) VALUES (?, ?, 'vip_days', ?, ?, 'processed', ?, 2490, 'BRL');",
		[key, accountID, days, '{"sku": "vip.1mo"}', plantedAt])
	_sql.ExecuteBindings("INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, 0, 'vip', ?, ?, ?, ?);",
		[accountID, days, plantedUntil, "grant:" + key, plantedAt])
	_sql.SetVIPUntil(accountID, plantedUntil)
	_sql.SetVIPTier(accountID, 1)
	var r : Dictionary = _refund(accountID, key)
	_checkEq(str(r.get("reason", "")), "refunded", "estorno aceito dentro da janela (3 dias < 7)")
	var prorata : int = maxi(0, plantedUntil - (days * FixDay - age))
	_checkEq(_vipUntil(accountID), maxi(0, plantedUntil - days * FixDay), "saem os 30 dias CONCEDIDOS (amount da perna), não 30 - elapsed")
	_check(_vipUntil(accountID) != prorata, "o resultado não coincide com pro-rata por tempo decorrido (%d != %d)" % [_vipUntil(accountID), prorata])
	_check(_vipUntil(accountID) <= baseNow, "sem dia comprado sobrando, a janela não cobre o amanhã")
	_checkEq(int(_sql.GetVIPTier(accountID)), 0, "tier 0 quando a janela revogada se esgotou")

# ------------------------------------------------------------------ D. sandbox não é dinheiro

func _suiteSandbox() -> void:
	print("[suite D] grant de sandbox (price 0) não é estornável, nem em VIP")
	var accountID : int = _mkAccount("rrv_sbx")
	if not _check(accountID > 0, "conta sandbox criada"):
		return
	var key : String = "rrv-sbx-%d" % tag
	_check(_grant(accountID, "vip_days", 7, key, '{"sku": "starter.pack"}', 0), "grant de VIP sem preço enfileirado")
	_flushQueue()
	var until : int = _vipUntil(accountID)
	_check(until > baseNow, "o grant de sandbox deu janela de verdade")
	_checkEq(str(_refund(accountID, key).get("reason", "")), "not_paid", "price 0 → not_paid (nada a devolver, nada a revogar)")
	_checkEq(_vipUntil(accountID), until, "recusado não toca no estado")

# ------------------------------------------------------------------ E. bundle: pernas derivadas do payment

func _suiteBundle() -> void:
	print("[suite E] founder.pack (bundle) estornado pela chave do payment")
	var accountID : int = _mkAccount("rrv_bdl")
	if not _check(accountID > 0, "conta de bundle criada"):
		return
	var payment : String = "9%d" % tag
	var kGems : String = "%s:0:gems" % payment
	var kVip : String = "%s:1:vip_days" % payment
	var gemsBefore : int = int(_sql.GetGems(accountID))
	var vipBefore : int = _vipUntil(accountID)
	_check(_grant(accountID, "gems", 1200, kGems, '{"sku": "founder.pack"}', 3990), "perna 0 (gems) carrega o preço da compra")
	_check(_grant(accountID, "vip_days", 30, kVip, '{"sku": "founder.pack"}', 0), "perna 1 (VIP) sem preço (bundle paga numa perna só)")
	var t0 : int = _now()
	_flushQueue()
	_checkEq(int(_sql.GetGems(accountID)), gemsBefore + 1200, "bundle creditou as gems")
	# `vip_until` é timestamp ABSOLUTO e o grant empilha em `max(now, atual)`: a âncora
	# do assert é o instante da entrega, não 0 (mesmo motivo da suite C).
	_check(_vipUntil(accountID) >= maxi(vipBefore, t0) + 30 * FixDay - 120, "bundle creditou os 30 dias (vip_until >= max(antes, agora) + 30 dias)")
	var untilBefore : int = _vipUntil(accountID)
	var r : Dictionary = _refund(accountID, payment)
	_checkEq(str(r.get("reason", "")), "refunded", "a chave do payment resolve as pernas derivadas (era not_found)")
	_checkEq(int(r.get("amount", 0)), 1200, "o dinheiro devolvido em gems = a perna de gem")
	_checkEq(int(_sql.GetGems(accountID)), gemsBefore, "gems do bundle voltaram")
	_checkEq(int(_sql.GetGemsPaid(accountID)), 0, "gems PAGAS do bundle voltaram junto (prova de origem drenada)")
	_checkEq(_vipUntil(accountID), maxi(0, untilBefore - 30 * FixDay), "VIP do bundle revogado pela mesma operação (saem os dias concedidos)")
	_check(_vipUntil(accountID) <= _now(), "sem dia pago sobrando, a janela do bundle não cobre o amanhã")
	_checkEq(_queueStatus(kGems), "refunded", "fila: perna de gem marcada")
	_checkEq(_queueStatus(kVip), "refunded", "fila: perna de VIP marcada (nenhuma perna pode ficar pendente de entrega)")
	_checkEq(_ledgerAmount(accountID, "grant:" + kGems) + _ledgerAmount(accountID, "refund:" + kGems), 0, "ledger da gem fecha em zero")
	_checkEq(_ledgerAmount(accountID, "grant:" + kVip) + _ledgerAmount(accountID, "refund:" + kVip + ":vip"), 0, "ledger do VIP fecha em zero")
	_checkEq(str(_refund(accountID, payment).get("reason", "")), "already_refunded", "bundle estornado não estorna de novo")

# ------------------------------------------------------------------ F. cosmético: posse e equip

func _suiteCosmetic() -> void:
	print("[suite F] donate.support: título sai da posse e do equip")
	var accountID : int = _mkAccount("rrv_cos")
	if not _check(accountID > 0, "conta de cosmético criada"):
		return
	var cid : String = "title_apoiador"
	var key : String = "rrv-cos-%d" % tag
	_check((_catalog.get("COSMETIC_CATALOG") as Dictionary).has(cid), "%s existe no catálogo de cosméticos" % cid)
	_check(_grant(accountID, "cosmetic", 1, key, '{"sku": "donate.support", "cosmetic_id": "%s"}' % cid, 490), "grant donate.support enfileirado")
	_flushQueue()
	_checkEq(_cosmeticCount(accountID, cid), 1, "doação deu a posse do título")
	_sql.ExecuteBindings("INSERT OR REPLACE INTO cosmetic_equip (account_id, slot, cosmetic_id) VALUES (?, 'title', ?);", [accountID, cid])
	var r : Dictionary = _refund(accountID, key)
	_checkEq(str(r.get("reason", "")), "refunded", "art.49 da doação aceito (era not_found)")
	_checkEq(_cosmeticCount(accountID, cid), 0, "posse revogada")
	var equip : Array = _sql.QueryBindings("SELECT cosmetic_id FROM cosmetic_equip WHERE account_id = ? AND cosmetic_id = ?;", [accountID, cid])
	_checkEq(equip.size(), 0, "equip órfão removido junto (cosmetic_equip não tem FK, migration 024)")
	_checkEq(_ledgerAmount(accountID, "grant:" + key) + _ledgerAmount(accountID, "refund:" + key + ":cosmetic"), 0, "ledger do cosmético fecha em zero")
	_checkEq(str(_refund(accountID, key).get("reason", "")), "already_refunded", "doação estornada não estorna de novo")

# ------------------------------------------------------------------ G. chargeback também revoga

func _suiteChargeback() -> void:
	print("[suite G] chargeback do provedor toma o dinheiro E o bem")
	var accountID : int = _mkAccount("rrv_cb")
	if not _check(accountID > 0, "conta de chargeback criada"):
		return
	var payment : String = "8%d" % tag
	_check(_grant(accountID, "pass_premium", 1, payment, '{"sku": "pass.s2"}', 2490), "passe comprado")
	_flushQueue()
	_checkEq(_premiumOf(accountID), 1, "premium no ar antes da contestação")
	_checkEq(bool(_eco.call("EnqueueGrant", accountID, "chargeback", 0, payment + ":chargeback", '{"payment_id": "%s"}' % payment, 0, "")), false,
		"a API da fila recusa clawback a 0 — por isso o companion escreve a linha direto")
	_check(_grantRowRaw(accountID, "chargeback", 0, payment + ":chargeback", '{"payment_id": "%s", "sku": "pass.s2"}' % payment), "clawback a 0 escrito na fila (como o companion faz)")
	_flushQueue()
	_checkEq(_premiumOf(accountID), 0, "chargeback revoga o premium (antes: só debitava gem, e aqui não havia gem)")
	_checkEq(_reasonCount(accountID, "clawback:" + payment), 1, "linha clawback única")
	_checkEq(_reasonCount(accountID, "revoke:" + payment + ":pass"), 1, "revogação do chargeback registrada no ledger")
	_checkEq(str(_refund(accountID, payment).get("reason", "")), "charged_back", "art.49 sobre payment contestado: charged_back")
	# redelivery do MESMO clawback sob outra chave: a pré-checagem de `clawback:`
	# devolve true e nada é revogado duas vezes
	_check(_grantRowRaw(accountID, "chargeback", 0, payment + ":chargeback:2", '{"payment_id": "%s", "sku": "pass.s2"}' % payment), "clawback re-enfileirado sob outra chave")
	_flushQueue()
	_checkEq(_reasonCount(accountID, "clawback:" + payment), 1, "clawback não é escrito duas vezes por payment")
	_checkEq(_reasonCount(accountID, "revoke:" + payment + ":pass"), 1, "revogação não roda duas vezes")
	_checkEq(_premiumOf(accountID), 0, "nem o estado é reescrito")
	# chargeback de compra de gem: o débito antigo preservado, sem dobro
	var gaccount : int = _mkAccount("rrv_cbg")
	if not _check(gaccount > 0, "conta de chargeback de gem criada"):
		return
	var gkey : String = "7%d" % tag
	_check(_grant(gaccount, "gems", 550, gkey, '{"sku": "gems.550"}', 1990), "compra de gems enfileirada")
	_flushQueue()
	var afterBuy : int = int(_sql.GetGems(gaccount))
	_check(_grant(gaccount, "chargeback", 550, gkey + ":chargeback", '{"payment_id": "%s", "sku": "gems.550"}' % gkey, 0), "clawback de gem enfileirado")
	_flushQueue()
	_checkEq(int(_sql.GetGems(gaccount)), afterBuy - 550, "clawback toma as gems pagas (comportamento antigo preservado)")
	_checkEq(int(_sql.GetGemsPaid(gaccount)), 0, "gems pagas zeradas pelo clawback")
	_checkEq(_reasonCount(gaccount, "revoke:" + gkey + ":gems"), 0, "chargeback não debita a perna de gem duas vezes")
	_checkEq(_reasonCount(gaccount, "refund:" + gkey), 0, "e não escreve linha de estorno por cima do clawback")
	_checkEq(str(_refund(gaccount, gkey).get("reason", "")), "charged_back", "art.49 fechado após clawback")

# ------------------------------------------------------------------ H. o alias continua sendo a mesma porta

func _suiteAlias() -> void:
	print("[suite H] RequestGemRefund é alias fino de RequestPurchaseRefund")
	var accountID : int = _mkAccount("rrv_alias")
	if not _check(accountID > 0, "conta de alias criada"):
		return
	var key : String = "rrv-alias-%d" % tag
	_check(_grant(accountID, "vip_days", 30, key, '{"sku": "vip.1mo"}', 2490), "grant enfileirado")
	_flushQueue()
	var untilBefore : int = _vipUntil(accountID)
	var viaAlias : Dictionary = _eco.call("RequestGemRefund", accountID, key)
	_checkEq(str(viaAlias.get("reason", "")), "refunded", "o nome histórico ainda abre a mesma porta")
	_checkEq(_vipUntil(accountID), maxi(0, untilBefore - 30 * FixDay), "e revoga de verdade (não é só um log)")
	_check(_vipUntil(accountID) <= _now(), "a janela revogada pelo alias não cobre o amanhã")
	_checkEq(str(_eco.call("RequestGemRefund", accountID, key).get("reason", "")), "already_refunded", "alias idempotente")
	_checkEq(str(_refund(accountID, "nao-existe-%d" % tag).get("reason", "")), "not_found", "chave desconhecida segue not_found")
