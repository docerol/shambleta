extends SceneTree

# OPS-2/OPS-3 (a ponta que faltava): o mecanismo de temporada é dado
# (`data/conf/seasons.json` + `SeasonConfig`), a agenda de live ops é dado
# (`data/conf/liveops_calendar.json` + `LiveOpsCalendar`), e as duas réguas de
# agenda que existem no repo medem cada arquivo SOZINHO — `season_schedule_test`
# prova que a sucessora tem janela futura e SKU cobrável, `ops_fix_test` prova que
# existe uma campanha futura em algum momento. Nada amarrava as duas coisas, e o
# buraco apareceu sozinho: uma temporada agendada para abrir em 2027-01-15 sem
# NENHUMA janela de campanha cobrindo o marco dela. O mecanismo é real, a agenda
# está vazia naquele dia, e "uma temporada nova é dado" só conta como shipped
# quando o calendário embarca junto com ela.
#
# Este harness é a régua entre os dois arquivos. O que ele amarra:
#   A  os dois arquivos embarcados validam limpo PELO PRODUTO (`Errors()`,
#      `ValidateCalendarFile()`, `ValidateSeasonsFile()`) — sem isso a "falta de
#      campanha" podia ser só um arquivo recusado e invisível no ar;
#   B  PARA CADA temporada declarada com janela futura existe campanha cobrindo a
#      abertura, e o marco em si abre com algum kind no ar;
#   C  as campanhas que servem a abertura não estão no passado da temporada que
#      servem (nem por cauda arrastada: janela que nasceu um mês antes do marco é
#      histórico que expirou em cima da data, não agenda de lançamento) e os
#      valores delas estão na banda que o próprio produto cobra, lida das
#      constantes do fonte (`MinBonusValue`/`MaxBonusValue` para kinds de bônus,
#      `MinPoolMod`/`MaxPoolMod` para kinds de pool) — o harness não redigita
#      1.0/4.0 de memória;
#   D  higiene da agenda embarcada: nenhum par de janelas do MESMO kind se
#      sobrepõe, toda key é única, e nenhum kind embarcado está fora de
#      `ImplementedKinds` (kind sem consumidor é "agenda que ninguém lê");
#   E  controles NEGATIVOS, todos em memória e revertidos no fim — cópias mutadas
#      do arquivo real: campanha de abertura jogada para depois do fim da
#      temporada (a régua acusa), calendário reduzido às linhas que não servem
#      abertura nenhuma — é o arquivo exatamente como estava antes das linhas
#      novas (a régua acusa), `value` acima do teto (o validador do produto RECUSA
#      e o fail-closed deixa o consumidor no neutro), duas janelas do mesmo kind
#      sobrepostas (a régua de higiene acusa E o resolvedor se recusa a compor),
#      cauda de campanha antiga terminando dentro da abertura, `value` de pool
#      fora da banda do consumidor, agenda vazia. Sem isto, "0 failures" podia
#      significar apenas que a régua relê um arquivo que não sabe falhar.
#
# O que ele NÃO faz: não reimplementa parsing nem validação (os dois arquivos
# entram pelo caminho real do produto, `CurrentRaw` → `Validate*` → `Entries`), não
# inventa kind novo (um kind sem leitor seria promessa falsa, e `LiveOpsCalendar`
# recusaria o arquivo inteiro por `ImplementedKinds`), não escreve um byte sequer
# em disco. Contrato dos scripts `-s` do repo: o script compila antes dos
# autoloads, então nada de `SeasonConfig`/`LiveOpsCalendar` como identificador
# global em tempo de parse — as classes entram por `load()`. Não toca banco, rede
# nem mundo.

const DaySeconds : int				= 86400
const HourSeconds : int				= 3600
# Definição EXATA do que este harness chama de "abertura", escrita aqui porque é
# ela que é cobrada: os primeiros `OpeningSeconds` (7 dias) contados do
# `start_unix` nominal da temporada, truncados no `end_unix` do arquivo (uma
# temporada mais curta que a própria janela de abertura não tem abertura de 7
# dias). A janela de uma campanha é [start_unix, end_unix) — fim EXCLUSIVO, que é
# a regra do produto em `LiveOpsCalendar._Covers`. "Cobre a abertura" = interseção
# não-vazia das duas janelas, resolvida em INTEIRO UNIX, nunca comparando string
# de data. Como a janela de abertura está contida na temporada, cobertura da
# abertura implica que a campanha vive dentro do calendário que ela serve.
const OpeningSeconds : int			= 7 * DaySeconds
# O marco em si é exigido À PARTE: não basta "tem campanha em algum momento da
# primeira semana" — um lançamento que só acende no terceiro dia é agenda de
# meia-tigela, e o dia em que a temporada assume a rotação é o dia em que o
# jogador novo e o que voltou estão no mesmo lugar.
const SeasonsResPath : String		= "res://data/conf/seasons.json"
const CalendarResPath : String		= "res://data/conf/liveops_calendar.json"

var checks : int = 0
var failures : int = 0

var _cfg : GDScript = null
var _cal : GDScript = null
# Os consumidores reais: a agenda só é promessa se o multiplicador chega ao caminho
# que paga o jogador. `OfflineSettle.LiveOpsXpMods`/`LiveOpsChestMods` e
# `TournamentArenaService.PrizePoolMod` são estáticos puros (timestamp entra, float
# sai), exatamente como `season_liveops_test` e `ops_fix_test` os chamam — nada
# aqui toca banco, mundo ou rede.
var _offline : GDScript = null
var _arena : GDScript = null
# A foto limpa dos dois arquivos, tirada pelo caminho do produto antes de qualquer
# mutação em memória: é contra ela que os controles negativos comparam, e é ela
# que o fim do run confere de volta.
var shippedSeasons : Array = []
var shippedCampaigns : Array = []
var shippedRaw : String = ""

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

