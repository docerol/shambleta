extends RefCounted
class_name FlagsBootstrap

# OPS-3: o ponto onde as flags deixam de ser biblioteca e passam a ser parte do
# boot. Chamado por `Launcher._post_launch()` depois de SQL (a migration do
# `feature_flag` precisa ter rodado) e depois de Telemetry (o `/flags set` grava
# `flag_change`). Idempotente por guarda static: `Launcher.Mode()` pode ser chamado
# mais de uma vez no mesmo processo (é assim que os harnesses sobem), e
# `CommandManager.Register` em nome repetido faz `push_error` — com
# `treat_warnings_as_errors` isso é exatamente o tipo de ruído que vira bug de
# build em outra rodada.

static var _installed : bool = false
# Segurando o `RefCounted` vivo: `CommandCollection._notification` desregistra os
# comandos no PREDELETE, e uma instância solta aqui seria coletada no fim do
# Install() — o comando nasceria e morria no mesmo frame.
static var _commands : OpsCommands = null

# Retorna quantas flags vieram do banco (-1 = sem banco: client, ou server sem a
# migration aplicada). O número vai para o log de boot porque "a flag está
# ligada?" é a primeira pergunta de todo incidente de Live Ops, e a resposta sem
# fonte não é resposta.
static func Install() -> int:
	FeatureFlags.Reset()
	var loaded : int = FeatureFlags.Reload()
	if not _installed and Launcher.World != null:
		_commands = OpsCommands.new()
		_installed = true
	Util.PrintLog("Ops", "feature flags: %d do banco, %d conhecidas, /flags %s" % [
		loaded, FeatureFlags.Known().size(), "registrado" if _installed else "ausente (sem mundo ou desligado)"])
	return loaded

# Derruba o comando. Não há chamada manual de unregister: `CommandCollection`
# desregistra os próprios comandos no `NOTIFICATION_PREDELETE`, e soltar a
# referência é o que dispara isso (desregistar à mão aqui faria o PREDELETE
# reclamar de um nome que já saiu do dispatcher).
static func Uninstall() -> void:
	_commands = null
	_installed = false

static func IsInstalled() -> bool:
	return _installed
