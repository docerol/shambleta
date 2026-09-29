extends SceneTree

# OPS-2/OPS-3 (AUDITORIA_2026-09-27 §15): harness autocontido do calendário de
# temporadas (`data/conf/seasons.json` + `sources/season/SeasonConfig.gd`) e da
# agenda de live ops (`data/conf/liveops_calendar.json` + `sources/ops/LiveOpsCalendar.gd`).
#
# O que ele prova, nas FUNÇÕES REAIS (sem reimplementar nada):
#   A  a temporada VIGENTE resolve por timestamp, e uma sucessora anexada ao
#      arquivo assume o ar editando SÓ o JSON (inclusive anexando a entrada no
#      arquivo real do repo); janela materializa em `starts_at`/`ends_at`,
#      `config_id` viaja no `rules_frozen` que já existe (linhas antigas continuam
#      resolvendo); preempção da temporada de rotação quando a sucessora agendada
#      entra. A agenda embarcada no arquivo (`s1` rotação + `s2` com janela futura)
#      é medida por `tests/season_schedule_test.gd`, não aqui.
#   B  arquivo ausente/quebrado/typo = fail-closed com erro claro e nenhuma
#      temporada abre (a mesma régua de `EconomyCatalog.ValidatePaidCatalog`), e o
#      positivo: os dois arquivos do repo validam limpos.
#   C  `LiveOpsCalendar` respeita antes/dentro/depois da janela (fim exclusivo),
#      kinds independentes e sobreposição DETERMINÍSTICA que não compõe.
#   D  o multiplicador que o caminho real de gameplay aplica bate número a número
#      com o valor do arquivo (`OfflineSettle.LiveOpsXpMods`, consumido por
#      `GetModsForAccount`), inclusive o neutro 1.0 fora de janela e o fail-closed.
#
# Contrato dos scripts `-s` do repo (ver `run_idle_tests.gd` / `economy_design_fix_test.gd`):
# o script compila antes dos autoloads, então nada de `class_name` nem de
# Launcher/SeasonConfig/OfflineSettle em tempo de parse — as classes entram por
# `load()`. Diferente daqueles: este não toca o banco. As metades novas do live ops
# são puras por construção (timestamp entra, estado sai) e é exatamente isso que
# está sendo provado aqui; por isso ele roda mesmo com o resto do tree quebrado.
# Saída = contagem de falhas; a régua do gate é a última linha.

const DaySeconds : int = 86400
const SeasonsResPath : String = "res://data/conf/seasons.json"
const CalendarResPath : String = "res://data/conf/liveops_calendar.json"

var checks : int = 0
var failures : int = 0

var _cfg : GDScript = null
var _cal : GDScript = null
var _offline : GDScript = null
var _catalog : GDScript = null
var _pass : GDScript = null

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

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (+/-%f)" % [label, value, expected, tolerance])
		return false
	return true

