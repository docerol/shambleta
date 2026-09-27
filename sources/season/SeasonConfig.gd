extends RefCounted
class_name SeasonConfig

# OPS-2 (AUDITORIA_2026-09-27 §15 — Live Ops 5/10): "temporada nova = deploy" era
# o buraco. A S1 morava em três lugares de código: `SeasonService.EnsureSeasonS1()`
# (os 30 dias que o relógio abre), `EconomyCatalog.SeasonS1Rules()` (o JSON
# congelado na linha) e as trilhas do passe (`PASS_FREE`/`PASS_PREMIUM`/
# `PASS_MAX_LEVEL`). Abrir a S2 era PR. Este módulo move a decisão para
# `data/conf/seasons.json`: o arquivo diz QUEM está no ar, QUANDO e COM QUE
# PASSE; o código só sabe interpretar.
#
# Formato (uma linha por temporada, sem ordem implícita de grandeza):
#   {"seasons": [
#      {"id": "s1", "label": "S1", "start_unix": 0, "end_unix": 0,
#       "duration_days": 30, "theme": "...", "races": [...],
#       "rewards_ref": "gems+cosmetics, non-cashable", "premium_sku": "pass.s1",
#       "pass_tiers": {"max_level": 40, "bonus_start": 31, "bonus_gems": 20,
#                      "free": {"3": {"gems": 10}}, "premium": {...}}}
#   ]}
# `start_unix`/`end_unix` iguais em 0 = temporada de ROTAÇÃO: abre agora e dura
# `duration_days`. É o comportamento herdado do beta, congelado em teste
# (`SuiteSeasonBootstrap` exige 30 dias contados da abertura), e é assim que o
# arquivo nasce. Temporada com janela nominal estreita na hora marcada — ver
# `ShouldPreempt`, que congela a rolling antecipada.
#
# Entradas com janela VENCIDA continuam válidas e continuam no arquivo: é o
# histórico que resolve o passe de uma temporada encerrada
# (`EntryForSeasonRow`), e reescrever o passado para o placar de alguém não é
# opção. O que o validador exige é que exista ao menos uma linha capaz de abrir
# (uma de rotação, ou uma nominal ainda em janela) — senão o jogo subiu saudável
# e nunca mais teve temporada nenhuma.
#
# Fail-closed: arquivo ausente, JSON quebrado, `id` duplicado, trilha com nível
# acima do teto, SKU de passe que o catálogo cobrável não cobra — em qualquer um
# desses `Entries()` devolve vazio, `Errors()` devolve a lista e
# `SeasonService.EnsureSeason()` recusa abrir temporada (-1 + push_error).
# Recusar a ABERTURA e não o resto: fechar/liquidar uma temporada que já está no
# placar do jogador é pagar dívida, e negar isso por typo de operador seria o
# pior efeito colateral possível. `ValidateSeasons` é a mesma régua de
# `EconomyCatalog.ValidatePaidCatalog`: texto entra, lista de erros sai, sem disco,
# sem banco, sem rede. Quem a exercita é o relógio de temporada
# (`SeasonService.EnsureSeason`, no processo do jogo) e a suíte
# `tests/season_liveops_test.gd` — e a suíte não boota: nada nela depende de
# servidor, rede, mundo ou banco, só do parser, do relógio e do disco.

const SeasonsPath : String			= "res://data/conf/seasons.json"
# Espelho do `SHAMBLETA_CATALOG_FILE` do companion: onde o `.pck` é só leitura, é
# por aqui que o operator aponta o arquivo editado sem rebuild.
const SeasonsFileEnv : String		= "SHAMBLETA_SEASONS_FILE"

const DaySeconds : int				= 86400
const DefaultDurationDays : int		= 30
const ConfigIDKey : String			= "config_id"
# O consumidor é o relógio de temporada (5 min) e o claim do passe — nunca o
# frame de render. TTL curto o bastante para "editei o arquivo, o próximo tick já
# viu", longo o bastante para não reler JSON a cada claim.
const CacheTTLmsec : int			= 60 * 1000

