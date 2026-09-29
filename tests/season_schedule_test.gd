extends SceneTree

# OPS-2 (segunda metade): o relógio de temporada já era mecanismo — `SeasonConfig`
# valida, resolve por timestamp, preempta a rotação e congela `rules_frozen`. O
# que faltava era AGENDA: o arquivo tinha uma linha só, então "uma temporada nova
# é dado" nunca foi exercitado por dados e nenhum jogador via uma sucessora. Este
# harness é a régua que impede isso de apodrecer de novo: ele mede o arquivo real
# do repo pelo caminho real do produto (`CurrentRaw` → `ValidateSeasons` →
# `Entries`), e nada aqui reimplementa parsing nem reescreve a validação.
#
# O que ele amarra, e por quê:
#   1. duas temporadas declaradas, com `id` único e válido — "só existe a S1" é
#      a reclamação que fechou este buraco, e reclamação de agenda se resolve com
#      agenda no arquivo, não com prosa;
#   2. a sucessora tem JANELA FUTURA — o piso é 2026-12-01 UTC. É a condição que
#      deixa a S2 agendada sem reescrever a régua de `SuiteSeasonBootstrap`, que
#      mede 30 dias contados da abertura: se uma janela nominal cobrisse o instante
#      do run, `ResolveAt` devolveria a nominal e o beta passaria a medir outra
#      coisa. A checagem morde o valor de hoje, não a intenção de quem escreveu;
#   3. `duration_days` bate com a janela (a validação do produto exige igualdade
#      quando a janela é nominal — "a janela É a duração"), e `SeasonConfig.Errors()`
#      está vazio para o arquivo embarcado;
#   4. `premium_sku` da sucessora resolve no catálogo que a loja cobra, nos dois
#      sentidos: pelo predicado do produto (`_SkuAdvertised`, o mesmo que o boot
#      cruza) e pelo arquivo canônico, com preço igual ao anunciado — é a lição do
#      M3, um botão de passe apontando para SKU que ninguém cobra;
#   5. cada `race` é uma corrida que `EconomyCatalog.SEASON_KINDS` conhece;
#   6. o caminho da segunda temporada funciona COM OS DADOS embarcados: a rotação
#      continua no ar hoje, a sucessora assume no marco e a preempta, e as regras
#      congeladas da sucessora carregam a própria identidade (`config_id`);
#   7. controle NEGATIVO: cópias mutadas em memória do arquivo real — janela que
#      diverge de `duration_days`, SKU que não existe, `id` repetido, corrida e
#      cosmético fora do catálogo, chave com typo — são RECUSADAS, com o erro certo
#      e com `Entries()` vazio. Sem isto, "0 failures" podia significar apenas que
#      a régua relê um arquivo que não consegue falhar.
#
# Contrato dos scripts `-s` do repo: o script compila antes dos autoloads, então
# as classes entram por `load()`, nunca por `class_name` em tempo de parse. Não
# toca banco, rede, mundo nem disco além dos dois JSON que o servidor também lê.
# Saída = contagem de falhas; a régua do gate é a última linha.

const DaySeconds : int				= 86400
const SeasonsResPath : String		= "res://data/conf/seasons.json"
const PaidResPath : String			= "res://data/conf/paid_catalog.json"
const BaseResPath : String			= "res://data/conf/economy_base_catalog.json"
# 2026-12-01T00:00:00Z. Nenhuma janela embarcada pode começar antes disto: é o
# piso que garante que o dia em que o CI roda (hoje, ou qualquer hoje plausível do
# beta) está fora de toda janela nominal do arquivo.
const FutureFloorUnix : int			= 1796083200
const RollingSeasonID : String		= "s1"
const NextSeasonID : String			= "s2"

var checks : int = 0
var failures : int = 0

var _cfg : GDScript = null
var _catalog : GDScript = null
var _store : GDScript = null

func _initialize():
	_run()