func _checkHas(errors : PackedStringArray, needle : String, label : String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return _check(true, label)
	return _check(false, "%s (esperado achar \"%s\" em %s)" % [label, needle, str(errors)])

func _contains(hay : String, needle : String, label : String) -> bool:
	return _check(hay.contains(needle), "%s (faltou \"%s\")" % [label, needle])

# ------------------------------------------------------------------ fixtures de agenda

func _rolling(id : String, label : String, days : int) -> Dictionary:
	return {"id": id, "label": label, "start_unix": 0, "end_unix": 0, "duration_days": days,
		"theme": "tema " + label, "rewards_ref": "gems+cosmetics, non-cashable",
		"races": ["power", "spend", "boss_kills", "guild_points"]}

func _scheduled(id : String, label : String, starts : int, days : int) -> Dictionary:
	var entry : Dictionary = _rolling(id, label, days)
	entry["start_unix"] = starts
	entry["end_unix"] = starts + days * DaySeconds
	return entry

func _seasonsRaw(list : Array) -> String:
	return JSON.stringify({"seasons": list})

func _eventsRaw(list : Array) -> String:
	return JSON.stringify({"events": list})

func _event(kind : String, key : String, starts : int, ends : int, value : float) -> Dictionary:
	return {"kind": kind, "key": key, "start_unix": starts, "end_unix": ends, "value": value}

func _row(configID : String, startsAt : int, endsAt : int) -> Dictionary:
	# A forma como a identidade chega no banco é o `rules_frozen` que a própria
	# entrada gera — sem coluna nova, sem migration.
	return {"season_id": 1, "starts_at": startsAt, "ends_at": endsAt, "status": "active",
		"rules_frozen": _cfg.call("RulesJSONForEntry", _cfg.call("EntryByID", _cfg.call("ParseEntries", _seasonsRaw([_rolling("s1", "S1", 30), _scheduled("s2", "S2", startsAt, 30)])), configID) if not configID.is_empty() else "")}

# ------------------------------------------------------------------ run

func _run():
	print("== OPS-2/OPS-3 harness: seasons.json + liveops_calendar.json ==")
	_cfg = load("res://sources/season/SeasonConfig.gd")
	_cal = load("res://sources/ops/LiveOpsCalendar.gd")
	_offline = load("res://sources/idle/OfflineSettle.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_pass = load("res://sources/economy/PassService.gd")
	var loaded : bool = _cfg != null and _cal != null and _offline != null and _catalog != null and _pass != null
	if not _check(loaded, "SeasonConfig/LiveOpsCalendar/OfflineSettle/EconomyCatalog/PassService carregam"):
		_finish()
		return
	_suiteConfigFiles()
	_suiteSeasonResolution()
	_suiteSeasonS2ByJSON()
	_suiteSeasonFailClosed()
	_suitePassByConfig()
	_suiteCalendarWindows()
	_suiteCalendarFailClosed()
	_suiteLiveOpsMultiplierPath()
	_cfg.call("ClearRawForTests")
	_cal.call("ClearRawForTests")
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ suite: os arquivos do repo

func _suiteConfigFiles():
	print("[suite] os dois arquivos do repo validam limpo (controle positivo do boot)")
	var seasonErrors : PackedStringArray = _cfg.call("ValidateSeasonsFile")
	_checkEq(seasonErrors.size(), 0, "data/conf/seasons.json valida limpo: %s" % [str(seasonErrors)])
	var calErrors : PackedStringArray = _cal.call("ValidateCalendarFile")
	_checkEq(calErrors.size(), 0, "data/conf/liveops_calendar.json valida limpo: %s" % [str(calErrors)])
	_check(FileAccess.file_exists(SeasonsResPath), "seasons.json existe (fail-closed só é bom se o caminho é único)")
	_check(FileAccess.file_exists(CalendarResPath), "liveops_calendar.json existe")
	# A S1 do beta continua descrita como era: rolling de 30 dias, etiqueta "S1".
	# `SuiteSeasonBootstrap` (IdleTests) congela exatamente essa régua.
	var repo : Array = _cfg.call("Entries")
	_check(repo.size() >= 2, "o arquivo traz a rotação e ao menos uma sucessora agendada (%d entradas)" % repo.size())
	var s1 : Dictionary = repo[0] if not repo.is_empty() else {}
	_checkStr(str(_cfg.call("ConfigID", s1)), "s1", "a entrada vigente é a s1")
	_checkStr(str(_cfg.call("Label", s1)), "S1", "label S1 preservado (é o que a GUI e as linhas antigas mostram)")
	_checkEq(int(_cfg.call("DurationDays", s1)), 30, "duração de 30 dias mantida")
	_check(not bool(_cfg.call("IsScheduled", s1)), "S1 é de rotação (0/0), senão o beta abriria temporada vencida")
	_contains(str(_cfg.call("RulesJSONForEntry", s1)), "\"S1\"", "rules_frozen ainda diz \"S1\" para quem lê o congelado")
	# Perigo de agenda conhecido: nenhuma janela double_xp pode cobrir o instante
	# em que `SuiteSettleGolden` roda (a expectativa dela é mods = 1.0).
	var now : int = int(Time.get_unix_time_from_system())
	_checkNear(float(_cal.call("ValueAtKind", _cal.get("KindDoubleXP"), now, 1.0)), 1.0, 0.000001, "nenhum double_xp no ar neste instante (SuiteSettleGolden continua em mods 1.0)")
	_checkEq(int(_cfg.call("PassMaxLevel", s1)), int(_catalog.get("PASS_MAX_LEVEL")), "passe da S1 sem trilha declarada = teto do catálogo")

# ------------------------------------------------------------------ suite A: resolução por timestamp

func _suiteSeasonResolution():
	print("[suite] A: temporada vigente resolve por timestamp (janela, duração, sucessão)")
	var t0 : int = 1800000000
	var s1 : Dictionary = _rolling("s1", "S1", 30)
	var s2 : Dictionary = _scheduled("s2", "S2", t0, 21)
	var raw : String = _seasonsRaw([s1, s2])
	_checkEq(_cfg.call("ValidateSeasons", raw).size(), 0, "calendário S1(rolling)+S2(agendada) valida limpo")
	var entries : Array = _cfg.call("ParseEntries", raw)
	_checkEq(entries.size(), 2, "duas entradas parseadas")
	# antes / dentro / depois da janela nominal
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, t0 - 1))), "s1", "antes do start_unix: a rolling continua no ar")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, t0))), "s2", "no start_unix (inclusive): S2 assume")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, t0 + 10 * DaySeconds))), "s2", "dentro da janela: S2")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, t0 + 21 * DaySeconds))), "s1", "no end_unix (exclusivo): volta para a rolling")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("EntryToOpen", entries, t0 + DaySeconds))), "s2", "EntryToOpen é o que o relógio abre")
	# a janela materializada na linha `season`
	var window : Dictionary = _cfg.call("WindowForEntry", s2, t0 + 3 * DaySeconds)
	_checkEq(int(window.get("starts_at", -1)), t0 + 3 * DaySeconds, "starts_at é o instante do relógio, nunca o start_unix do passado")
	_checkEq(int(window.get("ends_at", -1)), t0 + 21 * DaySeconds, "ends_at é o end_unix: a agendada fecha na hora marcada")
	var rollingWindow : Dictionary = _cfg.call("WindowForEntry", s1, t0)
	_checkEq(int(rollingWindow.get("ends_at", -1)) - int(rollingWindow.get("starts_at", 0)), 30 * DaySeconds, "rolling dura duration_days a partir da abertura")
	_checkEq(int(((_cfg.call("WindowForEntry", _scheduled("s9", "S9", t0 - 5 * DaySeconds, 3), t0)) as Dictionary).get("ends_at", 0)), 0, "janela nominal vencida não abre (window vazio)")
	# sobreposição de nominais: nunca duas no ar
	var later : Dictionary = _scheduled("s2b", "S2b", t0 + 5 * DaySeconds, 30)
	var overlapped : Array = _cfg.call("ParseEntries", _seasonsRaw([s1, s2, later]))
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", overlapped, t0 + 6 * DaySeconds))), "s2b", "sobreposição: a que começa depois vence")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", overlapped, t0 + DaySeconds))), "s2", "fora da segunda janela, a primeira segue")
	var tiedA : Dictionary = _scheduled("t_a", "TA", t0, 10)
	var tiedB : Dictionary = _scheduled("t_b", "TB", t0, 20)
	var tiedEntries : Array = _cfg.call("ParseEntries", _seasonsRaw([s1, tiedA, tiedB]))
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", tiedEntries, t0 + DaySeconds))), "t_b", "empate de início: a que termina depois vence (determinístico)")
	var tieAgain : Array = _cfg.call("ParseEntries", _seasonsRaw([s1, tiedB, tiedA]))
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", tieAgain, t0 + DaySeconds))), "t_b", "a ordem no arquivo não muda o resultado (empate resolvido por janela, não por autor)")
	# agenda legível (o que um `/season agenda` responde)
	var agendaNow : int = t0 + 6 * DaySeconds
	_checkEq(int(_cfg.call("NextScheduledStart", entries, t0 - DaySeconds)), t0, "next_start diz quando a sucessora assume")
	_checkEq(int(_cfg.call("NextScheduledStart", entries, t0 + DaySeconds)), 0, "sem nada no futuro, next_start = 0 (não é zero desconhecido)")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, agendaNow))), "s2", "resolução estável para um mesmo timestamp")

