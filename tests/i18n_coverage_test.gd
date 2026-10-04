extends SceneTree

# ORDEM #101 — régua de COBERTURA de i18n: toda chave usada pelo fonte/conteúdo
# precisa existir nos catálogos compilados dos idiomas DECLARADOS em
# `project.godot` (`locale/translations`), com um texto que o jogador daquele
# idioma possa ler.
#
# O que esta régua NÃO é: `tests/i18n_catalog_test.gd` já confere a tabela
# `data/i18n/ui.csv` contra os `.translation` que ela produz (drift de import,
# `unescape_keys`, registro no TranslationServer). O que a auditoria cega de
# 2026-09-28 achou é outra classe, e nada no portão a media: chave CHAMADA pelo
# fonte e ausente do catálogo. No cliente pt-BR aquilo cai no fallback — o
# jogador lê a frase inglesa no meio da fala do NPC. O censo em
# `tools/extract_i18n.py` já sabia (linha "conteúdo NPCs/quests" do
# `coverage_report.md`) e vivia como RELATÓRIO, não como gate: nada no portão
# lia o número. Reportagem que não derruba o build é documentação, não régua.
#
# De onde vem a lista de chaves (requisito da ordem: nunca uma lista escrita à
# mão neste arquivo):
#   1. `sources/**/*.gd`  -> literais de `tr("...")` e `TranslationServer.translate("...")`
#   2. `sources/**/*.gd`  -> atribuição de linha inteira de um prop RASTREADO
#      (a lista vem de `TrackedProps` (`sources/gui/Localizer.gd:@TrackedProps`), não
#      deste arquivo) — é o que o runtime traduz
#   3. `presets/**/*.tscn`-> os mesmos props (fora de maps/sprites/particles)
#   4. `sources/scripts/**` -> `Mes|Msg|Say|Dialog|Option|Answer|Question("...")` = domínio conteúdo
# Os quatro padrões são os mesmos de `tools/extract_i18n.py` e a régua R-SELF
# confere a contagem dos dois lados, senão um scanner que parasse de andar
# daria "0 órfãs" verde. É assim que a régua teria pego o defeito ANTES do
# conserto: com o catálogo de 2026-09-28 ela devolve as órfãs da tabela inteira.
#
# Idiomas: vindos de `project.godot`, não escritos aqui. Colunas de `ui.csv`
# (cabeçalho `keys,en,pt_BR`) dão o valor por idioma.
#
# Predicado de "coberto" para um idioma L (o mesmo para todo idioma, e o mesmo
# que os controles plantados atravessam):
#   - a chave está na lista de identidade (`IDENTITY`, lida de
#     `tools/extract_i18n.py` — símbolos e loanwords que a comunidade BR usa
#     crus): coberta por desenho;
#   - senão, a linha do CSV precisa DECLARAR o texto de L (`linha[L]` não vazio
#     e diferente da chave) OU declarar o idioma da própria chave pela outra
#     coluna (`linha[O]` != chave), que é o caso das falas escritas em português
#     ("Cancelar", "Forja") — sem essa segunda perna a régua cobraria do tradutor
#     a impossível tarefa de traduzir uma chave para a língua em que ela já está;
#   - e o catálogo COMPILADO daquele idioma tem de conter a chave com o texto da
#     tabela. É a perna que vira vermelha quando alguém conserta o CSV e esquece
#     o `--import`, ou edita o `.translation` derivado em vez da origem.
#
# CONTROLES PLANTADOS (sem eles esta régua não conta como fechada): cinco injeções
# em memória passam PELO MESMO `_orphans()` que julga o repositório:
#   C-PLANT-1 chave falsa sem linha no CSV   -> tem de acusar EXATAMENTE 1
#   C-PLANT-2 mesma chave com linha declarada nos dois idiomas e no catálogo
#                                              compilado -> tem de acusar 0
#   C-PLANT-3 chave com linha eco (en=pt=chave, não identidade) -> 1: prova que a
#                                              régua não mede só presença de linha
#   C-PLANT-4 linha certa no CSV, catálogo compilado SEM a chave -> 1: é o estado
#                                              "consertei a origem e não regenerei"
#   C-PLANT-5 40 linhas REAIS apagas do catálogo -> 40: a mordida é proporcional, e
#                                              é o "antes do conserto" reproduzido
#                                              sem lista escrita no harness
# E mais uma perna de chegada, fora dos controles: 40 chaves de conteúdo (as
# primeiras por ordem de chave) têm de resolver no `TranslationServer` exatamente
# no texto que a tabela declara — é o que o jogador lê, não o que o disco contém.
#
# Uso:   bash scripts/test.sh one i18n_coverage_test
# Saída: == RESULT: N checks, M failures ==   e exit code = nº de falhas.

