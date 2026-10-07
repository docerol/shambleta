extends RefCounted
class_name LiveOpsCalendar

# OPS-3 (AUDITORIA_2026-09-27 §15 — Live Ops 5/10): a agenda de eventos era
# código. `CommunityService.EnsureCalendarLiveEvents()` DERIVA as janelas do
# relógio UTC (fim de semana ×2 drop, semana do ferreiro −50% na taxa) e não há
# como um operador dizer "copa de 3 a 10 de novembro, ×1.5 de baú": os dois
# únicos kinds que existem nascem do algoritmo, com os números em
# `EconomyCatalog`. Este módulo é a metade que falta — o calendário DECLARATIVO
# em `data/conf/liveops_calendar.json`, resolvido por timestamp.
#
# Uma linha por evento:
#   {"kind": "double_xp"|"chest_bonus"|"tournament", "key": "xp_double_s1_abertura",
#    "start_unix": 1790000000, "end_unix": 1790600000, "value": 2.0}
#
# Não é a mesma coisa que a tabela `live_event`: aquela é o ESTADO ativado por
# job (`TickLiveEvents` escreve `live_event_tick`, e a leitura exige o tick), esta
# é a PROMESSA do calendário, resolvida no instante da consulta, sem banco, sem
# job e sem escrita. Os dois eixos se compõem (o `drops_mod` do banco continua
# valendo o que vale), e a razão de não fundir já está documentada em
# `CommunityService`: quem CONSOME modificador de banco precisa do tick como
# prova de ativação. Um arquivo lido por timestamp não precisa de prova nenhuma.
#
# Consolidação — os três kinds têm consumidor, e cada um paga num eixo diferente:
#   * `double_xp`   → `OfflineSettle.LiveOpsXpMods` (mesmo eixo de `mods` do VIP
#     1.2×, do buff de guild e do `drops_mod` — multiplica XP, ouro e chaves do
#     settle; NÃO dobra baús, que têm budget próprio, nem o ×2 do tier 2, que é
#     `adMult`);
#   * `chest_bonus` → `OfflineSettle.LiveOpsChestMods`, na LINHA DO COFRE do
#     settle (`_ApplyFormula`, logo acima do teto diário). O teto
#     (`EconomyCatalog.ChestsPerDayFromSettle`) NÃO se move: a campanha entrega o
#     mesmo dia mais cedo, não mais baús por dia — sem essa restrição a agenda
#     seria faucet novo, que é exatamente o que o cabeçalho antigo temia;
#   * `tournament`  → `TournamentArenaService.PrizePoolMod`, no pool de prêmios
#     CONGELADO da copa (`tournament.prizes_json`, liquidado em gems no
#     `SettleTournament`). O instante ancorado é o `ends_at` da copa, não o da
#     liquidação: a campanha que cobriu a competição é a que paga, e um job que
#     liquida atrasado não pode reescrever o prêmio.
#
# Kind declarado sem consumidor é recusado na validação (`ImplementedKinds` +
# `ConsumerOf`), não "aceito e fica esperando o dono": um evento que resolve e
# ninguém lê é o defeito que a medição de Live Ops apontou (2 dos 3 kinds não
# alcançavam ninguém, o arquivo continuava parseando limpo e o operador via a
# linha no JSON como se fosse promessa cumprida). A régua é a mesma de
# `SeasonConfig.Validate`: o arquivo só entra no ar se tudo que ele declara
# existe de verdade.
#
# Fail-closed e no sentido seguro: `value` de bônus nunca compõe (duas janelas do
# mesmo kind sobrepostas = UMA vencedora, determinística; senão ×2 sobre ×2 paga
# ×4 no meio de um erro de digitação). Arquivo ausente ou inválido = nenhum evento
# no ar, `ValueAtKind` devolve o neutro 1.0 e o erro vai no log uma vez por
# conteúdo. Nota de teste: nenhuma janela deste arquivo pode cobrir o instante em
# que `SuiteSettleGolden` roda — a expectativa dela é calculada com `mods` = 1.0
# (IdleTests.gd:238), então um `double_xp` ativo na hora do run deixava a suíte
# vermelha por agenda, não por bug.

const CalendarPath : String			= "res://data/conf/liveops_calendar.json"
const CalendarFileEnv : String		= "SHAMBLETA_LIVEOPS_FILE"

