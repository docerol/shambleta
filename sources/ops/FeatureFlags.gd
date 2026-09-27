extends RefCounted
class_name FeatureFlags

# OPS-1 (AUDITORIA_2026-09-27 §15 Live Ops 5/10): flag de runtime, não flag de
# deploy. As travas que existiam antes deste arquivo são `OS.get_environment`
# (AH bots, seasons, ad stub, GM mode, offsite, proxy TLS, …) — honestas e
# fail-closed, mas mudar uma exige rebuild + restart do processo, que é exatamente
# o que "Live Ops" não pode precisar para desligar uma feature que está sangrando.
# Isto aqui é a camada que falta: a mesma semântica de fail-closed, com o valor
# lido do banco e recarregável sem sair do ar.
#
# Precedência (nesta ordem, e `Source()` devolve qual venceu):
#   1. `feature_flag` no banco — estado runtime, gravado por `/flags` (GM) ou por
#      `Set()`. Só existe onde há SQL (servidor). Schema: migration 053.
#   2. `SHAMBLETA_FLAG_<CHAVE>` no ambiente — knob de deploy/CI, útil quando o
#      processo ainda não tem banco (client) ou quando o operator precisa forçar o
#      estado no boot. Aceita "1"/"0" e as variantes "true"/"false"/"on"/"off"/
#      "yes"/"no" para não brigar com quem já escreve env assim.
#   3. Default em código — fail-closed: nenhuma superfície de escrita nasce ligada.
#
# Escopo assumido, sem fingir mais do que é: cache em memória do processo que
# recarrega + leitura local no client. Não é A/B, não segmenta por conta, não tem
# histórico de auditoria (`updated_at` é o único rastro) e não tem painel. Numa
# arquitetura com vários processos de jogo, cada um precisa do seu `Reload()` —
# hoje há um único writer e um único server, então o reload do server é o sistema
# todo (e o client continua por env/default, que é o que ele consegue enxergar).
#
# Estado 100% static, como `CommandManager`/`AdProvider`: quem consulta é código
# de caminho quente (client a cada botão de anúncio, servidor a cada
# `/tournament enter`) e um `RefCounted` por chamada seria alocação no meio do
# frame. Sem lock: os chamadores são todos da thread principal do próprio
# processo, e a escrita no banco passa pelo `queryMutex` do SQL.

const FlagTable : String = "feature_flag"

# Chaves com gating real nesta passada. Nunca renomear uma chave em uso: o valor
# no banco e o runbook do deploy apontam para o nome.
const ADS_REWARDED : String = "ads_rewarded"			# sítio: AdProvider (client)
const TOURNAMENT_ENTER : String = "tournament_enter"	# sítio: WorldCommands (server)
const FLAGS_ADMIN : String = "ops_flags_admin"			# kill switch do /flags
const FUNNEL_DAILY : String = "analytics_funnel_daily"	# sítio: TelemetryService

# Fail-closed nas superfícies que escrevem; ligados nos caminhos que hoje já
# funcionam e cuja única mudança aqui é ganhar um desligador (ver `Reasons`).
const Defaults : Dictionary[String, bool] = {
	ADS_REWARDED: true,
	TOURNAMENT_ENTER: true,
	FLAGS_ADMIN: false,
	FUNNEL_DAILY: true,
}

# default -> por que é este o default (aparece em `/flags list`; um default sem
# explicação vira superstição na próxima rodada de deploy)
const Reasons : Dictionary[String, String] = {
	ADS_REWARDED: "o rewarded é opt-in e o servidor já nega sem SHAMBLETA_AD_STUB/SSV; a flag é o desligador de emergência do lado do client",
	TOURNAMENT_ENTER: "inscrição em gold com prêmio em gems: desliga-se sem deploy se a copa quebrar",
	FLAGS_ADMIN: "superfície de escrita em feature de receita: ligada por GM no deploy que precisar, nunca por default",
	FUNNEL_DAILY: "agregado diário do funil no tick da telemetria: é leitura pura, mas pode ser cortada sob carga",
}

# cache em memória: chave -> valor textual (o parse booleano é `IsTrue`)
static var _cache : Dictionary[String, String] = {}
static var _tableReady : bool = false

static func Known() -> Array[String]:
	var keys : Array[String] = []
	for key in Defaults:
		keys.append(String(key))
	keys.sort()
	return keys

static func IsKnown(key : String) -> bool:
	return Defaults.has(key)

static func DefaultOf(key : String) -> bool:
	return bool(Defaults.get(key, false))

