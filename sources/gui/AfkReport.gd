extends WindowPanel

# SOM-IDLE onboarding: AFK Report — último settle (preenchido pelo handler
# NetClient.AFKReport; auto-abre ao coletar). Somente leitura, exceto o
# rewarded ad da Fase E (arma 2×/4× na próxima coleta, 1×/liquidação).
const AdProvider = preload("res://sources/ads/AdProvider.gd")
@onready var hoursLabel : Label = $Layout/Hours
@onready var xpLabel : Label = $Layout/XP
@onready var goldLabel : Label = $Layout/Gold
@onready var dropsLabel : Label = $Layout/Drops
@onready var chestsLabel : Label = $Layout/Chests
@onready var effLabel : Label = $Layout/Efficiency
@onready var adHintLabel : Label = $Layout/AdHint
@onready var doubleAdButton : Button = $Layout/DoubleAd

func _ready():
	if NetClient.LastAFKReport.is_empty():
		Network.GetAFKReport()
	else:
		ShowReport(NetClient.LastAFKReport)

func ShowReport(report : Dictionary):
	if report.is_empty():
		return
	hoursLabel.text = tr("Away: %.1fh") % float(report.get("hours", 0.0))
	var doubled : bool = bool(report.get("doubled", false))
	var tag : String = " (2× AD!)" if doubled else ""
	xpLabel.text = tr("+%s XP") % Util.FormatNumber(int(report.get("xp_earned", 0))) + tag
	goldLabel.text = tr("+%s gold") % Util.FormatNumber(int(report.get("gold_earned", 0))) + tag
	var drops : Dictionary = report.get("drops", {})
	var dropTotal : int = 0
	for itemHash in drops:
		dropTotal += int(drops[itemHash])
	dropsLabel.text = tr("Drops: %d") % dropTotal + tag
	chestsLabel.text = tr("Chests: %d") % int(report.get("chests", 0))
	effLabel.text = tr("Efficiency: %d%%") % int(float(report.get("efficiency", 1.0)) * 100.0)
	if bool(report.get("armed", false)) and not doubled:
		adHintLabel.text = tr("2× ad armed — applies on Collect (4× with VIP)")
		doubleAdButton.disabled = true
	else:
		adHintLabel.text = ""
		doubleAdButton.disabled = false

func _on_collect_pressed():
	Network.ClaimOfflineSettle()

func _on_double_ad_pressed():
	if not AdProvider.IsReady("afk2x"):
		return
	doubleAdButton.disabled = true
	Network.WatchAd("afk2x", AdProvider.ShowStub("afk2x"))