const KindDoubleXP : String			= "double_xp"
const KindChestBonus : String		= "chest_bonus"
const KindTournament : String		= "tournament"
# Alias by-name do `double_xp`. O contrato de consumidor é mecânico — cada kind
# implementado é procurado no arquivo do leitor pelo nome `Kind<CamelCase do
# kind>` (`double_xp` → `KindDoubleXp`), e `double_xp` é o único dos três cujo
# nome histórico foge dessa forma (sigla em maiúsculo). Os dois constantes
# resolvem o MESMO kind; `OfflineSettle.LiveOpsXpMods` exige a igualdade em
# runtime, então um alias que divergir do kind validado desliga o bônus em vez
# de ler um nome que a agenda não conhece.
const KindDoubleXp : String			= KindDoubleXP
const Kinds : Array[String] = [KindDoubleXP, KindChestBonus, KindTournament]

# DOS TRÊS acima, os que têm consumidor de verdade no servidor. Um kind que entra
# em `Kinds` sem entrar aqui faz o arquivo INTEIRO ser rejeitado na validação: é
# o fail-closed do `SeasonConfig.Validate` aplicado à agenda, e a razão é a
# medição, não o gosto — o `ValidateCalendar` velho aceitava qualquer kind da
# lista, então "declarei e não liguei" era indistinguível de "declarei e está no
# ar". Quem descobre a diferença é o `tests/ops_fix_test.gd` (suíte F), que lê o
# fonte do consumidor e amarra o kind à chamada real.
const ImplementedKinds : Array[String] = [KindDoubleXP, KindChestBonus, KindTournament]

# Onde cada kind implementado é consumido. Não é comentário: é o texto que sai em
# `/metrics` e no erro de validação, então mentir aqui é detectável por scrape.
const Consumers : Dictionary[String, String] = {
	KindDoubleXP: "OfflineSettle.LiveOpsXpMods (faucet XP/ouro/chaves do settle)",
	KindChestBonus: "OfflineSettle.LiveOpsChestMods (linha do cofre em _ApplyFormula, sob o teto diario)",
	KindTournament: "TournamentArenaService.PrizePoolMod (pool de prêmios em gems da copa)",
}

# Kinds que são MULTIPLICADOR de ganho: abaixo de 1.0 um "bônus" seria nerf
# silencioso, acima do teto é dedo no teclado (20 em vez de 2.0) pagando faucet
# em produção.
const BonusKinds : Array[String] = [KindDoubleXP, KindChestBonus]
const MinBonusValue : float = 1.0
const MaxBonusValue : float = 4.0
# `tournament` NÃO está em `BonusKinds` de propósito: a faixa dele não é cheque no
# arquivo (um `value` fora da banda num kind de pool derrubaria a agenda inteira
# por um typo de prêmio), é recusa no CONSUMIDOR — `SanitizePoolMod` devolve o
# neutro e reclama uma vez. É o mesmo parâmetro 1.0..4.0 dos bônus, só aplicado
# onde o dano acontece.
const PoolKinds : Array[String] = [KindTournament]
const MinPoolMod : float = 1.0
const MaxPoolMod : float = 4.0

const DefaultMod : float = 1.0
# Mesmo TTL do `SeasonConfig`: o leitor é o settle (um clique por coleta), não o
# frame de render.
const CacheTTLmsec : int = 60 * 1000

const EntryKeys : Array[String] = ["kind", "key", "start_unix", "end_unix", "value", "label"]

static var cacheEntries : Array = []
static var cacheErrors : PackedStringArray = PackedStringArray()
static var cacheStamp : int = -1
static var reported : bool = false
static var injectedRaw : String = ""
static var injected : bool = false

# ------------------------------------------------------------------ carga

static func Reload() -> void:
	cacheStamp = -1

static func SetRawForTests(raw : String) -> void:
	injectedRaw = raw
	injected = true
	Reload()

static func ClearRawForTests() -> void:
	injectedRaw = ""
	injected = false
	Reload()

static func FilePath() -> String:
	var pointed : String = OS.get_environment(CalendarFileEnv).strip_edges()
	return pointed if not pointed.is_empty() else CalendarPath

static func CurrentRaw() -> String:
	if injected:
		return injectedRaw
	var path : String = FilePath()
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)

