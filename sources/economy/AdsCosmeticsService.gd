extends RefCounted
class_name AdsCosmeticsService

# SOM-IDLE Fatia 8: domínio de monetização de janela extraído do EconomyService
# (ROADMAP_COMERCIAL S3). Fase E - rewarded ads (rate-limit diário, token
# assinado, compra de hora de AFK, bau/reroll/chave bonus) e Fase D -
# cosmeticos/entitlements (guarda-roupa, equip, compra por gems, titulos de
# suporte e vitrine do renascimento). Composicao com back-reference: este servico
# NAO tem mutex proprio - toda mutacao passa pelo settleMutex do EconomyService
# via _eco, exatamente como antes da fatia.

var _eco : EconomyService = null

# ------------------------------------------------------------------ Fase E: rewarded ads (MONETIZATION §2.5)
#
# Abstração + stubs: o client (AdProvider) devolve um token que o servidor
# valida por formato + dia; o SDK real pluga sem mudar mais nada. Views vivem
# em telemetry_event (kind 'ad_view', meta {"placement"}) — sem migração, sem
# moeda nova, sem caminho p/ essência/favores (§0.1). Caps por placement: 1
# baú/dia, 2 chaves/dia, reroll-ad divide o contador pago (3/dia). Não há teto
# global de anúncios/dia desde 2026-09-25: a hora de offline é o prêmio e o
# dono quis que todo anúncio disponível fosse mostrável. VIP não multiplica
# anúncio nenhum — o ×2 do loot é perk do tier 2 (OfflineSettle._LootMult), e
# baú/chave continuam dobrando a QUANTIDADE para quem tem VIP ativo.
# SOM-IDLE M2 (era T7): o stub não é mais compilar-para-abrir — ele vive atrás
# de SHAMBLETA_AD_STUB=1 com default fechado, ligado pelo deploy do beta. O
# token stub é mintável pelo client por construção (é isso que a env controla);
# enquanto não houver SSV no servidor, o teto de abuso são os caps por
# placement, e no afkhoras o prêmio é hora de farm — não dinheiro. Produção
# sem a env não credita nada.

# Seam do divisor de dia (espelha OfflineSettle.nowOverride): sem isto a regra
# "a hora ganha não se perde se você coletar antes do divisor" é indemonstrável
# em harness headless — _AdDayStart() lia o relógio real direto.
static var dayStartOverride : int = 0

func _AdDayStart() -> int:
	if dayStartOverride > 0:
		return dayStartOverride
	return EconomyCatalog.PassDayStartTS(EconomyCatalog.ShopDay(SQLCommons.Timestamp()))

