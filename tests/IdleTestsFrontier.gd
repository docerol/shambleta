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

# O alvo de um ponteiro, UMA lista para os quatro regexes deste arquivo. Ela é o texto de
# `_TGT` da régua bash (`scripts/check_doc_drift.sh`) e a razão de existir dela é a mesma do
# adaptador `Herdado` lá: os dois juízes da mesma árvore têm de ler a mesma classe. Escrita à
# mão em quatro casas, esta lista aqui era mais estreita que a de lá e não via `nginx.conf`,
# `Dockerfile`, `.mjs`, `.html`, `.yaml` — 27 ponteiros de linha invisíveis para cá e julgados
# de lá (o censo desta varredura saltou de 447 para 474 ao içar a lista, com as âncoras paradas
# em 121), e a primeira consequência medida foi o braço de continuação acusar de órfã uma frase
# honesta do runbook de operação: o antecedente existia na linha, só não era um alvo
# reconhecível aqui.
# Dockerfile entra sem ponto porque é assim que a doc de deploy o cita.
const PTR_TGT : String = "((?:[A-Za-z0-9_./-]+\\.(?:gd|py|sh|yml|yaml|json|sql|cfg|conf|md|csv|mjs|toml|godot|tscn|example|html))|(?:[A-Za-z0-9_./-]*Dockerfile))"

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

# Estrutura da âncora (#124, fatia 2): `arquivo:@símbolo` só vale se o símbolo RESOLVE
# no alvo — uma declaração, num arquivo que tenha modelo de declaração. É a metade que
# o harness pode julgar sem discordar da régua bash: as outras duas (`prosa`, `bloco`)
# dependem do modelo de cláusula, e dois modelos de cláusula em duas réguas é a
# discórdia encomendada. Devolve "" quando não há o que acusar.
static func _AnchorStruct(sym : String, ext : String, symSpans : Dictionary) -> String:
	if ext != "gd" and ext != "sh" and ext != "py":
		return "`%s`: âncora em `%s`, arquivo sem modelo de declaração — âncora ali é linha disfarçada" % [sym, ext]
	var list : Array = symSpans.get(sym, [])
	if list.is_empty():
		return "`%s`: nenhuma declaração no alvo — a âncora aponta para um nome que o arquivo não declara" % sym
	if list.size() > 1:
		return "`%s`: %d declarações no alvo — âncora ambígua é acusação, não escolha" % [sym, list.size()]
	return ""

# Continuação de ponteiro (#124, fatia 5): o número sem arquivo entre backticks herda o arquivo
# do ÚLTIMO `arquivo:NN` ou `arquivo:@simbolo` ANTERIOR NA MESMA LINHA, e só ali. Herdar da linha
# de cima deixaria o veredito depender de onde a frase quebrou no arquivo — o mesmo defeito de
# juiz que le a linha errada que o #116 registrou. Sem antecedente devolve "", e a decisão é
# acusar, não adivinhar. A ordenação é por POSIÇÃO e não por regex porque é a posição que decide
# a cláusula: um ponteiro que vem depois do número herdado não pode ser o antecedente dele.
static func _ContHerdancas(line : String, ptrRx : RegEx, ancRx : RegEx, contRx : RegEx) -> Array:
	var eventos : Array = []
	for pm in ptrRx.search_all(line):
		eventos.append([pm.get_start(), "p", String(pm.get_string(1)), pm])
	for am in ancRx.search_all(line):
		eventos.append([am.get_start(), "a", String(am.get_string(1)), am])
	for cm in contRx.search_all(line):
		eventos.append([cm.get_start(), "c", "", cm])
	eventos.sort_custom(func(a, b) -> bool: return int(a[0]) < int(b[0]))
	var saida : Array = []
	var ultimo : String = ""
	for ev in eventos:
		if String(ev[1]) == "c":
			saida.append([ev[3], ultimo])
		else:
			ultimo = String(ev[2])
	return saida

# Metade estrutural do alvo herdado: a linha tem que caber no arquivo e nenhuma das duas bordas
# pode cair em branco — os mesmos dois predicados que a régua aplica ao ponteiro nomeado. Modelo
# de cláusula (identidade, literal, mensagem) fica com a régua que já o tem: reimplementar aqui
# seria criar o segundo modelo que discorda do primeiro, e é por isso que o braço de âncora
# acima declara o que não julga em vez de adivinhar. Devolve "" quando não há o que acusar.
static func _ContStruct(src : PackedStringArray, from : int, to : int) -> String:
	if from > src.size() or to > src.size():
		return "cai em %d-%d, que não cabe num arquivo de %d linhas" % [from, to, src.size()]
	if _LineBlank(src, from):
		return "a linha %d está em branco" % from
	if _LineBlank(src, to):
		return "a linha %d está em branco" % to
	return ""

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

# O ponteiro foi escrito com o alvo ou com o enfeite de linha? `cited` chega limpo da
# varredura ("docs/x.md" no exemplo) e com âncora dos controles ("probe_lie.md:5"), e
# `get_extension()` de "probe_lie.md:5" é "md:5" — sem tirar a âncora, o controle e a
# doc seguiriam caminhos diferentes da régua.
static func _IsProseTarget(cited : String) -> bool:
	return String(cited).split(":")[0].get_extension().to_lower() == "md"

# Alvo de PROSA: não há declaração para tocar, então o índice de símbolos vem vazio de
# propósito e o braço (b) da identidade, que confere o nome contra o ARQUIVO INTEIRO,
# perdoa a linha errada por construção. O achado de 2026-09-29, ao escrever o registro
# da #107: a linha 115 de `docs/development/testing.md` é onde `companion_gates()`
# mora, e a frase que o localizava apontava para a 99 — nenhuma régua reclamava, porque
# nenhuma olhava a LINHA de um alvo `.md`. Três locadores assim já estavam tortos. Aqui a
# unidade de prova é a LINHA: se o doc escreve o nome em algum lugar mas não no
# intervalo citado, a frase aponta para o arquivo certo e a janela errada. As três
# saídas são as da régua de série, inclusive o SILÊNCIO de "muda" quando o nome não
# está no arquivo: uma frase pode nomear um símbolo de código ao citar o parágrafo que
# descreve a mesma coisa em português, e acusar isso é máquina de reescrever prosa.
static func _ProseTargetVerdict(src : PackedStringArray, symName : String, from : int, to : int) -> String:
	if symName == "" or src.is_empty():
		return "muda"
	if not _MentionsWord(String("\n").join(src), symName):
		return "muda"
	for j in range(maxi(from, 1), mini(to, src.size()) + 1):
		if _MentionsWord(String(src[j - 1]), symName):
			return "dentro"
	return "fora"

