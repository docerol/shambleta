extends SceneTree

# AUDITORIA 2026-09-27, i18n: a tabela e o catálogo compilado precisam dizer a
# mesma coisa.
#
# `data/i18n/ui.csv` não é lido pelo jogo: ele passa pelo importador
# `csv_translation`, que produz `ui.en.translation` e `ui.pt_BR.translation`, e só
# esses recursos chegam ao `TranslationServer`. Todo check de i18n deste
# repositório até hoje leu a TABELA — inclusive o censo de cobertura
# (`tools/extract_i18n.py`) e a régua de consentimento em `IdleTests.gd`. Com isso
# existia uma classe inteira de defeito que passava verde: uma linha traduzida na
# tabela que nunca chegou ao catálogo.
#
# Essa classe não é hipotética. O importador roda com `unescape_keys=false`, e as
# 6 frases do onboarding têm `\n` na chave (o `.gd` chama
# `tr("Bem-vindo...\n\n...")` com a quebra de linha REAL do literal). A chave
# compilada ficava sendo a sequência de dois caracteres `\n` e nunca casava com a
# chamada: as 6 frases estavam traduzidas na tabela, contadas como cobertas pelo
# censo, e o jogador lia inglês. O conserto é a flag em true (a tabela inteira já
# era escrita no regime escapado — `unescape_translations` já era true); este
# harness é a régua que não deixa o conserto virar Folklore.
#
# O que este arquivo cobra, na ordem:
#  1. nenhuma linha do catálogo pode estar muda em `en` — é o que permite afirmar
#     que uma linha com `pt_BR == keys` é português-de-nascença e não esquecimento
#     (o censo chama isso de "fonte em português" só quando o `en` existe);
#  2. toda linha com `pt_BR` próprio tem que estar no catálogo pt_BR com EXATAMENTE
#     o texto da tabela (e o mesmo para `en`): drift de import, chave partida e
#     flag trocada abrem aqui;
#  3. as frases multilinha têm que existir no catálogo na forma desescapada e NÃO
#     na forma crua — é a prova positiva de `unescape_keys=true`, e é o check que
#     inverte de cor quando alguém desliga a flag;
#  4. o `tr()` do caminho real (TranslationServer, idioma pt_BR) devolve português
#     para as frases do onboarding, porque é ele que a tela mostra, não o recurso.
#
# Uso:   godot --headless --path . -s tests/i18n_catalog_test.gd
#        (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Saída: == RESULT: N checks, M failures ==   e exit code = nº de falhas.

var checks : int = 0
var failures : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _initialize() -> void:
	print("== I18N: ui.csv x catálogo compilado ==")
	var file : FileAccess = FileAccess.open("res://data/i18n/ui.csv", FileAccess.READ)
	if not Check(file != null, "ui.csv abre para leitura"):
		_finish()
		return
	var trPt : Translation = load("res://data/i18n/ui.pt_BR.translation") as Translation
	var trEn : Translation = load("res://data/i18n/ui.en.translation") as Translation
	if not Check(trPt != null and trEn != null, "os dois catálogos compilados carregam (en e pt_BR)"):
		_finish()
		return
	var header : PackedStringArray = file.get_csv_line()
	if not Check(header.size() == 3 and String(header[0]) == "keys" and String(header[2]) == "pt_BR",
			"ui.csv tem as três colunas keys,en,pt_BR (%s)" % ",".join(header)):
		_finish()
		return

	var rows : int = 0
	var semEn : String = ""
	var foraPt : String = ""
	var foraEn : String = ""
	var multiline : int = 0
	var escapadaAindaViva : String = ""
	var brPassthrough : int = 0
	while not file.eof_reached():
		var row : PackedStringArray = file.get_csv_line()
		if row.size() != 3:
			continue
		var rawKey : String = String(row[0])
		# O importador roda `unescape_keys=true` e `unescape_translations=true`: o
		# índice e o texto que existem no catálogo são as formas DES escapadas, e é
		# com a forma desescapada que o runtime chama `tr()`.
		var key : String = rawKey.replace("\\n", "\n")
		var en : String = String(row[1]).replace("\\n", "\n")
		var pt : String = String(row[2]).replace("\\n", "\n")
		if key.is_empty():
			continue
		rows += 1
		if en.is_empty():
			semEn += key.left(40) + " "
		if key.contains("\n"):
			multiline += 1
			# A chave CRUA não pode sobreviver como índice: se ela ainda resolve, a
			# flag foi desligada e o runtime voltou a chamar uma chave que não existe.
			if trPt.get_message(rawKey) != "":
				escapadaAindaViva += rawKey.left(40) + " "
		if pt != key and not pt.is_empty():
			if trPt.get_message(key) != pt:
				foraPt += key.left(40) + " "
		elif pt == key and not pt.is_empty():
			# pt_BR == fonte: ou é português-de-nascença, ou é linha esquecida. O
			# censo só aceita a primeira leitura quando a linha declara o inglês
			# dela, então aqui o que se mede é quantas assim existem.
			brPassthrough += 1
		if en != key and trEn.get_message(key) != en:
			foraEn += key.left(40) + " "
	file.close()

	Check(semEn.is_empty(), "nenhuma linha do catálogo está muda em en (%s)" % semEn.left(200))
	Check(foraPt.is_empty(), "toda linha com pt_BR próprio existe igual no catálogo pt_BR (%s)" % foraPt.left(200))
	Check(foraEn.is_empty(), "toda linha com en próprio existe igual no catálogo en (%s)" % foraEn.left(200))
	Check(escapadaAindaViva.is_empty(),
			"nenhuma chave multilinha sobrevive no catálogo na forma crua \\n — unescape_keys está ativo mesmo (%s)" % escapadaAindaViva.left(200))
	Check(rows >= 1000, "a varredura olhou o catálogo inteiro, não um pedaço (%d linhas)" % rows)
	Check(multiline >= 6, "%d frases multilinha entraram na varredura (as 6 do onboarding, no mínimo)" % multiline)
	Check(brPassthrough >= 1, "a contagem de linhas com fonte em português é medida (%d)" % brPassthrough)

	# Chegada: o que a tela usa é o TranslationServer, não o recurso carregado à
	# mão. Se a linha existir no recurso mas o catálogo não estiver registrado no
	# idioma, o jogador continua lendo inglês e nada acima perceberia.
	TranslationServer.set_locale("pt_BR")
	var vivo : String = ""
	for probe in [
			"Welcome to Shambleta!\n\nThis is an idle RPG — your character fights on its own. Let's take a quick tour.",
			"When you come back, your AFK earnings are ready to claim.\n\nTap the Menu button at the top of the screen and tap the AFK icon to collect your offline progress.",
			"I have read and accept the Terms of Use and Privacy Policy, and I am 18 years old or older"] :
		var said : String = tr(StringName(probe))
		if said == probe or said.is_empty():
			vivo += probe.left(38) + " "
	Check(vivo.is_empty(), "o tr() do caminho real devolve português nas frases multilinha e no aceite (%s)" % vivo.left(200))
	TranslationServer.set_locale("en")
	var ditoEn : String = tr(StringName("Eventos"))
	# "Eventos" é uma chave escrita em português na fonte: o jogador inglês só não
	# lê português se a coluna en estiver no catálogo — é a obrigação da checks 1.
	Check(ditoEn != "Eventos" and not ditoEn.is_empty(),
			"uma chave de fonte portuguesa chega traduzida ao jogador en (%s)" % ditoEn)
	TranslationServer.set_locale("pt_BR")
	_finish()