# ------------------------------------------------------------------ suite A2: linhas do banco + preempção

func _suiteSeasonS2ByJSON():
	print("[suite] A2: uma sucessora existe editando só o JSON (anexo no arquivo real do repo)")
	var text : String = FileAccess.get_file_as_string(SeasonsResPath)
	_check(not text.is_empty(), "o arquivo real do repo foi lido")
	var parsed : Variant = JSON.parse_string(text)
	if not _check(typeof(parsed) == TYPE_DICTIONARY, "seasons.json é um objeto"):
		return
	var list : Array = (parsed as Dictionary).get("seasons", [])
	var now : int = int(Time.get_unix_time_from_system())
	var start : int = now + DaySeconds
	var s2 : Dictionary = _scheduled("s2", "S2", start, 30)
	s2["theme"] = "Marés de Tulimshar"
	s2["premium_sku"] = "pass.s2"
	s2["pass_tiers"] = {"max_level": 25, "bonus_start": 21, "bonus_gems": 30,
		"free": {"2": {"gems": 7}}, "premium": {"4": {"cosmetics": ["skin_manto"]}}}
	# A s2 que o arquivo já traz (janela futura, agendada de verdade desde OPS-2)
	# sai do Anexo: anexar a mesma id duas vezes seria um erro de agenda, não a
	# demonstração de que anexo é o único passo. `tests/season_schedule_test.gd` é
	# quem mede a linha agendada do arquivo.
	var base : Array = []
	for item in list:
		if str((item as Dictionary).get("id", "")) != "s2":
			base.append(item)
	# O passo que ainda é código está amarrado aqui: sem o SKU no catálogo cobrável
	# o lançamento NÃO passa — é o oposto de estrear uma temporada que o servidor
	# não sabe cobrar.
	var ghost : Dictionary = (s2 as Dictionary).duplicate(true)
	ghost["premium_sku"] = "pass.s2.ninguem.cobra"
	var errorsS2 : PackedStringArray = _cfg.call("ValidateSeasons", _seasonsRaw(base + [ghost]))
	_checkEq(errorsS2.size(), 1, "S2 com premium_sku que ninguém cobra é recusada (1 erro, não um aviso)")
	_checkHas(errorsS2, "SHOP_CATALOG", "o erro diz onde falta o SKU")
	_checkEq(_cfg.call("ValidateSeasons", _seasonsRaw(base + [s2])).size(), 0, "o mesmo anexo com o SKU cobrável do catálogo passa (é o que a S2 agendada usa)")
	s2.erase("premium_sku")
	var withoutSKU : String = _seasonsRaw(base + [s2])
	var errors : PackedStringArray = _cfg.call("ValidateSeasons", withoutSKU)
	if not _checkEq(errors.size(), 0, "S2 anexada ao arquivo real valida limpa sem tocar em GDScript: %s" % [str(errors)]):
		return
	_cfg.call("SetRawForTests", withoutSKU)
	var entries : Array = _cfg.call("Entries")
	_checkEq(entries.size(), 2, "Entries() enxerga as duas")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("ResolveAt", entries, now))), "s1", "hoje: ainda é a S1 de rotação que está no ar")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("EntryToOpen", entries, start + 60))), "s2", "na hora marcada, o relógio abre a S2")
	var rules : String = str(_cfg.call("RulesJSONForEntry", _cfg.call("EntryByID", entries, "s2")))
	_contains(rules, "\"s2\"", "o rules_frozen carrega config_id/label da S2")
	_checkStr(str(_cfg.call("ConfigIDOfRow", {"rules_frozen": rules})), "s2", "config_id volta da linha do banco (compat com o schema atual, sem migration)")
	# Linha criada pelo OPS-2 resolve a própria entrada; linha legada (sem
	# config_id, ou criada por `/season create <dias>`) continua resolvendo.
	var rowS2 : Dictionary = _row("s2", start, start + 30 * DaySeconds)
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("EntryForSeasonRow", entries, rowS2))), "s2", "linha da S2 resolve a entrada da S2")
	var legacy : Dictionary = {"season_id": 7, "starts_at": now - 5 * DaySeconds, "ends_at": now + 25 * DaySeconds, "rules_frozen": "{\"season\":\"S1\",\"days\":30,\"frozen\":true}"}
	_checkStr(str(_cfg.call("ConfigIDOfRow", legacy)), "", "linha legada não tem config_id (e não é erro por isso)")
	_checkStr(str(_cfg.call("ConfigID", _cfg.call("EntryForSeasonRow", entries, legacy))), "s1", "linha legada resolve por timestamp para a rolling = defaults do catálogo")
	_check(_cfg.call("EntryForSeasonRow", entries, {}).is_empty(), "sem linha, sem entrada (nada é inventado)")
	_check(_cfg.call("EntryForSeasonRow", [], legacy).is_empty(), "calendário inválido não resolve entrada nenhuma")
	# Preempção: a rolling em andamento congela quando a agendada assume.
	var activeRolling : Dictionary = {"season_id": 9, "starts_at": now - 10 * DaySeconds, "ends_at": now + 20 * DaySeconds, "rules_frozen": str(_cfg.call("RulesJSONForEntry", _cfg.call("EntryByID", entries, "s1")))}
	_check(bool(_cfg.call("ShouldPreempt", entries, activeRolling, start + 60)), "a sucessora agendada preempta a rolling")
	_check(not bool(_cfg.call("ShouldPreempt", entries, activeRolling, now)), "antes do marco não se mexe na temporada no ar")
	var activeS2 : Dictionary = {"season_id": 10, "starts_at": start, "ends_at": start + 30 * DaySeconds, "rules_frozen": str(_cfg.call("RulesJSONForEntry", _cfg.call("EntryByID", entries, "s2")))}
	_check(not bool(_cfg.call("ShouldPreempt", entries, activeS2, start + DaySeconds)), "uma nominal nunca é preemptada por outra nominal")
	_check(not bool(_cfg.call("ShouldPreempt", entries, legacy, start + 60)), "linha legada (sem config_id) nunca é preemptada")
	# Wiring do relógio: a preempção e o fail-closed estão no caminho de produção.
	var seasonSrc : String = FileAccess.get_file_as_string("res://sources/economy/SeasonService.gd")
	_contains(seasonSrc, "SeasonConfig.ShouldPreempt(SeasonConfig.Entries(), active, now)", "TickSeasonLifecycle consulta a preempção do calendário")
	_contains(seasonSrc, "SeasonConfig.Errors()", "EnsureSeason lê os erros do calendário")
	_contains(seasonSrc, "push_error(\"Seasons: nenhuma temporada abre com seasons.json inválido", "a recusa de abrir é push_error, não silêncio")
	_contains(seasonSrc, "_CreateSeasonWindow(int(window[\"starts_at\"]), int(window[\"ends_at\"]), SeasonConfig.RulesJSONForEntry(entry))", "a abertura usa a janela e as regras do arquivo")
	_cfg.call("ClearRawForTests")