# Casa única do veredito de identidade (regra 6): laço da varredura e controles
# injetados em memória chamam este mesmo corpo, então uma mentira inventada mede a
# régua exata com que a doc real é medida — não uma cópia dela.
# Os quatro braços, e só eles:
# (a) o nome É declarado no arquivo -> o intervalo tem que tocar o span (ou a linha
#     citada tem que mostrar o nome, que é o caso do call site honesto);
# (b) o nome não é declarado mas tem FORMA de declaração e o arquivo inteiro não tem
#     aquela palavra -> SÍMBOLO FANTASMA. É o buraco que o juiz cego de 2026-09-28
#     provou: a linha citada existe, é cheia, a régua de resolução aprova, e a frase
#     afirma que ali está `Foo()` quando o arquivo nunca viu esse nome. Sem este
#     braço a identidade só mordida onde já havia declaração, e ponteiro para corpo
#     alheio com nome inexistente continuava "conferido";
# (c) o nome não é declarado, tem outra grafia no arquivo -> caixa não é identidade;
# (d) o ALVO é prosa (`.md`) -> não há span, e o que julga é a linha citada
#     (`_ProseTargetVerdict`). `opinion` recebe o total que teve opinião, porque um
#     eixo novo verde por não achar com o que comparar não é régua.
static func _IdentityVerdict(spans : Dictionary, src : PackedStringArray, symName : String,
		shape : String, from : int, to : int, cited : String, opinion : Dictionary = {}) -> String:
	if symName == "":
		return ""
	if _IsProseTarget(cited):
		var prose : String = _ProseTargetVerdict(src, symName, from, to)
		if prose == "muda":
			return ""
		opinion["prose"] = int(opinion.get("prose", 0)) + 1
		if prose == "dentro":
			return ""
		return "%d-%d cita `%s` como evidência e o nome não está nessa linha de `%s` — está em outra, e abrir no número citado não mostra o que a frase jura" % [from, to, symName, cited]
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
	ptrRx.compile("`" + PTR_TGT + ":(\\d+)(?:-(\\d+))?`")
	var symRx : RegEx = RegEx.new()
	symRx.compile("`([^`]+)`")
	# O índice do corpus é o MESMO da varredura: ponteiro de linha e âncora, lado a lado.
	# Sem a âncora aqui, o controle que morde a costura passaria numa casa que a régua
	# real não tem — fixture que reproduz o bug velho não prova o conserto dele.
	var ancRx : RegEx = RegEx.new()
	ancRx.compile("`" + PTR_TGT + ":@([A-Za-z_][A-Za-z0-9_]*)`")
	var recs : Array = []
	for p in docLines.size():
		var pTxt : String = String(docLines[p])
		for pm in ptrRx.search_all(pTxt):
			recs.append([p, pm.get_start(), pm.get_end()])
		for am in ancRx.search_all(pTxt):
			recs.append([p, am.get_start(), am.get_end(), true])
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
			var verdict : String = _IdentityVerdict(symSpans, src, String(served[1]), String(served[0]), from, to, tag, tally)
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
		ptrLine : int, m : RegExMatch, wholeProse : bool) -> Array:
	var best : Array = []
	var bestGap : int = 1000000000
	for wl in range(maxi(0, ptrLine - 2), mini(docLines.size(), ptrLine + 3)):
		var wLine : String = String(docLines[wl])
		# `.md` e JSON de conf são prosa inteira, porque JSON não tem marcador de comentário; em
		# código só o comentário fala de evidência, e o corpo da função nomeia coisas não citadas.
		if not wholeProse and not wLine.strip_edges().begins_with("#"):
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
# esta passada a varredura lia só `.md`. O custo é provado na própria rodada: os
# knobs de troca eram apontados para linhas que um fatiamento tinha movido, e
# `Peers.gd` se autodata em linhas que o próprio corte apagou. Nenhum portão disse
# nada porque nenhum olhava comentário. Varredura ampliada para as quatro raízes
# de código mantidas, e só linha de comentário — corpo de função não é evidência. Em
# 2026-09-29 entrou `res://data`: JSON é prosa sem marcador (`_note`, `_campos` e
# `_estado_atual` juram número), e ali morriam falsos os três ponteiros do censo.
static func _CodeAndDataProseAll() -> Array[String]:
	var skipped : Array[String] = ["addons", "archive", "graphify-out"]
	var exts : Array[String] = [".gd", ".py", ".sh", ".json"]
	var roots : Array[String] = ["res://sources", "res://tests", "res://scripts", "res://companion", "res://data"]
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
# ponteiro escrito nela viraria evidência falsa no run seguinte. E (9) CONTINUAÇÃO (#124, fatia 5):
# um número sem arquivo, cujo arquivo é o do último ponteiro ANTERIOR NA MESMA LINHA. A régua bash
# passou a ler essa classe na passada do órfão; um gémeo que lê só a metade nomeada da árvore faz os
# dois censos serem incomparáveis, e juiz que vê número diferente é a doença que o #116 registrou.
func SuiteEvidencePointers() -> void:
	print("[suite] ponteiros de evidência")
	var ptrRx : RegEx = RegEx.new()
	ptrRx.compile("`" + PTR_TGT + ":(\\d+)(?:-(\\d+))?`")
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
	# — são os cinco diretórios de prosa (quatro de código mais `res://data`), e o
	# JSON tem que estar na lista: sem ele, um `roots` mudo devolveria verde.
	var proseDocs : Array[String] = _CodeAndDataProseAll()
	if not Check(proseDocs.size() >= 100 and proseDocs.has("res://data/conf/seasons.json"),
			"varredura acha o comentário de código e o JSON de conf que promete ler: %d arquivos" % proseDocs.size()):
		return
	var sweep : Array[String] = []
	sweep.append_array(docs)
	sweep.append_array(proseDocs)
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
	# Quantas citações a linha de `.md` o eixo de prosa teve OPINIÃO (o nome está no
	# arquivo, então há linha certa ou errada a julgar). É o número que prova que o
	# braço (d) está olhando, e não verde por não ter com o que comparar.
	var proseOpinion : Dictionary = {}
	# Nome de suíte em backticks NA MESMA LINHA do ponteiro: é a forma como a prosa deste repo
	# amarra as duas coisas ("`SuiteRefund` (`tests/IdleTests.gd:@SuiteRefund`)"). Olhar a linha e
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
	# A ÂNCORA (#124) não é julgada por este laço — o braço dela é o (8), abaixo, e a
	# metade de cláusula fica com `scripts/check_doc_drift.sh`. Ela PRECISA estar no
	# índice de citações da doc, porque o vínculo nome→ponteiro decide por proximidade:
	# sem a âncora na casa, o nome colado nela é amarrado ao `arquivo:NN` da frase
	# vizinha, e o vizinho é acusado por uma promessa que não é dele. Foi a costura que
	# a migração da fatia 3 abriu — 103 números viraram âncora e dois ponteiros
	# honestos passaram a levar culpa alheia.
	var ancRx : RegEx = RegEx.new()
	ancRx.compile("`" + PTR_TGT + ":@([A-Za-z_][A-Za-z0-9_]*)`")
	# O número SEM ARQUIVO (#124, fatia 5): o `:` colado no backtick de abertura é o que separa
	# esta classe da de ponteiro nomeado, e exigir o backtick é o que impede um endereço com porta
	# de ser lido como continuação da frase anterior. Os grupos numeram DESLOCADOS em relação ao
	# `ptrRx` — aqui o primeiro número é o grupo 1, ali é o grupo 2 — e é por isso que a herança
	# devolve o `RegExMatch` cru e quem decide o alvo é o braço, não um índice compartilhado.
	var contRx : RegEx = RegEx.new()
	contRx.compile("`:(\\d+)(?:-(\\d+))?`")
	for docPath in sweep:
		var wholeProse : bool = ["md", "json"].has(String(docPath).get_extension().to_lower())
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
			if not wholeProse and not pLine.strip_edges().begins_with("#"):
				continue
			for pm in ptrRx.search_all(pLine):
				ptrRecs.append([p, pm.get_start(), pm.get_end()])
			# A âncora entra como quarto campo `true`: quem lê o registro pelos três
			# primeiros não muda de comportamento, e `_OwnerPtr` passa a saber que ali
			# também há uma citação — com nome, que é o que compete pelo vínculo.
			for am in ancRx.search_all(pLine):
				ptrRecs.append([p, am.get_start(), am.get_end(), true])
		for i in docLines.size():
			var ptrLine : String = String(docLines[i])
			# Em código só o comentário é prosa de evidência; em JSON toda linha é, porque não
			# existe marcador de comentário ali. Corpo de função pode conter um shape `x.gd:12`.
			if not wholeProse and not ptrLine.strip_edges().begins_with("#"):
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
				if not wholeProse:
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
				# declarado no arquivo citado e o intervalo citado tem que tocar o span dele
				# — ou, quando o alvo é prosa, o nome tem que estar na própria linha citada.
				# O vínculo é feito em duas metades: `_OwnerPtr` diz a quem um nome pertence
				# (direção da prosa, teto de cláusula em caracteres, nenhum ponteiro no meio)
				# e `_ServedName` devolve, dentre os nomes daquele ponteiro, o mais perto dele
				# — um número localiza UM símbolo, e o nome dito a 60 caracteres de distância
				# quando o vizinho está a 8 não é o que a frase estava procurando.
				var symExt : String = String(resPath).get_extension().to_lower()
				var proseTarget : bool = symExt == "md"
				if proseTarget or symExt == "gd" or symExt == "sh" or symExt == "py":
					if not symCache.has(resPath):
						symCache[resPath] = _SymbolSpans(src, symExt)
					var symSpans : Dictionary = symCache[resPath]
					# Em `.md` o índice é vazio DE PROPÓSITO (prosa não declara), e o que
					# julga é a linha citada; o gate de `is_empty()` só vale para código,
					# onde sem span não há régua nenhuma a chamar.
					if proseTarget or not symSpans.is_empty():
						var served : Array = _ServedName(docLines, symRx, ptrRecs, i, m, wholeProse)
						if not served.is_empty():
							var symName : String = String(served[1])
							if symSpans.has(symName):
								comIdentidade += 1
							var idrift : String = _IdentityVerdict(symSpans, src, symName, String(served[0]), from, to, cited, proseOpinion)
							if idrift != "":
								identes.append("%s: %s → %s" % [site, cited, idrift])
				# (7) SÉRIE NOMEADA × ARQUIVO QUE A EMITE. Um ponteiro pode jurar que a
				# linha `X.gd:A-B` é onde `shambleta_foo` é emitida sem nomear símbolo de
				# código nenhum — e a régua de identidade, que julga identificadores
				# declarados, passa adiante: `MetricsBody()` é o corpo de uma função
				# inteira, cobre qualquer intervalo que caia nela, então "está no corpo" era
				# verdade mesmo quando o intervalo citado já não continha a série que a
				# frase enumerava. Aqui o nome é LIDO da linha que cita e conferido no intervalo
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
					# Posse, pela MESMA casa da régua de métrica acima (`_OwnerPtr`): a
					# janela é de ±2 linhas, e numa tabela em que cada linha é uma cadeira
					# com os seus ponteiros, a mensagem dita na linha 188 era julgada contra
					# os ponteiros das linhas 186 e 187 — e o ponteiro de 188 que NÃO carrya
					# a frase (o da confissão do `AIAgent.gd`) era acusado por ela. Sem
					# vínculo, a régua julga menção como citação, que é exatamente o defeito
					# que a casa `_OwnerPtr` existe para impedir. A posição da mensagem é
					# devolvida para a linha/coluna da doc (a janela é um texto só), e só
					# então perguntamos a quem ela pertence.
					var msgWinCol : int = int(msgMatch.get_start())
					var msgLine : int = maxi(0, i - 2)
					var msgAcc : int = 0
					for wl in range(maxi(0, i - 2), mini(docLines.size(), i + 3)):
						var wlen : int = String(docLines[wl]).length() + 1
						if msgAcc + wlen > msgWinCol:
							msgLine = wl
							break
						msgAcc += wlen
					var ownMsg : Array = _OwnerPtr(ptrRecs, docLines, msgLine, msgWinCol - msgAcc)
					if ownMsg.is_empty() or int(ownMsg[1]) != int(m.get_start()):
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
	# (8) ÂNCORA (#124, fatia 2): `arquivo:@símbolo`. A régua de §28 do
	# `scripts/check_doc_drift.sh` julga a âncora inteira — nome na cláusula e literal
	# dentro do bloco — e é ela que decide a marreta. O braço de cá é o que o harness
	# precisa poder acusar sozinho, sem python na imagem: a âncora tem de RESOLVER,
	# porque resolver é o que apodrece quando o símbolo muda de nome, passa a ser
	# declarado duas vezes ou morre num arquivo sem modelo de declaração. Os outros dois
	# vereditos são de cláusula, e cláusula tem dois modelos — o da régua bash e um
	# daqui; reimplementar aqui seria criar a segunda régua que discorda da primeira,
	# que é justamente a doença que #116 e #123 registram. Então este braço julga
	# estrutura e declara em voz alta o que não julga. O `ancRx` é o hoisted de cima — o
	# mesmo padrão, não uma segunda leitura do shape.
	var anchorias : Array[String] = []
	var ancJulgadas : int = 0
	for ancPath in sweep:
		var ancProse : bool = ["md", "json"].has(String(ancPath).get_extension().to_lower())
		var ancLines : PackedStringArray = _RepoFile(ancPath).split("\n")
		for a in ancLines.size():
			var ancLine : String = String(ancLines[a])
			# Em código só o comentário é prosa de evidência; em `.md` e em JSON toda
			# linha é — é o corpo que a suíte já usa para o ponteiro de linha.
			if not ancProse and not ancLine.strip_edges().begins_with("#"):
				continue
			for am in ancRx.search_all(ancLine):
				ancJulgadas += 1
				var citedFile : String = String(am.get_string(1))
				var sym : String = String(am.get_string(2))
				var site : String = "%s:%d" % [String(ancPath).trim_prefix("res://"), a + 1]
				var target : String = _PtrResolve(citedFile)
				if target == "":
					anchorias.append("%s: âncora `%s` não resolve a arquivo na árvore" % [site, citedFile])
					continue
				var tExt : String = String(target).get_extension().to_lower()
				if not lineCache.has(target):
					lineCache[target] = _RepoFile(target).split("\n")
				if not symCache.has(target):
					symCache[target] = _SymbolSpans(lineCache[target], tExt)
				var verdict : String = _AnchorStruct(sym, tExt, symCache[target])
				if verdict != "":
					anchorias.append("%s: %s" % [site, verdict])
	CheckEq(anchorias.size(), 0, "âncora: %d `arquivo:@símbolo` julgadas pela estrutura, nenhuma cega (%s)" % [ancJulgadas, " | ".join(anchorias)])
	print("  [info] âncora: %d `arquivo:@símbolo` vistas pela varredura, %d acusadas — o censo é impresso também no verde, porque piso que ninguém lê não discrimina walk parado de árvore honesta" % [ancJulgadas, anchorias.size()])
	# O piso é do tamanho do que a varredura vê hoje, e a razão de existir dele é a
	# mesma de todo censo daqui: sem ele, "0 acusações" pode significar que o `sweep`
	# parou de ler o arquivo onde as âncoras moram, ou que a regex descendeu para
	# zero. O número NÃO é copiado da régua bash — os dois corpos são diferentes
	# (a bash pula os registros datados para linha e esta suíte tem a sua lista), e
	# comparar censos de corpora diferentes seria a discórdia encomendada.
	# 8 → 90 na fatia 3: oito era o censo da fatia 2, e depois de 103 ponteiros
	# migrados um piso de oito já não distinguia "walk parado" de "metade da migração
	# invisível". 101 é o medido nesta varredura em 2026-09-30; o piso fica onze abaixo
	# porque a migração é minha e o que eu quero é que a PRÓXIMA pessoa que encolher o
	# corpus tenha de explicar, não que o gate verdeje sozinho.
	Check(ancJulgadas >= 90,
			"âncora: %d `arquivo:@símbolo` encontradas na varredura — abaixo de 90 a régua estrutural está verde por não olhar (%s)" % [ancJulgadas, "fatia 3 migrou 103; 101 é o medido"])
	# Os três modos de a âncora apodrecer, mordidos em mesa, porque na árvore limpa
	# eles não têm como aparecer: o control negativo é a única prova de que a
	# acusação existe. E o positivo, para a régua não virar máquina de acusar.
	var ancMesa : PackedStringArray = PackedStringArray([
		"# cabecalho",
		"const GATE_RUN : int = 1",
		"",
		"func Beta() -> void:",
		"\tvar WAL_SALT = 1",
		"func Beta() -> void:",
		"\tBeta.run()",
	])
	var ancSpans : Dictionary = _SymbolSpans(ancMesa, "gd")
	Check(_AnchorStruct("GATE_RUN", "gd", ancSpans) == "",
			"âncora morde no certo: `GATE_RUN` declarado uma vez resolve (%s)" % _AnchorStruct("GATE_RUN", "gd", ancSpans))
	Check(_AnchorStruct("Zeta_Vivo", "gd", ancSpans).contains("nenhuma declaração"),
			"âncora morde no inexistente: símbolo que a mesa não declara é acusado (%s)" % _AnchorStruct("Zeta_Vivo", "gd", ancSpans))
	Check(_AnchorStruct("Beta", "gd", ancSpans).contains("2 declarações"),
			"âncora morde no duplo: dois `func Beta` na mesa são âncora ambígua, não escolha (%s)" % _AnchorStruct("Beta", "gd", ancSpans))
	Check(_AnchorStruct("README", "md", ancSpans).contains("sem modelo de declaração"),
			"âncora morde no arquivo: `.md` não declara, e âncora ali é linha disfarçada (%s)" % _AnchorStruct("README", "md", ancSpans))
	# (9) CONTINUAÇÃO (#124, fatia 5): o número SEM ARQUIVO. A régua de bash passou a ler esta
	# classe na passada do órfão e este gémeo não a lia: dois juízes da mesma árvore vendo
	# números diferentes é a doença que o #116 registrou, não um detalhe de paridade de código.
	# O braço julga a metade que os dois podem julgar sem inventar um segundo modelo de cláusula
	# — o vínculo é a POSIÇÃO na linha (é o que a frase promete), o alvo passa pelo mesmo
	# `_PtrResolve` do ponteiro nomeado e a estrutura é a mesma dupla borda: cabe no arquivo, não
	# cai em branco. Identidade, literal e mensagem continuam com a régua que já os tem.
	var contos : Array[String] = []
	var contLidas : int = 0
	var contJulgadas : int = 0
	var contOrfas : int = 0
	# Os quatro registros datados ficam fora, com a mesma lista e pela mesma razão da régua bash:
	# num registro um número sem arquivo cita o que a frase dizia NAQUELA rodada, e reescrevê-lo
	# é editar história — herdá-lo da linha de cima para torná-lo legível seria introduzir aqui o
	# defeito que este braço existe para não ter. É folga de ESCOPO, não de métrica: o censo
	# impresso abaixo é o medido com esses arquivos fora, e diz quantos ficaram dentro.
	var contSkip : Array[String] = ["CHANGELOG.md", "progress.md", "ROADMAP_COMERCIAL.md", "BLIND_JUDGE_PROTOCOL.md"]
	for contPath in sweep:
		if contSkip.has(String(contPath).get_file()):
			continue
		var contProse : bool = ["md", "json"].has(String(contPath).get_extension().to_lower())
		var contLines : PackedStringArray = _RepoFile(contPath).split("\n")
		for c in contLines.size():
			var contLine : String = String(contLines[c])
			if not contProse and not contLine.strip_edges().begins_with("#"):
				continue
			for herd in _ContHerdancas(contLine, ptrRx, ancRx, contRx):
				contLidas += 1
				var cmatch : RegExMatch = herd[0]
				var cfile : String = String(herd[1])
				var csite : String = "%s:%d" % [String(contPath).trim_prefix("res://"), c + 1]
				if cfile == "":
					contOrfas += 1
					contos.append("%s: continuação %s sem nenhum `arquivo:NN` ou `arquivo:@simbolo` antes, na mesma linha — sem antecedente não há de que arquivo falar, e a régua que adivinha pela linha de cima passa a depender de onde a frase quebrou" % [csite, cmatch.get_string(0)])
					continue
				var ctarget : String = _PtrResolve(cfile)
				if ctarget == "":
					contos.append("%s: continuação %s herda de `%s`, que não resolve a arquivo na árvore" % [csite, cmatch.get_string(0), cfile])
					continue
				if not lineCache.has(ctarget):
					lineCache[ctarget] = _RepoFile(ctarget).split("\n")
				var cfrom : int = int(cmatch.get_string(1))
				var cto : int = int(cmatch.get_string(2))
				if cto < cfrom:
					cto = cfrom
				contJulgadas += 1
				var cverdict : String = _ContStruct(lineCache[ctarget], cfrom, cto)
				if cverdict != "":
					contos.append("%s: continuação %s herda `%s:%d-%d`, que %s" % [csite, cmatch.get_string(0), cfile, cfrom, cto, cverdict])
	CheckEq(contos.size(), 0, "continuação: %d números sem arquivo lidos, %d julgados pelo antecedente da MESMA linha, %d órfãos (%s)" % [contLidas, contJulgadas, contOrfas, " | ".join(contos)])
	print("  [info] continuação: %d números sem arquivo vistos fora dos registros datados, %d julgados pelo arquivo herdado, %d órfãos — o censo sai também no verde porque piso sem número impresso não discrimina walk parado de árvore honesta" % [contLidas, contJulgadas, contOrfas])
	# O piso é o medido, e o medido é pequeno porque a classe é pequena: oito números na árvore de
	# hoje. A comparação é o ponto desta fatia — se um dos dois censos se mover e o outro não, a
	# primeira pergunta é qual dos dois parou de ler —, e é por isso que aqui não há a folga de
	# onze que o piso da âncora tem: com população oito, folga três deixaria três arquivos
	# inteiros saírem da varredura em silêncio. Oito, e não os nove que a régua bash leu na
	# passada do órfão, porque um daqueles nove era uma PORTA escrita em forma de continuação: no
	# runbook de escala o Alertmanager tinha o número de porta colado a dois-pontos dentro de
	# backticks, sem arquivo, logo depois de um ponteiro de linha. Este braço herdou a porta para
	# o arquivo do vizinho e a acusou de cair além da última linha. A bash não podia acusá-la
	# naquele momento: o `verdict` de lá não tinha predicado de fim de arquivo — a fatia de
	# faixa era cortada pelo comprimento do arquivo e o check de branco era condicionado a a
	# borda estar dentro dele, então número depois da última linha fatiava vazio e devolvia
	# "nada a acusar". A porta voltou a ser porta na prosa, o censo desceu um, e o piso desce
	# com ele aqui e em `CONT_MIN` na bash, com os dois números medidos e ditos. O predicado
	# foi escrito na passada seguinte (motivo `alem` no `verdict` de lá, com quatro controles
	# novos), e a auditoria que ele permitia fez junto: zero ponteiros nomeados da árvore caía
	# além do fim do alvo. Os dois juízes voltam a ler a mesma classe.
	Check(contLidas >= 8,
			"continuação: %d números sem arquivo na varredura — abaixo de 8 o braço está verde por não olhar (%s)" % [contLidas, "8 é o medido fora dos quatro registros datados"])
	# A herança mordendo em mesa, nos modos que a árvore limpa não mostra: sem o control negativo
	# o braço pode estar verde por não acusar nada, e sem o positivo vira máquina de acusar
	# citação honesta. A linha é inventada de propósito — o que se prova aqui é a aritmética do
	# vínculo (posição na linha, e QUAL grupo do regex é o número), não um fato da árvore. O
	# deslocamento é o defeito que o adaptador `Herdado` da régua bash existe para evitar: no
	# ponteiro nomeado o arquivo é o grupo 1 e os números vêm depois; no número solo o primeiro
	# número É o grupo 1. Trocar um pelo outro devolve um alvo legível e errado.
	var herdMesa : Array = _ContHerdancas("abre com `sources/x.gd:10`, continua em `:20-22`, ancora em `sources/y.gd:@Foo` e continua de novo em `:30`", ptrRx, ancRx, contRx)
	Check(herdMesa.size() == 2, "continuação morde no censo: a linha da mesa tem dois números sem arquivo (%d achados)" % herdMesa.size())
	if herdMesa.size() == 2:
		var hMesa0 : RegExMatch = herdMesa[0][0]
		Check(String(herdMesa[0][1]) == "sources/x.gd",
				"continuação herda do ponteiro anterior da mesma linha (herdou \"%s\")" % String(herdMesa[0][1]))
		Check(int(hMesa0.get_string(1)) == 20 and int(hMesa0.get_string(2)) == 22,
				"continuação numera no grupo certo: o `:20-22` da mesa é 20 e 22, não os números deslocados do ponteiro nomeado (grupo 1 = \"%s\", grupo 2 = \"%s\")" % [hMesa0.get_string(1), hMesa0.get_string(2)])
		Check(String(herdMesa[1][1]) == "sources/y.gd",
				"âncora é antecedente legítimo: o número depois de uma âncora fala daquele arquivo, e foi assim que a tabela de portas do runbook passou a ser julgada (herdou \"%s\")" % String(herdMesa[1][1]))
	var hOrfa : Array = _ContHerdancas("vem `:20` primeiro, e só depois `sources/x.gd:10`", ptrRx, ancRx, contRx)
	Check(hOrfa.size() == 1 and String(hOrfa[0][1]) == "",
			"continuação sem antecedente na linha é órfã, nunca herdada da linha de cima (%d achada(s))" % hOrfa.size())
	var contMesaSrc : PackedStringArray = PackedStringArray(["cheia", "", "outra cheia"])
	Check(_ContStruct(contMesaSrc, 1, 3) == "",
			"continuação não morde no alvo são: 1-3 cabe no arquivo de três linhas e nenhuma borda é branco (%s)" % _ContStruct(contMesaSrc, 1, 3))
	Check(_ContStruct(contMesaSrc, 2, 2).contains("em branco"),
			"continuação morde na borda em branco: herdada para a linha vazia é acusada (%s)" % _ContStruct(contMesaSrc, 2, 2))
	Check(_ContStruct(contMesaSrc, 3, 9).contains("arquivo de 3"),
			"continuação morde no fim do arquivo: herdada além da última linha é acusada (%s)" % _ContStruct(contMesaSrc, 3, 9))
	CheckEq(quebrados.size(), 0, "ponteiros: %d referências arquivo:linha conferidas, nenhuma fora do arquivo (%s)" % [conferidos, " | ".join(quebrados)])
	CheckEq(vazios.size(), 0, "ponteiros: nenhuma das %d referências cai em linha em branco — ponteiro em branco não mostra nada para quem abre no número citado (%s)" % [conferidos, " | ".join(vazios)])
	CheckEq(derrapados.size(), 0, "ponteiros: %d mensagens de check citadas na prosa batem com a linha indicada (%s)" % [comMensagem, " | ".join(derrapados)])
	CheckEq(deslocados.size(), 0, "ponteiros: %d citações que nomeiam uma suíte e dão o número caem dentro do span dela (%s)" % [comSuite, " | ".join(deslocados)])
	CheckEq(identes.size(), 0, "ponteiros: %d citações que nomeiam um símbolo caem no span daquele símbolo (ou numa linha que o usa) — e não no corpo de um vizinho — e %d alvos de arquivo de prosa tiveram o nome julgado contra a LINHA citada (%s)" % [comIdentidade, int(proseOpinion.get("prose", 0)), " | ".join(identes)])
	# A régua nova só vale se estiver de fato olhando: quatro é o mínimo dos ponteiros que
	# hoje nomeiam suíte (handoff da vitrine, e os três do documento de auditoria do beta).
	# Com `comSuite` em zero o comparador estaria verde por não achar com o que comparar.
	Check(comSuite >= 4, "ponteiros: %d citações com nome de suíte na mesma linha do número foram julgadas pelo span" % comSuite)
	# A ampliação para fora de `.md` só vale se ela estiver de fato olhando
	# alguma coisa: um `_CodeAndDataProseAll()` mudo, ou uma `exts` que não casa com
	# as cinco raízes, devolve "0 quebrados" pelo pior motivo possível. O
	# comparador em si já tem prova de que morde (nove ponteiros apodrecidos foi o
	# que ele achou na doc na rodada em que entrou); o que é novo aqui é a entrada,
	# então é a entrada que este check mede.
	Check(conferidosCode >= 20, "ponteiros: %d de %d referências vieram de prosa fora de `.md` (comentário e JSON de conf) — a varredura ampliada está olhando" % [conferidosCode, conferidos])
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
	# Classe F — ALVO DE PROSA. Um ponteiro para dentro de `.md` não tem declaração para
	# tocar, e o braço que confere o nome contra o ARQUIVO INTEIRO perdoa a linha errada:
	# foi assim que a linha 115 de `docs/development/testing.md`, onde `companion_gates()`
	# mora, deixou de ser o número que a frase citava: ela apontava para a 99, e continuava
	# verde. O fixture é um `.md` de cinco
	# linhas e o que muda entre a mentira e a verdade é SÓ o número. A terceira perna é o
	# silêncio: nomear um símbolo de código ao citar a linha do doc que descreve a mesma
	# coisa sem escrever aquele símbolo não é acusação — é máquina de reescrever prosa.
	var mdSrc : PackedStringArray = PackedStringArray([
		"# Prosa de prova",										# 1
		"",														# 2
		"O gate `companion_gates()` roda no runner.",			# 3
		"",														# 4
		"Outra linha fala de `harness_marker()`.",				# 5
	])
	var fTally : Dictionary = {}
	var fLie : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`companion_gates()` está na tabela (`probe_lie.md:5`).",
	]), mdSrc, _SymbolSpans(mdSrc, "md"), "probe_lie.md:5", fTally)
	var fTruth : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`companion_gates()` está na tabela (`probe_lie.md:3`).",
	]), mdSrc, _SymbolSpans(mdSrc, "md"), "probe_lie.md:3", fTally)
	var fMuda : Array[String] = _IdentityJudgeCorpus(PackedStringArray([
		"`ZetaLocked()` é o teto (`probe_lie.md:3`).",
	]), mdSrc, _SymbolSpans(mdSrc, "md"), "probe_lie.md:3", fTally)
	Check(_PtrResolve("probe_lie.md") == "",
			"a mentira de prosa nunca toca o disco: `probe_lie.md` não resolve em `%s`" % _PtrResolve("probe_lie.md"))
	CheckEq(fLie.size(), 1, "mentira injetada F (nome no `.md`, linha errada) produz [FAIL] na régua: %s" % " | ".join(fLie))
	CheckEq(fTruth.size(), 0, "o mesmo nome com o número certo silencia (F): %s" % " | ".join(fTruth))
	CheckEq(fMuda.size(), 0, "nome que o `.md` não escreve em lugar nenhum não é julgado (F): %s" % " | ".join(fMuda))
	Check(fLie.size() == 1 and fLie[0].contains("companion_gates") and fLie[0].contains("5"),
			"mentira F é detectada pelo símbolo e pela linha: %s" % " | ".join(fLie))
	# O piso de opinião do eixo: `muda` não conta, então dos três controles acima exatamente
	# dois têm linha certa ou errada a julgar. É o mesmo número que a varredura soma em
	# `proseOpinion`, por isso a casa é a MESMA decisão e não uma contagem à parte.
	CheckEq(int(fTally.get("prose", 0)), 2,
			"o braço de prosa teve opinião sobre %d dos três controles F — sem isso ele estaria verde por não olhar nada" % int(fTally.get("prose", 0)))
	# Classe G — A ÂNCORA NO ÍNDICE DO VÍNCULO. A fatia 3 migrou 103 ponteiros para
	# `arquivo:@símbolo` e abriu uma costura que nenhuma das duas réguas via: o vínculo
	# nome→ponteiro é por proximidade, e um nome colado numa âncora ficava a 20 caracteres
	# do `arquivo:NN` da frase vizinha — que era acusado por uma promessa que não é dele.
	# Os dois falsos positivos que a migração produziu no gate foram exatamente isso. O
	# control é a MESMA frase, mesma linha, mesmo símbolo, mudando só a presença da âncora
	# no índice: com ela, o nome pertence à âncora e o ponteiro de linha cala; sem ela, o
	# ponteiro é o único dono possível e a régua tem que morder. Sem a segunda perna, o
	# "silêncio" poderia ser apenas o vínculo cego para âncora — que é trocar uma régua
	# muda por outra muda.
	var gDocCom : PackedStringArray = PackedStringArray([
		"A conta fecha em (`probe_lie.gd:5`) e o símbolo `ZetaLocked` está em (`probe_lie.gd:@ZetaLocked`).",
	])
	var gDocSem : PackedStringArray = PackedStringArray([
		"A conta fecha em (`probe_lie.gd:5`) e o símbolo `ZetaLocked` está ali.",
	])
	var gTally : Dictionary = {}
	var gAncorada : Array[String] = _IdentityJudgeCorpus(gDocCom, lieSrc, lieSpans, "probe_lie.gd:5", gTally)
	var gSozinha : Array[String] = _IdentityJudgeCorpus(gDocSem, lieSrc, lieSpans, "probe_lie.gd:5", gTally)
	CheckEq(gAncorada.size(), 0,
			"âncora no índice: o nome colado em `probe_lie.gd:@ZetaLocked` não é servido pelo `:5` da frase (G): %s" % " | ".join(gAncorada))
	CheckEq(gSozinha.size(), 1,
			"a mesma frase sem âncora tem o `:5` como único dono do nome, e a régua morde (G): %s" % " | ".join(gSozinha))
	Check(int(gTally.get("judged", 0)) >= 1,
			"o par G apresentou %d nomes à régua — sem isso as duas pernas acima seriam o mesmo silêncio duas vezes" % int(gTally.get("judged", 0)))
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
	# Terceira recalibração, 2026-09-30, e ela é de ESCOPO, não de número: a fração de
	# um quinto foi escrita quando todo ponteiro nomeado era `arquivo:linha`, e a fatia 3
	# moveu justamente os ponteiros que carregavam nome para `arquivo:@símbolo`. Medidos
	# na nova árvore: 68 nomes em 455 linhas — 15%, abaixo do quinto. Manter a fórmula
	# velha seria chamar a migração de perda de cobertura, quando o que aconteceu é que o
	# nome mudou de casa e a casa nova é julgada pelo braço (8) desta mesma suíte. Então
	# a fração passa a ser da FAMÍLIA de citação nomeada: ponteiro de linha mais âncora,
	# nos dois lados da divisão. Não é afrouxamento gratuito — cada âncora do numerador
	# é uma citação que o braço (8) acusa se o símbolo não resolver, não declarar ou
	# declarar duas vezes (o `anchorias` acima é um CheckEq em zero), e o denominador
	# cresce junto. Folga medida: 169/556 = 30%, contra os 22% de antes do outro corpo.
	Check((comIdentidade + ancJulgadas) * 5 >= conferidos + ancJulgadas,
			"citação nomeada: %d+%d de %d+%d (linha julgada por símbolo, âncoras vistas) é pelo menos um quinto do que a família olha — abaixo disso a mordida medida é do tamanho do que a prosa deixou dizer" % [comIdentidade, ancJulgadas, conferidos, ancJulgadas])
	# O braço (d) nasceu nesta rodada, então o piso é o MEDIDO com margem, não o desejado: a
	# varredura de hoje julga três citações a linha de `.md` com o símbolo nomeado na mesma
	# cláusula, e uma delas é o registro desta própria régua citando a linha que ele prova —
	# o número mexe quando a prosa mexe, por isso o piso é queda-para-baixo e a mordida é
	# provada pelo controle F (opinião sobre exatamente 2 dos 3 casos injetados, com a
	# mentira acusando). O piso só impede que a doc enmudeça e "0 acusações" signifique "0 olhares".
	var comProse : int = int(proseOpinion.get("prose", 0))
	Check(comProse >= 2,
			"ponteiros: %d citações a linha de `.md` tiveram o nome julgado contra a própria linha — sem isso o eixo novo está verde por não olhar nada" % comProse)
	print("  [info] ponteiros: %d referências arquivo:linha (%d em prosa fora de `.md`), %d com mensagem de check na prosa, %d com suíte nomeada na mesma linha, %d com símbolo nomeado na cláusula, %d nomes de suíte, %d pares (série, intervalo) julgados, %d alvos de `.md` julgados por linha" % [conferidos, conferidosCode, comMensagem, comSuite, comIdentidade, citadas.size(), metricos, comProse])

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

