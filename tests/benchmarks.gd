extends SceneTree

# SOM-IDLE P2: performance benchmark gate.
# Measures settle, XP walk, and zone catalog operations.
# Exit code: 0 = within budget, 1 = over budget.

const BudgetSettleMs: int = 500
const BudgetZoneCatalogMs: int = 200
const BudgetSettleP99Ms: int = 200
# Fração tolerada de settles acima de 50 ms. O auto-checkpoint do WAL é caro por
# natureza (é um fsync do arquivo) e não existe código de jogo que o barateie — o
# que se pode exigir é a *taxa* do hitch. 2% de 800 iterações são 16; o default do
# SQLite (1000 páginas) media 2 em 200, ou 1%. Acima disso, alguém afrouxou o
# checkpoint ou o colocou num caminho quente.
const BudgetSlowIterPct: int = 2
const BudgetLeaderboardMs: int = 50
const BudgetAuctionBrowseMs: int = 50
# Save/logout: três upserts em lote dentro de uma transação. O orçamento é de
# round trip, não de tempo — é o número que crescia com o progresso do jogador.
const BudgetLogoutQueries: int = 12
const BudgetLogoutTransactions: int = 1
# Crescimento de objeto ao longo dos 800 settles do probe: a régua não media
# memória antes, e foi assim que um `queue_free()` em nó fora da árvore sobreviveu
# ao beta gate.
const BudgetObjectGrowth: int = 400
const BudgetResourceGrowth: int = 200
# 800, não 200: com o auto-checkpoint em 4000 páginas, 200 settles não cruzam a
# fronteira nenhuma vez — o probe fecharia verde sem nunca pagar um checkpoint e
# estaria medindo o cache, não o servidor. 800 crosses a fronteira e devolve o
# custo real no `max`.
const LoadProbeIters: int = 800
const ExpectedZoneCount: int = 24
# Massa das duas leituras ordenadas: 60 personagens para um LIMIT 50 (a página
# tem que nascer cheia e disputada) e 200 listings para um LIMIT 20.
const LbSeedChars: int = 60
const AhSeedListings: int = 200

func _initialize():
    _run_benchmarks()

func _getAutoload(nodeName: String) -> Node:
    return root.get_node_or_null(NodePath(nodeName))

