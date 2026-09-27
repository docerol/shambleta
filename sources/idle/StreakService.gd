extends RefCounted
class_name StreakService

# SOM-IDLE: gatilho de retorno — streak diário de login (AUDITORIA_2026-09-27
# §6: "WebPush morto, sem streaks em lugar nenhum, notify só de UI"). O dia é
# decidido exclusivamente pelo relógio do servidor: `EconomyCatalog.ShopDay`
# (mesmo divisor UTC dos resets de loja/passe/baú-de-settle, com offset de
# 06:00 UTC) — nada aqui aceita data de cliente.
#
# Estado 100% no banco (tabela `login_streak`, migration 058): a escada de
# recompensa vive em código, o ouro pago passa pela via do ledger do Economy
# com reason "login_streak" (nunca wallet nua), e o registro é idempotente por
# dia: reentradas no mesmo ShopDay não concedem nada.
#
# Escada limitada: 7 degraus, depois cicla do índice 0. Teto de ouro por dia =
# o maior degrau (1000); soma de um ciclo completo = 3250, medido por
# `LadderCycleTotal()`. Referência do faucet: UMA liquidação F2P de zona 1 no
# cap de 8h paga 108000 de ouro — a escada inteira de 7 dias é ~3,0% disso, e
# não toca em nenhum cap próprio da economia (baús, chaves, gems, PT).

const LadderGold : Array[int] = [100, 200, 300, 400, 500, 750, 1000]
const LedgerReason : String = "login_streak"

# Test seams (mesmo padrão de OfflineSettle: headless `-s` sem Launcher)
static var sqlOverride : SQLService		= null
static var economyOverride : EconomyService	= null
static var nowOverride : int				= 0

static func _sql() -> SQLService:
	return sqlOverride if sqlOverride else Launcher.SQL

static func _economy() -> EconomyService:
	return economyOverride if economyOverride else Launcher.Economy

static func _now() -> int:
	return nowOverride if nowOverride > 0 else SQLCommons.Timestamp()

# Degrau vigente da escada (1-based; cicla a cada 7). Pura p/ harness.
static func LadderReward(streak : int) -> int:
	if streak <= 0:
		return 0
	return LadderGold[(streak - 1) % LadderGold.size()]

static func LadderCycleTotal() -> int:
	var sum : int = 0
	for gold : int in LadderGold:
		sum += gold
	return sum

# ------------------------------------------------------------------ escada (pura)

# O próximo MARCO da escada: o primeiro dia acima de `streak` em que ela paga o
# topo do ciclo (o maior degrau). No topo do ciclo o marco é o topo SEGUINTE, e é
# por isso que quem acabou de coletar o 7º dia continua tendo um próximo motivo
# para voltar.
static func NextMark(streak : int) -> int:
	var cycle : int = LadderGold.size()
	return streak + (cycle - streak % cycle)

# Soma da escada no intervalo fechado de dias (0 se o intervalo for vazio). É o
# degrau CICLANDO que se soma aqui — mesmo `LadderReward`, nenhuma regra nova.
static func RewardSpan(fromDay : int, toDay : int) -> int:
	var sum : int = 0
	var day : int = maxi(1, fromDay)
	while day <= toDay:
		sum += LadderReward(day)
		day += 1
	return sum

# O que se PERDE ao quebrar a sequência hoje: o ouro que falta para chegar ao
# próximo marco menos o que a MESMA quantidade de dias pagaria recomeçando do
# degrau 1 (é exatamente o que o servidor faz com quem volta depois de um dia
# fora — `RecordLogin` zera `newStreak` para 1). No topo do ciclo o número é 0 de
# propósito: quem acaba de coletar o marco não tem escalada a perder, só o
# recomeço.
static func LossOnBreak(streak : int) -> int:
	if streak <= 0:
		return 0
	var mark : int = NextMark(streak)
	return RewardSpan(streak + 1, mark) - RewardSpan(1, mark - streak)

# ------------------------------------------------------------------ superfície

