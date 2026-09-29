extends SceneTree

# Régua do `Conf` e da folha de configuração: os três defeitos que a tempestade de
# SCRIPT ERROR do `webpush_subscription_test` revelou, cada um com uma sonda que
# falha no fonte de antes da correção.
#
# 1. Índice negativo. `Type.NONE = -1` é o default de todo getter e `Array` do Godot
#    aceita índice negativo: `confFiles[-1]` é o ÚLTIMO arquivo da lista, que é
#    `AUTH_TOKEN`. Um `GetString(secao, chave)` que esqueceu o tipo lia, em silêncio,
#    a credencial de login e devolvia como se fosse preferência do usuário.
# 2. Array vazio. `Conf.Init()` só era chamado do `Launcher._ready`, e `Conf` é
#    estático: em qualquer caminho que não passou por ali — todo harness `-s`, e o
#    `WebPush._Save` foi flagrado exatamente aí — o primeiro acesso estourava
#    out-of-bounds e a gravação da preferência caía no chão sem nenhum aviso.
# 3. A folha conhecia o mundo. `Util` lia `SkillCommons` por uma constante de
#    projeção, `SkillCommons` puxa `DB`, `DB` escreve `Launcher` — e num `-s` esse
#    grafo todo compila antes de os autoloads serem registrados. Soma 41 linhas de
#    `Compile Error` antes do `_init`, a classe `Launcher` inteira virando
#    `Nonexistent function`, `FileSystem.LoadConfig` devolvendo null e o processo
#    morrendo em SIGABRT no teardown.
#
# Uso: godot --headless --path . -s tests/conf_type_guard_test.gd
# Exit code: número de checks falhos.

const CONF_SOURCE : String = "res://sources/conf/Conf.gd"
const Accessors : Array[String] = ["GetVariant", "SetValue", "HasSection", "HasSectionKey", "SaveType"]

# A camada de configuração é folha: `Util` é chamado por todo log do projeto, `Conf`
# por todo serviço, e ambos por qualquer harness `-s`. Um único nome de classe do
# mundo que entre ali faz o grafo inteiro ser compilado — antes de qualquer autoload
# estar registrado.
const Leaves : Array[String] = [
	"res://sources/conf/Conf.gd",
	"res://sources/util/Util.gd",
	"res://sources/launcher/LauncherCommons.gd",
	"res://sources/system/FileSystem.gd",
]