const EntryKeys : Array[String] = ["id", "label", "start_unix", "end_unix", "duration_days",
	"theme", "races", "rewards_ref", "premium_sku", "pass_tiers"]
const PassTierKeys : Array[String] = ["max_level", "bonus_start", "bonus_gems", "free", "premium"]
const RewardKeys : Array[String] = ["gems", "chests", "vip_days", "cosmetics"]

static var cacheEntries : Array = []
static var cacheErrors : PackedStringArray = PackedStringArray()
static var cacheStamp : int = -1
static var reported : bool = false
# Seam de teste (mesma linhagem de `OfflineSettle.sqlOverride`): injeta o texto
# sem tocar em `data/conf/` — o arquivo do repo é compartilhado com as outras
# suítes e escrever nele mudaria o comportamento de quem roda em paralelo.
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
	var pointed : String = OS.get_environment(SeasonsFileEnv).strip_edges()
	return pointed if not pointed.is_empty() else SeasonsPath

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
	cacheErrors = ValidateSeasons(raw)
	cacheEntries = [] if not cacheErrors.is_empty() else ParseEntries(raw)
	# Reporta uma vez por conteúdo lido: o relógio chama a cada 5 min e um
	# push_error por passada é o log inútil — e o gate de SCRIPT ERROR não
	# distingue um erro novo do eco do mesmo.
	if not cacheErrors.is_empty() and not reported:
		reported = true
		for e : String in cacheErrors:
			push_error("seasons.json: %s" % e)
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

static func ValidateSeasonsFile() -> PackedStringArray:
	return ValidateSeasons(CurrentRaw())

static func ValidateSeasons(raw : String) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	if raw.strip_edges().is_empty():
		errors.append("%s ausente ou vazio — o servidor não tem de onde ler a temporada vigente" % SeasonsPath)
		return errors
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("não é um objeto JSON (%s)" % _FirstLine(raw))
		return errors
	var list : Variant = (parsed as Dictionary).get("seasons")
	if typeof(list) != TYPE_ARRAY:
		errors.append("\"seasons\" ausente ou não é uma lista — sem lista não há temporada que abra")
		return errors
	if (list as Array).is_empty():
		errors.append("\"seasons\" está vazia — precisa de ao menos uma entrada")
		return errors
	var seen : Dictionary = {}
	var idx : int = 0
	for item in (list as Array):
		idx += 1
		if typeof(item) != TYPE_DICTIONARY:
			errors.append("seasons[%d]: não é um objeto" % idx)
			continue
		_ValidateEntry(item, idx, seen, errors)
	_ValidateOpensomething((list as Array), errors)
	return errors

# Um typo que fecha toda janela do arquivo não erro de sintaxe nenhum: o JSON
# parseia, o servidor sobe, o relógio roda e o beta fica permanently sem
# temporada — sem placar, sem passe, sem `pass.s1` entregável. Esta é a única
# checagem de conteúdo global do arquivo e é ela que torna "editar o JSON" um
# passo de operação seguro.
static func _ValidateOpensomething(list : Array, errors : PackedStringArray) -> void:
	var now : int = _Now()
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry : Dictionary = item
		var startsAt : int = _IntOf(entry, "start_unix", 0)
		var endsAt : int = _IntOf(entry, "end_unix", 0)
		if startsAt <= 0 or endsAt <= startsAt:
			return		# entrada de rotação: sempre capaz de abrir
		if endsAt > now:
			return		# nominal ainda em janela (ou futura)
	errors.append("nenhuma temporada capaz de abrir: toda janela nominal venceu e não há entrada de rotação — o jogo ficaria sem temporada")