func _run_benchmarks():
    print("== Performance Benchmarks ==")

    var launcher: Node = _getAutoload("Launcher")
    if launcher == null:
        print("FATAL: Launcher autoload missing")
        quit(1)
        return

    var waited: int = 0
    var sqlNode: Node = null
    var worldNode: Node = null
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        sqlNode = launcher.SQL
        worldNode = launcher.World
        if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
            break

    if sqlNode == null or worldNode == null or not sqlNode.isInitialized or not worldNode.isInitialized:
        print("FATAL: Services not initialized within timeout")
        quit(1)
        return

    print("Services initialized after %d ms" % waited)

    # Beta fechado: duck-typed (ver run_idle_tests.gd) — sem refs estáticas.
    var sql: Node = sqlNode
    var economy: Node = launcher.Economy
    var failures: int = 0

    # Benchmark: settle (single character) — caminho real OfflineSettle.
    # (Antes chamava EconomyService.SettleCharacter, que não existe: o
    # benchmark nunca rodou. Beta fechado: usa SettlePending duck-typed.)
    var settleScript: GDScript = load("res://sources/idle/OfflineSettle.gd")
    sql.AddAccount("bench_settle", "testpass", "bench_settle@test.local")
    var benchAcct: int = sql.GetAccountID("bench_settle")
    # ActorCommons via load() em runtime (ref estática no -s quebra o compile
    # antes dos autoloads — mesma regra de run_idle_tests.gd).
    var commons: GDScript = load("res://sources/actor/ActorCommons.gd")
    sql.AddCharacter(benchAcct, "BenchSettle", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var benchChar: int = sql.GetCharacterID(benchAcct, "BenchSettle")
    sql.SetCharacterFarmZone(benchChar, 1)
    sql.UpdateSettleAnchor(benchChar, 1750000000, 1.0)
    sql.ResetCounters()
    var settleStart: int = Time.get_ticks_msec()
    var settleResult: Dictionary = settleScript.SettlePending(benchChar)
    var settleMs: int = Time.get_ticks_msec() - settleStart
    var settleQueries: int = sql.QueryCount()
    var settleTx: int = sql.TransactionCount()
    sql.db.delete_rows("character", "nickname = 'BenchSettle'")
    sql.db.delete_rows("account", "username = 'bench_settle'")
    print("Settle benchmark: %d ms, %d queries, %d tx (budget: %d ms)" % [settleMs, settleQueries, settleTx, BudgetSettleMs])
    if settleResult.is_empty():
        print("FAIL: settle returned empty")
        failures += 1
    if settleMs > BudgetSettleMs:
        print("FAIL: settle exceeded budget")
        failures += 1

    # Benchmark: zone catalog — o laço ia até 41 numa coleção de 24; agora o
    # tamanho esperado é asserção, não coincidência de print.
    var catalogStart: int = Time.get_ticks_msec()
    var zoneCount: int = 0
    var farmZones: GDScript = load("res://sources/idle/FarmZoneData.gd")
    for zoneID in range(1, ExpectedZoneCount + 1):
        if farmZones.GetZone(zoneID):
            zoneCount += 1
    var catalogMs: int = Time.get_ticks_msec() - catalogStart
    print("Zone catalog benchmark: %d ms for %d zones (budget: %d ms)" % [catalogMs, zoneCount, BudgetZoneCatalogMs])
    if catalogMs > BudgetZoneCatalogMs:
        print("FAIL: zone catalog exceeded budget")
        failures += 1
    if zoneCount != ExpectedZoneCount:
        print("FAIL: zona faltando no catálogo (%d de %d)" % [zoneCount, ExpectedZoneCount])
        failures += 1

    # Benchmark: as duas leituras ordenadas quentes do produto, com linhas reais na
    # mesa e o plano de execução conferido. Antes era o "XP walk" de `totalXp += 10`
    # sobre zero linhas: sem dados, o ORDER BY não compete com nada e um índice
    # ausente imprime exatamente a mesma coisa. O índice da migration 047 sem
    # asserção de plano é arquivo que ninguém usa.
    var lbSeed: Array[int] = []
    sql.AddAccount("bench_lb", "testpass", "bench_lb@test.local")
    var lbAcct: int = sql.GetAccountID("bench_lb")
    for i in range(LbSeedChars):
        sql.AddCharacter(lbAcct, "BenchLb%d" % i, commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
        var seedChar: int = sql.GetCharacterID(lbAcct, "BenchLb%d" % i)
        lbSeed.append(seedChar)
        # Potência esparsa e fora de ordem de inserção: se o índice não existir,
        # o SQLite paga temp B-tree e o time/plan mostram.
        sql.UpdatePowerScore(seedChar, (i * 7919) % (LbSeedChars * 3))
    # Realce nas 20 linhas MAIS ANTIGAS: se a ordenação esquecer `highlight`, o
    # LIMIT 20 devolve as 20 mais novas e a asserção cai. Sem o índice, o plano
    # paga temp B-tree. As duas falhas são distinguishable.
    for i in range(AhSeedListings):
        sql.ExecuteBindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, status, highlight, created_at) VALUES (?, ?, ?, ?, ?, 'open', ?, ?);", [
            lbSeed[i % lbSeed.size()], lbAcct, 1234 + i, 1, 1000 + i, 1 if i < 20 else 0, 1750000000 + i])

    var lbStart: int = Time.get_ticks_msec()
    var lbRows: Array[Dictionary] = sql.GetLeaderboard(50)
    var lbMs: int = Time.get_ticks_msec() - lbStart
    var lbPlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN SELECT c.char_id, s.level, c.power_score, a.username FROM character AS c INNER JOIN account AS a ON c.account_id = a.account_id INNER JOIN stat AS s ON s.char_id = c.char_id ORDER BY c.power_score DESC, c.char_id ASC LIMIT 50;"):
        lbPlan += String(row.get("detail", "")) + " | "
    print("Leaderboard: %d ms, %d de %d personagens, plan: %s" % [lbMs, lbRows.size(), LbSeedChars, lbPlan])
    if lbMs > BudgetLeaderboardMs:
        print("FAIL: leaderboard exceeded budget")
        failures += 1
    var lbOrdered: bool = true
    for i in range(1, lbRows.size()):
        if int(lbRows[i - 1].get("power_score", 0)) < int(lbRows[i].get("power_score", 0)):
            lbOrdered = false
    if lbRows.size() != 50:
        print("FAIL: leaderboard devolveu %d linhas com %d personagens semeados" % [lbRows.size(), LbSeedChars])
        failures += 1
    if not lbOrdered:
        print("FAIL: leaderboard fora de ordem em power_score DESC")
        failures += 1
    if lbPlan.find("TEMP B-TREE") >= 0:
        print("FAIL: leaderboard ordenando em temp B-tree — idx_character_leaderboard não está sendo usado")
        failures += 1
    if lbPlan.find("idx_character_leaderboard") < 0:
        print("FAIL: leaderboard sem o índice de cobertura da migration 047")
        failures += 1

    var ahStart: int = Time.get_ticks_msec()
    var ahRows: Array[Dictionary] = economy.BrowseListings(20)
    var ahMs: int = Time.get_ticks_msec() - ahStart
    var ahPlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE status = 'open' ORDER BY highlight DESC, id DESC LIMIT 20;"):
        ahPlan += String(row.get("detail", "")) + " | "
    print("Auction browse: %d ms, %d de %d listing(s), plan: %s" % [ahMs, ahRows.size(), AhSeedListings, ahPlan])
    if ahMs > BudgetAuctionBrowseMs:
        print("FAIL: browse do leilão excedeu o orçamento")
        failures += 1
    # São exatamente 20 realces e o LIMIT é 20: "todas as linhas voltadas têm
    # highlight=1" só é verdade se a ordenação usou o destaque, e os id
    # estritamente decrescentes provam o segundo termo do ORDER BY.
    var ahOk: bool = ahRows.size() == 20
    for i in range(ahRows.size()):
        if int(ahRows[i].get("highlight", 0)) != 1:
            ahOk = false
        if i > 0 and int(ahRows[i - 1].get("id", 0)) <= int(ahRows[i].get("id", 0)):
            ahOk = false
    if not ahOk:
        print("FAIL: browse não devolveu os 20 realces em id DESC")
        failures += 1
    if ahPlan.find("TEMP B-TREE") >= 0:
        print("FAIL: browse do leilão em temp B-tree — idx_auction_browse não está sendo usado")
        failures += 1
    if ahPlan.find("idx_auction_browse") < 0:
        print("FAIL: browse sem o índice de cobertura da migration 047")
        failures += 1

    sql.db.delete_rows("auction_listing", "seller_account = %d" % lbAcct)
    sql.db.delete_rows("stat", "char_id IN (SELECT char_id FROM character WHERE account_id = %d)" % lbAcct)
    sql.db.delete_rows("character", "account_id = %d" % lbAcct)
    sql.db.delete_rows("account", "username = 'bench_lb'")

    # Benchmark: save/logout — round trips de UpdateProgress com o progresso de
    # um jogador razoavelmente avançado (30 quests, 80 mobs, 40 skills). Antes:
    # três statements por entrada, cada um no próprio BEGIN/END.
    sql.AddAccount("bench_progress", "testpass", "bench_progress@test.local")
    var progAcct: int = sql.GetAccountID("bench_progress")
    sql.AddCharacter(progAcct, "BenchProgress", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var progChar: int = sql.GetCharacterID(progAcct, "BenchProgress")
    var progress = load("res://sources/actor/Progress.gd").new(null, false)
    for q in range(30):
        progress.quests["quest%d".hash() + q] = q % 3
    for b in range(80):
        progress.bestiary["mob%d".hash() + b] = b * 7
    for s in range(40):
        progress.skills["skill%d".hash() + s] = 1
    sql.ResetCounters()
    var progStart: int = Time.get_ticks_msec()
    var progOk: bool = sql.UpdateProgress(progChar, progress)
    var progMs: int = Time.get_ticks_msec() - progStart
    var progQueries: int = sql.QueryCount()
    var progTx: int = sql.TransactionCount()
    var readBack: int = sql.GetQuests(progChar).size() + sql.GetBestiaries(progChar).size() + sql.GetSkills(progChar).size()
    sql.db.delete_rows("quest", "char_id = %d" % progChar)
    sql.db.delete_rows("bestiary", "char_id = %d" % progChar)
    sql.db.delete_rows("skill", "char_id = %d" % progChar)
    sql.db.delete_rows("character", "nickname = 'BenchProgress'")
    sql.db.delete_rows("account", "username = 'bench_progress'")
    print("Progress save: %d ms, %d queries, %d tx para 150 entradas (budget: <= %d queries, <= %d tx)" % [progMs, progQueries, progTx, BudgetLogoutQueries, BudgetLogoutTransactions])
    if not progOk:
        print("FAIL: UpdateProgress devolveu false")
        failures += 1
    if readBack != 150:
        print("FAIL: upsert perdeu linha (%d de 150 lidas de volta)" % readBack)
        failures += 1
    if progQueries > BudgetLogoutQueries:
        print("FAIL: save com round trips demais")
        failures += 1
    if progTx > BudgetLogoutTransactions:
        print("FAIL: save não está numa transação única")
        failures += 1

    # ROADMAP_COMERCIAL S3: load probe real — 200 settles sequenciais no mesmo
    # char (rewind de 1h no anchor por iteração), P99 medido, gate < 200ms.
    # Substitui o print-only anterior; mede latência de transação real.
    sql.AddAccount("bench_load", "testpass", "bench_load@test.local")
    var loadAcct: int = sql.GetAccountID("bench_load")
    sql.AddCharacter(loadAcct, "BenchLoad", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var loadChar: int = sql.GetCharacterID(loadAcct, "BenchLoad")
    sql.SetCharacterFarmZone(loadChar, 1)
    var memBefore: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
    var resBefore: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
    # µs, não ms: `get_ticks_msec()` tem resolução de 1 ms e o settle fechava em
    # "1 ms" — a distribuição inteira era arredondamento. O que o gate decide é o
    # p99, e um p99 lido com resolução de 1 ms é um número inventado.
    var probeUs: Array[int] = []
    var probeErrors: int = 0
    var probeQueries: int = 0
    var slowCount: int = 0
    var slowIdx: String = ""
    sql.ResetCounters()
    for i in range(LoadProbeIters):
        sql.UpdateSettleAnchor(loadChar, int(Time.get_unix_time_from_system()) - 3600, 1.0)
        var probeStart: int = Time.get_ticks_usec()
        var probeResult: Dictionary = settleScript.SettlePending(loadChar)
        probeUs.append(Time.get_ticks_usec() - probeStart)
        if probeUs[-1] > 50000:
            slowCount += 1
            if slowCount <= 24:
                slowIdx += "%d:%dms " % [i, probeUs[-1] / 1000]
        if probeResult.is_empty():
            probeErrors += 1
    # Contador lido ainda dentro do probe: os `delete_rows` abaixo não passam pelo
    # chokepoint contado, mas ler aqui deixa o número inequívoco.
    probeQueries = sql.QueryCount()
    var probeTx: int = sql.TransactionCount()
    var memAfter: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
    var resAfter: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
    sql.db.delete_rows("character", "nickname = 'BenchLoad'")
    sql.db.delete_rows("account", "username = 'bench_load'")
    probeUs.sort()
    var p50Us: int = probeUs[LoadProbeIters / 2]
    var p99Us: int = probeUs[LoadProbeIters * 99 / 100]
    var maxUs: int = probeUs[LoadProbeIters - 1]
    print("Load probe: %d settles — p50 %d µs, p99 %d µs, max %d µs (budget p99: %d µs), erros: %d, %d queries, %d tx" % [LoadProbeIters, p50Us, p99Us, maxUs, BudgetSettleP99Ms * 1000, probeErrors, probeQueries, probeTx])
    print("Load probe hitches: %d de %d settles acima de 50 ms (budget: %d)" % [slowCount, LoadProbeIters, BudgetSlowIterPct * LoadProbeIters / 100])
    if slowIdx != "":
        print("Load probe iterações lentas: %s%s" % [slowIdx, "(truncado em 24) " if slowCount > 24 else ""])
    print("Load probe memória: %d objetos (+%d), %d recursos (+%d) no probe (budget: +%d / +%d)" % [memAfter, memAfter - memBefore, resAfter, resAfter - resBefore, BudgetObjectGrowth, BudgetResourceGrowth])
    if probeErrors > 0:
        print("FAIL: settle devolveu vazio em %d iterações" % probeErrors)
        failures += 1
    if p99Us > BudgetSettleP99Ms * 1000:
        print("FAIL: p99 do settle estourou o orçamento (%d µs > %d µs)" % [p99Us, BudgetSettleP99Ms * 1000])
        failures += 1
    # O p99 sozinho absolve um checkpoint que só aparece uma vez a cada cem
    # iterações: com 800 amostras, 1% de hitch cai exatamente no furo do p99. Esta
    # é a conta que enxerga o checkpoint, e ela é lida na taxa, não no pico.
    if slowCount * 100 > BudgetSlowIterPct * LoadProbeIters:
        print("FAIL: %d de %d settles acima de 50 ms, orçamento é %d por cento" % [slowCount, LoadProbeIters, BudgetSlowIterPct])
        failures += 1
    if memAfter - memBefore > BudgetObjectGrowth:
        print("FAIL: vazamento de objeto no loop de load")
        failures += 1
    if resAfter - resBefore > BudgetResourceGrowth:
        print("FAIL: vazamento de recurso no loop de load")
        failures += 1

    print("== Benchmarks: %d failures ==" % failures)
    quit(failures)