const SENTINELA : String = "nao-e-um-token-de-verdade"
const Section : String = "auth"
const Key : String = "token"
const IntKey : String = "untyped_probe"
const CacheKey : String = "stale_probe"

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
	# Anti-vazio: toda a suite abaixo só prova alguma coisa se este processo chegou
	# mesmo sem `Init()` — é o estado que o `WebPush._Save` de harness tinha, e é o
	# estado que produzia os dois defeitos. Se um dia alguém inicializar `Conf` na
	# carga de classe, as sondas viram ornamento e esta linha avisa antes.
	Check(Conf.confFiles.is_empty(),
		"o processo chegou aqui sem `Conf.Init()` (sem isso as sondas abaixo são decorativas)")

	# ---------------------------------------------------------------- 1) o tipo
	Check(not Conf.Usable(Conf.Type.NONE), "Type.NONE não é um tipo utilizável (era confFiles[-1] = auth_token)")
	Check(not Conf.Usable(Conf.Type.COUNT), "Type.COUNT (o teto) também está fora do intervalo")
	Check(not Conf.Usable(Conf.Type.SETTINGS), "com a lista vazia nem o tipo válido é utilizável")

	# O que segura o `Ensure()` implícito é cada acesso público chamar a régua antes
	# de indexar. Isso é verificável no fonte, e é o que um getter novo esqueceria:
	# sem a linha ele volta a produzir a tempestade de out-of-bounds que aqui se caça.
	_assertAccessorGuards()

	# --------------------------------- 5) a folha não pode conhecer o mundo (acoplamento)
	_assertLeavesAreLeaves()

	# --------------------------------------- 2) o primeiro acesso é um acesso de verdade
	Conf.SetValue(Section, Key, Conf.Type.AUTH_TOKEN, SENTINELA)
	Check(Conf.confFiles.size() == Conf.Type.COUNT,
		"o primeiro acesso (um `SetValue`) inicializou os %d arquivos: medido %d" %
			[Conf.Type.COUNT, Conf.confFiles.size()])
	Check(Conf.Usable(Conf.Type.SETTINGS) and Conf.Usable(Conf.Type.USERSETTINGS) and Conf.Usable(Conf.Type.AUTH_TOKEN),
		"SETTINGS, USERSETTINGS e AUTH_TOKEN abriram (antes o auth_token estava fora da lista)")
	Check(Conf.GetString(Section, Key, Conf.Type.AUTH_TOKEN) == SENTINELA,
		"e a gravação fora do caminho do Launcher chegou no arquivo (antes: out-of-bounds, nada escrito)")

	# ------------------------------------------------------ 3) o leak pelo default
	var leaked : String = Conf.GetString(Section, Key)
	Check(leaked == "",
		"getter sem tipo devolve o default, não o conteúdo de auth_token (devolveu \"%s\")" % leaked)
	# A chave número existe DE FATURA no auth_token, com o valor posto logo abaixo: se
	# a leitura sem tipo devolver 77, o que vazou foi o arquivo, não um descuido da sonda.
	Conf.SetValue(Section, IntKey, Conf.Type.AUTH_TOKEN, 77)
	Check(Conf.GetInt(Section, IntKey, Conf.Type.AUTH_TOKEN) == 77,
		"a sonda numérica está mesmo no auth_token (sem isso a régua de baixo não discrimina nada)")
	Check(Conf.GetInt(Section, IntKey) == 0 and not Conf.GetBool(Section, IntKey),
		"GetInt/GetBool sem tipo também não atravessam para o último arquivo")
	Check(not Conf.HasSectionKey(Section, Key, Conf.Type.NONE),
		"HasSectionKey com Type.NONE responde false em vez de perguntar ao auth_token")
	Check(not Conf.HasSection(Section, Conf.Type.NONE),
		"HasSection com Type.NONE responde false em vez de perguntar ao auth_token")

	# ------------------------------------------- 4) recarregar não pode cheirar velho
	# O cache é por (seção, chave, tipo) e não sabe de que arquivo o valor veio. Um
	# `Init()` que relê o disco e mantém o cache devolve valor que já não está em
	# lugar nenhum — aqui ele nem chegou a ser salvo em disco, de propósito.
	Conf.SetValue("web", CacheKey, Conf.Type.USERSETTINGS, true)
	Check(Conf.GetBool("web", CacheKey, Conf.Type.USERSETTINGS),
		"o valor recém-escrito é lido de volta (o cache não está quebrado)")
	Conf.Init()
	Check(not Conf.GetBool("web", CacheKey, Conf.Type.USERSETTINGS),
		"reinicializar descarta o cache: um valor nunca salvo não sobrevive ao `Init()`")

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)

# Varre o fonte do `Conf` e exige que, em cada acesso público, toda linha que indexa
# `confFiles` esteja protegida por um `Ensure()` e um `Usable(type)` anteriores. É a
# régua do caso novo: um getter adicionado amanhã com `confFiles[type]` solto não
# passa daqui, e é exatamente assim que a tempestade de out-of-bounds voltaria.
func _assertAccessorGuards() -> void:
	var file : FileAccess = FileAccess.open(CONF_SOURCE, FileAccess.READ)
	if file == null:
		Check(false, "fonte do Conf ilegível (%s)" % CONF_SOURCE)
		return
	var lines : PackedStringArray = file.get_as_text().split("\n")
	file.close()

	for name : String in Accessors:
		var header : int = -1
		for i in lines.size():
			if lines[i].begins_with("static func %s(" % name):
				header = i
				break
		if header < 0:
			Check(false, "%s: existe no `Conf`? (a lista de nomes apodreceu)" % name)
			continue
		var guarded : bool = false
		var ensured : bool = false
		var bare : int = 0
		for i in range(header + 1, lines.size()):
			var line : String = lines[i]
			if line.begins_with("static func "):
				break
			if line.contains("confFiles[") and not guarded:
				bare = i + 1
				break
			if line.contains("Usable(type)"):
				guarded = true
			if line.contains("Ensure()"):
				ensured = true
		Check(ensured and guarded and bare == 0,
			"%s: indexa `confFiles` só depois de `Ensure()`+`Usable(type)`%s" %
				[name, "" if (ensured and guarded and bare == 0) else " (violação na linha %d; Ensure visto: %s; Usable visto: %s)" % [bare, str(ensured), str(guarded)]])