# Casa única do predicado de fantasma de harness. Um `tests/<nome>.gd` citado é
# fantasma quando NEM `tests/` o lista NEM algum `scripts/*.sh` o escreve.
#
# Por que a segunda metade existe, e por que é DERIVADA: `check_gate_markers.sh`
# planta os fixtures com que julga o próprio contrato de marcador escrevendo-os no
# scratch do run (`cat > "$WORK/tests/probe_ok.gd"`, `printf … > "$WORK/tests/probe_mixed.gd"`),
# nunca commitando um `tests/probe_ok.gd`. O nome é real (o gate o cria e o cobra) e o
# arquivo não existe entre uma passada e outra — uma allowlist digitada desses nomes
# apodreceria no dia em que o gate ganha um probe novo ou troca o diretório do scratch,
# que é exatamente a doença que esta suíte existe para denunciar. Então a exceção é lida
# da escrita: `SuiteHarnessCitations` varre `scripts/*.sh` pelo padrão `> …tests/<nome>.gd`
# e o que um script escreve existe. Quem nenhum script escreve continua acusado, e é o
# que o par de controles abaixo prova — inclusive contra a própria exceção: o nome
# plantado tem forma de probe e NÃO está na derivação, logo tem que morder.
static func _HarnessGhost(base : String, realFiles : Dictionary, scratch : Dictionary) -> bool:
	return not realFiles.has(base) and not scratch.has(base)