static func EnsureLoaded() -> void:
	var stamp : int = Time.get_ticks_msec()
	if cacheStamp >= 0 and stamp - cacheStamp < CacheTTLmsec:
		return
	cacheStamp = stamp
	var raw : String = CurrentRaw()
	cacheErrors = ValidateCalendar(raw)
	cacheEntries = [] if not cacheErrors.is_empty() else ParseEntries(raw)
	if not cacheErrors.is_empty() and not reported:
		reported = true
		for e : String in cacheErrors:
			push_error("liveops_calendar.json: %s" % e)
	elif cacheErrors.is_empty():
		reported = false

static func Entries() -> Array:
	EnsureLoaded()
	return cacheEntries

static func Errors() -> PackedStringArray:
	EnsureLoaded()
	return cacheErrors

static func IsValid() -> bool:
	return Errors().is_empty()

# ------------------------------------------------------------------ validação

static func ValidateCalendarFile() -> PackedStringArray:
	return ValidateCalendar(CurrentRaw())

static func ValidateCalendar(raw : String) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	if raw.strip_edges().is_empty():
		errors.append("%s ausente ou vazio — sem agenda nada entra no ar (o multiplicador fica no neutro %s)" % [CalendarPath, str(DefaultMod)])
		return errors
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("não é um objeto JSON")
		return errors
	var list : Variant = (parsed as Dictionary).get("events")
	if typeof(list) != TYPE_ARRAY:
		errors.append("\"events\" ausente ou não é uma lista")
		return errors
	var seen : Dictionary = {}
	var idx : int = 0
	for item in (list as Array):
		idx += 1
		if typeof(item) != TYPE_DICTIONARY:
			errors.append("events[%d]: não é um objeto" % idx)
			continue
		_ValidateEntry(item, idx, seen, errors)
	return errors

static func _ValidateEntry(entry : Dictionary, idx : int, seen : Dictionary, errors : PackedStringArray) -> void:
	for key in entry.keys():
		var k : String = str(key)
		if not k.begins_with("_") and not EntryKeys.has(k):
			errors.append("events[%d]: chave desconhecida \"%s\"" % [idx, k])
	var kind : String = str(entry.get("kind", ""))
	if not Kinds.has(kind):
		# O caso mais geral de "declarado sem consumidor": um kind que não existe
		# na agenda tem, por definição, leitor nenhum. A mensagem diz as duas
		# pontas (o typo e a lista implementada) porque é ela que o operador lê no
		# log quando o arquivo INTEIRO sai do ar.
		errors.append("events[%d]: kind \"%s\" não existe (só %s) e está declarado sem consumidor no servidor — implemented: %s; um typo aqui é um evento que nunca dispara" % [idx, kind, _JoinKinds(), _JoinList(ImplementedKinds)])
	elif not ImplementedKinds.has(kind):
		errors.append("events[%d]: kind \"%s\" declarado mas sem consumidor no servidor (implemented: %s) — agenda que ninguém lê é promessa falsa" % [idx, kind, _JoinList(ImplementedKinds)])
	var eventKey : String = str(entry.get("key", ""))
	if eventKey.is_empty() or not _IsKey(eventKey):
		errors.append("events[%d]: \"key\" ausente ou fora do padrão [a-z][a-z0-9_]*" % idx)
	elif seen.has(eventKey):
		errors.append("events[%d]: \"key\" \"%s\" duplicada" % [idx, eventKey])
	else:
		seen[eventKey] = idx
	for field : String in ["start_unix", "end_unix"]:
		if not entry.has(field):
			errors.append("events[%d/%s]: \"%s\" ausente — evento sem janela não tem quando dispara" % [idx, eventKey, field])
		elif not _IsInteger(entry[field]):
			errors.append("events[%d/%s]: \"%s\" não é inteiro" % [idx, eventKey, field])
	var startsAt : int = _IntOf(entry, "start_unix", -1)
	var endsAt : int = _IntOf(entry, "end_unix", -1)
	if startsAt >= 0 and endsAt >= 0 and endsAt <= startsAt:
		errors.append("events[%d/%s]: end_unix (%d) <= start_unix (%d) — janela vazia" % [idx, eventKey, endsAt, startsAt])
	if not entry.has("value"):
		errors.append("events[%d/%s]: \"value\" ausente" % [idx, eventKey])
	elif not (entry["value"] is float or entry["value"] is int):
		errors.append("events[%d/%s]: \"value\" não é número" % [idx, eventKey])
	elif BonusKinds.has(kind):
		var value : float = float(entry["value"])
		if value < MinBonusValue or value > MaxBonusValue:
			errors.append("events[%d/%s]: value %s fora de %s..%s para o kind %s (bônus abaixo de 1.0 é nerf disfarçado, acima do teto é faucet)" % [idx, eventKey, str(value), str(MinBonusValue), str(MaxBonusValue), kind])