# ------------------------------------------------------------------ suite B: fail-closed

func _suiteSeasonFailClosed():
	print("[suite] B: seasons.json quebrado/typado = fail-closed com erro claro")
	var t0 : int = 1800000000
	var good : Dictionary = _rolling("s1", "S1", 30)
	_check(_cfg.call("ValidateSeasons", "").size() > 0, "arquivo ausente/vazio é erro")
	_checkHas(_cfg.call("ValidateSeasons", "{ \"seasons\": [ }, "), "não é um objeto JSON", "JSON sintaticamente quebrado é erro")
	_checkHas(_cfg.call("ValidateSeasons", "{\"season\": []}"), "ausente ou não é uma lista", "chave errada no topo é erro (não vira agenda vazia)")
	_checkHas(_cfg.call("ValidateSeasons", "{\"seasons\": []}"), "vazia", "lista sem entrada é erro")
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([good, good])), "duplicado", "id duplicado é erro (a resolução por timestamp ficaria ambígua)")
	var typo : Dictionary = _rolling("s3", "S3", 30)
	typo["start_unx"] = t0
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([typo])), "chave desconhecida", "typo de chave é erro (start_unx não é \"sem janela\")")
	var neg : Dictionary = _rolling("s4", "S4", -5)
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([neg])), "duration_days", "duração não-positiva é erro")
	var half : Dictionary = _rolling("s5", "S5", 30)
	half["start_unix"] = t0
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([half])), "janela inválida", "janela pela metade é erro")
	var floaty : Dictionary = _rolling("s6", "S6", 30)
	floaty["end_unix"] = 1.5
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([floaty])), "não é número inteiro", "timestamp fracionado é erro")
	var badRace : Dictionary = _rolling("s7", "S7", 30)
	badRace["races"] = ["power", "durabilidade"]
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badRace])), "SEASON_KINDS", "corrida inexistente é erro")
	var badSku : Dictionary = _rolling("s8", "S8", 30)
	badSku["premium_sku"] = "pass.nao.existe"
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badSku])), "SHOP_CATALOG", "SKU de passe não cobrável é erro")
	var badTier : Dictionary = _scheduled("s9", "S9", t0, 10)
	badTier["pass_tiers"] = {"max_level": 25, "free": {"26": {"gems": 5}}}
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badTier])), "fora de 1..25", "nível acima do teto da própria temporada é erro")
	var badMax : Dictionary = _rolling("s10", "S10", 30)
	badMax["pass_tiers"] = {"max_level": 41}
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badMax])), "max_level", "teto acima do que a curva de PT alcança é erro")
	var badCosm : Dictionary = _rolling("s11", "S11", 30)
	badCosm["pass_tiers"] = {"free": {"2": {"cosmetics": ["skin_inventada"]}}}
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badCosm])), "COSMETIC_CATALOG", "cosmético fora do catálogo é erro")
	var badField : Dictionary = _rolling("s12", "S12", 30)
	badField["pass_tiers"] = {"free": {"2": {"glims": 5}}}
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badField])), "não conhece", "campo que o aplicador não sabe pagar é erro")
	var badDur : Dictionary = _scheduled("s13", "S13", t0, 10)
	badDur["duration_days"] = 12
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([badDur])), "duration_days", "janela e duração divergentes são erro")
	var now : int = int(Time.get_unix_time_from_system())
	var expired : Dictionary = _scheduled("s14", "S14", now - 40 * DaySeconds, 10)
	expired["duration_days"] = 10
	expired["end_unix"] = now - 30 * DaySeconds
	_checkHas(_cfg.call("ValidateSeasons", _seasonsRaw([expired])), "capaz de abrir", "só janela vencida e nenhuma rolling = o jogo ficaria sem temporada")
	# Janela vencida continua SENDO histórico válido (resolve passe de temporada
	# encerrada); o que não pode é não sobrar nada capaz de abrir.
	_checkEq(_cfg.call("ValidateSeasons", _seasonsRaw([good, expired])).size(), 0, "vencida + rolling valida limpa (histórico preservado)")
	# Fail-closed de comportamento: nada abre, nada é silencioso.
	_cfg.call("SetRawForTests", "{ \"seasons\": [ }")
	_check(_cfg.call("Errors").size() > 0, "Errors() reporta o conteúdo quebrado")
	_check(not bool(_cfg.call("IsValid")), "IsValid() false com arquivo quebrado")
	_checkEq(_cfg.call("Entries").size(), 0, "Entries() fica vazia (nada entra no ar sem validação)")
	_check(_cfg.call("EntryToOpen", _cfg.call("Entries"), now).is_empty(), "EntryToOpen não inventa temporada: o relógio recebe {} e recusa abrir")
	_check(_cfg.call("ResolveAt", _cfg.call("Entries"), now).is_empty(), "resolução com calendário inválido é vazia, não \"S1 por padrão\"")
	_cfg.call("ClearRawForTests")
	_checkEq(_cfg.call("Errors").size(), 0, "o arquivo bom volta a validar (nenhum estado travado)")
	_check(not _cfg.call("EntryToOpen", _cfg.call("Entries"), now).is_empty(), "com o arquivo bom há o que abrir")
	_checkEq(_cfg.call("ValidateSeasons", _seasonsRaw([good, _scheduled("s2", "S2", t0, 21)])).size(), 0, "controle: o positivo do parser não é sortudo")

