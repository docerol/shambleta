extends RefCounted
class_name GuildService

# SOM-IDLE Fatia 2 (ROADMAP_COMERCIAL S3): guild domain extraído de
# EconomyService. Composição com back-reference (_eco): o serviço não tem
# transação nem mutex próprios — usa o MESMO settleMutex e os MESMOS helpers
# raw de EconomyService, então a semântica de locking é 100% idêntica à de
# antes da extração (nenhum risco novo de concorrência). Os wrappers públicos
# ficam em EconomyService (callers não mudam).

var _eco : EconomyService = null

# ------------------------------------------------------------------ E1: guilds
# Custo de nível 1→2 .. 9→10 (índice = nível atual). Pontos: coluna pronta,
# acúmulo via settle = fast follow (v0 = gold+gems).

func GetGuildForAccount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int(rows[0]["guild_id"]) if not rows.is_empty() else 0

func GetGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id, name, level, points, leader_account, created_at FROM guild WHERE guild_id = ?;", [guildID])
	return {} if rows.is_empty() else rows[0]

func GetMemberRank(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str(rows[0]["rank"]) if not rows.is_empty() else ""

func GuildBuffForAccount(accountID : int) -> float:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT g.level FROM guild g INNER JOIN guild_member m ON m.guild_id = g.guild_id WHERE m.account_id = ?;", [accountID])
	if rows.is_empty():
		return 1.0
	return 1.0 + EconomyCatalog.GuildBuffPerLevel * float(maxi(0, int(rows[0]["level"]) - 1))

func GetGuildLeaderboard(limit : int = 10) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT g.guild_id, g.name, g.level, g.points, COUNT(m.account_id) AS members FROM guild g LEFT JOIN guild_member m ON m.guild_id = g.guild_id GROUP BY g.guild_id ORDER BY g.level DESC, g.points DESC, members DESC LIMIT ?;", [limit])

# SOM-IDLE social (painel de guild): busca por nome para o fluxo "procurar e
# entrar" sem comando. Case-insensitive, substring, limitado. LIKE faz o `LOWER`
# das duas pontas — SQLite só tem collation NOCASE no ASCII, e é o bastante para
# o catálogo de guilds (nomes validados por CheckSize). Devolve só o necessário
# para o painel listar e oferecer "entrar": id, nome, tag, nível, pontos, membros.
func SearchGuilds(query : String, limit : int = 20) -> Array[Dictionary]:
	var clean : String = query.strip_edges()
	if clean.is_empty():
		return []
	var pattern : String = "%" + clean.to_lower() + "%"
	return Launcher.SQL.QueryBindings("SELECT g.guild_id, g.name, g.tag, g.level, g.points, COUNT(m.account_id) AS members FROM guild g LEFT JOIN guild_member m ON m.guild_id = g.guild_id WHERE LOWER(g.name) LIKE ? GROUP BY g.guild_id ORDER BY g.name ASC LIMIT ?;", [pattern, limit])

# IDs de conta dos membros de uma guild — base do roteamento de chat de guild e
# do fanout que o Server precisa para entregar uma linha ao canal. Server resolve
# account → peer via Peers.accounts; a guild não conhece transporte, só pertinência.
func GetMemberAccounts(guildID : int) -> Array:
	var accounts : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT account_id FROM guild_member WHERE guild_id = ?;", [guildID]):
		accounts.append(int(row["account_id"]))
	return accounts

func GetGuildIDForName(guildName : String) -> int:
	var clean : String = guildName.strip_edges()
	if clean.is_empty():
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id FROM guild WHERE LOWER(name) = ?;", [clean.to_lower()])
	return int(rows[0]["guild_id"]) if not rows.is_empty() else 0

func CreateGuild(accountID : int, charID : int, guildName : String) -> int:
	var clean : String = guildName.strip_edges()
	if not NetworkCommons.CheckSize(clean, 3, 30) or GetGuildForAccount(accountID) != 0:
		return 0
	var out : Dictionary = {"id" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if _eco._CharGoldRaw(charID) < EconomyCatalog.GuildCreateCostGold:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild (name, level, points, leader_account, created_at) VALUES (?, 1, 0, ?, ?);", [clean, accountID, SQLCommons.Timestamp()]):
			return false
		var guildID : int = sql.LastInsertRowIDRaw()
		if guildID <= 0:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'leader', ?);", [guildID, accountID, SQLCommons.Timestamp()]):
			return false
		var gp : int = _eco._CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - EconomyCatalog.GuildCreateCostGold}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -EconomyCatalog.GuildCreateCostGold, gp - EconomyCatalog.GuildCreateCostGold, "guild_create"):
			return false
		out["id"] = guildID
		return true):
		pass
	_eco.settleMutex.unlock()
	return int(out["id"])