var checks : int = 0
var failures : int = 0

var _usedTr : Dictionary = {}
var _usedTextGd : Dictionary = {}
var _usedTscn : Dictionary = {}
var _usedContent : Dictionary = {}
var _catalog : Dictionary = {}
var _identity : Dictionary = {}
var _locales : PackedStringArray = PackedStringArray()
var _msgs : Dictionary = {}
var _props : PackedStringArray = PackedStringArray()

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		# O verde também é impresso: quem lê o log precisa ver o que os controles
		# plantados acusaram, não só a linha de veredito. Um controle mudo é um
		# controle que não pode ser conferido por um juiz.
		print("  [ok] " + label)
	return condition

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _initialize() -> void:
	print("== I18N COVERAGE: chaves usadas x catálogos por idioma ==")
	_props = _trackedProps()
	print("  props traduzidos no runtime (%d): %s" % [_props.size(), ", ".join(_props)])
	_scanGd()
	_scanTscn()
	var used : Dictionary = _unionUsed()
	_locales = _declaredLocales()
	_catalog = _loadCatalog()
	_identity = _loadIdentity()
	_msgs = _loadCompiled(used)

	# R-SELF: o scanner tem de estar andando, e os quatros domínios têm de bater com
	# o censo que `tools/extract_i18n.py` escreve em `data/i18n/coverage_report.md`.
	# Uma chave a menos no lado da varredura é a régua mudando-se em verde — dois
	# leitores independentes do mesmo fonte é o que impede isso. Os tetos abaixo são
	# os números medidos em 2026-09-29 (95 / 64 / 164 / 732), rebaixados de propósito
	# só o bastante para o gate não cair quando uma tela perde um botão: quem segura o
	# número real é a conferência cruzada com o relatório.
	var nTr : int = _usedTr.size()
	var nText : int = _usedTextGd.size()
	var nTscn : int = _usedTscn.size()
	var nCont : int = _usedContent.size()
	print("  domínios: tr()=%d text=.gd=%d tscn=%d conteúdo(NPC)=%d" % [nTr, nText, nTscn, nCont])
	# O piso abaixo é o número medido em 2026-10-04 (text/title/placeholder_text).
	# Perder um prop é ato deliberado do produto, e a régua exige que ele apareça:
	# se a leitura de `TrackedProps` voltasse vazia por mudança de forma, a varredura
	# dos dois domínios iria a zero e o verde seria mudo.
	_check(_props.size() >= 3, "a varredura recebeu do produto os props que o runtime traduz (%s)" % ", ".join(_props))
	_check(nTr >= 80, "domínio tr()/TranslationServer varrido (%d chaves; medido 95)" % nTr)
	_check(nText >= 50, "domínio text= de .gd varrido (%d; medido 64)" % nText)
	_check(nTscn >= 150, "domínio text/title= de .tscn varrido (%d; medido 164)" % nTscn)
	_check(nCont >= 700, "domínio de conteúdo NPC varrido (%d; medido 732)" % nCont)
	_check(_locales.size() >= 2, "idiomas declarados em project.godot (%s)" % ", ".join(_locales))
	_check(_identity.size() >= 20, "lista de identidade lida de tools/extract_i18n.py (%d entradas; menos que 20 = parse do bloco quebrado)" % _identity.size())
	_check(_catalog.size() >= 1000, "catálogo ui.csv carregado (%d linhas)" % _catalog.size())
	var divergencia : String = _divergenciaContraCenso(nTr, nText, nTscn, nCont)
	_check(divergencia.is_empty(),
			"os dois leitores do mesmo fonte concordam por domínio (%s)" % divergencia.left(240))

	# O censo derivado, impresso antes do veredito: N chaves, M idiomas, K órfãs.
	var porIdioma : Dictionary = {}
	var totalOrfas : int = 0
	for locale in _locales:
		porIdioma[locale] = _orphans(used, _catalog, _identity, _msgs, String(locale))
		totalOrfas += (porIdioma[locale] as Array).size()
	print("== CENSO i18n: %d chaves usadas, %d idiomas declarados (%s), %d órfãs ==" % [used.size(), _locales.size(), ", ".join(_locales), totalOrfas])
	for locale in _locales:
		var lista : Array = porIdioma[locale]
		print("  %s: %d órfãs" % [locale, lista.size()])
		for i in range(mini(lista.size(), 12)):
			print("      - " + String(lista[i]).left(150))
		if lista.size() > 12:
			print("      ... +%d" % (lista.size() - 12))
		_check(lista.is_empty(), "%s: nenhuma chave usada sem texto legível no catálogo (%d órfãs)" % [locale, lista.size()])

	# Chegada pelo caminho do jogador: o TranslationServer registrado, não o recurso
	# carregado à mão. Se o catálogo estiver no disco mas fora do idioma, a tela
	# continua em inglês e nada acima perceberia.
	_checkRuntimeSweep(used)

	_controles(used)
	_finish()