# ------------------------------------------------------------------ suite B2: passe por configuração

func _suitePassByConfig():
	print("[suite] B2: trilha do passe pode ser dado da temporada (PassService lê SeasonConfig)")
	var t0 : int = 1800000000
	var declared : Dictionary = _scheduled("s2", "S2", t0, 25)
	declared["pass_tiers"] = {"max_level": 25, "bonus_start": 21, "bonus_gems": 30,
		"free": {"2": {"gems": 7}, "10": {"chests": 2, "cosmetics": ["emote_tocha"]}},
		"premium": {"4": {"cosmetics": ["skin_manto"]}, "20": {"gems": 40, "vip_days": 3}}}
	var raw : String = _seasonsRaw([_rolling("s1", "S1", 30), declared])
	_checkEq(_cfg.call("ValidateSeasons", raw).size(), 0, "temporada com trilha declarada valida")
	_cfg.call("SetRawForTests", raw)
	var entries : Array = _cfg.call("Entries")
	var s2 : Dictionary = _cfg.call("EntryByID", entries, "s2")
	var s1 : Dictionary = _cfg.call("EntryByID", entries, "s1")
	_checkEq(int(_cfg.call("PassMaxLevel", s2)), 25, "teto de nível é da temporada")
	_checkEq(int(_cfg.call("PassBonusStart", s2)), 21, "bônus começa onde a temporada diz")
	_checkEq(int(_cfg.call("PassBonusGems", s2)), 30, "bônus paga o valor da temporada")
	var free : Dictionary = _cfg.call("PassTiers", s2, "free")
	_checkEq(free.size(), 2, "trilha free declarada parseada (2 níveis)")
	_check(bool((free as Dictionary).has(2)), "chave de nível é INT (JSON só tem string; dict int×float não bate)")
	_checkEq(int(((free as Dictionary)[10] as Dictionary).get("chests", 0)), 2, "recompensa com dois campos parseada (chests)")
	_checkEq((((free as Dictionary)[10] as Dictionary).get("cosmetics", []) as Array).size(), 1, "e a lista de cosméticos chega como lista")
	var premium : Dictionary = _cfg.call("PassTiers", s2, "premium")
	_checkEq(int(((premium as Dictionary)[20] as Dictionary).get("vip_days", 0)), 3, "vip_days da trilha premium declarada")
	_checkEq(int(_cfg.call("PassMaxLevel", s1)), int(_catalog.get("PASS_MAX_LEVEL")), "S1 sem trilha = teto do catálogo (comportamento antigo)")
	_checkEq((_cfg.call("PassTiers", s1, "free") as Dictionary).size(), 0, "S1 sem trilha: PassTiers devolve vazio e o chamador cai no catálogo")
	# Os dois leitores reais do PassService, sem banco (funções puras do serviço).
	var passSvc : RefCounted = _pass.call("new")
	_check(passSvc != null, "PassService instancia para o teste das funções puras")
	if passSvc != null:
		var fallbackFree : Dictionary = passSvc.call("_PassTrackTable", {}, "free")
		_checkEq(fallbackFree.size(), ( _catalog.get("PASS_FREE") as Dictionary).size(), "sem entrada declarada, a trilha é a do catálogo (tamanho idêntico)")
		_checkEq(int((fallbackFree.get(30, {}) as Dictionary).get("gems", 0)), 30, "e paga o mesmo prêmio de sempre no nível 30")
		var declaredFree : Dictionary = passSvc.call("_PassTrackTable", s2, "free")
		_checkEq(declaredFree.size(), 2, "com trilha declarada, é ela que vale")
		_checkEq(int((declaredFree.get(2, {}) as Dictionary).get("gems", 0)), 7, "gems do nível 2 vêm do JSON")
		_checkStr(str(passSvc.call("_PassCosmeticSource", {}, "premium", 12)), "pass_s1:premium:12", "linha sem config_id mantém a etiqueta histórica pass_s1 (nada já concedido muda de origem)")
		_checkStr(str(passSvc.call("_PassCosmeticSource", s2, "premium", 4)), "pass_s2:premium:4", "a S2 estreita com a própria etiqueta")
		_check((passSvc.call("_SeasonEntry", {}) as Dictionary).is_empty(), "sem temporada, sem entrada (o passe continua no_season)")
	_cfg.call("ClearRawForTests")

