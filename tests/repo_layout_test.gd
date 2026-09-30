extends SceneTree

# repo_layout_test.gd — dono: forma do repo (Código, auditoria 2026-09-27).
#
# Três coisas que nenhum outro gate deste repo mede:
#
#  A) A RAIZ. Havia três sondas de 3-5 linhas rastreadas na raiz
#     (`test_classdb.gd`, `test_load.gd`, `test_service_base.gd`). Elas não eram
#     só mortas: eram FALSAS. `extends Node` + `_ready()` num script rodado com
#     `-s` não dispara `_ready` de nada (o main loop é o SceneTree), não imprimia
#     marcador `== ...:` e não chamava `quit()` — o `harness_marker()` do
#     `scripts/test.sh` cairia no default e o §24-8 não teria o que ler. E o que
#     a primeira aferia estava errado: `ClassDB.class_exists("ServiceBase")`
#     devolve FALSE em run headless `-s` (confirmei: 182 classes GDScript vivem em
#     `ProjectSettings.get_global_class_list()`, não no ClassDB nativo). A suíte B
#     daqui refaz os três fatos com a régua certa e passa a cobrá-los.
#  C) PORTÃO SEM CHAMADOR. A razão pela qual
#     `check_secrets.sh` (`scripts/test.sh:579-585`) entrou na lista diz exatamente
#     isto: um gate não chamado é régua sem efeito — e foi isso que aconteceu com
#     `check_doc_drift.sh` e `check_compose.sh` (42 checks verdes, zero chamadores).
#     Esta suíte torna a frase verificável nos dois sentidos: todo `scripts/*.sh` e
#     todo `tests/*.gd` tem de ser alcançável por um de três caminhos DECLARADOS
#     (glob de descoberta, chamada nominal no runner/CI, ferramenta de mão com
#     receita escrita), e nenhuma entrada do runner pode apontar para arquivo que
#     não existe.
#  D) A CERA DOS 800. `check_god_nodes.sh` hoje tem ratchet por arquivo (teto
#     nomeado + folga máxima). Faltava a outra borda: um arquivo PARA em exatamente
#     `MAX_LINES` e o gate mede "> teto", então 800/800 passa e não diz nada —
#     é onde `Gui.gd` e `EconomyService.gd` estão agora. Esta suíte (i) confere o
#     ratchet do gate por fora, com os números do run, e (ii) exige motivo escrito
#     para quem encosta na cerca por baixo. Não refatorei nada: a regra da casa é
#     "sem reescrita sem benefício mensurável".
#
# Escopo declarado (e por quê): A e C medem a ÁRVORE DE TRABALHO, que é onde um
# scratch se esconde. D mede o que o índice registra (`git ls-files --cached`),
# porque um arquivo ainda não rastreado é obra em curso de outro agente e o dono
# daquele número é o `check_god_nodes.sh` — o que passa aqui é NOTADO em voz alta,
# não silenciado. `check_secrets.sh` cobre o estado inverso (apagado sem `git rm`).
#
# Pré-condição minha, e ela tem rótulo: as contagens acima só valem se o git
# respondeu. O job em `container:` da CI já devolveu "0 arquivos" porque o
# workspace pertence ao uid do runner e o processo fala como outro uid — o git
# fecha o índice nesse caso, e a régua que conta sem perguntar acusa o repositório
# pelo ambiente. Por isso `_git()` retém rc e stderr, `_gitWhy()` nomeia a causa e
# `_gitBlame()` pendura o motivo em todo rótulo que conta arquivos lidos do índice,
# inclusive nos que passariam por vacuidade (`moved`, `over`, `undeclared`). A
# acusação continua de pé: índice ilegível é FAIL, nunca verde silencioso — o que
# mudou é que agora o log diz qual das três causas o produziu.
#
# Uso:
#   XDG_DATA_HOME=/tmp/impl-sec/.data XDG_CACHE_HOME=/tmp/impl-sec/.cache \
#     timeout 300 godot --headless --path . -s tests/repo_layout_test.gd
# Saída: "== RESULT: <n> checks, <m> failures ==" (exit code = <m>).