# Admissão ao roster. A checagem de fora (`JoinReason`) é para DEVOLVER O MOTIVO ao
# jogador; ela não é a decisão. AUDITORIA rodada 3 (social): aqui e em
# `PromoteMember`/`DemoteMember`/`RemoveMember` o caminho era
# leitura (`QueryBindings`, lock próprio) → escrita (`ExecuteBindings`, lock próprio)
# sem nenhum funil segurando as duas — entre as duas acquisition outro join/promote
# entrava, e o resultado era ou roster acima do teto ou posto perdido (merge perdido).
# Agora as quatro mutações do roster passam pelo MESMO funil serializado do resto do
# arquivo (`_eco.settleMutex` + `Launcher.SQL.Transaction`), que é o padrão que
# `CreateGuild`, `LeaveGuild`, `DepositToVault` e `WithdrawFromVault` já usam, e
# re-fazem a política dentro da transação com as leituras cruas que a transação
# permite (`db.select_rows` / `db.query_with_bindings` / `UpdateRowsRaw`).
func JoinGuild(accountID : int, guildID : int) -> bool:
	if GuildRoster.JoinReason(accountID, guildID) != GuildRoster.ReasonOk:
		return false	# o motivo é um token do catálogo; `GuildRoster.RefusalFor` o devolve para a tela
	var joined : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if sql.db.select_rows("guild", "guild_id = %d" % guildID, ["guild_id"]).is_empty():
			return false
		if not sql.db.select_rows("guild_member", "account_id = %d" % accountID, ["guild_id"]).is_empty():
			return false
		# O teto re-respondido DENTRO do funil, pela boca única de `GuildRoster`.
		if GuildRoster.IsFullLocked(sql, guildID):
			return false
		return bool(sql.db.query_with_bindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);", [guildID, accountID, SQLCommons.Timestamp()]))):
		joined = true
	_eco.settleMutex.unlock()
	return joined

func LeaveGuild(accountID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var left : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var members : Array = sql.db.select_rows("guild_member", "guild_id = %d ORDER BY joined_at" % guildID, ["account_id", "rank"])
		if members.is_empty():
			return false
		var isLeader : bool = false
		for m in members:
			if int(m["account_id"]) == accountID and str(m["rank"]) == "leader":
				isLeader = true
		if members.size() == 1:
			# Último membro dissolve a guild — vault precisa estar vazio (sem perda).
			if not sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"]).is_empty():
				return false
			if not sql.DeleteRowsRaw("guild_member", "guild_id = %d" % guildID):
				return false
			return sql.DeleteRowsRaw("guild", "guild_id = %d" % guildID)
		if not sql.DeleteRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, accountID]):
			return false
		if isLeader:
			# Promove o membro mais antigo a líder.
			for m in members:
				if int(m["account_id"]) != accountID:
					return sql.UpdateRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, int(m["account_id"])], {"rank" = "leader"}) \
						and sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"leader_account" = int(m["account_id"])})
			return false
		return true):
		left = true
	_eco.settleMutex.unlock()
	return left

func DepositToVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _eco._ItemCountRaw(charID, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID]):
			return false
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty():
			# Fase F: teto de stacks distintas (expansível por nível/compra).
			var distinct : Array = sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"])
			if distinct.size() >= VaultSlotsForGuild(guildID).get("cap", 0):
				return false
			if not sql.db.insert_row("guild_vault", {"guild_id" = guildID, "item_id" = itemID, "count" = count}):
				return false
		elif not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = int(vault[0]["count"]) + count}):
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'deposit', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()]):
			return false
		return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, -count, 0, "vault_deposit:%d:%d" % [guildID, itemID])):
		ok = true
	_eco.settleMutex.unlock()
	return ok

func WithdrawFromVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	# §14, metade do SERVIDOR. O teto por ação é checável sem banco, então ele vai
	# antes do lock: um cliente modado que manda `count = 10^9` recebe `false` sem
	# nem abrir transação.
	if count > GuildVaultLimits.MaxWithdrawPerAction:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		# A janela é contada no RASTRO, não em memória de processo: um limitador em
		# dicionário morre no restart, e reconectar é a primeira coisa que um oficial
		# modado tenta. `guild_vault_log` já é escrito por este próprio caminho
		# (append-only), então a contagem da janela é a MESMA evidência que o painel
		# mostra em `GuildVaultTrail`. Dentro da transação de propósito: conferir
		# antes e gravar depois, fora da transação, deixaria duas abas simultâneas
		# gastarem o mesmo crédito de janela.
		if _WithdrawsInWindowLocked(sql, accountID) >= GuildVaultLimits.MaxWithdrawActionsInWindow:
			return false
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty() or int(vault[0]["count"]) < count:
			return false
		var remain : int = int(vault[0]["count"]) - count
		if remain > 0:
			if not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = remain}):
				return false
		elif not sql.DeleteRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID]):
			return false
		if _eco._GrantStackRaw(charID, accountID, itemID, count, "vault_withdraw:%d:%d" % [guildID, itemID], "vault_withdraw") == 0:
			return false
		return sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'withdraw', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()])):
		ok = true
	_eco.settleMutex.unlock()
	return ok

# Quantos saques DA CONTA caem na janela anti-dreno. Falha de leitura é recusa
# (`999`), nunca licença: o caminho já é o do dinheiro, e um SELECT que quebra não
# pode virar "deixa passar" — mesmo contrato de `SQL.TradeCountTodayRaw`.
# O índice que sostiene a consulta é `idx_vault_log_window`, criado em
# data/conf/migrations/060_vault_withdraw_gate.sql e asserido como SEARCH por
# `tests/guild_vault_gate_test.gd` (sem ele seria um SCAN num log append-only que
# cresce para sempre — o gate mais caro da casa).
func _WithdrawsInWindowLocked(sql : SQLService, accountID : int) -> int:
	if not sql.db.query_with_bindings("SELECT COUNT(*) AS n FROM guild_vault_log WHERE account_id = ? AND kind = 'withdraw' AND created_at >= ?;", [accountID, SQLCommons.Timestamp() - GuildVaultLimits.WindowSec]):
		return 999
	var res : Array = sql.db.query_result
	return int(res[0].get("n", 999)) if not res.is_empty() else 999

func LevelUpGuild(accountID : int, charID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= EconomyCatalog.GuildMaxLevel:
			return false
		var costGold : int = EconomyCatalog.GuildLevelCostGold[level]
		var costGems : int = EconomyCatalog.GuildLevelCostGems[level]
		if _eco._CharGoldRaw(charID) < costGold:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < costGems:
			return false
		var gp : int = _eco._CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - costGold}):
			return false
		if not sql.SetGemsRaw(accountID, gems - costGems):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -costGold, gp - costGold, "guild_level"):
			return false
		return _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -costGems, gems - costGems, "guild_level")):
		ok = true
	_eco.settleMutex.unlock()
	return ok

# Quantas linhas a ÚLTIMA escrita desta conexão mexeu. Só tem significado dentro do
# funil: lida fora da transação, ela respondia pela escrita do OUTRO thread (o
# `changes()` é por conexão, não por chamada). Com `settleMutex` + `Transaction`
# segurando o par escrita→contagem, é a prova de que o posto mudou mesmo.
func _ChangedRaw(sql : SQLService) -> int:
	if not bool(sql.db.query_with_bindings("SELECT changes() AS c;", [])):
		return 0
	var res : Array = sql.db.query_result
	return int(res[0].get("c", 0)) if not res.is_empty() else 0