# ------------------------------------------------------------------ suite C: janelas do calendário

func _suiteCalendarWindows():
	print("[suite] C: LiveOpsCalendar resolve antes/dentro/depois e sobrevõe sem compor")
	var t0 : int = 1890000000
	var xp : Dictionary = _event("double_xp", "xp_double_copa", t0, t0 + 2 * DaySeconds, 2.0)
	var raw : String = _eventsRaw([xp])
	_checkEq(_cal.call("ValidateCalendar", raw).size(), 0, "calendário com uma janela double_xp valida")
	var entries : Array = _cal.call("ParseEntries", raw)
	_check(_cal.call("ActiveAtFrom", entries, "double_xp", t0 - 1).is_empty(), "um segundo antes: nada no ar")
	_checkStr(str(((_cal.call("ActiveAtFrom", entries, "double_xp", t0) as Dictionary).get("key", ""))), "xp_double_copa", "no start_unix: no ar (inclusive)")
	_checkStr(str(((_cal.call("ActiveAtFrom", entries, "double_xp", t0 + 2 * DaySeconds - 1) as Dictionary).get("key", ""))), "xp_double_copa", "no último segundo: ainda no ar")
	_check(_cal.call("ActiveAtFrom", entries, "double_xp", t0 + 2 * DaySeconds).is_empty(), "no end_unix: fora (fim exclusivo, sem segundo perdido entre janelas)")
	_check(_cal.call("ActiveAtFrom", entries, "double_xp", t0 + 9 * DaySeconds).is_empty(), "muito depois: nada no ar")
	_checkNear(float(_cal.call("ValueAtFrom", entries, "double_xp", t0 + DaySeconds, 1.0)), 2.0, 0.000001, "value dentro da janela")
	_checkNear(float(_cal.call("ValueAtFrom", entries, "double_xp", t0 + 5 * DaySeconds, 1.0)), 1.0, 0.000001, "value fora da janela = neutro")
	_checkNear(float(_cal.call("ValueAtFrom", entries, "chest_bonus", t0 + DaySeconds, 1.0)), 1.0, 0.000001, "kind sem janela = neutro (não vaza double_xp)")
	_check(_cal.call("ActiveAtFrom", entries, "copa_do_mundo", t0 + DaySeconds).is_empty(), "kind inexistente não resolve nada")
	# encadeamento: duas janelas coladas não se sobrepõem
	var second : Dictionary = _event("double_xp", "xp_double_segunda", t0 + 2 * DaySeconds, t0 + 4 * DaySeconds, 3.0)
	var chained : Array = _cal.call("ParseEntries", _eventsRaw([xp, second]))
	_checkStr(str((chained[0] as Dictionary).get("key", "")), "xp_double_copa", "a primeira janela cobre até o marco")
	_checkNear(float(_cal.call("ValueAtFrom", chained, "double_xp", t0 + 2 * DaySeconds, 1.0)), 3.0, 0.000001, "no marco exato vale a segunda (encadeamento sem buraco nem sobreposição)")
	# sobreposição real: determinística e NÃO compõe
	var wide : Dictionary = _event("double_xp", "xp_larga", t0, t0 + 5 * DaySeconds, 2.0)
	var late : Dictionary = _event("double_xp", "xp_curta_tardia", t0 + DaySeconds, t0 + 2 * DaySeconds, 3.0)
	var mid : Dictionary = _event("double_xp", "xp_meia", t0 + DaySeconds, t0 + 3 * DaySeconds, 1.5)
	var overlapped : Array = _cal.call("ParseEntries", _eventsRaw([wide, late, mid]))
	var winner : Dictionary = _cal.call("ActiveAtFrom", overlapped, "double_xp", t0 + DaySeconds + 60)
	_checkStr(str(winner.get("key", "")), "xp_meia", "começa depois vence; empate de início é resolvido por fim mais distante")
	_checkNear(float(winner.get("value", 0.0)), 1.5, 0.000001, "e paga UM multiplicador (×2 sobre ×3 não vira ×6)")
	var dupLate : Dictionary = _event("double_xp", "xp_empate_b", t0 + DaySeconds, t0 + 3 * DaySeconds, 4.0)
	var dupEntries : Array = _cal.call("ParseEntries", _eventsRaw([wide, mid, dupLate]))
	_checkNear(float(_cal.call("ValueAtFrom", dupEntries, "double_xp", t0 + DaySeconds + 60, 1.0)), 4.0, 0.000001, "empate total (início e fim): a última do arquivo vence, sempre")
	var dupSwap : Array = _cal.call("ParseEntries", _eventsRaw([wide, dupLate, mid]))
	_checkNear(float(_cal.call("ValueAtFrom", dupSwap, "double_xp", t0 + DaySeconds + 60, 1.0)), 1.5, 0.000001, "inverter a ordem no arquivo inverte o vencedor (regra é estável, não arbitrária)")
	# kinds convivem
	var chest : Dictionary = _event("chest_bonus", "baus_copa", t0, t0 + 3 * DaySeconds, 1.5)
	var tourney : Dictionary = _event("tournament", "copa_sabado", t0 + DaySeconds, t0 + 2 * DaySeconds, 1.0)
	var mixed : Array = _cal.call("ParseEntries", _eventsRaw([xp, chest, tourney]))
	var active : Array = _cal.call("ActiveEntriesAt", mixed, t0 + DaySeconds + 60)
	_checkEq(active.size(), 3, "kinds diferentes não se cancelem (um por kind)")
	var kinds : Array[String] = []
	for item in active:
		kinds.append(str((item as Dictionary).get("kind", "")))
	_check(kinds.has("double_xp") and kinds.has("chest_bonus") and kinds.has("tournament"), "os três kinds ativos saem da consulta")
	_checkEq(active.size(), (_cal.call("ActiveEntriesAt", mixed, t0 - 1) as Array).size() + 3, "fora de tudo: nenhuma janela")
	_checkEq(int(_cal.call("NextStart", mixed, t0 - DaySeconds, "tournament")), t0 + DaySeconds, "next_start da copa")
	_checkEq(int(_cal.call("NextStart", mixed, t0 + 4 * DaySeconds, "")), 0, "sem evento futuro = 0")