# ---------------------------------------------------------------- predicado

func _orphans(used : Dictionary, catalog : Dictionary, identity : Dictionary, msgs : Dictionary, locale : String) -> Array[String]:
	var out : Array[String] = []
	for keyV in used.keys():
		var key : String = String(keyV)
		if identity.has(key):
			continue
		var rowV : Variant = catalog.get(key)
		if typeof(rowV) != TYPE_DICTIONARY:
			out.append(key + "  [sem linha em ui.csv]")
			continue
		var row : Dictionary = rowV
		var vis : String = String(row.get(locale, ""))
		var declarado : bool = not vis.is_empty() and vis != key
		if not declarado:
			# A segunda perna: a linha declara o IDIOMA DA PRÓPRIA CHAVE por uma outra
			# coluna (chave escrita em português, com o inglês declarado ao lado).
			# Vale para qualquer outro idioma declarado, não só o segundo — amanhã
			# serem três, a régua continua simétrica.
			for l2 in _locales:
				if String(l2) == locale:
					continue
				var alt : String = String(row.get(String(l2), ""))
				if not alt.is_empty() and alt != key:
					declarado = true
					break
		if not declarado:
			out.append(key + "  [linha eco: nenhum idioma declara texto]")
			continue
		var porChave : Variant = msgs.get(locale)
		if typeof(porChave) != TYPE_DICTIONARY:
			out.append(key + "  [catálogo compilado ausente]")
			continue
		var comp : Dictionary = porChave
		if not comp.has(key):
			out.append(key + "  [ui.csv consertado, .translation velho (faltou --import)]")
			continue
		if not vis.is_empty() and String(comp[key]) != vis:
			out.append(key + "  [texto compilado != ui.csv]")
			continue
	return out

# ---------------------------------------------------------------- varredura