static func _ValidateEntry(entry : Dictionary, idx : int, seen : Dictionary, errors : PackedStringArray) -> void:
	var id : String = str(entry.get("id", ""))
	if id.is_empty() or not IsConfigID(id):
		errors.append("seasons[%d]: \"id\" ausente ou fora do padrão [a-z][a-z0-9_]*" % idx)
	elif seen.has(id):
		errors.append("seasons[%d]: \"id\" \"%s\" duplicado (a resolução por timestamp ficaria ambígua)" % [idx, id])
	else:
		seen[id] = idx
	# Chave desconhecida É erro: `start_unx` escrito errado não é "sem janela", é
	# uma temporada que nasce de rotação em silêncio — a mesma classe de bug que o
	# validador do catálogo pago fecha.
	for key in entry.keys():
		var k : String = str(key)
		if not k.begins_with("_") and not EntryKeys.has(k):
			errors.append("seasons[%d/%s]: chave desconhecida \"%s\"" % [idx, id, k])
	for field : String in ["start_unix", "end_unix", "duration_days"]:
		if entry.has(field) and not _IsInteger(entry[field]):
			errors.append("seasons[%d/%s]: \"%s\" não é número inteiro" % [idx, id, field])
	var startsAt : int = _IntOf(entry, "start_unix", 0)
	var endsAt : int = _IntOf(entry, "end_unix", 0)
	var durationGiven : bool = entry.has("duration_days")
	var duration : int = _IntOf(entry, "duration_days", DefaultDurationDays)
	if startsAt < 0 or endsAt < 0:
		errors.append("seasons[%d/%s]: timestamp negativo" % [idx, id])
	elif startsAt == 0 and endsAt == 0:
		if duration <= 0:
			errors.append("seasons[%d/%s]: temporada de rotação precisa de \"duration_days\" > 0" % [idx, id])
	elif startsAt > 0 and endsAt > startsAt:
		if durationGiven and duration * DaySeconds != endsAt - startsAt:
			errors.append("seasons[%d/%s]: janela nominal (%d s) != duration_days × 86400 (%d s)" % [idx, id, endsAt - startsAt, duration * DaySeconds])
	else:
		errors.append("seasons[%d/%s]: janela inválida (use 0/0 para rotação, ou 0 < start_unix < end_unix)" % [idx, id])
	if entry.has("races"):
		var races : Variant = entry["races"]
		if typeof(races) != TYPE_ARRAY:
			errors.append("seasons[%d/%s]: \"races\" não é lista" % [idx, id])
		else:
			for race in (races as Array):
				if not EconomyCatalog.SEASON_KINDS.has(str(race)):
					errors.append("seasons[%d/%s]: corrida \"%s\" não existe em EconomyCatalog.SEASON_KINDS" % [idx, id, str(race)])
	if entry.has("premium_sku") and not _SkuAdvertised(str(entry["premium_sku"])):
		errors.append("seasons[%d/%s]: \"premium_sku\" \"%s\" não está no SHOP_CATALOG cobrável (o botão do passe viraria unknown_sku)" % [idx, id, str(entry["premium_sku"])])
	if entry.has("pass_tiers"):
		_ValidatePassTiers(entry["pass_tiers"], idx, id, errors)