# ------------------------------------------------------------------ suite C2: fail-closed do calendário

func _suiteCalendarFailClosed():
	print("[suite] C2: liveops_calendar.json quebrado = nenhum evento no ar (sentido seguro)")
	var t0 : int = 1890000000
	var good : Dictionary = _event("double_xp", "xp_ok", t0, t0 + DaySeconds, 2.0)
	_check(_cal.call("ValidateCalendar", "").size() > 0, "arquivo ausente é erro")
	_checkHas(_cal.call("ValidateCalendar", "[1,2]"), "não é um objeto JSON", "topo errado é erro")
	_checkHas(_cal.call("ValidateCalendar", "{\"event\": []}"), "ausente ou não é uma lista", "\"events\" ausente é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp2", "xp_typo", t0, t0 + DaySeconds, 2.0)])), "kind", "kind com typo é erro (evento que nunca dispara)")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([good, good])), "duplicada", "key duplicada é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "", t0, t0 + DaySeconds, 2.0)])), "key", "key vazia é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "XP_Maiuscula", t0, t0 + DaySeconds, 2.0)])), "fora do padr", "key fora do padrão é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "xp_sem_fim", t0, t0, 2.0)])), "vazia", "janela vazia é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "xp_invertida", t0 + DaySeconds, t0, 2.0)])), "end_unix", "fim antes do início é erro")
	var noStart : Dictionary = _event("double_xp", "xp_sem_start", t0, t0 + DaySeconds, 2.0)
	noStart.erase("start_unix")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([noStart])), "ausente", "evento sem janela é erro")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "xp_zero", t0, t0 + DaySeconds, 0.5)])), "fora de", "bônus abaixo de 1.0 é nerf disfarçado")
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([_event("double_xp", "xp_gigante", t0, t0 + DaySeconds, 20.0)])), "fora de", "dedo no teclado (20 em vez de 2.0) não vira faucet")
	var badKey : Dictionary = _event("double_xp", "xp_extra", t0, t0 + DaySeconds, 2.0)
	badKey["valor"] = 9
	_checkHas(_cal.call("ValidateCalendar", _eventsRaw([badKey])), "desconhecida", "chave com typo é erro")
	var tourneyBig : Dictionary = _event("tournament", "copa_valor", t0, t0 + DaySeconds, 99.0)
	_checkEq(_cal.call("ValidateCalendar", _eventsRaw([tourneyBig])).size(), 0, "tournament não é multiplicador de ganho: sem faixa de value")
	_cal.call("SetRawForTests", "{\"events\": [ }")
	_check(_cal.call("Errors").size() > 0, "Errors() do calendário reporta")
	_checkEq(_cal.call("Entries").size(), 0, "nada entra no ar com arquivo quebrado")
	_checkNear(float(_cal.call("ValueAtKind", "double_xp", t0, 1.0)), 1.0, 0.000001, "e o consumidor recebe o neutro 1.0 (fail-closed no sentido seguro)")
	_check(not bool(_cal.call("IsKindActive", "double_xp", t0)), "nada ativo")
	_cal.call("ClearRawForTests")
	_checkEq(_cal.call("ValidateCalendarFile").size(), 0, "o arquivo do repo volta a validar")

