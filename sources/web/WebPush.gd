extends Node
class_name WebPush

# SOM-IDLE F3: web push notification support for browser builds.
# Uses the browser's Notification API and a service worker for push events.
# Requires HTTPS (or localhost) and user permission.

static var _permission : String = "default"
static var _enabled : bool = false

static func Initialize():
	if not LauncherCommons.isWeb:
		return
	_enabled = Conf.GetBool("web", "push_enabled", Conf.Type.USERSETTINGS)
	_register_service_worker()

static func _register_service_worker():
	var js : JavaScriptBridge = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	if js.has_method("register_sw"):
		js.register_sw("/sw.js")

static func RequestPermission() -> String:
	if not LauncherCommons.isWeb:
		return "unsupported"
	var js : JavaScriptBridge = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return "unsupported"
	var result : String = js.request_permission()
	if result == "granted":
		_permission = "granted"
		_enabled = true
		Conf.SetValue("web", "push_enabled", Conf.Type.USERSETTINGS, true)
		Conf.SaveType("settings", Conf.Type.USERSETTINGS)
	elif result == "denied":
		_permission = "denied"
		_enabled = false
	else:
		_permission = "default"
		_enabled = false
	return _permission

static func GetPermission() -> String:
	return _permission

static func IsEnabled() -> bool:
	return _enabled and _permission == "granted"

static func IsSupported() -> bool:
	return LauncherCommons.isWeb

static func Show(title : String, body : String, icon : String = ""):
	if not LauncherCommons.isWeb or not IsEnabled():
		return
	var js : JavaScriptBridge = JavaScriptBridge.get_interface("ShambletaPush")
	if not js:
		return
	js.show_notification(title, body, icon)

static func SetEnabled(enabled : bool):
	_enabled = enabled
	if LauncherCommons.isWeb:
		Conf.SetValue("web", "push_enabled", Conf.Type.USERSETTINGS, enabled)
		Conf.SaveType("settings", Conf.Type.USERSETTINGS)

