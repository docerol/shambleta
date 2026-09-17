extends WindowPanel

# SOM-IDLE Fase C: janela do passe de temporada (BATTLE_PASS_S1). Trilhas
# grátis/premium lado a lado por nível claimável, missões do período com
# progresso server-side e botões BuyPass/Skip. Tudo dinâmico a partir do
# SeasonPassState; ações voltam como PassFeedback + estado fresco.
@onready var headerLabel : Label = $Layout/Header
@onready var trackBox : VBoxContainer = $Layout/TrackScroll/TrackList
@onready var missionBox : VBoxContainer = $Layout/MissionScroll/MissionList
@onready var buyPassButton : Button = $Layout/BuyPass
@onready var buyDeluxeButton : Button = $Layout/BuyDeluxe
@onready var skipButton : Button = $Layout/SkipLevel

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshPass()

func _on_visibility_changed():
	if is_visible():
		RefreshPass()

func RefreshPass():
	ShowSeasonPass(NetClient.LastSeasonPass)
	Network.GetSeasonPass()

func ShowSeasonPass(state : Dictionary):
	for c in trackBox.get_children():
		c.queue_free()
	for c in missionBox.get_children():
		c.queue_free()
	if state.is_empty() or not bool(state.get("ok", false)):
		headerLabel.text = "Season pass: %s" % str(state.get("reason", "no season"))
		buyPassButton.disabled = true
		buyDeluxeButton.disabled = true
		skipButton.disabled = true
		return
	var premium : bool = int(state.get("premium", 0)) == 1
	var dbl : String = " · 2× PT!" if bool(state.get("double_xp", false)) else ""
	headerLabel.text = "Season #%d — L%d (%d PT)%s · %s" % [
		int(state.get("season_id", 0)), int(state.get("level", 0)),
		int(state.get("pt", 0)), dbl, "PREMIUM" if premium else "free track"]
	buyPassButton.disabled = premium
	buyPassButton.text = "Premium owned" if premium else "Buy premium — R$ 24,90"
	buyDeluxeButton.disabled = premium
	buyDeluxeButton.text = "Premium owned" if premium else "Buy deluxe — R$ 44,90"
	var skips : int = int(state.get("skips_used", 0))
	var skipsMax : int = int(state.get("skips_max", 10))
	skipButton.disabled = skips >= skipsMax
	skipButton.text = "Skip level — 50 gems (%d/%d)" % [skips, skipsMax]
	for lvl in state.get("free_claimable", []):
		trackBox.add_child(_claim_button("Free L%d" % int(lvl), int(lvl), "free"))
	for lvl in state.get("premium_claimable", []):
		trackBox.add_child(_claim_button("Premium L%d" % int(lvl), int(lvl), "premium"))
	if trackBox.get_children().is_empty():
		var none := Label.new()
		none.text = "No rewards to claim — earn PT from missions below."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		trackBox.add_child(none)
	_add_missions("Dailies", state.get("dailies", []))
	_add_missions("Weeklies", state.get("weeklies", []))
	_add_missions("Milestones", state.get("milestones", []))

func _claim_button(text : String, level : int, track : String) -> Button:
	var b := Button.new()
	b.text = "Claim %s" % text
	b.pressed.connect(func() -> void: Network.ClaimPassReward(level, track))
	return b

func _add_missions(title : String, missions : Array):
	var header := Label.new()
	header.text = title
	missionBox.add_child(header)
	for m in missions:
		if not (m is Dictionary):
			continue
		var done : bool = int(m.get("progress", 0)) >= int(m.get("goal", 1))
		var claimed : bool = int(m.get("claimed", 0)) == 1
		var row := Button.new()
		row.text = "%s — %d/%d PT%s%s" % [str(m.get("label", "?")),
			int(m.get("progress", 0)), int(m.get("goal", 1)),
			" · claimed" if claimed else (" · CLAIM" if done else "")]
		row.disabled = claimed or not done
		if done and not claimed:
			var mid : String = str(m.get("id", ""))
			row.pressed.connect(func() -> void: Network.ClaimMission(mid))
		missionBox.add_child(row)

func _on_buy_pass_pressed():
	Network.BuyPass("standard")

func _on_buy_deluxe_pressed():
	Network.BuyPass("deluxe")

func _on_skip_level_pressed():
	Network.SkipPassLevel()
