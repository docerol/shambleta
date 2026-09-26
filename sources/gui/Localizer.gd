# SOM-IDLE i18n: runtime translation pass.
# Godot 4 does NOT auto-translate Control.text set by scenes or code (verified
# in 4.7), and this client sets most labels directly (presets/gui/*.tscn plus a
# handful of `text = "..."` in .gd). Instead of touching every window script,
# the pass translates the *static* text properties via the ui.csv table, stashing
# the original in node metadata so it is idempotent and locale changes
# re-translate correctly:
#   - text never seen          -> stash original, show tr(original)
#   - text still equals output -> nothing to do (the fast path, allocation free)
#   - app changed the text     -> rebase the stash (dynamic strings like
#     "5 gems" or player names simply miss the table and echo unchanged —
#     tr() on a non-key returns the input, so the pass is always safe).
#   - the stash generation moved (locale change) -> re-translate the original
# Event driven, no periodic full-tree sweep:
#   - a node created inside the GUI tree is translated on SceneTree.node_added
#     (unpruned: visibility is not settled yet at that point)
#   - boot and locale changes ask for one full pass through _pendingPass
#   - text the app assigns behind our back emits no signal at all, so a slow
#     fallback pass re-checks the VISIBLE tree only: a hidden Control prunes its
#     whole subtree, children are indexed instead of get_children() (which
#     allocates one Array per call) and a node whose text did not move writes no
#     metadata. Steady state therefore allocates nothing per second.
# Not covered (accepted for phase 1 / polimento UI/UX — documentado):
# OptionButton item labels and TabContainer tab titles (item APIs, not properties).
# Logged as leftover in archive/I18N_PHASE1_REPORT.md; aceito como gap residual.
extends Node
class_name Localizer

const MetaPrefix : String = "som_i18n_"
# [property, metadata key] — the metadata name is precomputed because the pass
# runs once per tracked property per node, and `MetaPrefix + prop` there is an
# allocation. Kept in one table so a property can never be out of step with its
# metadata key.
const TrackedProps : Array[Array] = [
	["text", MetaPrefix + "text"],
	["title", MetaPrefix + "title"],
	["placeholder_text", MetaPrefix + "placeholder_text"],
]

# Fallback cadence of the visible-only pass, for text code assigns directly
# (`label.text = "Next"`). Same latency budget the old sweep had; the walk is
# what got cheaper.
const Interval : float = 1.0

# The longest key in data/i18n/ui.csv measures 257 characters, so anything past
# this budget cannot be a table key. Skipping it also keeps tr() from interning
# a huge StringName (an unbounded chat pane passes 10 KB easily), which is a
# permanent allocation.
const MaxStaticTextLength : int = 1024

# Bumped on every locale change so stashes written under another locale are
# recomputed instead of being mistaken for "nothing changed".
static var generation : int = 0

var _elapsed : float = 0.0
var _pendingPass : bool = false
var _root : Node = null

func _ready() -> void:
	set_process(true)
	_root = get_parent()
	var tree : SceneTree = get_tree()
	if tree:
		tree.node_added.connect(_onNodeAdded)
	# Scene-authored text entered the tree before the signal above existed.
	_pendingPass = true

# The engine posts this to every node when the locale changes (and once when the
# node enters the tree); TranslationServer has no signal to connect to.
func _notification(what : int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		generation += 1
		_pendingPass = true

func _process(delta : float) -> void:
	_elapsed += delta
	if _pendingPass:
		_pendingPass = false
		_elapsed = 0.0
		if _root:
			ApplySubtree(_root)
		return
	if _elapsed < Interval:
		return
	_elapsed = 0.0
	if _root:
		ApplyVisible(_root)

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

# Same reach as Apply(), including the node itself, without allocating the
# per-node child array. Used by the boot/locale pass and by fresh nodes.
static func ApplySubtree(node : Node) -> void:
	_applyNode(node)
	for childIdx in node.get_child_count():
		ApplySubtree(node.get_child(childIdx))

# Recurring walk: skips what the player cannot see. A hidden Control hides its
# whole subtree; a Window (Popup/AcceptDialog) draws over its parent regardless
# of the parent's visibility, so only a hidden Window prunes.
static func ApplyVisible(node : Node) -> void:
	for childIdx in node.get_child_count():
		_applyVisible(node.get_child(childIdx), false)

static func _applyVisible(node : Node, insideWindow : bool) -> void:
	var window : Window = node as Window
	if window != null:
		if not window.visible:
			return
		insideWindow = true
	elif not insideWindow:
		var control : Control = node as Control
		if control != null and not control.is_visible_in_tree():
			return
	_applyNode(node)
	for childIdx in node.get_child_count():
		_applyVisible(node.get_child(childIdx), insideWindow)

static func _applyNode(node : Node) -> void:
	var control : Control = node as Control
	if control == null:
		return
	for tracked in TrackedProps:
		var prop : String = tracked[0]
		if not prop in control:
			continue
		var current : String = control.get(prop)
		if current.is_empty() or current.length() > MaxStaticTextLength:
			continue
		var meta : String = tracked[1]
		var trackedBefore : bool = control.has_meta(meta)
		var original : String = current
		if trackedBefore:
			var stash : Array = control.get_meta(meta)
			if current == stash[1] and stash[2] == generation:
				continue
			if current == stash[1]:
				# same text, new locale: keep translating the stashed original
				original = stash[0]
		var out : String = node.tr(original)
		if out != current:
			control.set_meta(meta, [original, out, generation])
			control.set(prop, out)
		elif not trackedBefore:
			control.set_meta(meta, [original, out, generation])

# A node entering the GUI tree already carries its text, so translating it here
# drops the up-to-Interval lag the old sweep had for runtime built panels. The
# ancestry gate keeps the reach the old sweep had (the GUI tree) and skips world
# nodes; visibility is not settled yet at this point, hence the unpruned walk.
# SceneTree.node_added carries the node only (verified against 4.7: a second
# parameter here errors at emit time on every node the game creates).
func _onNodeAdded(node : Node) -> void:
	if _root == null or not _root.is_ancestor_of(node):
		return
	ApplySubtree(node)
