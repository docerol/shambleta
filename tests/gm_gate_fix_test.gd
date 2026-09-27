extends SceneTree

# Gate de permissão do CommandManager: o bypass por `OS.is_debug_build()` foi
# removido — um export acidental de debug dava a qualquer jogador os comandos
# de ADMIN (`/setstat gp`, `/ban`, `/permission`). Este runner fixa a nova
# régua no fonte vivo e no comportamento da env opt-in.
#
# Uso: godot --headless --path . -s tests/gm_gate_fix_test.gd
# Exit code: número de checks falhos.

const SOURCE_PATH := "res://sources/debug/CommandManager.gd"

var checks : int = 0
var failures : int = 0

func Check(cond : bool, label : String) -> void:
	checks += 1
	if cond:
		print("PASS · " + label)
	else:
		failures += 1
		print("FAIL · " + label)

func _init() -> void:
	var f : FileAccess = FileAccess.open(SOURCE_PATH, FileAccess.READ)
	if not f:
		print("FAIL · fonte do CommandManager ilegível")
		print("== RESULT: 1 checks, 1 failures ==")
		quit(1)
		return
	var src : String = f.get_as_text()
	f.close()

	# 1) O bypass de build não pode voltar em nenhum teste de permissão.
	var bypasses : Array = []
	for line in src.split("\n"):
		var t : String = line.strip_edges()
		if t.begins_with("#"):
			continue
		if t.contains("is_debug_build") and t.contains("command._permission"):
			bypasses.append(t)
	Check(bypasses.is_empty(),
		"permissão de comando nunca é condicionada a is_debug_build (%d achados)" % bypasses.size())

	# 2) A gate viva é a env opt-in explícita.
	Check(src.contains("not GMModeEnabled() and command._permission"),
		"gate de permissão usa GMModeEnabled() (opt-in por operador)")

	# 3) A única alavanca é a env nomeada, lida por OS.get_environment — varrida
	#    no fonte porque `-s` não resolve autoloads e CommandManager referencia
	#    Network/Peers (compilar aqui seria falso positivo do modo, não prova).
	Check(src.contains("func GMModeEnabled()"), "GMModeEnabled() existe como a régua de gate")
	Check(src.contains('OS.get_environment(GM_MODE_ENV)'),
		"GM mode lê a env declarada, sem outro caminho de ativação")
	Check(src.contains('const GM_MODE_ENV : String = "SHAMBLETA_GM_MODE"'),
		"a env é nomeada por constante (não dedada no meio da lógica)")
	var setters : int = src.count("set_environment")
	Check(setters == 0, "o próprio módulo não escreve a env que o libera (%d)" % setters)

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)
