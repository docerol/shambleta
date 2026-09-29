extends IdleTests
class_name IdleTestsFrontier

# Fatiamento (2026-09-28): o kernel `tests/IdleTests.gd` chegou ao teto de
# `TESTS_MAX_LINES` de `scripts/check_god_nodes.sh`, e a saída que o próprio gate
# prescreve é fatiar. Este arquivo leva a fronteira do produto — o que se recebe no
# topo (`SuiteTormentRush`), o que a vitrine e o anúncio prometem e cumprem
# (`SuiteOfflineAdHours`, `SuiteStorefrontHonesty`), o que a documentação afirma
# com ponteiro para a árvore (`SuiteEvidencePointers`, `SuiteExternalLinksWebBranch`)
# e a esteira de item do farm vivo (`SuiteIdleLootPipeline`).
#
# Por que `extends IdleTests` e não um segundo objeto: a instância É o contexto do
# portão. `checks`/`failures` compõem a linha `== RESULT:` que
# `scripts/ci_gate_log.sh` lê, e `lastCharID` é o fixture que as suítes de mundo
# compartilham; `tests/run_idle_tests.gd` chama as 92 suítes numa instância só.
# Duas instâncias seriam dois placares para somar, e somar a régua é justamente o
# que o gate recusa. Então a FOLHA da hierarquia é o que o runner carrega
# (`IdleTestsFrontier`), e quem só quer os helpers do kernel (outros harnesses)
# continua carregando `IdleTests.gd` — nada saiu de lá.

# Tormento (D2) + boss rush com key.
func SuiteTormentRush(sql : SQLService, economy : EconomyService) -> void:
	print("[suite] torment + boss rush")
	# Mults puros
	Check(absf(Formula.TormentRewardMult(0) - 1.0) < 0.0001, "T0 reward x1")
	Check(absf(Formula.TormentRewardMult(4) - 2.0) < 0.0001, "T4 reward x2")
	Check(absf(Formula.TormentMobHpFactor(10) - 2.0) < 0.0001, "T10 mobs 2x HP")
	Check(absf(Formula.TormentMobDmgFactor(10) - 2.5) < 0.0001, "T10 mobs 2.5x dmg")
	Check(absf(Formula.TormentRewardMult(-3) - 1.0) < 0.0001, "negative torment clamps")
	CheckEq(Formula.TormentMaxCap, 10, "torment cap 10")
	# Persistência + gate de set
	var charID : int = CreateFixture(sql, "idle_torment_account", "IdleTormentTester", 20000)
	if not Check(charID != 0, "torment fixture created"):
		return
	CheckEq(sql.GetTormentLevel(charID), 0, "torment default 0")
	CheckEq(sql.GetTormentMax(charID), 0, "torment max default 0")
	Check(sql.SetTormentMax(charID, 2) and sql.GetTormentMax(charID) == 2, "torment max stored")
	Check(not bool(economy.SetTorment(charID, null, 5).get("ok", false)), "set above max rejected")
	Check(bool(economy.SetTorment(charID, null, 2).get("ok", false)), "set within max ok")
	CheckEq(sql.GetTormentLevel(charID), 2, "torment level stored")
	# Compra de key com gold
	var gp0 : int = int(sql.QueryBindings("SELECT gp FROM stat WHERE char_id = ?;", [charID])[0]["gp"])
	var buy : Dictionary = economy.BuyBossKey(charID)
	if Check(bool(buy.get("ok", false)), "key bought with gold"):
		CheckEq(int(buy.get("keys", -1)), 1, "first key")
		var gp1 : int = int(sql.QueryBindings("SELECT gp FROM stat WHERE char_id = ?;", [charID])[0]["gp"])
		CheckEq(gp0 - gp1, EconomyCatalog.BOSS_KEY_GOLD_PRICE, "key price burned")
	# Rush sem key → rejeita (gasta a key comprada primeiro)
	Check(economy.SpendBossKey(charID, 1, "test"), "key spent")
	Check(not bool(economy.RunBossRush(charID, null).get("ok", false)), "rush without agent rejected")
	# Rush com agente overpower: vence a escada inteira
	var agent : PlayerAgent = await _SpawnSimAgent(charID, 981, 1)
	if Check(agent != null, "rush agent spawned"):
		IdlePolicyService.StopIdleSession(agent)
		agent.stat.current.attack = 999999
		agent.stat.current.defense = 999999
		agent.stat.current.maxHealth = 99999999
		CheckEq(economy.GrantBossKey(charID, 1, "test"), 1, "rush key granted")
		var xpBefore : int = agent.stat.experience
		var rush : Dictionary = economy.RunBossRush(charID, agent)
		if Check(bool(rush.get("ok", false)), "rush resolves"):
			CheckEq(int(rush.get("wins", -1)), BossService.GetBossCount(), "rush clears the ladder")
			Check(int(rush.get("xp", 0)) > 0, "rush grants xp")
			Check(int(rush.get("chests", 0)) >= BossService.GetBossCount(), "rush grants chest per win")
			Check(agent.stat.experience > xpBefore, "rush xp applied to agent")
			CheckEq(sql.GetCharacterBossesBeaten(charID), BossService.GetBossCount(), "rush advances ladder")
			Check(sql.GetTormentMax(charID) >= 1, "clearing ladder unlocks T1")
		IdlePolicyService.StopIdleSession(agent)
	for nick in ["IdleTormentTester"]:
		sql.db.delete_rows("character", "nickname = '%s'" % nick)
	for uname in ["idle_torment_account"]:
		sql.db.delete_rows("account", "username = '%s'" % uname)

# Índice de basename -> caminhos `res://` (no máximo três por nome), construído uma vez por
# processo. Ele existe porque a documentação escreve ponteiro das duas formas: medido, dos 122
# `arquivo:linha` do beta, 40 vêm com caminho e 82 com nome cru (a forma `arquivo.gd:681`). Sem
# índice a régua olharia um terço da evidência que diz estar olhando.
static var _ptrIndex : Dictionary = {}

static func _PtrIndexWalk(dirPath : String) -> void:
	var dir : DirAccess = DirAccess.open(dirPath)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry : String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				_PtrIndexWalk(dirPath.path_join(entry))
			else:
				var bucket : Array = _ptrIndex.get(entry, [])
				if bucket.size() < 3:
					bucket.append(dirPath.path_join(entry))
					_ptrIndex[entry] = bucket
		entry = dir.get_next()
	dir.list_dir_end()

# Devolve "" quando o ponteiro não resolve sem ambiguidade. Ordem: caminho literal; caminho com barra
# que é único como SUFIXO na árvore (o nome bate e o diretório está errado — `server/Peers.gd:284`,
# que vive em `sources/network/server/`); nome único na árvore. Nome ausente é histórico legítimo (a
# prosa que fala do `gut_runner.gd` apagado tem que poder existir) e nome ambíguo não tem como
# decidir — os dois ficam fora de propósito. A sufixo existe porque sem ela o ponteiro de caminho
# errado era justamente o único tipo que a régua não julgava: barrado no `find("/")` anterior, ele
# saía pela porta dos invisíveis e a linha citada nunca era conferida.
static func _PtrResolve(cited : String) -> String:
	var direct : String = "res://" + cited
	if FileAccess.file_exists(direct):
		return direct
	if _ptrIndex.is_empty():
		_PtrIndexWalk("res://")
	var arr : Array = _ptrIndex.get(cited.get_file(), [])
	if arr.is_empty():
		return ""
	var bySuffix : Array = []
	for entry in arr:
		if String(entry).ends_with("/" + cited):
			bySuffix.append(entry)
	if bySuffix.size() == 1:
		return String(bySuffix[0])
	if cited.find("/") < 0 and arr.size() == 1:
		return String(arr[0])
	return ""

# Linha em branco é ponteiro morto: quem abre o arquivo no número citado vê nada, e um intervalo cujo
# lado é em branco descreve o bloco uma linha além do que ele vai. Medido na passada de 2026-09-28:
# 15 dos ponteiros resolvidos caíam em branco, e um deles (EconomyCatalog.gd linhas 296-307, citado como a
# autorização de mint do `SHAMBLETA_AD_STUB`) não era só deslocado — apontava para constantes de
# guilda. A régua de mensagem não pega esse caso porque não há mensagem de check na prosa.
static func _LineBlank(lines : PackedStringArray, n : int) -> bool:
	if n < 1 or n > lines.size():
		return false
	return String(lines[n - 1]).strip_edges() == ""

# Span de cada função de coluna zero do arquivo: [linha do `func`, linha anterior ao próximo
# `func`] — derivado do arquivo, nunca de lista. É o que permite cobrar que o número citado
# esteja DENTRO da suíte que a prosa nomeia: `SuiteStorefrontHonesty` (`…:505`) atravessou um
# fatiamento de 39 linhas e continuou "resolvido" (a linha 505 existia e era cheia), só que
# apontando para outra função. Nome de suíte sem número é o que a regra (4) já cobria; número
# sem nome era o buraco.
static func _FnSpans(lines : PackedStringArray) -> Dictionary:
	var spans : Dictionary = {}
	var pending : String = ""
	for i in lines.size():
		var line : String = String(lines[i])
		if not line.begins_with("func ") and not line.begins_with("static func "):
			continue
		if pending != "":
			var prev : Array = spans[pending]
			prev[1] = i
		var head : String = line.substr(line.find("func ") + 5)
		var name : String = head.substr(0, head.find("(")).strip_edges()
		pending = name
		spans[name] = [i + 1, lines.size()]
	return spans

# Devolve "" quando não há o que julgar (suíte não mora naquele arquivo — a prosa pode estar
# apontando para harness irmão, e a regra (4) cuida do nome). Fora disso, devolve o texto da
# falha quando o intervalo citado escapa do span da suíte nomeada.
static func _SpanDrift(spans : Dictionary, suiteName : String, from : int, to : int) -> String:
	if suiteName == "" or not spans.has(suiteName):
		return ""
	var span : Array = spans[suiteName]
	if from >= int(span[0]) and to <= int(span[1]):
		return ""
	return "%s-%d fora de `%s`, que vai em %d-%d" % [from, to, suiteName, int(span[0]), int(span[1])]

# Identidade declared -> span, para TODA declaração de coluna zero (não só `func`).
# A régua de span acima julga `Suite*` com o nome NA MESMA LINHA do número; isto aqui
# julga qualquer símbolo nomeado na cláusula, de qualquer arquivo de código, e é o que
# fecha o buraco que a passada do juiz de 2026-09-28 provou com onze exemplos: um
# ponteiro cuja linha existe e é cheia é declarado "conferido" seja lá o que a prosa
# afirmar sobre ele. Um `harnesses_extra()` dito numa linha e o número na linha de
# baixo passava porque a única régua de identidade exigia as duas coisas na mesma
# linha — e o número apontava para o corpo de outra função, com o símbolo nomeado a
# dezenas de linhas de distância. Formas reconhecidas na coluna zero: GDScript `func`/`static func`/
# `const`/`enum`/`class_name`/`var`/`static var`; shell `nome() {` e `NOME=`; python
# `def nome(`/`class Nome`/`NOME =`. Shell e python só indexam atribuição MAIÚSCULA de
# propósito: em `.sh` uma atribuição minúscula de coluna zero é variável de loop, e
# doc que nomeia `checks` falando do `scripts/check_doc_drift.sh` não está citando a
# declaração dele. Arquivo sem modelo de identidade (`.md`, `.json`, `.tscn`, `.cfg`)
# devolve índice vazio e a régua fica inertes nele — inventar regra para formato que
# não tem declaração é a receita para a régua chorar lobo.
static func _SymbolSpans(lines : PackedStringArray, ext : String) -> Dictionary:
	var spans : Dictionary = {}
	if ext != "gd" and ext != "sh" and ext != "py":
		return spans
	var decls : Array = []
	for i in lines.size():
		var name : String = _SymbolNameAt(String(lines[i]), ext)
		if name == "":
			continue
		decls.append([name, i + 1])
	for k in decls.size():
		var nm : String = String(decls[k][0])
		var start : int = int(decls[k][1])
		var finish : int = lines.size()
		if k + 1 < decls.size():
			finish = int(decls[k + 1][1]) - 1
		if not spans.has(nm):
			spans[nm] = []
		(spans[nm] as Array).append([start, maxi(start, finish)])
	return spans

# Nome do símbolo declarado nesta linha de coluna zero, ou "" se a linha não declara.
static func _SymbolNameAt(line : String, ext : String) -> String:
	if line.begins_with(" ") or line.begins_with("\t"):
		return ""
	if ext == "gd":
		for prefix in ["static func ", "func ", "static var ", "const ", "class_name ", "enum ", "var "]:
			if not line.begins_with(prefix):
				continue
			var tok : String = _FirstToken(line.substr(prefix.length()).strip_edges())
			return tok if _IsIdent(tok) else ""
		return ""
	if ext == "sh":
		if line.begins_with("#"):
			return ""
		var fn : int = line.find("()")
		if fn > 0 and _IsIdent(line.substr(0, fn)):
			return line.substr(0, fn)
		var eq : int = line.find("=")
		if eq > 0:
			var nm : String = line.substr(0, eq).strip_edges()
			return nm if _IsUpperIdent(nm) else ""
		return ""
	if ext == "py":
		for prefix in ["async def ", "def ", "class "]:
			if line.begins_with(prefix):
				var tok : String = _FirstToken(line.substr(prefix.length()).strip_edges())
				return tok if _IsIdent(tok) else ""
		var eq : int = line.find("=")
		if eq > 0:
			var nm : String = line.substr(0, eq).strip_edges()
			return nm if _IsUpperIdent(nm) else ""
		return ""
	return ""

# Token até o primeiro separador de declaração (espaço, tab, `(`, `=`, `:`, `{`).
static func _FirstToken(rest : String) -> String:
	var out : String = ""
	for i in rest.length():
		var c : int = rest.unicode_at(i)
		if c == 32 or c == 9 or c == 40 or c == 61 or c == 58 or c == 123:
			break
		out += rest[i]
	return out

static func _IsIdent(name : String) -> bool:
	if name.is_empty():
		return false
	for i in name.length():
		var c : int = name.unicode_at(i)
		var ok : bool = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or (c >= 48 and c <= 57 and i > 0)
		if not ok:
			return false
	return true

# Identificador MAIÚSCULO de coluna zero (`EXPLICIT_HARNESSES="..."`, `ZONE_COUNT`),
# o único tipo de atribuição que doc cita como declaração em `.sh`/`.py`.
static func _IsUpperIdent(name : String) -> bool:
	if not _IsIdent(name):
		return false
	if name.unicode_at(0) < 65 or name.unicode_at(0) > 90:
		return false
	for i in name.length():
		var c : int = name.unicode_at(i)
		if c >= 97 and c <= 122:
			return false
	return true

# Devolve "" quando não há o que julgar: o símbolo nomeado não é declarado no arquivo
# que a prosa acabou de citar (a frase pode estar nomeando um membro de OUTRO arquivo,
# como um `WaitStats()` citado ao lado de um ponteiro para o servidor de métricas), e
# acusar nesse caso é a régua inventando falha. Fora isso, o intervalo citado tem que
# INTERSECTAR o span com a folga de ±2 da regra de mensagem: `to < início-2` ou
# `from > fim+2` é o ponteiro que mudou de dono. Intersectar (e não "estar contido") é
# o que permite a citação honesta de duas declarações vizinhas com um número só: a
# linha que monta a lista explícita e a função que descobre o resto, no `scripts/test.sh`.
# A exceção de USO é o que separa a mentira desta casa de uma frase legítima sobre
# fluxo: ponteiro para uma linha que CHAMA o símbolo nomeado mostra o símbolo, então
# não é acusação — sem essa exceção a régua gritaria com toda doc que explica um
# caminho de código apontando o call site. O que não vale é o call site inventado:
# linha que nem declara nem nomeia o símbolo não mostra nada do símbolo.
static func _IdentityDrift(spans : Dictionary, src : PackedStringArray, symName : String, from : int, to : int) -> String:
	if symName == "" or not spans.has(symName):
		return ""
	var first : Array = spans[symName][0]
	# `class_name` É o arquivo inteiro: quem nomeia a classe e cita qualquer linha dela
	# está certo por construção, e acusar isso é a régua brigar com o nome do próprio
	# módulo (caso medido na árvore: `Localizer` nomeado ao lado de um ponteiro para
	# dentro de Localizer.gd, e `NpcScript` idem).
	if String(src[int(first[0]) - 1]).strip_edges().begins_with("class_name "):
		return ""
	for spV in spans[symName]:
		var sp : Array = spV
		if to >= int(sp[0]) - 2 and from <= int(sp[1]) + 2:
			return ""
	if _SrcMentions(src, symName, from, to):
		return ""
	return "%d-%d não declara nem usa `%s`, declarado em %d-%d" % [from, to, symName, int(first[0]), int(first[1])]

