extends Node
# SOM-IDLE parser: class_name WebPush escondia o autoload homônimo (erro de
# parse no Godot estrito) — a API estática vive em WebPushService; o autoload
# `WebPush` (nó) continua existindo para a cena/service worker.
class_name WebPushService

# SOM-IDLE F3: web push notification support for browser builds.
# Uses the browser's Notification API and a service worker for push events.
# Requires HTTPS (or localhost) and user permission.
#
# AUDITORIA_INDEPENDENTE W5. Os guards `Engine.has_singleton("Conf")` /
# `("LauncherCommons")` que abriam todas as funções abaixo nunca foram
# verdadeiros: `Conf` e `LauncherCommons` são `class_name` (ServiceBase /
# RefCounted), não autoload — os autoloads do projeto são Launcher, Network,
# FSM, Monitoring, WebPush e PwaUpdate. `Engine.has_singleton` devolvia false em 100% dos
# builds e cada função saía pelo ramo nulo: o toggle de Settings não gravava
# nada, `Initialize` não registrava o service worker e `Show` nunca entregava.
# Chamada estática direta é o que o resto do código já usa (Settings.gd lê
# `LauncherCommons.isWeb` e `Conf.Type.USERSETTINGS` direto) e funciona também
# sob `godot -s`, que era o pretexto do guard. Mesmo defeito de FSM.gd:41.
#
# Os tipos literais `0` que existiam nestas chamadas também estavam errados:
# `Conf.Type` é { NONE = -1, SETTINGS = 0, USERSETTINGS = 1 }, ou seja o `0`
# apontava para o settings.cfg embarcado (o override do jogador nunca era
# escrito e um SaveType gravaria por cima do arquivo do pacote).

static var _permission : String = "default"
static var _enabled : bool = false

# Capacidade real de entrega — é o que a linha de Settings consulta.
# Push iniciado pelo servidor precisa de três peças que não existem no
# repositório: chave VAPID, tabela de subscription e um sender no companion.
# `deploy/web/sw.js` escuta `push`, mas nada jamais chamou
# `pushManager.subscribe`, então o evento nunca chega. Notificação local não
# cobre o caso de uso: com a aba em background o navegador pausa o
# requestAnimationFrame e o main loop do export web para de rodar
# (godotengine/godot#37031) — o jogo não percebe o evento que teria de avisar.
# Enquanto faltar o sender, mostrar o controle é prometer "avise-me quando
# voltar" sem poder cumprir; W5 é P3 na tabela do audit e cai depois do beta.
static func CanDeliver() -> bool:
	return false

static func Initialize():
	if not LauncherCommons.isWeb:
		return
	_enabled = Conf.GetBool("web", "push_enabled", Conf.Type.USERSETTINGS)
	_permission = _BrowserPermission()
	_register_service_worker()

static func _register_service_worker():
	# `js.has_method("register_sw")` não é checagem de existência: Godot encaminha o
	# nome para o lado JS, `ShambletaPush.has_method` não existe, e cada boot
	# despejava um `TypeError: obj[method] is not a function` no console do
	# navegador (medido em 2026-09-25). O guard real é CanDeliver(): o worker que já
	# está registrado no escopo "/" é o do engine (index.service.worker.js, que é o
	# que traz COOP/COEP e o cache offline), e `deploy/web/sw.js` nem é copiado pelo
	# Dockerfile. Registrar por cima deslocaria o do engine. Push server-side (VAPID
	# + tabela de subscription + sender) é o que falta para W5 existir; enquanto não
	# existir, nada daqui roda.
	if not CanDeliver():
		return
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	js.register_sw("/sw.js")

# O resultado de `Notification.requestPermission()` só existe no callback da
# Promise — a bridge antiga devolvia a Promise para um `var result : String`,
# que nunca casaria com "granted". `Notification.permission` é um getter
# síncrono: dispara o prompt e lê o estado real por ele.
static func RequestPermission() -> String:
	if not IsSupported():
		return "unsupported"
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return "unsupported"
	js.request_permission()
	_permission = str(js.get_permission())
	if _permission == "granted":
		_enabled = true
		_Save()
	elif _permission == "denied":
		_enabled = false
		_Save()
	return _permission

static func _BrowserPermission() -> String:
	if not IsSupported():
		return _permission
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return _permission
	return str(js.get_permission())

static func GetPermission() -> String:
	return _permission

static func IsEnabled() -> bool:
	return _enabled and _permission == "granted"

static func IsSupported() -> bool:
	return LauncherCommons.isWeb

static func Show(title : String, body : String, icon : String = ""):
	if not IsEnabled():
		return
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	js.show_notification(title, body, icon)

static func SetEnabled(enabled : bool):
	_enabled = enabled
	_Save()

static func _Save():
	if not LauncherCommons.isWeb:
		return
	Conf.SetValue("web", "push_enabled", Conf.Type.USERSETTINGS, _enabled)
	Conf.SaveType("settings", Conf.Type.USERSETTINGS)
