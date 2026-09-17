extends RefCounted
class_name DeviceFingerprint

# SOM-IDLE S5: device fingerprint for multi-account detection.
# Collects anonymous device identifiers to detect multi-account abuse.
# Does NOT collect personal information — only hardware/software hashes.

static func Collect() -> Dictionary:
	var fingerprint : Dictionary = {}
	fingerprint["platform"] = OS.get_name()
	fingerprint["version"] = OS.get_version()
	fingerprint["arch"] = OS.get_processor_name() if OS.has_feature("pc") else OS.get_model()
	fingerprint["screen"] = "%dx%d" % [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y]
	fingerprint["dpi"] = DisplayServer.screen_get_dpi()
	fingerprint["locale"] = OS.get_locale()
	fingerprint["timezone"] = Time.get_time_zone_from_system().get_bias_minutes()
	fingerprint["user_agent"] = _get_user_agent()
	fingerprint["hash"] = _hash(fingerprint)
	return fingerprint

static func _get_user_agent() -> String:
	if LauncherCommons.isWeb:
		var js : JavaScriptBridge = JavaScriptBridge.get_interface("ShambletaFingerprint")
		if js and js.has_method("get_user_agent"):
			return js.get_user_agent()
	return ""

static func _hash(data : Dictionary) -> String:
	var json : String = JSON.stringify(data)
	var hash : int = 0
	for i in range(json.length()):
		hash = ((hash << 5) - hash) + json.ord_at(i)
		hash = hash & hash
	return str(hash)