# ------------------------------------------------------------------ contagem

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : int, expected : int, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %d vs %d" % [label, value, expected])
		return false
	return true

func _checkStr(value : String, expected : String, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: \"%s\" vs \"%s\"" % [label, value, expected])
		return false
	return true

func _checkHas(errors : PackedStringArray, needle : String, label : String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return _check(true, label)
	return _check(false, "%s (esperado achar \"%s\" em %s)" % [label, needle, str(errors)])

# ------------------------------------------------------------------ helpers

# A lista do arquivo, como o produto a devolve, sem o `_idx` que `ParseEntries`
# atribui por posição: serializar de volta com `_idx` dentro seria um erro de
# "chave desconhecida" inventado pelo harness, não pelo validador.
func _rawList(entries : Array) -> Array:
	var out : Array = []
	for item in entries:
		var entry : Dictionary = (item as Dictionary).duplicate(true)
		entry.erase("_idx")
		out.append(entry)
	return out

func _seasonsRaw(list : Array) -> String:
	return JSON.stringify({"seasons": list})

func _find(entries : Array, id : String) -> Dictionary:
	return _cfg.call("EntryByID", entries, id)

# A predicate deste harness (não do produto): janela nominal E inteira depois do
# instante do run E depois do piso de agenda. O produto aceita janela cobrindo
# "agora" — é assim que a S2 vai ao ar um dia; o que este harness recusa é que o
# arquivo EMBARCADO reescreva a régua do beta enquanto o beta mede.
func _isSafeFutureWindow(entry : Dictionary, now : int) -> bool:
	if not bool(_cfg.call("IsScheduled", entry)):
		return false
	var startsAt : int = int(entry["start_unix"])
	var endsAt : int = int(entry["end_unix"])
	return startsAt >= FutureFloorUnix and endsAt > startsAt and startsAt > now

# ------------------------------------------------------------------ run

func _run():
	print("[suite] agenda de temporadas embarcada em data/conf/seasons.json")
	_cfg = load("res://sources/season/SeasonConfig.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_store = load("res://sources/economy/Storefront.gd")
	if not _check(_cfg != null and _catalog != null and _store != null,
			"SeasonConfig/EconomyCatalog/Storefront carregam"):
		_finish()
		return
	# O caminho é o do produto (`SHAMBLETA_SEASONS_FILE`, senão `res://`): onde o
	# `.pck` é só leitura é por aí que o operator aponta o arquivo editado, e uma
	# régua que lesse o disco por conta própria mediria outro arquivo.
	var pointed : String = OS.get_environment(str(_cfg.get("SeasonsFileEnv")))
	_check(str(_cfg.call("FilePath")) == (pointed if pointed.strip_edges() != "" else SeasonsResPath),
		"SeasonConfig.FilePath() é o caminho que este harness lê (%s)" % str(_cfg.call("FilePath")))
	if not _check(_cfg.call("CurrentRaw").length() > 0, "o arquivo do produto é lido por CurrentRaw (sem ler o disco por fora)"):
		_finish()
		return
	var entries : Array = _cfg.call("Entries")
	if not _check(entries.size() >= 2, "há pelo menos duas temporadas declaradas (%d)" % entries.size()):
		_finish()
		return
	var s1 : Dictionary = _find(entries, RollingSeasonID)
	var s2 : Dictionary = _find(entries, NextSeasonID)
	if not _check(not s1.is_empty() and not s2.is_empty(), "as duas resolvem por id (EntryByID, o caminho do passe)"):
		_finish()
		return
	_suiteIdsAndClock(entries, s1, s2)
	_suiteSkuChain(s2)
	_suiteRaces(entries)
	_suiteSecondSeasonPath(entries, s1, s2)
	_suiteNegativeControls(entries, s2)
	_cfg.call("ClearRawForTests")
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ 1 e 2: ids, janela, duração

func _suiteIdsAndClock(entries : Array, s1 : Dictionary, s2 : Dictionary):
	print("[suite] 1-3: ids, janela futura e duração batendo com o arquivo embarcado")
	# O controle positivo do boot: `Errors()` é o que `EnsureSeason()` lê para
	# recusar abrir temporada — vazio aqui é a agenda embarcada sendo válida.
	var shipped : PackedStringArray = _cfg.call("Errors")
	_checkEq(shipped.size(), 0, "SeasonConfig.Errors() vazio para o arquivo do repo: %s" % [str(shipped)])
	_check(bool(_cfg.call("IsValid")), "IsValid() com o arquivo do repo")
	_checkEq(_cfg.call("ValidateSeasonsFile").size(), 0, "ValidateSeasonsFile (a mesma régua, lida do disco) também devolve zero")
	# ids únicos e no padrão, contados sobre as entradas que o produto devolve.
	var seen : Dictionary = {}
	var badID : int = 0
	for item in entries:
		var id : String = str(_cfg.call("ConfigID", item))
		if not bool(_cfg.call("IsConfigID", id)) or seen.has(id):
			badID += 1
		seen[id] = true
	_check(not seen.has(""), "nenhum id vazio entre as %d entradas" % entries.size())
	_checkEq(badID, 0, "todo id é do padrão [a-z][a-z0-9_]* e único (a resolução por timestamp depende disso)")
	_checkEq(seen.size(), entries.size(), "%d ids para %d entradas (nada colapsou)" % [seen.size(), entries.size()])
	# A rotação do beta continua intacta — é ela que responde pelo instante do run.
	_check(not bool(_cfg.call("IsScheduled", s1)), "a temporada de rotação segue sem janela nominal (0/0)")
	_checkEq(int(_cfg.call("DurationDays", s1)), 30, "rotação continua durando 30 dias contados da abertura")
	_checkStr(str(_cfg.call("Label", s1)), "S1", "label da rotação é S1 (a GUI e as linhas antigas leem isto)")
	# A sucessora.
	_check(bool(_cfg.call("IsScheduled", s2)), "a sucessora tem janela nominal (não é mais rotação anônima)")
	var now : int = int(Time.get_unix_time_from_system())
	var startsAt : int = int(s2["start_unix"])
	var endsAt : int = int(s2["end_unix"])
	_check(_isSafeFutureWindow(s2, now), "janela da sucessora é futura e começa depois do piso de agenda (%d > %d, agora %d)" % [startsAt, FutureFloorUnix, now])
	_check(startsAt > now, "a janela abre depois do instante deste run: começar dentro do run mudaria a régua de SuiteSeasonBootstrap")
	_check(endsAt > startsAt, "fim depois do início (janela não vazia)")
	var days : int = int(_cfg.call("DurationDays", s2))
	_checkEq(days, int(s2["duration_days"]), "duration_days do arquivo == DurationDays() do produto")
	_checkEq(endsAt - startsAt, days * DaySeconds, "a janela É a duração: %d s != %d dias" % [endsAt - startsAt, days])
	_checkEq(days, 30, "a sucessora promete 30 dias")
	_check(s2.has("premium_sku"), "a sucessora declara o próprio SKU de passe")
	_check(str(s2.get("theme", "")).length() > 0, "a sucessora tem tema para a UI")
	_check(str(s2.get("rewards_ref", "")).length() > 0, "a sucessora declara rewards_ref (a prova congelada na linha)")
	_check(s2.has("pass_tiers"), "a sucessora declara a própria trilha do passe (o campo existia sem nenhum dado usando ele)")

# ------------------------------------------------------------------ 4: o SKU que a loja cobra

func _suiteSkuChain(s2 : Dictionary):
	print("[suite] 4: premium_sku resolve no catálogo cobrável, nos dois sentidos")
	var sku : String = str(s2.get("premium_sku", ""))
	_checkStr(sku, "pass.s2", "o SKU declarado pela sucessora é o SKU criado nos catálogos")
	# O predicado do produto, chamado pelo nome que o validador de boot chama.
	_check(bool(_cfg.call("_SkuAdvertised", sku)), "SeasonConfig._SkuAdvertised conhece o SKU (é isto que o M3 não conhecia)")
	_check(not bool(_cfg.call("_SkuAdvertised", sku + ".fantasma")), "controle: o predicado devolve false para SKU inexistente (não é always-true)")
	var advertised : Variant = _catalog.get("SHOP_CATALOG")
	if not _check(advertised is Array and (advertised as Array).size() > 0, "SHOP_CATALOG é legível no harness (o catálogo que a loja anuncia)"):
		return
	var advertisedPrice : float = -1.0
	for line in (advertised as Array):
		if str((line as Dictionary).get("sku", "")) == sku:
			advertisedPrice = float((line as Dictionary).get("price", -1.0))
	_check(advertisedPrice > 0.0, "%s tem preço anunciado (%.2f)" % [sku, advertisedPrice])
	# O arquivo canônico é o que o gateway cobra.
	var paidRaw : String = FileAccess.get_file_as_string(PaidResPath)
	_check(not paidRaw.is_empty(), "data/conf/paid_catalog.json foi lido")
	var paidErrors : PackedStringArray = _catalog.call("ValidatePaidCatalog", paidRaw)
	_checkEq(paidErrors.size(), 0, "catálogo pago canônico valida limpo contra o anúncio (%s)" % [str(paidErrors)])
	var paid : Variant = JSON.parse_string(paidRaw)
	if not _check(typeof(paid) == TYPE_DICTIONARY, "paid_catalog.json é um objeto"):
		return
	var paidLine : Variant = (paid as Dictionary).get(sku)
	if not _check(typeof(paidLine) == TYPE_DICTIONARY, "%s existe no catálogo que o companion cobra" % sku):
		return
	_checkStr(str((paidLine as Dictionary).get("kind", "")), "pass_premium", "%s é kind pass_premium (o grant que o passe aplica)" % sku)
	_checkEq(int((paidLine as Dictionary).get("amount", 0)), 1, "%s concede um passe" % sku)
	var charged : float = float((paidLine as Dictionary).get("price", -1.0))
	_checkEq(int(round(charged * 100.0)), int(round(advertisedPrice * 100.0)), "preço cobrado == preço anunciado (CDC), em centavos")
	# Paridade com o passe da temporada em vigor: a tarifa não muda de uma
	# temporada para outra sem decisão registrada, e o validador de boot amarra os
	# dois lados de cada SKU, não a relação entre eles.
	var s1Sku : String = "pass.s1"
	if (paid as Dictionary).has(s1Sku):
		var s1Charged : float = float(((paid as Dictionary)[s1Sku] as Dictionary).get("price", -1.0))
		_checkEq(int(round(charged * 100.0)), int(round(s1Charged * 100.0)), "%s é precificado como %s (centavos)" % [sku, s1Sku])
	# Os outros dois espelhos que o boot cruza, para a agenda não nascer válida e
	# a loja quebrar no commit seguinte.
	var baseRaw : String = FileAccess.get_file_as_string(BaseResPath)
	_check(not baseRaw.is_empty(), "data/conf/economy_base_catalog.json foi lido")
	_checkEq(_catalog.call("ValidateBaseCatalog", baseRaw).size(), 0, "catálogo base (a vitrine espelhada) valida limpo com a sucessora no ar")
	_check(str(baseRaw).contains(sku), "o SKU da sucessora está no catálogo base (igualdade de contagem e preço com o anúncio)")
	_check(paidRaw.count("\"price\"") >= 10, "o catálogo canônico continua com a tabela inteira (%d linhas de preço)" % paidRaw.count("\"price\""))
	# Vitrine: um SKU de passe que a loja anuncia e `PassSkus` não conhece é
	# merchandising fora do gate de temporada ativa.
	var passSkus : Variant = _store.get("PassSkus")
	_check(passSkus is Array and (passSkus as Array).has(sku), "Storefront.PassSkus lista %s (a amarra com kind pass_premium do catálogo canônico)" % sku)

# ------------------------------------------------------------------ 5: corridas

func _suiteRaces(entries : Array):
	print("[suite] 5: cada corrida declarada existe em EconomyCatalog.SEASON_KINDS")
	var kinds : Variant = _catalog.get("SEASON_KINDS")
	if not _check(kinds is Array and (kinds as Array).size() > 0, "SEASON_KINDS é legível (o enum que o placar sabe apurar)"):
		return
	var declaredTotal : int = 0
	var unknown : String = ""
	for item in entries:
		var races : Array = _cfg.call("Races", item)
		_check(races.size() > 0, "%s declara ao menos uma corrida" % str(_cfg.call("ConfigID", item)))
		for race in races:
			declaredTotal += 1
			if not (kinds as Array).has(str(race)):
				unknown += str(race) + " "
	_checkEq(unknown.length(), 0, "nenhuma corrida fora de SEASON_KINDS (%s)" % unknown)
	_check(declaredTotal >= (kinds as Array).size(), "%d corridas declaradas entre as temporadas embarcadas" % declaredTotal)
	# `Races()` tem fallback para o catálogo quando o arquivo não declara — se a
	# checagem acima só visse o fallback, "subset" seria sempre verdade por construção.
	var bare : Dictionary = {"id": "probe", "start_unix": 0, "end_unix": 0, "duration_days": 30}
	_checkEq((_cfg.call("Races", bare) as Array).size(), (kinds as Array).size(), "fallback de Races() é o catálogo inteiro (por isso a checagem acima olha o arquivo, não o fallback)")

# ------------------------------------------------------------------ 6: o caminho da segunda temporada

func _suiteSecondSeasonPath(entries : Array, s1 : Dictionary, s2 : Dictionary):
	print("[suite] 6: com os dados embarcados, a sucessora assume no marco (o caminho nunca exercitado por dados)")
	var now : int = int(Time.get_unix_time_from_system())
	var startsAt : int = int(s2["start_unix"])
	# Hoje: a rotação responde. É exatamente o que `SuiteSeasonBootstrap` mede —
	# 30 dias contados da abertura, `rules_frozen` dizendo S1.
	var openNow : Dictionary = _cfg.call("EntryToOpen", entries, now)
	_checkStr(str(_cfg.call("ConfigID", openNow)), RollingSeasonID, "o relógio abre a rotação hoje (a janela futura não rouba a régua do beta)")
	var window : Dictionary = _cfg.call("WindowForEntry", openNow, now)
	_checkEq(int(window.get("ends_at", 0)) - int(window.get("starts_at", 0)), 30 * DaySeconds, "a janela materializada é 30*86400 desde agora (o número que a suíte idle congela)")
	_contains(str(_cfg.call("RulesJSONForEntry", openNow)), "\"S1\"", "rules_frozen da rotação continua dizendo \"S1\"")
	# O operador vê a sucessora: é isto que faltava para "relógio de temporada" não
	# ser mecanismo sem agenda.
	_checkEq(int(_cfg.call("NextScheduledStart", entries, now)), startsAt, "NextScheduledStart devolve a estreia da sucessora (o jogador/operador vê a próxima temporada)")
	_check(bool(_cfg.call("IsScheduled", _cfg.call("ResolveAt", entries, startsAt))), "no marco, a nominal assume")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, startsAt))), NextSeasonID, "quem assume no marco é a sucessora embarcada")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, startsAt - 1))), RollingSeasonID, "um segundo antes do marco é a rotação (fim inclusivo no início, exclusivo no fim)")
	var nextWindow : Dictionary = _cfg.call("WindowForEntry", s2, startsAt + 60)
	_checkEq(int(nextWindow.get("ends_at", 0)), int(s2["end_unix"]), "a sucessora fecha no horário marcado, mesmo se o servidor acordou tarde")
	# Preempção com os dados reais: a rotação em andamento congela no marco.
	var rollingRow : Dictionary = {"season_id": 9, "starts_at": now - 10 * DaySeconds,
		"ends_at": now + 20 * DaySeconds,
		"rules_frozen": str(_cfg.call("RulesJSONForEntry", s1))}
	_check(bool(_cfg.call("ShouldPreempt", entries, rollingRow, startsAt)), "ShouldPreempt com o arquivo do repo: a sucessora encerra a rotação antecipada")
	_check(not bool(_cfg.call("ShouldPreempt", entries, rollingRow, now)), "e não encerra antes do marco")
	# Identidade congelada na linha, sem migration.
	var rules : String = str(_cfg.call("RulesJSONForEntry", s2))
	_contains(rules, NextSeasonID, "rules_frozen da sucessora carrega o próprio config_id")
	_contains(rules, "Marés", "rules_frozen carrega o tema da sucessora (a UI lê daqui)")
	_checkStr(str(_cfg.call("ConfigIDOfRow", {"rules_frozen": rules})), NextSeasonID, "config_id volta da linha do banco")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("EntryForSeasonRow", entries, {"rules_frozen": rules}))), NextSeasonID, "linha da sucessora resolve a entrada da sucessora (é isto que liquida o passe dela)")
	# A trilha embarcada é a que o passe vai usar quando ela abrir.
	_checkEq(int(_cfg.call("PassMaxLevel", s2)), int(s2["pass_tiers"]["max_level"]), "teto de nível da sucessora vem da trilha embarcada")
	_check(int(_cfg.call("PassBonusStart", s2)) > 1 and int(_cfg.call("PassBonusStart", s2)) <= int(_cfg.call("PassMaxLevel", s2)) + 1, "bônus da sucessora começa dentro do próprio teto")
	_checkEq((_cfg.call("PassTiers", s2, "premium") as Dictionary).size(), 4, "a trilha premium embarcada chega inteira ao PassService")
	_checkEq(int(_cfg.call("PassMaxLevel", s1)), int(_catalog.get("PASS_MAX_LEVEL")), "a rotação sem trilha declarada continua nos defaults do catálogo")

