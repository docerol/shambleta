extends WindowPanel

# SOM-IDLE onboarding + SOM-GAMEPLAY G1 (juiz cego 2026-09-27): este painel era um
# editor de UMA skill por slot (`PackedInt64Array([skillID])`), enquanto o motor de
# cast decide por uma ORDEM (SkillPriority) e o único jeito de declarar essa ordem
# era digitar `/priority` no chat. O painel agora declara a ordem inteira.
#
# E continua sem ser autoridade: a ordem NÃO é gravada por `SetFormation` (esse RPC
# é a escrita bruta da linha de formação, sem Trim). Ela sai como a MESMA mensagem
# que o jogador digitava — `priority [slot <n>] set <id> ...` — pelo MESMO RPC do
# chat (`TriggerCommand`) e pelo MESMO despachante (`CommandManager.Handle` →
# `WorldCommands.CommandPriority`), que no servidor resolve a conta pelo PEER
# (o painel não nomeia personagem nenhum nessa ponta), descarta o que o char não
# aprendeu, aplica o teto e só então persiste + aplica ao vivo.
#
# Formato do fio: sem a barra inicial. Chat.gd:147 a corta antes de enviar
# (`trim_prefix("/")`) e CommandManager.Handle procura o nome sem ela.

# Costura da casa (mesma de AuctionHousePanel/Chests/Shop): o harness injeta
# `SendHook` e MEDe cada envio; sem hook, `_Send` cai no RPC real de `Network`.
var SendHook : Callable

# Costura irmã para a LISTA DE CANDIDATAS (o cardápio de cliques). Em produção é a
# sessão viva; o hook existe porque `Launcher.Player` é tipado `Entity` (Launcher.gd:28,
# atribuído em Map.gd:123) e um harness `-s` não tem entidade de mapa para injetar.
# Isto NÃO é autoridade: é só o que vale um clique. O que entra na carga é decidido
# por `SkillPriority.Trim` no servidor, na ponta do `TriggerCommand`.
var CandidateProvider : Callable

# Ordem DECLARADA por slot, espelho do que o painel enviou — não fonte da verdade.
# O protocolo não tem RPC de leitura de carga, então abrir o painel pede
# `priority slot <n>`: o ramo `list` devolve no chat a carga EFETIVA que o
# servidor gravou (depois do Trim), que é o único "estado do mundo" honesto aqui.
var _orders : Dictionary = {}
var _slot : int = 0
var _selected : int = -1
var charID : int = 0
var potionPct : float = 35.0

@onready var slotOption : OptionButton = $Layout/SlotRow/Slot
@onready var charLabel : Label = $Layout/CharRow/CharName
@onready var skillOption : OptionButton = $Layout/SkillRow/Skill
@onready var addButton : Button = $Layout/SkillRow/AddSkill
@onready var potionSlider : HSlider = $Layout/PotionRow/Potion
@onready var potionLabel : Label = $Layout/PotionRow/PotionPct
@onready var skinLabel : Label = $Layout/SkinRow/Skin
@onready var priorityTitle : Label = $Layout/PriorityTitle
@onready var priorityList : VBoxContainer = $Layout/PriorityList
@onready var upButton : Button = $Layout/PriorityControls/Up
@onready var downButton : Button = $Layout/PriorityControls/Down
@onready var removeButton : Button = $Layout/PriorityControls/Remove
@onready var clearButton : Button = $Layout/PriorityControls/Clear

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	for slotIndex in IdlePolicyService.MaxFormationSlots:
		slotOption.add_item("Slot %d" % slotIndex, slotIndex)
	potionSlider.value_changed.connect(_on_potion_changed)
	if is_visible():
		RefreshFormation()

func _on_visibility_changed():
	if is_visible():
		RefreshFormation()

func _on_potion_changed(value : float):
	potionPct = clampf(value, 0.0, 100.0)
	if potionLabel:
		potionLabel.text = "%d%%" % int(potionPct)

func RefreshFormation():
	if Launcher.Player:
		charLabel.text = str(Launcher.Player.nick) if str(Launcher.Player.nick) != "" else "?"
		charID = int(Launcher.Player.characterID)
	ShowSkin(NetClient.LastCosmetics)
	Network.GetCosmetics()
	RequestPriority()
	RefreshPriorityRows()

