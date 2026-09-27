extends RefCounted
class_name SeasonService

# SOM-IDLE Fatia 2 (ROADMAP_COMERCIAL S3): domínio E2 (seasons) extraído de
# EconomyService — criação/fechamento, snapshots das 4 corridas, ciclo de vida
# e premiação automática. Composição com back-reference (_eco): o serviço não
# tem transação nem mutex próprios — usa o MESMO settleMutex e os MESMOS
# helpers raw de EconomyService, então a semântica de locking é 100% idêntica
# à de antes da extração. Os wrappers públicos ficam em EconomyService
# (callers não mudam).
#
# OPS-2 (2026-09-27): o catálogo de temporadas saiu do código e foi para
# `data/conf/seasons.json`, lido por `SeasonConfig` (validação + resolução pura
# por timestamp). Abrir temporada é decisão de arquivo, não de GDScript: o
# relógio de produção abre a vigente e fecha a de rotação quando uma sucessora
# agendada assume o ar. `season.rules_frozen` guarda o `config_id` da entrada, e
# linhas antigas (sem `config_id`) continuam válidas — continuam resolvendo para
# os defaults do catálogo. Com o arquivo ausente/corrompido a abertura é
# fail-closed (`EnsureSeason` → -1 + `push_error`); fechar e liquidar o que já
# está no banco segue funcionando, porque dívida com jogador não se nega por typo
# de agenda. Testes: `tests/season_liveops_test.gd`.

var _eco : EconomyService = null

# ------------------------------------------------------------------ E2: seasons (corridas power + spend; premiação automática no ciclo de vida — fecha e liquida)

func ActiveSeason() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT season_id, starts_at, ends_at, rules_frozen, status FROM season WHERE status = 'active' ORDER BY season_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

# A linha ativa resolvida na entrada do arquivo (OPS-2). `{}` = "o banco tem uma
# temporada, o calendário não declara nenhuma para ela" — que é o estado de toda
# linha anterior ao OPS-2, e significa "usa os defaults do catálogo", não
# "temporada inexistente".
func ActiveSeasonEntry() -> Dictionary:
	return SeasonConfig.EntryForSeasonRow(SeasonConfig.Entries(), ActiveSeason())

# Leitura de agenda (sem escrita): o que está no ar, quando fecha, o que vem
# depois e o que está travando a abertura. É o que um `/season agenda` ou o
# painel do operador precisa responder sem SQL na mão.
func SeasonAgenda() -> Dictionary:
	var now : int = SQLCommons.Timestamp()
	var entries : Array = SeasonConfig.Entries()
	var errors : PackedStringArray = SeasonConfig.Errors()
	var active : Dictionary = ActiveSeason()
	return {
		"ok" = errors.is_empty(),
		"errors" = errors,
		"now" = now,
		"active" = active,
		"config_id" = SeasonConfig.ConfigIDOfRow(active),
		"scheduled" = SeasonConfig.ResolveAt(entries, now),
		"next_start" = SeasonConfig.NextScheduledStart(entries, now),
		"preempts_active" = SeasonConfig.ShouldPreempt(entries, active, now),
	}

# SOM-IDLE beta fechado (T5): Seasons é pós-lançamento — criação e ciclo de
# vida ficam TRAVADOS por padrão (qualquer chamada normal, GM ou job, vira
# no-op com aviso). Quem habilita é o env `SHAMBLETA_ENABLE_SEASONS=1`: os
# testes a ligam em `run_idle_tests.gd` e o deploy do beta a liga em
# `deploy/docker-compose.yml`. O ciclo coberto por essa ativação é
# active→closed→settled (`TickSeasonLifecycle` + `SettleSeasonPrizes`, com
# prova de idempotência no ledger por vencedor); não existe estágio
# "closing" no schema. Enquanto a env não estiver posta, o shell continua
# funcionando com Season Pass/placar vazios (as suítes de lock e de
# boards-empty cobrem exatamente isso).

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
	var now : int = SQLCommons.Timestamp()
	return _CreateSeasonWindow(now, now + days * 86400, rules)

# Meia pública da abertura com janela explícita: `starts_at` é o instante em que
# o relógio abre (nunca o `start_unix` do calendário — uma linha nascida no
# passado faria `SnapshotSeasonSpend` puxar gasto de antes da temporada para
# dentro da apuração) e `ends_at` é o do calendário quando a temporada tem janela
# nominal. É o que `EnsureSeason()` usa; `CreateSeason(days)` continua a rota do
# `/season create <dias>` e das suítes, com a mesma régua de antes.
func _CreateSeasonWindow(startsAt : int, endsAt : int, rules : String) -> int:
	if endsAt <= startsAt:
		return 0
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if not sql.db.query_with_bindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, ?, 'active');", [startsAt, endsAt, rules]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	_eco.settleMutex.unlock()
	return int(out["id"])

