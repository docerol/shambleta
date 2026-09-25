extends Node
class_name SQLBackups

#
var thread : Thread						= Thread.new()
var isRunning : bool					= false
var stopRequested : bool				= false

#
func CreateDailyBackup() -> String:
	var date : Dictionary = Time.get_datetime_dict_from_system()
	var frequencyDir : String = SQLCommons.BackupFrequency.keys()[SQLCommons.BackupFrequency.DAILY]
	var backupFile : String = SQLCommons.GetBackupPath() + "%s/%d-%02d-%02d_%02d-%02d-%02d" % [frequencyDir, date.year, date.month, date.day, date.hour, date.minute, date.second] + Path.DBExt
	if Launcher.SQL.db.backup_to(backupFile):
		Util.PrintInfo("SQL", "Backup created: " + backupFile)
		return backupFile
	else:
		Util.PrintLog("SQL", "Backup failed: " + backupFile)
		return ""

func CopyBackup(backupFilePath : String, backupFrequency : SQLCommons.BackupFrequency) -> String:
	var frequencyDir : String = SQLCommons.BackupFrequency.keys()[backupFrequency]
	var newFile : String = SQLCommons.GetBackupPath() + "%s/%s" % [frequencyDir, backupFilePath.get_file()]
	var errorCode : Error = DirAccess.copy_absolute(backupFilePath, newFile)

	if (errorCode == Error.OK):
		Util.PrintInfo("SQL", "Backup created: " + newFile)
		return newFile
	else:
		Util.PrintLog("SQL", "Backup failed for file %s with code %d" % [newFile, errorCode])
		return ""

# SOM-IDLE A2: push offsite best-effort + verificação de restore.
# Chamado após o backup diário; nunca falha o backup local.
static func PushOffsite(backupFilePath : String, offsiteDir : String = "") -> String:
	var target : String = offsiteDir if not offsiteDir.is_empty() else SQLCommons.GetOffsiteBackupPath()
	if target.is_empty() or backupFilePath.is_empty():
		return ""
	if not DirAccess.dir_exists_absolute(target):
		if DirAccess.make_dir_absolute(target) != OK:
			Util.PrintLog("SQL", "Offsite backup dir unreachable: " + target)
			return ""
	var newFile : String = target.rstrip("/") + "/" + backupFilePath.get_file()
	if DirAccess.copy_absolute(backupFilePath, newFile) != OK:
		Util.PrintLog("SQL", "Offsite backup copy failed: " + newFile)
		return ""
	if not VerifyBackupRestorable(newFile):
		Util.PrintLog("SQL", "Offsite backup failed restore check: " + newFile)
		return ""
	Util.PrintInfo("SQL", "Offsite backup pushed + verified: " + newFile)
	return newFile

# Abre a cópia e lê a tabela migration — prova que o restore abre e é legível.
static func VerifyBackupRestorable(backupFilePath : String) -> bool:
	if backupFilePath.is_empty() or not FileAccess.file_exists(backupFilePath):
		return false
	var probe : SQLite = SQLite.new()
	probe.path = backupFilePath
	probe.verbosity_level = SQLite.QUIET
	if not probe.open_db():
		return false
	var ok : bool = probe.query("SELECT version FROM migration LIMIT 1;") and not probe.query_result.is_empty()
	probe.close_db()
	return ok

func PruneBackups() -> void:
	for backupFrequency in SQLCommons.BackupFrequency.values():
		var backupFrequencyDir = SQLCommons.BackupFrequency.keys()[backupFrequency]
		var dir : DirAccess = DirAccess.open(SQLCommons.GetBackupPath() + "/" + backupFrequencyDir)
		if not dir:
			Util.PrintLog("SQL", "PruneBackups: diretório '%s' inacessível — disco cheio?" % (SQLCommons.GetBackupPath() + "/" + backupFrequencyDir))
			return
		
		var dirFiles : PackedStringArray = dir.get_files()
		var backupFiles : PackedStringArray = []
		for file in dirFiles:
			if file.get_extension() == "db":
				backupFiles.append(file)

		while backupFiles.size() > SQLCommons.BackupLimits[backupFrequency]:
			backupFiles.sort() # Oldest backups first
			var prunedFile : String = backupFiles[0]
			var err : Error = dir.remove(prunedFile)
			if err == OK:
				Util.PrintInfo("SQL", "Backup removed: " + prunedFile)
			else:
				Util.PrintLog("SQL", "Backup removal failed: %s [%d]" % [prunedFile, err])
			backupFiles.remove_at(0)