# ------------------------------------------------------------------ suite D: o multiplicador no caminho real

func _suiteLiveOpsMultiplierPath():
	print("[suite] D: o double_xp do calendário entra no faucet do settle, número a número")
	var t0 : int = 1890000000
	var cases : Array = [[2.0, "xp_double_2"], [1.5, "xp_double_15"], [4.0, "xp_double_4"]]
	for item in cases:
		var value : float = float(item[0])
		_cal.call("SetRawForTests", _eventsRaw([_event("double_xp", str(item[1]), t0, t0 + 2 * DaySeconds, value)]))
		_checkNear(float(_offline.call("LiveOpsXpMods", t0 + DaySeconds)), value, 0.000001, "dentro da janela o settle aplica exatamente %s" % [str(value)])
		_checkNear(float(_offline.call("LiveOpsXpMods", t0 + 2 * DaySeconds)), 1.0, 0.000001, "no marco do fim volta ao neutro (%s)" % [str(value)])
		_checkNear(float(_cal.call("ValueAtKind", "double_xp", t0 + DaySeconds, 1.0)), float(_offline.call("LiveOpsXpMods", t0 + DaySeconds)), 0.000001, "o que o calendário resolve == o que o settle usa (uma fonte, um leitor)")
	_cal.call("ClearRawForTests")
	_checkNear(float(_offline.call("LiveOpsXpMods", t0 + DaySeconds)), 1.0, 0.000001, "calendário do repo (nenhuma janela no ar) = 1.0 no settle")
	# O kind errado não entra no eixo do XP.
	_cal.call("SetRawForTests", _eventsRaw([_event("chest_bonus", "baus_copa", t0, t0 + 2 * DaySeconds, 2.0), _event("tournament", "copa", t0, t0 + 2 * DaySeconds, 1.0)]))
	_checkNear(float(_offline.call("LiveOpsXpMods", t0 + DaySeconds)), 1.0, 0.000001, "chest_bonus/tournament não mexem no multiplicador de XP")
	_checkNear(float(_cal.call("ValueAtKind", "chest_bonus", t0 + DaySeconds, 1.0)), 2.0, 0.000001, "mas resolvem para quem for consumir (pendência de dono: _ChestBudgetToday / TournamentArenaService)")
	# Fail-closed no caminho do gameplay: arquivo inválido = 1.0, nunca "o último valor bom".
	_cal.call("SetRawForTests", "{\"events\": [{\"kind\": \"double_xp\", \"key\": 17}] }")
	_checkNear(float(_offline.call("LiveOpsXpMods", t0 + DaySeconds)), 1.0, 0.000001, "com o calendário inválido o settle NÃO aplica bônus nenhum")
	_cal.call("ClearRawForTests")
	# Wiring: a chamada está dentro do ramo que roda no settle de conta real.
	var settleSrc : String = FileAccess.get_file_as_string("res://sources/idle/OfflineSettle.gd")
	_contains(settleSrc, "mods *= LiveOpsXpMods(now)", "GetModsForAccount multiplica o modificador da agenda")
	_contains(settleSrc, "LiveOpsCalendar.ValueAtKind(LiveOpsCalendar.KindDoubleXP", "e lê o kind certo do calendário")
	var inBranch : int = settleSrc.find("mods *= LiveOpsXpMods(now)")
	var branch : int = settleSrc.rfind("if accountID > 0 and now > 0:", inBranch)
	_check(branch >= 0 and branch < inBranch and inBranch - branch < 900, "a chamada está no ramo de conta com relógio (não no preview anônimo)")
	_checkEq(int(_offline.call("GetModsForAccount", 0, t0 + DaySeconds) * 1000), int(float(_offline.get("GuildHookFactor")) * 1000), "preview sem conta continua no gancho neutro (nada de agenda em quem não tem conta)")
