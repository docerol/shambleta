extends Node
# SOM-IDLE parser: class_name WebPush escondia o autoload homônimo (erro de
# parse no Godot estrito) — a API estática vive em WebPushService; o autoload
# `WebPush` (nó) continua existindo para a cena/service worker.
class_name WebPushService

# SOM-IDLE F3: web push notification support for browser builds.
# Uses the browser's Notification API and a service worker for push events.
# Requires HTTPS (or localhost) and user permission.

static var _permission : String = "default"
static var _enabled : bool = false

static func Initialize():
	# Corrige erro de parse no modo -s: autoloads não disponíveis diretamente;
	# acessa via singleton global (Engine.get_singleton) — conforme API Godot 4.
	var launcher_node = Engine.get_singleton("LauncherCommons") if Engine.has_singleton("LauncherCommons") else null
	var conf_node = Engine.get_singleton("Conf") if Engine.has_singleton("Conf") else null
	if launcher_node == null or conf_node == null:
		return
	if not launcher_node.isWeb:
		return
	_enabled = conf_node.GetBool("web", "push_enabled", 0)  # Conf.Type.USERSETTINGS = 0
	_register_service_worker()

static func _register_service_worker():
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	if js.has_method("register_sw"):
		js.register_sw("/sw.js")

static func RequestPermission() -> String:
	var launcher_node = Engine.get_singleton("LauncherCommons") if Engine.has_singleton("LauncherCommons") else null
	var conf_node = Engine.get_singleton("Conf") if Engine.has_singleton("Conf") else null
	if launcher_node == null or conf_node == null:
		return "unsupported"
	if not launcher_node.isWeb:
		return "unsupported"
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return "unsupported"
	var result : String = js.request_permission()
	if result == "granted":
		_permission = "granted"
		_enabled = true
		conf_node.SetValue("web", "push_enabled", 0, true)
		conf_node.SaveType("settings", 0)
	elif result == "denied":
		_permission = "denied"
		_enabled = false
	else:
		_permission = "default"
		_enabled = false
	return _permission

static func GetPermission() -> String:
	var conf_node = Engine.get_singleton("Conf") if Engine.has_singleton("Conf") else null
	if conf_node == null:
		return _permission
	return _permission

static func IsEnabled() -> bool:
	return _enabled and _permission == "granted"

static func IsSupported() -> bool:
	var launcher_node = Engine.get_singleton("LauncherCommons") if Engine.has_singleton("LauncherCommons") else null
	if launcher_node == null:
		return false
	return launcher_node.isWeb

static func Show(title : String, body : String, icon : String = ""):
	var launcher_node = Engine.get_singleton("LauncherCommons") if Engine.has_singleton("LauncherCommons") else null
	var conf_node = Engine.get_singleton("Conf") if Engine.has_singleton("Conf") else null
	if launcher_node == null or conf_node == null:
		return
	if not launcher_node.isWeb or not IsEnabled():
		return
	var js = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	js.show_notification(title, body, icon)

static func SetEnabled(enabled : bool):
	_enabled = enabled
	var launcher_node = Engine.get_singleton("LauncherCommons") if Engine.has_singleton("LauncherCommons") else null
	var conf_node = Engine.get_singleton("Conf") if Engine.has_singleton("Conf") else null
	if launcher_node == null or conf_node == null:
		return
	if launcher_node.isWeb:
		conf_node.SetValue("web", "push_enabled", 0, enabled)
		conf_node.SaveType("settings", 0)