static func _ValidatePassTiers(tiers : Variant, idx : int, seasonID : String, errors : PackedStringArray) -> void:
	if typeof(tiers) != TYPE_DICTIONARY:
		errors.append("seasons[%d/%s]: \"pass_tiers\" não é objeto" % [idx, seasonID])
		return
	var tiersDict : Dictionary = tiers
	for key in tiersDict.keys():
		var k : String = str(key)
		if not k.begins_with("_") and not PassTierKeys.has(k):
			errors.append("seasons[%d/%s]: \"pass_tiers.%s\" desconhecido" % [idx, seasonID, k])
	var maxLevel : int = _IntOf(tiersDict, "max_level", EconomyCatalog.PASS_MAX_LEVEL)
	if maxLevel < 1 or maxLevel > EconomyCatalog.PASS_MAX_LEVEL:
		errors.append("seasons[%d/%s]: pass_tiers.max_level %d fora de 1..%d (a curva de PT do catálogo não alcança mais que isso)" % [idx, seasonID, maxLevel, EconomyCatalog.PASS_MAX_LEVEL])
	var bonusStart : int = _IntOf(tiersDict, "bonus_start", EconomyCatalog.PASS_BONUS_START)
	if bonusStart < 1 or bonusStart > maxLevel + 1:
		errors.append("seasons[%d/%s]: pass_tiers.bonus_start %d acima do max_level %d" % [idx, seasonID, bonusStart, maxLevel])
	for track : String in ["free", "premium"]:
		if not tiersDict.has(track):
			continue
		var table : Variant = tiersDict[track]
		if typeof(table) != TYPE_DICTIONARY:
			errors.append("seasons[%d/%s]: pass_tiers.%s não é objeto nível→recompensa" % [idx, seasonID, track])
			continue
		for levelKey in (table as Dictionary).keys():
			var lk : String = str(levelKey)
			if lk.begins_with("_"):
				continue
			var level : int = lk.to_int()
			if level < 1 or str(level) != lk or level > maxLevel:
				errors.append("seasons[%d/%s]: pass_tiers.%s nível \"%s\" fora de 1..%d" % [idx, seasonID, track, lk, maxLevel])
				continue
			_ValidateReward(table[levelKey], idx, seasonID, "%s nível %d" % [track, level], errors)

static func _ValidateReward(reward : Variant, idx : int, seasonID : String, label : String, errors : PackedStringArray) -> void:
	if typeof(reward) != TYPE_DICTIONARY:
		errors.append("seasons[%d/%s]: %s não é objeto" % [idx, seasonID, label])
		return
	var rewardDict : Dictionary = reward
	for key in rewardDict.keys():
		var k : String = str(key)
		if not k.begins_with("_") and not RewardKeys.has(k):
			errors.append("seasons[%d/%s]: %s tem campo \"%s\" que o aplicador do passe não conhece" % [idx, seasonID, label, k])
	for field : String in ["gems", "chests", "vip_days"]:
		if rewardDict.has(field) and (not _IsInteger(rewardDict[field]) or int(rewardDict[field]) < 0):
			errors.append("seasons[%d/%s]: %s.%s precisa ser inteiro >= 0" % [idx, seasonID, label, field])
	if not rewardDict.has("cosmetics"):
		return
	var cosmetics : Variant = rewardDict["cosmetics"]
	if typeof(cosmetics) != TYPE_ARRAY:
		errors.append("seasons[%d/%s]: %s.cosmetics não é lista" % [idx, seasonID, label])
		return
	for cid in (cosmetics as Array):
		if not EconomyCatalog.COSMETIC_CATALOG.has(str(cid)):
			errors.append("seasons[%d/%s]: %s cosmético \"%s\" fora do COSMETIC_CATALOG" % [idx, seasonID, label, str(cid)])

# ------------------------------------------------------------------ parsing

