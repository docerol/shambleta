extends SceneTree

# SOM-IDLE: E2E multiplayer connectivity runner
# Usage: godot --headless --path . -s tests/run_multiplayer_tests.gd

func _initialize():
	var scriptPath : String = "res://tests/MultiplayerTests.gd"
	if not FileAccess.file_exists(scriptPath):
		print("FATAL: %s not found" % scriptPath)
		quit(1)
		return
	var script : GDScript = load(scriptPath)
	var tests : RefCounted = script.new()
	var result : Dictionary = tests.RunAll()
	quit(result.get("failures", 0))
