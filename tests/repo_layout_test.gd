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
#     `check_secrets.sh` entrou na lista de `structure_gates`
#     (`scripts/test.sh:@structure_gates`) diz exatamente
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
#  E) CENA x SCRIPT. Uma cena veste um script e o script nomeia caminhos de nó. Quando
#     os dois divergem o engine escreve `ERROR: Node not found` no log, e NENHUM portão
#     deste repo lê essa linha (`scripts/ci_gate_log.sh` é um script plano, sem função,
#     e cobra `SCRIPT ERROR` e `Parse Error` — um `Node not found` de `_ready` não é
#     nenhum dos dois). Foi assim que `presets/gui/Progress.tscn` passou a história
#     inteira vestindo o script de outro painel. A suíte mede os dois sentidos da
#     costura, cena por cena, com controle plantado em cada direção.
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
# Mapa caminho-de-cena -> script da raiz, montado sob demanda pela suíte E. As cenas
# de mapa instanciam as mesmas folhas dezenas de vezes; sem aqui, a suíte relia o
# mesmo arquivo a cada bloco.
var _rootScriptCache : Dictionary = {}

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
		"path": "sources/economy/EconomyCatalog.gd",
		"reason": "lote C (2026-10-06): o catálogo é a fonte única das políticas de economia e cada fatia do lote pendurou a sua decisão aqui — janela de lavagem `AHWashWindowSec` (C-6), a política declarada da dupla taxa de craftado (C-10) e os validadores de passe/table do VIP (C-7); as 6 suites que leem catálogo juram pelo arquivo, não por extrato. Onda M-3/M-8 (2026-10-07): a fatia pendurou knobs de presente e duas coleções aqui e ESTOUROU o teto na hora — a saída foi consumida pela metade honesta: as conquistas saíram para `AchievementCatalog.gd` e os knobs do presente para `GiftService.gd` (aliases de 2 linhas ficam para nenhum leitor ser reensinado), do mesmo jeito que `EconomyPassTrack` saiu no M-1. O plano do `AHPolicy` (fees/banda/lifecycle) segue vivo para a próxima onda que acrescentar const.",
	},
	{
		"path": "sources/economy/EconomyService.gd",
		"reason": "lote M-1/M-5 (2026-10-07): a fachada do serviço é o contrato público das suítes e do RPC — as fachadas novas `BuyGuildPerk`/`GuildPerks` (M-2) e `FlashToday`/`BuyFlashSlot` (M-5) entraram sem mudar uma linha de decisão (toda ela mora no dono: `GuildService`/`ShopService`); quem entra aqui é assinatura, não lógica. Saída registrada: a próxima onda que acrescentar fachada aqui parte o domain por dono (trade/vault/loja) em sub-fachadas do próprio `EconomyService`, do mesmo jeito que `stateView`/`shopService`/`guildService` já nasceram internos.",
	},
	# M-4 (2026-10-07): a entrada `companion/test_webhook.py` saiu da tabela porque
	# a saída registrada dela FOI CONSUMIDA: a onda abriu `test_push.py` (fila +
	# ganchos, padrão `test_metrics.py`) e `push_hooks.py` (a fila do Store, mix-in),
	# e o webhook voltou para baixo da banda. Motivo para arquivo fora da banda é
	# allowlist podre — a régua de cima caça exatamente isso.
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

# --- E) cena x script -------------------------------------------------------