# --------------------------------------------------------------- 5) o acoplamento
# `Util` é chamado por cada log do projeto, `Conf` por cada serviço, e os dois por
# qualquer harness `-s`. O Godot resolve o grafo de classes no momento em que a
# classe é compilada, e num `godot -s` isso acontece ANTES de os autoloads serem
# registrados. Uma única aresta para o mundo faz o mundo inteiro compilar ali, e cada
# classe que escreve `Launcher.`/`Network.` solto devolve
# `SCRIPT ERROR: Compile Error: Identifier not found: Launcher` — que não é log
# cosmético: a classe falha por inteiro e os estáticos dela viram `Nonexistent
# function`. Medido antes da correção: tocar `Util` dava 41 dessas linhas, `Conf` 43
# e `LauncherCommons` 42, todas antes do `_init`. A aresta era uma só —
# `Util.UnrollPathLength` lendo `SkillCommons.PerspectiveIncrease`, uma constante de
# projeção isométrica. `SkillCommons` puxa `DB`, e `DB` escreve `Launcher`.
#
# A régua não lista classes proibidas: ela percorre o grafo a partir das quatro
# folhas e falha se algum arquivo alcançado nomeia um autoload. Uma aresta nova
# apontando para uma classe que ninguém pensou em proibir pega aqui do mesmo jeito.
func _assertLeavesAreLeaves() -> void:
	var files : Array[String] = []
	_gdUnder("res://sources", files)
	Check(files.size() > 200,
		"a varredura achou %d arquivos `.gd` em `sources/` (abaixo disso o grafo é ilustrativo)" % files.size())

	var code : Dictionary = {}
	var owner : Dictionary = {}
	for path : String in files:
		var text : String = _read(path)
		code[path] = _codeOnly(text)
		for line : String in text.split("\n"):
			if line.begins_with("class_name "):
				var parts : PackedStringArray = line.split(" ")
				if parts.size() > 1:
					owner[parts[1]] = path

	var autoloads : Array[String] = _autoloadNames()
	Check(autoloads.size() >= 4,
		"%d autoloads lidos do `project.godot` (%s)" % [autoloads.size(), ", ".join(autoloads)])

	var carriers : Dictionary = {}
	for path : String in code:
		for a : String in autoloads:
			if _names(code[path], a):
				carriers[path] = a
				break
	Check(not carriers.is_empty(),
		"%d arquivos de `sources/` nomeiam um autoload no código — é isso que a folha não pode alcançar" % carriers.size())

	# Prova de que a varredura funciona ANTES de confiar nela: do `SkillCommons` (a
	# classe da aresta histórica) ela tem de chegar a um portador. Sem esta linha, um
	# `_names` quebrado diria "folha limpa" para sempre — e a asserção de baixo é
	# justamente a que este arquivo existe para proteger.
	var seed : String = "res://sources/skill/SkillCommons.gd"
	if code.has(seed):
		var probe : Dictionary = _bfs([seed], owner, code, carriers)
		var probeParents : Dictionary = probe["parents"]
		var probeCarrier : String = str(probe["carrier"])
		Check(probeCarrier != "",
			"a varredura ACHA um portador de autoload partindo de `SkillCommons` (cadeia: %s)" %
				_chain(probeParents, probeCarrier))
	else:
		Check(false, "`SkillCommons` não está mais em `sources/skill/` — a sonda de cima apodreceu")

	var reach : Dictionary = _bfs(Leaves, owner, code, carriers)
	var reachParents : Dictionary = reach["parents"]
	var hit : String = str(reach["carrier"])
	Check(hit == "",
		"nenhum arquivo alcançado de `Conf`/`Util`/`LauncherCommons`/`FileSystem` nomeia autoload%s" %
			("" if hit == "" else " — alcançado pela cadeia: %s" % _chain(reachParents, hit)))
	Check(reachParents.size() > Leaves.size(),
		"o fechamento da folha tem %d arquivos além dos %d próprios (sem aresta percorrida a régua de cima é decorativa)" %
			[reachParents.size() - Leaves.size(), Leaves.size()])

