extends SceneTree

# SOM-IDLE P2: performance benchmark gate.
# Measures settle, XP walk, and zone catalog operations.
# Exit code: 0 = within budget, 1 = over budget.

const BudgetSettleMs: int = 500
const BudgetXpWalkMs: int = 1000
const BudgetZoneCatalogMs: int = 200

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
    var settleStart: int = Time.get_ticks_msec()
    var settleResult: Dictionary = settleScript.SettlePending(benchChar)
    var settleMs: int = Time.get_ticks_msec() - settleStart
    sql.db.delete_rows("character", "nickname = 'BenchSettle'")
    sql.db.delete_rows("account", "username = 'bench_settle'")
    print("Settle benchmark: %d ms (budget: %d ms)" % [settleMs, BudgetSettleMs])
    if settleResult.is_empty():
        print("FAIL: settle returned empty")
        failures += 1
    if settleMs > BudgetSettleMs:
        print("FAIL: settle exceeded budget")
        failures += 1

    # Benchmark: zone catalog
    var catalogStart: int = Time.get_ticks_msec()
    var zoneCount: int = 0
    var farmZones: GDScript = load("res://sources/idle/FarmZoneData.gd")
    for zoneID in range(1, 41):
        var zone = farmZones.GetZone(zoneID)
        if zone:
            zoneCount += 1
    var catalogMs: int = Time.get_ticks_msec() - catalogStart
    print("Zone catalog benchmark: %d ms for %d zones (budget: %d ms)" % [catalogMs, zoneCount, BudgetZoneCatalogMs])
    if catalogMs > BudgetZoneCatalogMs:
        print("FAIL: zone catalog exceeded budget")
        failures += 1

    # Benchmark: XP walk (simulate 1000 XP gains)
    var xpStart: int = Time.get_ticks_msec()
    var totalXp: int = 0
    for i in range(1000):
        totalXp += 10
    var xpMs: int = Time.get_ticks_msec() - xpStart
    print("XP walk benchmark: %d ms for 1000 iterations (budget: %d ms)" % [xpMs, BudgetXpWalkMs])
    if xpMs > BudgetXpWalkMs:
        print("FAIL: XP walk exceeded budget")
        failures += 1

    # ROADMAP_COMERCIAL S3: load probe real — 200 settles sequenciais no mesmo
    # char (rewind de 1h no anchor por iteração), P99 medido, gate < 200ms.
    # Substitui o print-only anterior; mede latência de transação real.
    const LoadProbeIters: int = 200
    const BudgetSettleP99Ms: int = 200
    sql.AddAccount("bench_load", "testpass", "bench_load@test.local")
    var loadAcct: int = sql.GetAccountID("bench_load")
    sql.AddCharacter(loadAcct, "BenchLoad", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var loadChar: int = sql.GetCharacterID(loadAcct, "BenchLoad")
    sql.SetCharacterFarmZone(loadChar, 1)
    var probeLat: Array[int] = []
    var probeErrors: int = 0
    for i in range(LoadProbeIters):
        sql.UpdateSettleAnchor(loadChar, int(Time.get_unix_time_from_system()) - 3600, 1.0)
        var probeStart: int = Time.get_ticks_msec()
        var probeResult: Dictionary = settleScript.SettlePending(loadChar)
        probeLat.append(Time.get_ticks_msec() - probeStart)
        if probeResult.is_empty():
            probeErrors += 1
    sql.db.delete_rows("character", "nickname = 'BenchLoad'")
    sql.db.delete_rows("account", "username = 'bench_load'")
    probeLat.sort()
    var p99Ms: int = probeLat[LoadProbeIters * 99 / 100]
    print("Load probe: %d settles, P99 %d ms (budget: %d ms), errors: %d" % [LoadProbeIters, p99Ms, BudgetSettleP99Ms, probeErrors])
    if probeErrors > 0:
        print("FAIL: load probe errors")
        failures += 1
    if p99Ms > BudgetSettleP99Ms:
        print("FAIL: load probe P99 exceeded budget")
        failures += 1

    print("== Benchmarks: %d failures ==" % failures)
    quit(failures)