# Posto de um account DA GUILDA DO LÍDER, re-respondido dentro do funil. É a perna
# de escrita dos dois verbos de posto (`PromoteMember`/`DemoteMember`); existia antes
# como dois bodies separados que liam rank/guild por `QueryBindings` (lock próprio) e
# gravavam por `ExecuteBindings` (outro lock) — dois promotes concorrentes sobre o
# mesmo roster podiam um escrever em cima do outro, e o `WHERE account_id = ?` ainda
# alcançava qualquer guilda do banco, não só a do ator.
func _SetMemberRank(leaderAccount : int, targetAccount : int, rank : String) -> bool:
	if leaderAccount <= 0 or targetAccount <= 0 or rank.is_empty():
		return false
	var done : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var leaderRows : Array = sql.db.select_rows("guild_member", "account_id = %d" % leaderAccount, ["guild_id", "rank"])
		if leaderRows.is_empty() or str(leaderRows[0]["rank"]) != "leader":
			return false
		var guildID : int = int(leaderRows[0]["guild_id"])
		if guildID <= 0:
			return false
		var targetRows : Array = sql.db.select_rows("guild_member", "guild_id = %d AND account_id = %d" % [guildID, targetAccount], ["rank"])
		if targetRows.is_empty():
			return false
		if str(targetRows[0]["rank"]) == "leader":
			return false
		if not sql.UpdateRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, targetAccount], {"rank" = rank}):
			return false
		return _ChangedRaw(sql) > 0):
		done = true
	_eco.settleMutex.unlock()
	return done

func PromoteMember(leaderAccount : int, targetAccount : int) -> bool:
	# O líder não tem posto acima dele para onde ser "promovido", e deixá-lo sem
	# linha de líder seria a guilda órfã por um clique. `GuildRoster.Kick` recusa o
	# mesmo caso por outro motivo (ninguém se chuta); aqui é a tabela se protegendo.
	return _SetMemberRank(leaderAccount, targetAccount, "officer")

# Rebaixa a `member`. É o avesso de `PromoteMember` e existe pelo mesmo motivo do
# outro lado da política: sem rebaixar, promover é um depósito — um posto errado fica
# errado para sempre. O líder não é rebaixável pela mesma razão de acima.
func DemoteMember(leaderAccount : int, targetAccount : int) -> bool:
	return _SetMemberRank(leaderAccount, targetAccount, "member")

# Tira um account da fileira. ESCREVE só em `guild_member`: dissolver a guilda não é
# remoção, é `LeaveGuild` (que exige vault vazio e promove o mais antigo quando sobra
# gente) — um kick que sumisse com a última linha deixaria um `guild` sem dono e um
# vault sem ninguém para esvaziá-lo. O `rank <> 'leader'` na WHERE é o teto da decisão
# nº 3 da política dentro do dono da tabela: quem chuta não é o líder, e quem é o líder
# não sai por aqui. `changes()` confere que a linha caiu mesmo (um UPDATE/DELETE que não
# casa linha nenhuma é sucesso de query — precedente `SQL.gd`, `ResolveReport`), e por
# isso a contagem passou a ser lida NA MESMA transação da escrita: lida do lado de
# fora, ela era o resultado da escrita de outro thread (dois kicks do mesmo alvo
# davam "removi" para quem não removeu nada, e "nada" para quem removeu).
func RemoveMember(guildID : int, targetAccount : int) -> bool:
	if guildID <= 0 or targetAccount <= 0:
		return false
	var removed : bool = false
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if not bool(sql.db.query_with_bindings("DELETE FROM guild_member WHERE guild_id = ? AND account_id = ? AND rank <> 'leader';", [guildID, targetAccount])):
			return false
		return _ChangedRaw(sql) > 0):
		removed = true
	_eco.settleMutex.unlock()
	return removed