func _gdUnder(dir : String, out : Array[String]) -> void:
	var d : DirAccess = DirAccess.open(dir)
	if d == null:
		Check(false, "não dá para abrir %s para varrer o grafo" % dir)
		return
	for f : String in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub : String in d.get_directories():
		_gdUnder(dir.path_join(sub), out)

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text : String = f.get_as_text()
	f.close()
	return text

# Autoloads lidos do `project.godot`, não de uma lista à mão: a régua acompanha o
# registro real e um autoload novo entra sozinho.
func _autoloadNames() -> Array[String]:
	var out : Array[String] = []
	var inside : bool = false
	for line : String in _read("res://project.godot").split("\n"):
		if line == "[autoload]":
			inside = true
			continue
		if inside:
			if line.begins_with("["):
				break
			var eq : int = line.find("=")
			if eq > 0:
				out.append(line.substr(0, eq))
	return out

# Só código cria aresta de compilação: fora comentários e fora do miolo das strings.
func _codeOnly(text : String) -> String:
	var out : Array[String] = []
	for line : String in text.split("\n"):
		if line.lstrip(" \t").begins_with("#"):
			continue
		if line.contains("\"\"\""):
			out.append(line)
			continue
		var buf : String = ""
		var inString : bool = false
		for i in line.length():
			var c : String = line[i]
			if inString:
				inString = c != "\""
				continue
			if c == "\"":
				inString = true
				buf += " "
				continue
			if c == "#":
				break
			buf += c
		out.append(buf)
	return "\n".join(out)

func _isIdent(c : String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")

# Casa o nome como identificador inteiro: `Launcher` não bate dentro de
# `LauncherCommons`, e `Conf` não bate dentro `Config`.
func _names(code : String, token : String) -> bool:
	var at : int = code.find(token)
	while at >= 0:
		var before : String = "" if at == 0 else code[at - 1]
		var after : String = "" if at + token.length() >= code.length() else code[at + token.length()]
		if not _isIdent(before) and not _isIdent(after):
			return true
		at = code.find(token, at + token.length())
	return false

# Largura em profundidade com pai por onde passou, para poder contar a cadeia de
# uma falha em vez de só dizer "tem um problema em algum lugar do grafo".
func _bfs(seeds : Array[String], owner : Dictionary, code : Dictionary, carriers : Dictionary) -> Dictionary:
	var parents : Dictionary = {}
	var queue : Array[String] = []
	for s : String in seeds:
		if code.has(s):
			parents[s] = ""
			queue.append(s)
	var head : int = 0
	var carrier : String = ""
	while head < queue.size():
		var path : String = queue[head]
		head += 1
		if carrier == "" and carriers.has(path):
			carrier = path
		for cls : String in owner:
			var target : String = owner[cls]
			if target == path or parents.has(target):
				continue
			if _names(code[path], cls):
				parents[target] = path
				queue.append(target)
	return {"parents": parents, "carrier": carrier}

func _chain(parents : Dictionary, target : String) -> String:
	if target == "" or not parents.has(target):
		return "—"
	var steps : Array[String] = []
	var at : String = target
	while at != "" and at != null:
		steps.append(at.replace("res://sources/", ""))
		at = str(parents.get(at, ""))
	steps.reverse()
	return " → ".join(steps)