# O nome aparece, como palavra, nas linhas citadas (com a mesma folga de ±2)?
static func _SrcMentions(src : PackedStringArray, symName : String, from : int, to : int) -> bool:
	for j in range(maxi(0, from - 3), mini(src.size(), to + 2)):
		if _MentionsWord(String(src[j]), symName):
			return true
	return false

static func _MentionsWord(text : String, name : String) -> bool:
	var at : int = text.find(name)
	while at >= 0:
		var leftOk : bool = at == 0 or not _IsIdentByte(text.unicode_at(at - 1))
		var nxt : int = at + name.length()
		var rightOk : bool = nxt >= text.length() or not _IsIdentByte(text.unicode_at(nxt))
		if leftOk and rightOk:
			return true
		at = text.find(name, at + 1)
	return false

# `unicode_at` devolve o codepoint, então a fronteira é medida por número, não por
# String: o `_IsIdentChar` do kernel recebe String e `allowDigit`, e uma função daqui
# com o mesmo nome não é sobrecarga — é assinatura conflitante com o pai.
static func _IsIdentByte(c : int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or (c >= 48 and c <= 57)

# Quantos caracteres separam dois pontos de leitura na doc, dobrando quebra de linha:
# é a medida da CLÁUSULA, não da linha. A régua de identidade só pode acusar um nome
# que a prosa amarru àquele ponteiro; numa linha de tabela com vinte símbolos e um
# número no fim, dezenove deles não estão em cláusula nenhuma daquele número, e
# tratá-los como se estivessem é a régua gritando com quem só listou o que existe.
static func _ClauseGap(docLines : PackedStringArray, l1 : int, c1 : int, l2 : int, c2 : int) -> int:
	if l1 == l2:
		return maxi(0, c2 - c1)
	var gap : int = maxi(0, String(docLines[l1]).length() - c1)
	for l in range(l1 + 1, l2):
		gap += String(docLines[l]).strip_edges().length()
	return gap + c2

# Distância entre um NOME e o PONTEIRO que ele poderia estar servindo, na geometria do
# `_OwnerPtr`: coluna pura quando os dois estão na mesma linha, ordem de leitura quando
# estão em linhas vizinhas. É a medida gêmea da régua: `_OwnerPtr` responde "de quem é
# este nome" e `_BindGap` responde "quão forte". Juntas elas implementam a única regra
# que faz sentido numa cláusula — um ponteiro serve a UM símbolo, o mais perto dele.
# Sem isso, `SkillAllowed()` dita duas frases antes de `TeachSkill` era julgado pelo
# número de `TeachSkill`, e a régua acusava uma menção correta como se fosse citação.
static func _BindGap(docLines : PackedStringArray, ptrLine : int, ptrStart : int, ptrEnd : int,
		nameLine : int, nameStart : int, nameEnd : int) -> int:
	if ptrLine == nameLine:
		return absi(nameStart - ptrStart)
	if ptrLine < nameLine:
		return _ClauseGap(docLines, ptrLine, ptrEnd, nameLine, nameStart)
	return _ClauseGap(docLines, nameLine, nameEnd, ptrLine, ptrStart)

# A separação mais forte de cláusula que o markdown produz é o FIM DE PARÁGRAFO: em
# `.md` duas linhas contíguas são uma frase só, e uma linha em branco é dois assuntos.
# Por isso a janela de ±2 linhas da regra de mensagem não pode virar janela de
# parágrafo: nome citado três parágrafos acima de um ponteiro não está sendo
# localizado por aquele ponteiro. Em arquivo de código o análogo é o comentário
# contíguo — bloco de `#` colado é uma frase, separado por linha vazia é outro assunto.
static func _ParaGap(docLines : PackedStringArray, l1 : int, l2 : int) -> int:
	var saltos : int = 0
	for l in range(mini(l1, l2) + 1, maxi(l1, l2)):
		if String(docLines[l]).strip_edges() == "":
			saltos += 1
	return saltos

# Nome com FORMA de declaração que o arquivo só declara com OUTRA grafia de caixa. É a
# família do defeito achado no CSV de interface (`Key,en,pt_BR` escrito onde o arquivo
# tem `keys,en,pt_BR`): a linha existe, é cheia, e a régua de resolução aprova — o que
# mente é a identidade. Só julga forma de definição (`nome()`, `enum nome`, `const
# nome`) porque uma palavra minúscula solta na prosa é menção, não citação de
# declaração. E fica em silêncio quando o arquivo usa a grafia escrita em algum lugar:
# aí a palavra é outra coisa (uma API, um campo), não um erro de caixa.
static func _IdentityShapeDrift(spans : Dictionary, src : PackedStringArray, symName : String, defShape : bool) -> String:
	if not defShape or symName == "" or spans.has(symName):
		return ""
	if _MentionsWord("\n".join(src), symName):
		return ""
	for keyV in spans.keys():
		var key : String = String(keyV)
		if key.to_lower() == symName.to_lower():
			return "prosa nomeia `%s`, o arquivo declara `%s` (caixa não é identidade)" % [symName, key]
	return ""

# Veredito da régua de série: três saídas e só elas.
#   "dentro" — o arquivo emite a série e uma das linhas citadas a contém;
#   "fora"   — o arquivo emite a série em alguma linha, mas NENHUMA das citadas a
#              contém: é a frase que aponta para o arquivo certo e a janela errada,
#              o resto do intervalo está cheio e legível, então nenhuma outra régua
#              deste arquivo teria como saber;
#   "muda"   — o arquivo não emite aquela série em lugar nenhum. Aqui a régua CALA:
#              uma frase pode nomear `shambleta_foo` ao citar a migration que cria a
#              tabela, o alerta que consome a série ou o `SQL.gd` que conta a espera.
#              Acusar isso seria transformar a régua em máquina de reescrever prosa.
static func _SeriesSpanVerdict(src : PackedStringArray, serie : String, from : int, to : int) -> String:
	if serie == "" or src.is_empty():
		return "muda"
	var emite : bool = false
	for j in src.size():
		if String(src[j]).contains(serie):
			emite = true
			break
	if not emite:
		return "muda"
	for j in range(maxi(from, 1), mini(to, src.size()) + 1):
		if String(src[j - 1]).contains(serie):
			return "dentro"
	return "fora"

# Casa única do veredito de identidade (regra 6): laço da varredura e controles
# injetados em memória chamam este mesmo corpo, então uma mentira inventada mede a
# régua exata com que a doc real é medida — não uma cópia dela.
# Os três braços, e só eles:
# (a) o nome É declarado no arquivo -> o intervalo tem que tocar o span (ou a linha
#     citada tem que mostrar o nome, que é o caso do call site honesto);
# (b) o nome não é declarado mas tem FORMA de declaração e o arquivo inteiro não tem
#     aquela palavra -> SÍMBOLO FANTASMA. É o buraco que o juiz cego de 2026-09-28
#     provou: a linha citada existe, é cheia, a régua de resolução aprova, e a frase
#     afirma que ali está `Foo()` quando o arquivo nunca viu esse nome. Sem este
#     braço a identidade só mordida onde já havia declaração, e ponteiro para corpo
#     alheio com nome inexistente continuava "conferido";
# (c) o nome não é declarado, tem outra grafia no arquivo -> caixa não é identidade.
static func _IdentityVerdict(spans : Dictionary, src : PackedStringArray, symName : String,
		shape : String, from : int, to : int, cited : String) -> String:
	if symName == "":
		return ""
	if spans.has(symName):
		return _IdentityDrift(spans, src, symName, from, to)
	if _SpanHasDefShape(shape):
		if _MentionsWord(String("\n").join(src), symName):
			return ""
		return "%d-%d cita `%s` como evidência e `%s` não declara nem menciona esse nome — não há o que abrir no número citado" % [from, to, symName, cited]
	return _IdentityShapeDrift(spans, src, symName, _SpanHasDefShape(shape))

# Vínculo nome -> ponteiro e veredito, num corpus de prosa dado. O laço da varredura
# tem a mesma forma; o que está aqui em cima é a decisão, que é o que os controles
# precisam dividir com a régua. Devolve as acusações no formato da varredura.
static func _IdentityJudgeCorpus(docLines : PackedStringArray, src : PackedStringArray,
		symSpans : Dictionary, tag : String, tally : Dictionary) -> Array[String]:
	var out : Array[String] = []
	var ptrRx : RegEx = RegEx.new()
	ptrRx.compile("`([A-Za-z0-9_./-]+\\.(?:gd|py|sh|yml|json|sql|csv|cfg|godot|tscn|md)):(\\d+)(?:-(\\d+))?`")
	var symRx : RegEx = RegEx.new()
	symRx.compile("`([^`]+)`")
	var recs : Array = []
	for p in docLines.size():
		for pm in ptrRx.search_all(String(docLines[p])):
			recs.append([p, pm.get_start(), pm.get_end()])
	for i in docLines.size():
		var matches : Array[RegExMatch] = ptrRx.search_all(String(docLines[i]))
		for m in matches:
			var from : int = int(m.get_string(2))
			var to : int = int(m.get_string(3))
			if to < from:
				to = from
			var served : Array = _ServedName(docLines, symRx, recs, i, m, true)
			if served.is_empty():
				continue
			tally["judged"] = int(tally.get("judged", 0)) + 1
			var verdict : String = _IdentityVerdict(symSpans, src, String(served[1]), String(served[0]), from, to, tag)
			if verdict != "":
				out.append("%s → %s" % [tag, verdict])
	return out


# O nome que a cláusula deste ponteiro SERVE: de todos os nomes que `_OwnerPtr` declara
# deste ponteiro, o mais perto dele. É a metade que falta ao vínculo — sem ela dois nomes
# da mesma frase caem no mesmo número, e o que a prosa não estava localizando é julgado
# como se estivesse. Foi assim que `SkillAllowed()`, dito duas frases antes do `TeachSkill`
# que o número localizava, virou acusação.
# A fronteira de frase é a segunda metade: `Network.gd` `_init()`: eles **foram
# removidos**, e a razão está escrita no fonte — `FSM.gd:41-47` tem `_init` a 47
# caracteres do número de `FSM`, mas separados por DOIS PONTOS e um TRAVESSÃO. A janela
# de 140 caracteres não distingue os dois casos porque eles estão realmente perto; o
# que os distingue é que a frase de `_init()` já fechou antes do ponteiro começar.
static func _ServedName(docLines : PackedStringArray, symRx : RegEx, recs : Array,
		ptrLine : int, m : RegExMatch, isMd : bool) -> Array:
	var best : Array = []
	var bestGap : int = 1000000000
	for wl in range(maxi(0, ptrLine - 2), mini(docLines.size(), ptrLine + 3)):
		var wLine : String = String(docLines[wl])
		# A janela de um `.md` é prosa inteira; em arquivo de código só o comentário fala
		# de evidência, e o corpo da função nomeia coisas que ninguém escreveu como citação.
		if not isMd and not wLine.strip_edges().begins_with("#"):
			continue
		for sm in symRx.search_all(wLine):
			var shape : String = String(sm.get_string(1))
			var symName : String = _SymOfSpan(shape)
			if symName == "":
				continue
			var owner : Array = _OwnerPtr(recs, docLines, wl, sm.get_start())
			if owner.is_empty() or int(owner[0]) != ptrLine or int(owner[1]) != int(m.get_start()):
				continue
			if _CrossesSentence(docLines, ptrLine, m.get_start(), m.get_end(),
					wl, sm.get_start(), sm.get_end()):
				continue
			var gap : int = _BindGap(docLines, ptrLine, m.get_start(), m.get_end(), wl, sm.get_start(), sm.get_end())
			if gap < bestGap:
				bestGap = gap
				best = [shape, symName]
	return best


# Entre dois pontos de leitura da doc, tem fim de frase por fora de backticks? São
# fronteira `.`, `:`, `;`, `!`, `?` e o travessão FOLLOWED de espaço (ou fim de linha):
# `Util.PrintLog` e um caminho de arquivo não abrem frase nova, e o texto dentro de
# backticks é símbolo, não prosa. Mede do FIM do item mais cedo ao COMEÇO do mais tarde,
# na mesma ordem de leitura do `_BindGap`.
static func _CrossesSentence(docLines : PackedStringArray, lA : int, sA : int, eA : int,
		lB : int, sB : int, eB : int) -> bool:
	var fromL : int = lA
	var fromC : int = eA
	var toL : int = lB
	var toC : int = sB
	if lB < lA or (lB == lA and sB < sA):
		fromL = lB
		fromC = eB
		toL = lA
		toC = sA
	var seg : String = ""
	if fromL == toL:
		seg = String(docLines[fromL]).substr(fromC, maxi(0, toC - fromC))
	else:
		seg = String(docLines[fromL]).substr(fromC) + "\n"
		for l in range(fromL + 1, toL):
			seg += String(docLines[l]) + "\n"
		seg += String(docLines[toL]).substr(0, toC)
	var inTick : bool = false
	for idx in seg.length():
		var ch : String = String(seg[idx])
		if ch == "`":
			inTick = not inTick
			continue
		if inTick or ch == "\n":
			continue
		if ch == ";" or ch == "!" or ch == "?" or ch == "—":
			return true
		if ch == "." or ch == ":":
			var nxt : String = " "
			if idx + 1 < seg.length():
				nxt = String(seg[idx + 1])
			if nxt == " " or nxt == "\n":
				return true
	return false

# Conteúdo entre backticks -> nome de símbolo citado, ou "". Uma cláusula só pode
# apontar para UM símbolo, então o qualificador é resolvido pelo último segmento:
# `SQL.QueryMutexWaitSeconds()` -> `QueryMutexWaitSeconds`, `FarmZoneData.MapBackedNames`
# -> `MapBackedNames`. Isso também descarta o `class_name` do próprio arquivo citando
# linha de outro lugar (`NetworkCommons.ServerAddress` aponta para o membro, não para a
# linha 2 do arquivo). Caminho com extensão, glob, `$`, espaço ou dois-pontos não é
# nome de símbolo.
static func _SymOfSpan(content : String) -> String:
	var s : String = content.strip_edges()
	if s.is_empty() or s.length() > 64:
		return ""
	if s.contains("/") or s.contains("*") or s.contains("$") or s.contains(":") or s.contains("|"):
		return ""
	for kw in ["static func ", "func ", "static var ", "const ", "enum ", "class_name ", "var ", "def ", "class "]:
		if s.begins_with(kw):
			s = s.substr(kw.length()).strip_edges()
			break
	var par : int = s.find("(")
	if par >= 0:
		s = s.substr(0, par).strip_edges()
	if s.ends_with("."):
		return ""
	# Nome de ARQUIVO entre backticks (`gut_runner.gd`, `README.md`) tem ponto, mas o
	# último segmento é extensão, não membro: sem este filtro a palavra `gd` viraria
	# símbolo citado e a régua acusaria prosa que só nomeia um arquivo.
	const exts : PackedStringArray = ["gd", "gdshader", "py", "sh", "md", "markdown", "json",
			"yml", "yaml", "sql", "csv", "cfg", "godot", "tscn", "tres", "res", "tmx", "txt",
			"ini", "toml", "js", "ts", "css", "html", "env", "xml", "csv"]
	if s.contains(".") and exts.has(s.substr(s.rfind(".") + 1).to_lower()):
		return ""
	if s.contains("."):
		s = s.substr(s.rfind(".") + 1)
	if s.contains(" ") or not _IsIdent(s):
		return ""
	return s

static func _SpanHasDefShape(content : String) -> bool:
	var s : String = content.strip_edges()
	for kw in ["static func ", "func ", "static var ", "const ", "enum ", "class_name ", "var ", "def ", "class "]:
		if s.begins_with(kw):
			return true
	return s.find("(") >= 0

# Dono de um nome entre backticks: o ponteiro de arquivo e linha mais próximo na ordem
# de leitura, a no máximo duas linhas dele. O vínculo tem DIREÇÃO porque os dois
# sentidos da prosa são legítimos — o nome pode vir depois do número que o localiza,
# ou antes dele, na frase que abre a citação. Sem direção, um nome dito DEPOIS de um
# ponteiro seria julgado pelo ponteiro SEGUINTE, da frase vizinha, que é exatamente
# como a régua passaria a acusar citação correta. Na mesma linha do nome vale o
# ponteiro mais perto em coluna; em linha vizinha vale a MESMA janela de cláusula
# medida em caracteres (`_ClauseGap`), com empate decidido pelo posterior — o formato
# dominante desta documentação é nomear e depois localizar.
static func _OwnerPtr(ptrRecs : Array, docLines : PackedStringArray, line : int, col : int) -> Array:
	# A CLÁUSULA é a unidade, não a linha. Numa bala de changelog de 2.000 caracteres com
	# cinco ponteiros, "o ponteiro mais próximo da linha" amarra `SUM` e `enqueue` — que a
	# frase usa sobre SQL e companion — ao único ponteiro de teste que aparece 1.500
	# caracteres antes, e a régua passa a acusar menção como se fosse citação. Duas
	# condições: distância de cláusula e nenhum outro ponteiro entre o nome e ele.
	# 140 caracteres: um nome e seu ponteiro vivem na mesma cláusula quando escritos
	# na forma deste repo — ``Foo`` (`arquivo.gd:12-30`) são ~40.
	var clauseWindow : int = 140
	var best : Array = []
	var bestDist : int = clauseWindow + 1
	var ownLineHasPtr : bool = false
	for rec in ptrRecs:
		if int(rec[0]) != line:
			continue
		ownLineHasPtr = true
		var d : int = absi(int(rec[1]) - col)
		if d >= bestDist or d > clauseWindow:
			continue
		# Entre o nome e este ponteiro tem outro ponteiro? então o nome não é deste.
		var lo : int = mini(col, int(rec[1]))
		var hi : int = maxi(col, int(rec[1]))
		var encruza : bool = false
		for other in ptrRecs:
			if int(other[0]) == line and int(other[1]) > lo and int(other[1]) < hi:
				encruza = true
				break
		if encruza:
			continue
		bestDist = d
		best = rec
	if not best.is_empty():
		return best
	if ownLineHasPtr:
		# A linha própria já tem ponteiros e nenhum deles é da cláusula deste nome: a
		# frase não está citando evidência de linha nenhuma, e caçar um ponteiro de outra
		# linha seria inventar o vínculo que a régua vai julgar.
		return []
	# Linha vizinha: a distância NÃO se mede em linhas. Uma bala de changelog de 1.700
	# caracteres tem nome e ponteiro a 800 caracteres um do outro E em linhas adjacentes,
	# porque o markdown quebra a frase onde quer. Aqui foi exatamente assim que `Transaction`
	# e `SUM` — ditos na bala da passada de segurança — caíram no ponteiro de teste da bala
	# de cima. Mede-se em ordem de leitura, pela geometria: o que sobra da linha do mais
	# cedo, mais as linhas do meio, mais o que precede o mais tarde. A mesma janela de
	# cláusula vale, e o mesmo veto — outro ponteiro no caminho não é da frase.
	var near : Array = []
	var nearGap : int = clauseWindow + 1
	var nearAfter : bool = false
	for recV in ptrRecs:
		var rec : Array = recV
		var pl : int = int(rec[0])
		if absi(pl - line) > 2:
			continue
		var gap : int = 0
		if pl < line:
			gap = _ClauseGap(docLines, pl, int(rec[2]), line, col)
		else:
			gap = _ClauseGap(docLines, line, col, pl, int(rec[1]))
		if gap > clauseWindow:
			continue
		var blocked : bool = false
		for other in ptrRecs:
			var ol : int = int(other[0])
			var oc : int = int(other[1])
			if pl < line:
				if (ol > pl and ol < line) or (ol == pl and oc > int(rec[2])) or (ol == line and oc < col):
					blocked = true
					break
			elif ol > line and ol < pl:
				blocked = true
				break
			elif ol == line and oc > col:
				blocked = true
				break
			elif ol == pl and oc < int(rec[1]):
				blocked = true
				break
		if blocked:
			continue
		if gap < nearGap or (gap == nearGap and pl > line and not nearAfter):
			near = rec
			nearGap = gap
			nearAfter = pl > line
	return near




# Toda `*.md` que o projeto mantém, com o mesmo critério de exclusão do walk de
# código: diretório escondido (`.godot`, `.git`, `.test-home`), vendor em `addons/` e o
# depósito de registros mortos em `archive/`. `graphify-out/` sai também, e por outro
# motivo: é saída de ferramenta, regravada por outro processo, `gitignore`ada e já
# excluída do pacote (`export_presets.cfg`, `exclude_filter`). Não é documentação que
# alguém mantenha, e um número de linha dela vem do snapshot do dia em que o gráfico foi
# gerado — a régua puniria o run por algo que nenhum autor escreveu.
# Derivar da árvore é o ponto — uma lista escrita à mão aqui é exatamente a doc que
# grava número: `README.md` e as quatro `docs/adding-*.md` (o primeiro arquivo que um
# contribuidor novo abre) ficaram de fora da régua de ponteiros enquanto ela existiu, e
# nada avisou.
static func _MdFilesAll() -> Array[String]:
	var skipped : Array[String] = ["addons", "archive", "graphify-out"]
	var found : Array[String] = []
	var stack : Array[String] = ["res://"]
	while not stack.is_empty():
		var current : String = stack.pop_back()
		var dir : DirAccess = DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var fname : String = dir.get_next()
		while fname != "":
			var full : String = current.path_join(fname)
			if dir.current_is_dir():
				if not fname.begins_with(".") and not skipped.has(fname):
					stack.append(full)
			elif fname.ends_with(".md"):
				found.append(full)
			fname = dir.get_next()
		dir.list_dir_end()
	found.sort()
	return found

# Os mesmos ponteiros de evidência moram também em comentário de código, e até
# esta passada a varredura lia só `.md`. O custo de ler isso provado na própria
# rodada: `EconomyBaseCatalog.gd` apontava os knobs de troca para
# `EconomyService.gd:208/209/212` quando o assento estava em `:174/175/178` havia
# um fatiamento, e `Peers.gd` se autodata em linhas que o próprio corte tinha
# apagado. Nenhum portão disse nada porque nenhum portão olhava comentário de
# código. Varredura ampliada para os quatro diretórios mantidos, e só linha de
# comentário — corpo de função não é prosa de evidência.
static func _CommentFilesAll() -> Array[String]:
	var skipped : Array[String] = ["addons", "archive", "graphify-out"]
	var exts : Array[String] = [".gd", ".py", ".sh"]
	var roots : Array[String] = ["res://sources", "res://tests", "res://scripts", "res://companion"]
	var found : Array[String] = []
	var stack : Array[String] = roots.duplicate()
	while not stack.is_empty():
		var current : String = stack.pop_back()
		var dir : DirAccess = DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var fname : String = dir.get_next()
		while fname != "":
			var full : String = current.path_join(fname)
			if dir.current_is_dir():
				if not fname.begins_with(".") and not skipped.has(fname):
					stack.append(full)
			elif exts.has("." + fname.get_extension().to_lower()):
				found.append(full)
			fname = dir.get_next()
		dir.list_dir_end()
	found.sort()
	return found

# A mensagem de um check é o ÚLTIMO literal de linha. `Check(src.contains("SetupTwoFactor"), "…")`
# tem um identificador no meio e o rótulo no fim, e foi isso que mordeu quando a janela da regra (3)
# abriu: com ±2 linha, dois nomes de método viraram "mensagem de check" (`SetupTwoFactor`, achado em
# `IdleTests.gd:5485`, e `GetGuildForAccount`, em `GuildService.gd:68`) sem que nenhuma citação
# verdadeira tivesse sido ganha. Recortar pelo rótulo é o que permite a janela maior: ela passa a
# alcançar a citação que a frase separa do ponteiro, e o corte devolve o sinal que a janela sozinha
# não tem.
static func _LabelOf(line : String) -> String:
	var last : String = ""
	var i : int = 0
	while i < line.length():
		if String(line[i]) != "\"":
			i += 1
			continue
		var j : int = line.find("\"", i + 1)
		if j < 0:
			break
		last = line.substr(i + 1, j - i - 1)
		i = j + 1
	return last

# Ponteiros de evidência da documentação do beta. O §24, o handoff de lançamento e o roadmap citam
# `arquivo:linha` como prova de cada item — e linha derrapa sozinha quando o código muda de
# tamanho. Medido na passada que abriu esta régua: nove ponteiros do próprio documento de auditoria
# apontavam para outro lugar (oito com número errado, um com o caminho trocado — um `Peers.gd` citado
# sem o diretório, que hoje resolve pelo sufixo único), e um caía numa suíte diferente da que a prosa
# nomeava. Os números daquela varredura moram no documento de auditoria, não aqui: esta casa é
# comentário de ferramenta, e um `arquivo:linha` escrito nela viraria evidência falsa no run
# seguinte. A checagem é quíntupla: (1) o arquivo citado existe e a linha citada cabe nele; (2)
# nenhuma das duas bordas do intervalo cai em linha em branco; (3) se a prosa das duas linhas de cada
# lado cita uma mensagem de check entre aspas, e essa frase é o rótulo (último literal) de alguma linha
# do arquivo, ela tem que cair no intervalo citado; (4) todo `Suite*` citado tem que ser `func` real;
# (5) quando a MESMA linha da prosa nomeia a suíte e dá o número, o número tem que cair dentro do span daquela
# `func` — é o que faltava para um ponteiro continuar "resolvido" depois de um fatiamento que moveu a
# suíte, que é exatamente como o da vitrine honesta sobrevou mudo. Mensagem que não existe no
# arquivo é prosa, não citação de teste, e fica fora de propósito. Só o que está entre backticks
# conta na regra de linha: sem isso, `127.0.0.1:8901` viraria caminho de arquivo. E (6) IDENTIDADE
# de símbolo para QUALQUER arquivo de código e QUALQUER declaração de coluna zero: todo nome entre
# backticks da cláusula — amarrado ao ponteiro que vem depois dele na leitura, com a janela de ±2
# linhas — tem que ser declarado no arquivo citado e o intervalo citado tem que tocar o span dele.
# É a regra que a passada do juiz de 2026-09-28 provou que faltava: com (5) exigindo nome e número
# na MESMA linha, um `harnesses_extra()` dito numa linha e o número na linha de baixo passava verde
# sendo que as duas linhas citadas eram o corpo de `gate()`, e um `enum BackupFrequency` dito ao
# lado de um número que caía num comentário de poda de ledger também. Números reais desses casos
# moram nos documentos que a varredura julga, não aqui: esta casa é comentário de ferramenta, e um
# ponteiro escrito nela viraria evidência falsa no run seguinte.
func SuiteEvidencePointers() -> void:
	print("[suite] ponteiros de evidência")
	var ptrRx : RegEx = RegEx.new()
	ptrRx.compile("`([A-Za-z0-9_./-]+\\.(?:gd|py|sh|yml|json|sql|csv|cfg|godot|tscn|md)):(\\d+)(?:-(\\d+))?`")
	var msgRx : RegEx = RegEx.new()
	msgRx.compile("\"([^\"]{12,90})\"")
	# `CheckBox.new(` não é check de teste: a âncora exige chamada `Check…(`.
	var checkRx : RegEx = RegEx.new()
	checkRx.compile("\\bCheck[A-Za-z]*\\(")
	# A lista é derivada da árvore (`_MdFilesAll`), não escrita aqui. O que ficou de
	# fora é só o que a própria suíte de código já exclui: vendor e o depósito de
	# registros mortos. Uma lista à mão foi o formato até 2026-09-27 e ela envelheceu
	# mais rápido que a documentação — as `docs/adding-*.md`, que são exatamente o
	# caminho de entrada de quem chega novo, nunca foram conferidas.
	var docs : Array[String] = _MdFilesAll()
	if not Check(docs.size() >= 30 and docs.has("res://README.md")
			and docs.has("res://docs/development/testing.md")
			and docs.has("res://deploy/ROLLBACK.md"),
			"varredura acha a doc que a régua tem que ler: %d arquivos .md, com README, testing.md e ROLLBACK.md" % docs.size()):
		return
	# A varredura ampliada tem o mesmo guard da lista de `.md`: uma régua que para
	# de achar arquivo de código passa a dizer "0 falhas" por não olhar nada, que é
	# o defeito que este suite existe para denunciar. O número é baixo de propósito
	# — são os quatro diretórios mantidos; folga para um fatiamento não virar falha
	# de régua, e um `roots` errado continua sendo falha.
	var codeDocs : Array[String] = _CommentFilesAll()
	if not Check(codeDocs.size() >= 100,
			"varredura acha os arquivos de código cujo comentário a régua ampliada promete ler: %d" % codeDocs.size()):
		return
	var sweep : Array[String] = []
	sweep.append_array(docs)
	sweep.append_array(codeDocs)
	var lineCache : Dictionary = {}
	var spanCache : Dictionary = {}
	var symCache : Dictionary = {}
	var quebrados : Array[String] = []
	var derrapados : Array[String] = []
	var vazios : Array[String] = []
	var deslocados : Array[String] = []
	var identes : Array[String] = []
	var metricosFora : Array[String] = []
	var metricos : int = 0
	var conferidos : int = 0
	var conferidosCode : int = 0
	var comMensagem : int = 0
	var comSuite : int = 0
	var comIdentidade : int = 0
	# Nome de suíte em backticks NA MESMA LINHA do ponteiro: é a forma como a prosa deste repo
	# amarra as duas coisas ("`SuiteRefund` (`tests/IdleTests.gd:7686-7758`)"). Olhar a linha e
	# não a janela evita puxar nome de um parágrafo vizinho.
	var suiteRx : RegEx = RegEx.new()
	suiteRx.compile("`Suite[A-Za-z0-9_]+`")
	# Regra (6): todo conteúdo entre backticks da cláusula é candidato a nome de símbolo;
	# `_SymOfSpan` decide o que é nome e o que é caminho, glob ou frase solta.
	var symRx : RegEx = RegEx.new()
	symRx.compile("`([^`]+)`")
	# Série de métrica é o outro tipo de nome que a prosa de runbook enumera, e não é
	# identificador de código: `MetricsBody()` cobre o intervalo inteiro como função,
	# então a régua de identidade não tem como saber que a série citada na frase não
	# está naquelas linhas. O prefixo é o da casa (`shambleta_*` em todo o /metrics),
	# aplicado como padrão e não como lista de nomes — lista à mão apodrece no dia em
	# que entra uma série nova.
	var metRx : RegEx = RegEx.new()
	if metRx.compile("(shambleta_[a-z0-9_]+)") != OK:
		Check(false, "o padrão de série de métrica compila")
		return
	for docPath in sweep:
		var isMd : bool = String(docPath).get_extension().to_lower() == "md"
		var docRaw : String = _RepoFile(docPath)
		if not Check(docRaw != "", "evidência: %s existe e lê" % docPath):
			continue
		var docLines : PackedStringArray = docRaw.split("\n")
		# Passagem 1 da doc: onde mora cada ponteiro, em ordem de leitura. É o que permite
		# amarrar um nome ao ponteiro que a prosa dele acabou de abrir ("`harnesses_extra()`,
		# o número embaixo") sem amarrá-lo ao ponteiro da frase anterior ou da vizinha —
		# que é justamente como a régua não vira máquina de acusar citação correta.
		var ptrRecs : Array = []
		for p in docLines.size():
			var pLine : String = String(docLines[p])
			if not isMd and not pLine.strip_edges().begins_with("#"):
				continue
			for pm in ptrRx.search_all(pLine):
				ptrRecs.append([p, pm.get_start(), pm.get_end()])
		for i in docLines.size():
			var ptrLine : String = String(docLines[i])
			# Em arquivo de código só comentário é prosa de evidência: o corpo da
			# função pode conter um shape `x.gd:12` que ninguém escreveu como prova.
			if not isMd and not ptrLine.strip_edges().begins_with("#"):
				continue
			var matches : Array[RegExMatch] = ptrRx.search_all(ptrLine)
			if matches.is_empty():
				continue
			var window : String = ""
			for w in range(maxi(0, i - 2), mini(docLines.size(), i + 3)):
				window += String(docLines[w]) + "\n"
			for m in matches:
				var cited : String = String(m.get_string(1))
				var resPath : String = _PtrResolve(cited)
				if resPath == "":
					continue
				# O SÍTIO abre a mensagem: sem `arquivo:linha` de quem cita, a régua devolve
				# uma acusação verdadeira e não editável — quem corrige teria de caçar a frase.
				var site : String = "%s:%d" % [String(docPath).trim_prefix("res://"), i + 1]
				if not lineCache.has(resPath):
					lineCache[resPath] = _RepoFile(resPath).split("\n")
				var src : PackedStringArray = lineCache[resPath]
				var from : int = int(m.get_string(2))
				var to : int = int(m.get_string(3))
				if to < from:
					to = from
				conferidos += 1
				if not isMd:
					conferidosCode += 1
				if from > src.size() or to > src.size():
					quebrados.append("%s: %s:%d (%s tem %d linhas)" % [site, cited, to, resPath, src.size()])
					continue
				if _LineBlank(src, from):
					vazios.append("%s: %s → %s:%d está em branco" % [site, cited, resPath, from])
					continue
				if _LineBlank(src, to):
					vazios.append("%s: %s → %s:%d está em branco" % [site, cited, resPath, to])
					continue
				# (5) Nome + número na mesma linha: o número tem que estar dentro da suíte nomeada.
				var named : String = ""
				var nm : RegExMatch = suiteRx.search(ptrLine)
				if nm != null:
					named = String(nm.get_string(0)).trim_prefix("`").trim_suffix("`")
				if named != "" and String(resPath).get_extension().to_lower() == "gd":
					if not spanCache.has(resPath):
						spanCache[resPath] = _FnSpans(src)
					comSuite += 1
					var drift : String = _SpanDrift(spanCache[resPath], named, from, to)
					if drift != "":
						deslocados.append("%s: %s → %s" % [site, cited, drift])
				# (6) IDENTIDADE: o símbolo que a cláusula deste ponteiro serve tem que estar
				# declarado no arquivo citado e o intervalo citado tem que tocar o span dele.
				# O vínculo é feito em duas metades: `_OwnerPtr` diz a quem um nome pertence
				# (direção da prosa, teto de cláusula em caracteres, nenhum ponteiro no meio)
				# e `_ServedName` devolve, dentre os nomes daquele ponteiro, o mais perto dele
				# — um número localiza UM símbolo, e o nome dito a 60 caracteres de distância
				# quando o vizinho está a 8 não é o que a frase estava procurando.
				var symExt : String = String(resPath).get_extension().to_lower()
				if symExt == "gd" or symExt == "sh" or symExt == "py":
					if not symCache.has(resPath):
						symCache[resPath] = _SymbolSpans(src, symExt)
					var symSpans : Dictionary = symCache[resPath]
					if not symSpans.is_empty():
						var served : Array = _ServedName(docLines, symRx, ptrRecs, i, m, isMd)
						if not served.is_empty():
							var symName : String = String(served[1])
							if symSpans.has(symName):
								comIdentidade += 1
							var idrift : String = _IdentityVerdict(symSpans, src, symName, String(served[0]), from, to, cited)
							if idrift != "":
								identes.append("%s: %s → %s" % [site, cited, idrift])
				# (7) SÉRIE NOMEADA × ARQUIVO QUE A EMITE. Um ponteiro pode jurar que a
				# linha `X.gd:A-B` é onde `shambleta_foo` é emitida sem nomear símbolo de
				# código nenhum — e a régua de identidade, que julga identificadores
				# declarados, passa adiante: `MetricsBody()` mora em `:114` e cobre o
				# intervalo inteiro, então "está no corpo" era verdade mesmo quando o
				# intervalo citando `:197-216` já não continha a série que a frase
				# enumerava. Aqui o nome é LIDO da linha que cita e conferido no intervalo
				# citado, com uma condição para não acusar prosa inocente: só julga quando
				# o arquivo alvo EMITE a série em alguma linha. Sem essa trava, "a série
				# aparece na frase" viraria acusação contra qualquer `.gd` que a frase só
				# menciona de passagem. Não confunde elisão (`..._over_1ms`) com nome:
				# elisão não é nome, e a régua não inventa o que a frase cortou.
				for metMatch : RegExMatch in metRx.search_all(ptrLine):
					# O vínculo série -> ponteiro passa pela MESMA casa da régua de identidade
					# (`_OwnerPtr`): sem ele, todo nome da linha é julgado contra todo ponteiro
					# da linha, e a frase que amarra uma lista de séries a UM ponteiro acusa os
					# outros. Julgar por posse é a mesma disciplina que fez a regra (6) parar de
					# acusar citação correta.
					var ownSerie : Array = _OwnerPtr(ptrRecs, docLines, i, metMatch.get_start())
					if ownSerie.is_empty() or int(ownSerie[1]) != int(m.get_start()):
						continue
					var serie : String = String(metMatch.get_string(1))
					var verdictSerie : String = _SeriesSpanVerdict(src, serie, from, to)
					if verdictSerie == "fora":
						metricos += 1
						metricosFora.append("%s: %s → `%s` é emitida em %s mas não nas linhas %d-%d" % [site, cited, serie, resPath, from, to])
					elif verdictSerie == "dentro":
						metricos += 1
				for msgMatch in msgRx.search_all(window):
					var msg : String = String(msgMatch.get_string(1))
					if msg.find("/") >= 0 or msg.find("res://") >= 0:
						continue
					# A regra só vale para citação de *mensagem de check*: em arquivo de código, o
					# hit tem que ser uma linha de `Check…` com a frase no posto do RÓTULO (o último
					# literal da linha). Sem o rótulo, a janela ampliada confunde identificador com
					# mensagem — os dois falsos positivos medidos estão no comentário de `_LabelOf`.
					# Em `.md` a citação é prosa sobre prosa, então vale o match solto.
					var prosa : bool = cited.get_extension().to_lower() == "md"
					var hit : int = 0
					for j in src.size():
						var srcLine : String = String(src[j])
						if srcLine.find(msg) < 0:
							continue
						if not prosa and (checkRx.search(srcLine) == null or _LabelOf(srcLine) != msg):
							continue
						hit = j + 1
						break
					if hit == 0:
						continue
					comMensagem += 1
					if hit < from - 2 or hit > to + 2:
						derrapados.append("%s: %s:%d-%d cita \"%s\", que está em :%d" % [site, cited, from, to, msg, hit])
	CheckEq(quebrados.size(), 0, "ponteiros: %d referências arquivo:linha conferidas, nenhuma fora do arquivo (%s)" % [conferidos, " | ".join(quebrados)])
	CheckEq(vazios.size(), 0, "ponteiros: nenhuma das %d referências cai em linha em branco — ponteiro em branco não mostra nada para quem abre no número citado (%s)" % [conferidos, " | ".join(vazios)])
	CheckEq(derrapados.size(), 0, "ponteiros: %d mensagens de check citadas na prosa batem com a linha indicada (%s)" % [comMensagem, " | ".join(derrapados)])
	CheckEq(deslocados.size(), 0, "ponteiros: %d citações que nomeiam uma suíte e dão o número caem dentro do span dela (%s)" % [comSuite, " | ".join(deslocados)])
	CheckEq(identes.size(), 0, "ponteiros: %d citações que nomeiam um símbolo caem no span daquele símbolo (ou numa linha que o usa) — e não no corpo de um vizinho (%s)" % [comIdentidade, " | ".join(identes)])
	# A régua nova só vale se estiver de fato olhando: quatro é o mínimo dos ponteiros que
	# hoje nomeiam suíte (handoff da vitrine, e os três do documento de auditoria do beta).
	# Com `comSuite` em zero o comparador estaria verde por não achar com o que comparar.
	Check(comSuite >= 4, "ponteiros: %d citações com nome de suíte na mesma linha do número foram julgadas pelo span" % comSuite)
	# A ampliação para comentário de código só vale se ela estiver de fato olhando
	# alguma coisa: um `_CommentFilesAll()` mudo, ou um filtro de `#` que não casa
	# com os quatro diretórios, devolve "0 quebrados" pelo pior motivo possível. O
	# comparador em si já tem prova de que morde (nove ponteiros apodrecidos foi o
	# que ele achou na doc na rodada em que entrou); o que é novo aqui é a entrada,
	# então é a entrada que este check mede.
	Check(conferidosCode >= 20, "ponteiros: %d de %d referências vieram de comentário de código, não só de `.md` — a varredura ampliada está olhando" % [conferidosCode, conferidos])
	# Prova de que as duas réguas novas mordem, no mesmo formato do guard de entrada (uma
	# comparação que nunca viu o caso que descreve é uma comparação que pode estar errada em
	# silêncio). Usado dado do repo, não fixture inventado: a linha 3 de `LauncherCommons.gd`
	# é o vão entre `class_name` e `# Project`, e `network/server/Peers.gd` não existe como
	# caminho mas termina num único arquivo da árvore — era o tipo de ponteiro que o `find("/")`
	# antigo devolvia como "não sei" e nem chegava a ser julgado.
	var blankProbe : PackedStringArray = _RepoFile("res://sources/launcher/LauncherCommons.gd").split("\n")
	Check(_LineBlank(blankProbe, 3), "detector morde no branco: LauncherCommons.gd:3 é o vão depois de `class_name`")
	Check(not _LineBlank(blankProbe, 2), "detector não morde no conteúdo: LauncherCommons.gd:2 é `class_name LauncherCommons`")
	Check(_PtrResolve("network/server/Peers.gd") == "res://sources/network/server/Peers.gd",
			"ponteiro de caminho errado passa a ser julgado: `network/server/Peers.gd` resolve pelo sufixo único (devolveu \"%s\")" % _PtrResolve("network/server/Peers.gd"))
	# O mesmo para a régua de span, medida no próprio arquivo: conter-se é o caso vero, e
	# uma linha antes do `func` é o caso que tem que acusar — sem os dois, "0 deslocados"
	# pode significar apenas que a comparação não sabe comparar.
	var spanProbe : Dictionary = _FnSpans(_RepoFile("res://tests/IdleTestsFrontier.gd").split("\n"))
	var selfSpan : Array = spanProbe.get("SuiteEvidencePointers", [])
	Check(selfSpan.size() == 2 and _SpanDrift(spanProbe, "SuiteEvidencePointers", int(selfSpan[0]), int(selfSpan[1])) == "",
			"régua de span morde no certo: `SuiteEvidencePointers` cabe no span derivado de si (%s)" % str(selfSpan))
	Check(selfSpan.size() == 2 and _SpanDrift(spanProbe, "SuiteEvidencePointers", int(selfSpan[0]) - 1, int(selfSpan[0]) - 1) != "",
			"régua de span morde no errado: número uma linha antes do `func` é fora do span")
	# E o recorte do rótulo, nos dois casos, medido em linha real da árvore (achada pelo próprio
	# conteúdo, não por número: o número é justamente o que drifta). `SetupTwoFactor` aparece numa
	# linha de `Check` de `IdleTests.gd` como identificador no meio da expressão — é o falso positivo
	# que a janela ±2 trouxe; `c1: permission da vítima inalterada` é citação de check verdadeira.
	var labelSrc : PackedStringArray = _RepoFile("res://tests/IdleTests.gd").split("\n")
	var labelFalse : int = 0
	var labelTrue : int = 0
	for j in labelSrc.size():
		var lj : String = String(labelSrc[j])
		if labelFalse == 0 and lj.contains("SetupTwoFactor") and checkRx.search(lj) != null:
			labelFalse = j + 1
		if labelTrue == 0 and lj.contains("\"c1: permission da vítima inalterada\"") and checkRx.search(lj) != null:
			labelTrue = j + 1
	Check(labelFalse != 0 and _LabelOf(String(labelSrc[labelFalse - 1])) != "SetupTwoFactor",
			"recorte do rótulo devolve o identificador: a linha %d tem `SetupTwoFactor` no meio, não no rótulo" % labelFalse)
	Check(labelTrue != 0 and _LabelOf(String(labelSrc[labelTrue - 1])) == "c1: permission da vítima inalterada",
			"recorte do rótulo pega a mensagem verdadeira: a linha %d é o check citado pela prosa" % labelTrue)
	# (6) Identidade de símbolo, mordendo nos três formatos de falsidade que a passada do
	# juiz de 2026-09-28 deixou passar, e no positivo — uma régua sem control positivo é a
	# máquina de acusar citação correta que o header desta casa proíbe. Os números são
	# DERIVADOS do conteúdo (achados pelo próprio `_SymbolSpans`), nunca escritos aqui: o
	# que drifta é justamente a linha.
	var shSrc : PackedStringArray = _RepoFile("res://scripts/test.sh").split("\n")
	var shSpans : Dictionary = _SymbolSpans(shSrc, "sh")
	var heList : Array = shSpans.get("harnesses_extra", [])
	var heStart : int = int(heList[0][0]) if heList.size() > 0 else 0
	var heEnd : int = int(heList[0][1]) if heList.size() > 0 else 0
	var corpoAlheio : int = 0
	var candidatos : Array = []
	# O corpo alheio tem que ser alheio de fato: `harness_marker` é declarado depois de
	# `harnesses_extra` e o corpo de quem a CHAMA (`gate_all`, :234) também usa o nome —
	# olhar só a linha de abertura do span escolhia exatamente esse corpo, e o control
	# passou a falhar por causa de um número que andou, não por causa da régua.
	for keyV in shSpans.keys():
		for spV in (shSpans[keyV] as Array):
			var sp : Array = spV
			if int(sp[0]) <= heEnd + 3:
				continue
			var usa : bool = String(shSrc[int(sp[0]) - 1]).find("harnesses_extra") >= 0
			var k : int = int(sp[0]) - 1
			while not usa and k < mini(int(sp[1]), shSrc.size()):
				if String(shSrc[k]).find("harnesses_extra") >= 0:
					usa = true
				k += 1
			if not usa:
				candidatos.append(int(sp[0]))
	candidatos.sort()
	if candidatos.size() > 0:
		corpoAlheio = int(candidatos[0])
	Check(heStart > 0 and corpoAlheio > 0 and _IdentityDrift(shSpans, shSrc, "harnesses_extra", corpoAlheio, corpoAlheio) != "",
			"identidade morde no corpo alheio: `%s` declara `harnesses_extra()`? não — span é %d-%d e a linha %d é outro símbolo (err: \"%s\")" % ["scripts/test.sh", heStart, heEnd, corpoAlheio, _IdentityDrift(shSpans, shSrc, "harnesses_extra", corpoAlheio, corpoAlheio)])
	# Positivo: a linha que CHAMA `harnesses_extra` é evidência honesta do símbolo, embora
	# não seja a declaração dele. É o formato de frase mais comum desta documentação e a
	# régua que o acusa passa a chorar lobo em todo run.
	var uso : int = 0
	for s in shSrc.size():
		if String(shSrc[s]).contains("harnesses_extra"):
			uso = s + 1
			break
	Check(uso > 0 and _IdentityDrift(shSpans, shSrc, "harnesses_extra", uso, uso) == "",
			"identidade não morde no call site: a linha %d usa `harnesses_extra` sem declará-lo e a prosa que aponta para ela está certa (err: \"%s\")" % [uso, _IdentityDrift(shSpans, shSrc, "harnesses_extra", uso, uso)])
	var sqlcSrc : PackedStringArray = _RepoFile("res://sources/sql/SQLCommons.gd").split("\n")
	var sqlcSpans : Dictionary = _SymbolSpans(sqlcSrc, "gd")
	var bfList : Array = sqlcSpans.get("BackupFrequency", [])
	var bfStart : int = int(bfList[0][0]) if bfList.size() > 0 else 0
	Check(bfStart > 5 and _IdentityDrift(sqlcSpans, sqlcSrc, "BackupFrequency", bfStart - 5, bfStart - 5) != "",
			"identidade morde no enum longe do número: `enum BackupFrequency` declarado em %d, citado cinco linhas acima (err: \"%s\")" % [bfStart, _IdentityDrift(sqlcSpans, sqlcSrc, "BackupFrequency", bfStart - 5, bfStart - 5)])
	Check(bfStart > 0 and _IdentityDrift(sqlcSpans, sqlcSrc, "BackupFrequency", bfStart, bfStart) == "",
			"identidade morde no certo: o `enum BackupFrequency` cai no próprio número %d" % bfStart)
	# Caixa não é identidade: a família do `Key,en,pt_BR` escrito onde o arquivo tem
	# `keys,en,pt_BR`. Aqui medido na declaração real mais parecida da árvore.
	Check(_IdentityShapeDrift(sqlcSpans, sqlcSrc, _SymOfSpan("enum backupfrequency"), _SpanHasDefShape("enum backupfrequency")) != "",
			"identidade morde na grafia errada: `enum backupfrequency` não é o que o arquivo declara")
	Check(_IdentityShapeDrift(sqlcSpans, sqlcSrc, _SymOfSpan("enum BackupFrequency"), _SpanHasDefShape("enum BackupFrequency")) == "",
			"identidade não morde na grafia certa: `enum BackupFrequency` é o que o arquivo declara")
	# O vínculo nome→ponteiro tem direção e tem teto: nome sem ponteiro próximo, ou
	# ponteiro de outra frase, não é julgado. Medido numa tabela própria, porque aqui o
	# que se prova é a aritmética do vínculo, não um fato da árvore. Os tetos são dois —
	# distância de linha E distância de cláusula — e cada um tem a sua mentira: o nome a
	# quatro linhas (`Epsilon`) e o nome a 880 caracteres na bala longa (`Delta`), que é
	# exatamente como `Transaction` e `SUM` da bala de segurança caíram no ponteiro da
	# bala de cima antes deste teto existir.
	var linkLines : PackedStringArray = PackedStringArray([
		"",
		"",
		"          `x.gd:1-9` abre a frase e nomeia `Gamma()` depois",
		"",
		"",
		"    `Alpha()`",
		"   `x.gd:20-29` fecha a frase",
		"",
		"          `x.gd:40-49`" + "".rpad(878, "b"),
		"  `Delta()`",
		"",
		"",
		"  `Epsilon()`",
	])
	var linkRecs : Array = [[2, 10, 20], [6, 3, 15], [8, 10, 22]]
	var ownAfter : Array = _OwnerPtr(linkRecs, linkLines, 2, 40)
	var ownBefore : Array = _OwnerPtr(linkRecs, linkLines, 5, 4)
	var ownLonge : Array = _OwnerPtr(linkRecs, linkLines, 12, 2)
	var ownComprido : Array = _OwnerPtr(linkRecs, linkLines, 9, 2)
	Check(ownAfter.size() == 3 and int(ownAfter[0]) == 2 and int(ownAfter[1]) == 10,
			"vínculo pega o ponteiro da mesma frase quando o nome vem depois dele")
	Check(ownBefore.size() == 3 and int(ownBefore[0]) == 6 and int(ownBefore[1]) == 3,
			"vínculo pega o ponteiro que vem depois do nome, na linha seguinte")
	Check(ownLonge.is_empty(), "vínculo não inventa dono: nome a mais de duas linhas de qualquer ponteiro fica fora da regra")
	Check(ownComprido.is_empty(),
			"vínculo não inventa dono na bala longa: `Delta` está a 880 caracteres do ponteiro da linha de cima, e proximidade de linha não é cláusula")
	# (3) Nome de suíte. A prosa do beta afirma "coberto por `SuiteX`", e nome que não é `func`
	# na árvore é exatamente a classe de defeito que já foi achado nesta auditoria (documentação
	# descrevendo teste inexistente). Diferente de número de linha, nome não drifta com edição.
	# A coleta varre `tests/` inteiro, não só este arquivo: as suítes que vivem em harness
	# próprio (`*_test.gd` descoberto por `scripts/test.sh`) são tão reais quanto as daqui, e
	# chamá-las de fantasma seria a régua inventando falha.
	var nameRx : RegEx = RegEx.new()
	nameRx.compile("\\b(Suite[A-Za-z0-9_]+)\\b")
	var defRx : RegEx = RegEx.new()
	defRx.compile("(?m)^(static )?func (Suite[A-Za-z0-9_]+)\\(")
	var definidas : Dictionary = {}
	for testFile in _GdFilesUnder("res://tests"):
		for d in defRx.search_all(_RepoFile(String(testFile))):
			definidas[String(d.get_string(2))] = true
	var citadas : Dictionary = {}
	var fantasmas : Array[String] = []
	for docPath in docs:
		for n in nameRx.search_all(_RepoFile(docPath)):
			var nome : String = String(n.get_string(1))
			if citadas.has(nome):
				continue
			citadas[nome] = true
			if not definidas.has(nome):
				fantasmas.append(nome)
	CheckEq(fantasmas.size(), 0, "ponteiros: %d nomes de suíte citados na documentação existem como `func` em algum arquivo de tests/ (%s)" % [citadas.size(), " | ".join(fantasmas)])
	# (7) MENTIRAS INJETADAS EM MEMÓRIA. As réguas acima mordem dado REAL da árvore, o
	# que prova que não estão inertes — mas não prova que pegariam uma mentira nova,
	# porque a árvore pode simplesmente não conter o caso até a mentira acontecer. Aqui
	# o caso é escrito à mão, num fonte que não existe em disco (`_PtrResolve` abaixo
	# prova que ele não resolve), e passa pela MESMA decisão (`_IdentityVerdict`, pelo
	# mesmo vínculo `_OwnerPtr`) que julga a doc real. Cada classe vem com o seu par
	# honesto: a mentira acusa, a verdade silencia. Sem o par, "acusou" pode ser só a
	# régua gritando com tudo — e é o par que diz que o que mudou foi a frase, não o céu.
	var witnessBefore : String = _RepoFile("res://scripts/test.sh")
	var lieSrc : PackedStringArray = PackedStringArray([
		"class_name LieProbe",		# 1
		"",							# 2
		"func Alpha() -> void:",	# 3
		"\tvar guard : int = 1",	# 4
		"\tvar slot : int = 2",		# 5
		"\tvar tick : int = 3",		# 6
		"\tvar hold : int = 4",		# 7
		"",							# 8
		"func Beta() -> void:",		# 9
		"\tvar zeta : int = 5",		# 10
		"\tvar zetaMore : int = 6",	# 11
		"\tvar zTail : int = 7",	# 12
		"\tvar zLast : int = 8",	# 13
		"const ZetaLocked : int = 3",	# 14
		"",							# 15
		"func Gamma() -> void:",	# 16
		"\tvar other : int = 9",	# 17
	])
	var lieSpans : Dictionary = _SymbolSpans(lieSrc, "gd")
	var lieTally : Dictionary = {}
	# Classe A — linha que existe, é cheia, e não é o que a frase afirma: `ZetaLocked`
	# dito na linha 5, que é o corpo de `Alpha()`, com o `const` a nove linhas dali.
	var aLie : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`ZetaLocked` trava o teto (`probe_lie.gd:5`).",
	]), lieSrc, lieSpans, "probe_lie.gd:5", lieTally)
	var aTruth : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Alpha()` abre a conta (`probe_lie.gd:5`).",
	]), lieSrc, lieSpans, "probe_lie.gd:5", lieTally)
	# Classe B — nomeia `Foo()` numa linha dentro de `Bar()`: a forma que a régua de
	# resolução aprova de olhos fechados, porque a linha citada existe e é conteúdo.
	var bLie : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Beta()` soma o slot (`probe_lie.gd:6`).",
	]), lieSrc, lieSpans, "probe_lie.gd:6", lieTally)
	var bTruth : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Alpha()` soma o slot (`probe_lie.gd:6`).",
	]), lieSrc, lieSpans, "probe_lie.gd:6", lieTally)
	# Classe C — token citado AUSENTE do arquivo: `Theta()` como evidência de um fonte
	# que nunca escreve essa palavra. Nenhum span, nenhuma menção: nada no número
	# citado mostra o que a frase diz.
	var cLie : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Theta()` fecha o lote (`probe_lie.gd:10`).",
	]), lieSrc, lieSpans, "probe_lie.gd:10", lieTally)
	var cTruth : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Beta()` fecha o lote (`probe_lie.gd:10`).",
	]), lieSrc, lieSpans, "probe_lie.gd:10", lieTally)
	# Classe D — FRONTEIRA DE FRASE. O mesmo `ZetaLocked()` à mesma distância do mesmo
	# número, só que separado por dois-pontos: é a forma exata de
	# `docs/development/debugging.md`, que diz "não procure `_init()` em `Network.gd`: a
	# razão está escrita em `FSM.gd:41-47`". Sem o veto, o `_init()` da frase fechada era
	# julgado pelo número da frase seguinte e a régua acusava citação correta.
	# O número é 4, não 17: `ZetaLocked` é `const` na linha 14 e o span dele termina em
	# 15, então a folga de ±2 da própria régua cobre 17 por construção. Mentira alguma
	# pode morar dentro da folga da régua que se quer medir.
	var dBind : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`ZetaLocked()` some do número (`probe_lie.gd:4`).",
	]), lieSrc, lieSpans, "probe_lie.gd:4", lieTally)
	var dVeto : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`ZetaLocked()`: a frase fechou, e o número vem depois (`probe_lie.gd:4`).",
	]), lieSrc, lieSpans, "probe_lie.gd:4", lieTally)
	# Classe E — UM PONTEIRO, UM NOME. Dos dois nomes ditos antes do mesmo número, o
	# mais perto é o que a cláusula localiza; o outro é prosa vizinha. É a metade que
	# faltava: foi assim que `SkillAllowed()`, duas frases antes do `TeachSkill` que o
	# número procurava, virou acusação.
	var eOne : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`Theta()` não é o mais perto, `Beta()` é (`probe_lie.gd:3`).",
	]), lieSrc, lieSpans, "probe_lie.gd:3", lieTally)
	var eTruth : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`ZetaLocked()` mora em (`probe_lie.gd:14`).",
	]), lieSrc, lieSpans, "probe_lie.gd:14", lieTally)
	Check(_PtrResolve("probe_lie.gd") == "",
			"a mentira injetada nunca toca o disco: `probe_lie.gd` não resolve em `%s`" % _PtrResolve("probe_lie.gd"))
	CheckEq(aLie.size(), 1, "mentira injetada A (linha cheia e alheia) produz [FAIL] na régua: %s" % " | ".join(aLie))
	CheckEq(bLie.size(), 1, "mentira injetada B (`Beta()` dito dentro de `Alpha()`) produz [FAIL] na régua: %s" % " | ".join(bLie))
	CheckEq(cLie.size(), 1, "mentira injetada C (token ausente do arquivo) produz [FAIL] na régua: %s" % " | ".join(cLie))
	CheckEq(aTruth.size(), 0, "a mesma forma, dita verdadeira, não acusa (A): %s" % " | ".join(aTruth))
	CheckEq(bTruth.size(), 0, "a mesma forma, dita verdadeira, não acusa (B): %s" % " | ".join(bTruth))
	CheckEq(cTruth.size(), 0, "a mesma forma, dita verdadeira, não acusa (C): %s" % " | ".join(cTruth))
	# D e E são o par das duas metades novas do vínculo: a fronteira de frase e o teto de
	# um nome por ponteiro. Cada uma tem a mentira que morde e o silêncio que prova que
	# foi a regra que mudou, não o céu.
	CheckEq(dBind.size(), 1, "sem fronteira de frase, o nome a 40 caracteres do número É julgado (D): %s" % " | ".join(dBind))
	CheckEq(dVeto.size(), 0,
			"com dois-pontos no meio, a frase do nome fechou antes do ponteiro e a régua cala (D): %s" % " | ".join(dVeto))
	Check(eOne.size() == 1 and eOne[0].contains("Beta"),
			"dos dois nomes da mesma cláusula, o mais perto do número é o SERVIDO, e o outro fica fora: %s" % " | ".join(eOne))
	CheckEq(eTruth.size(), 0, "a mesma forma, dita verdadeira, não acusa (E): %s" % " | ".join(eTruth))
	# A acusação é mecânica: nomeia o símbolo e o número, não descreve o humor da régua.
	Check(aLie.size() == 1 and aLie[0].contains("ZetaLocked") and aLie[0].contains("5"),
			"mentira A é detectada pelo símbolo e pela linha: %s" % " | ".join(aLie))
	Check(bLie.size() == 1 and bLie[0].contains("Beta") and bLie[0].contains("6"),
			"mentira B é detectada pelo símbolo e pela linha: %s" % " | ".join(bLie))
	Check(cLie.size() == 1 and cLie[0].contains("Theta"),
			"mentira C é detectada pelo token ausente: %s" % " | ".join(cLie))
	# O par mentiroso/verdadeiro por classe é o control de mutação: se a régua acusasse
	# as duas, ela não estaria medindo a frase. E o injetado tem que chegar à decisão:
	# nove nomes apresentados, no mínimo, senão os seis checks acima julgaram o vazio.
	Check(int(lieTally.get("judged", 0)) >= 6,
			"controles injetados apresentam %d nomes à régua de identidade (A/B/C, mentira e verdade)" % int(lieTally.get("judged", 0)))
	Check(_RepoFile("res://scripts/test.sh") == witnessBefore and witnessBefore.length() > 0,
			"bloco injeta em memória só: `scripts/test.sh` relido depois dos controles é byte-idêntico (%d bytes)" % witnessBefore.length())
	# Cobertura no log: "0 falhas" sozinho não diz o quanto foi olhado, que é exatamente a
	# classe de problema que este guard veio fechar. O piso é TETO AO CONTRÁRIO: declara o
	# mínimo que esta casa sabe que a varredura entrega, e foi recalibrado quando `_OwnerPtr`
	# passou a julgar a CLÁUSULA e não a linha inteira — bala de changelog de 2.000 caracteres
	# com cinco ponteiros amarrava `SUM`/`enqueue`/`Transaction` ao ponteiro de teste mais
	# próximo, e esses 56 vínculos inventados contavam como "cobertura". Medido depois do
	# aperto: 111 nomes julgados em 445 referências.
	# Segunda recalibração, 2026-09-28: o UNIVERSO encolheu (tests/ e a doc morta saíram do
	# pacote julgado, e o que ficou foi 243 referências) e o vínculo ganhou duas regras que
	# retiram julgamento falso — um ponteiro serve UM nome, e frase fechada não é julgada
	# pelo número da frase seguinte. 53 nomes em 243 referências é o medido de hoje, e a
	# proporção (22%) é a que sobreviveu ao aperto: 111/445 era 25%. Por isso o piso passa a
	# ser dois checks — o absoluto, que não deixa a varredura emudecer, e a fração (1 em 5),
	# que não deixa um piso absoluto velho virar falha só porque a doc encolheu.
	Check(comIdentidade >= 50,
			"ponteiros: %d de %d referências tiveram um símbolo nomeado julgado pela régua de identidade — sem isso, \"0 acusações\" pode significar só que a doc não nomeou nada" % [comIdentidade, conferidos])
	Check(comIdentidade * 5 >= conferidos,
			"ponteiros: %d de %d referências julgadas pela régua de identidade é pelo menos um quinto do que ela olha — abaixo disso a mordida medida é do tamanho do que a prosa deixou dizer" % [comIdentidade, conferidos])
	print("  [info] ponteiros: %d referências arquivo:linha (%d em comentário de código), %d com mensagem de check na prosa, %d com suíte nomeada na mesma linha, %d com símbolo nomeado na cláusula, %d nomes de suíte, %d pares (série, intervalo) julgados" % [conferidos, conferidosCode, comMensagem, comSuite, comIdentidade, citadas.size(), metricos])

	# ---------------------------------------------------------------- régua de série (7)
	# O veredito do que a régua achou na doc do beta, e o piso do que ela julgou: "0
	# fora" com 0 pares julgados é a MESMA frase que "0 fora" com 40, então o número
	# julgado é check, não enfeite.
	CheckEq(metricosFora.size(), 0,
			"ponteiros: toda série nomeada na cláusula aparece no intervalo do arquivo que a emite (%s)" % " | ".join(metricosFora))
	Check(metricos >= 3,
			"ponteiros: %d pares (série, intervalo) julgados pela régua de série — abaixo disso ela está muda e o \"0 fora\" não é prova" % metricos)
	# Controle derivado do arquivo, não de número copiado: acha a linha onde a série é
	# emitida, inocenta o intervalo que a contém e acusa o que termina uma linha antes.
	# Sem isto, a regra (7) pode estar sempre dizendo "dentro" — e é exatamente o que
	# ela dizia antes de existir, só que por não existir.
	var witness : PackedStringArray = _RepoFile("res://sources/system/MetricsServer.gd").split("\n")
	var hitSerie : int = 0
	for w in witness.size():
		if String(witness[w]).contains("shambleta_sql_query_mutex_waits"):
			hitSerie = w + 1
			break
	Check(hitSerie > 1, "o controle acha a linha (%d) onde `shambleta_sql_query_mutex_waits` é emitida" % hitSerie)
	Check(hitSerie <= 1 or _SeriesSpanVerdict(witness, "shambleta_sql_query_mutex_waits", hitSerie, hitSerie) == "dentro",
			"controle: o intervalo que CONTÉM a emissão é inocentado")
	Check(hitSerie <= 1 or _SeriesSpanVerdict(witness, "shambleta_sql_query_mutex_waits", 1, hitSerie - 1) == "fora",
			"controle: o mesmo par, com o intervalo cortando uma linha antes, é acusado")
	Check(_SeriesSpanVerdict(witness, "shambleta_serie_que_nenhum_arquivo_emite", 1, witness.size()) == "muda",
			"controle: série que o arquivo não emite em lugar nenhum não é julgada — é a trava que impede acusar prosa inocente")

# Régua de citação de harness — audita o PAR doc↔gate nos dois sentidos.
#
# Por que ela existe: `gut_runner.gd` é o precedente registrado (imprimia
# "1193 testes" e foi apagado; `archive/AUDITORIA_SHAMBLETA.md:110` conta o caso).
# A doença não era o harness mentir sozinho — era ninguém ter como saber que o
# resto da doc acreditava nele. Duas metades, e cada uma mente de um jeito:
#
#  (a) harness que o gate roda SEM linha na tabela de `testing.md` → ele existe e
#      corre, mas quem chega não sabe o que ele apura, e o próximo a refatorar o
#      caminho que ele cobre não sabe que vai acordar;
#  (b) linha na tabela (ou citação `tests/<nome>.gd` na prosa) nomeando harness que o
#      gate NÃO roda, ou arquivo que NÃO existe → a doc promete uma prova que não
#      acontece. É o `gut_runner` em forma de frase, e foi exatamente o que a
#      rodada cega de 2026-09-28 achou em `sources/economy/GuildRoster.gd`: dois
#      cabeçalhos amarrando a régua a `guild_roster_test.gd`, arquivo que
#      nunca existiu. A promessa forte ("impede o mapa de virar decoração") estava
#      lá; o instrumento, não.
#
# O que o gate roda é DERIVADO de `scripts/test.sh` (a lista explícita + o padrão
# de autodescoberta), não copiado para cá: uma lista copiada é um espelho, e
# espelho continua verde quando o CI muda. `tests/` real é lido do diretório pelo
# mesmo motivo. Os dois controles injetados provam que cada acusação saberia
# acusar — sem eles, "0 órfãos" e "0 fantasmas" são a mesma frase que sai de uma
# varredura que não olhou nada.
func SuiteHarnessCitations() -> void:
	print("[suite] citação de harness")
	var shSrc : String = _RepoFile("res://scripts/test.sh")
	if not Check(shSrc.length() > 2000, "`scripts/test.sh` foi lido para derivar o que o gate roda (%d bytes)" % shSrc.length()):
		return
	# (1) Lista explícita do script — o mesmo `EXPLICIT_HARNESSES` que `all` consome.
	var explRx : RegEx = RegEx.new()
	var discRx : RegEx = RegEx.new()
	var citeRx : RegEx = RegEx.new()
	var rowRx : RegEx = RegEx.new()
	if explRx.compile("EXPLICIT_HARNESSES=\"([^\"]*)\"") != OK \
			or discRx.compile("tests/\\*_([a-z]+)\\.gd") != OK \
			or citeRx.compile("tests/([A-Za-z0-9_]+\\.gd)") != OK \
			or rowRx.compile("(?m)^\\|[[:space:]]*`([a-z][a-z0-9_]+)`[[:space:]]*\\|") != OK:
		Check(false, "os quatro padrões da régua de harness compilam")
		return
	var expl : Dictionary = {}
	for tok : String in String(explRx.search(shSrc).get_string(1)).split(" "):
		if tok.strip_edges() != "":
			expl[tok.strip_edges()] = true
	Check(expl.size() >= 5, "a lista explícita do gate é lida de verdade: %d harnesses" % expl.size())
	# (2) Autodescoberta: `harnesses_extra()` roda `tests/*_test.gd` e `tests/*_fuzz.gd`.
	#     O sufixo é LIDO do próprio script (o padrão acima extrai `test`/`fuzz`), não
	#     redigitado aqui — se um dia entra um terceiro sufixo no glob, a régua tem que
	#     acompanhar sem que alguém lembre de mexer nesta suíte.
	var sufixos : Array[String] = []
	for m : RegExMatch in discRx.search_all(shSrc):
		var sfx : String = String(m.get_string(1))
		if not sufixos.has(sfx):
			sufixos.append(sfx)
	if not Check(sufixos.size() >= 2, "os sufixos autodescobertos são lidos do glob do script: %s" % " ".join(sufixos)):
		return
	var discovered : Dictionary = {}
	var realFiles : Dictionary = {}
	var dir : DirAccess = DirAccess.open("res://tests")
	if not Check(dir != null, "`res://tests` abre para listagem"):
		return
	dir.list_dir_begin()
	var fname : String = dir.get_next()
	while fname != "":
		if fname.ends_with(".gd"):
			realFiles[fname] = true
			for sfx : String in sufixos:
				if fname.ends_with("_" + sfx + ".gd") and not expl.has(fname.trim_suffix(".gd")):
					discovered[fname.trim_suffix(".gd")] = true
		fname = dir.get_next()
	dir.list_dir_end()
	# (3) Quem só é alcançado por tabela: `run_idle_tests` carrega kernel e folha.
	#     Valem como alvo da regra de fantasma (6) e contam como "roda" para a regra
	#     de linha (5), mas não precisam de linha própria na tabela: a linha de
	#     `run_idle_tests` é a que os nomeia, e exigir linha de um arquivo que é
	#     metade de outro harness seria inventar um gate que não existe.
	var carregados : Dictionary = {}
	var wrapper : String = _RepoFile("res://tests/run_idle_tests.gd")
	for m : RegExMatch in citeRx.search_all(wrapper):
		var base2 : String = String(m.get_string(1))
		if realFiles.has(base2):
			carregados[base2.trim_suffix(".gd")] = true
	Check(carregados.size() >= 2,
			"a derivação vê o runner carregar kernel e folha: %d harnesses carregados" % carregados.size())
	var direto : Dictionary = {}
	for k : String in expl:
		direto[k] = true
	for k : String in discovered:
		direto[k] = true
	var alcancados : Dictionary = direto.duplicate()
	for k : String in carregados:
		alcancados[k] = true
	Check(direto.size() >= 50,
			"o universo derivado é o gate inteiro: %d invocados direto (%d por nome + %d por padrão) e %d alcancados no total" % [direto.size(), expl.size(), discovered.size(), alcancados.size()])

	# (4) Metade (a): todo harness que o gate roda é NOMEADO em `testing.md`. O
	#     predicado é "o nome aparece na doc", não "tem linha na primeira coluna":
	#     `IdleTests` e `IdleTestsFrontier` são nomeados dentro da linha de
	#     `run_idle_tests`, e o que importa para quem chega é poder descobrir que o
	#     arquivo existe e o que ele apura — não a geometria da tabela.
	var testingSrc : String = _RepoFile("res://docs/development/testing.md")
	if not Check(testingSrc.length() > 2000, "`docs/development/testing.md` foi lida (%d bytes)" % testingSrc.length()):
		return
	var rows : Dictionary = {}
	for m : RegExMatch in rowRx.search_all(testingSrc):
		rows[String(m.get_string(1))] = true
	Check(rows.size() >= 50, "a tabela de harnesses tem %d linhas — abaixo disso a régua julgaria uma tabela que não existe" % rows.size())
	var anonimados : Array[String] = []
	for k : String in direto:
		if not testingSrc.contains(k):
			anonimados.append(k)
	anonimados.sort()
	CheckEq(anonimados.size(), 0, "todo harness que o gate roda é nomeado em `testing.md` (%s)" % " | ".join(anonimados))

	# (5) Metade (b) na tabela: nenhuma linha nomeia coisa que o gate não roda.
	var linhasFalsas : Array[String] = []
	for k : String in rows:
		if not alcancados.has(k):
			linhasFalsas.append(k)
	linhasFalsas.sort()
	CheckEq(linhasFalsas.size(), 0, "nenhuma linha da tabela nomeia harness que o gate não roda (%s)" % " | ".join(linhasFalsas))

	# (6) Metade (b) na prosa: toda citação `tests/<nome>.gd` fora de `archive/` nomeia
	#     arquivo que existe. `archive/` está fora por construção do `_MdFilesAll()` e do
	#     `_CommentFilesAll()` — lá dentro a frase descreve o que ERA (o próprio registro
	#     do `gut_runner` apagado mora ali), e confundi-la com mentira seria apagar o
	#     histórico para calar a régua.
	var sweep : Array[String] = []
	sweep.append_array(_MdFilesAll())
	sweep.append_array(_CommentFilesAll())
	if not Check(sweep.size() >= 180, "a varredura de prosa lê %d arquivos — a régua julga a doc e o comentário, não só uma tabela" % sweep.size()):
		return
	var citados : Dictionary = {}
	var fantasmas : Array[String] = []
	for path in sweep:
		var src : String = _RepoFile(String(path))
		for m : RegExMatch in citeRx.search_all(src):
			var base : String = String(m.get_string(1))
			citados[base] = true
			if not realFiles.has(base):
				fantasmas.append("%s → tests/%s" % [String(path).trim_prefix("res://"), base])
	fantasmas.sort()
	Check(citados.size() >= 40, "a prosa cita %d harnesses diferentes — censo baixo demais para a acusação de fantasma significar algo" % citados.size())
	CheckEq(fantasmas.size(), 0, "nenhuma citação de harness na prosa nomeia arquivo inexistente (%s)" % " | ".join(fantasmas))

	# (7) Controles: as três réguas acima têm que acusar o que foi plantado. Sem isto,
	#     cada `0` pode ser uma varredura muda — que é o defeito que esta suíte existe
	#     para denunciar, e a rodada cega de 2026-09-28 já viu régua com esse formato.
	#     Cada controle vem em par: o nome falso tem que ser acusado e um nome verdadeiro
	#     tem que sair limpo, senão "acusou" pode ser só um predicado que acusa tudo.
	var plantado : String = "harness_que_nao_existe_gd.gd"
	var verdadeiro : String = "reason_toast_test.gd"
	Check(not realFiles.has(plantado), "controle: o nome plantado realmente não existe em `tests/`")
	Check(realFiles.has(verdadeiro), "controle: o nome verdadeiro do par existe em `tests/` (senão o par abaixo não significa nada)")
	var acusouFalso : bool = false
	var acusouVerdadeiro : bool = false
	for m : RegExMatch in citeRx.search_all("ver `tests/" + plantado + "` e `tests/" + verdadeiro + "`"):
		var citedBase : String = String(m.get_string(1))
		# O PREDICADO de acusão é `not realFiles.has(...)`. Um controle que marca
		# "acusado" só porque o nome apareceu no texto julga menção, não a régua — e
		# aí o par falso/verdadeiro perde o sentido (o nome verdadeiro "acusaria"
		# sempre, e o controle viraria a própria falha que denuncia).
		var acusado : bool = not realFiles.has(citedBase)
		if acusado and citedBase == plantado:
			acusouFalso = true
		if acusado and citedBase == verdadeiro:
			acusouVerdadeiro = true
	Check(acusouFalso, "controle de fantasma: o mesmo predicado acusa o nome plantado")
	Check(not acusouVerdadeiro, "controle de fantasma: o mesmo predicado NÃO acusa um harness que existe — a régua varre %d harnesses reais e os trata como existentes" % realFiles.size())
	Check(rowRx.search_all("| `" + plantado.trim_suffix(".gd") + "` | x |\n").size() == 1,
			"controle de linha: o mesmo predicado lê uma linha plantada na tabela")
	Check(not alcancados.has(plantado.trim_suffix(".gd")),
			"controle de linha: o nome plantado não está no conjunto alcançado — é isto que faz a regra (5) poder acusar")
	Check(not testingSrc.contains(plantado.trim_suffix(".gd")) and testingSrc.contains(verdadeiro.trim_suffix(".gd")),
			"controle de nomeação: `testing.md` contém o harness verdadeiro e não contém o plantado — é o par que faz a regra (4) poder acusar")
	print("  [info] harness: %d invocados direto, %d linhas na tabela, %d harnesses citados na prosa de %d arquivos" % [direto.size(), rows.size(), citados.size(), sweep.size()])

# Navegação externa no export Web. O beta roda no navegador, e no navegador
# `OS.shell_open` não leva a URL para lugar nenhum — por isso a porta do dinheiro
# (`Checkout.gd`, `_launch_payment_url`) faz `window.open` por `JavaScriptBridge` quando
# `LauncherCommons.isWeb`. O outro sítio que navega para fora é o clique de link dentro do
# texto do ACEITE (`Scrollable.gd`, o painel que o gate de idade obriga o jogador a ler
# antes de marcar a caixa de 18+), que chamava `OS.shell_open` cru. Um terceiro — o botão
# do Discord em `Gui.gd` — saiu do jogo em 2026-09-25 junto da ponte e do addon, porque o
# endereço horneado em `LauncherCommons` era o do upstream de que o projeto fez fork e o
# projeto não tem servidor próprio. A régua é por BLOCO e varre `sources/`
# inteira, não por arquivo: a guarda antiga lia o corpo de uma função do checkout e por
# construção não podia ver o resto do cliente. Linha de comentário não conta como ramo —
# senão dá para passar na régua escrevendo a palavra na prosa.
func SuiteExternalLinksWebBranch() -> void:
	print("[suite] navegação externa no export Web")
	var sitios : int = 0
	var nus : Array[String] = []
	for found in _GdFilesUnder("res://sources"):
		var path : String = String(found)
		var src : PackedStringArray = _RepoFile(path).split("\n")
		var fnNome : String = ""
		var fnFim : int = -1
		for i in src.size():
			var line : String = String(src[i])
			var trimmed : String = line.strip_edges()
			if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
				fnNome = trimmed.substr(trimmed.find("func ") + 5).get_slice("(", 0)
				fnFim = i
				continue
			if trimmed.begins_with("#") or line.find("OS.shell_open(") < 0:
				continue
			sitios += 1
			var j : int = fnFim + 1
			var bloco : String = ""
			while j < src.size():
				var inner : String = String(src[j])
				var innerTrimmed : String = inner.strip_edges()
				if not innerTrimmed.is_empty() and not inner.begins_with("\t"):
					break
				if not innerTrimmed.begins_with("#"):
					bloco += inner + "\n"
				j += 1
			if not bloco.contains("JavaScriptBridge") or not bloco.contains("isWeb"):
				nus.append("%s:%d em %s" % [path, i + 1, fnNome])
	CheckEq(nus.size(), 0, "navegação externa: todo OS.shell_open de sources/ tem ramo Web com JavaScriptBridge (%d sítios; sem ramo: %s)" % [sitios, " | ".join(nus)])
	print("  [info] navegação externa: %d sítios de OS.shell_open em sources/, todos com ramo Web" % sitios)

# Offline comprado com anúncio (plano 2026-09-25). A regra do dono: "cada anúncio
# soma +1h; o divisor de 24h reinicia; VIP faz 24h sem assistir nada". O piso F2P
# que era 1h saiu da zona hostil da retenção e hoje é `OfflineSettle.BaseCapHours`
# (8h, P1-retenção) — o que o anúncio compra continua sendo HORA por cima dele, e
# é isso que esta suíte mede. Esta suíte cobre o mecanismo — placement, horas
# ganhas por PERSONAGEM, as duas metades da janela (divisor e coleta) e o teto de
# baú. O C2 ligou o settle nela (CapHoursForCharacter em BuildReport e em
# SettlePending), então os asserts de liquidação no fim são a prova de que a
# ligou: sem eles o cap novo existiria no catálogo sem pagar hora a ninguém.
func SuiteOfflineAdHours(sql : SQLService) -> void:
	print("[suite] offline comprado com anúncio (C1/C2)")
	var economy : EconomyService = Launcher.Economy
	var tele : TelemetryService = Launcher.Telemetry
	var now : int = SQLCommons.Timestamp()
	var tok : Callable = func(a : int, p : String) -> String: return AdToken(a, p)
	OS.set_environment("SHAMBLETA_AD_STUB", "1")
	var charA : int = CreateFixture(sql, "idle_offad_a", "IdleOffAdA")
	var charB : int = CreateFixture(sql, "idle_offad_b", "IdleOffAdB")
	if not Check(charA != 0 and charB != 0, "offad fixtures created"):
		return
	var acctA : int = sql.GetAccountIDForCharacter(charA)
	var acctB : int = sql.GetAccountIDForCharacter(charB)
	sql.SetCharacterFarmZone(charA, 1)
	var old : int = now - 7200		# anchor "2h atrás", i.e. nada coletado depois das views

	Check(EconomyCatalog.AD_PLACEMENTS.has(EconomyCatalog.AD_AFKHOURS), "afkhoras é placement conhecido")
	CheckEq(int(EconomyCatalog.AD_OFFLINE_HOURS_PER_AD * 100.0), 100, "cada anúncio vale 1h")

	# O placement novo não abriu porta de bypass: sem a env do beta não há mint,
	# e um nonce chutado continua sem valer nada.
	OS.set_environment("SHAMBLETA_AD_STUB", "")
	Check(str(economy.MintAdSlot(acctA, EconomyCatalog.AD_AFKHOURS).get("reason", "")) == "ad_source", "afkhoras sem a env: mint recusado")
	Check(str(economy.WatchAd(acctA, charA, EconomyCatalog.AD_AFKHOURS, "slot:" + "f".repeat(32)).get("reason", "")) == "bad_token", "afkhoras sem a env: bad_token")
	OS.set_environment("SHAMBLETA_AD_STUB", "1")

	CheckNear(economy.AfkHoursEarned(acctA, charA, old), 0.0, 0.01, "sem view: 0h compradas")
	Check(str(economy.WatchAd(acctA, charA, EconomyCatalog.AD_BOSSKEY, tok.call(acctA, EconomyCatalog.AD_BOSSKEY)).get("reason", "")) == "ok", "bosskey view registrada")
	CheckNear(economy.AfkHoursEarned(acctA, charA, old), 0.0, 0.01, "view de outro placement não compra hora")

	# Linearidade: 1 view = 1h, sem teto e sem acúmulo de sobra.
	for i in 3:
		Check(str(economy.WatchAd(acctA, charA, EconomyCatalog.AD_AFKHOURS, tok.call(acctA, EconomyCatalog.AD_AFKHOURS)).get("reason", "")) == "ok", "afkhoras view %d ok" % (i + 1))
		CheckNear(economy.AfkHoursEarned(acctA, charA, old), float(i + 1), 0.01, "cap cresce 1h por view")

	# Por PERSONAGEM: a mesma conta com outro personagem, ou outro personagem com
	# a mesma conta, não herda a hora — senão 6 personagens lavariam o contador.
	CheckNear(economy.AfkHoursEarned(acctB, charA, old), 0.0, 0.01, "conta errada: 0h")
	CheckNear(economy.AfkHoursEarned(acctA, charB, old), 0.0, 0.01, "personagem errado: 0h")

	# As duas metades do max(divisor do dia, último settle): o divisor zera a
	# janela quando o dia vira, e o anchor consome quando se coleta.
	AdsCosmeticsService.dayStartOverride = now + 60
	CheckNear(economy.AfkHoursEarned(acctA, charA, old), 0.0, 0.01, "virou o dia sem coletar: hora perdida")
	AdsCosmeticsService.dayStartOverride = 0
	CheckNear(economy.AfkHoursEarned(acctA, charA, old), 3.0, 0.01, "janela de volta: as 3h continuam compradas")
	CheckNear(economy.AfkHoursEarned(acctA, charA, now + 60), 0.0, 0.01, "anchor passado pela coleta: nada pendente")

	# Composição do cap: comprado pela conta + assistido pelo personagem.
	CheckNear(OfflineSettle.CapHoursForCharacter(charA, acctA, old), OfflineSettle.CapHoursForAccount(acctA) + 3.0, 0.01, "cap do personagem = comprado + 3h de anúncio")
	Check(str(economy.WatchAd(acctB, charB, EconomyCatalog.AD_AFKHOURS, tok.call(acctB, EconomyCatalog.AD_AFKHOURS)).get("reason", "")) == "ok", "view do personagem B ok")
	Check(sql.SetVIPUntil(acctB, now + 30 * 86400) and sql.SetVIPTier(acctB, 1), "vip tier 1 na conta B")
	CheckNear(OfflineSettle.CapHoursForAccount(acctB), 24.0, 0.01, "VIP compra 24h sem assistir nada")
	CheckNear(OfflineSettle.CapHoursForCharacter(charB, acctB, old), 25.0, 0.01, "VIP + anúncio compõem sem teto")

	# O settle LÊ o cap composto: comprado pela conta + assistido pelo personagem.
	# Com a base em 8h e três views, uma janela de 14h paga 11h — o que não coube
	# no teto não é pago e não se acumula.
	sql.UpdateSettleAnchor(charA, now - 14 * 3600, 1.0)
	var report : Dictionary = OfflineSettle.SettlePending(charA)
	tele.Flush()
	if Check(not report.is_empty(), "settle lê o cap do personagem"):
		CheckNear(float(report.get("hours", 0.0)), OfflineSettle.BaseCapHours + 3.0, 0.01, "14h de janela pagam a base + 3h de anúncio")
		CheckNear(float(report.get("cap_hours", 0.0)), OfflineSettle.BaseCapHours + 3.0, 0.01, "cap_hours vai no relatório")
		Check(not bool(report.get("doubled", true)), "F2P nunca líquida dobrado")
		CheckEq(int(report.get("chests", 0)), 2, "11h no floor(h/4) com teto de 3 pagam 2 baús")
	# Hora não liquidada não fica pendurada: o anchor avançou além das views.
	OfflineSettle.nowOverride = int(report.get("last_settled_at", 0)) + 3600
	var next : Dictionary = OfflineSettle.SettlePending(charA)
	tele.Flush()
	OfflineSettle.nowOverride = 0
	if Check(not next.is_empty(), "settle seguinte produz"):
		CheckNear(float(next.get("hours", 0.0)), 1.0, 0.01, "sem view nova, a janela de 1h é paga por inteiro")
		CheckNear(float(next.get("cap_hours", 0.0)), OfflineSettle.BaseCapHours, 0.01, "sem view nova, o teto volta à base")

	# Piso e teto de baú (risco 1 do plano). A 1h o floor(h/4) pagaria 0 baú, e a
	# janela AFK é justamente o produto do F2P; na outra ponta, o gate de pegada
	# de 60 s permite uma coleta por minuto, que sem teto viraria 24 baús/dia.
	var budgetChar : int = CreateFixture(sql, "idle_offad_c", "IdleOffAdC")
	if Check(budgetChar != 0, "chest budget fixture created"):
		var budgetAcct : int = sql.GetAccountIDForCharacter(budgetChar)
		sql.SetCharacterFarmZone(budgetChar, 1)
		var minted : int = 0
		for i in 24:
			sql.UpdateSettleAnchor(budgetChar, SQLCommons.Timestamp() - 3600, 1.0)
			var r : Dictionary = OfflineSettle.SettlePending(budgetChar)
			minted += int(r.get("chests", 0))
			if i == 0:
				CheckEq(int(r.get("chests", 0)), 1, "1h líquida garante 1 baú")
				CheckEq(int(r.get("boss_keys", 0)), 0, "1h não fabrica chave de chefe")
		tele.Flush()
		CheckEq(minted, EconomyCatalog.ChestsPerDayFromSettle, "24 coletas de 1h pagam o teto do dia")
		CheckEq(int(sql.QueryBindings("SELECT COUNT(*) AS n FROM chest_instance WHERE char_id = ? AND origin = 'settle';", [budgetChar])[0]["n"]), minted, "o teto vale na tabela, não só no relatório")
		sql.db.delete_rows("chest_instance", "char_id = %d" % budgetChar)
		sql.db.delete_rows("character", "nickname = 'IdleOffAdC'")
		sql.db.delete_rows("account", "username = 'idle_offad_c'")

	# ok ⇒ a view está contável. Antes WatchAd respondia ok:true sem olhar o que
	# TelemetryService.Flush() devolveu (0 quando a transação falha); com hora
	# offline em jogo isso viraria anúncio assistido e não pago.
	var viewsBefore : int = economy.AdViewsToday(acctA, EconomyCatalog.AD_AFKHOURS)
	Check(str(economy.WatchAd(acctA, charA, EconomyCatalog.AD_AFKHOURS, tok.call(acctA, EconomyCatalog.AD_AFKHOURS)).get("reason", "")) == "ok", "afkhoras com a janela normal: ok")
	CheckEq(economy.AdViewsToday(acctA, EconomyCatalog.AD_AFKHOURS), viewsBefore + 1, "ok: a view está na janela que os caps consultam")

	# O ramo negativo, injetado pelo próprio seam: uma janela que não consegue
	# ver a view recém-gravada não pode creditar.
	AdsCosmeticsService.dayStartOverride = now + 3600
	Check(str(economy.WatchAd(acctA, charA, EconomyCatalog.AD_AFKHOURS, tok.call(acctA, EconomyCatalog.AD_AFKHOURS)).get("reason", "")) == "ad_persist", "view fora da janela: ad_persist, não ok")
	AdsCosmeticsService.dayStartOverride = 0

	sql.db.delete_rows("telemetry_event", "account_id = %d OR account_id = %d" % [acctA, acctB])
	sql.db.delete_rows("character", "nickname = 'IdleOffAdA' OR nickname = 'IdleOffAdB'")
	sql.db.delete_rows("account", "username = 'idle_offad_a' OR username = 'idle_offad_b'")

# Vitrine honesta (plano 2026-09-25, fatias 2 e 4). Duas famílias de defeito,
# ambas medidas no mapeamento de venda: anunciar algo que a outra porta recusa
# (o passe fora de temporada) e cobrar por algo que nenhum renderizador mostra
# (frame, rebirth_fx). A função de filtro é pura de propósito — os dois ramos
# são provados sem tocar banco; o banco prova só o fio que a liga ao estado.
func SuiteStorefrontHonesty(sql : SQLService) -> void:
	print("[suite] vitrine honesta: passe, rótulo de cobrança e renderizador (C3/C4)")
	var economy : EconomyService = Launcher.Economy
	var charID : int = CreateFixture(sql, "idle_vitrine_a", "IdleVitrineA")
	if not Check(charID != 0, "vitrine fixture created"):
		return
	var accountID : int = sql.GetAccountIDForCharacter(charID)
	var total : int = EconomyCatalog.SHOP_CATALOG.size()
	var off : Array = Storefront.ShopCatalog("")

	# A vitrine com temporada no ar não é o catálogo inteiro: é o catálogo menos o
	# passe de OUTRA temporada. `pass.s2` entrou nos catálogos com a temporada
	# agendada do OPS-2, e enquanto a S1 está no ar anunciá-lo é botão que concede
	# premium na temporada errada — o mesmo defeito do `pass.s1` comprado na S2, só
	# que do lado de cá. A régua é contada de `PassSkus`, não redigitada.
	var base : String = SeasonConfig.DefaultPremiumSku
	var other : String = ""
	var own : int = 0
	for passSku in Storefront.PassSkus:
		var candidate : String = String(passSku)
		if candidate == base or candidate == base + ".deluxe":
			own += 1
		elif other.is_empty():
			other = candidate
	Check(not other.is_empty(), "há um passe de outra temporada na lista (sem ele, esta régua não morde)")
	var on : Array = Storefront.ShopCatalog(base)
	var onSkus : Array = []
	for e in on:
		onSkus.append(str((e as Dictionary).get("sku", "")))
	CheckEq(on.size(), total - Storefront.PassSkus.size() + own, "com o passe da temporada no ar, só o dele fica")
	Check(onSkus.has(base), "o passe da temporada ativa é anunciado (%s)" % base)
	Check(not onSkus.has(other), "o passe de outra temporada não é anunciado (%s)" % other)
	CheckEq(off.size(), total - Storefront.PassSkus.size(), "sem temporada, só os SKUs de passe somem")
	var offSkus : Array = []
	for e in off:
		offSkus.append(str((e as Dictionary).get("sku", "")))
	for passSku in Storefront.PassSkus:
		Check(not offSkus.has(String(passSku)), "%s some da vitrine sem temporada" % String(passSku))

	# Terceira família de mentira de vitrine: o NÚMERO impresso no letreiro. A loja
	# anunciava "offline cap 1h + 1h per ad" e o VIP "(24h offline)" como texto
	# corrido; quando a base F2P subiu para 8h (P1-retenção) a tela continuou
	# vendendo a regra velha — que é exatamente o tipo de divergência que nenhuma
	# asserção de comportamento pega, porque o comportamento estava certo. A régua
	# é de fonte: os rótulos são montados em `ShowState`, e hora de offline só pode
	# chegar lá por constante (`OfflineSettle` / `EconomyCatalog`), nunca por dígito.
	# Varrido por String e não RegEx pelo mesmo motivo de `_MemberAccesses`.
	var shopSrc : String = _FnBody(_RepoFile("res://sources/gui/Shop.gd"), "func ShowState(")
	if Check(shopSrc.contains("vipLabel.text") and shopSrc.contains("buyVip1.text"),
			"loja: os dois letreiros de VIP são montados em ShowState"):
		var hoursChumbadas : String = ""
		for rawLine in shopSrc.split("\n"):
			var line : String = String(rawLine)
			if not line.contains("vipLabel.text") and not line.contains("buyVip"):
				continue
			var k : int = 0
			while k < line.length():
				if line[k] < "0" or line[k] > "9":
					k += 1
					continue
				var e : int = k
				while e < line.length() and line[e] >= "0" and line[e] <= "9":
					e += 1
				while e < line.length() and line[e] == " ":
					e += 1
				if e < line.length() and line[e] == "h" \
						and not _IsIdentChar(line[e + 1] if e + 1 < line.length() else " ", false):
					hoursChumbadas += line.substr(k, e - k + 1) + " "
				k = e
		Check(hoursChumbadas.is_empty(), "nenhuma hora de offline chumbada no letreiro da loja (%s)" % hoursChumbadas)

	# `Storefront.PassSkus` é uma lista de SKUs; a verdade sobre o que É passe
	# mora no kind do catálogo canônico. Sem este amarrio a lista vira quarta
	# cópia à deriva — e o erro silencioso é filtrar demais (some produto pagável).
	var parsed : Variant = JSON.parse_string(_RepoFile("res://data/conf/paid_catalog.json"))
	if not Check(typeof(parsed) == TYPE_DICTIONARY, "catálogo pago canônico parseia"):
		return
	var paid : Dictionary = parsed
	var jsonPass : Array = []
	var placeholder : String = ""
	for key in paid.keys():
		var sku : String = String(key)
		if sku.begins_with("_"):
			continue
		var item : Variant = paid[key]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry : Dictionary = item
		if str(entry.get("kind", "")) == "pass_premium":
			jsonPass.append(sku)
		# O `title` é impresso no Checkout Pro pelo companion
		# (`build_preference_payload`: "título (sku)") — é o que o pagador lê no
		# extrato, e o que uma contestação cita.
		var title : String = str(entry.get("title", ""))
		if not title.is_empty() and title.to_lower().contains("pending"):
			placeholder += sku + " "
	# Comparação bidirecional: filtrar de menos deixa botão mentiroso na vitrine,
	# filtrar a mais esconde produto pagável — e os dois erros são silenciosos.
	var drift : String = ""
	for want in Storefront.PassSkus:
		if not jsonPass.has(String(want)):
			drift += String(want) + " "
	for have in jsonPass:
		if not Storefront.PassSkus.has(String(have)):
			drift += String(have) + " "
	Check(drift.is_empty(), "PassSkus == kind pass_premium do catálogo canônico (%s)" % drift)
	Check(placeholder.is_empty(), "nenhum rótulo de cobrança com placeholder (%s)" % placeholder)

	# O fio que liga o filtro ao estado consolidado que a Loja desenha. A env é
	# salva e devolvida no fim: `CreateSeason` recusa -1 com a trava ligada, e o
	# estado da env no fim do run não é decisão desta suíte.
	var seasonsEnv : String = OS.get_environment("SHAMBLETA_ENABLE_SEASONS")
	OS.set_environment("SHAMBLETA_ENABLE_SEASONS", "1")
	for r in sql.QueryBindings("SELECT season_id FROM season WHERE status = 'active';", []):
		economy.CloseSeason(int((r as Dictionary).get("season_id", 0)))
	var stateOff : Dictionary = economy.GetEconomyState(accountID, charID)
	CheckEq((stateOff.get("catalog", []) as Array).size(), off.size(), "estado sem temporada traz a vitrine filtrada")
	Check(not bool(stateOff.get("season_active", true)), "estado declara season_active = false")
	# A regra congelada é a que o PRODUTO congela na abertura — não um literal
	# inventado pela suíte: `RulesJSONForEntry` da entrada do calendário que vende
	# `other` (hoje a S2 agendada). Assim o `config_id` também bate, e as duas
	# escadas de resolução (linha congelada e calendário) têm que concordar.
	var otherEntry : Dictionary = {}
	for e in SeasonConfig.Entries():
		if SeasonConfig.PremiumSku(e as Dictionary) == other:
			otherEntry = e as Dictionary
	if Check(not otherEntry.is_empty(), "o calendário embarcado declara a sucessora que vende %s" % other):
		var seasonID : int = economy.CreateSeason(7, SeasonConfig.RulesJSONForEntry(otherEntry))
		if Check(seasonID > 0, "temporada criada para a vitrine"):
			var stateOn : Dictionary = economy.GetEconomyState(accountID, charID)
			# A linha CONGELADA manda, não o calendário: uma temporada que declarou
			# `pass.s2` na abertura vende `pass.s2` mesmo com a rotação do arquivo
			# ainda em `pass.s1`. É o que o transport não sabia fazer (SKU por
			# literal), e é o que fazia o botão comprar o passe da temporada errada.
			# `Check` e não `CheckEq`: o helper do kernel é tipado em `int`, e
			# comparar String com ele não compila — o preflight pegou isso antes
			# de o gate morrer no timeout, e a régua só vale impressa com os dois
			# lados (esperado × lido).
			var activeSku : String = economy.ActivePassSku()
			Check(activeSku == other,
					"a linha congelada decide o passe à venda (esperado %s, lido %s)" % [other, activeSku])
			var onOther : Array = Storefront.ShopCatalog(other)
			CheckEq((stateOn.get("catalog", []) as Array).size(), onOther.size(), "com a sucessora no ar, a vitrine é a dela")
			var viaSeason : Dictionary = economy.GetPassCheckoutIntent(accountID, "standard")
			var viaSku : Dictionary = economy.GetCheckoutIntent(accountID, other)
			Check(str(viaSeason.get("reason", "")) == str(viaSku.get("reason", "")) \
					and str(viaSeason.get("sku", "")) == str(viaSku.get("sku", "")) \
					and float(viaSeason.get("price", 0.0)) == float(viaSku.get("price", 0.0)),
					"BuyPass cai na mesma porta do SKU da temporada (mesmo veredito, mesmo preço)")
			Check(bool(stateOn.get("season_active", false)), "estado declara season_active = true")
			Check(economy.CloseSeason(seasonID), "temporada da vitrine fechada")
	OS.set_environment("SHAMBLETA_ENABLE_SEASONS", seasonsEnv)

	# Cosmético sem renderizador: a oferta sai do botão (flag no payload) e a
	# cobrança sai na porta do dinheiro. O resto da vitrine continua listado —
	# colecionar o que se ganhou não é vender.
	var col : Dictionary = economy.GetCosmetics(accountID)
	var colSkus : Array = col.get("catalog", [])
	CheckEq(colSkus.size(), EconomyCatalog.COSMETIC_CATALOG.size(), "a coleção continua listando o catálogo inteiro")
	var sellable : int = 0
	for c in colSkus:
		var ce : Dictionary = c
		if int(ce.get("price", 0)) > 0:
			if bool(ce.get("rendered", false)):
				sellable += 1
			else:
				Check(not Storefront.IsRenderedCosmetic(str(ce.get("id", ""))),
					"%s: flag do estado bate com o catálogo" % str(ce.get("id", "")))
	CheckEq(sellable, 1, "um único cosmético pago tem renderizador hoje")
	Check(not Storefront.IsRenderedCosmetic("nao_existe"), "cosmético inexistente não é renderizável")
	sql.IncRebirthCounter(charID)
	sql.SetGems(accountID, 5000)
	var blocked : Dictionary = economy.BuyCosmetic(accountID, charID, "rebirth_fx")
	Check(str(blocked.get("reason", "")) == "not_rendered", "rebirth_fx cobrado com saldo => not_rendered")
	CheckEq(economy.GetGems(accountID), 5000, "not_rendered: o gate é pré-débito, saldo intacto")
	Check(not economy.HasCosmetic(accountID, "rebirth_fx"), "not_rendered não concedeu o cosmético")

	# O ledger NÃO é parte da limpeza: `ledger_transaction_no_delete`
	# (data/conf/migrations/056_ledger_retention.sql:103) recusa qualquer DELETE de
	# linha não coberta por rollup, e é o que a vitrine honesta passava por cima em
	# silêncio enquanto o fixture escrevia `stat.gp` cru. Aposentar a fixture é
	# tirar o dono: as pernas do reconcile dão INNER JOIN em character/account,
	# então apagar as duas já as remove de toda varredura.
	sql.db.delete_rows("cosmetic_grant", "account_id = %d" % accountID)
	sql.db.delete_rows("character", "nickname = 'IdleVitrineA'")
	sql.db.delete_rows("account", "username = 'idle_vitrine_a'")

# SOM-IDLE (2026-09-28): a esteira de item do farm vivo, elo a elo, cada um com
# número próprio. O elo quebrado era o do farmer: `State.LOOT` não tinha transição
# registrada no kill e `_findNearestDrop` não tinha raio, então `loot_ticks` = 0 e
# a auto-poção (Apple, a mesma mesa do Salt Slime da zona 1) não tinha suprimento
# nenhum — medido 2026-09-27: 0 em 41 kills.
#
# O elo do MOB foi A/B-medido hoje contra `HEAD` no mesmo harness e derrubava SIM:
# o desenho antigo (roll no `AIAgent.SetData`, guardado no inventário do mob,
# varrido em `MonsterAgent.Killed`) deu `kills=12 dropped=8 esperado=8.4`, com mobs
# vivos segurando `items=1`. Não era código morto, e nada aqui prova o contrário.
# A mudança para o roll na morte é de SEMÂNTICA: `data._drops` é
# `Dictionary[ItemCell, float]` — probabilidade POR KILL — e no desenho antigo o
# inventário do mob era um depósito de loot que só existia para ser jogado fora,
# com a quantidade derrubada vindo de `item.count` (estado da pilha) em vez da
# mesa. A régua (3) é a que separa os dois desenhos: no antigo um mob vivo
# segurava célula de mesa, no atual nenhum.
func SuiteIdleLootPipeline(charID : int) -> void:
	print("[suite] esteira de item do farm vivo")
	var sql : SQLService = Launcher.SQL

	# (1) Elo do farmer: coletar o que está no chão e beber a poção que abastece.
	# A 1× de propósito: a compressão de 20× não é neutra para a morte (medido hoje,
	# mesmo fixture: 19 mortes em 240 s de jogo @20× contra 3 em 300 s @1×) e a
	# sessão comprimida reprovava o próprio gate de custo de morte do `_SimRun`.
	# Compressão é sampler de política, não regime de produto. Vem primeiro porque
	# `_SimRun` toma a instância da zona e libera o agente no fim — nada daqui pode
	# segurar referência de antes dela.
	var snapshot : Dictionary = await _SimRun(charID, 972, 180, 1.0, 1, false)
	var simKills : int = int(snapshot.get("kills", 0))
	var lootTicks : int = int(snapshot.get("loot_ticks", 0))
	var picks : int = int(snapshot.get("drops_picked", 0))
	var potions : int = int(snapshot.get("potions_used", 0))
	print("LOOTPIPE: kills=%d loot_ticks=%d picks=%d potions=%d deaths=%d" % [
		simKills, lootTicks, picks, potions, int(snapshot.get("deaths", 0))])
	Check(simKills > 0, "loot: sessão produtiva (kills=%d)" % simKills)
	Check(lootTicks > 0, "loot: a policy entrou em State.LOOT (loot_ticks=%d)" % lootTicks)
	Check(picks >= 2, "loot: o farmer tirou item do chão (drops_picked=%d ≥ 2)" % picks)
	# `potions_used` da sessão NÃO é régua: medido no gate de 2026-09-28, o farmer
	# que chega com o nível/equipamento das suítes anteriores coleta 16 e bebe 0,
	# porque nunca afunda o limiar de 35%. Beber é consequência de apanhar, e
	# apanhar é função do vizinho — a régua do elo bebe abaixo, dirigida.

	var agent : PlayerAgent = await _SpawnSimAgent(charID, 971, 1)
	if not Check(agent != null, "loot: agente na zona 1"):
		return
	var inst : WorldInstance = IdlePolicyService.GetFarmInstance(1)
	if not Check(inst != null, "loot: instância da zona 1"):
		WorldAgent.RemoveAgent(agent)
		return

	# (1b) A bebereira dirigida: HP forçado no chão e pilha garantida, para medir o
	# caminho `_tickPotion → limiar → _usePotion → UseItem` sem depender de quanto o
	# farmer apanhou. É também aqui que o elo coleta→poção vira afirmação sobre a
	# MESMA célula: `autoPotionItemHash` é a mesa da zona, não um item à parte.
	if Check(IdlePolicyService.StartIdleSession(agent, 1) and agent.idlePolicy != null, "loot: sessão dirigida pela bebereira"):
		var pol : IdlePolicy = agent.idlePolicy
		var potionCell : ItemCell = DB.GetItem(pol.autoPotionItemHash)
		if Check(potionCell != null and potionCell.usable, "loot: a célula da bebereira existe e é usável (hash %d)" % pol.autoPotionItemHash):
			var pushPp : bool = agent.inventory.PushItem(potionCell, 2)
			var ppIdx : int = agent.inventory.FindItemIndex(potionCell) if pushPp else -1
			var ppBefore : int = int(agent.inventory.items[ppIdx].count) if ppIdx >= 0 else -1
			var ppUsed : int = pol.metricPotionsUsed
			agent.stat.health = 1
			pol._tickPotion(IdlePolicy.PotionCheckInterval + 0.5)
			var ppIdx2 : int = agent.inventory.FindItemIndex(potionCell)
			var ppAfter : int = int(agent.inventory.items[ppIdx2].count) if ppIdx2 >= 0 else 0
			CheckEq(pol.metricPotionsUsed, ppUsed + 1, "loot: com HP abaixo do limiar, um tick bebe exatamente uma vez")
			CheckEq(ppAfter, ppBefore - 1, "loot: beber consome uma unidade da pilha que a coleta traz (%d → %d)" % [ppBefore, ppAfter])
		IdlePolicyService.StopIdleSession(agent)

	# (2) Elo do mob: matar empurra a mesa para o chão, NA taxa da mesa. O roll é
	# `randf() < p` por célula, então a soma é binomial independente: média = Σp,
	# variância = Σp(1−p). A régua é a banda de 3,5σ — com 12 Salt Slime (0,7) fica
	# 3–13 e o falso positivo por run é ~0,08% (P(X ≤ 2) de Binomial(12; 0,7)).
	var expected : float = 0.0
	var variance : float = 0.0
	var killed : int = 0
	var before : int = inst.drops.size()
	for mob in inst.mobs:
		if killed >= 12:
			break
		if mob == null or not is_instance_valid(mob) or not ActorCommons.IsAlive(mob):
			continue
		if mob.data == null or mob.data._drops.is_empty():
			continue
		for cell : ItemCell in mob.data._drops:
			var p : float = float(mob.data._drops[cell])
			expected += p
			variance += p * (1.0 - p)
		mob.Kill()
		killed += 1
	var dropped : int = inst.drops.size() - before
	var sigma : float = sqrt(variance) if variance > 0.0 else 1.0
	var bandLo : int = int(ceilf(expected - 3.5 * sigma))
	var bandHi : int = int(floorf(expected + 3.5 * sigma))
	Check(killed >= 10, "loot: amostra suficiente de mobs com mesa (kills=%d ≥ 10)" % killed)
	Check(dropped > 0, "loot: a morte empurra drop para a instância (%d em %d kills)" % [dropped, killed])
	Check(dropped >= bandLo and dropped <= bandHi,
		"loot: taxa de drop na banda da mesa (dropped=%d, esperado=%.1f, banda=%d–%d)" % [dropped, expected, bandLo, bandHi])
	# Costura das duas economias: o ppm que o offline liquida É a probabilidade por
	# kill medida aqui na mesa viva, com 25% de folga. Sem esta amarra o
	# `dropRatePPM` volta a ser número solto — foi 150 lido como ppm-de-segundos
	# contra os 0,7/kill que a própria zona derruba (2026-09-28).
	if killed > 0:
		var perKillLive : float = expected / float(killed)
		var ppmPerKill : float = float(FarmZoneData.DefaultDropRatePPM) / 1000000.0
		Check(absf(ppmPerKill - perKillLive) <= 0.25 * perKillLive,
			"loot: ppm do catálogo offline bate com a mesa viva (%.3f vs %.3f por kill)" % [ppmPerKill, perKillLive])

	# (3) O inventário do mob não é depósito de mesa. É a régua que separa o roll
	# por kill (atual) do roll por spawn (desenho antigo, medido hoje com mobs vivos
	# segurando `items=1`): se alguém voltar a guardar o roll no mob, isto pega.
	var held : int = 0
	for mob in inst.mobs:
		if mob == null or not is_instance_valid(mob) or mob.data == null or mob.inventory == null:
			continue
		for item in mob.inventory.items:
			if item == null:
				continue
			for dcell : ItemCell in mob.data._drops:
				if dcell != null and dcell.id == item.cellID and dcell.customfield == item.cellCustomfield:
					held += 1
					break
	CheckEq(held, 0, "loot: nenhum mob segura célula de mesa no inventário (retidas=%d)" % held)

	# (4) Elo do chão, pelo caminho do inventário: `PushItem` empilha na memória e
	# `DropItem` devolve ao mundo. `Inventory.DropItem` tem guarda — só consome a
	# pilha quando o agente TEM instância e o mapa não é NO_DROP; sem ela o item
	# sumiria do dono sem nunca aparecer no chão. O farmer recém-spawnado aqui pode
	# não ter instância (a do sim é desmontada no fim de `_SimRun`), então cada lado
	# entra na régua do ramo que de fato exercita, e o consumo completo é medido no
	# mob, que está num instance vivo.
	var apple : ItemCell = DB.GetItem(DB.GetCellHash("Apple"), "")
	if not Check(apple != null, "loot: célula Apple resolve"):
		WorldAgent.RemoveAgent(agent)
		return
	var seedIdx : int = agent.inventory.FindItemIndex(apple)
	var seedCount : int = int(agent.inventory.items[seedIdx].count) if seedIdx >= 0 else 0
	var pushOk : bool = agent.inventory.PushItem(apple, 2)
	var idx : int = agent.inventory.FindItemIndex(apple)
	Check(pushOk and idx >= 0, "loot: PushItem aceita 2 maçãs empilhadas (ok=%s idx=%d)" % [str(pushOk), idx])
	if pushOk and idx >= 0:
		# Delta, não absoluto: a bebereira dirigida de (1b) empilha na MESMA célula
		# Apple e o fixture pode chegar com pilha do settle — quem fecha com a
		# quantidade pedida é a soma, não o total da célula.
		CheckEq(int(agent.inventory.items[idx].count), seedCount + 2, "loot: a pilha em memória fecha com a quantidade pedida (+2 sobre %d)" % seedCount)
		var playerInst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
		var pBefore : int = inst.drops.size()
		agent.inventory.DropItem(apple, 1, idx)
		var leftIdx : int = agent.inventory.FindItemIndex(apple)
		var leftCount : int = int(agent.inventory.items[leftIdx].count) if leftIdx >= 0 else -1
		if playerInst != null:
			CheckEq(leftCount, seedCount + 1, "loot: DropItem do player tira da pilha exatamente o que pede (sobrou %d de %d)" % [leftCount, seedCount + 2])
			CheckEq(inst.drops.size() - pBefore, 1, "loot: o drop do player cai na instância")
		else:
			CheckEq(leftCount, seedCount + 2, "loot: sem instância o DropItem não consome a pilha (item nem some nem duplica)")
			CheckEq(inst.drops.size() - pBefore, 0, "loot: sem instância nada vai para o chão")

	var mobLink : MonsterAgent = null
	for mob in inst.mobs:
		if mob != null and is_instance_valid(mob) and ActorCommons.IsAlive(mob) and mob is MonsterAgent:
			mobLink = mob
			break
	if Check(mobLink != null, "loot: sobra um mob vivo para o link de inventário"):
		var mBefore : int = inst.drops.size()
		var mPush : bool = mobLink.inventory.PushItem(apple, 1)
		var mIdx : int = mobLink.inventory.FindItemIndex(apple) if mPush else -1
		if Check(mPush and mIdx >= 0, "loot: mob aceita item no inventário para o teste do link"):
			mobLink.inventory.DropItem(apple, 1, mIdx)
			CheckEq(inst.drops.size() - mBefore, 1, "loot: DropItem do inventário empurra exatamente um Drop para a instância")
			Check(mobLink.inventory.FindItemIndex(apple) < 0, "loot: a pilha do mob fecha com o que foi para o chão (não sobra resto)")

	# (5) Elo do banco, com o link bruto isolado do farming: `Inventory.AddItem` de
	# um jogador CONECTADO escreve pilha E lote. Sem peer ligado ele grava só em
	# memória (é o caso do farmer do sim em (1)), por isso o peer OFFLINE é montado
	# aqui. Esta é a régua do bug consertado em `SQL.AddItem`: o ramo de pilha
	# existente somava 1 por chamada enquanto a memória somava `itemCount`, então um
	# `AddItem(apple, 5)` de baú/NPC deixava 5 em memória e 1 no banco — no relog o
	# item sumia, e o `RemoveItem` seguinte era recusado por falta de lote enquanto
	# a memória já tinha jogado o resto fora.
	var peerID : int = 971971
	Peers.AddPeer(peerID, Peers.TransportType.OFFLINE)
	var peer : Peers.Peer = Peers.GetPeer(peerID)
	if Check(peer != null, "loot: peer OFFLINE registrado"):
		peer.characterID = charID
		agent.peerID = peerID
		sql.db.delete_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [apple.id, charID])
		sql.DeleteRowsRaw("item_instance", "char_id = %d AND item_id = %d" % [charID, apple.id])
		agent.inventory.AddItem(apple, 3)
		var stackA : int = _CountItem(sql, charID, apple.id)
		var lotsA : int = sql.GetLotBalanceRaw(charID, apple.id)
		CheckEq(stackA, 3, "loot: pilha nova grava a quantidade pedida, não 1 (item=%d)" % stackA)
		CheckEq(lotsA, 3, "loot: o lote de origem `world` fecha com a pilha (lote=%d)" % lotsA)
		agent.inventory.AddItem(apple, 2)
		var stackB : int = _CountItem(sql, charID, apple.id)
		var lotsB : int = sql.GetLotBalanceRaw(charID, apple.id)
		var stackDelta : int = stackB - stackA
		var lotDelta : int = lotsB - lotsA
		CheckEq(stackDelta, 2, "loot: incrementar pilha existente soma itemCount, não 1 (delta=%d)" % stackDelta)
		CheckEq(lotDelta, 2, "loot: o journal acompanha o incremento da pilha (delta=%d)" % lotDelta)
		CheckEq(stackB, lotsB, "loot: reconciliação B1 — soma de lotes == soma de pilhas (%d vs %d)" % [stackB, lotsB])
		Peers.RemovePeer(peerID)
		sql.db.delete_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [apple.id, charID])
		sql.DeleteRowsRaw("item_instance", "char_id = %d AND item_id = %d" % [charID, apple.id])
	WorldAgent.RemoveAgent(agent)