# ------------------------------------------------------------------ parsing

static func ParseEntries(raw : String) -> Array:
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var list : Variant = (parsed as Dictionary).get("events")
	if typeof(list) != TYPE_ARRAY:
		return []
	var out : Array = []
	var idx : int = 0
	for item in (list as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		idx += 1
		var entry : Dictionary = (item as Dictionary).duplicate(true)
		entry["kind"] = str(entry.get("kind", ""))
		entry["key"] = str(entry.get("key", ""))
		entry["start_unix"] = _IntOf(entry, "start_unix", 0)
		entry["end_unix"] = _IntOf(entry, "end_unix", 0)
		entry["value"] = float(entry.get("value", DefaultMod))
		entry["label"] = str(entry.get("label", entry["key"]))
		entry["_idx"] = idx
		out.append(entry)
	return out

# ------------------------------------------------------------------ resolução (pura)

# Uma entrada vale em `ts` se `start_unix <= ts < end_unix` — o fim é exclusivo,
# então duas janelas encadeadas (a última hora de uma e a primeira da outra)nunca
# se sobrepõem e não há segundo perdido.
static func _Covers(entry : Dictionary, ts : int) -> bool:
	return int(entry.get("start_unix", 0)) <= ts and ts < int(entry.get("end_unix", 0))

static func ActiveEntriesAt(entries : Array, ts : int) -> Array:
	var byKind : Dictionary = {}
	for item in entries:
		var entry : Dictionary = item
		if not entry.has("_idx") or not _Covers(entry, ts):
			continue
		var kind : String = str(entry.get("kind", ""))
		if not Kinds.has(kind):
			continue
		var current : Dictionary = byKind.get(kind, {})
		if current.is_empty() or _Beats(entry, current):
			byKind[kind] = entry
	var out : Array = []
	for kind in byKind.keys():
		out.append((byKind[kind] as Dictionary).duplicate(true))
	out.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return str(a["kind"]) < str(b["kind"]))
	return out

# Determinismo de sobreposição, na ordem: começa depois → termina depois → veio
# depois no arquivo. É "a autoria mais recente manda", e NÃO é composição: duas
# janelas de `double_xp` cruzadas pagam uma ×2, nunca ×4.
static func _Beats(a : Dictionary, b : Dictionary) -> bool:
	if int(a["start_unix"]) != int(b["start_unix"]):
		return int(a["start_unix"]) > int(b["start_unix"])
	if int(a["end_unix"]) != int(b["end_unix"]):
		return int(a["end_unix"]) > int(b["end_unix"])
	return int(a["_idx"]) > int(b["_idx"])

static func ActiveAtFrom(entries : Array, kind : String, ts : int) -> Dictionary:
	if not Kinds.has(kind):
		return {}
	var best : Dictionary = {}
	for item in entries:
		var entry : Dictionary = item
		if not entry.has("_idx") or str(entry.get("kind", "")) != kind:
			continue
		if _Covers(entry, ts) and (best.is_empty() or _Beats(entry, best)):
			best = entry
	return best.duplicate(true) if not best.is_empty() else {}

static func ValueAtFrom(entries : Array, kind : String, ts : int, fallback : float) -> float:
	var active : Dictionary = ActiveAtFrom(entries, kind, ts)
	if active.is_empty():
		return fallback
	return float(active.get("value", fallback))

static func ActiveAt(kind : String, ts : int) -> Dictionary:
	return ActiveAtFrom(Entries(), kind, ts)

