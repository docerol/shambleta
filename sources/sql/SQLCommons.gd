extends RefCounted
class_name SQLCommons

# Constant variables
const DBNameTemplate : String			= "sqlite.template.db"
const DBNameTesting : String			= "testing.db"
const DBName : String					= "live.db"
const BackupPath : String				= "sql-backups/"
const BackupPathTesting : String		= "sql-testing-backups/"
const BackupCheckIntervalSec : int		= 2
const BackupPlayersSec : int			= 10 * 60 # Every minute

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

enum BackupFrequency {DAILY, WEEKLY, MONTHLY}

const BackupLimits : Dictionary[BackupFrequency, int] = {
	BackupFrequency.DAILY: 7,
	BackupFrequency.WEEKLY: 4,
	BackupFrequency.MONTHLY: 12
}

const Verbosity : SQLite.VerbosityLevel	= SQLite.NORMAL

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