# Fase D: skin de formação equipada (rótulo; o sprite é follow-up de arte).
func ShowSkin(data : Dictionary):
	var equipped : Dictionary = data.get("equipped", {})
	var skin : String = str(equipped.get("formation_skin", ""))
	if skinLabel:
		if skin.is_empty():
			skinLabel.text = "Default"
		else:
			var label : String = skin
			for e in data.get("catalog", []):
				if str((e as Dictionary).get("id", "")) == skin:
					label = str((e as Dictionary).get("label", skin))
			skinLabel.text = label
	if skillOption == null:
		return
	skillOption.clear()
	for skillID : int in LearnedSkillIDs():
		var skill : SkillCell = DB.GetSkill(skillID)
		if skill is SkillCell:
			skillOption.add_item(str(skill.name) if str(skill.name) != "" else str(skillID), skillID)
	if skillOption.item_count == 0:
		skillOption.add_item("Melee", SkillCommons.SkillMeleeName.hash())
	if potionSlider:
		potionSlider.value = potionPct
		_on_potion_changed(potionPct)

# ------------------------------------------------------------------ estado da ordem

# Skills que o char aprendeu — a única lista que o painel oferece como candidata
# (o servidor re-confere com SkillPriority.Trim; aqui é só o que vale um clique).
func LearnedSkillIDs() -> Array[int]:
	var source : Variant = null
	if CandidateProvider.is_valid():
		source = CandidateProvider.call()
	elif Launcher.Player and Launcher.Player.progress:
		source = Launcher.Player.progress.skills
	var out : Array[int] = []
	if source is Dictionary:
		for skillID in (source as Dictionary):
			out.append(int(skillID))
	elif source is Array:
		for value : Variant in (source as Array):
			out.append(int(value))
	out.sort()
	return out

func MaxPriority() -> int:
	return SkillPriority.MaxPrioritySkills

func FormationSlot() -> int:
	return _slot

func GetPriorityOrder() -> Array[int]:
	return _orderOf(_slot)

func _orderOf(slot : int) -> Array[int]:
	var out : Array[int] = []
	var raw : Variant = _orders.get(slot, null)
	if raw is Array:
		for value : Variant in (raw as Array):
			out.append(int(value))
	return out

func _storeOrder(slot : int, order : Array[int]):
	_orders[slot] = order

func SelectSlot(slot : int):
	_slot = clampi(slot, 0, IdlePolicyService.MaxFormationSlots - 1)
	_selected = -1
	if slotOption and slotOption.item_count > _slot:
		slotOption.select(_slot)
	RefreshPriorityRows()
	RequestPriority()

func SelectPriority(index : int):
	_selected = index if index >= 0 and index < _orderOf(_slot).size() else -1
	RefreshPriorityRows()

# Anexa ao fim da carga. Recusa o que não foi aprendido, a duplicata e o excesso do
# teto — as mesmas três regras que SkillPriority.Trim aplica no servidor, antes de
# o jogador esperar um round-trip para descobrir que a skill não entrava.
func AddSkillToPriority(skillID : int) -> bool:
	var order : Array[int] = _orderOf(_slot)
	if not (skillID in LearnedSkillIDs()) or skillID in order or order.size() >= SkillPriority.MaxPrioritySkills:
		return false
	order.append(skillID)
	_storeOrder(_slot, order)
	_selected = order.size() - 1
	RefreshPriorityRows()
	return true

func MovePriorityUp(index : int) -> bool:
	return _SwapPriority(index, index - 1)

func MovePriorityDown(index : int) -> bool:
	return _SwapPriority(index, index + 1)

func _SwapPriority(from : int, to : int) -> bool:
	var order : Array[int] = _orderOf(_slot)
	if from < 0 or to < 0 or from >= order.size() or to >= order.size():
		return false
	var held : int = order[from]
	order[from] = order[to]
	order[to] = held
	_storeOrder(_slot, order)
	_selected = to
	RefreshPriorityRows()
	return true

func RemovePriorityAt(index : int) -> bool:
	var order : Array[int] = _orderOf(_slot)
	if index < 0 or index >= order.size():
		return false
	order.remove_at(index)
	_storeOrder(_slot, order)
	_selected = index if index < order.size() else order.size() - 1
	RefreshPriorityRows()
	return true