func AdViewsToday(accountID : int, placement : String = "") -> int:
	if placement.is_empty():
		return int(Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND created_at >= ?;", [accountID, _AdDayStart()])[0]["n"])
	return int(Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND created_at >= ? AND json_extract(meta, '$.placement') = ?;", [accountID, _AdDayStart(), placement])[0]["n"])

func _ValidAdToken(token : String, placement : String) -> bool:
	# Stub: "stub:<placement>:<dia UTC-3>" — aceito SOMENTE com o stub ligado por
	# env (SHAMBLETA_AD_STUB=1, o deploy do beta). Default do servidor é fechado:
	# sem a env, nenhum token stub credita, em nenhum placement. Produção com SDK
	# real exige callback verificado no servidor (formato próprio), nunca "stub:".
	if not EconomyCatalog.AdStubEnabled():
		return false
	var parts : PackedStringArray = token.split(":")
	return parts.size() == 3 and parts[0] == "stub" and parts[1] == placement and parts[2] == str(EconomyCatalog.ShopDay(SQLCommons.Timestamp()))

func _AdAllowed(accountID : int, placement : String) -> Dictionary:
	if EconomyCatalog.AD_PLACEMENT_CAPS.has(placement) and AdViewsToday(accountID, placement) >= int(EconomyCatalog.AD_PLACEMENT_CAPS[placement]):
		return {"ok": false, "reason": "placement_cap"}
	return {"ok": true, "reason": "ok"}

# Persiste a view e PROVA que ela está no banco antes de o chamador creditar.
# TelemetryService.Flush() devolve 0 quando a transação falha (o evento fica no
# buffer) e o Record cai no BufferCap com pop_front: antes disso era um clique
# perdido; com hora offline como prêmio, seria hora comprada e não paga. A
# verificação é por re-leitura e não pelo retorno do Flush porque o buffer é
# compartilhado — o número que Flush devolve não é atribuível a esta view.
# Sem lock aqui: a cadeia RPC→WatchAd→Flush é síncrona na thread principal (o
# único Thread do repositório é SQLBackups.gd:5) e não tem await, então não há
# interleaving a excluir; e envolver em sql.Transaction deadlockaria, porque Flush
# abre a dele e queryMutex (SQL.gd:511) não é reentrante.
func _RecordAdView(accountID : int, charID : int, placement : String) -> bool:
	var before : int = AdViewsToday(accountID, placement)
	Launcher.Telemetry.Record("ad_view", accountID, charID, 0, JSON.stringify({"placement": placement}))
	Launcher.Telemetry.Flush()
	return AdViewsToday(accountID, placement) > before

# Registra uma visualização. No afkhoras a view É o produto: ela vale hora de
# offline até o divisor do dia ou até a coleta, o que vier primeiro.
func WatchAd(accountID : int, charID : int, placement : String, token : String) -> Dictionary:
	if not placement in EconomyCatalog.AD_PLACEMENTS:
		return {"ok": false, "reason": "unknown_placement"}
	if not _ValidAdToken(token, placement):
		return {"ok": false, "reason": "bad_token"}
	var gate : Dictionary = _AdAllowed(accountID, placement)
	if not bool(gate.get("ok", false)):
		return gate
	if not _RecordAdView(accountID, charID, placement):
		return {"ok": false, "reason": "ad_persist"}
	return {"ok": true, "reason": "ok"}

# Horas de offline compradas e ainda não liquidadas: views afkhoras depois de
# max(divisor do dia, último settle). Por PERSONAGEM — o anchor
# (character.last_settled_at) e o char_id da view são por personagem, e numa
# conta com 6 personagens a leitura por conta lavaria o contador. O max() com o
# divisor é o que implementa as duas metades da regra do dono: coletar antes do
# divisor não perde o que foi assistido (o anchor avança e a janela continua), e
# virar o dia sem coletar zera (a janela volta ao divisor).
func AfkHoursEarned(accountID : int, charID : int, anchorTs : int) -> float:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND char_id = ? AND created_at > ? AND json_extract(meta, '$.placement') = ?;", [accountID, charID, maxi(_AdDayStart(), anchorTs), EconomyCatalog.AD_AFKHOURS])
	if rows.is_empty():
		return 0.0
	return float(int(rows[0]["n"])) * EconomyCatalog.AD_OFFLINE_HOURS_PER_AD

# Baú bônus (VIP dobra a quantidade).
func ClaimAdChest(accountID : int, charID : int, token : String) -> Dictionary:
	var w : Dictionary = WatchAd(accountID, charID, EconomyCatalog.AD_CHEST, token)
	if not bool(w.get("ok", false)):
		return w
	var n : int = 2 if Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp() else 1
	_eco.settleMutex.lock()
	var ok : bool = Launcher.SQL.Transaction(func() -> bool:
		for i in n:
			if not Launcher.SQL.AddChestInstance(charID, 0, "ad"):
				return false
		return true)
	_eco.settleMutex.unlock()
	if not ok:
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "chests": n}

# Reroll via ad: mesma rotação e contador do pago (3/dia somados), sem gems.
func RerollDailyShopAd(accountID : int, token : String) -> Dictionary:
	if not _ValidAdToken(token, EconomyCatalog.AD_REROLL):
		return {"ok": false, "reason": "bad_token"}
	var gate : Dictionary = _AdAllowed(accountID, EconomyCatalog.AD_REROLL)
	if not bool(gate.get("ok", false)):
		return gate
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _eco._DailyRow(accountID, day)
	if int(row["rerolls_used"]) >= EconomyCatalog.DAILY_REROLLS_MAX:
		return {"ok": false, "reason": "reroll_cap"}
	if not _RecordAdView(accountID, 0, EconomyCatalog.AD_REROLL):
		return {"ok": false, "reason": "ad_persist"}
	return _eco._DoReroll(accountID, day, row)

# Chave de boss extra (VIP dobra a quantidade).
func ClaimAdBossKey(accountID : int, charID : int, token : String) -> Dictionary:
	var w : Dictionary = WatchAd(accountID, charID, EconomyCatalog.AD_BOSSKEY, token)
	if not bool(w.get("ok", false)):
		return w
	var n : int = 2 if Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp() else 1
	var keys : int = _eco.GrantBossKey(charID, n, "ad_reward")
	if keys < 0:
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "keys": keys}