# Q-7 (2026-10-07): o pino do harness. A régua dourada liquida no tempo real e o
# calendário entra no faucet por ESTA porta; enquanto a única defesa era "nenhuma
# janela pode cobrir o dia do run" (a nota `_cuidado_com_a_suite` do JSON), a agenda
# ficava proibida de existir no futuro próximo — live ops que só pode viver em data
# distante é o Achado #98 de outra roupa. O pino fecha os DOIS eixos de bônus
# (`double_xp`, `chest_bonus`) no neutro para o harness que AFERE a economia do
# settle (`run_idle_tests`, `balance_test`); o eixo `tournament` fica de fora de
# propósito: a âncora dele é o `ends_at` congelado na criação da copa, ele pode
# ficar permanentemente no ar pela regra do próprio arquivo, e as suítes de copa
# contam com isso. Quem TESTA o calendário (`season_liveops_test`, `doc_facts_test`)
# não pinna nada.
static var PinnedNeutral : bool = false

static func PinNeutral(pinned : bool) -> void:
	PinnedNeutral = pinned

# O consultado pelo gameplay. Arquivo inválido → `Entries()` vazio → neutro: o
# fail-closed aqui é "nenhum bônus não validado entra no ar", que é o sentido
# seguro de um multiplicador de faucet.
static func ValueAtKind(kind : String, ts : int, fallback : float = DefaultMod) -> float:
	if PinnedNeutral and not PoolKinds.has(kind):
		return fallback
	return ValueAtFrom(Entries(), kind, ts, fallback)

static func IsKindActive(kind : String, ts : int) -> bool:
	return not ActiveAt(kind, ts).is_empty()

# A campanha que está no ar para um kind, ou "" quando nenhuma. É o que sai como
# comentário `# campaign` no /metrics: um `shambleta_liveops_mod_chest_bonus 1.5`
# nu não diz qual campanha o operator ligou, e "qual evento está no ar agora" é a
# pergunta que se faz às 3h.
static func ActiveKeyAt(kind : String, ts : int) -> String:
	return str(ActiveAt(kind, ts).get("key", ""))

# ------------------------------------------------------------------ banda do consumidor

# O modificador que um CONSUMIDOR de pool (prêmio de copa) pode usar. Fora da
# banda é neutro + uma reclamação no log: o `value` de um kind de pool não é
# cheque no arquivo (ver `PoolKinds`), e o sentido seguro de um multiplicador de
# faucet é devolver 1.0 — nunca "o valor esquisito mesmo assim".
static var poolModWarned : Dictionary = {}

static func SanitizePoolMod(value : float) -> float:
	if not is_finite(value) or value < MinPoolMod or value > MaxPoolMod:
		var mark : String = str(value)
		if not poolModWarned.has(mark):
			poolModWarned[mark] = true
			push_warning("liveops_calendar: value de pool %s fora de %s..%s — aplicado o neutro %s (prêmio de copa não pode ser reescado por typo)" % [mark, str(MinPoolMod), str(MaxPoolMod), str(DefaultMod)])
		return DefaultMod
	return value

# O modificador de um kind de bônus/pool já resolvido pela faixa dele. É a única
# porta que os consumidores novos usam: `double_xp` continua no `ValueAtKind`
# direto (faixa chequeada no arquivo) e os dois novos passam por aqui.
static func BonusMod(kind : String, ts : int) -> float:
	if not Kinds.has(kind):
		return DefaultMod
	var value : float = ValueAtKind(kind, ts, DefaultMod)
	if PoolKinds.has(kind):
		return SanitizePoolMod(value)
	return value

# ------------------------------------------------------------------ /metrics

