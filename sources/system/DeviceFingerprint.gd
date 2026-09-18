extends RefCounted
class_name DeviceFingerprint

# SOM-IDLE S5: device fingerprint for multi-account detection.
# Collects anonymous device identifiers to detect multi-account abuse.
# Does NOT collect personal information — only hardware/software hashes.

static func Collect() -> Dictionary:
	var fingerprint : Dictionary = {}
	fingerprint["platform"] = OS.get_name()
	fingerprint["version"] = OS.get_version()
	# SOM-IDLE parser: OS.get_model() não existe neste target — fallback
	# para o nome da plataforma (hash opaco; só precisa ser estável).
	fingerprint["arch"] = OS.get_processor_name() if OS.has_feature("pc") else OS.get_name()
	fingerprint["screen"] = "%dx%d" % [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y]
	fingerprint["dpi"] = DisplayServer.screen_get_dpi()
	fingerprint["locale"] = OS.get_locale()
	# SOM-IDLE parser: get_time_zone_from_system() devolve Dictionary
	# (chave "bias"), não um objeto com método.
	fingerprint["timezone"] = int(Time.get_time_zone_from_system().get("bias", 0))
	fingerprint["user_agent"] = _get_user_agent()
	fingerprint["hash"] = _hash(fingerprint)
	return fingerprint

static func _get_user_agent() -> String:
	if LauncherCommons.isWeb:
		var js = JavaScriptBridge.get_interface("ShambletaFingerprint")
		if js and js.has_method("get_user_agent"):
			return js.get_user_agent()
	return ""

static func _hash(data : Dictionary) -> String:
	# SOM-IDLE parser: String.ord_at() não existe neste build — hash opaco
	# via String.hash() (estável por conteúdo; muda vs. versão anterior, o
	# que só invalida matches com telemetria antiga, sem quebrar nada).
	return str(JSON.stringify(data).hash())