# Uma cena veste um script na raiz, e o script nomeia caminhos de nó. Quando os dois
# divergem o engine reclama no log com `ERROR: Node not found`, e NENHUM portão deste
# repo lê essa linha: `scripts/ci_gate_log.sh` cobra `SCRIPT ERROR` e `Parse Error`, e
# um `Node not found` de `_ready` não é nenhum dos dois. Foi assim que
# `presets/gui/Progress.tscn` passou a história inteira vestindo `res://sources/gui/Settings.gd`
# numa árvore de log de missões: o painel só existia de verdade porque
# `presets/gui/Game.tscn` redeclarava `Progress.gd` por cima da instância, e o
# arquivo — que é o que qualquer outro caminho de carga lê — estava errado.
#
# Duas asserções, cada uma com controle plantado no fim da suíte:
#   E1  todo caminho de nó que o script da raiz DECLARA numa `@onready` (`$A/B`,
#       `$"A B"` ou `get_node("A/B")`) resolve no nó real da cena que o veste;
#   E2  nenhum nó que uma cena INSTANCIA de outra cena veste um script DIFERENTE do que
#       a cena filha declara na raiz — é o dispositivo que esvazia E1 no produto.
#
# O que deliberadamente NÃO é régua aqui, e foi medido para chegar nisso:
#  - "duas cenas não podem vestir o mesmo script". Há três compartilhamentos no
#    diretório e dois deles são o design (cinco cenas de efeito em
#    `res://sources/effects/Projectile.gd`, dois menus em
#    `res://sources/gui/context/ContextMenu.gd`).
#  - "nada redeclara script num nó instanciado". 28 blocos em `presets/maps/layers/`
#    reimprimem o MESMO script da filha — é ruído do editor, não máscara. Acusar isso
#    trocaria 28 falsos positivos por um verdadeiro, e o controle plantado da
#    redundância é exatamente o que impede a régua de escorregar para lá.
#  - `get_node_or_null`: quem o escreve declarou que o nó pode faltar (há um caso real
#    no `Timer` de `res://sources/gui/SpeechBubble.gd`). Cobrar esse seria a régua
#    mentir sobre a intenção do código.
#
# Escopo da extração, declarado: só `@onready`, que é onde um caminho errado é
# garantidamente nulo antes de qualquer uso.

const SCENE_ROOT : String = "res://presets"

func _suiteSceneScript() -> void:
	print("-- E) toda cena veste o script que declara, e o script acha os nós que declara")
	var scenes : Array = []
	_walk(SCENE_ROOT, PackedStringArray(["tscn"]), scenes)
	if not Check(scenes.size() > 100, "%d cenas lidas de %s (o censo é do diretório, não de lista escrita)" % [scenes.size(), SCENE_ROOT]):
		return
	var charged : int = 0
	var gaps : Array[String] = []
	var unbuilt : Array[String] = []
	var overrides : Array[String] = []
	for scenePath in scenes:
		var packed : PackedScene = load(String(scenePath)) as PackedScene
		var inst : Node = null if packed == null else packed.instantiate()
		if inst == null:
			unbuilt.append(String(scenePath))
			continue
		var scr : Script = inst.get_script()
		if scr != null:
			var scriptPath : String = String(scr.resource_path)
			if scriptPath.begins_with("res://sources/"):
				var declared : Dictionary = _declaredNodePaths(_read(scriptPath))
				charged += declared.size()
				for nodePath in declared:
					if inst.get_node_or_null(NodePath(String(nodePath))) == null:
						gaps.append("%s <- %s: %s" % [String(scenePath), scriptPath, String(nodePath)])
		for blocked in _sceneOverrides(String(scenePath)):
			overrides.append(String(blocked))
		inst.free()
	CheckEq(unbuilt.size(), 0, "todas as %d cenas de %s instanciam (%s)" % [scenes.size(), SCENE_ROOT, ", ".join(unbuilt)])
	CheckEq(gaps.size(), 0, "%d caminhos de nó declarados em `@onready` por %d cenas: todos resolvem no nó real (%s)" % [charged, scenes.size(), " | ".join(gaps)])
	CheckEq(overrides.size(), 0, "%d cenas: nenhum nó herdado de outra cena veste um script diferente do que ela declara (%s)" % [scenes.size(), " | ".join(overrides)])

	# O caso concreto, preso sem depender do censo: a cena do log de missões veste o
	# script do log de missões, e os seis caminhos que ele nomeia estão na árvore.
	var progress : PackedScene = load("res://presets/gui/Progress.tscn") as PackedScene
	var progressNode : Node = null if progress == null else progress.instantiate()
	if Check(progressNode != null, "Progress.tscn instancia"):
		var progressScript : Script = progressNode.get_script()
		CheckEq(String(progressScript.resource_path) if progressScript != null else "", "res://sources/gui/Progress.gd", "Progress.tscn veste Progress.gd, e não o script de outro painel")
		var progressDeclared : Dictionary = _declaredNodePaths(_read("res://sources/gui/Progress.gd"))
		CheckEq(progressDeclared.size(), 6, "Progress.gd nomeia os seis caminhos de nó do painel")
		var progressMissing : int = 0
		for nodePath in progressDeclared:
			if progressNode.get_node_or_null(NodePath(String(nodePath))) == null:
				progressMissing += 1
		CheckEq(progressMissing, 0, "os seis caminhos de Progress.gd resolvem em Progress.tscn")
		progressNode.free()

	CheckEq(_sceneControls(), 0, "controles plantados da suíte E: os cinco morderam")
	suitesDone += 1

