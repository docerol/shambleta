extends RefCounted
class_name CheckoutReversal

# C-4 (2026-10-06): a reversão por SKU (work order #97) saiu do
# `CheckoutService.gd` verbatim — o serviço estava no teto exato do god-node
# gate (923/923) e cada linha futura ali seria um PR morto por triviaidade.
# OS MÉTODOS NÃO ABREM TRANSAÇÃO: todos correm DENTRO do lambda
# `Launcher.SQL.Transaction(func(` do chamador (`_FlagChargebackShortfall`,
# `RequestPurchaseRefund`, `RequestGemRefund`), no mesmo `settleMutex` de
# sempre — é por isso que a fachada e as entradas de CDC art.49 ficam no
# CheckoutService, e o `gate de escrita` lê esta frase no arquivo porque a
# prova textual dele é justamente essa. `_eco` é injetado pelo dono.

var _eco : EconomyService = null

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

