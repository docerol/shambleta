# SOM-IDLE i18n: runtime translation pass.
# Godot 4 does NOT auto-translate Control.text set by scenes or code (verified
# in 4.7), and this client sets most labels directly (presets/gui/*.tscn plus a
# handful of `text = "..."` in .gd). Instead of touching every window script,
# one periodic pass walks the GUI tree and translates the *static* text
# properties via the ui.csv table, stashing the original in node metadata so
# the pass is idempotent and locale changes re-translate correctly:
#   - text never seen          -> stash original, show tr(original)
#   - text still equals output -> re-run tr(original) (catches locale changes)
#   - app changed the text     -> rebase the stash (dynamic strings like
#     "5 gems" or player names simply miss the table and echo unchanged —
#     tr() on a non-key returns the input, so the pass is always safe).
# Not covered (accepted for phase 1 / polimento UI/UX — documentado):
# OptionButton item labels and TabContainer tab titles (item APIs, not properties).
# Logged as leftover in archive/I18N_PHASE1_REPORT.md; aceito como gap residual.
extends Node
class_name Localizer

const Props : Array[String] = ["text", "title", "placeholder_text"]
const MetaPrefix : String = "som_i18n_"

var _elapsed : float = 0.0
const Interval : float = 1.0

func _ready() -> void:
	set_process(true)

func _process(delta : float) -> void:
	_elapsed += delta
	if _elapsed < Interval:
		return
	_elapsed = 0.0
	Apply(get_parent())

# Resolve the persisted selector value ("auto"/"en"/"pt_BR") to a concrete
# locale. "auto" follows the OS, exactly like Godot's untouched default.
static func ResolveLocale(setting : String) -> String:
	if setting.is_empty() or setting == "auto":
		return OS.get_locale()
	return setting

# Translates node and all descendants. Safe to call any number of times.
static func Apply(node : Node) -> void:
	for child in node.get_children():
		_applyNode(child)
		Apply(child)

static func _applyNode(node : Node) -> void:
	var control : Control = node as Control
	if control == null:
		return
	for prop in Props:
		if not prop in control:
			continue
		var current : String = control.get(prop)
		if current.is_empty():
			continue
		var meta : String = MetaPrefix + prop
		var original : String
		if control.has_meta(meta):
			var stash : Array = control.get_meta(meta)
			original = stash[0]
			if current != stash[1]:
				# the app replaced the text: rebase (dynamic content passes through)
				original = current
		else:
			original = current
		var out : String = node.tr(original)
		control.set_meta(meta, [original, out])
		if out != current:
			control.set(prop, out)
