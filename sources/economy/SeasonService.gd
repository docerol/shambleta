extends RefCounted
class_name SeasonService

# SOM-IDLE Fatia 2 (ROADMAP_COMERCIAL S3): domínio E2 (seasons) extraído de
# EconomyService — criação/fechamento, snapshots das 4 corridas, ciclo de vida
# e premiação automática. Composição com back-reference (_eco): o serviço não
# tem transação nem mutex próprios — usa o MESMO settleMutex e os MESMOS
# helpers raw de EconomyService, então a semântica de locking é 100% idêntica
# à de antes da extração. Os wrappers públicos ficam em EconomyService
# (callers não mudam).

var _eco : EconomyService = null

# ------------------------------------------------------------------ E2: seasons (corridas power + spend; premiação automática no ciclo de vida — fecha e liquida)

func ActiveSeason() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT season_id, starts_at, ends_at, rules_frozen, status FROM season WHERE status = 'active' ORDER BY season_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

# SOM-IDLE beta fechado (T5): Seasons é pós-lançamento — criação e ciclo de
# vida ficam TRAVADOS por padrão (qualquer chamada normal, GM ou job, vira
# no-op com aviso). Testes habilitam explicitamente via env
# SHAMBLETA_ENABLE_SEASONS=1 (run_idle_tests.gd). Remover a trava só na
# ativação, após a auditoria do ciclo ACTIVE→CLOSING→CLOSED→SETTLED
# (som-idle-docs/SEASON_ACTIVATION_NOTE.md).

static func SeasonsEnabled() -> bool:
	if not EconomyCatalog.SeasonsBetaLock:
		return true
	return OS.get_environment("SHAMBLETA_ENABLE_SEASONS") == "1"

func CreateSeason(days : int, rules : String = "{}") -> int:
	if not SeasonsEnabled():
		push_warning("SOM-IDLE Seasons: criação bloqueada no beta (T5)")
		return -1
	if days <= 0 or not ActiveSeason().is_empty():
		return 0
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var now : int = SQLCommons.Timestamp()
		if not sql.db.query_with_bindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, ?, 'active');", [now, now + days * 86400, rules]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	_eco.settleMutex.unlock()
	return int(out["id"])

func CloseSeason(seasonID : int) -> bool:
	return Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'closed' WHERE season_id = ? AND status = 'active';", [seasonID])

# ROADMAP_COMERCIAL S2: temporada S1 — regras congeladas desde o dia 1.
# Respeita a trava do beta (T5): retorna -1 enquanto SeasonsEnabled() for false.
# Quando habilitada, cria 30 dias com rules_frozen (4 corridas, premiação
# não-cashable). Idempotente: se já houver temporada ativa, retorna 0.
func EnsureSeasonS1() -> int:
	if not ActiveSeason().is_empty():
		return 0
	return CreateSeason(30, EconomyCatalog.SeasonS1Rules())

func SnapshotSeasonPower(seasonID : int, limit : int = 100) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_score FROM character WHERE power_score > 0 ORDER BY power_score DESC LIMIT ?;", [limit])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'power', ?, ?);", [seasonID, int(row["char_id"]), int(row["power_score"])]):
			n += 1
	return n

func SnapshotSeasonSpend(seasonID : int) -> int:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT starts_at FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, SUM(-amount) AS spent FROM ledger_transaction WHERE kind = 'gems' AND amount < 0 AND created_at >= ? GROUP BY account_id;", [int(season[0]["starts_at"])])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'spend', ?, ?);", [seasonID, int(row["account_id"]), int(row["spent"])]):
			n += 1
	return n

# Fase F: snapshot das 2 novas corridas (idempotente por REPLACE).
func SnapshotSeasonBossKills(seasonID : int) -> int:
	var n : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT char_id, bosses_beaten FROM character WHERE bosses_beaten > 0;", []):
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'boss_kills', ?, ?);", [seasonID, int(row["char_id"]), int(row["bosses_beaten"])]):
			n += 1
	return n

func SnapshotSeasonGuildPoints(seasonID : int) -> int:
	var n : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT guild_id, points FROM guild WHERE points > 0;", []):
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'guild_points', ?, ?);", [seasonID, int(row["guild_id"]), int(row["points"])]):
			n += 1
	return n

func GetSeasonBoard(seasonID : int, kind : String, limit : int = 20) -> Array[Dictionary]:
	if not kind in EconomyCatalog.SEASON_KINDS:
		return []
	return Launcher.SQL.QueryBindings("SELECT subject_id, value FROM season_score WHERE season_id = ? AND kind = ? ORDER BY value DESC LIMIT ?;", [seasonID, kind, limit])

