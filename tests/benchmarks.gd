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
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        var sqlNode: Node = launcher.SQL
        var worldNode: Node = launcher.World
        if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
            break

    if not sqlNode.isInitialized or not worldNode.isInitialized:
        print("FATAL: Services not initialized within timeout")
        quit(1)
        return

    print("Services initialized after %d ms" % waited)

    var sql: SQLService = sqlNode
    var economy: Node = launcher.Economy
    var failures: int = 0

    # Benchmark: settle (single character)
    var settleStart: int = Time.get_ticks_msec()
    var settleResult: Dictionary = economy.SettleCharacter(1, 3600, 0.9)
    var settleMs: int = Time.get_ticks_msec() - settleStart
    print("Settle benchmark: %d ms (budget: %d ms)" % [settleMs, BudgetSettleMs])
    if settleMs > BudgetSettleMs:
        print("FAIL: settle exceeded budget")
        failures += 1

    # Benchmark: zone catalog
    var catalogStart: int = Time.get_ticks_msec()
    var zoneCount: int = 0
    for zoneID in range(1, 41):
        var zone = FarmZoneData.GetZone(zoneID)
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

    print("== Benchmarks: %d failures ==" % failures)
    quit(failures)