func _checkNear(value : float, expected : float, epsilon : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > epsilon:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(value), str(expected)])
		return false
	return true

func _checkHas(errors : PackedStringArray, needle : String, label : String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return _check(true, label)
	return _check(false, "%s (esperado achar \"%s\" em %s)" % [label, needle, str(errors)])

# ------------------------------------------------------------------ a régua

# Uma temporada "tem janela futura" quando o produto a declara agendada
# (`IsScheduled`) e o `start_unix` dela ainda não chegou. É o conjunto que a
# exigência de cobertura percorre — a rotação do beta fica de fora de propósito:
# ela abre no instante do run, e amarrar campanha a uma janela que é sempre
# "agora" obrigaria a agenda a ter um bônus ligado para sempre, que é exatamente o
# que `_cuidado_com_a_suite` proíbe (SuiteSettleGolden calcula a expectativa com
# mods 1.0).
func _futureWindowSeasons(entries : Array, now : int) -> Array:
	var out : Array = []
	for item in entries:
		var entry : Dictionary = item
		if not bool(_cfg.call("IsScheduled", entry)):
			continue
		if int(entry.get("start_unix", 0)) > now:
			out.append(entry)
	return out

# A janela de abertura de uma temporada, pelo contrato declarado no cabeçalho.
func _openingOf(season : Dictionary) -> Dictionary:
	var mark : int = int(season.get("start_unix", 0))
	var seasonEnd : int = int(season.get("end_unix", 0))
	return {"mark": mark, "opening_end": mini(mark + OpeningSeconds, seasonEnd)}

func _markOf(season : Dictionary) -> int:
	return int(_openingOf(season)["mark"])

func _openingEndOf(season : Dictionary) -> int:
	return int(_openingOf(season)["opening_end"])

# As campanhas cuja janela [start, end) intercepta a abertura. É o PREDICADO DESTE
# HARNESS aplicado sobre as entradas que o PRODUTO devolve — quem trouxe as
# janelas foi `LiveOpsCalendar.ParseEntries`, nada aqui redecodifica JSON à mão.
func _servesOpening(camp : Dictionary, mark : int, openingEnd : int) -> bool:
	var startsAt : int = int(camp.get("start_unix", 0))
	var endsAt : int = int(camp.get("end_unix", 0))
	return endsAt > startsAt and startsAt < openingEnd and endsAt > mark

func _servingCampaigns(campaigns : Array, mark : int, openingEnd : int) -> Array:
	var out : Array = []
	for item in campaigns:
		var camp : Dictionary = item
		if _servesOpening(camp, mark, openingEnd):
			out.append(camp)
	return out

func _servesAnyUpcoming(camp : Dictionary, upcoming : Array) -> bool:
	for item in upcoming:
		if _servesOpening(camp, _markOf(item), _openingEndOf(item)):
			return true
	return false

# O veredito da régua para UMA temporada: vazio = a abertura está coberta. Toda
# acusação nomeia o id da temporada, porque é assim que o log diz QUAL agenda
# falta, em vez de "alguma coisa" falhou.
func _openingGaps(season : Dictionary, campaigns : Array, now : int) -> PackedStringArray:
	var gaps : PackedStringArray = PackedStringArray()
	var id : String = str(_cfg.call("ConfigID", season))
	var label : String = str(_cfg.call("Label", season))
	var mark : int = _markOf(season)
	var openingEnd : int = _openingEndOf(season)
	var serving : Array = _servingCampaigns(campaigns, mark, openingEnd)
	if serving.is_empty():
		gaps.append("%s (%s): nenhuma campanha cobre a abertura [%d, %d) — temporada agendada sem live ops no marco" % [id, label, mark, openingEnd])
	# O marco abre com algo no ar? A pergunta é feita ao RESOLVEDOR do produto
	# (`ActiveEntriesAt`), com entradas que o produto parseou — elas carregam o
	# `_idx` que a resolução exige, e é por isso que toda cópia mutada deste
	# harness passa por `ParseEntries` antes de ser medida.
	var atMark : Array = _cal.call("ActiveEntriesAt", campaigns, mark)
	if atMark.is_empty():
		gaps.append("%s (%s): o instante do marco (%d) não tem NENHUM kind no ar" % [id, label, mark])
	for item in serving:
		var camp : Dictionary = item
		var key : String = str(camp.get("key", ""))
		var startsAt : int = int(camp.get("start_unix", 0))
		var endsAt : int = int(camp.get("end_unix", 0))
		var kind : String = str(camp.get("kind", ""))
		# "não está no passado da temporada que serve": o fim exclusivo tem que
		# cair depois do marco, e o nascimento a no máximo uma janela de abertura
		# antes dele — uma campanha que expirou em cima da data não é lançamento.
		if endsAt <= mark:
			gaps.append("%s: campanha %s termina em %d <= marco %d (está no passado da temporada que serviria)" % [id, key, endsAt, mark])
		if startsAt < mark - OpeningSeconds:
			gaps.append("%s: campanha %s nasceu em %d, mais de %d s antes do marco %d (cauda de campanha antiga não é agenda de lançamento)" % [id, key, startsAt, OpeningSeconds, mark])
		if endsAt <= now:
			gaps.append("%s: campanha %s já encerrou antes deste run (fim %d <= agora %d)" % [id, key, endsAt, now])
		var band : Array = _bandOf(kind)
		if band.size() == 2:
			var value : float = float(camp.get("value", 0.0))
			if value < float(band[0]) or value > float(band[1]):
				gaps.append("%s: campanha %s (%s) com value %s fora da banda %s..%s que o produto cobra" % [id, key, kind, str(value), str(band[0]), str(band[1])])
	return gaps

# A banda que o PRODUTO cobra de cada kind, lida das constantes do fonte. Kinds de
# bônus têm faixa cobrada no arquivo (`BonusKinds`); kinds de pool têm faixa
# cobrada no consumidor (`PoolKinds`). A banda existe nos dois casos, o que muda é
# onde ela morde — o harness não assume nenhuma das duas de memória.
func _bandOf(kind : String) -> Array:
	var bonusKinds : Variant = _cal.get("BonusKinds")
	var poolKinds : Variant = _cal.get("PoolKinds")
	if bonusKinds is Array and (bonusKinds as Array).has(kind):
		return [float(_cal.get("MinBonusValue")), float(_cal.get("MaxBonusValue"))]
	if poolKinds is Array and (poolKinds as Array).has(kind):
		return [float(_cal.get("MinPoolMod")), float(_cal.get("MaxPoolMod"))]
	return []

func _has(arrayVariant : Variant, value : String) -> bool:
	return arrayVariant is Array and (arrayVariant as Array).has(value)

func _joinGaps(gaps : PackedStringArray) -> String:
	var out : String = ""
	for g in gaps:
		out += " | " + str(g)
	return out

# Sobreposição do MESMO kind na agenda. O produto NÃO recusa o par sobreposto no
# arquivo — a regra dele é determinística e anti-composição (vence a que começa
# depois; duas janelas de double_xp cruzadas pagam ×2, nunca ×4). Por isso a
# higiene é régua deste harness, não erro de validação, e é assim que ela aparece
# na mensagem.
func _sameKindOverlaps(campaigns : Array) -> PackedStringArray:
	var found : PackedStringArray = PackedStringArray()
	for i in campaigns.size():
		for j in range(i + 1, campaigns.size()):
			var a : Dictionary = campaigns[i]
			var b : Dictionary = campaigns[j]
			if str(a.get("kind", "")) != str(b.get("kind", "")):
				continue
			var overlap : int = mini(int(a.get("end_unix", 0)), int(b.get("end_unix", 0))) - maxi(int(a.get("start_unix", 0)), int(b.get("start_unix", 0)))
			if overlap > 0:
				found.append("kind %s sobreposto: %s e %s (%d s de interseção)" % [str(a.get("kind", "")), str(a.get("key", "")), str(b.get("key", "")), overlap])
	return found

# ------------------------------------------------------------------ serialização das cópias

# Serializa de volta pelo caminho do produto, SEM o `_idx` que `ParseEntries`
# atribui por posição: reinjetar `_idx` seria um erro de "chave desconhecida"
# inventado pelo harness, não pelo validador. Toda mutação passa por aqui e por
# `ParseEntries`, então as cópias carregam janelas e índices de verdade.
func _rawEvents(list : Array) -> String:
	return JSON.stringify({"events": list})

func _rawList(entries : Array) -> Array:
	var out : Array = []
	for item in entries:
		var entry : Dictionary = (item as Dictionary).duplicate(true)
		entry.erase("_idx")
		out.append(entry)
	return out

func _campaignsOf(list : Array) -> Array:
	return _cal.call("ParseEntries", _rawEvents(list))

func _seasonId(entry : Dictionary) -> String:
	return str(_cfg.call("ConfigID", entry))

# ------------------------------------------------------------------ run

func _run():
	print("[suite] alinhamento temporada x agenda de live ops (seasons.json + liveops_calendar.json)")
	_cfg = load("res://sources/season/SeasonConfig.gd")
	_cal = load("res://sources/ops/LiveOpsCalendar.gd")
	_offline = load("res://sources/idle/OfflineSettle.gd")
	_arena = load("res://sources/economy/TournamentArenaService.gd")
	if not _check(_cfg != null and _cal != null, "SeasonConfig/LiveOpsCalendar carregam por load()"):
		_finish()
		return
	# O veredito de alinhamento não depende dos consumidores: se `OfflineSettle` ou
	# `TournamentArenaService` estiverem quebrados por outra mão neste tree, isto é
	# UMA falha nomeando o arquivo (e a suíte de aterrissagem fica de fora), não o
	# colapso da régua de agenda inteira.
	_check(_offline != null, "OfflineSettle carrega por load() (é o seam que paga XP e baús)")
	_check(_arena != null, "TournamentArenaService carrega por load() (é o seam que paga o pool de copa)")
	# Estado conhecido antes de ler qualquer coisa: o fail-closed do produto é o
	# que o jogador recebe, então a régua começa neutra e termina neutra.
	_cfg.call("ClearRawForTests")
	_cal.call("ClearRawForTests")
	# Os dois arquivos entram pelo caminho do produto (`SHAMBLETA_LIVEOPS_FILE` /
	# `SHAMBLETA_SEASONS_FILE`, senão `res://`), lidos por `CurrentRaw`: uma régua
	# que lesse o disco por conta própria mediria outro arquivo.
	_check(str(_cal.call("FilePath")) == CalendarResPath or str(OS.get_environment(str(_cal.get("CalendarFileEnv")))) != "",
		"LiveOpsCalendar.FilePath() é o caminho que este harness lê (%s)" % str(_cal.call("FilePath")))
	_check(str(_cfg.call("CurrentRaw")).length() > 0, "seasons.json chega por SeasonConfig.CurrentRaw (sem ler o disco por fora)")
	shippedRaw = str(_cal.call("CurrentRaw"))
	_check(shippedRaw.length() > 0, "liveops_calendar.json chega por LiveOpsCalendar.CurrentRaw (sem redecodificar o disco por fora)")
	shippedSeasons = _cfg.call("Entries")
	shippedCampaigns = _cal.call("Entries")
	if not _check(not shippedSeasons.is_empty() and not shippedCampaigns.is_empty(),
			"os dois arquivos embarcados devolvem entradas (%d temporadas, %d campanhas)" % [shippedSeasons.size(), shippedCampaigns.size()]):
		_finish()
		return
	var now : int = int(Time.get_unix_time_from_system())
	_suiteShippedValid(now)
	_suiteOpeningAlignment(now)
	_suiteBandsAndFuture(now)
	_suiteAgendaHygiene(now)
	_suiteConsumerLanding(now)
	_suiteNegativeControls(now)
	_suiteReverted(now)
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ A

func _suiteShippedValid(now : int):
	print("[suite] A: os dois arquivos embarcados validam limpo pelo produto")
	var calErrors : PackedStringArray = _cal.call("Errors")
	_checkEq(calErrors.size(), 0, "LiveOpsCalendar.Errors() zero para a agenda do repo: %s" % [str(calErrors)])
	_check(bool(_cal.call("IsValid")), "a agenda embarcada é válida (Entries() não está vazio por recusa)")
	var revalidated : PackedStringArray = _cal.call("ValidateCalendarFile")
	_checkEq(revalidated.size(), 0, "ValidateCalendarFile (a mesma régua, lida do caminho do produto) devolve zero: %s" % [str(revalidated)])
	var fromRaw : PackedStringArray = _cal.call("ValidateCalendar", shippedRaw)
	_checkEq(fromRaw.size(), 0, "ValidateCalendar sobre o CurrentRaw embarcado devolve zero")
	var seasonErrors : PackedStringArray = _cfg.call("Errors")
	_checkEq(seasonErrors.size(), 0, "SeasonConfig.Errors() zero para o seasons.json do repo: %s" % [str(seasonErrors)])
	_check(bool(_cfg.call("IsValid")), "IsValid() com o arquivo de temporadas do repo")
	var seasonsFile : PackedStringArray = _cfg.call("ValidateSeasonsFile")
	_checkEq(seasonsFile.size(), 0, "ValidateSeasonsFile devolve zero (é isto que EnsureSeason lê antes de abrir)")
	var upcoming : Array = _futureWindowSeasons(shippedSeasons, now)
	if not upcoming.is_empty():
		# O marco que a régua de cobertura vai exigir coberto é o mesmo marco que o
		# relógio do produto promete abrir — uma temporada que só existe no JSON e
		# que `NextScheduledStart` não vê não abre nunca, e campanha nenhuma a serve.
		var mark : int = _markOf(upcoming[0])
		_checkEq(int(_cfg.call("NextScheduledStart", shippedSeasons, now)), mark, "o relógio do produto vê o marco da sucessora como a próxima temporada (%d)" % mark)
		_check(bool(_cfg.call("IsScheduled", _cfg.call("ResolveAt", shippedSeasons, mark))), "e a nominal assume no marco resolvido pelo produto")
	# O perigo de agenda conhecido, na outra ponta: nada deste arquivo pode cobrir
	# o instante do run no eixo do XP (SuiteSettleGolden calcula com mods 1.0), e
	# as duas réguas leem o mesmo instante.
	var xpNow : Dictionary = _cal.call("ActiveAtFrom", shippedCampaigns, str(_cal.get("KindDoubleXP")), now)
	_check(xpNow.is_empty(), "nenhum double_xp cobrindo este instante (%d) — a suíte dourada continua em mods 1.0 (achado: %s)" % [now, str(xpNow.get("key", ""))])
	_checkNear(float(_cal.call("ValueAtKind", str(_cal.get("KindDoubleXP")), now, float(_cal.get("DefaultMod")))), float(_cal.get("DefaultMod")), 0.000001, "e o consumidor do settle recebe o neutro hoje")

# ------------------------------------------------------------------ B

func _suiteOpeningAlignment(now : int):
	print("[suite] B: cada temporada com janela futura tem campanha cobrindo a abertura")
	var upcoming : Array = _futureWindowSeasons(shippedSeasons, now)
	# Sem isto a régua seria vacua: um arquivo sem sucessora agendada "passa"
	# porque não há o que cobrir, e o verde mentiria.
	if not _check(upcoming.size() >= 1, "há ao menos uma temporada com janela futura para cobrir (%d)" % upcoming.size()):
		return
	var covered : int = 0
	for item in upcoming:
		var season : Dictionary = item
		var id : String = _seasonId(season)
		var mark : int = _markOf(season)
		var openingEnd : int = _openingEndOf(season)
		var gaps : PackedStringArray = _openingGaps(season, shippedCampaigns, now)
		var serving : Array = _servingCampaigns(shippedCampaigns, mark, openingEnd)
		_checkEq(gaps.size(), 0, "%s: abertura coberta pela agenda embarcada%s" % [id, _joinGaps(gaps)])
		_check(serving.size() >= 1, "%s: %d campanha(s) com janela interceptando [%d, %d)" % [id, serving.size(), mark, openingEnd])
		_check(mark + OpeningSeconds <= int(season.get("end_unix", 0)),
			"%s: a janela de abertura cabe no calendário da temporada (%d + %d <= %d)" % [id, mark, OpeningSeconds, int(season.get("end_unix", 0))])
		_check(mark > now, "%s: o marco (%d) é futuro relativo a este run (%d) — nada aqui liga bônus no presente" % [id, mark, now])
		# O marco em si, pela resolução do produto, não por contagem minha.
		var atMark : Array = _cal.call("ActiveEntriesAt", shippedCampaigns, mark)
		_check(atMark.size() >= 1, "%s: o marco (%d) abre com algum kind no ar (%d no ar)" % [id, mark, atMark.size()])
		var oneSecondLater : Array = _cal.call("ActiveEntriesAt", shippedCampaigns, mark + 1)
		_checkEq(atMark.size(), oneSecondLater.size(), "%s: a cobertura não morre no primeiro segundo (fim exclusivo não engole o dia 1)" % id)
		var lastSecond : Array = _cal.call("ActiveEntriesAt", shippedCampaigns, openingEnd - 1)
		_check(lastSecond.size() >= 1, "%s: o último segundo da abertura (%d) ainda tem kind no ar (%d)" % [id, openingEnd - 1, lastSecond.size()])
		# Nenhum DIA da abertura abre em branco: a exigência não é "existe uma
		# campanha em algum momento", é "cada dia dos primeiros 7 tem alguma coisa
		# no ar". Uma temporada com double_xp só no dia 1 e nada nos outros seis
		# passaria na checagem de interseção e seria lançamento pela metade.
		var dayCount : int = int((openingEnd - mark + DaySeconds - 1) / DaySeconds)
		var blankDays : String = ""
		for d in range(dayCount):
			var ts : int = mark + d * DaySeconds
			if (_cal.call("ActiveEntriesAt", shippedCampaigns, ts) as Array).is_empty():
				blankDays += "%d " % d
		_checkEq(blankDays.length(), 0, "%s: nenhum dia da abertura [%d, %d) em branco (dias vazios: %s)" % [id, mark, openingEnd, blankDays])
		if gaps.is_empty():
			covered += 1
	_checkEq(covered, upcoming.size(), "todas as %d temporadas futuras têm a abertura coberta" % upcoming.size())
	# A rotação fica de fora da exigência, mas a régua precisa dizer que ela está
	# lá: é ela que responde pelo instante do run.
	var rolling : int = shippedSeasons.size() - upcoming.size()
	_check(rolling >= 1, "%d temporada(s) de rotação sem janela nominal ficam fora da exigência (é ela que abre hoje)" % rolling)

# ------------------------------------------------------------------ C

func _suiteBandsAndFuture(now : int):
	print("[suite] C: as campanhas da abertura não estão no passado e os valores estão na banda do produto")
	var bands : String = "bonus %s..%s pool %s..%s" % [str(_cal.get("MinBonusValue")), str(_cal.get("MaxBonusValue")), str(_cal.get("MinPoolMod")), str(_cal.get("MaxPoolMod"))]
	var ceiling : float = float(_cal.get("MaxBonusValue"))
	var minBonus : float = float(_cal.get("MinBonusValue"))
	_check(ceiling > minBonus, "a banda lida do fonte é uma faixa e não um ponto (%s)" % bands)
	_check(ceiling < 100.0, "o teto lido do fonte é um teto de verdade, não um dedo no teclado (%s)" % str(ceiling))
	var inspected : int = 0
	var offBand : String = ""
	var past : String = ""
	var staleTail : String = ""
	var kindsSeen : Dictionary = {}
	for item in _futureWindowSeasons(shippedSeasons, now):
		var season : Dictionary = item
		var id : String = _seasonId(season)
		var mark : int = _markOf(season)
		var serving : Array = _servingCampaigns(shippedCampaigns, mark, _openingEndOf(season))
		for entry in serving:
			var camp : Dictionary = entry
			var key : String = str(camp.get("key", ""))
			var kind : String = str(camp.get("kind", ""))
			var value : float = float(camp.get("value", 0.0))
			inspected += 1
			kindsSeen[kind] = true
			var band : Array = _bandOf(kind)
			_check(band.size() == 2, "%s: kind %s tem banda declarada no produto (%s)" % [key, kind, bands])
			if band.size() == 2 and (value < float(band[0]) or value > float(band[1])):
				offBand += "%s=%s " % [key, str(value)]
			if int(camp.get("end_unix", 0)) <= now:
				past += key + " "
			if int(camp.get("start_unix", 0)) < mark - OpeningSeconds:
				staleTail += key + " "
			_check(int(camp.get("end_unix", 0)) > int(camp.get("start_unix", 0)), "%s: janela não vazia (fim exclusivo depois do início)" % key)
			_check(int(camp.get("end_unix", 0)) > mark, "%s: não termina antes do marco %d da temporada %s" % [key, mark, id])
			_check(int(camp.get("start_unix", 0)) >= mark - OpeningSeconds, "%s: nasceu a no máximo uma janela de abertura antes do marco %d" % [key, mark])
	_check(inspected >= 1, "%d campanha(s) de abertura inspecionadas nas temporadas futuras" % inspected)
	_checkEq(offBand.length(), 0, "nenhum value de abertura fora da banda do produto (%s)" % offBand)
	_checkEq(past.length(), 0, "nenhuma campanha de abertura já encerrou relativo a este run (%s)" % past)
	_checkEq(staleTail.length(), 0, "nenhuma campanha de abertura é cauda arrastada de mês anterior (%s)" % staleTail)
	_check(kindsSeen.has(str(_cal.get("KindDoubleXP"))), "a abertura mexe no eixo do faucet (double_xp) — %s" % str(kindsSeen.keys()))
	_check(kindsSeen.has(str(_cal.get("KindChestBonus"))), "e no eixo do cofre (chest_bonus) — %s" % str(kindsSeen.keys()))
	_check(kindsSeen.has(str(_cal.get("KindTournament"))), "e no eixo do pool de copa (tournament), ancorado no ends_at da competição — %s" % str(kindsSeen.keys()))

# ------------------------------------------------------------------ D

func _suiteAgendaHygiene(now : int):
	print("[suite] D: higiene da agenda embarcada — sem sobreposição do mesmo kind, todo kind com consumidor")
	var overlaps : PackedStringArray = _sameKindOverlaps(shippedCampaigns)
	_checkEq(overlaps.size(), 0, "nenhuma sobreposição do MESMO kind na agenda embarcada%s" % _joinGaps(overlaps))
	var implemented : Variant = _cal.get("ImplementedKinds")
	var known : Variant = _cal.get("Kinds")
	_check(not (implemented is Array and (implemented as Array).is_empty()), "ImplementedKinds é legível (é ele que recusa agenda que ninguém lê)")
	_checkEq(_sameKindOverlaps(_campaignsOf(_rawList(shippedCampaigns))).size(), 0, "a ida e volta pelo parser do produto mantém as janelas sem sobreposição")
	var orphans : String = ""
	var unknownKinds : String = ""
	var dupKeys : String = ""
	var seen : Dictionary = {}
	for item in shippedCampaigns:
		var camp : Dictionary = item
		var kind : String = str(camp.get("kind", ""))
		var key : String = str(camp.get("key", ""))
		if not _has(known, kind):
			unknownKinds += kind + " "
		elif not _has(implemented, kind):
			orphans += kind + " "
		if seen.has(key):
			dupKeys += key + " "
		seen[key] = true
	_checkEq(unknownKinds.length(), 0, "todo kind embarcado existe na agenda (%s)" % unknownKinds)
	_checkEq(orphans.length(), 0, "todo kind embarcado tem consumidor no servidor (%s)" % orphans)
	_checkEq(dupKeys.length(), 0, "toda key embarcada é única (a resolução por timestamp depende disso) (%s)" % dupKeys)
	var nextStart : int = int(_cal.call("NextStart", shippedCampaigns, now, ""))
	_check(nextStart > now, "a agenda tem promessa futura para o operador ver no /metrics (next_start_unix = %d)" % nextStart)
	for item in _futureWindowSeasons(shippedSeasons, now):
		var serving : Array = _servingCampaigns(shippedCampaigns, _markOf(item), _openingEndOf(item))
		var axes : Dictionary = {}
		for entry in serving:
			axes[str((entry as Dictionary).get("kind", ""))] = true
		_check(axes.size() >= 2, "%s: a abertura cobre mais de um eixo de ganho do settle (%s)" % [_seasonId(item), str(axes.keys())])

# ------------------------------------------------------------------ D2

func _suiteConsumerLanding(now : int):
	print("[suite] D2: o que a agenda promete no marco é o que o CONSUMIDOR paga")
	if _offline == null or _arena == null:
		return
	var neutral : float = float(_cal.get("DefaultMod"))
	# Hoje, na costura real: nenhum bônus do arquivo embarcado alcança o instante do
	# run. É a proteção de `_cuidado_com_a_suite` medida no consumidor, não no JSON.
	_checkNear(float(_offline.call("LiveOpsXpMods", now)), neutral, 0.000001, "o settle de XP recebe o neutro neste instante")
	_checkNear(float(_offline.call("LiveOpsChestMods", now)), neutral, 0.000001, "e o seam do baú também (SuiteSettleGolden intacta)")
	for item in _futureWindowSeasons(shippedSeasons, now):
		var id : String = _seasonId(item)
		var mark : int = _markOf(item)
		var atMark : Array = _cal.call("ActiveEntriesAt", shippedCampaigns, mark)
		if not _check(atMark.size() >= 1, "%s: há campanha no marco para conferir no consumidor" % id):
			continue
		for entry in atMark:
			var camp : Dictionary = entry
			var kind : String = str(camp.get("kind", ""))
			var key : String = str(camp.get("key", ""))
			var value : float = float(camp.get("value", 0.0))
			var applied : float = neutral
			if kind == str(_cal.get("KindDoubleXP")):
				applied = float(_offline.call("LiveOpsXpMods", mark))
			elif kind == str(_cal.get("KindChestBonus")):
				applied = float(_offline.call("LiveOpsChestMods", mark))
			elif kind == str(_cal.get("KindTournament")):
				applied = float(_arena.call("PrizePoolMod", mark))
			else:
				_check(false, "%s: kind %s não tem consumidor conhecido por este harness" % [key, kind])
				continue
			_checkNear(applied, value, 0.000001, "%s (%s): o consumidor do eixo paga no marco exatamente o value da fileira embarcada (%s)" % [key, kind, str(value)])
			_checkNear(applied, float(_cal.call("ValueAtKind", kind, mark, neutral)), 0.000001, "%s: o que o calendário resolve == o que o consumidor usa (uma fonte, um leitor)" % key)
	_checkNear(float(_offline.call("LiveOpsXpMods", now)), neutral, 0.000001, "e depois das leituras do marco o instante do run continua no neutro")

# ------------------------------------------------------------------ E

func _suiteNegativeControls(now : int):
	print("[suite] E: mutações do arquivo embarcado são acusadas (a régua morde)")
	var upcoming : Array = _futureWindowSeasons(shippedSeasons, now)
	if upcoming.is_empty():
		return
	var season : Dictionary = upcoming[0]
	var id : String = _seasonId(season)
	var mark : int = _markOf(season)
	var openingEnd : int = _openingEndOf(season)
	var seasonEnd : int = int(season.get("end_unix", 0))
	var serving : Array = _servingCampaigns(shippedCampaigns, mark, openingEnd)
	if not _check(not serving.is_empty(), "existe positivo para ser mutado (%s tem %d campanhas de abertura)" % [id, serving.size()]):
		return
	# (1) campanha de abertura jogada para DEPOIS do fim da temporada. O arquivo
	# continua perfeitamente válido — a acusação tem que vir do alinhamento, não da
	# sintaxe, e é por isso que o controle afirma a validação antes da régua.
	var late : Array = _rawList(shippedCampaigns)
	for entry in late:
		var camp : Dictionary = entry
		if _servesAnyUpcoming(camp, upcoming):
			camp["start_unix"] = seasonEnd + DaySeconds
			camp["end_unix"] = int(camp["start_unix"]) + 3 * DaySeconds
	var lateCampaigns : Array = _campaignsOf(late)
	_checkEq(_cal.call("ValidateCalendar", _rawEvents(late)).size(), 0, "controle (1): a mutação é um arquivo VÁLIDO — a acusação não pode vir da sintaxe")
	var lateGaps : PackedStringArray = _openingGaps(season, lateCampaigns, now)
	_check(lateGaps.size() > 0, "mover a campanha de abertura para depois do fim da temporada é ACUSADO%s" % _joinGaps(lateGaps))
	_checkHas(lateGaps, id, "e a acusação nomeia a temporada descoberta (%s)" % id)
	_check((_cal.call("ActiveAtFrom", lateCampaigns, str(_cal.get("KindDoubleXP")), mark) as Dictionary).is_empty(),
		"pelo resolvedor do produto, a temporada mutada abre o eixo de XP no neutro")
	_checkEq(_servingCampaigns(lateCampaigns, mark, openingEnd).size(), 0, "e a interseção com a abertura fica literalmente zero segundos")
	# (2) calendário reduzido às linhas que não servem abertura nenhuma — é o
	# arquivo EXATAMENTE como estava antes das linhas novas, o estado que motivou
	# esta régua. A régua acusa.
	var shrunk : Array = []
	for entry in _rawList(shippedCampaigns):
		if not _servesAnyUpcoming((entry as Dictionary), upcoming):
			shrunk.append(entry)
	_check(shrunk.size() < shippedCampaigns.size(), "%d linhas sobram depois de tirar as que servem a abertura (de %d)" % [shrunk.size(), shippedCampaigns.size()])
	var shrunkCampaigns : Array = _campaignsOf(shrunk)
	_checkEq(_cal.call("ValidateCalendar", _rawEvents(shrunk)).size(), 0, "controle (2): o calendário sem campanhas de abertura continua válido como arquivo (o buraco dele nunca foi sintaxe)")
	var shrunkGaps : PackedStringArray = _openingGaps(season, shrunkCampaigns, now)
	_check(shrunkGaps.size() > 0, "tirar as campanhas de abertura é ACUSADO%s" % _joinGaps(shrunkGaps))
	_checkHas(shrunkGaps, "nenhuma campanha", "e a mensagem diz que a abertura está vazia (%s)" % id)
	_checkHas(shrunkGaps, "NENHUM kind no ar", "e que o marco em si abre sem nada no ar")
	_checkNear(float(_cal.call("ValueAtFrom", shrunkCampaigns, str(_cal.get("KindDoubleXP")), mark, float(_cal.get("DefaultMod")))), float(_cal.get("DefaultMod")), 0.000001, "com as campanhas removidas o XP resolve o neutro no marco (nada fica no ar por sobra)")
	# (3) value acima do teto: aqui quem recusa é o VALIDADOR DO PRODUTO, e o
	# caminho inteiro cai no fail-closed (Entries() vazio → consumidor no neutro).
	var ceiling : float = float(_cal.get("MaxBonusValue"))
	var over : Array = _rawList(shippedCampaigns)
	(over[0] as Dictionary)["value"] = ceiling + 1.0
	var overRaw : String = _rawEvents(over)
	var overErrors : PackedStringArray = _cal.call("ValidateCalendar", overRaw)
	_checkEq(overErrors.size(), 1, "value %s (teto %s + 1) é recusado pelo validador do produto" % [str(ceiling + 1.0), str(ceiling)])
	_checkHas(overErrors, "fora de", "e o erro nomeia a banda violada")
	_cal.call("SetRawForTests", overRaw)
	_checkEq(_cal.call("Entries").size(), 0, "com o value recusado NADA entra no ar (fail-closed, não 'o valor esquisito mesmo assim')")
	_checkNear(float(_cal.call("ValueAtKind", str(_cal.get("KindDoubleXP")), mark, float(_cal.get("DefaultMod")))), float(_cal.get("DefaultMod")), 0.000001, "e o consumidor do settle recebe o neutro com a agenda recusada")
	_cal.call("ClearRawForTests")
	# (4) duas janelas do MESMO kind sobrepostas. Duas metades honestas: o produto
	# não trata isso como erro de arquivo (a regra dele é não compor), então a
	# RÉGUA DE HIGIENE deste harness acusa o par, e o RESOLVEDOR recusa a
	# composição — nunca ×2 sobre ×3.
	var overlapList : Array = _rawList(shippedCampaigns)
	var first : Dictionary = overlapList[0]
	var twin : Dictionary = first.duplicate(true)
	twin["key"] = "xp_double_sobreposta_controle"
	twin["start_unix"] = int(first["start_unix"]) + DaySeconds
	twin["end_unix"] = int(first["end_unix"]) + DaySeconds
	twin["value"] = 3.0
	overlapList.append(twin)
	var overlapCampaigns : Array = _campaignsOf(overlapList)
	_checkEq(_cal.call("ValidateCalendar", _rawEvents(overlapList)).size(), 0, "controle (4): sobreposição do mesmo kind não é erro de arquivo (a regra do produto é não compor)")
	var overlapGaps : PackedStringArray = _sameKindOverlaps(overlapCampaigns)
	_check(overlapGaps.size() > 0, "a régua de higiene ACUSA o par sobreposto do mesmo kind%s" % _joinGaps(overlapGaps))
	# Um instante dentro da interseção das duas janelas: só assim "vence uma" é
	# medida e não uma coincidência de janelas encadeadas.
	var inside : int = maxi(int(first["start_unix"]), int(twin["start_unix"])) + HourSeconds
	_check(_servesOpening(first, inside, inside + 1), "o instante %d está dentro da janela original de double_xp" % inside)
	_check(_servesOpening(twin, inside, inside + 1), "e também dentro da janela sobreposta (a interseção é de verdade)")
	var winners : Array = _cal.call("ActiveEntriesAt", overlapCampaigns, inside)
	var xpCount : int = 0
	for item in winners:
		if str((item as Dictionary).get("kind", "")) == str(_cal.get("KindDoubleXP")):
			xpCount += 1
	_checkEq(xpCount, 1, "no cruzamento das duas janelas de double_xp exatamente UMA vence (nenhum kind paga duas vezes)")
	var resolved : float = float(_cal.call("ValueAtFrom", overlapCampaigns, str(_cal.get("KindDoubleXP")), inside, float(_cal.get("DefaultMod"))))
	_checkNear(resolved, 3.0, 0.000001, "e a vencedora é a que começa depois (x3), não a que veio antes")
	_check(absf(resolved - 6.0) > 0.000001, "duas janelas de double_xp cruzadas NUNCA pagam x2 sobre x3 (o produto proíbe compor)")
	# (5) cauda de campanha antiga terminando dentro da abertura: janela válida,
	# intercepta a abertura, e ainda assim é recusada pela exigência de nascimento.
	var stale : Array = _rawList(shippedCampaigns)
	var staleRow : Dictionary = stale[0]
	staleRow["start_unix"] = mark - 30 * DaySeconds
	staleRow["end_unix"] = mark + DaySeconds
	var staleCampaigns : Array = _campaignsOf(stale)
	_checkEq(_cal.call("ValidateCalendar", _rawEvents(stale)).size(), 0, "controle (5): a mutação também é um arquivo válido")
	_check(not _servingCampaigns(staleCampaigns, mark, openingEnd).is_empty(), "e a janela antiga de fato intercepta a abertura (por isso a exigência de nascimento importa)")
	var staleGaps : PackedStringArray = _openingGaps(season, staleCampaigns, now)
	_check(staleGaps.size() > 0, "nascimento 30 dias antes do marco é ACUSADO como cauda, não como lançamento%s" % _joinGaps(staleGaps))
	_checkHas(staleGaps, "cauda", "e a mensagem diz por que (uma janela que expirou em cima da data não é agenda)")
	# (6) value de pool fora da banda do CONSUMIDOR: o arquivo aceita (é assim por
	# construção no produto — um typo de prêmio não derruba a agenda inteira),
	# `SanitizePoolMod` devolve o neutro.
	var poolBand : Array = _bandOf(str(_cal.get("KindTournament")))
	_checkEq(poolBand.size(), 2, "tournament tem banda de consumidor lida do fonte")
	if poolBand.size() == 2:
		var bogus : float = float(poolBand[1]) + 5.0
		_checkNear(float(_cal.call("SanitizePoolMod", bogus)), float(_cal.get("DefaultMod")), 0.000001, "prêmio de copa com value %s fora de %s..%s vira o neutro no consumidor" % [str(bogus), str(poolBand[0]), str(poolBand[1])])
		var shippedPool : float = float(_cal.get("DefaultMod"))
		for entry in serving:
			if str((entry as Dictionary).get("kind", "")) == str(_cal.get("KindTournament")):
				shippedPool = float((entry as Dictionary).get("value", 1.0))
		_checkNear(float(_cal.call("SanitizePoolMod", shippedPool)), shippedPool, 0.000001, "e o value de copa embarcado passa como está (a banda não morde o que é legítimo)")
	# (7) temporada futura com agenda VAZIA: a régua acusa. É o que prova que o
	# predicado de cobertura não é always-true.
	var emptyGaps : PackedStringArray = _openingGaps(season, [], now)
	_check(emptyGaps.size() > 0, "agenda vazia é acusada (o predicado não é always-true)%s" % _joinGaps(emptyGaps))
	# (8) ida e volta pelo parser do produto: o arquivo real continua válido e
	# coberto, então as acusações acima vêm do que mudou, não da serialização.
	var roundTrip : Array = _campaignsOf(_rawList(shippedCampaigns))
	_checkEq(_cal.call("ValidateCalendar", _rawEvents(_rawList(roundTrip))).size(), 0, "controle: o arquivo real ida e volta pelo parser continua válido")
	var roundTripGaps : PackedStringArray = _openingGaps(season, roundTrip, now)
	_checkEq(roundTripGaps.size(), 0, "e ida e volta continua com a abertura coberta%s" % _joinGaps(roundTripGaps))

# ------------------------------------------------------------------ F

func _suiteReverted(now : int):
	print("[suite] F: nenhuma mutação tocou o disco e o estado embarcado volta limpo")
	_cal.call("ClearRawForTests")
	_cfg.call("ClearRawForTests")
	_checkEq(_cal.call("Errors").size(), 0, "LiveOpsCalendar.Errors() volta a zero depois das injeções em memória")
	var reread : PackedStringArray = _cal.call("ValidateCalendarFile")
	_checkEq(reread.size(), 0, "o arquivo do repo volta a validar limpo lido do caminho do produto")
	_checkEq(_cfg.call("Errors").size(), 0, "SeasonConfig.Errors() continua zero (nenhuma injeção de temporadas existiu)")
	_check(str(_cal.call("CurrentRaw")) == shippedRaw, "o raw relido depois das injeções é byte a byte o mesmo do início do run (injected desligado, disco intocado)")
	var campaigns : Array = _cal.call("Entries")
	_checkEq(campaigns.size(), shippedCampaigns.size(), "as %d campanhas embarcadas estão todas lá depois do fail-closed exercitado" % shippedCampaigns.size())
	_checkEq(_cfg.call("Entries").size(), shippedSeasons.size(), "as %d temporadas embarcadas continuam todas lá" % shippedSeasons.size())
	_checkEq(_sameKindOverlaps(campaigns).size(), 0, "a relida limpa não tem sobreposição do mesmo kind")
	var upcoming : Array = _futureWindowSeasons(shippedSeasons, now)
	var still : int = 0
	for item in upcoming:
		if _openingGaps(item, campaigns, now).is_empty():
			still += 1
	_checkEq(still, upcoming.size(), "e a abertura de cada temporada futura continua coberta pela agenda REAL do disco (%d/%d)" % [still, upcoming.size()])
	_check(FileAccess.file_exists(CalendarResPath) and FileAccess.file_exists(SeasonsResPath), "os dois arquivos continuam existindo no caminho res:// — nenhuma mutação foi persistida")