# Trilha de auditoria da GOVERNANÇA (AUDITORIA 2026-09-28, item 3): cada promote/demote/
# kick que o SERVIDOR aceitou fica reviewável depois, na MESMA forma append-only do
# `guild_vault_log` — tabela própria (`guild_governance_log`, migration 062), uma linha por
# ação, lida por guild+ação+tempo via `idx_governance_log_review`. O ator é o
# `actorAccount` autenticado que os verbos de `GuildRoster` já conferiram CONTRA O RANK
# LIDO DO BANCO (nunca um role declarado pelo cliente) — o contrato de autorização da casa.
# A ESCRITA mora aqui, no dono das tabelas de guild: quem chama (`GuildRoster`) chega por
# `Launcher.Economy.guildService`, o mesmo acesso direto ao service que `ChatModeration`
# usa para `GetMemberAccounts`. Best-effort por desenho: um INSERT de rastro que falha não
# desfaz a governança já aplicada (o rastro é evidência, não a decisão), mas nunca aceita
# args inválidos — registro sem ator/alvo/ação é ruído, não trilha.
func LogGovernance(guildID : int, actorAccount : int, targetAccount : int, action : String) -> bool:
	if guildID <= 0 or actorAccount <= 0 or targetAccount <= 0 or action.is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO guild_governance_log (guild_id, actor_account, target_account, action, created_at) VALUES (?, ?, ?, ?, ?);", [guildID, actorAccount, targetAccount, action, SQLCommons.Timestamp()])

# §14, metade do SERVIDOR: o rastro de governança sai do banco por um accessor do serviço,
# não por quem desenha a tela (mesmo contrato de `VaultTrail`). Read-only; LIMIT 20 porque
# é uma janela de revisão, não um extrato completo.
func GovernanceTrail(guildID : int) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT actor_account, target_account, action, created_at FROM guild_governance_log WHERE guild_id = ? ORDER BY id DESC LIMIT 20;", [guildID])

# Follow-up G3: tag da guild (2–5 chars A-Z0-9, só líder). Exibida no board,
# no painel e nas corridas ([TAG] Nome) — identidade sem poder.
func SetGuildTag(accountID : int, tag : String) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	if GetMemberRank(accountID) != "leader":
		return {"ok": false, "reason": "not_leader"}
	var clean : String = tag.strip_edges().to_upper()
	if not EconomyCatalog.IsValidGuildTag(clean):
		return {"ok": false, "reason": "bad_tag"}
	if not Launcher.SQL.ExecuteBindings("UPDATE guild SET tag = ? WHERE guild_id = ?;", [clean, guildID]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "tag": clean}

# ------------------------------------------------------------------ Fase F: guild premium (MONETIZATION §1 item 10)
#
# Pontos acumulam no settle (1/hora) e na vitória de boss (+5): a corrida
# guild_points da temporada nasce daqui. Level-up fast pula o gold (2× gems).
# Vault tem teto de stacks distintas (10 + 2/nível + comprados, máx +20).

func AddGuildPoints(guildID : int, points : int) -> bool:
	if guildID <= 0 or points <= 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild SET points = points + ? WHERE guild_id = ?;", [points, guildID])

# Chamado no settle (dentro da transação do caller): 1 pt/hora liquidada.
func GuildSettlePoints(accountID : int, hours : float) -> void:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID > 0:
		AddGuildPoints(guildID, maxi(1, floori(hours)))

func VaultSlotsForGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT level, vault_slots_purchased FROM guild WHERE guild_id = ?;", [guildID])
	if rows.is_empty():
		return {"cap": 0, "used": 0, "purchased": 0}
	var cap : int = EconomyCatalog.GUILD_VAULT_BASE_SLOTS + EconomyCatalog.GUILD_VAULT_PER_LEVEL * maxi(0, int(rows[0].get("level", 1)) - 1) + int(rows[0].get("vault_slots_purchased", 0))
	var used : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM guild_vault WHERE guild_id = ?;", [guildID])
	return {"cap": cap, "used": int(used[0]["n"]) if not used.is_empty() else 0, "purchased": int(rows[0].get("vault_slots_purchased", 0))}

# SOM-IDLE social: stacks distintas do vault (item_id + count), para o painel
# listar cada pilha com um botão de retirada. Read-only; não mexe no locking nem
# no invariante do vault (só espelha guild_vault).
func VaultStacks(guildID : int) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT item_id, count FROM guild_vault WHERE guild_id = ? ORDER BY item_id;", [guildID])