func ClearPriorityOrder():
	_storeOrder(_slot, [])
	_selected = -1
	RefreshPriorityRows()

# ------------------------------------------------------------------ o que vai para o
# servidor. Separado do envio para o harness afirmar a STRING que o painel produz e
# o que o servidor faz com ela, na mesma ordem.

func BuildPriorityCommand() -> String:
	var order : Array[int] = _orderOf(_slot)
	if order.is_empty():
		return "priority slot %d clear" % _slot
	var tokens : PackedStringArray = PackedStringArray()
	for skillID : int in order:
		tokens.append(str(skillID))
	return "priority slot %d set %s" % [_slot, " ".join(tokens)]

func RequestPriority():
	_Send("TriggerCommand", ["priority slot %d" % _slot])

func SaveLoadout() -> bool:
	var order : Array[int] = _orderOf(_slot)
	# 1) A ORDEM vai pelo caminho que decide (comando do servidor).
	_Send("TriggerCommand", [BuildPriorityCommand()])
	# 2) A linha de formação em si (char + poção automática). Levamos a carga
	#    declarada junto para que o RPC não apague a ordem no mesmo salvamento:
	#    `order` já é saída do mesmo crivo (aprendidas, sem duplicata, teto), e o
	#    servidor ainda re-decide no ramo 1 — se ele cortar algo, a carga efetiva
	#    é a dele, lida em IdlePolicyService._Attach na próxima sessão.
	var loadout : PackedInt64Array = PackedInt64Array()
	for skillID : int in order:
		loadout.append(skillID)
	_Send("SetFormation", [_slot, charID, loadout, potionPct])
	return true

func _on_save_pressed():
	# `charID` vem da sessão viva (RefreshFormation). Sem personagem não existe linha
	# de formação a gravar — e sem linha a ordem declarada não tem para quem ser
	# aplicada, então o clique não sai atirando RPC ao vazio.
	if charID <= 0:
		return
	if not SaveLoadout():
		return

# ------------------------------------------------------------------ controles

func _on_add_slot_pressed():
	if skillOption == null:
		return
	if not AddSkillToPriority(skillOption.get_selected_id()):
		RefreshPriorityRows()

func _on_priority_up_pressed():
	_MoveSelected(-1)

func _on_priority_down_pressed():
	_MoveSelected(1)

func _MoveSelected(delta : int):
	if _selected < 0:
		return
	var moved : bool = MovePriorityUp(_selected) if delta < 0 else MovePriorityDown(_selected)
	if not moved:
		return

func _on_priority_remove_pressed():
	if _selected < 0:
		return
	if not RemovePriorityAt(_selected):
		return

func _on_priority_clear_pressed():
	ClearPriorityOrder()

# ------------------------------------------------------------------ linhas

func RefreshPriorityRows():
	var order : Array[int] = _orderOf(_slot)
	if priorityTitle:
		priorityTitle.text = "Cast order (slot %d) %d/%d" % [_slot, order.size(), SkillPriority.MaxPrioritySkills]
	if upButton:
		upButton.disabled = _selected <= 0
	if downButton:
		downButton.disabled = _selected < 0 or _selected >= order.size() - 1
	if removeButton:
		removeButton.disabled = _selected < 0
	if clearButton:
		clearButton.disabled = order.is_empty()
	if priorityList == null:
		return
	for row : Node in priorityList.get_children():
		priorityList.remove_child(row)
		row.queue_free()
	if order.is_empty():
		var none : Label = Label.new()
		none.text = "1. (none) -> plain melee"
		priorityList.add_child(none)
		return
	for index : int in order.size():
		var row : Button = Button.new()
		row.text = "%d. %s" % [index + 1, _SkillName(order[index])]
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.flat = index != _selected
		row.pressed.connect(_on_priority_row_pressed.bind(index))
		priorityList.add_child(row)

func _on_priority_row_pressed(index : int):
	SelectPriority(index)

func _SkillName(skillID : int) -> String:
	var cell : SkillCell = DB.GetSkill(skillID)
	if cell is SkillCell and str(cell.name) != "":
		return str(cell.name)
	return "skill %d" % skillID

# ------------------------------------------------------------------ envio

func _Send(methodName : String, args : Array):
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	Network.callv(StringName(methodName), args)