# Normaliza o arquivo para o que o código consome: `id`/`label`/duração sempre
# presentes e `pass_tiers.free`/`premium` com chave INT — JSON só tem string, e
# `table.has(lvl)` com int×float não bate (o mesmo normalizador que
# `PassService._PassStateRaw` aplica em `claimed_free`). Só roda em arquivo
# validado: `Entries()` devolve vazio quando há erro.
static func ParseEntries(raw : String) -> Array:
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var list : Variant = (parsed as Dictionary).get("seasons")
	if typeof(list) != TYPE_ARRAY:
		return []
	var out : Array = []
	var idx : int = 0
	for item in (list as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		idx += 1
		var entry : Dictionary = (item as Dictionary).duplicate(true)
		var id : String = str(entry.get("id", ""))
		entry["id"] = id
		entry["label"] = str(entry.get("label", id.to_upper()))
		entry["start_unix"] = _IntOf(entry, "start_unix", 0)
		entry["end_unix"] = _IntOf(entry, "end_unix", 0)
		entry["theme"] = str(entry.get("theme", ""))
		entry["rewards_ref"] = str(entry.get("rewards_ref", "gems+cosmetics, non-cashable"))
		entry["races"] = Races(entry)
		entry["duration_days"] = DurationDays(entry)
		entry["_idx"] = idx
		out.append(entry)
	return out

static func IsScheduled(entry : Dictionary) -> bool:
	var startsAt : int = int(entry.get("start_unix", 0))
	var endsAt : int = int(entry.get("end_unix", 0))
	return startsAt > 0 and endsAt > startsAt

static func DurationDays(entry : Dictionary) -> int:
	if IsScheduled(entry):
		return maxi(1, (int(entry["end_unix"]) - int(entry["start_unix"])) / DaySeconds)
	var duration : int = _IntOf(entry, "duration_days", DefaultDurationDays)
	return duration if duration > 0 else DefaultDurationDays

static func Races(entry : Dictionary) -> Array:
	var races : Variant = entry.get("races")
	if typeof(races) == TYPE_ARRAY and not (races as Array).is_empty():
		var out : Array = []
		for race in (races as Array):
			out.append(str(race))
		return out
	var fallback : Array = []
	fallback.append_array(EconomyCatalog.SEASON_KINDS)
	return fallback

static func ConfigID(entry : Dictionary) -> String:
	return str(entry.get("id", ""))

static func Label(entry : Dictionary) -> String:
	return str(entry.get("label", entry.get("id", "")))

static func IsConfigID(id : String) -> bool:
	if id.is_empty():
		return false
	var first : String = id[0]
	if not ((first >= "a" and first <= "z")):
		return false
	for i in id.length():
		var c : String = id[i]
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true

# ------------------------------------------------------------------ resolução (pura)

# O arquivo é a agenda; esta função é "o que está no ar em `ts`". Entrada com
# janela nominal cobre `start_unix <= ts < end_unix` e VENCE a rotação; sem
# nenhuma nominal cobrindo, vale a última entrada de rotação do arquivo.
# Sobreposição entre nominais: a que começa depois ganha (autoria mais recente),
# empate de início → a que termina depois, empate → a última do arquivo. Nunca
# duas no ar: duas temporadas ativas seriam dois `pass_premium` para o mesmo
# dinheiro.
static func ResolveAt(entries : Array, ts : int) -> Dictionary:
	var best : Dictionary = {}
	for item in entries:
		var entry : Dictionary = item
		if not IsScheduled(entry) or not entry.has("_idx"):
			continue
		if int(entry["start_unix"]) <= ts and ts < int(entry["end_unix"]) and _Beats(entry, best):
			best = entry
	if not best.is_empty():
		return best.duplicate(true)
	return RollingEntry(entries)

static func RollingEntry(entries : Array) -> Dictionary:
	var best : Dictionary = {}
	for item in entries:
		var entry : Dictionary = item
		if IsScheduled(entry) or not entry.has("_idx"):
			continue
		if best.is_empty() or int(entry["_idx"]) > int(best["_idx"]):
			best = entry
	return best.duplicate(true) if not best.is_empty() else {}

static func _Beats(a : Dictionary, b : Dictionary) -> bool:
	if b.is_empty():
		return true
	if int(a["start_unix"]) != int(b["start_unix"]):
		return int(a["start_unix"]) > int(b["start_unix"])
	if int(a["end_unix"]) != int(b["end_unix"]):
		return int(a["end_unix"]) > int(b["end_unix"])
	return int(a["_idx"]) > int(b["_idx"])

static func EntryByID(entries : Array, id : String) -> Dictionary:
	if id.is_empty():
		return {}
	for item in entries:
		if str((item as Dictionary).get("id", "")) == id:
			return (item as Dictionary).duplicate(true)
	return {}

# A temporada que o relógio deve ABRIR agora (nenhuma linha ativa no banco).
static func EntryToOpen(entries : Array, ts : int) -> Dictionary:
	return ResolveAt(entries, ts)

# Janela materializada na linha `season`. Começa SEMPRE em `now`: uma linha com
# `starts_at` no passado faria `SnapshotSeasonSpend` puxar gasto de antes da
# temporada para dentro da apuração. O calendário é honrado no FIM —
# `ends_at = end_unix` — então a temporada agendada termina na hora marcada mesmo
# se o servidor acordou tarde.
static func WindowForEntry(entry : Dictionary, now : int) -> Dictionary:
	if entry.is_empty():
		return {}
	if IsScheduled(entry):
		var endsAt : int = int(entry["end_unix"])
		if endsAt <= now:
			return {}
		return {"starts_at": now, "ends_at": endsAt}
	return {"starts_at": now, "ends_at": now + DurationDays(entry) * DaySeconds}

# `rules_frozen` é prova auditável, não input de parsing — mas é onde a linha
# carrega a própria identidade desde OPS-2 (`config_id`), o que dispensa migration
# numa tabela que já tem dados de jogador. As chaves históricas
# (`season`/`days`/`kinds`/`prizes`/`frozen`) continuam presentes para quem lê o
# congelado hoje (GUI, `SuiteSeasonBootstrap`).
static func RulesJSONForEntry(entry : Dictionary) -> String:
	if entry.is_empty():
		return "{}"
	# Chaves atribuídas uma a uma de propósito: no literal de dicionário do
	# GDScript, `ConfigIDKey = x` grava a LITERAL "ConfigIDKey" como chave (não o
	# valor do const), e o `config_id` nunca voltaria de `rules_frozen`. É o
	# constante que amarra escrita e leitura (`ConfigIDOfRow`), então ele tem de
	# entrar como expressão de índice.
	var rules : Dictionary = {}
	rules[ConfigIDKey] = ConfigID(entry)
	rules["season"] = Label(entry)
	rules["days"] = DurationDays(entry)
	rules["kinds"] = Races(entry)
	rules["prizes"] = str(entry.get("rewards_ref", ""))
	rules["frozen"] = true
	if str(entry.get("theme", "")).length() > 0:
		rules["theme"] = str(entry["theme"])
	if entry.has("premium_sku"):
		rules["premium_sku"] = str(entry["premium_sku"])
	return JSON.stringify(rules)

static func ConfigIDOfRow(row : Dictionary) -> String:
	var raw : String = str(row.get("rules_frozen", ""))
	if raw.strip_edges().is_empty():
		return ""
	var parsed : Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return str((parsed as Dictionary).get(ConfigIDKey, ""))

# Linha do banco → entrada do arquivo. Ordem: o `config_id` congelado na linha;
# sem ele (linha anterior ao OPS-2, ou criada por `/season create <dias>`), a
# janela da linha resolve por timestamp; sem resolução, `{}` = "use os defaults
# do catálogo", que é exatamente o comportamento antigo. Nenhum dado gravado por
# jogador é reescrito nem invalidado por aqui.
static func EntryForSeasonRow(entries : Array, row : Dictionary) -> Dictionary:
	if entries.is_empty() or row.is_empty():
		return {}
	var id : String = ConfigIDOfRow(row)
	if not id.is_empty():
		return EntryByID(entries, id)
	var startsAt : int = int(row.get("starts_at", 0))
	if startsAt <= 0:
		return {}
	return ResolveAt(entries, startsAt)

# O calendário assumiu o ar: a temporada de rotação em andamento congela no
# marco, senão a sucessora agendada só abriria quando os `duration_days` da
# corrente vencessem. Uma nominal em andamento NUNCA é preemptada — ela tem
# calendário próprio e fechá-la cedo seria mexer numa temporada prometida; linha
# legada (sem `config_id`) também não.
static func ShouldPreempt(entries : Array, activeRow : Dictionary, ts : int) -> bool:
	if entries.is_empty() or activeRow.is_empty():
		return false
	var current : Dictionary = ResolveAt(entries, ts)
	if current.is_empty() or not IsScheduled(current):
		return false
	var activeID : String = ConfigIDOfRow(activeRow)
	if activeID.is_empty() or activeID == str(current["id"]):
		return false
	var activeEntry : Dictionary = EntryByID(entries, activeID)
	if activeEntry.is_empty():
		return false
	return not IsScheduled(activeEntry)

# Início nominal mais próximo no futuro (0 = nada agendado). É o que transforma
# "lançar S2" em leitura de agenda: o operador vê aqui a data em que a temporada
# em rotação vai congelar.
static func NextScheduledStart(entries : Array, ts : int) -> int:
	var next : int = 0
	for item in entries:
		var entry : Dictionary = item
		if not IsScheduled(entry):
			continue
		var startsAt : int = int(entry["start_unix"])
		if startsAt > ts and (next == 0 or startsAt < next):
			next = startsAt
	return next

# ------------------------------------------------------------------ passe por temporada

# Só as TRILHAS são dado da temporada. A curva de PT (`PassThresholds`), o custo
# do skip e o valor das missões continuam no catálogo: a régua é uma regra só
# prometida no beta, e curva por temporada sem histórico de PT no banco criaria
# duas escalas de nível para a mesma coluna `season_account_state.pt`. Por isso
# `max_level` é teto, não extensão: validado em 1..PASS_MAX_LEVEL.
static func PassMaxLevel(entry : Dictionary) -> int:
	var tiers : Dictionary = _Tiers(entry)
	return mini(_IntOf(tiers, "max_level", EconomyCatalog.PASS_MAX_LEVEL), EconomyCatalog.PASS_MAX_LEVEL)

static func PassBonusStart(entry : Dictionary) -> int:
	return _IntOf(_Tiers(entry), "bonus_start", EconomyCatalog.PASS_BONUS_START)

static func PassBonusGems(entry : Dictionary) -> int:
	return _IntOf(_Tiers(entry), "bonus_gems", EconomyCatalog.PASS_BONUS_GEMS)

# Tabela da trilha (`"free"`/`"premium"`). `{}` = "o arquivo não declara trilha
# para esta temporada" → o chamador usa o default do catálogo, que é o que o
# jogador já via na tela antes do OPS-2.
static func PassTiers(entry : Dictionary, track : String) -> Dictionary:
	var table : Variant = _Tiers(entry).get(track)
	if typeof(table) != TYPE_DICTIONARY or (table as Dictionary).is_empty():
		return {}
	var out : Dictionary = {}
	for key in (table as Dictionary).keys():
		var k : String = str(key)
		if k.begins_with("_"):
			continue
		var level : int = k.to_int()
		if level < 1 or str(level) != k or typeof(table[k]) != TYPE_DICTIONARY:
			continue
		out[level] = _NormalizeReward(table[k])
	return out

static func _Tiers(entry : Dictionary) -> Dictionary:
	var tiers : Variant = entry.get("pass_tiers")
	return tiers if typeof(tiers) == TYPE_DICTIONARY else {}

static func _NormalizeReward(reward : Dictionary) -> Dictionary:
	var out : Dictionary = {
		"gems" = _IntOf(reward, "gems", 0),
		"chests" = _IntOf(reward, "chests", 0),
		"vip_days" = _IntOf(reward, "vip_days", 0),
	}
	var cosmetics : Array = []
	if typeof(reward.get("cosmetics")) == TYPE_ARRAY:
		for cid in (reward["cosmetics"] as Array):
			cosmetics.append(str(cid))
	out["cosmetics"] = cosmetics
	return out

# ------------------------------------------------------------------ helpers

static func _SkuAdvertised(sku : String) -> bool:
	for line in EconomyCatalog.SHOP_CATALOG:
		if str((line as Dictionary).get("sku", "")) == sku:
			return true
	return false

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

static func _FirstLine(raw : String) -> String:
	var cut : int = raw.find("\n")
	return raw.substr(0, cut) if cut > 0 else raw

static func _Now() -> int:
	return int(Time.get_unix_time_from_system())