# G1: fechar É congelar. As quatro corridas são gravadas em `season_score` antes
# do flip active→closed, e o flip é protegido por `status = 'active'` +
# `changes()` — um segundo fechamento não reescreve o placar. A liquidação passou
# a ler só esse congelamento: antes ela relia as tabelas vivas, então podia
# correr horas depois do fim da temporada e premar quem treinou/gastou depois do
# `ends_at` (débitos 1 e 3 de archive/SEASON_ACTIVATION_NOTE.md). O `settleMutex`
# é o mesmo da criação, portanto não há interleaving dentro do processo.
# O que isto NÃO resolve: `power_score`, `bosses_beaten` e `guild.points` são
# contadores correntes sem histórico — o valor congelado é o do instante do
# fechamento. É por isso que o relógio de temporada fecha em minutos e não em
# horas (`SQLCommons.SeasonClockIntervalSec`): a janela restante é fração do ciclo
# de jogo. O estágio `CLOSING` com apuração por evento (débito 4) continua
# em aberto, e é pós-beta.
func CloseSeason(seasonID : int) -> bool:
	if Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE season_id = ? AND status = 'active';", [seasonID]).is_empty():
		return false
	_eco.settleMutex.lock()
	SnapshotSeasonPower(seasonID)
	SnapshotSeasonSpend(seasonID)
	SnapshotSeasonBossKills(seasonID)
	SnapshotSeasonGuildPoints(seasonID)
	var flipped : bool = Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'closed' WHERE season_id = ? AND status = 'active';", [seasonID])
	var changed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT changes() AS c;", [])
	_eco.settleMutex.unlock()
	return flipped and not changed.is_empty() and int(changed[0]["c"]) > 0

# ROADMAP_COMERCIAL S2 → OPS-2: esta função é a metade "abre" do relógio de
# produção (`SQLBackups`, logo depois de `TickSeasonLifecycle` fechar/liquidar a
# vencida) e o nome está amarrado em `SuiteSeasonBootstrap`, então fica. O que
# ela abre deixou de ser uma S1 hardcoded: desde OPS-2 ela delega a
# `EnsureSeason()`, que lê a temporada VIGENTE de `data/conf/seasons.json`
# (janela, duração, tema, trilha do passe, SKU cobrável). Lançar a S2 é anexar
# uma linha no arquivo — nenhum GDScript, nenhuma migration.
# Mantém as três regras de antes: -1 com a trava do beta (T5) desligada, 0 se já
# existe temporada ativa, season_id >0 quando abre.
# Congelado histórico: a S1 do beta continua descrita em
# `EconomyCatalog.SeasonS1Rules()` para quem lê a string congelada em linhas
# antigas. Quem abre temporada gera o equivalente direto da entrada do arquivo
# (`SeasonConfig.RulesJSONForEntry`), com `config_id` junto.
func EnsureSeasonS1() -> int:
	return EnsureSeason()

# Abre a temporada vigente do calendário. Fail-closed por construção: com
# `seasons.json` ausente/corrompido nada abre (-1 + push_error), porque abrir uma
# temporada sem regras nem pass validados é prometer premiação que o servidor não
# sabe entregar. Fechar e liquidar o que já está no banco NÃO passa por aqui —
# dívida com jogador não se nega por typo de agenda.
func EnsureSeason() -> int:
	if not SeasonsEnabled():
		push_warning("SOM-IDLE Seasons: criação bloqueada no beta (T5)")
		return -1
	if not ActiveSeason().is_empty():
		return 0
	var errors : PackedStringArray = SeasonConfig.Errors()
	if not errors.is_empty():
		push_error("Seasons: nenhuma temporada abre com seasons.json inválido (%s)" % "; ".join(errors))
		return -1
	var now : int = SQLCommons.Timestamp()
	var entry : Dictionary = SeasonConfig.EntryToOpen(SeasonConfig.Entries(), now)
	if entry.is_empty():
		push_error("Seasons: seasons.json sem entrada vigente para %d — nenhuma temporada abre" % now)
		return -1
	var window : Dictionary = SeasonConfig.WindowForEntry(entry, now)
	if window.is_empty():
		push_error("Seasons: a janela nominal de %s já venceu — nada a abrir" % SeasonConfig.ConfigID(entry))
		return -1
	var created : int = _CreateSeasonWindow(int(window["starts_at"]), int(window["ends_at"]), SeasonConfig.RulesJSONForEntry(entry))
	if created > 0:
		Util.PrintLog("Economy", "Season %d (%s) opened from seasons.json: %d dias" % [created, SeasonConfig.ConfigID(entry), (int(window["ends_at"]) - int(window["starts_at"])) / 86400])
	return created

