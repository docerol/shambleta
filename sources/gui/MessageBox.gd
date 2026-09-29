extends PanelContainer

#
@onready var label : Label						= $Margin/VBoxContainer/Label
@onready var buttonBox : Control				= $Margin/VBoxContainer/ButtonBoxes

var wasActionEnabled : bool						= true

#
func Display(text : String, primary = null, primaryText : String = "", cancel = null, cancelText : String = "", secondary = null, secondaryText : String = "", tertiary = null, tertiaryText : String = ""):
	wasActionEnabled = Launcher.Action.IsEnabled()
	if wasActionEnabled:
		Launcher.Action.Enable(false)

	label.set_text(text)
	if primary and primary is Callable:			buttonBox.Bind(UICommons.ButtonBox.PRIMARY, primaryText, Call.bind(primary))
	if cancel and cancel is Callable:			buttonBox.Bind(UICommons.ButtonBox.CANCEL, cancelText, Call.bind(cancel))
	if secondary and secondary is Callable:		buttonBox.Bind(UICommons.ButtonBox.SECONDARY, secondaryText, Call.bind(secondary))
	if tertiary and tertiary is Callable:		buttonBox.Bind(UICommons.ButtonBox.TERTIARY, tertiaryText, Call.bind(tertiary))
	_fitToHost()
	set_visible(true)
	buttonBox.TrapFocus()
	buttonBox.Focus.call_deferred(UICommons.ButtonBox.PRIMARY)

func Clear():
	if  wasActionEnabled:
		Launcher.Action.Enable(true)

	set_visible(false)
	buttonBox.ReleaseFocus()
	buttonBox.ClearAll()
	label.set_text("")

# O diálogo global de confirmar/cancelar tem que caber no aparelho: a largura é
# limitada à do host (nada de pixel de cena) e a linha de decisão reencaixa com o
# piso de toque que o produto declara em `GuiUiScale.DecisionTouchPx()`. No desktop
# o host é largo: `FitDecisionRow` não aperta, o mínimo volta ao de cena e a caixa
# fica exatamente onde a cena a desenhou. Idempotente via meta `baseMin`.
func _fitToHost() -> void:
	var host : Control = get_parent() as Control
	if host == null or buttonBox == null:
		return
	var hostRect : Rect2 = host.get_global_rect()
	# O que sobra para o CONTEÚDO não é o host menos um número chutado: é o host menos
	# o chrome que o próprio tema come. Medido no telefone de 390 px: a variação
	# `MessageBox` usa `StyleBoxTexture_5wphw` de `data/themes/DefaultTheme.tres`, que não
	# declara `content_margin` e sim `texture_margin_left = texture_margin_right = 61` —
	# e margin negativo NÃO é zero, é "usa a borda da textura" (9-patch). São 122 px de
	# borda + 10 px do `MarginContainer` da cena: com `room = host - 24` a linha recebia
	# 356 px para usar em 390, o painel fechava em 478 (346 da linha + 132 de chrome) e a
	# última decisão saía 22 px fora do aparelho.
	var chrome : float = 0.0
	var panelBox : StyleBox = get_theme_stylebox("panel")
	if panelBox != null:
		var chromeL : float = maxf(0.0, panelBox.content_margin_left)
		var chromeR : float = maxf(0.0, panelBox.content_margin_right)
		if panelBox is StyleBoxTexture:
			var texBox : StyleBoxTexture = panelBox as StyleBoxTexture
			if chromeL <= 0.0:
				chromeL = maxf(0.0, texBox.texture_margin_left)
			if chromeR <= 0.0:
				chromeR = maxf(0.0, texBox.texture_margin_right)
		chrome += chromeL + chromeR
	var marginNode : MarginContainer = get_node_or_null("Margin") as MarginContainer
	if marginNode != null:
		chrome += float(marginNode.get_theme_constant("margin_left")) + float(marginNode.get_theme_constant("margin_right"))
	var room : float = hostRect.size.x - chrome
	if room <= 0.0:
		return
	if not has_meta("baseMin"):
		set_meta("baseMin", custom_minimum_size)
	if not has_meta("baseLabelMin"):
		set_meta("baseLabelMin", label.custom_minimum_size)
	var base : Vector2 = get_meta("baseMin") as Vector2
	var baseLabel : Vector2 = get_meta("baseLabelMin") as Vector2
	# `custom_minimum_size` é a largura TOTAL do painel, e o mínimo total que o motor
	# impõe é `conteúdo + chrome` — por isso o teto aqui é o host inteiro, não a sala do
	# conteúdo: apertar o painel para `room` deixaria sempre os 122 px de chrome por fora
	# e o mínimo de conteúdo nunca seria alcançado.
	custom_minimum_size = Vector2(minf(base.x, hostRect.size.x), base.y)
	# O aperto tem que vir de dentro, não de fora: o MÍNIMO de um `Label` com autowrap é
	# medido sobre a largura que o rótulo tem naquele instante — com o painel ainda no
	# tamanho de cena (550), um texto de 36 caracteres reportava 468 px de mínimo e a
	# caixa nascia em 478 num aparelho de 390. `size = Vector2(room, …)` não derruba o
	# próprio mínimo (o motor clampa de volta). Declarar a sala do conteúdo no rótulo faz
	# o autowrap reencaixar sobre ela, e a linha de decisão é chamada com a MESMA sala:
	# quatro decisões de 346 px não cabem em 258, e `FitDecisionRow` empilha a linha.
	label.custom_minimum_size = baseLabel
	if base.x > hostRect.size.x:
		label.custom_minimum_size = Vector2(room, baseLabel.y)
	GuiUiScale.FitDecisionRow(buttonBox, room)
	reset_size()
	_centerInHost()

# Recentraliza com o tamanho que o painel TEM. O tamanho final só é conhecido depois
# do layout (a linha empilhada reescreve a altura), e centrar com o tamanho velho
# deixava a caixa fora do aparelho. O `NOTIFICATION_RESIZED` é o instante em que o
# tamanho é verdadeiro, e o clamp é idempotente — por isso ele roda nos dois caminhos
# sem brigar consigo mesmo.
func _centerInHost() -> void:
	var host : Control = get_parent() as Control
	if host == null:
		return
	var hostRect : Rect2 = host.get_global_rect()
	var centered : Vector2 = hostRect.get_center() - size * 0.5
	global_position = Vector2(clampf(centered.x, hostRect.position.x, maxf(hostRect.position.x, hostRect.end.x - size.x)),
			clampf(centered.y, hostRect.position.y, maxf(hostRect.position.y, hostRect.end.y - size.y)))

func _notification(what : int) -> void:
	if what == NOTIFICATION_RESIZED:
		_centerInHost()

func Call(callback : Callable):
	Clear()
	callback.call()