# ------------------------------------------------------------------ Fase D: cosméticos / entitlements (MONETIZATION §2.4 + §2.7)
#
# Camada de dados completa; visuais (sprites/partículas) são follow-up de arte
# — o catálogo carrega só identidade (tipo + rótulo). Slots = tipos, um
# equipado por slot. Preço 0 = não vendável avulso (passe, marcos, backfill).
# req_rebirths: só compra quem já alcançou o marco jogando (vitrine decora o
# número ganho, nunca vende o número).

static func CosmeticLabel(cosmeticID : String) -> String:
	return EconomyCatalog.CosmeticLabel(cosmeticID)
func HasCosmetic(accountID : int, cosmeticID : String) -> bool:
	return not Launcher.SQL.QueryBindings("SELECT id FROM cosmetic_grant WHERE account_id = ? AND cosmetic_id = ? LIMIT 1;", [accountID, cosmeticID]).is_empty()

func GrantCosmetic(accountID : int, cosmeticID : String, source : String) -> bool:
	if not EconomyCatalog.COSMETIC_CATALOG.has(cosmeticID):
		return false
	return Launcher.SQL.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM cosmetic_grant WHERE account_id = ? AND cosmetic_id = ?);", [accountID, cosmeticID, source, SQLCommons.Timestamp(), accountID, cosmeticID])

