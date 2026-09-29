extends SceneTree

# SOM-IDLE D1: pacing diagnostic — ONE real-time farm run (no time compression)
# to measure the TRUE kill rate before recalibrating the par.
# Usage: godot --headless --path . -s tests/diag_pacing.gd
# Env: SOM_DIAG_SECS (default 120), SOM_DIAG_ZONE (default 1).
# NOTE: duck-typed like run_idle_tests.gd (no class_name refs at parse time).

func _initialize():
	_run()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _run():
	print("== SOM-IDLE D1 pacing diagnostic ==")
	var launcher : Node = _getAutoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return

	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.SQL
		var worldNode : Node = launcher.World
		if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
			break

	var sql : Node = launcher.SQL
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	for i in 40:
		if dbScript.isInitialized:
			break
		await create_timer(0.25).timeout

	var secs : int = int(OS.get_environment("SOM_DIAG_SECS")) if OS.get_environment("SOM_DIAG_SECS") != "" else 120
	var zone : int = int(OS.get_environment("SOM_DIAG_ZONE")) if OS.get_environment("SOM_DIAG_ZONE") != "" else 1
	# Runs repetidos, porque uma sessão só é ruído: a mediana entre runs é o que
	# dá para comparar antes/depois de mexer na política. `SOM_DIAG_SCALE` existe
	# para o custo cair (600 s de jogo em ~30 s de parede), mas a taxa comprimida
	# NÃO é número de design: medido em 2026-09-27, o mesmo fixture L1/zona 1 deu
	# 4 kills em 600 s @20x (4/4/4/4 em quatro runs) e 4 kills em 300 s @1x. O
	# kills SATURA — o que muda entre os dois modos é só o denominador, e a
	# diferença é o stall, não a cadência. Use `SOM_DIAG_SCALE=1` para taxa do
	# produto; @20x serve para A/B entre duas versões do mesmo código.
	var runs : int = int(OS.get_environment("SOM_DIAG_RUNS")) if OS.get_environment("SOM_DIAG_RUNS") != "" else 1
	var scale : float = float(OS.get_environment("SOM_DIAG_SCALE")) if OS.get_environment("SOM_DIAG_SCALE") != "" else 1.0
	suites.SuiteZoneCatalog()
	var charID : int = suites.CreateFixture(sql, "idle_diag_account", "IdleDiagTester")
	print("diag: fixture char %d, zone %d, %ds @%sx, %d runs" % [charID, zone, secs, scale, runs])
	var rates : Array[float] = []
	for runIdx in runs:
		var snapshot : Dictionary = await suites._SimRunScaled(charID, 900 + zone + runIdx, secs, scale, zone, true)
		var rate : float = float(snapshot.get("kills_per_hour", 0.0))
		rates.append(rate)
		print("DIAG RUN %d: %.0f kills/h kills=%d secs_per_kill=%.1f casts=%d casts_per_kill=%.1f walk=%.0f" % [
			runIdx, rate, int(snapshot.get("kills", 0)),
			float(snapshot.get("secs_per_kill", 0.0)), int(snapshot.get("attacks_cast", 0)),
			float(snapshot.get("attacks_per_kill", 0.0)), float(snapshot.get("walk_distance", 0.0)),
		])
	var sorted : Array[float] = rates.duplicate()
	sorted.sort()
	var median : float = sorted[sorted.size() / 2]
	var par : int = _parOf(zone)
	print("DIAG MEDIAN: %.0f kills/h (par %d/h, %5.1f%% do par) runs=%s" % [
		median, par, 100.0 * median / maxf(1.0, float(par)), str(rates)])
	sql.db.delete_rows("character", "nickname = 'IdleDiagTester'")
	sql.db.delete_rows("account", "username = 'idle_diag_account'")
	quit(0)

# O par é lido do próprio catálogo de zonas — a régua não pode ser um número
# digitado aqui, senão o design muda e o diagnóstico continua elogiando o velho.
func _parOf(zone : int) -> int:
	var farmZone : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var data : Object = farmZone.call("GetZone", zone)
	return int(data.parKillsPerHour) if data != null else 0