var checks : int = 0
var failures : int = 0
var suitesDone : int = 0
var _gitSeq : int = 0
# O índice do git é a matéria-prima de A e D. Quando ele não vem, três causas
# diferentes (git ausente, git recusando o dono do diretório, repo sem índice)
# despejam o mesmo "0 arquivos" no log — aqui mora a causa que o rótulo passa a
# carregar, lida do rc e do stderr do git, não da minha hipótese.
var _gitRc : int = -1
var _gitErr : String = ""
var _indexDiag : String = ""

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	var same : bool = typeof(got) == typeof(want) and got == want
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (got " + str(got) + ", want " + str(want) + ")")
		return false
	print("  [ok] " + label)
	return true

func Note(text : String) -> void:
	print("       " + text)

func _initialize() -> void:
	_run()

# --- util -------------------------------------------------------------------

func _read(path : String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var body : String = f.get_as_text()
	f.close()
	return body

func _repoRoot() -> String:
	var p : String = ProjectSettings.globalize_path("res://")
	if p.ends_with("/"):
		p = p.substr(0, p.length() - 1)
	return p

# Saída de git para um arquivo temporário e lê o arquivo: neste build o stdout de
# `OS.execute` não volta no array de saída, então o veredicto viaja por arquivo.
# O stderr viaja por ARQUIVO PRÓPRIO e o código de saída é retido: até aqui o
# `2>/dev/null || true` apagava a recusa do git e deixava no log um "0 arquivos"
# que parecia acusação ao repositório sendo acusação ao ambiente.
func _git(args : String) -> PackedStringArray:
	_gitSeq += 1
	var tmp : String = OS.get_temp_dir().path_join("shambleta-layout-%d-%d.txt" % [Time.get_ticks_msec(), _gitSeq])
	var errPath : String = tmp + ".err"
	_gitRc = OS.execute("sh", ["-c", "cd '%s' && git %s > '%s' 2> '%s'" % [_repoRoot(), args, tmp, errPath]])
	_gitErr = _oneLine(_read(errPath), 200)
	DirAccess.remove_absolute(errPath)
	var out : PackedStringArray = PackedStringArray()
	var body : String = _read(tmp)
	DirAccess.remove_absolute(tmp)
	if body.strip_edges() != "":
		for l in body.split("\n", false):
			if l != "":
				out.append(l)
	if args.begins_with("ls-files"):
		# Sticky só enquanto a leitura do índice estiver ruim; a primeira leitura boa
		# limpa a acusação, senão um glitch antigo continuaria pendurado em rótulo.
		_indexDiag = "" if (_gitRc == 0 and out.size() > 0) else _gitWhy()
	return out

# stderr em uma linha só: rótulo de veredito é lido em coluna, e o que quebra
# linha em meio a um `[FAIL]` some do resumo que o runner faz das falhas.
func _oneLine(text : String, maxLen : int) -> String:
	var flat : String = text.replace("\r", " ").replace("\n", " | ").replace("\t", " ")
	while flat.contains("  "):
		flat = flat.replace("  ", " ")
	flat = flat.strip_edges()
	if flat.length() > maxLen:
		return flat.substr(0, maxLen) + "…"
	return flat

# Qual das causas o git realmente confessou. Nomes dos sintomas vêm do texto dele.
func _gitWhy() -> String:
	if _gitRc == 127:
		return "git não é um programa deste ambiente (rc=127 = não encontrado); stderr: %s" % (_gitErr if _gitErr != "" else "(vazio)")
	if _gitRc == -1:
		return "git nem foi chamado direito (rc=-1)"
	if _gitErr.contains("dubious ownership"):
		return "git RECUSOU ler este diretório: rc=%d, %s (é o uid do runner contra o uid do processo no container; cura: `git config --global --add safe.directory <workspace>)" % [_gitRc, _gitErr]
	if _gitErr.contains("not a git repository"):
		return "%s não é um repositório git (rc=%d): %s" % [_repoRoot(), _gitRc, _gitErr]
	if _gitRc != 0:
		return "git respondeu rc=%d com saída vazia: %s" % [_gitRc, (_gitErr if _gitErr != "" else "(sem stderr)")]
	return "git respondeu rc=0 e índice VAZIO mesmo assim — repo sem nada rastreado (rc=0, stderr: %s)" % (_gitErr if _gitErr != "" else "(vazio)")

# Sufixo de rótulo: vazio quando o índice foi lido, nomeado quando não foi. Toda
# régua que conta arquivos do índice passa a dizer com que autoridade conta.
func _gitBlame() -> String:
	if _indexDiag == "":
		return ""
	return " || ÍNDICE NÃO LIDO — " + _indexDiag

# Lista de um diretório da árvore: arquivos, ou subdiretórios (`wantDirs`).
func _list(dir : String, wantDirs : bool) -> Array:
	var out : Array = []
	var d : DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n : String = d.get_next()
	while n != "":
		if n != "." and n != ".." and d.current_is_dir() == wantDirs:
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	return out

func _join(dir : String, name : String) -> String:
	if dir.ends_with("/"):
		return dir + name
	return dir + "/" + name

func _walk(dir : String, exts : PackedStringArray, out : Array) -> void:
	for f in _list(dir, false):
		if exts.has(str(f).get_extension()):
			out.append(_join(dir, str(f)))
	for sub in _list(dir, true):
		_walk(_join(dir, str(sub)), exts, out)

func _countLines(path : String) -> int:
	# `wc -l` conta `\n`: mesma régua do check_god_nodes.sh, senão as duas réguas
	# divergem em todo arquivo sem nova linha final.
	return _read(path).count("\n")

func _between(hay : String, left : String, right : String) -> String:
	var a : int = hay.find(left)
	if a < 0:
		return ""
	var b : int = hay.find(right, a + left.length())
	if b < 0:
		return ""
	return hay.substr(a + left.length(), b - (a + left.length()))

func _regexInt(hay : String, name : String) -> int:
	# `(^|[^A-Za-z_])` importa: sem ele, ler `MAX_LINES` apanharia
	# `TESTS_MAX_LINES=9000` e as duas réguas do gate se misturariam aqui também.
	var re : RegEx = RegEx.create_from_string("(^|[^A-Za-z_])" + name + "[[:space:]]*=[[:space:]]*([0-9]+)")
	if re == null:
		return 0
	var m : RegExMatch = re.search(hay)
	return int(m.get_string(2)) if m != null else 0

# Concatena o texto de tudo que está no índice sob estes prefixos — o corpus onde
# um nome pode ser citado. Arquivos do índice que não existem mais na árvore são
# pulados (o `_read` já devolve "" para eles).
func _corpus(prefixes : Array, suffixes : PackedStringArray) -> String:
	var out : String = ""
	for p in _git("ls-files --cached"):
		var under : bool = false
		for pref in prefixes:
			if str(p).begins_with(str(pref)):
				under = true
				break
		if not under:
			continue
		if suffixes.size() > 0 and not suffixes.has(str(p).get_extension()):
			continue
		out += _read(_join(_repoRoot(), str(p))) + "\n"
	return out

# --- A) raiz ----------------------------------------------------------------

const PROBES : Array = ["test_classdb.gd", "test_load.gd", "test_service_base.gd"]

func _suiteRoot() -> void:
	print("-- A) a raiz do repo não é depósito de scratch")
	var rootFiles : Array = _list("res://", false)
	var loose : Array = []
	var looseUid : Array = []
	var looseSh : Array = []
	for f in rootFiles:
		var name : String = str(f)
		if name.get_extension() == "gd":
			loose.append(name)
		elif name.ends_with(".gd.uid"):
			looseUid.append(name)
		elif name.get_extension() == "sh":
			looseSh.append(name)
	CheckEq(loose.size(), 0, "zero .gd soltos na raiz (achado: %s)" % ", ".join(PackedStringArray(loose)))
	CheckEq(looseUid.size(), 0, "zero .gd.uid órfãos na raiz (achado: %s)" % ", ".join(PackedStringArray(looseUid)))
	CheckEq(looseSh.size(), 0, "zero .sh de uso único na raiz (achado: %s)" % ", ".join(PackedStringArray(looseSh)))
	var present : int = 0
	for p in PROBES:
		if rootFiles.has(p):
			present += 1
	CheckEq(present, 0, "as três sondas não voltaram para a raiz")
	# O índice: apagou na árvore mas não preparou a exclusão, `git ls-files` ainda
	# lista. Não posso rodar `git rm --cached` (regra da rodada), então o fato sai
	# em voz alta com o comando que falta. A régua tem dente na direção que importa:
	# nenhum .gd rastreado E vivo na raiz — uma sonda nova (ou uma velha que
	# voltou) cai aqui.
	var rootGdInIndex : Array = []
	var indexSize : int = 0
	for p in _git("ls-files --cached"):
		indexSize += 1
		var rel : String = str(p)
		if not rel.contains("/") and rel.get_extension() == "gd":
			rootGdInIndex.append(rel)
	Check(indexSize > 200, "git ls-files respondeu (%d arquivos no índice; zero aqui = git indisponível e A/D viram escuridão, não verde)%s" % [indexSize, _gitBlame()])
	var stillTracked : Array = []
	var stale : Array = []
	for p in rootGdInIndex:
		if rootFiles.has(p):
			stillTracked.append(p)
		else:
			stale.append(p)
	CheckEq(stillTracked.size(), 0, "nenhum .gd rastreado E presente na raiz (achado: %s)%s" % [", ".join(PackedStringArray(stillTracked)), _gitBlame()])
	if stale.size() > 0:
		Note("fora da árvore, ainda no índice até o commit: %s (fica com quem commita: `git rm --cached %s`)" % [", ".join(PackedStringArray(stale)), str(stale[0])])
	var pj : String = _read("res://project.godot")
	Check(pj.length() > 1000, "project.godot lido (%d bytes)" % pj.length())
	var dangling : int = 0
	for p in PROBES:
		if pj.contains(str(p)):
			dangling += 1
	CheckEq(dangling, 0, "project.godot não referencia nenhuma das três sondas removidas")
	suitesDone += 1

# --- B) os fatos das sondas, na régua que devolve a resposta certa ----------

func _globalClassPath(className : String) -> String:
	for e in ProjectSettings.get_global_class_list():
		if str(e["class"]) == className:
			return str(e["path"])
	return ""

func _suiteProbeFacts() -> void:
	print("-- B) o que as três sondas aferiam, agora com a régua verdadeira")
	# O erro que a suíte denuncia: em `-s` o ClassDB não vê class_name de GDScript.
	Note("ClassDB.class_exists(\"ServiceBase\") = %s neste modo de run (por isso o test_classdb.gd não provava nada)" % str(ClassDB.class_exists("ServiceBase")))
	Check(_globalClassPath("ServiceBase") == "res://sources/system/ServiceBase.gd", "a classe global ServiceBase está registrada no caminho certo (o fato que a sonda procurava)")
	Check(_globalClassPath("Hasher") == "res://sources/util/Hasher.gd", "a classe global Hasher está registrada (cache de class_name em dia — é o que o ensure_class_cache() garante)")
	var sb : Variant = load("res://sources/system/ServiceBase.gd")
	Check(sb is GDScript, "res://sources/system/ServiceBase.gd carrega como GDScript")
	if sb is GDScript:
		Check((sb as GDScript).get_instance_base_type() == "Node", "ServiceBase desce de Node (o `extends ServiceBase` do test_service_base.gd compila)")
		var inst : Object = (sb as GDScript).new()
		Check(inst != null and inst is Node, "ServiceBase.new() é um Node de verdade")
		if inst != null:
			Check(str(inst.get("isInitialized")) == "false", "serviço recém-instanciado ainda não se inicializou")
			inst.free()
	var client : Variant = load("res://sources/network/client/Client.gd")
	Check(client is Script, "load(client) devolve Script, não null (o `typeof == SCRIPT` do test_load.gd)")
	if client is Script:
		Check(str((client as Script).resource_path) != "", "o Script carrega o próprio resource_path")
		Check((client as Script).can_instantiate(), "Client.gd é instanciável (não virou abstract no meio do caminho)")
	# E o fato estrutural que nenhuma das três tinha: um harness precisa ser
	# SceneTree para rodar com `-s`. As sondas eram `extends Node`, ou seja: nunca
	# rodaram em lugar nenhum — e "mudar de pasta" não conserta isso.
	var moved : Array = []
	for p in _git("ls-files --cached --others --exclude-standard"):
		var rel : String = str(p)
		if PROBES.has(rel.get_file()) and FileAccess.file_exists(_join(_repoRoot(), rel)):
			moved.append(rel)
	CheckEq(moved.size(), 0, "nenhuma das três sondas foi apenas MOVIDA de pasta (ainda existe em: %s)%s" % [", ".join(PackedStringArray(moved)), _gitBlame()])
	suitesDone += 1

# --- C) portão sem chamador -------------------------------------------------

func _suiteReachability() -> void:
	print("-- C) nem gate, nem harness podem morar aqui sem quem os chame")
	var runner : String = _read("res://scripts/test.sh")
	Check(runner.contains("structure_gates() {"), "scripts/test.sh define structure_gates() — a porta única dos gates de estrutura")
	var ci : String = _corpus([".github/"], PackedStringArray())
	var machine : String = runner + ci + _corpus(["tests/"], PackedStringArray(["gd"])) \
		+ _read("res://deploy/web/Dockerfile") + _read("res://deploy/api/Dockerfile")
	var manual : String = _corpus(["docs/"], PackedStringArray(["md"])) + _corpus(["deploy/"], PackedStringArray(["md"])) \
		+ _read("res://README.md") + _read("res://ROADMAP_COMERCIAL.md")
	Check(ci.contains("scripts/test.sh structure"), "a CI chama `scripts/test.sh structure` — a mesma porta do `all` local, sem divergir (corpus lido do índice: %d chars)%s" % [ci.length(), _gitBlame()])

	var orphans : int = 0
	var called : int = 0
	var byHand : Array = []
	for f in _list("res://scripts", false):
		var name : String = str(f)
		if name.get_extension() != "sh" or name == "test.sh":
			continue
		if machine.contains(name):
			called += 1
		elif manual.contains(name):
			byHand.append(name)
		else:
			orphans += 1
			print("  [FAIL] gate sem chamador: scripts/%s" % name)
	CheckEq(orphans, 0, "todo scripts/*.sh é chamado por máquina ou por receita documentada (o corpus onde procurei o chamador saiu do índice)%s" % _gitBlame())
	Note("scripts citados só em doc (ferramenta de mão, não gate): %s" % ", ".join(PackedStringArray(byHand)))
	Check(called >= 4, "%d scripts invocados por test.sh/CI/harness (check_secrets.sh conta entre eles)" % called)
	Check(runner.contains("check_secrets.sh") and runner.contains("SECRETS GATE"), "o gate de segredo está ligado em structure_gates(), não só escrito")

	# Harnesses: descoberta por glob, chamada nominal, ou ferramenta de mão.
	var discovered : int = 0
	var stranded : int = 0
	var manualTools : Array = []
	var noMarker : Array = []
	for f in _list("res://tests", false):
		var name : String = str(f)
		if name.get_extension() != "gd":
			continue
		var stem : String = name.get_basename()
		var src : String = _read(_join("res://tests", name))
		if stem.ends_with("_test") or stem.ends_with("_fuzz"):
			discovered += 1
			var re : RegEx = RegEx.create_from_string("\"== [A-Z]+[A-Z ]*:")
			# Mesmo filtro do `harness_marker()`: só conta marcador que o runner
			# conseguiria achar, e ele é obrigatório porque o §24-8 LÊ o número da
			# linha — harness mudo é gate que nunca rodou passando por verde.
			if re == null or re.search(src) == null:
				noMarker.append(stem)
			continue
		if runner.contains(stem):
			continue
		var recipe : RegEx = RegEx.create_from_string("-s tests/" + stem + "\\.gd")
		if (recipe != null and recipe.search(machine) != null) or manual.contains(stem):
			manualTools.append(stem)
			continue
		stranded += 1
		print("  [FAIL] tests/%s não é descoberto, não é chamado e não tem receita escrita" % name)
	CheckEq(noMarker.size(), 0, "todo harness descoberto por glob imprime marcador de resultado: %s" % ", ".join(PackedStringArray(noMarker)))
	CheckEq(stranded, 0, "nenhum tests/*.gd morto (sem glob, sem chamada, sem receita)%s" % _gitBlame())
	Check(discovered >= 25, "%d harnesses cobertos pelo glob de descoberta de `all`" % discovered)
	Note("ferramentas de mão declaradas (não rodam no gate): %s" % ", ".join(PackedStringArray(manualTools)))
	# Todo harness SceneTree tem de terminar sozinho: sem `quit()` o `-s` fica com
	# o processo vivo e o gate vira timeout de 300 s, não veredito.
	var noQuit : Array = []
	for f in _list("res://tests", false):
		var name : String = str(f)
		if name.get_extension() != "gd":
			continue
		var stem : String = name.get_basename()
		if not (stem.ends_with("_test") or stem.ends_with("_fuzz")):
			continue
		var src : String = _read(_join("res://tests", name))
		if not src.contains("quit("):
			noQuit.append(stem)
	CheckEq(noQuit.size(), 0, "todo harness descoberto chama quit() (sem isso o gate espera o timeout): %s" % ", ".join(PackedStringArray(noQuit)))
	# A outra direção: entrada de runner sem arquivo é a mesma doença de um gate
	# sem chamador, só que escondida dentro do whitelist.
	var explicit : String = _between(runner, "EXPLICIT_HARNESSES=\"", "\"")
	Check(explicit.length() > 20, "EXPLICIT_HARNESSES lido do próprio runner (%d chars)" % explicit.length())
	var testFiles : Array = _list("res://tests", false)
	var ghosts : int = 0
	for entry in explicit.split(" ", false):
		if not testFiles.has(str(entry) + ".gd"):
			ghosts += 1
			print("  [FAIL] EXPLICIT_HARNESSES cita tests/%s.gd, que não existe" % entry)
	CheckEq(ghosts, 0, "nenhuma entrada de EXPLICIT_HARNESSES aponta para harness inexistente")
	# Os gates de estrutura, na função e não duplicados fora dela. A régua é pelos
	# NOMES nos dois sentidos: só contar deixava o vermelho mudo — quando
	# check_ci.sh entrou no runner, o que se lia era "got 5, want 4" sem dizer o
	# quinto, e quem conserta adivinha.
	var sg : String = _fnBody(runner, "structure_gates")
	var gates : Array = ["check_god_nodes.sh", "check_doc_drift.sh", "check_compose.sh", "check_secrets.sh", "check_ci.sh", "check_dead_code.sh", "check_untracked.sh", "check_gate_log.sh", "check_boot_sandbox.sh", "check_gate_markers.sh", "check_write_funnel.sh"]
	var calledGates : Array = []
	for g in gates:
		if not sg.contains(g):
			print("  [FAIL] structure_gates() não chama %s — gate existe em scripts/ e ninguém roda" % g)
	var strays : Array = []
	for token in sg.split("\n", false):
		var t : String = str(token).strip_edges()
		# Só a linha de registro é prova de que o gate roda. O corpo tem a prosa que
		# explica por que cada gate entrou, e essa prosa cita nomes de script: varrer
		# comentário como se fosse chamada inventa gate — foi assim que `ci_gate_log.sh`, o
		# LEITOR do veredito, saiu desta régua listado como se fosse um gate.
		if t.is_empty() or t.begins_with("#"):
			continue
		if not t.begins_with("gate_sh") and not t.ends_with("{"):
			strays.append(t)
		var script : String = _between(t + " ", "scripts/", ".sh")
		if not script.is_empty() and not calledGates.has(script + ".sh"):
			calledGates.append(script + ".sh")
	for found in calledGates:
		if not gates.has(found):
			print("  [FAIL] structure_gates() chama %s, que não está na lista declarada deste harness" % found)
	CheckEq(calledGates.size(), gates.size(), "structure_gates() chama exatamente os %d gates declarados (medido: %d — %s)" % [gates.size(), calledGates.size(), ", ".join(PackedStringArray(calledGates))])
	# Toda linha de código do corpo é uma chamada gate_sh. O teto antigo media TEXTO
	# e acusava quem escrevia o motivo dentro da função — exatamente o que a casa pede
	# — enquanto deixava passar uma segunda forma de ligar gate. Aqui a FORMA é
	# vigiada pelo nome, e o cabeçalho `nome() {` fica fora porque não é trabalho.
	# Régua que pune prosa e perdoa duplicação é o inverso do que se quer.
	CheckEq(strays.size(), 0, "structure_gates(): toda linha de código é uma chamada gate_sh (%d fora da forma: %s — gate novo se liga aqui, não duplicando o laço)" % [strays.size(), ", ".join(PackedStringArray(strays))])
	suitesDone += 1

func _fnBody(source : String, fnName : String) -> String:
	# Bash: `nome() {` ... `}` na coluna zero. Aceito `func` no caminho para o
	# mesmo helper servir a outro formato sem mentir sobre o que não achou.
	var out : String = ""
	var seen : bool = false
	for l in source.split("\n", false):
		var line : String = str(l)
		var t : String = line.strip_edges()
		if not seen:
			if t.begins_with(fnName + "()") or t.begins_with("func " + fnName):
				seen = true
				out += line + "\n"
			continue
		if t == "}":
			break
		out += line + "\n"
	return out

# --- D) a cerca dos 800 -----------------------------------------------------

# Arquivos hoje encostados no teto (>=98% e <=100%), com o motivo. A regra é esta
# lista existir: quem encosta escreve porquê, um TERCEIRO na cerca só passa depois
# de entrada nova com motivo, e entrada que apodrece (arquivo saiu da banda) é
# FAIL. Sem refatoração estética nesta rodada (decisão de escopo, não de gosto).
#
# 2026-09-27, rodada do fatiamento do `Gui`: a entrada de `sources/gui/Gui.gd`
# (800/800) saiu daqui porque o arquivo saiu da banda — 608 linhas em seis módulos
# irmãos (`GuiStateScreens`, `GuiCharacterHub`, `GuiNoticeRules`, `GuiHudTargets`,
# `GuiSandboxFlows`, `GuiUiScale`). `MAX_LINES` não foi tocado: o teto continua
# 800, e a lista vazia é o estado verde que esta suíte cobra de quem fatiou
# (motivo velho é allowlist podre).
# Quem encosta na banda [98%, 100%] do teto do `check_god_nodes.sh` precisa de
# motivo REGISTRADO AQUI, junto da entrada — a banda não é punição, é o sinal de
# que o arquivo está a uma onda do estouro e alguém precisa dizer por que ainda é
# ele o lugar certo. O teto continua sendo o do gate (800): esta lista não compra
# cheque em branco, compra explicação.
const NEAR_FENCE : Array = [
	{
		"path": "sources/economy/EconomyService.gd",
		"reason": "odres/estagios de 2026-09-28-29 (#96-#104): o ciclo de temporada (CloseSeason congela placar, SnapshotSeasonSpend tem teto em `ends_at`, SettleSeasonPrizes liquida, EnsureSeasonS1 idempotente, _trySeedAuctionBots gated-off) e o ReconcileDaily moram nos braços do MESMO mutex de settle, cada um com a sua guarda de transação; mover orquestração para um colaborador no meio de uma rodada de hardening seria redesenho de economia, não arrumação de tamanho. Saída registrada: a próxima onda que tocar este arquivo baixa `SeasonS1Rules`/`EnsureSeasonS1` para um `SeasonRules` próprio e a banda volta a ter folga.",
	},
]

func _suiteCeiling() -> void:
	print("-- D) folga contra o teto: medir é mais barato que brigar na cerca")
	var gate : String = _read("res://scripts/check_god_nodes.sh")
	Check(gate.length() > 400, "scripts/check_god_nodes.sh lido (a régua é dele; eu confiro por fora, não reescrevo)")
	var ceiling : int = _regexInt(gate, "MAX_LINES")
	var testsCeiling : int = _regexInt(gate, "TESTS_MAX_LINES")
	var slack : int = _regexInt(gate, "RATCHET_SLACK")
	Check(ceiling > 0 and testsCeiling > ceiling and slack > 0, "números lidos do próprio gate, nenhum copiado para cá: teto %d, teto tests/ %d, folga máxima %d" % [ceiling, testsCeiling, slack])
	var reR : RegEx = RegEx.create_from_string("\\[\"([^\"]+)\"\\][[:space:]]*=[[:space:]]*([0-9]+)")
	var ratchet : Dictionary = {}
	if reR != null:
		var pos : int = 0
		var each : RegExMatch = reR.search(gate, pos)
		while each != null:
			ratchet[each.get_string(1)] = int(each.get_string(2))
			pos = each.get_start() + 1
			each = reR.search(gate, pos)
	Check(ratchet.size() >= 4, "o ratchet do gate foi parseado do `declare -A RATCHET=` (%d tetos nomeados)" % ratchet.size())
	for p in ratchet.keys():
		Check(FileAccess.file_exists(_join(_repoRoot(), str(p))), "teto nomeado para %s aponta para arquivo que existe (teto órfão = ratchet mentindo)" % str(p))

	var tracked : Dictionary = {}
	for q in _git("ls-files --cached"):
		tracked[str(q)] = true
	Check(tracked.size() > 200, "índice do git lido (%d arquivos) — régua D mede o repo, não a bagunça da vez%s" % [tracked.size(), _gitBlame()])

	var measured : Array = []
	_walk("res://sources", PackedStringArray(["gd"]), measured)
	_walk("res://companion", PackedStringArray(["py"]), measured)
	var rows : Array = []
	var over : int = 0
	var overUntracked : Array = []
	var atFence : Array = []
	var ratchetBad : Array = []
	for path in measured:
		var local : String = str(path).replace("res://", "")
		var n : int = _countLines(str(path))
		if not tracked.has(local):
			if n > ceiling:
				overUntracked.append("%s=%d" % [local, n])
			continue
		var capped : bool = ratchet.has(local)
		rows.append([local, n, capped])
		if capped:
			var cap : int = int(ratchet[local])
			if n > cap or (cap - n) > slack:
				ratchetBad.append("%s=%d teto %d folga %d" % [local, n, cap, cap - n])
		elif n > ceiling:
			over += 1
			print("  [FAIL] %s tem %d linhas, acima do teto %d e sem teto nomeado no ratchet" % [local, n, ceiling])
		# A banda é [98%, 100%]: encostado POR BAIXO, ainda não estourou. Quem já
		# estourou é passivo do ratchet do gate, não desta régua.
		if not capped and ceiling > 0 and n <= ceiling and n * 100 >= ceiling * 98:
			atFence.append([local, n])
	CheckEq(over, 0, "nenhum arquivo rastreado sem teto nomeado acima de MAX_LINES%s" % _gitBlame())
	CheckEq(ratchetBad.size(), 0, "o ratchet do gate bate com o run por fora (estouro ou teto velho sem baixa): %s" % ", ".join(PackedStringArray(ratchetBad)))
	if overUntracked.size() > 0:
		Note("acima do teto e AINDA não rastreado (obra de outro agente; dono do número é o check_god_nodes.sh): %s" % ", ".join(PackedStringArray(overUntracked)))

	var declared : Dictionary = {}
	for e in NEAR_FENCE:
		declared[str(e["path"])] = str(e["reason"])
	var undeclared : Array = []
	for row in atFence:
		if not declared.has(str(row[0])):
			undeclared.append("%s=%d" % [row[0], int(row[1])])
	CheckEq(undeclared.size(), 0, "encostar no teto exige motivo registrado junto da entrada (novos na banda >=98%%: %s)%s" % [", ".join(PackedStringArray(undeclared)), _gitBlame()])
	var staleWhy : Array = []
	for p in declared.keys():
		Check(FileAccess.file_exists("res://" + str(p)), "%s da lista de motivo existe no repo" % str(p))
		var still : bool = false
		for row in atFence:
			if str(row[0]) == str(p):
				still = true
		if not still:
			staleWhy.append(str(p))
	CheckEq(staleWhy.size(), 0, "nenhum motivo para arquivo que já saiu da banda — apague a entrada (motivo velho é allowlist podre): %s%s" % [", ".join(PackedStringArray(staleWhy)), _gitBlame()])
	for e in NEAR_FENCE:
		Check(str(e["reason"]).length() > 80, "%s tem motivo de verdade escrito (%d chars, não placeholder)" % [str(e["path"]), str(e["reason"]).length()])

	rows.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	var shown : int = 0
	for row in rows:
		if bool(row[2]):
			continue
		Note("folga %d/%d (%.0f%%): %s = %d linhas" % [ceiling - int(row[1]), ceiling, 100.0 * (ceiling - int(row[1])) / float(ceiling), row[0], row[1]])
		shown += 1
		if shown >= 5:
			break
	# teto de tests/ — o gate passou a medir harness também; confiro por fora e
	# mostro quem está mais perto dele (é onde um 4º `IdleTests` nasceria).
	var testRows : Array = []
	for f in _list("res://tests", false):
		if str(f).get_extension() != "gd":
			continue
		testRows.append([str(f), _countLines(_join("res://tests", str(f)))])
	testRows.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	var overTests : int = 0
	for row in testRows:
		if int(row[1]) > testsCeiling:
			overTests += 1
			print("  [FAIL] tests/%s tem %d linhas, acima do teto de tests/ %d" % [row[0], row[1], testsCeiling])
	CheckEq(overTests, 0, "nenhum harness acima do teto de tests/ (%d)" % testsCeiling)
	if testRows.size() > 0:
		Note("maior harness: tests/%s = %d linhas (folga %d contra o teto de tests/)" % [testRows[0][0], testRows[0][1], testsCeiling - int(testRows[0][1])])
	Check(rows.size() > 150, "%d arquivos próprios medidos contra o teto de %d%s" % [rows.size(), ceiling, _gitBlame()])
	suitesDone += 1

func _run() -> void:
	_suiteRoot()
	_suiteProbeFacts()
	_suiteReachability()
	_suiteCeiling()
	# Guarda de integridade, descoberta no run deste mesmo arquivo: um SCRIPT ERROR
	# no meio de uma suíte aborta a função, mas o CHAMADOR CONTINUA — o marcador
	# verde foi impresso com a suíte D pela metade (37 checks em vez de 46). O
	# `ci_gate_log.sh` pega isso pelo grep de SCRIPT ERROR no log; esta linha pega
	# do lado de dentro, para o verde nunca depender de alguém reler o log.
	CheckEq(suitesDone, 4, "as 4 suítes rodaram até o fim (aborto no meio não imprime verde)")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
