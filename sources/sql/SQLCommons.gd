extends RefCounted
class_name SQLCommons

# Constant variables
const DBNameTemplate : String			= "sqlite.template.db"
const DBNameTesting : String			= "testing.db"
const DBName : String					= "live.db"
const BackupPath : String				= "sql-backups/"
const BackupPathTesting : String		= "sql-testing-backups/"
const BackupCheckIntervalSec : int		= 2
const BackupPlayersSec : int			= 10 * 60 # A cada 10 minutos (600 s): cadência do passe de persistência iniciado pelo worker.

const DailyBackupIntervalSec : int		= 60 * 60 * 24
const WeeklyBackupIntervalSec : int		= 60 * 60 * 24 * 7
const MonthlyBackupIntervalSec : int	= 60 * 60 * 24 * 7 * 4

# #28 (AUDITORIA item 7 / G3): timer próprio para a rotação meta — reconcile,
# fraud scan, copas, referral, live events e tickets de arena. Ela heredava o
# intervalo E a condição de sucesso do backup, então um disco cheio desligava o
# meta game inteiro.
const MetaJobIntervalSec : int			= 60 * 60 * 24

# G1 (auditoria 2026-09-24, Bloco 1 #7): relógio próprio para a espinha sazonal
# (fechar vencida → congelar placar → liquidar → abrir a próxima). O ciclo saiu do
# job diário porque `power_score`, `bosses_beaten` e pontos de guild são contadores
# correntes, sem histórico: o placar é congelado no instante do fechamento, então
# cada hora entre `ends_at` e o fechamento é hora de jogo pós-temporada contando
# como se fosse da temporada. Cinco minutos deixam uma janela irredutível de
# fração do ciclo de jogo; o custo por passada é um `SELECT` por status.
const SeasonClockIntervalSec : int		= 60 * 5

# §12 (AUDITORIA_2026-09-27): cadência da poda de ledger no mesmo worker. Seis horas
# porque a janela de retenção é de dias: rodar mais vezes que isso só multiplica o
# scan de fronteira sem retirar mais uma linha. `SHAMBLETA_LEDGER_RETENTION=0`
# desliga na hora, sem recompilar — é o botão do ops para "a poda está competindo
# com o writer numa janela ruim".
const LedgerRetentionIntervalSec : int	= 60 * 60 * 6
const LedgerRetentionEnv : String		= "SHAMBLETA_LEDGER_RETENTION"
# Rodadas por gatilho: cada rodada poda BatchRows linhas; o teto limita o tamanho do
# passe (e portanto o quanto de writer um único disparo pode consumir).
const LedgerRetentionMaxRounds : int	= 20

enum BackupFrequency {DAILY, WEEKLY, MONTHLY}

const BackupLimits : Dictionary[BackupFrequency, int] = {
	BackupFrequency.DAILY: 7,
	BackupFrequency.WEEKLY: 4,
	BackupFrequency.MONTHLY: 12
}

const Verbosity : SQLite.VerbosityLevel	= SQLite.NORMAL

# Árvore de patches que o boot enxerga. Vazio = `Path.MigrationRsc` (o caminho
# embarcado no pacote), que é a resposta de sempre. Existe porque o carimbo de
# versão agora é fail-closed e precisa ser testado com um patch quebrado DE
# VERDADE: apontar para um diretório descartável é o único modo de provar isso
# sem escrever no `live.db` nem no `data/conf/migrations/` da produção. É também
# o ensaio de migration em staging antes do deploy.
const MigrationsDirEnv : String			= "SHAMBLETA_MIGRATIONS_DIR"

# Nome de slot de cosmético em `cosmetic_equip`. Entra como PARÂMETRO nas queries
# quentes: um literal `'title'` no texto da statement tira a leitura do caminho
# rápido de certificação (`SQLReadRules._FastCertify` não tem como separar código
# de conteúdo sem aspas, então abstém — ver tests/read_pool_test.gd).
const CosmeticSlotTitle : String		= "title"

# Read pool (WAL): conexões read-only concorrentes com o handle de escrita.
# O leitor fala com o mesmo arquivo, mas com `PRAGMA query_only=1`, e só é usado
# para leitura pura fora de transação de escrita — ver `SQLReadRules` (a regra) e
# `SQLReadPool` (as conexões).
#  - `ReadPoolDefaultEnabled` é o padrão do processo; `SHAMBLETA_SQL_READ_POOL=0`
#    desliga (e `=1` liga) sem recompilar, porque mexer no caminho de leitura do
#    dinheiro exige poder de desligar na hora.
#  - 2 slots, não 8: com o writer numa thread e o worker de backup na outra, dois
#    leitores já removem a espera do `queryMutex`; mais handle é mais -shm e mais
#    página em cache duplicada. Medido em tests/read_pool_test.gd.
const ReadPoolDefaultEnabled : bool		= true
const ReadPoolEnableEnv : String		= "SHAMBLETA_SQL_READ_POOL"
const ReadPoolSizeEnv : String			= "SHAMBLETA_SQL_READ_POOL_SIZE"
const ReadPoolSize : int				= 2
const MaxReadPoolSize : int				= 4
# Mesmo prazo do writer: um leitor em WAL não espera lock de escrita, mas se
# esperar (checkpoint, -shm recuperando) ele espera com prazo e devolve falha —
# nunca trava o loop do servidor.
const ReadPoolBusyTimeoutMs : int		= 5000
# QUIET de propósito: o erro de um leitor é tratado (fallback para o writer), não
# gritado. No worker thread, cada `push_error` de PRAGMA custodiado viraria ruído
# no log que o gate §24-8 lê.
const ReadPoolVerbosity : SQLite.VerbosityLevel	= SQLite.QUIET

# Utils
static func HasValue(data : Dictionary, key : String) -> bool:
	return data[key] != null if data.has(key) else false

static func GetOrAddValue(data : Dictionary, key : String, defaultVal : Variant) -> Variant:
	return data[key] if HasValue(data, key) else defaultVal

static func Timestamp() -> int:
	return int(Time.get_unix_time_from_system()) # Remove sub-seconds precision

# Live/Testing DB handling
static func GetBackupPath() -> String:
	return Path.Local + (BackupPathTesting if LauncherCommons.IsTesting else BackupPath)

# SOM-IDLE A2: diretório offsite (montagem NFS/S3-fuse/segundo disco) via env.
# Vazio = desabilitado. O push é best-effort e nunca falha o backup local.
static func GetOffsiteBackupPath() -> String:
	return OS.get_environment("SHAMBLETA_OFFSITE_BACKUPS").strip_edges()

static func GetDBPath() -> String:
	return Path.Local + (DBNameTesting if LauncherCommons.IsTesting else DBName)

static func CopyDatabase(targetPath : String) -> bool:
	# Try to copy the live database
	if LauncherCommons.IsTesting:
		if FileSystem.CopyFile(Path.Local + DBName, targetPath):
			return true
	# Try to copy the template database
	if FileSystem.CopyFile(Path.TemplateRsc + DBNameTemplate, targetPath):
		return true
	push_error("Could not find the default database template")
	return false