#
func Run():
	var lastDailyBackupTimestamp : int = SQLCommons.Timestamp()
	var lastWeeklyBackupTimestamp : int = SQLCommons.Timestamp()
	var lastMonthlyBackupTimestamp : int = SQLCommons.Timestamp()
	var lastPlayerUpdateTimestamp : int = SQLCommons.Timestamp()
	var lastStopCheckTimestamp : int = SQLCommons.Timestamp()
	# #28: 0, e não `Timestamp()` — a rotação meta precisa rodar na primeira
	# passada útil após o boot. Herdar o convenção dos timers de backup (primeira
	# só dispara 24 h depois) significava que um servidor que reinicia mais de uma
	# vez por dia nunca rodava reconcile, copas, ciclo de temporada, eventos,
	# referral nem tickets de arena.
	var lastMetaJobTimestamp : int = 0
	# G1: mesmo raciocínio do timestamp acima — o relógio da temporada precisa
	# valer no primeiro boot (abrir a S1 é o que torna o `pass.s1` do catálogo
	# entregável), não 24 h depois.
	var lastSeasonClockTimestamp : int = 0

	while isRunning:
		var timestamp : int = SQLCommons.Timestamp()

		# #28: a rotação meta saiu do guard do backup. Estava dentro de
		# `if not backupFilePath.is_empty()`, então falha de disco, diretório de
		# backup removido ou backup desligado paravam reconcile, fraud-scan,
		# ciclo de temporada, copas, referral, live events e tickets de arena de
		# uma vez. Os dois timers são independentes e nenhum manda no outro.
		# Os dois `isInitialized` são o preço de o job poder disparar no boot: esta
		# thread nasce em `SQLBackups.new()`, que o `_post_launch` chama ANTES do
		# `ApplyMigrations()` — sem o gate ela consultaria `live_event`/`tournament`
		# no meio da migração. Sem `continue`: fica sem marcar o timestamp e tenta
		# de novo na próxima passada (100 ms).
		if timestamp - lastMetaJobTimestamp >= SQLCommons.MetaJobIntervalSec \
				and Launcher.SQL != null and Launcher.SQL.isInitialized \
				and Launcher.Economy != null and Launcher.Economy.isInitialized:
			lastMetaJobTimestamp = timestamp
			Launcher.Economy.RunReconcileJob()

		# G1: relógio da espinha sazonal — cadência própria (`SeasonClockIntervalSec`,
		# minutos) e não o intervalo diário do reconcile, porque o placar da
		# temporada é congelado no instante do fechamento e `ends_at` não espera o
		# job. As duas metades são chamadas na ordem fechamento→abertura:
		# `TickSeasonLifecycle` fecha e liquida a vencida e `EnsureSeasonS1` abre a
		# sucessora (é ela que torna o `pass.s1` do catálogo entregável). São duas
		# chamadas e não uma porque as suítes e qualquer leitor do ciclo querem
		# fechar sem, como efeito colateral, ganhar uma temporada ativa. As duas são
		# no-op com a trava do beta desligada (`SHAMBLETA_ENABLE_SEASONS`), então
		# desligar a env continua desligando o espinho inteiro por aqui. Mesmos gates
		# do bloco acima: a thread nasce antes de `ApplyMigrations()`.
		if timestamp - lastSeasonClockTimestamp >= SQLCommons.SeasonClockIntervalSec \
				and Launcher.SQL != null and Launcher.SQL.isInitialized \
				and Launcher.Economy != null and Launcher.Economy.isInitialized:
			lastSeasonClockTimestamp = timestamp
			var seasonTick : Dictionary = Launcher.Economy.TickSeasonLifecycle()
			# `EnsureSeasonS1` devolve o season_id da temporada criada ou 0 se já
			# havia uma ativa — por isso aqui é contagem 0/1, igual a `TickTournaments`.
			var opened : int = 1 if Launcher.Economy.EnsureSeasonS1() > 0 else 0
			if int(seasonTick.get("closed", 0)) > 0 or int(seasonTick.get("settled", 0)) > 0 or opened > 0:
				Util.PrintLog("Economy", "Season clock: closed %d, settled %d, opened %d" % [int(seasonTick.get("closed", 0)), int(seasonTick.get("settled", 0)), opened])

		if timestamp - lastDailyBackupTimestamp >= SQLCommons.DailyBackupIntervalSec:
			var backupFilePath: String = CreateDailyBackup()
			lastDailyBackupTimestamp = timestamp
			if not backupFilePath.is_empty():
				PushOffsite(backupFilePath)

			if timestamp - lastWeeklyBackupTimestamp >= SQLCommons.WeeklyBackupIntervalSec \
					and !backupFilePath.is_empty():
				backupFilePath = CopyBackup(backupFilePath, SQLCommons.BackupFrequency.WEEKLY)
				lastWeeklyBackupTimestamp = timestamp
			
			if timestamp - lastMonthlyBackupTimestamp >= SQLCommons.MonthlyBackupIntervalSec \
					and !backupFilePath.is_empty():
				CopyBackup(backupFilePath, SQLCommons.BackupFrequency.MONTHLY)
				lastMonthlyBackupTimestamp = timestamp

			PruneBackups()

		if timestamp - lastPlayerUpdateTimestamp >= SQLCommons.BackupPlayersSec:
			if Launcher.World and Launcher.World.is_inside_tree():
				Launcher.World.call_deferred("BackupPlayers")
			lastPlayerUpdateTimestamp = timestamp

		if timestamp - lastStopCheckTimestamp >= SQLCommons.BackupCheckIntervalSec:
			if stopRequested:
				isRunning = false
				break
			lastStopCheckTimestamp = timestamp

		OS.delay_msec(100)

func Start():
	if not isRunning:
		isRunning = true
		thread.start(Run, Thread.PRIORITY_LOW)

func Stop():
	if isRunning and not stopRequested:
		stopRequested = true
		thread.wait_to_finish()

# The worker calls back into Launcher.World/Economy/SQL. Left running, its Thread
# is destroyed unjoined at teardown and races the tree it is reaching into, so
# every holder joins here instead of relying on SQL.Destroy() being reachable.
func _exit_tree():
	Stop()

#
func _init():
	var backupPath : String = SQLCommons.GetBackupPath()
	if not DirAccess.dir_exists_absolute(backupPath):
		DirAccess.make_dir_absolute(backupPath)

	for backupFrequency in SQLCommons.BackupFrequency.values():
		var frequencyDir : String = SQLCommons.GetBackupPath() + SQLCommons.BackupFrequency.keys()[backupFrequency] + "/"
		if not DirAccess.dir_exists_absolute(frequencyDir):
			DirAccess.make_dir_absolute(frequencyDir)

	Start()
