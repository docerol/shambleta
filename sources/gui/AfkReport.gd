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
  if Network and Network.has_method("GetAFKReport"):
    if NetClient.LastAFKReport.is_empty():
      hoursLabel.text = tr("Carregando...")
      goldLabel.text = "—"
      xpLabel.text = "—"
      effLabel.text = "—"
      Network.GetAFKReport()
    else:
      ShowReport(NetClient.LastAFKReport)

func ShowReport(report : Dictionary):
	if report.is_empty():
		return
	# P-B1: polimento visual — cores para valores positivos, destaque de eficiência.
	hoursLabel.text = tr("Away: %.1fh") % float(report.get("hours", 0.0))
	var doubled : bool = bool(report.get("doubled", false))
	var tag : String = " (2× AD!)" if doubled else ""
	# Cores: verde para valores positivos (ganho), amarelo para eficiência alta.
	var xp_val : int = int(report.get("xp_earned", 0))
	xpLabel.text = tr("+%s XP") % Util.FormatNumber(xp_val) + tag
	xpLabel.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2) if xp_val > 0 else Color(0.8, 0.8, 0.8))
	var gold_val : int = int(report.get("gold_earned", 0))
	goldLabel.text = tr("+%s gold") % Util.FormatNumber(gold_val) + tag
	goldLabel.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2) if gold_val > 0 else Color(0.8, 0.8, 0.8))
	var drops : Dictionary = report.get("drops", {})
	var dropTotal : int = 0
	for itemHash in drops:
		dropTotal += int(drops[itemHash])
	dropsLabel.text = tr("Drops: %d") % dropTotal + tag
	chestsLabel.text = tr("Chests: %d") % int(report.get("chests", 0))
	# Eficiência com cor de destaque (amarelo/dourado para alta eficiência).
	var eff_raw : float = float(report.get("efficiency", 1.0))
	var eff_pct : int = int(eff_raw * 100.0)
	var eff_symbol : String = "▲" if eff_pct >= 80 else ("→" if eff_pct >= 50 else "▼")
	effLabel.text = tr("Efficiency: %s %d%%") % [eff_symbol, eff_pct]
	effLabel.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3) if eff_pct >= 80 else (Color(1.0, 0.95, 0.6) if eff_pct >= 50 else Color(0.9, 0.3, 0.2)))
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
	AdProvider.ShowRewarded("afk2x", func(token : String) -> void:
		if token.is_empty():
			doubleAdButton.disabled = false
			return
		Network.WatchAd("afk2x", token))