# "1"/"true"/"on"/"yes" — o mesmo vocabulário que as env gates do deploy já
# aceitam, e nada além dele: um valor escrito errado não é "verdadeiro porque
# existe". `SHAMBLETA_AD_STUB` mede exatamente isso (valor não-1 não liga o stub)
# e a régua daqui é a mesma.
static func IsTrue(value : String) -> bool:
	var v : String = value.strip_edges().to_lower()
	return v == "1" or v == "true" or v == "on" or v == "yes"

# "db" > "env" > "default". Não é conforto de painel: as três fontes têm donos
# diferentes (operator, deploy, código) e a divergência entre elas é o defeito que
# ninguém vê no post-mortem.
static func Source(key : String) -> String:
	if _cache.has(key):
		return "db"
	if not EnvValue(key).is_empty():
		return "env"
	return "default"

static func EnvValue(key : String) -> String:
	return OS.get_environment("SHAMBLETA_FLAG_" + key.to_upper()).strip_edges()

static func Enabled(key : String) -> bool:
	return IsTrue(Value(key))

static func Value(key : String) -> String:
	if _cache.has(key):
		return _cache[key]
	var fromEnv : String = EnvValue(key)
	if not fromEnv.is_empty():
		return fromEnv
	return "1" if DefaultOf(key) else "0"

# Estado declarativo do processo (chave -> "valor (fonte)"), para log, `/flags`
# e teste. Cópia: quem recebe não muda estado ligando na mão.
static func Snapshot() -> Dictionary[String, String]:
	var out : Dictionary[String, String] = {}
	for key in Known():
		out[key] = "%s (%s)" % [Value(key), Source(key)]
	for key in _cache:
		if not out.has(key):
			out[key] = "%s (db)" % _cache[key]
	return out

# Devolve o processo ao estado "só defaults + env", sem tocar no banco. É o que o
# boot chama antes do `Reload()`: depois de um `Mode()` que trocou de base, cache
# herdado da base anterior seria lido como se fosse da atual.
static func Reset() -> void:
	_cache = {}
	_tableReady = false

# Relê a tabela inteira. Retorna quantas chaves ficaram no cache, ou -1 quando não
# há SQL pronto (client, ou server antes da migration): o cache antigo é
# preservado de propósito num reload que não pôde ler — apagar o estado que o
# processo está servindo seria pior do que envelhecê-lo.
static func Reload() -> int:
	if Launcher.SQL == null or not Launcher.SQL.isInitialized or not TableReady():
		return -1
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT key, value FROM feature_flag;", [])
	var fresh : Dictionary[String, String] = {}
	for row in rows:
		var key : String = str(row.get("key", ""))
		if key.is_empty():
			continue
		fresh[key] = str(row.get("value", ""))
	_cache = fresh
	return _cache.size()

# A tabela só existe depois da migration; no client (e em qualquer processo sem
# SQL) isto é false e o resto da API continua funcionando por env/default.
static func TableReady() -> bool:
	if _tableReady:
		return true
	if Launcher.SQL == null or not Launcher.SQL.isInitialized:
		return false
	var rows : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name = '%s';" % FlagTable)
	_tableReady = not rows.is_empty()
	return _tableReady

# Escrita admin (`/flags set`, caminho de teste). Upsert em uma statement: `key`
# é PRIMARY KEY, então o `INSERT OR REPLACE` é o conflito resolvido pelo próprio
# SQLite — sem SELECT antes, sem janela entre ler e gravar.
# Retorna false sem tocar em nada quando não há banco: flag que não persiste não
# pode parecer ligada para o processo inteiro e sumir no reload seguinte.
static func Set(key : String, value : String) -> bool:
	if key.is_empty() or value.is_empty():
		return false
	if not TableReady():
		return false
	var now : int = SQLCommons.Timestamp()
	if not Launcher.SQL.ExecuteBindings(
		"INSERT OR REPLACE INTO feature_flag (key, value, updated_at) VALUES (?, ?, ?);",
		[key, value, now]):
		return false
	_cache[key] = value
	return true

static func Forget(key : String) -> bool:
	if key.is_empty() or not TableReady():
		return false
	if not Launcher.SQL.ExecuteBindings("DELETE FROM feature_flag WHERE key = ?;", [key]):
		return false
	_cache.erase(key)
	return true

# UNIX seconds do último write (unidade: segundos desde o epoch, mesma régua de
# `telemetry_event.created_at` e de `SQLCommons.Timestamp()`).
static func UpdatedAt(key : String) -> int:
	if key.is_empty() or not TableReady():
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT updated_at FROM feature_flag WHERE key = ?;", [key])
	return int(rows[0].get("updated_at", 0)) if not rows.is_empty() else 0
