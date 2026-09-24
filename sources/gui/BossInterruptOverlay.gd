extends Control
class_name BossInterruptOverlay

# SOM-IDLE: overlay do duelo de boss (botão de interrupt + flash de recompensa
# + banner de qualidade do timing). Extraído de Gui.gd para manter o HUD dentro
# do teto do gate anti-god-node (800 linhas) — a delegação fica em Gui via
# ShowBossInterruptWindow / ShowBossInterruptFeedback / FlashOverlay.
#
# Renderiza como camada cheia (full rect) com mouse_filter IGNORE: só o botão
# interno recebe toque (toque na tela fora do botão jamais envia interrupt).

var _button : Button = null
var _flashRect : ColorRect = null
var _notification : Control = null		# Notification.gd (AddNotification via duck)

# SOM-IDLE: ping de abertura da janela (o jogador toca no "go" — sem áudio o
# timing vira jogo de olhos; o banner chega tarde demais p/ telegrafar).
const WindowOpenSfx : AudioStream = preload("res://data/sounds/alteration/skillup.ogg")
var _cuePlayer : AudioStreamPlayer = null

func Setup(notification : Control):
	_notification = notification
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100

	_button = Button.new()
	_button.name = "BossInterrupt"
	_button.text = "⚡ INTERRUPTAR"
	_button.visible = false
	_button.custom_minimum_size = Vector2(220, 64)
	_button.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_button.offset_left = -110
	_button.offset_right = 110
	_button.offset_top = -150
	_button.offset_bottom = -86
	_button.pressed.connect(_on_pressed)
	add_child(_button)

func SetWindowVisible(open : bool):
	if _button:
		_button.visible = open
	if open:
		_PlayWindowCue()

# Veredito do toque: banner colorido pela qualidade do timing.
func ShowFeedback(quality : String, mult : float):
	if _notification == null:
		return
	match quality:
		"perfect":
			_notification.AddNotification("[color=#ffd24a]⚡ INTERRUPT PERFEITO! ×%.2f[/color]" % mult, 1.2)
			Flash(Color(1.0, 0.85, 0.3, 0.25))
		"good":
			_notification.AddNotification("[color=#7be07b]✦ Interrupt bom ×%.2f[/color]" % mult, 1.0)
		_:
			_notification.AddNotification("[color=#9a9a9a]Interrupt errou a janela[/color]", 0.8)

# Pulso de tela (hit-stop barato): ColorRect translúcido que some em ~0.3s.
func Flash(color : Color):
	if _flashRect == null or not is_instance_valid(_flashRect):
		_flashRect = ColorRect.new()
		_flashRect.name = "RewardFlash"
		_flashRect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_flashRect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_flashRect)
	var t : Tween = create_tween()
	var endAlpha : float = color.a
	color.a = 0.0
	_flashRect.color = color
	t.tween_property(_flashRect, "color:a", endAlpha, 0.06)
	t.tween_property(_flashRect, "color:a", 0.0, 0.22)

func _on_pressed():
	Network.BossInterrupt()

func _PlayWindowCue():
	if _cuePlayer == null or not is_instance_valid(_cuePlayer):
		_cuePlayer = AudioStreamPlayer.new()
		_cuePlayer.bus = ActorCommons.SfxAlterationBus
		add_child(_cuePlayer)
	_cuePlayer.set_stream(WindowOpenSfx)
	_cuePlayer.play()