# §14 (AUDITORIA 2026-09-27): o rastro do vault sai do SERVIDOR. Antes a tela tinha
# um ramo de leitura que ia direto à `Launcher.SQL` "no boot dev", e a fronteira
# que a suíte 2fa-m1 mede é justamente esta: quem desenha a UI não consulta o
# banco, consulta o estado que o serviço autorizou. LIMIT fechado em 12 porque o
# painel é uma janela, não um extrato.
func VaultTrail(guildID : int) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT account_id, char_id, item_id, count, kind, created_at FROM guild_vault_log WHERE guild_id = ? ORDER BY id DESC LIMIT 12;", [guildID])

func GetGuildState(accountID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	var mine : Dictionary = {}
	if guildID > 0:
		var g : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild WHERE guild_id = ?;", [guildID])
		var members : Array = []
		# SOM-IDLE social: enriquece cada membro com account_id e a lista de nicks
		# dos personagens da conta. Presença é por agente (nick), não por conta, e o
		# painel precisa do nick para casar com o índice O(1) de OnlineList — antes
		# só vinha `username`, que nunca bate com `agent.nick`. Aditivo: Social.gd e o
		# push do Server leem name/rank e continuam funcionando.
		var nicksByAccount : Dictionary = {}
		for c in Launcher.SQL.QueryBindings("SELECT gm.account_id, ch.nickname FROM guild_member AS gm INNER JOIN character AS ch ON ch.account_id = gm.account_id WHERE gm.guild_id = ?;", [guildID]):
			var cid : int = int(c.get("account_id", 0))
			if not nicksByAccount.has(cid):
				nicksByAccount[cid] = []
			nicksByAccount[cid].append(str(c.get("nickname", "")))
		for m in Launcher.SQL.QueryBindings("SELECT a.account_id, a.username, gm.rank FROM guild_member AS gm INNER JOIN account AS a ON a.account_id = gm.account_id WHERE gm.guild_id = ? ORDER BY gm.rank, a.username;", [guildID]):
			var accID : int = int(m.get("account_id", 0))
			members.append({"name": str(m.get("username", "?")), "rank": str(m.get("rank", "member")),
				"account_id": accID, "nicks": nicksByAccount.get(accID, [])})
		if not g.is_empty():
			mine = {"id": guildID, "name": str(g[0].get("name", "?")), "tag": str(g[0].get("tag", "")),
				"level": int(g[0].get("level", 1)),
				"points": int(g[0].get("points", 0)), "my_rank": GetMemberRank(accountID),
				"vault": VaultSlotsForGuild(guildID), "vault_stacks": VaultStacks(guildID),
				"vault_log": VaultTrail(guildID), "members": members}
	var board : Array = []
	for b in Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild ORDER BY points DESC, guild_id ASC LIMIT 10;", []):
		board.append({"name": str(b.get("name", "?")), "tag": str(b.get("tag", "")), "level": int(b.get("level", 1)), "points": int(b.get("points", 0))})
	return {"ok": true, "my_guild": mine, "board": board,
		"vault_slot_cost": EconomyCatalog.GUILD_VAULT_SLOT_COST}

# P1-C (auditoria 2026-10-06): o `LevelUpGuildFast` (2× gems, pula a escada de
# gold) foi REMOVIDO — era a perna que convertia dinheiro real em multiplicador
# permanente de faucet (92.340 gems ≈ R$ 2.459 por ×1.18 em três torneiras),
# cruzando a linha "sem P2W" que o próprio roadmap declara. A escada honesta
# (`LevelUpGuild`, gold + gems) continua única.

# Expansão do vault (leader/officer): +1 stack distinta por 200 gems (máx 20).
func BuyVaultSlots(accountID : int, charID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return {"ok": false, "reason": "not_officer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["vault_slots_purchased"])
		if rows.is_empty():
			return false
		var bought : int = int(rows[0].get("vault_slots_purchased", 0))
		if bought >= EconomyCatalog.GUILD_VAULT_SLOTS_MAX:
			result["reason"] = "slots_cap"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.GUILD_VAULT_SLOT_COST:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.GUILD_VAULT_SLOT_COST):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"vault_slots_purchased" = bought + 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGems, -EconomyCatalog.GUILD_VAULT_SLOT_COST, gems - EconomyCatalog.GUILD_VAULT_SLOT_COST, "guild_vault_slots"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = bought + 1
		return true):
		pass
	_eco.settleMutex.unlock()
	return result
