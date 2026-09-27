extends RefCounted
class_name GuildPanelRows

# As fileiras de entrada do `GuildPanel`, montadas em código (o painel é usado tanto
# pela cena `presets/gui/GuildPanel.tscn` quanto por `.new()` em teste headless — é
# o mesmo padrão de Activities/Checkout). Separar daqui é o que deixa o painel decidir
# O QUE cada botão faz em vez de escrever 150 linhas de `.new()` + `.name =` no meio
# do `_ready`.
#
# Nada aqui conhece regra de guilda. O que sai é nó pronto, com os MESMOS nomes que a
# cena e os harnesses procuram (`Layout/Info`, `ConfirmRow`, `GuildChatSend`, …),
# porque quem confere esta UI é a árvore real: `tests/hud_wiring_test.gd` lê nós e
# `tests/panel_fit_test.gd` mede retângulos.

static func LabelOf(parent : Node, nodeName : String, text : String) -> Label:
	var label := Label.new()
	label.name = nodeName
	label.text = text
	parent.add_child(label)
	return label

static func Header(parent : Node, nodeName : String, text : String, fontSize : int) -> Label:
	var label := LabelOf(parent, nodeName, text)
	label.add_theme_font_size_override("font_size", fontSize)
	return label

# Rótulo de seção + ScrollContainer + VBox de itens; devolve o VBox, que é onde a
# lista entra. A altura mínima é o que mantém a seção visível mesmo vazia — sem ela
# o painel "encolhe" para nada e o jogador não vê onde colocar o olho.
static func ScrollSection(parent : Node, title : String, minHeight : int) -> VBoxContainer:
	# `_LabelOf` já pendura no pai: add_child de novo seria "already has a parent".
	LabelOf(parent, title + "Header", title)
	var scroll := ScrollContainer.new()
	scroll.name = title + "Scroll"
	scroll.custom_minimum_size = Vector2(0, minHeight)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	var box := VBoxContainer.new()
	box.name = title + "List"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box

# Um campo + um botão. Criar, buscar e o chat da guilda são o mesmo retângulo com
# nomes diferentes. `maxLength > 0` prende o campo ao teto do servidor
# (`NetworkCommons.ChatMaxSize`): limite de tamanho é regra de quem recebe, a caixa
# só repete. `onSubmit` inválido = campo sem Enter ligado (o campo de nome era assim).
static func EditRow(parent : Node, rowName : String, editName : String, placeholder : String,
		buttonName : String, buttonText : String, onSubmit : Callable, onPress : Callable,
		maxLength : int = 0) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = rowName
	parent.add_child(row)
	var edit := LineEdit.new()
	edit.name = editName
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if maxLength > 0:
		edit.max_length = maxLength
	if onSubmit.is_valid():
		edit.text_submitted.connect(onSubmit)
	row.add_child(edit)
	var button := Button.new()
	button.name = buttonName
	button.text = buttonText
	button.pressed.connect(onPress)
	row.add_child(button)
	return {"row": row, "edit": edit, "button": button}

# Campos de depósito: item, quantidade e o botão. A caixa de quantidade é estreita
# de propósito — largura é o eixo em que a cerca de geometria NÃO deixa rolar, e foi
# uma linha de inputs larga que empurrou o botão "Deposit" para fora da janela.
static func DepositRow(parent : Node, onDeposit : Callable) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "DepositRow"
	parent.add_child(row)
	var item := LineEdit.new()
	item.name = "DepositItemEdit"
	item.placeholder_text = "item id"
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(item)
	var count := LineEdit.new()
	count.name = "DepositCountEdit"
	count.text = "1"
	count.custom_minimum_size = Vector2(60, 0)
	row.add_child(count)
	var button := Button.new()
	button.name = "DepositButton"
	button.text = "Deposit to vault"
	button.pressed.connect(onDeposit)
	row.add_child(button)
	return {"row": row, "item": item, "count": count, "button": button}

# Fileira de botões: `specs` = [[nodeName, text, onPress], …]. Os dois gastos de gems
# vivem numa linha e "Leave" em outra — um botão sozinho na fileira não briga por
# largura com os de cima. Devolve {"row":…, "buttons": nodeName → Button}.
static func ButtonRow(parent : Node, rowName : String, specs : Array) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = rowName
	parent.add_child(row)
	var byName : Dictionary = {}
	for spec in specs:
		var entry : Array = spec
		var button := Button.new()
		button.name = str(entry[0])
		button.text = str(entry[1])
		button.pressed.connect(entry[2] as Callable)
		row.add_child(button)
		byName[str(entry[0])] = button
	return {"row": row, "buttons": byName}

# Espelho da prévia de gasto para quando o modal da casa não existe (HUD ainda
# montando). Nasce escondido: arma no `_Arm` do painel e some no confirm/cancel.
static func ConfirmRow(parent : Node, onConfirm : Callable, onCancel : Callable) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "ConfirmRow"
	row.visible = false
	parent.add_child(row)
	var text := LabelOf(row, "ConfirmText", "")
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var confirm := Button.new()
	confirm.name = "ConfirmButton"
	confirm.text = "Confirm"
	confirm.pressed.connect(onConfirm)
	row.add_child(confirm)
	var abort := Button.new()
	abort.name = "CancelButton"
	abort.text = "Cancel"
	abort.pressed.connect(onCancel)
	row.add_child(abort)
	return {"row": row, "label": text}

static func Clear(box : Node) -> void:
	if box == null:
		return
	for child in (box as Node).get_children():
		box.remove_child(child)
		child.queue_free()
