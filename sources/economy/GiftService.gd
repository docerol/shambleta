extends RefCounted
class_name GiftService

# M-3 (2026-10-07): gifting de gems conta-a-conta, com taxa QUEIMADA. O funil é
# o mesmo da fee de troca: `_eco.settleMutex` + `Launcher.SQL.Transaction` —
# as três pernas (`gift_out`, `gift_fee`, `gift_in`) e a linha do `gem_gift`
# escrevem num único commit no mesmo handle cru; meio-presente não existe.
#
# A guarda anti-flip É A PORTA do funil, não revisão post-hoc: existindo
# presente B→A dentro de `GiftFlipWindowSec`, a volta A→B é RECUSADA. Aceitar
# seria vender a volta com 40% de queima — ninguém "lava" duas vezes sem
# perder, e o que sobra é exatamente o padrão que o chargeback persegue. O
# `ah_wash_pair` do FraudeReview é o irmão de auditoria dessa lógica; aqui ela
# é preventiva porque gems não tem escrow de 7 dias como o ouro do leilão.
#
# M-8 (2026-10-07): os knobs vivem AQUI, no dono do caminho — o `EconomyCatalog`
# mantém aliases para quem jura pelo catálogo (regime do `AchievementCatalog`).
const GiftMinGems : int = 10
const GiftFeePct : int = 20
const GiftMaxPerDay : int = 3
const GiftFlipWindowSec : int = 86400

var _eco : EconomyService = null

func SendGift(fromAccountID : int, toNickname : String, gems : int) -> Dictionary:
	if gems < GiftMinGems:
		return {"ok" = false, "reason" = "gift_min"}
	var out : Dictionary = {"ok" = false, "reason" = "?"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var nick : String = toNickname.strip_edges()
		if nick.is_empty():
			out["reason"] = "gift_unknown"
			return false
		# Identidade do destinatário é resolvida AQUI, do disco: o pacote nomeia
		# o nick, nunca a conta (mesma regra do `SetReferralCode`).
		var target : Array[Dictionary] = sql.ExecNoLockQuery("SELECT a.account_id FROM character c INNER JOIN account a ON a.account_id = c.account_id WHERE c.nickname = ?;", [nick])
		if target.is_empty():
			out["reason"] = "gift_unknown"
			return false
		var toAccount : int = int(target[0]["account_id"])
		if toAccount == fromAccountID:
			out["reason"] = "gift_self"
			return false
		var now : int = SQLCommons.Timestamp()
		var day : int = EconomyCatalog.ShopDay(now)
		var flips : Array[Dictionary] = sql.ExecNoLockQuery("SELECT COUNT(*) AS n FROM gem_gift WHERE from_account = ? AND to_account = ? AND created_at > ?;", [toAccount, fromAccountID, now - GiftFlipWindowSec])
		if not flips.is_empty() and int(flips[0]["n"]) > 0:
			out["reason"] = "gift_flip"
			return false
		var todays : Array[Dictionary] = sql.ExecNoLockQuery("SELECT COUNT(*) AS n FROM gem_gift WHERE from_account = ? AND day = ?;", [fromAccountID, day])
		if not todays.is_empty() and int(todays[0]["n"]) >= GiftMaxPerDay:
			out["reason"] = "gift_cap"
			return false
		var fee : int = maxi(1, roundi(float(gems) * float(GiftFeePct) / 100.0))
		var balance : int = sql.GetGemsRaw(fromAccountID)
		if balance < gems + fee:
			out["reason"] = "gift_nofunds"
			return false
		if not sql.db.query_with_bindings("INSERT INTO gem_gift (from_account, to_account, gems, fee, day, created_at) VALUES (?, ?, ?, ?, ?, ?);", [fromAccountID, toAccount, gems, fee, day, now]):
			return false
		var giftID : int = sql.LastInsertRowIDRaw()
		if giftID <= 0:
			return false
		# Duas mutações de carteira no debit (presente, depois taxa) para cada
		# linha do ledger nascer com o `balance_after` do instante dela — é o
		# contrato do invariante 1 do kernel, o mesmo que o `ah_burn` do leilão
		# jura (movimento de carteira, não contagem).
		if not sql.SetGemsRaw(fromAccountID, balance - gems):
			return false
		if not _eco._LedgerAppendLocked(fromAccountID, 0, EconomyCatalog.LedgerKindGems, -gems, balance - gems, "gift_out:%d" % giftID):
			return false
		var afterFee : int = balance - gems - fee
		if not sql.SetGemsRaw(fromAccountID, afterFee):
			return false
		if not _eco._LedgerAppendLocked(fromAccountID, 0, EconomyCatalog.LedgerKindGems, -fee, afterFee, "gift_fee:%d" % giftID):
			return false
		var toBal : int = sql.GetGemsRaw(toAccount)
		if not sql.SetGemsRaw(toAccount, toBal + gems):
			return false
		if not _eco._LedgerAppendLocked(toAccount, 0, EconomyCatalog.LedgerKindGems, gems, toBal + gems, "gift_in:%d" % giftID):
			return false
		out["ok"] = true
		out["reason"] = "ok"
		out["gift_id"] = giftID
		out["fee"] = fee
		out["balance"] = afterFee
		return true):
		pass
	_eco.settleMutex.unlock()
	return out

# Estado da porta para a tela: knobs + cota restante do dia, tudo lido do disco.
# A prévia do preço (fee = pct sobre o valor digitado) é aritmética do catálogo
# congelado dos dois lados — a tela desenha, o funil decide.
func GetGiftState(accountID : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var used : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM gem_gift WHERE from_account = ? AND day = ?;", [accountID, day])
	return {
		"fee_pct" = GiftFeePct,
		"min_gems" = GiftMinGems,
		"max_per_day" = GiftMaxPerDay,
		"left_today" = maxi(0, GiftMaxPerDay - (int(used[0]["n"]) if not used.is_empty() else 0)),
		"flip_window_sec" = GiftFlipWindowSec,
	}