# O lado servido da agenda. Live ops que só existe em JSON e nunca é raspado por
# ninguém é igual a não existir: quem opera precisa ver no mesmo scrape do
# `shambleta_up` qual campanha está no ar, com que multiplicador e quando assume
# a próxima. Mesmo formato de `TelemetryService.FunnelGaugeLines` (HELP/TYPE/
# gauge, valor nu sem rótulo — o scrape do deploy não tem parser de label), e as
# linhas `shambleta_*` continuam de fora da regex de nomes do
# `tests/deploy_ops_test.gd`, que lê o corpo de `MetricsServer.gd`.
static func GaugeLines(ts : int) -> String:
	var lines : String = ""
	var valid : bool = IsValid()
	lines += "# HELP shambleta_liveops_calendar_valid 1 quando a agenda declarada parseia limpa; 0 = nada no ar (fail-closed).\n"
	lines += "# TYPE shambleta_liveops_calendar_valid gauge\n"
	lines += "shambleta_liveops_calendar_valid %d\n" % (1 if valid else 0)
	if not valid:
		lines += "# liveops_disabled: agenda com %d erro(s); todo multiplicador abaixo fica no neutro %s\n" % [cacheErrors.size(), str(DefaultMod)]
		return lines
	var active : int = 0
	for kind in ImplementedKinds:
		var key : String = ActiveKeyAt(kind, ts)
		var onAir : bool = not key.is_empty()
		if onAir:
			active += 1
		lines += "# HELP shambleta_liveops_active_%s 1 com a campanha deste kind no ar (%s).\n" % [kind, Consumers.get(kind, "?")]
		lines += "# TYPE shambleta_liveops_active_%s gauge\n" % kind
		lines += "shambleta_liveops_active_%s %d\n" % [kind, 1 if onAir else 0]
		lines += "# HELP shambleta_liveops_mod_%s multiplicador resolvido deste kind neste instante (neutro %s fora de janela).\n" % [kind, str(DefaultMod)]
		lines += "# TYPE shambleta_liveops_mod_%s gauge\n" % kind
		lines += "shambleta_liveops_mod_%s %s\n" % [kind, "%.4f" % BonusMod(kind, ts)]
		if onAir:
			lines += "# campaign kind=%s key=%s\n" % [kind, key]
	lines += "# HELP shambleta_liveops_events_active quantos kinds de campanha estão no ar neste instante.\n"
	lines += "# TYPE shambleta_liveops_events_active gauge\n"
	lines += "shambleta_liveops_events_active %d\n" % active
	var entries : Array = Entries()
	var nextStart : int = NextStart(entries, ts)
	lines += "# HELP shambleta_liveops_next_start_unix segunda do próximo evento agendado; 0 = agenda sem promessa futura.\n"
	lines += "# TYPE shambleta_liveops_next_start_unix gauge\n"
	lines += "shambleta_liveops_next_start_unix %d\n" % nextStart
	if nextStart > 0:
		lines += "# next_campaign kind=%s key=%s\n" % [_KindStartingAt(entries, ts, nextStart), str(_EntryStartingAt(entries, ts, nextStart).get("key", ""))]
	return lines

# A entrada que assume em `start` (o `NextStart` devolve a segunda, não a linha).
static func _EntryStartingAt(entries : Array, ts : int, start : int) -> Dictionary:
	for item in entries:
		var entry : Dictionary = item
		if int(entry.get("start_unix", 0)) == start and start > ts:
			return entry
	return {}

static func _KindStartingAt(entries : Array, ts : int, start : int) -> String:
	return str(_EntryStartingAt(entries, ts, start).get("kind", "none"))

# Janela mais próxima no futuro (0 = nada agendado) — o que o operador lê para
# saber quando o próximo evento assume.
static func NextStart(entries : Array, ts : int, kind : String = "") -> int:
	var next : int = 0
	for item in entries:
		var entry : Dictionary = item
		if not kind.is_empty() and str(entry.get("kind", "")) != kind:
			continue
		var startsAt : int = int(entry.get("start_unix", 0))
		if startsAt > ts and (next == 0 or startsAt < next):
			next = startsAt
	return next

# ------------------------------------------------------------------ helpers

static func _JoinKinds() -> String:
	return _JoinList(Kinds)

static func _JoinList(values : Array[String]) -> String:
	var joined : String = ""
	for k in values:
		joined = str(k) if joined.is_empty() else "%s, %s" % [joined, str(k)]
	return joined

static func _IsKey(key : String) -> bool:
	if key.is_empty():
		return false
	var first : String = key[0]
	if not (first >= "a" and first <= "z"):
		return false
	for i in key.length():
		var c : String = key[i]
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true

static func _IsInteger(value : Variant) -> bool:
	if value is int:
		return true
	if not (value is float):
		return false
	return float(int(value)) == float(value)

static func _IntOf(dict : Dictionary, key : String, fallback : int) -> int:
	var value : Variant = dict.get(key, null)
	if value == null or not _IsInteger(value):
		return fallback
	return int(value)