func SnapshotSeasonPower(seasonID : int, limit : int = 100) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_score FROM character WHERE power_score > 0 ORDER BY power_score DESC LIMIT ?;", [limit])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'power', ?, ?);", [seasonID, int(row["char_id"]), int(row["power_score"])]):
			n += 1
	return n

func SnapshotSeasonSpend(seasonID : int) -> int:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT starts_at, ends_at FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return 0
	# G1: a corrida é a janela da temporada, não "tudo desde o início". Sem o
	# teto em `ends_at`, o gasto das horas entre o fim e o fechamento entrava na
	# apuração (débito 2 de archive/SEASON_ACTIVATION_NOTE.md).
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, SUM(-amount) AS spent FROM ledger_transaction WHERE kind = 'gems' AND amount < 0 AND created_at >= ? AND created_at <= ? GROUP BY account_id;", [int(season[0]["starts_at"]), int(season[0]["ends_at"])])
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

# Relógio de temporada (G1), parte 1 de 2: fecha as vencidas congelando o placar
# (incluindo as adiantadas por preempção do calendário, OPS-2) e liquida as
# fechadas. Quem abre a temporada é `EnsureSeasonS1`, chamado logo
# depois pelo mesmo relógio em `SQLBackups` — a separação é de propósito: fechar o
# que venceu e abrir a sucessora são decisões diferentes, e as suítes que só
# querem o fechamento (payout, races) não podem ganhar uma temporada ativa como
# efeito colateral. Rodado a cada `SQLCommons.SeasonClockIntervalSec` — também no
# boot. Idempotente: uma temporada só fecha e paga uma vez.
# A cadência curta é parte do conserto, não otimização: `power_score`,
# `bosses_beaten` e pontos de guild não têm histórico, então o placar congelado é
# o do instante do fechamento e cada hora de atraso é hora de jogo pós-temporada
# que entraria na apuração.
func TickSeasonLifecycle() -> Dictionary:
	if not SeasonsEnabled():
		return {"closed" = 0, "settled" = 0, "disabled" = true}
	var closed : int = 0
	var settled : int = 0
	var now : int = SQLCommons.Timestamp()
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'active' AND ends_at <= ?;", [now]):
		if CloseSeason(int(row["season_id"])):
			closed += 1
	# OPS-2: uma temporada de rotação também sai do ar por preempção — se o
	# calendário pôs uma sucessora AGENDADA no ar antes do `ends_at` derivado
	# (duração em dias), a linha em produção é fechada no ponto de troca. Sem
	# isto a sucessora estrearia atrasada pela sobra do ciclo antigo e as duas
	# ficariam simultâneas, o que o placar e o passe não modelam.
	var active : Dictionary = ActiveSeason()
	if not active.is_empty() and SeasonConfig.ShouldPreempt(SeasonConfig.Entries(), active, now):
		Util.PrintLog("Economy", "Season %d preemptada pelo calendário de seasons.json em %d" % [int(active["season_id"]), now])
		CloseSeason(int(active["season_id"]))
		# Confirma pelo estado observável, não pelo booleano de `CloseSeason`: a
		# prova de idempotência dele é um `SELECT changes()` que hoje cai numa
		# conexão de leitura do pool (SQL.gd) e devolve 0 mesmo com o flip
		# aplicado — contaria `closed = 0` para um fechamento que aconteceu. O
		# contrato do contador é "não sobrou temporada no ar", e é isso que se lê.
		if ActiveSeason().is_empty():
			closed += 1
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'closed';", []):
		var res : Dictionary = SettleSeasonPrizes(int(row["season_id"]))
		if bool(res.get("ok", false)):
			settled += 1
	return {"closed" = closed, "settled" = settled}

# Liquida os prêmios de uma temporada fechada a partir do placar CONGELADO por
# `CloseSeason` (não das tabelas vivas), concede gems aos top-N por corrida e
# marca 'settled'. Gems (não-casháveis) via AddGems
# com reason 'season_prize:<id>:<kind>:<subject>' — a prova no ledger garante
# idempotência por vencedor, mesmo se uma execução anterior falhou no meio.
# Sem snapshot aqui de propósito: se ele existisse, a liquidação de uma
# temporada vencida dias antes recompunha o placar com o estado corrente e
# pagaria quem subiu depois do fim.
func SettleSeasonPrizes(seasonID : int) -> Dictionary:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return {"ok" = false, "reason" = "not_found", "awarded" = 0}
	var status : String = str(season[0]["status"])
	if status == "settled":
		return {"ok" = true, "reason" = "already_settled", "awarded" = 0}
	if status != "closed":
		return {"ok" = false, "reason" = "not_closed", "awarded" = 0}

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