# Caminhos de nó que um script nomeia nas suas `@onready`. Duas formas duras:
# `$A/B` (e a variante com aspas `$"A B"`) e `get_node("A/B")`. Devolve conjunto.
# `get_node_or_null` fica de fora de propósito: quem o escreve declarou que o nó pode
# faltar, e acusar isso seria a régua mentir sobre a intenção do código.
func _declaredNodePaths(scriptText : String) -> Dictionary:
	var out : Dictionary = {}
	var reNode : RegEx = RegEx.create_from_string("get_node\\([[:space:]]*\"([^\"]+)\"")
	var reQuoted : RegEx = RegEx.create_from_string("\\$\"([^\"]+)\"")
	var reDollar : RegEx = RegEx.create_from_string("\\$([A-Za-z0-9_/\\.]+)")
	for rawLine in scriptText.split("\n"):
		var line : String = String(rawLine)
		if not line.contains("@onready"):
			continue
		for each in [reNode, reQuoted, reDollar]:
			var re : RegEx = each
			var pos : int = 0
			while true:
				var m : RegExMatch = re.search(line, pos)
				if m == null:
					break
				out[String(m.get_string(1))] = true
				pos = m.get_start() + 1
	return out

# Nós que uma cena INSTANCIA de outra cena e, no próprio bloco, redeclaram um script
# DIFERENTE do que a cena instanciada declara na raiz. É o dispositivo que esvazia E1
# no produto: `res://presets/gui/Game.tscn` fazia exatamente isso com o log de missões,
# e por isso o painel funcionava enquanto o arquivo estava errado.
#
# O que NÃO é acusado, e por quê:
#  - redundância (`script` igual ao da cena instanciada): 28 blocos assim em
#    `presets/maps/layers/` — o editor reimprime o script quando o nó filho muda de
#    nome/tipo. Mesmo dono, nenhuma máscara.
#  - cena filha sem script na raiz, script vindo do pai: é a saída legítima do repo
#    para "container genérico" (ButtonTip, CellSelection, HealthBar, Window).
func _sceneOverrides(scenePath : String) -> Array[String]:
	var out : Array[String] = []
	var text : String = _read(scenePath)
	var scripts : Dictionary = _extResources(text, "Script")
	var packs : Dictionary = _extResources(text, "PackedScene")
	var inNode : bool = false
	var instanceId : String = ""
	var blockScript : String = ""
	var header : String = ""
	var lines : PackedStringArray = text.split("\n")
	for i in lines.size():
		var line : String = String(lines[i])
		var newHeader : String = ""
		if line.begins_with("[node "):
			newHeader = line
		if inNode and (newHeader != "" or i == lines.size() - 1):
			for verdict in _overrideVerdict(scenePath, header, instanceId, blockScript, scripts, packs):
				out.append(String(verdict))
		if line.begins_with("[") and newHeader == "":
			inNode = false
			instanceId = ""
			blockScript = ""
		if newHeader != "":
			inNode = true
			header = newHeader
			instanceId = _extRefId(newHeader, "instance=ExtResource(")
			blockScript = ""
			continue
		if line.begins_with("script = ExtResource("):
			blockScript = _extRefId(line, "script = ExtResource(")
	return out

