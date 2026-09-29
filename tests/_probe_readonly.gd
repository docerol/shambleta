extends SceneTree

# SONDAS: runner descartável de SUITES DE LEITURA (nenhuma toca estado). Existe para
# conferir a régua de ponteiros em ~40s em vez dos ~20min do `idle` completo. Não é
# harness do gate: `scripts/test.sh` descobre `tests/*_test.gd` e `tests/*_fuzz.gd`, e
# este nome não cai em nenhum dos dois globs.
# Uso: stdbuf -oL -eL env XDG_DATA_HOME=... XDG_CACHE_HOME=... \
#        godot --headless --path . -s tests/_probe_readonly.gd

func _initialize():
	_run()

func _run():
	print("== probe: suites de leitura ==")
	var launcher : Node = root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		print("FATAL: Launcher ausente")
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
	load("res://sources/combat/ElementCommons.gd")
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	for i in 40:
		if dbScript.isInitialized:
			break
		await create_timer(0.25).timeout
	# As duas suítes de leitura vivem na folha da hierarquia (ver o cabeçalho de
	# `tests/IdleTestsFrontier.gd`); a instância continua sendo a mesma, então o
	# placar impresso aqui é o placar das suítes, não uma soma.
	var suitesScript : GDScript = load("res://tests/IdleTestsFrontier.gd")
	var suites : RefCounted = suitesScript.new()
	suites.SuiteEvidencePointers()
	# A régua de citação de harness entrou na sonda porque a sonda existia para não
	# se depender de 20 min de gate: em 2026-09-28 o controle de fantasma dela ficou
	# vermelho (confundia "nome citado" com "nome acusado") e só apareceu no `idle`
	# completo — o ciclo de 20 min é justamente o que impede ninguém de conferir as
	# réguas. Mesma ordem do `run_idle_tests.gd`, e nenhum estado tocado.
	suites.SuiteHarnessCitations()
	suites.SuiteExternalLinksWebBranch()
	print("== RESULT: %d checks, %d failures ==" % [suites.checks, suites.failures])
	quit(suites.failures if suites.failures > 0 else 0)