func _readAll(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var txt : String = f.get_as_text()
	f.close()
	return txt

func _walk(dirPath : String, ext : String, out : Array[String]) -> void:
	var d : DirAccess = DirAccess.open(dirPath)
	if d == null:
		return
	d.list_dir_begin()
	var name : String = d.get_next()
	while name != "":
		var full : String = dirPath + "/" + name
		if d.current_is_dir():
			if not name.begins_with(".") and not name.begins_with("import"):
				_walk(full, ext, out)
		elif name.ends_with(ext):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()

func _rx(pattern : String) -> RegEx:
	var r : RegEx = RegEx.new()
	var err : int = r.compile(pattern)
	if err != OK:
		push_error("regex inválida: " + pattern)
	return r

# Os props que o jogador vê traduzidos NO RUNTIME, lidos de `TrackedProps`
# (`sources/gui/Localizer.gd:@TrackedProps`) — não uma lista escrita neste harness.
# A régua varre exatamente o que o Localizer traduz: um quarto prop na tabela do
# produto entra no censo no mesmo commit, e se as strings dele não tiverem linha na
# tabela a régua as devolve como órfãs. É assim que o buraco de `placeholder_text`
# (medido 2026-10-04: nove chaves atribuídas no fonte, nenhuma linha no CSV, o
# jogador BR lendo inglês dentro da caixa onde ia digitar) fecha sozinho em vez de
# ficar esperando alguém lembrar de ampliar a varredura.
func _trackedProps() -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var scr : GDScript = load("res://sources/gui/Localizer.gd") as GDScript
	if scr == null:
		return out
	var table : Variant = scr.get_script_constant_map().get("TrackedProps")
	if typeof(table) != TYPE_ARRAY:
		return out
	for pairV in (table as Array):
		var pair : Array = pairV
		if not pair.is_empty():
			out.append(String(pair[0]))
	out.sort()
	return out

func _alternatives(props : PackedStringArray) -> String:
	# Mais longo primeiro: a alternação tem de tentar `placeholder_text` antes de
	# `text`, senão o sufixo casaria no meio do nome e o prop fugiria da varredura.
	var porTamanho : Array[String] = []
	for p in props:
		porTamanho.append(String(p))
	porTamanho.sort_custom(func(a : String, b : String) -> bool: return a.length() > b.length())
	return "|".join(porTamanho)

func _literal(inner : String) -> String:
	# O importador roda com unescape_keys/unescape_translations = true, então a
	# forma comparável é a desescapada — mesma função do engine, não uma cópia.
	return inner.c_unescape()

func _scanGd() -> void:
	var files : Array[String] = []
	_walk("res://sources", ".gd", files)
	var reTr : RegEx = _rx('tr\\("((?:[^"\\\\]|\\\\.)+)"\\)')
	var reTs : RegEx = _rx('TranslationServer\\.translate\\("((?:[^"\\\\]|\\\\.)+)"\\)')
	var reMes : RegEx = _rx('\\b(?:Mes|Msg|Say|Dialog|Option|Answer|Question)\\s*\\(\\s*"((?:[^"\\\\]|\\\\.)+)"')
	var reText : RegEx = _rx('^\\s*(?:\\w+\\.)*(?:' + _alternatives(_props) + ')\\s*=\\s*"((?:[^"\\\\]|\\\\.)+)"\\s*$')
	for path in files:
		var src : String = _readAll(path)
		if src.is_empty():
			continue
		var emContent : bool = path.begins_with("res://sources/scripts")
		for m in reTr.search_all(src):
			var k : String = _literal(m.get_string(1))
			if emContent:
				_usedContent[k] = true
			else:
				_usedTr[k] = true
		for m in reTs.search_all(src):
			var k2 : String = _literal(m.get_string(1))
			if emContent:
				_usedContent[k2] = true
			else:
				_usedTr[k2] = true
		for m in reMes.search_all(src):
			_usedContent[_literal(m.get_string(1))] = true
		for line in src.split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			var mt : RegExMatch = reText.search(line)
			if mt != null:
				var k3 : String = _literal(mt.get_string(1))
				if emContent:
					_usedContent[k3] = true
				else:
					_usedTextGd[k3] = true

func _scanTscn() -> void:
	var files : Array[String] = []
	_walk("res://presets", ".tscn", files)
	var reProps : RegEx = _rx('\\b(?:' + _alternatives(_props) + ')\\s*=\\s*"((?:[^"\\\\]|\\\\.)+)"')
	for path in files:
		if path.contains("/maps/") or path.contains("/sprites/") or path.contains("/particles/"):
			continue
		var src : String = _readAll(path)
		for m in reProps.search_all(src):
			_usedTscn[_literal(m.get_string(1))] = true

func _unionUsed() -> Dictionary:
	var used : Dictionary = {}
	for grupo in [_usedTr, _usedTextGd, _usedTscn, _usedContent]:
		for k in (grupo as Dictionary).keys():
			used[String(k)] = true
	return used

# ---------------------------------------------------------------- fontes

func _declaredLocales() -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var re : RegEx = _rx('res://data/i18n/ui\\.([A-Za-z0-9_]+)\\.translation')
	for m in re.search_all(_readAll("res://project.godot")):
		var loc : String = m.get_string(1)
		if not out.has(loc):
			out.append(loc)
	return out

func _loadCatalog() -> Dictionary:
	var out : Dictionary = {}
	var f : FileAccess = FileAccess.open("res://data/i18n/ui.csv", FileAccess.READ)
	if f == null:
		return out
	var header : PackedStringArray = f.get_csv_line()
	while not f.eof_reached():
		var row : PackedStringArray = f.get_csv_line()
		if row.size() != header.size():
			continue
		var key : String = _literal(String(row[0]))
		if key.is_empty():
			continue
		var vals : Dictionary = {}
		for i in range(1, header.size()):
			vals[String(header[i])] = _literal(String(row[i]))
		out[key] = vals
	f.close()
	return out

func _loadIdentity() -> Dictionary:
	# Fonte única: o bloco IDENTITY de tools/extract_i18n.py. Linhas de comentário
	# são descartadas ANTES de extrair as aspas — as notas do bloco citam palavras
	# entre aspas e virar isenção de tradução a partir de uma prosa é exatamente o
	# tipo de licença que esta casa caça.
	var out : Dictionary = {}
	var src : String = _readAll("res://tools/extract_i18n.py")
	var ini : int = src.find("IDENTITY = {")
	if ini < 0:
		return out
	var fim : int = src.find("\n}", ini)
	if fim < 0:
		return out
	var bloco : String = src.substr(ini, fim - ini)
	var re : RegEx = _rx('"((?:[^"\\\\]|\\\\.)+)"')
	for line in bloco.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		for m in re.search_all(line):
			out[_literal(m.get_string(1))] = true
	return out

func _loadCompiled(used : Dictionary) -> Dictionary:
	# `load()` de um `.translation` devolve `OptimizedTranslation`, que NÃO expõe
	# `get_messages()` nem `has_message()` (a tabela de mensagens dele é o hash
	# compilado, e o único método que sobra dos dois formatos é `get_message()`).
	# Presença = texto não vazio: uma linha vazia no catálogo é exatamente o defeito
	# que se caça, então medir por "devolveu string" não afrouxa nada — medido em
	# 2026-09-29, `ui.csv` não tem nenhuma célula vazia (0 em `en`, 0 em `pt_BR`).
	# O mapa é montado sobre as chaves USADAS: é só contra elas que o predicado
	# decide, e assim a régua não depende de método exclusivo do formato otimizado.
	var out : Dictionary = {}
	for loc in _locales:
		var locale : String = String(loc)
		var res : Translation = load("res://data/i18n/ui.%s.translation" % locale) as Translation
		_check(res != null, "catálogo compilado %s carrega" % locale)
		var map : Dictionary = {}
		if res != null:
			for keyV in used.keys():
				var msg : String = res.get_message(StringName(String(keyV)))
				if not msg.is_empty():
					map[String(keyV)] = msg
		out[locale] = map
	return out

# ---------------------------------------------------------------- runtime

func _divergenciaContraCenso(nTr : int, nText : int, nTscn : int, nCont : int) -> String:
	# O censo de `tools/extract_i18n.py` (linha "Domínio | Chaves" de
	# `data/i18n/coverage_report.md`) e esta varredura GDScript leem o mesmo fonte por
	# caminhos independentes. Concordarem é a prova de que o scanner daqui não parou
	# de andar; divergir é gate vermelho com os dois números na etiqueta.
	var esperado : Dictionary = {
		"tr()": nTr, "text=": nText, "cenas": nTscn, "conte": nCont,
	}
	var visto : Dictionary = {}
	for line in _readAll("res://data/i18n/coverage_report.md").split("\n"):
		var l : String = line.strip_edges()
		if not l.begins_with("|"):
			continue
		var miolo : String = l
		if miolo.ends_with("|"):
			miolo = miolo.substr(0, miolo.length() - 1)
		if miolo.begins_with("|"):
			miolo = miolo.substr(1)
		var col : PackedStringArray = miolo.split("|")
		if col.size() < 2:
			continue
		var nome : String = String(col[0]).strip_edges()
		var num : String = String(col[1]).strip_edges()
		if not num.is_valid_int():
			continue
		for prefix in esperado.keys():
			if nome.begins_with(prefix):
				visto[prefix] = num.to_int()
	var out : String = ""
	for prefix in esperado.keys():
		if not visto.has(prefix):
			out += " %s: domínio ausente do relatório" % prefix
			continue
		if int(visto[prefix]) != int(esperado[prefix]):
			out += " %s: censo=%d varredura=%d" % [prefix, int(visto[prefix]), int(esperado[prefix])]
	return out.strip_edges()

func _checkRuntimeSweep(used : Dictionary) -> void:
	# Chegada pelo caminho do jogador: o `TranslationServer` REGISTRADO (os catálogos
	# que `project.godot` declara), com a chave EXATA que a tela chama. Medir por
	# substring de português seria a métrica que mente: "The port is where most goods
	# come in..." tem "e" e "o" e passaria. Então: amostra determinística das chaves
	# de conteúdo cuja linha do CSV declara um texto pt-BR diferente da chave, e a
	# exigência é que o `tr()` devolva EXATAMENTE esse texto.
	var alvo : String = "pt_BR"
	if not _locales.has(alvo):
		alvo = String(_locales[0])
	var candidatos : Array[String] = []
	for keyV in used.keys():
		var key : String = String(keyV)
		if _identity.has(key) or not _usedContent.has(key):
			continue
		var rowV : Variant = _catalog.get(key)
		if typeof(rowV) != TYPE_DICTIONARY:
			continue
		var vis : String = String((rowV as Dictionary).get(alvo, ""))
		if vis.is_empty() or vis == key:
			continue
		candidatos.append(key)
	candidatos.sort()
	var antes : String = TranslationServer.get_locale()
	TranslationServer.set_locale(alvo)
	var mudas : int = 0
	var vistas : int = mini(candidatos.size(), 40)
	for i in range(vistas):
		var key2 : String = candidatos[i]
		var vis2 : String = String((_catalog[key2] as Dictionary).get(alvo, ""))
		if TranslationServer.translate(key2) != vis2:
			mudas += 1
			print("      [muda] " + key2.left(90) + " -> " + TranslationServer.translate(key2).left(60))
	TranslationServer.set_locale(antes)
	_check(vistas == 40, "a amostra de chegada tem 40 chaves de conteúdo com pt-BR declarado (%d candidatas)" % candidatos.size())
	_check(mudas == 0, "chegada: o tr() do caminho real devolve EXATAMENTE o texto da tabela em %s sobre a amostra (%d conferidas, %d mudas)" % [alvo, vistas, mudas])

# ---------------------------------------------------------------- controles

func _linhaPlantada(sufixo : String) -> Dictionary:
	# A linha injetada é montada a partir dos idiomas DECLARADOS, não de nomes
	# escritos aqui: se o projeto declarar um terceiro idioma amanhã, o controle
	# planta nele também.
	var row : Dictionary = {}
	for loc in _locales:
		row[String(loc)] = "PLANTED #101 texto declarado" + sufixo + "-" + String(loc)
	return row

func _msgsMais(chave : String, valores : Dictionary) -> Dictionary:
	var out : Dictionary = {}
	for loc in _locales:
		var map : Dictionary = (_msgs[String(loc)] as Dictionary).duplicate()
		if valores.is_empty():
			map.erase(chave)
		else:
			map[chave] = String(valores[String(loc)])
		out[String(loc)] = map
	return out

func _controles(used : Dictionary) -> void:
	var falso : String = "PLANTED #101 — fala de NPC injetada que não existe no catálogo"
	var baseline : Dictionary = {}
	for locale in _locales:
		baseline[String(locale)] = (_orphans(used, _catalog, _identity, _msgs, String(locale)) as Array).size()
	var u1 : Dictionary = used.duplicate()
	u1[falso] = true

	# C-PLANT-1: a chave falsa entra no conjunto USADO em memória e nada mais muda.
	# Cada idioma declarado tem de acusar EXATAMENTE +1 órfã. Uma régua que devolvesse
	# 0 aqui estaria morta — é isto que separa régua de enfeite, e é o mesmo `_orphans()`
	# que acabou de julgar o repositório, sem um caractere de caminho alternativo.
	for locale in _locales:
		var d : int = (_orphans(u1, _catalog, _identity, _msgs, String(locale)) as Array).size() - int(baseline[String(locale)])
		_check(d == 1, "C-PLANT-1 %s: chave usada sem tradução acusou %d (esperado 1)" % [locale, d])

	# C-PLANT-2: a MESMA chave, agora com linha declarada em todos os idiomas e
	# presente no catálogo compilado. Tem de acusar 0 — senão toda chave traduzida
	# também seria contada e o verde do repositório seria inatingível.
	var plantada : Dictionary = _linhaPlantada("")
	var c2 : Dictionary = _catalog.duplicate()
	c2[falso] = plantada
	var m2 : Dictionary = _msgsMais(falso, plantada)
	for locale in _locales:
		var d2 : int = (_orphans(u1, c2, _identity, m2, String(locale)) as Array).size() - int(baseline[String(locale)])
		_check(d2 == 0, "C-PLANT-2 %s: chave usada COM tradução acusou %d (esperado 0)" % [locale, d2])

	# C-PLANT-3: linha que só ecoa a chave em todos os idiomas, fora da lista de
	# identidade — o "traduzido" que não traduz nada. Tem de acusar +1: prova que a
	# régua não mede apenas presença de linha no catálogo.
	var eco : Dictionary = {}
	for locale in _locales:
		eco[String(locale)] = falso
	var c3 : Dictionary = _catalog.duplicate()
	c3[falso] = eco
	var m3 : Dictionary = _msgsMais(falso, eco)
	for locale in _locales:
		var d3 : int = (_orphans(u1, c3, _identity, m3, String(locale)) as Array).size() - int(baseline[String(locale)])
		_check(d3 == 1, "C-PLANT-3 %s: linha eco sem declaração acusou %d (esperado 1)" % [locale, d3])

	# C-PLANT-4: origem (ui.csv) consertada e derivado (.translation) SEM a chave —
	# o estado de quem edita a origem e não regenere, ou edita o derivado à mão.
	var m4 : Dictionary = _msgsMais(falso, {})
	for locale in _locales:
		var d4 : int = (_orphans(u1, c2, _identity, m4, String(locale)) as Array).size() - int(baseline[String(locale)])
		_check(d4 == 1, "C-PLANT-4 %s: ui.csv com a chave e catálogo compilado sem ela acusou %d (esperado 1)" % [locale, d4])

	# C-PLANT-5: a mordida tem de ser proporcional ao estrago, que é o que faz desta
	# régua a prova do "antes do conserto". Apago em memória N linhas REAIS do
	# catálogo (as primeiras por ordem de chave, nenhuma escolhida por mim) e exijo
	# exatamente +N órfãs por idioma: é o catálogo de 2026-09-28 reproduzido sem uma
	# lista hardcodeada no harness.
	var c5 : Dictionary = _catalog.duplicate()
	var apagadas : int = 0
	var ordem : Array = used.keys()
	ordem.sort()
	for keyV in ordem:
		if apagadas >= 40:
			break
		var key : String = String(keyV)
		if c5.has(key) and not _identity.has(key):
			c5.erase(key)
			apagadas += 1
	for locale in _locales:
		var d5 : int = (_orphans(used, c5, _identity, _msgs, String(locale)) as Array).size() - int(baseline[String(locale)])
		_check(apagadas == 40 and d5 == apagadas,
				"C-PLANT-5 %s: %d linhas reais removidas do catálogo acusaram %d órfãs (esperado %d)" % [locale, apagadas, d5, 40])