func _overrideVerdict(scenePath : String, header : String, instanceId : String, blockScript : String, scripts : Dictionary, packs : Dictionary) -> Array[String]:
	if instanceId == "" or blockScript == "" or not packs.has(instanceId):
		return []
	var childScene : String = String(packs[instanceId])
	var imposed : String = String(scripts.get(blockScript, ""))
	if imposed.is_empty():
		return []
	var native : String = _rootSceneScript(childScene)
	if native.is_empty() or native == imposed:
		return []
	return ["%s/%s veste %s mas a cena que ele instancia (%s) declara %s" % [scenePath, header, imposed, childScene, native]]

# Mapa id -> path dos `ext_resource` de um tipo.
func _extResources(sceneText : String, wantType : String) -> Dictionary:
	var out : Dictionary = {}
	var re : RegEx = RegEx.create_from_string("\\[ext_resource type=\"" + wantType + "\"[^\n]*?path=\"([^\"]+)\"[^\n]*?id=\"([^\"]+)\"")
	var pos : int = 0
	while true:
		var m : RegExMatch = re.search(sceneText, pos)
		if m == null:
			break
		out[String(m.get_string(2))] = String(m.get_string(1))
		pos = m.get_start() + 1
	return out

# Planta uma cena no `user://` com o gesto exato do defeito: um nó que instancia uma
# cena filha e redeclara o script dela. Só `scriptPath` muda entre os dois controles —
# imposta (deve morder) e redundante (não pode morder).
func _writeOverride(path : String, scriptPath : String, scriptId : String) -> bool:
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("[gd_scene load_steps=3 format=3]\n\n"
		+ "[ext_resource type=\"PackedScene\" path=\"res://presets/effects/ambient/Lighting.tscn\" id=\"1_child\"]\n"
		+ "[ext_resource type=\"Script\" path=\"" + scriptPath + "\" id=\"" + scriptId + "\"]\n\n"
		+ "[node name=\"Holder\" type=\"Node2D\"]\n\n"
		+ "[node name=\"Lighting\" type=\"CanvasLayer\" parent=\".\" instance=ExtResource(\"1_child\")]\n"
		+ "script = ExtResource(\"" + scriptId + "\")\n")
	f.close()
	return true

func _extRefId(line : String, prefix : String) -> String:
	var at : int = line.find(prefix)
	if at < 0:
		return ""
	var rest : String = line.substr(at + prefix.length())
	var open : int = rest.find("\"")
	if open < 0:
		return ""
	var close : int = rest.find("\"", open + 1)
	return "" if close < 0 else rest.substr(open + 1, close - open - 1)

# Script que a RAIZ de uma cena declara, resolvido pelo id do próprio arquivo.
func _rootSceneScript(scenePath : String) -> String:
	if _rootScriptCache.has(scenePath):
		return String(_rootScriptCache[scenePath])
	var answer : String = ""
	var text : String = _read(scenePath)
	if text != "":
		var scripts : Dictionary = _extResources(text, "Script")
		var started : bool = false
		for rawLine in text.split("\n"):
			var line : String = String(rawLine)
			if line.begins_with("[node "):
				if started:
					break
				started = true
				continue
			if started and line.begins_with("["):
				break
			if started and line.begins_with("script = ExtResource("):
				answer = String(scripts.get(_extRefId(line, "script = ExtResource("), ""))
				break
	_rootScriptCache[scenePath] = answer
	return answer