func _contains(hay : String, needle : String, label : String) -> bool:
	return _check(hay.contains(needle), "%s (faltou \"%s\")" % [label, needle])

# ------------------------------------------------------------------ 7: controles negativos

# Cópias mutadas DO ARQUIVO REAL, em memória. Não é fixture inventado: se a régua
# do produto não recusar estas cinco mutações, ela também não recusa o typo que
# alguém vai cometer na S3.
func _suiteNegativeControls(entries : Array, s2 : Dictionary):
	print("[suite] 7: mutações do arquivo embarcado são recusadas (a régua morde)")
	var base : Array = _rawList(entries)
	# (0) ida e volta: o harness serializa as entradas que o produto devolve, e o
	# validador aceita — prova de que as mutações abaixo falham pelo que mudou.
	var roundTrip : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(base))
	if not _checkEq(roundTrip.size(), 0, "o arquivo real ida e volta pelo parser continua válido (%s)" % [str(roundTrip)]):
		return
	var mutated : Array = _rawList(entries)
	var idx : int = mutated.size() - 1
	# (1) janela que diverge de duration_days.
	(mutated[idx] as Dictionary)["duration_days"] = int(s2["duration_days"]) - 1
	var badDur : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkEq(badDur.size(), 1, "janela != duration_days na sucessora embarcada é 1 erro")
	_checkHas(badDur, "duration_days", "o erro nomeia o campo (a janela É a duração quando é nominal)")
	# (2) SKU que o catálogo cobrável não cobra.
	mutated = _rawList(entries)
	(mutated[idx] as Dictionary)["premium_sku"] = "pass.s2.ninguem.cobra"
	var badSku : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkEq(badSku.size(), 1, "premium_sku inexistente é recusa, não aviso")
	_checkHas(badSku, "SHOP_CATALOG", "e o erro diz onde falta o SKU (o caminho do M3)")
	# (3) id duplicado.
	mutated = _rawList(entries)
	mutated.append((mutated[idx] as Dictionary).duplicate(true))
	var badID : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkEq(badID.size(), 1, "repetir a linha da sucessora é erro")
	_checkHas(badID, "duplicado", "a resolução por timestamp ficaria ambígua")
	# (4) corrida que nenhum placar apura.
	mutated = _rawList(entries)
	(mutated[idx] as Dictionary)["races"] = ["power", "durabilidade"]
	var badRace : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkHas(badRace, "SEASON_KINDS", "corrida fora do enum é erro")
	# (5) cosmético de trilha fora do catálogo = prêmio que ninguém concede.
	mutated = _rawList(entries)
	((mutated[idx] as Dictionary)["pass_tiers"] as Dictionary)["premium"] = {"10": {"cosmetics": ["skin_inventada"]}}
	var badCos : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkHas(badCos, "COSMETIC_CATALOG", "cosmético fora do catálogo é erro, não item perdido")
	# (6) chave com typo: `start_unx` não é "sem janela", é temporada de rotação
	# nascendo em silêncio — a mutação exata que a fail-closed do arquivo proíbe.
	mutated = _rawList(entries)
	(mutated[idx] as Dictionary)["start_unx"] = int(s2["start_unix"])
	var badKey : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(mutated))
	_checkHas(badKey, "chave desconhecida", "typo de chave é erro")
	# (7) janela que cobre o instante do run: este harness recusa (a régua do beta
	# mudaria), o validador do produto aceita (é assim que a S2 vai ao ar um dia).
	var covering : Array = _rawList(entries)
	var now : int = int(Time.get_unix_time_from_system())
	(covering[idx] as Dictionary)["start_unix"] = now - DaySeconds
	(covering[idx] as Dictionary)["end_unix"] = now + DaySeconds
	(covering[idx] as Dictionary)["duration_days"] = 2
	_checkEq(_cfg.call("ValidateSeasons", _seasonsRaw(covering)).size(), 0, "o produto aceita janela cobrindo agora (é assim que a sucessora vai ao ar um dia)")
	_check(not _isSafeFutureWindow(_find(covering, NextSeasonID), now), "mas esta régua recusa a janela cobrindo o run (o controle negativo do item 2)")
	_check(not _isSafeFutureWindow(_rawRolling(), now), "e uma sucessora sem janela nominal também (IsScheduled é a porta de entrada)")
	# Fail-closed de comportamento: com a agenda inválida no ar, nada abre.
	_cfg.call("SetRawForTests", _seasonsRaw(mutated))
	_check(_cfg.call("Errors").size() > 0, "Errors() reporta a mutação (é isto que EnsureSeason lê)")
	_check(not bool(_cfg.call("IsValid")), "IsValid() false com a mutação")
	_checkEq(_cfg.call("Entries").size(), 0, "Entries() fica vazio: nenhuma temporada nova abre com a agenda quebrada")
	_check(_cfg.call("EntryToOpen", _cfg.call("Entries"), now).is_empty(), "EntryToOpen não inventa sucessora")
	_cfg.call("ClearRawForTests")
	_checkEq(_cfg.call("Errors").size(), 0, "o arquivo embarcado volta a validar (nenhum estado travado)")
	_check(_find(_cfg.call("Entries"), NextSeasonID).size() > 0, "e a sucessora continua lá depois do fail-closed")

# Sucessora de rotação para o controle negativo de `IsScheduled` — só um `id`, o
# resto é o que o produto preenche.
func _rawRolling() -> Dictionary:
	return {"id": NextSeasonID, "start_unix": 0, "end_unix": 0, "duration_days": 30}