# As mesmas duas metades, aplicadas a um texto de prosa: devolve os nomes citados que
# a régua acusaria. A varredura e os controles chamam este corpo, então o controle
# mede a régua real — não uma cópia dela que poderia esquecer a cláusula `scratch`.
static func _HarnessGhosts(text : String, realFiles : Dictionary, scratch : Dictionary) -> Array[String]:
	var out : Array[String] = []
	var rx : RegEx = RegEx.new()
	if rx.compile("tests/([A-Za-z0-9_]+\\.gd)") != OK:
		return out
	for m : RegExMatch in rx.search_all(text):
		var base : String = String(m.get_string(1))
		if _HarnessGhost(base, realFiles, scratch):
			out.append(base)
	return out

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
	#     `_CodeAndDataProseAll()` — lá dentro a frase descreve o que ERA (o registro
	#     do `gut_runner` apagado mora ali), e confundi-la com mentira seria apagar o
	#     histórico para calar a régua.
	var sweep : Array[String] = []
	sweep.append_array(_MdFilesAll())
	sweep.append_array(_CodeAndDataProseAll())
	if not Check(sweep.size() >= 180, "a varredura de prosa lê %d arquivos — a régua julga a doc, o comentário e o JSON de conf, não só uma tabela" % sweep.size()):
		return
	# Derivado, não redigitado: um gate que PLANTA probes em `tests/` dentro do seu
	# scratch (`cat > "$WORK/tests/probe_ok.gd"`, é o que `check_gate_markers.sh` faz
	# para julgar o próprio contrato de marcador) nomeia na sua fonte um arquivo que
	# só existe enquanto o gate roda. A exceção não é uma lista digitada de nomes que
	# convém: ela é lida de todos os `scripts/*.sh`, no padrão de escrita, e acompanha
	# o gate se ele trocar o nome do probe ou o diretório do scratch. Quem citar um
	# `tests/<nome>.gd` que nenhum script escreve nem lista continua acusado pelo
	# predicado `_HarnessGhost` (a casa única que a varredura e o controle (7) chamam)
	# — inclusive o probe plantado no próprio controle, que tem a forma e não está na
	# derivação.
	var writeRx : RegEx = RegEx.new()
	if writeRx.compile(">{1,2}[[:space:]]*\"?[^\"'[:space:]]*tests/([A-Za-z0-9_]+\\.gd)") != OK:
		Check(false, "o padrão de escrita de probe temporário compila")
		return
	var scratch : Dictionary = {}
	var sdir : DirAccess = DirAccess.open("res://scripts")
	if not Check(sdir != null, "`res://scripts` abre para derivar os probes que um gate planta"):
		return
	sdir.list_dir_begin()
	var sname : String = sdir.get_next()
	while sname != "":
		if sname.ends_with(".sh"):
			for m : RegExMatch in writeRx.search_all(_RepoFile("res://scripts/" + sname)):
				scratch[String(m.get_string(1))] = true
		sname = sdir.get_next()
	sdir.list_dir_end()
	Check(scratch.size() >= 1,
			"a derivação lê os probes que um gate planta no scratch: %d nome(s) — zero aqui é varredura muda, não inocência" % scratch.size())
	var citados : Dictionary = {}
	var fantasmas : Array[String] = []
	for path in sweep:
		var src : String = _RepoFile(String(path))
		for m : RegExMatch in citeRx.search_all(src):
			citados[String(m.get_string(1))] = true
		for ghost : String in _HarnessGhosts(src, realFiles, scratch):
			fantasmas.append("%s → tests/%s" % [String(path).trim_prefix("res://"), ghost])
	fantasmas.sort()
	Check(citados.size() >= 40, "a prosa cita %d harnesses diferentes — censo baixo demais para a acusação de fantasma significar algo" % citados.size())
	CheckEq(fantasmas.size(), 0, "nenhuma citação de harness na prosa nomeia arquivo inexistente (%s)" % " | ".join(fantasmas))

	# (7) Controles: as três réguas acima têm que acusar o que foi plantado. Sem isto,
	#     cada `0` pode ser uma varredura muda — que é o defeito que esta suíte existe
	#     para denunciar, e a rodada cega de 2026-09-28 já viu régua com esse formato.
	#     Cada controle vem em par: o nome falso tem que ser acusado e um nome verdadeiro
	#     tem que sair limpo, senão "acusou" pode ser só um predicado que acusa tudo.
	# E o par agora tem TRÊS lados, porque a régua ganhou uma cláusula de exceção (o
	# probe que um gate planta no scratch): um predicado com exceção só está provado
	# quando se mostra que ela poupa o que tem que poupar E continua mordendo o resto.
	var plantado : String = "harness_que_nao_existe_gd.gd"
	var verdadeiro : String = "reason_toast_test.gd"
	# Nome com a MESMA forma dos probes do gate, que nenhum script escreve: se a exceção
	# fosse uma regra de caixa (`probe_*`) ou uma lista batida à mão, este nome passaria
	# limpo. Ele é o que prova que salva o probe é a derivação, não o prefixo.
	var probeFalso : String = "probe_que_nenhum_gate_escreve.gd"
	Check(not realFiles.has(plantado), "controle: o nome plantado realmente não existe em `tests/`")
	Check(not realFiles.has(probeFalso) and not scratch.has(probeFalso),
			"controle: o probe falso plantado não está em `tests/` nem na derivação de scratch — é o caso que a exceção não pode cobrir")
	Check(realFiles.has(verdadeiro), "controle: o nome verdadeiro do par existe em `tests/` (senão o par abaixo não significa nada)")
	var chavesScratch : Array[String] = []
	for k : String in scratch:
		chavesScratch.append(k)
	chavesScratch.sort()
	var probeDerivado : String = "" if chavesScratch.is_empty() else String(chavesScratch[0])
	Check(probeDerivado != "" and not realFiles.has(probeDerivado),
			"controle: o probe derivado (%s) não existe em `tests/` — é a exceção trabalhando, não um arquivo que passaria de todo jeito" % probeDerivado)
	# O plantio vai EM CIMA da prosa de um doc real (`docs/development/testing.md`, a mesma
	# já lida e guardada no bloco (4)): o controle exerce a régua sobre texto que a
	# varredura consome de verdade, e não sobre uma frase órfã. Se um dia a doc for
	# filtrada para fora da varredura, o controle perde o sentido — e é isto que ele denuncia.
	# O predicado julgado é `_HarnessGhost`, a MESMA casa que a varredura usa: um controle
	# que marca "acusado" só porque o nome apareceu no texto julga menção, não a régua — e
	# aí o par falso/verdadeiro perde o sentido (o nome verdadeiro "acusaria" sempre, e o
	# controle viraria a própria falha que denuncia).
	var prosaBase : String = testingSrc
	var prosaPlantada : String = prosaBase + "\nVer `tests/" + plantado + "`,"
	prosaPlantada += " `tests/" + probeFalso + "`, `tests/" + probeDerivado
	prosaPlantada += "` e `tests/" + verdadeiro + "`, todos na mesma frase.\n"
	Check(_HarnessGhosts(prosaBase, realFiles, scratch).is_empty(),
			"controle: a doc real sem plantio sai limpa — o que acusa no par abaixo foi o plantio, não a base")
	var fantasmasPlantados : Array[String] = _HarnessGhosts(prosaPlantada, realFiles, scratch)
	Check(fantasmasPlantados.has(plantado), "controle de fantasma: a mesma régua acusa o nome plantado na prosa de um doc real")
	Check(fantasmasPlantados.has(probeFalso), "controle de fantasma: a mesma régua acusa um nome com forma de probe que nenhum script escreve")
	Check(not fantasmasPlantados.has(probeDerivado),
			"controle de probe: a mesma régua NÃO acusa o probe que um gate planta no scratch (%d nome(s) derivado(s) de `scripts/*.sh`)" % chavesScratch.size())
	Check(not fantasmasPlantados.has(verdadeiro),
			"controle de fantasma: o mesmo predicado NÃO acusa um harness que existe — a régua varre %d harnesses reais e os trata como existentes" % realFiles.size())
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
	var snapshot : Dictionary = await _SimRun(charID, 972, 180, 1.0, 1, false, -1.0, true)
	var simKills : int = int(snapshot.get("kills", 0))
	var lootTicks : int = int(snapshot.get("loot_ticks", 0))
	var picks : int = int(snapshot.get("drops_picked", 0))
	var potions : int = int(snapshot.get("potions_used", 0))
	print("LOOTPIPE: kills=%d loot_ticks=%d picks=%d potions=%d deaths=%d" % [
		simKills, lootTicks, picks, potions, int(snapshot.get("deaths", 0))])
	Check(simKills > 0, "loot: sessão produtiva (kills=%d)" % simKills)
	Check(lootTicks > 0, "loot: a policy entrou em State.LOOT (loot_ticks=%d)" % lootTicks)
	# A régua é de GRANDEZA de coleta, com a precondição declarada no `_SimRun`
	# (mochila com espaço — ver `_FreeCarriedSlots`), e a conservação do chão é
	# julgada à parte em (4b). Ela continuava existindo só por determinismo de
	# identidade enquanto o settle pagava um hash replicado; desde #95 o que se
	# afirma aqui é "o farmer tira itens do chão e eles chegam a ele", que é o
	# que importa e que pega se o elo quebrar.
	Check(picks >= 2, "loot: o farmer tirou item do chão (drops_picked=%d ≥ 2)" % picks)
	# `potions_used` da sessão NÃO é régua: medido no gate de 2026-09-28, o farmer
	# que chega com o nível/equipamento das suítes anteriores coleta 16 e bebe 0,
	# porque nunca afunda o limiar de 35%. Beber é consequência de apanhar, e
	# apanhar é função do vizinho — a régua do elo bebe abaixo, dirigida.

	var agent : PlayerAgent = await _SpawnSimAgent(charID, 971, 1)
	if not Check(agent != null, "loot: agente na zona 1"):
		return
	# Medido, não afirmado: quantos slots o load do MESMO char traz ocupados antes de
	# a precondição abrir espaço. É o número que a #95 moveu (o settle offline paga
	# agora uma identidade por rolagem, e `AddItemsBatchToCharacter` empilha uma
	# linha por identidade sem olhar o teto de `InventorySize`, enquanto `ImportInventory` chama
	# `PushItem` e descarta o que não cabe) — com a mochila no teto, `PushItem` recusa
	# e as réguas de chão→inventário caem juntas por estado de fixture.
	print("LOOTPIPE: mochila do char %d chegou com %d/%d slots" % [charID, agent.inventory.itemCount, ActorCommons.InventorySize])
	var inst : WorldInstance = IdlePolicyService.GetFarmInstance(1)
	if not Check(inst != null, "loot: instância da zona 1"):
		WorldAgent.RemoveAgent(agent)
		return
	# Mesma precondição do elo dirigido abaixo (1b) e das réguas de pilha (4)/(5):
	# sem slot livre, `PushItem` recusa tudo e as quatro réguas caem juntas por
	# motivo de fixture, não de produto.
	_FreeCarriedSlots(agent)
	# E a precondição do CHÃO: `PickupDrop`/`DropItem` resolvem a instância por
	# `WorldAgent.GetInstanceFromAgent`, que é `get_parent()`, enquanto
	# `WorldAgent.PushAgent` anexa com `call_deferred` — o farmer recém-spawnado está
	# LISTADO na zona com o pai ainda nulo. Julgar guarda de chão sem a anexação é
	# a cadeia devolvendo false antes de olhar a mochila: as asserções de recusa
	# passam VAZIAS. Espera-se a anexação e cobra-se a instância; sem ela a régua
	# acusa, em vez de degradar para um ramo mais fraco.
	var attachFrames : int = 0
	while attachFrames < 60 and WorldAgent.GetInstanceFromAgent(agent) == null:
		await Launcher.get_tree().physics_frame
		attachFrames += 1
	if not Check(WorldAgent.GetInstanceFromAgent(agent) as WorldInstance == inst,
			"loot: o farmer está anexado à instância que tem o chão (frames=%d)" % attachFrames):
		WorldAgent.RemoveAgent(agent)
		return
	# Vida cheia de volta antes de (1b): nos frames de espera o farmer fica parado
	# apanhando da zona, e um farmer morto não bebe — a régua da bebereira acusaria o
	# fixture. Quem afunda o HP de propósito é a própria (1b), duas linhas abaixo.
	agent.stat.health = agent.stat.current.maxHealth
	if not Check(ActorCommons.IsAlive(agent), "loot: farmer vivo depois de anexar à zona (frames=%d)" % attachFrames):
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
	# sumiria do dono sem nunca aparecer no chão. A anexação é precondição cobrada
	# antes de (1b), então aqui se julga sempre o ramo forte: sai da pilha E cai no
	# chão da mesma instância que (4b) vai varrer. O consumo completo do outro lado
	# é medido no mob, logo abaixo, que está num instance vivo por construção.
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
		var pBefore : int = inst.drops.size()
		agent.inventory.DropItem(apple, 1, idx)
		var leftIdx : int = agent.inventory.FindItemIndex(apple)
		var leftCount : int = int(agent.inventory.items[leftIdx].count) if leftIdx >= 0 else -1
		CheckEq(leftCount, seedCount + 1, "loot: DropItem do player tira da pilha exatamente o que pede (sobrou %d de %d)" % [leftCount, seedCount + 2])
		CheckEq(inst.drops.size() - pBefore, 1, "loot: o drop do player cai na instância")

	# (4b) Guarda do chão cheio — conservação, não tamanho. `WorldDrop.PickupDrop`
	# dava `PopDrop` ANTES de saber se o item cabia: com a mochila no teto o drop
	# saía do mundo sem nunca entrar em inventário nenhum, e o `drops_picked` do
	# farmer ficava em zero enquanto o chão esvaziava (é o P0 de loot que derrubou
	# esta esteira no gate de 2026-09-28). A régua abaixo é o lado que a grandeza
	# sozinha não julga: o que não coube CONTINUA no chão, ninguém é creditado por
	# ele, o MESMO item sai do chão quando há onde guardá-lo e as unidades dele
	# APARECEM na mochila. Inverter a ordem pega aqui de qualquer lado. A anexação
	# que faz este chão ser o do agente foi cobrada antes de (1b), junto com a
	# mochila despejada — sem elas a recusa seria atribuída a outra coisa.
	if not Check(WorldAgent.GetInstanceFromAgent(agent) as WorldInstance == inst, "loot: o farmer continua na instância que tem o chão"):
		WorldAgent.RemoveAgent(agent)
		return
	var guardID : int = -1
	var guardUnits : int = 0
	# O chão desta guarda é um drop que a SUÍTE plantou, não "o primeiro que o
	# dicionário entrega": desde #95 a mesa rola identidade por kill, e varrer
	# `inst.drops` podia devolver uma célula que `DB.GetItem` não resolve ou uma
	# não-empilhável com mais unidades que o teto da mochila — a coleta recusaria
	# por um motivo que não é nada do que esta guarda caça (e a recusa anterior
	# passava VAZIA, porque vazio e correto têm o mesmo veredito). Planta-se uma
	# maçã de uma unidade e o id dela é o delta do dicionário.
	var plantBefore : Dictionary = {}
	for pid in inst.drops:
		plantBefore[pid] = true
	var plantIdx : int = agent.inventory.FindItemIndex(apple)
	if Check(plantIdx >= 0, "loot: a guarda tem uma maçã na pilha para plantar"):
		agent.inventory.DropItem(apple, 1, plantIdx)
		for nid in inst.drops:
			if plantBefore.has(nid):
				continue
			var nd : Drop = inst.drops[nid]
			if nd != null and is_instance_valid(nd) and nd.item != null:
				guardID = int(nid)
				guardUnits = int(nd.item.count)
				agent.position = nd.position
				break
	# Os outros elos da cadeia não podem ser a causa da recusa, senão a régua julga
	# a árvore em vez da mochila: vida cheia — (1b) deixa o HP no chão e os mobs
	# apanham do farmer parado nos frames de espera — e mochila sem nenhuma célula
	# que mescle com a do drop: `CanHold` espelha `PushItem`, que aceita pilha
	# existente mesmo no teto, então só com a bolsa despejada a recusa é do teto.
	agent.stat.health = agent.stat.current.maxHealth
	if not Check(ActorCommons.IsAlive(agent) and agent.inventory != null, "loot: farmer vivo e com inventário para a guarda"):
		WorldAgent.RemoveAgent(agent)
		return
	if Check(guardID != -1 and guardUnits > 0, "loot: há um drop no chão para a guarda do chão cheio (unidades=%d)" % guardUnits):
		_FreeCarriedSlots(agent)
		var slotsBefore : int = agent.inventory.itemCount
		agent.inventory.itemCount = ActorCommons.InventorySize	# mochila no teto, só em memória
		var refused : bool = WorldDrop.PickupDrop(guardID, agent)
		var unitsMid : int = 0
		for it in agent.inventory.items:
			if it != null:
				unitsMid += it.count
		Check(not refused, "loot: com a mochila no teto a coleta recusa (coletou=%s)" % str(refused))
		Check(inst.drops.has(guardID), "loot: o item que não coube continua no chão (nada é apagado antes de caber)")
		CheckEq(unitsMid, 0, "loot: recusa não credita unidade em ninguém (%d no agente, 0 esperado)" % unitsMid)
		agent.inventory.itemCount = slotsBefore
		var took : bool = WorldDrop.PickupDrop(guardID, agent)
		Check(took and not inst.drops.has(guardID), "loot: o MESMO drop sai do chão para o inventário quando há slot (took=%s)" % str(took))
		# O outro lado da conservação: sair do chão e não entrar em ninguém é o
		# MESMO P0, visto de cima. Só a mudança de folga da mochila separa a recusa
		# do sucesso — controle negativo pelo mesmo predicado, sem mutar produto.
		var unitsAfter : int = 0
		for it in agent.inventory.items:
			if it != null:
				unitsAfter += it.count
		CheckEq(unitsAfter, guardUnits, "loot: o que saiu do chão chega ao inventário (%d vs %d)" % [unitsAfter, guardUnits])

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
