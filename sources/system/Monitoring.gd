extends Node

# SOM-IDLE: contexto de erro do client/servidor no Sentry (addon em addons/sentry).
#
# Por que este arquivo existe de novo: f781f71 ("Resgata boot headless") esvaziou o
# Monitoring por causa de um erro de parser — BeforeSend estava indentado com dois
# espaços num arquivo de tabs, a mesma classe de bug que o próprio commit lista como
# corrigida em oito arquivos outros. Apagaram o conteúdo em vez da indentação, e um
# autoload que não parseia derruba o boot inteiro. O efeito colateral ficou vivo:
# Map.gd chama Monitoring.SetPlayer na chegada do jogador local ao mapa, e a função
# deixou de existir — erro de runtime no meio daquele fluxo.
#
# Quando isto não faz nada: `OS.has_feature("sentry")` é falso fora de export, e é
# verdadeiro exatamente onde a CI injeta a tag (`.github/workflows/godot-ci.yml`,
# job "Configure Sentry", conditional ao segredo do DSN). Ou seja: sem DSN no build,
# nenhum byte sai da máquina — inclusive aqui no headless dos testes.
#
# Nada de "spans de performance": nunca houve StartSpan/FinishSpan/ActiveSpans no
# projeto. Performance se mede com tests/benchmarks.gd e o profiler do editor;
# processo vivo e fila de grants se medem em sources/system/MetricsServer.gd.

# Gate de privacidade: Conf.GetVariant lê a seção [User] do settings.cfg do usuário,
# que só existe depois de alguém mexer no botão em Settings.gd (SetValue escreve em
# [User]). Sem escolha salva, o valor é false e o evento é descartado — opt-in de
# verdade, não o [Default] empacotado (que por isso mesmo está em false).
func BeforeSend(event : SentryEvent) -> SentryEvent:
	var enabled : bool = Conf.GetVariant("User", "Privacy-BugReports", Conf.Type.USERSETTINGS, false)
	return event if enabled else null

func Configure(options : SentryOptions) -> void:
	options.godot_logger.event_mask = SentryOptions.MASK_ERROR | SentryOptions.MASK_WARNING | SentryOptions.MASK_SCRIPT | SentryOptions.MASK_SHADER
	options.debug = false
	options.attach_log = false
	options.before_send = BeforeSend

func SetPlayer(playerName : String) -> void:
	if SentrySDK.is_enabled() and not playerName.is_empty():
		var user : SentryUser = SentryUser.new()
		user.username = playerName
		SentrySDK.set_user(user)
		SentrySDK.set_tag("player", playerName)

# Chamadores passam Peers.TransportType (enum/int) — parâmetro sem tipo e str() na
# tag para não criar dependência Monitoring → Peers.
func SetTransport(transport) -> void:
	if SentrySDK.is_enabled():
		SentrySDK.set_tag("transport", str(transport))

func _enter_tree() -> void:
	if not OS.has_feature("sentry"):
		return
	SentrySDK.init(Configure)
	if SentrySDK.is_enabled():
		SentrySDK.set_tag("platform", OS.get_name())
		SentrySDK.set_tag("version", str(ProjectSettings.get_setting("application/config/version", "")))
		SentrySDK.set_tag("role", "server" if "--server" in OS.get_cmdline_args() else "client")
		SentrySDK.set_tag("headless", "true" if DisplayServer.get_name() == "headless" else "false")