# Os cinco controles, cada um com a direção certa. Dois plantados que PRECISAM morder
# (as duas formas duras de caminho, e a máscara de script), dois que NÃO podem morder
# (a forma tolerada `get_node_or_null`, e a redundância que o editor reimprime) e um
# positivo verdadeiro (o texto de `TitleBar.gd`, que tem de resolver inteiro) — sem os
# que não mordem, uma extração que acusasse tudo passaria nos que mordem.
func _sceneControls() -> int:
	var bitten : int = 0
	var planted : int = 5
	var packed : PackedScene = load("res://presets/gui/TitleBar.tscn") as PackedScene
	if packed == null:
		return 1
	var node : Node = packed.instantiate()
	if node == null:
		return 1
	var ghost : Dictionary = _declaredNodePaths("extends Control\n@onready var a : Control\t= $NoSuchChild/Ghost\n@onready var b : Label\t= get_node(\"AlsoNoSuch\")\n@onready var c : Timer\t= get_node_or_null(\"StillNoSuch\")\n")
	if ghost.size() == 2 and not ghost.has("StillNoSuch") and node.get_node_or_null(NodePath("NoSuchChild/Ghost")) == null:
		bitten += 1
	# Forma com aspas (`$"Com Espaço"`) também tem de ser lida, senão o buraco continua.
	var quoted : Dictionary = _declaredNodePaths("@onready var q : Control\t= $\"Um Dois\"")
	if quoted.size() == 1 and quoted.has("Um Dois"):
		bitten += 1
	# A máscara, montada em arquivo de verdade no `user://`: um nó que instancia
	# `Lighting.tscn` (cuja raiz veste `res://sources/effects/Lighting.gd`) e redeclara
	# `Settings.gd`. É o gesto do `Game.tscn` sobre o Progress, sem tocar no repo.
	var maskPath : String = "user://repo_layout_mask.tscn"
	var redundPath : String = "user://repo_layout_redundant.tscn"
	var maskOK := _writeOverride(maskPath, "res://sources/gui/Settings.gd", "2_mask")
	var redundOK := _writeOverride(redundPath, "res://sources/effects/Lighting.gd", "2_same")
	if maskOK and redundOK:
		var masked : Array[String] = _sceneOverrides(maskPath)
		var redundant : Array[String] = _sceneOverrides(redundPath)
		if masked.size() == 1 and masked[0].contains("Settings.gd") and masked[0].contains("Lighting.gd"):
			bitten += 1
		# Sentido inverso: reimpressão do MESMO script não pode ser acusada, senão a
		# régua passa a gritar sobre os 28 blocos de mapa que sempre estiveram certos.
		if redundant.is_empty():
			bitten += 1
		var d : DirAccess = DirAccess.open("user://")
		if d != null:
			d.remove(maskPath.get_file())
			d.remove(redundPath.get_file())
	var honest : Dictionary = _declaredNodePaths(_read("res://sources/gui/TitleBar.gd"))
	var honestMissing : int = 0
	for nodePath in honest:
		if node.get_node_or_null(NodePath(String(nodePath))) == null:
			honestMissing += 1
	if honest.size() > 0 and honestMissing == 0:
		bitten += 1
	node.free()
	if bitten != planted:
		print("  [FAIL] controles da suíte E: %d de %d mordendo (extração ou detecção está cega)" % [bitten, planted])
		failures += 1
	return planted - bitten

func _run() -> void:
	_suiteRoot()
	_suiteProbeFacts()
	_suiteReachability()
	_suiteCeiling()
	_suiteSceneScript()
	# Guarda de integridade, descoberta no run deste mesmo arquivo: um SCRIPT ERROR
	# no meio de uma suíte aborta a função, mas o CHAMADOR CONTINUA — o marcador
	# verde foi impresso com a suíte D pela metade (37 checks em vez de 46). O
	# `ci_gate_log.sh` pega isso pelo grep de SCRIPT ERROR no log; esta linha pega
	# do lado de dentro, para o verde nunca depender de alguém reler o log.
	CheckEq(suitesDone, 5, "as 5 suítes rodaram até o fim (aborto no meio não imprime verde)")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