# Projeção PURA do estado (sem SQL, sem relógio próprio): é o payload que o
# servidor manda para a UI do jogador. Dia atual, o que destrava no próximo
# marco e o que se perde ao quebrar — os três números que fazem o streak puxar
# alguém de volta. Nada aqui é autoridade nova: `day`/`now` entram por parâmetro,
# o resto vem da mesma escada que `RecordLogin` paga.
static func BuildView(streak : int, best : int, lastDay : int, now : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(now)
	var loggedToday : bool = lastDay == day
	var mark : int = NextMark(streak)
	var ladder : Array = []
	for step : int in LadderGold.size():
		ladder.append({"day" = step + 1, "gold" = LadderGold[step]})
	return {
		"ok" = true,
		"current_streak" = streak,
		"best_streak" = maxi(best, streak),
		"logged_today" = loggedToday,
		"server_day" = day,
		"today_reward" = LadderReward(streak) if loggedToday else 0,
		"next_day" = streak + 1,
		"next_reward" = LadderReward(streak + 1),
		"mark_day" = mark,
		"mark_reward" = LadderReward(mark),
		"days_to_mark" = mark - streak,
		"loss_on_break" = LossOnBreak(streak),
		"cycle_total" = LadderCycleTotal(),
		"reset_in_sec" = maxi(0, EconomyCatalog.PassDayStartTS(day + 1) - now),
		"ladder" = ladder,
	}

# A projeção lida do banco — só pelo SERVIDOR (push do login e RPC `GetStreak`).
# Relê o que `RecordLogin` escreveu, então o que aparece na tela é o estado
# gravado, nunca um número que o cliente possa inventar.
static func View(charID : int, now : int = 0) -> Dictionary:
	var state : Dictionary = PeekStreak(charID)
	return BuildView(int(state.get("current_streak", 0)), int(state.get("best_streak", 0)), int(state.get("last_day", -1)), _now() if now <= 0 else now)

# Frase do pagamento (o toast do login e o `/streak`). Sai do MESMO resultado que
# concedeu ouro, chamada só quando `reward > 0`.
static func RewardLine(streak : int, reward : int, best : int) -> String:
	return "Streak day %d: +%d gold (best %d). Day %d pays %d — break it and you lose %d." % [
		streak, reward, best, NextMark(streak), LadderReward(NextMark(streak)), LossOnBreak(streak)]

# Leitura do estado atual (0/None quando nunca logou com streak).
static func PeekStreak(charID : int) -> Dictionary:
	var rows : Array[Dictionary] = _sql().QueryBindings(
		"SELECT current_streak, best_streak, last_day FROM login_streak WHERE char_id = ?;", [charID])
	if rows.is_empty():
		return {"current_streak" = 0, "best_streak" = 0, "last_day" = -1}
	return {"current_streak" = int(rows[0]["current_streak"]), "best_streak" = int(rows[0]["best_streak"]), "last_day" = int(rows[0]["last_day"])}

# O registro do login. Chamado APENAS pelo caminho server-side de login
# (IdlePolicyService.AutoFarmOnLogin). `stat` é o ActorStats do agent recém-logado
# (espelho em memória — o gp vivo do char online mora na memória e o snapshot
# do §7.1 o preserva; com stat==null a escrita fica só no banco, p/ seams).
# Retorna {ok, streak, reward, reason}.
static func RecordLogin(charID : int, accountID : int, stat : ActorStats = null) -> Dictionary:
	var sql : SQLService = _sql()
	var economy : EconomyService = _economy()
	var now : int = _now()
	var day : int = EconomyCatalog.ShopDay(now)
	# O dicionário é MUTADO por chave dentro do lambda: GDScript captura locais por
	# valor, então `result = {...}` dentro da transação não vazaria para fora (a
	# chamada sempre devolveria "db_error"). Por chave, o mesmo objeto é visível.
	var result : Dictionary = {"ok" = false, "streak" = 0, "best" = 0, "reward" = 0, "reason" = "db_error"}
	if not sql.Transaction(func() -> bool:
		var rows : Array[Dictionary] = sql.db.select_rows("login_streak", "char_id = %d" % charID, ["current_streak", "best_streak", "last_day"])
		var cur : int = 0
		var best : int = 0
		var lastDay : int = -1
		if not rows.is_empty():
			cur = int(rows[0]["current_streak"])
			best = int(rows[0]["best_streak"])
			lastDay = int(rows[0]["last_day"])
			if lastDay == day:
				# Idempotente por dia: segunda entrada no mesmo ShopDay não
				# concede nada (sem isto, relog farming pagaria a escada inteira
				# num dia).
				result["ok"] = true
				result["streak"] = cur
				result["best"] = best
				result["reward"] = 0
				result["reason"] = "same_day"
				return true
		var newStreak : int = cur + 1 if lastDay == day - 1 else 1
		var newBest : int = maxi(best, newStreak)
		var data : Dictionary = {"current_streak" = newStreak, "best_streak" = newBest, "last_day" = day, "updated_at" = now}
		var wrote : bool = false
		if rows.is_empty():
			data["char_id"] = charID
			wrote = sql.db.insert_row("login_streak", data)
		else:
			wrote = sql.UpdateRowsRaw("login_streak", "char_id = %d" % charID, data)
		if not wrote:
			return false
		var reward : int = LadderReward(newStreak)
		if reward > 0:
			var statRows : Array[Dictionary] = sql.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
			var gpRaw : Variant = statRows[0].get("gp", null) if not statRows.is_empty() else null
			var gp : int = int(gpRaw) if gpRaw != null else 0
			if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp + reward}):
				return false
			# Ledger disciplina: concede junto da escrita, dentro da MESMA
			# transação — sem linha de ledger não tem grant (§7.3).
			if economy != null and not economy.LedgerAppend(charID, accountID, "gold", reward, gp + reward, LedgerReason):
				return false
			if stat != null:
				stat.AddGP(reward, false)
		result["ok"] = true
		result["streak"] = newStreak
		result["best"] = newBest
		result["reward"] = reward
		result["reason"] = "logged"
		return true):
		return result
	return result