# SOM-IDLE Fase F: 4 corridas (ARCHITECTURE §4.6) — power/spend + boss_kills
# (por char) + guild_points (por guild, do hook de settle/vitória).

# SOM-IDLE (3b): premiação AUTOMÁTICA — substitui o payout manual/GM da v0.
# Tabela de prêmios em gems por colocação (top-N) para cada corrida (power/spend).

# Rodado no job diário (e chamável a qualquer momento): fecha temporadas vencidas
# e liquida as fechadas. Idempotente — uma temporada só paga uma vez.
func TickSeasonLifecycle() -> Dictionary:
	if not SeasonsEnabled():
		return {"closed" = 0, "settled" = 0, "disabled" = true}
	var closed : int = 0
	var settled : int = 0
	var now : int = SQLCommons.Timestamp()
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'active' AND ends_at <= ?;", [now]):
		if CloseSeason(int(row["season_id"])):
			closed += 1
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'closed';", []):
		var res : Dictionary = SettleSeasonPrizes(int(row["season_id"]))
		if bool(res.get("ok", false)):
			settled += 1
	return {"closed" = closed, "settled" = settled}

# Liquida os prêmios de uma temporada fechada: congela o placar final, concede
# gems aos top-N por corrida e marca 'settled'. Gems (não-casháveis) via AddGems
# com reason 'season_prize:<id>:<kind>:<subject>' — a prova no ledger garante
# idempotência por vencedor, mesmo se uma execução anterior falhou no meio.
func SettleSeasonPrizes(seasonID : int) -> Dictionary:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return {"ok" = false, "reason" = "not_found", "awarded" = 0}
	var status : String = str(season[0]["status"])
	if status == "settled":
		return {"ok" = true, "reason" = "already_settled", "awarded" = 0}
	if status != "closed":
		return {"ok" = false, "reason" = "not_closed", "awarded" = 0}

	SnapshotSeasonPower(seasonID)
	SnapshotSeasonSpend(seasonID)
	SnapshotSeasonBossKills(seasonID)
	SnapshotSeasonGuildPoints(seasonID)
	var awarded : int = 0
	for kind in ["power", "spend", "boss_kills"]:
		var board : Array[Dictionary] = GetSeasonBoard(seasonID, kind, EconomyCatalog.SeasonPrizeGems.size())
		for rank : int in board.size():
			var prize : int = EconomyCatalog.SeasonPrizeGems[rank]
			if prize <= 0:
				continue
			var subject : int = int(board[rank]["subject_id"])
			var accountID : int = _eco._AccountIDForCharacterRaw(subject) if kind == "power" or kind == "boss_kills" else subject
			if accountID <= 0:
				continue
			var reason : String = "season_prize:%d:%s:%d" % [seasonID, kind, subject]
			if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, reason]).is_empty():
				continue
			if _eco.AddGems(accountID, prize, reason):
				awarded += 1
	# Corrida de guilds: top-3 guilds premiam o líder (custodiante) em gems.
	var gboard : Array[Dictionary] = GetSeasonBoard(seasonID, "guild_points", EconomyCatalog.GUILD_PRIZE_GEMS.size())
	for rank : int in gboard.size():
		var gprize : int = EconomyCatalog.GUILD_PRIZE_GEMS[rank]
		if gprize <= 0:
			continue
		var gid : int = int(gboard[rank]["subject_id"])
		var lead : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT leader_account FROM guild WHERE guild_id = ?;", [gid])
		if lead.is_empty():
			continue
		var leader : int = int(lead[0].get("leader_account", 0))
		var greason : String = "season_prize:%d:guild_points:%d" % [seasonID, gid]
		if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [leader, greason]).is_empty():
			continue
		if _eco.AddGems(leader, gprize, greason):
			awarded += 1
	Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'settled' WHERE season_id = ? AND status = 'closed';", [seasonID])
	if awarded > 0:
		Util.PrintLog("Economy", "Season %d settled automatically: %d prize grants" % [seasonID, awarded])
	var auto : Dictionary = _eco._AutoClaimPass(seasonID)
	if int(auto.get("claimed", 0)) > 0:
		Util.PrintLog("Economy", "Season %d pass auto-claim: %d rewards" % [seasonID, int(auto.get("claimed", 0))])
	return {"ok" = true, "reason" = "settled", "awarded" = awarded}
