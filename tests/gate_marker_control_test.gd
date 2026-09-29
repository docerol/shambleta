extends SceneTree

# gate-marker: == Marker Probe:
#
# CONTROLE PLANTADO do finding #81 (scripts/check_gate_markers.sh o lê e o confere;
# apagar este arquivo ou estas três linhas é o estado vermelho que a régua caça).
#
# Este harness existe para provar três coisas que nenhum outro harness prova, e as
# três são a classe do defeito #81:
#   (a) marcador MIXED-CASE funciona. A regex antiga (`"== [A-Z]+[A-Z ]*:`) não via
#       `== Marker Probe:` e cobrava `== RESULT:` — um harness perfeito virava
#       GATE VERMELHO com `godot exit=0` e o veredito impresso no log.
#   (b) o marcador NÃO vem da posição no arquivo. Abaixo há um banner em caixa alta
#       e ANTERIOR (`== DECOY BANNER: …==`) — a regex antiga, que pegava a primeira
#       `== [A-Z]+[A-Z ]*:`, escolheria esse banner como marcador. A derivadora nova
#       só admite linha com contagem de falha, então ordem de fonte não decide; era
#       assim que `reason_toast_test.gd` passava por acidente textual.
#   (c) a DECLARAÇÃO manda, e o que ela declara é conferido contra o arquivo:
#       trocar `== Marker Probe:` por qualquer outro texto deixa R1 vermelha antes
#       mesmo de ligar o Godot, e o `one` cobraria marcador que nenhuma linha de
#       resultado imprime.
#
# Rodar: bash scripts/test.sh one gate_marker_control_test

var checks : int = 0
var failures : int = 0

func Check(ok : bool, label : String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		print("  [FAIL] " + label)
	return ok

func _initialize() -> void:
	# Banner ANTES da linha de resultado de propósito, e em CAIXA ALTA: a regex do
	# defeito #81 (`"== [A-Z]+[A-Z ]*:` + primeira aparição) escolhia ESTE texto
	# como marcador porque ele vem antes na fonte — é o acidente de
	# `reason_toast_test.gd`, onde mover `_finish` de lugar trocava o marcador
	# cobrado. A derivadora nova só admite linha com contagem de falha, então banner
	# não concorre, em nenhuma ordem de arquivo.
	print("== DECOY BANNER: apenas um título, não é linha de resultado ==")
	Check(true, "o machinery do portão me descobriu e me rodou")
	Check(harnessSeesItself(), "scripts/test.sh tem o contrato de marcador documentado (R5)")
	# A linha de resultado é a única com contagem de falha. (a) e (b) acima.
	print("== Marker Probe: %d checks, %d failures ==" % [checks, failures])
	# Esta nota menciona falha sem contagem alguma — se a derivadora contar por
	# palavra solta, ela vira o "veredito" do arquivo e o gate cobra um marcador que
	# ninguém imprime. O achado #81 é exatamente essa confusão entre banner e
	# veredito, então ela fica aqui plantada como ruído ativo.
	print("  nota: nenhum check deveria falhar aqui, e falhar é o que este arquivo reporta")
	quit(failures)

func harnessSeesItself() -> bool:
	var f : FileAccess = FileAccess.open("res://scripts/test.sh", FileAccess.READ)
	if f == null:
		return false
	var txt : String = f.get_as_text()
	return txt.contains("# gate-marker:") and txt.contains("== RESULT:")