func _MaxRebirths(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(rebirths) AS m FROM character WHERE account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

# Backfill preguiçoso (sem boot-hook): quem comprou starter/founder na Fase A
# recebe o título prometido no payload asim que o estado é lido.
func _BackfillSupportTitles(accountID : int) -> void:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT DISTINCT payload FROM grant_queue WHERE account_id = ? AND status = 'processed';", [accountID])
	var starter : bool = false
	var founder : bool = false
	for r in rows:
		var p : Variant = JSON.parse_string(str(r.get("payload", "")))
		if p is Dictionary:
			var sku : String = str((p as Dictionary).get("sku", ""))
			if sku == "starter.pack":
				starter = true
			if sku == "founder.pack":
				founder = true
	if starter and not HasCosmetic(accountID, "title_recruta"):
		GrantCosmetic(accountID, "title_recruta", "starter.pack")
	if founder and not HasCosmetic(accountID, "title_fundador"):
		GrantCosmetic(accountID, "title_fundador", "founder.pack")

func GetCosmetics(accountID : int) -> Dictionary:
	_BackfillSupportTitles(accountID)
	var owned : Array = []
	for r in Launcher.SQL.QueryBindings("SELECT cosmetic_id, source FROM cosmetic_grant WHERE account_id = ? ORDER BY id;", [accountID]):
		owned.append({"id": str(r.get("cosmetic_id", "")), "source": str(r.get("source", ""))})
	var equipped : Dictionary = {}
	for r in Launcher.SQL.QueryBindings("SELECT slot, cosmetic_id FROM cosmetic_equip WHERE account_id = ?;", [accountID]):
		equipped[str(r.get("slot", ""))] = str(r.get("cosmetic_id", ""))
	var catalog : Array = []
	for cid in EconomyCatalog.COSMETIC_CATALOG:
		var e : Dictionary = EconomyCatalog.COSMETIC_CATALOG[cid]
		catalog.append({"id": cid, "type": str(e.get("type", "")), "label": str(e.get("label", "")),
			"price": int(e.get("price", 0)), "req_rebirths": int(e.get("req_rebirths", 0)),
			"rendered": Storefront.IsRenderedCosmetic(cid)})
	return {"ok": true, "catalog": catalog, "owned": owned, "equipped": equipped,
		"rebirths": _MaxRebirths(accountID)}

func EquipCosmetic(accountID : int, cosmeticID : String) -> Dictionary:
	if not EconomyCatalog.COSMETIC_CATALOG.has(cosmeticID):
		return {"ok": false, "reason": "unknown_cosmetic"}
	if not HasCosmetic(accountID, cosmeticID):
		return {"ok": false, "reason": "not_owned"}
	var slot : String = str((EconomyCatalog.COSMETIC_CATALOG[cosmeticID] as Dictionary).get("type", ""))
	if not Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO cosmetic_equip (account_id, slot, cosmetic_id) VALUES (?, ?, ?);", [accountID, slot, cosmeticID]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "slot": slot}

func UnequipCosmetic(accountID : int, slot : String) -> Dictionary:
	if not Launcher.SQL.ExecuteBindings("DELETE FROM cosmetic_equip WHERE account_id = ? AND slot = ?;", [accountID, slot]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok"}

# Compra avulsa em gems (vitrine): exige posse do marco + saldo, na MESMA
# transação (débito + grant). Cosméticos price 0 nunca vendem aqui.
func BuyCosmetic(accountID : int, charID : int, cosmeticID : String) -> Dictionary:
	if not EconomyCatalog.COSMETIC_CATALOG.has(cosmeticID):
		return {"ok": false, "reason": "unknown_cosmetic"}
	var entry : Dictionary = EconomyCatalog.COSMETIC_CATALOG[cosmeticID]
	var price : int = int(entry.get("price", 0))
	if price <= 0:
		return {"ok": false, "reason": "not_for_sale"}
	if _MaxRebirths(accountID) < int(entry.get("req_rebirths", 0)):
		return {"ok": false, "reason": "milestone_locked"}
	if HasCosmetic(accountID, cosmeticID):
		return {"ok": false, "reason": "already_owned"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < price:
			result["reason"] = "insufficient_gems"
			return false
		# Gate de produto: não se vende renderizador que o jogo não tem. Depois da
		# leitura de saldo de propósito — antes dela, `rebirth_fx` a 0 gems morreria
		# em not_rendered e a cobertura de insufficient_gems sumiria sem ninguém ver.
		if not Storefront.IsRenderedCosmetic(cosmeticID):
			result["reason"] = "not_rendered"
			return false
		if not sql.SetGemsRaw(accountID, balance - price):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -price, balance - price, "cosmetic:" + cosmeticID):
			return false
		if not sql.ExecuteBindings("INSERT INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, cosmeticID, "shop", SQLCommons.Timestamp()]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = price
		result["balance"] = balance - price
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

# Vitrine do renascimento no ato (pós-commit): 1º ciclo concede o básico
# grátis (existir não se vende); estilo continua à venda na loja.
func _RebirthVitrine(accountID : int, rebirths : int) -> void:
	if rebirths == 1:
		GrantCosmetic(accountID, "rebirth_t1", "rebirth:1")
		GrantCosmetic(accountID, "rebirth_f1", "rebirth:1")

func EquippedTitleLabel(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT cosmetic_id FROM cosmetic_equip WHERE account_id = ? AND slot = 'title';", [accountID])
	if rows.is_empty():
		return ""
	return EconomyCatalog.CosmeticLabel(str(rows[0].get("cosmetic_id", "")))
