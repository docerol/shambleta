# SOM-CRAFT (juiz "Core Loop", 2026-09-28): a forja existia, mas nenhuma tela
# apontava para ela — `grep -i craft sources/gui/` devolvia ZERO e o único caminho
# era o comando de GM `/cs_craft`. O serviço já validava tudo (`CraftCatalog` +
# `ItemForgeService`: budget por (tier, slot), matéria-prima da faixa, taxa de
# submissão, cap diário, fila de aprovação) e o caminho autorizado já estava
# montado — `Network.SubmitCraft` → `Server.SubmitCraft` → `EconomyService.SubmitCraft`
# → `ItemForgeService.SubmitCraft`, que resolve character/account pelo PEER.
#
# Este painel é só a PORTA. Ele não minta item, não calcula resultado e não afirma
# ter material nenhum: o que ele desenha é a leitura do catálogo em runtime, e quem
# cobra insumo, ouro e daily cap continua sendo o servidor. Mintar resultado no
# cliente seria exatamente o que a auditoria chama de "crafting by lying about
# materials".
#
# A submissão não entrega item: vira linha `pending` na fila do GM (`/cs_craft
# approve`), e o veredito chega ao jogador pelo toast de `Client.CraftSubmitFeedback`.
# Como mexe em dois recursos (ouro e matéria-prima), passa pelo portão da casa:
# `RequestCraft()` só ARMA a prévia; `ConfirmPending()` é o único caminho de rede.
#
# Nasce da CENA (`presets/gui/CraftPanel.tscn`), como guilda/leilão/arena: o
# TitleBar da cena é o único botão de fechar no mouse/touch (§13 da auditoria).
extends WindowPanel
class_name CraftPanel

# Único alvo que este painel sabe emitir: o RPC de submissão (mesmo portão de
# nomes de `AuctionHousePanel` — um nome fora da tabela NÃO sai e NÃO entra no
# rastro de envios).
const NetworkTargets : Array[String] = ["SubmitCraft"]

var SendHook : Callable
var SentTargets : Array[String] = []

var _recipes : Array = []
var _modKeys : PackedStringArray = PackedStringArray()
var _pending : Dictionary = {}
var _recipeOption : OptionButton = null
var _modOption : OptionButton = null
var _modValue : SpinBox = null
var _nameEdit : LineEdit = null
var _recipeLabel : Label = null
var _statusLabel : Label = null
var _confirmRow : HBoxContainer = null
var _confirmLabel : Label = null

func _ready():
	name = "Craft"
	custom_minimum_size = Vector2(360, 460)

	var root := VBoxContainer.new()
	root.name = "CraftRoot"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Dentro da cena (TitleBar acima), o corpo entra num ScrollContainer — é o que
	# segura a linha da prévia e os botões dentro da caixa da janela (panel_fit R2).
	# Fora de cena (degradação de harness), segue colado à raiz.
	var host : Node = get_node_or_null("Layout")
	if host != null:
		var scroll := ScrollContainer.new()
		scroll.name = "CraftScroll"
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		host.add_child(scroll)
		scroll.add_child(root)
	else:
		add_child(root)

	var title := _label(root, "Forja")
	title.add_theme_font_size_override("font_size", 18)
	_recipeLabel = _label(root, "Receita: lendo o catálogo...")

	_recipeOption = OptionButton.new()
	_recipeOption.name = "CraftRecipe"
	_recipeOption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipeOption.item_selected.connect(_on_recipe_selected)
	root.add_child(_recipeOption)

	_modOption = OptionButton.new()
	_modOption.name = "CraftModifier"
	_modOption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_modOption)

	_modValue = SpinBox.new()
	_modValue.name = "CraftValue"
	_modValue.min_value = 1.0
	_modValue.max_value = 200.0
	_modValue.value = 5.0
	_modValue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_modValue)

	_nameEdit = LineEdit.new()
	_nameEdit.name = "CraftName"
	_nameEdit.placeholder_text = "Nome do item"
	_nameEdit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_nameEdit)

	_statusLabel = _label(root, "Nada enviado ainda.")

	_confirmRow = HBoxContainer.new()
	_confirmRow.name = "CraftConfirmRow"
	_confirmRow.visible = false
	root.add_child(_confirmRow)
	_confirmLabel = _label(_confirmRow, "")
	_confirmLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var confirm := Button.new()
	confirm.name = "CraftConfirm"
	confirm.text = "Confirmar"
	confirm.pressed.connect(ConfirmPending)
	_confirmRow.add_child(confirm)
	var abort := Button.new()
	abort.name = "CraftAbort"
	abort.text = "Cancelar"
	abort.pressed.connect(CancelPending)
	_confirmRow.add_child(abort)

	var forge := Button.new()
	forge.name = "CraftForgeButton"
	forge.text = "Submeter à forja"
	forge.pressed.connect(_on_forge_pressed)
	root.add_child(forge)
	var refresh := Button.new()
	refresh.name = "CraftRefresh"
	refresh.text = "Reler catálogo"
	refresh.pressed.connect(_on_refresh_pressed)
	root.add_child(refresh)

	Rebuild()

func _label(parent : Node, text : String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l

# ------------------------------------------------------------------ catálogo (leitura)
# Toda a vitrine vem de `CraftCatalog` + `FarmZoneData` + `DB.ItemsDB`, varrida em
# runtime: par (tier, slot) liberado é o que `BudgetCap` declara (> 0), o preço em
# ouro é `SubmitFee`, o preço em matéria-prima é `MaterialPerCraft` da faixa
# declarada por `GetBandMaterialHash`, o nome exibido é `SLOT_NAMES`. Não existe
# lista de receitas neste arquivo nem no .tscn — mexer no catálogo mexe a tela.
func BuildRecipes() -> Array:
	var out : Array = []
	var slotCount : int = CraftCatalog.SLOT_NAMES.size()
	for tierKey in CraftCatalog.BUDGET_CAP.keys():
		var tier : int = int(tierKey)
		for slot in slotCount:
			var cap : int = CraftCatalog.BudgetCap(tier, slot)
			if cap <= 0:
				continue
			var baseHash : int = FirstBaseHash(tier, slot)
			if baseHash <= 0:
				continue
			var materialHash : int = FarmZoneData.GetBandMaterialHash(tier)
			out.append({
				"tier" = tier,
				"slot" = slot,
				"cap" = cap,
				"base_hash" = baseHash,
				"fee" = CraftCatalog.SubmitFee(tier),
				"material_hash" = materialHash,
				"material_units" = CraftCatalog.MaterialPerCraft(tier),
				"owned" = OwnedUnits(materialHash),
			})
	return out

# Template visual da submissão: célula EQUIPÁVEL real do (tier, slot) — o mesmo
# predicado que o servidor confere (`baseCell.slot == slot`, e matéria-prima não
# veste). Menor hash = ordem determinística.
func FirstBaseHash(tier : int, slot : int) -> int:
	var best : int = 0
	for cellHash in DB.ItemsDB.keys():
		var cell : ItemCell = DB.ItemsDB.get(int(cellHash), null)
		if cell == null or not CellCommons.IsEquippable(cell):
			continue
		if cell.tier != tier or int(cell.slot) != slot:
			continue
		if best == 0 or int(cellHash) < best:
			best = int(cellHash)
	return best

# Matéria-prima no bolso: só leitura do inventário para o jogador ver se já tem.
# NÃO é portão — quem consome e recusa (`no_stock`) é o servidor.
func OwnedUnits(materialHash : int) -> int:
	if materialHash <= 0:
		return 0
	if Launcher.Player == null or Launcher.Player.inventory == null:
		return 0
	var total : int = 0
	for entry in Launcher.Player.inventory.items:
		if int(entry.cellID) == materialHash:
			total += int(entry.count)
	return total

# Chaves do enum que o servidor aceita como modificador e que têm peso no budget:
# peso 0 é justamente o buraco histórico (lendário de graça), e `None`/`Count` não
# são efeitos. A tabela de pesos vem do catálogo, nunca daqui.
func ModifierKeys() -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var weights : Array[float] = CraftCatalog.MOD_WEIGHTS
	for keyName in CellCommons.Modifier.keys():
		var ident : String = String(keyName)
		if ident == "None" or ident == "Count":
			continue
		var effect : int = int(CellCommons.Modifier.get(ident, CellCommons.Modifier.None))
		if effect <= 0 or effect >= weights.size():
			continue
		if weights[effect] <= 0.0:
			continue
		out.append(ident)
	return out

func Rebuild() -> void:
	_recipes = BuildRecipes()
	_modKeys = ModifierKeys()
	_recipeOption.clear()
	for index in _recipes.size():
		_recipeOption.add_item(RecipeLabel(_recipes[index] as Dictionary))
	_modOption.clear()
	for keyName in _modKeys:
		_modOption.add_item(ModifierLabel(String(keyName)))
	_modOption.selected = 0 if _modOption.item_count > 0 else -1
	_recipeOption.selected = 0 if not _recipes.is_empty() else -1
	_recipeLabel.text = RecipeLine(SelectedRecipe()) if not _recipes.is_empty() else "Catálogo sem par (tier, slot) liberado."

func RecipeLabel(recipe : Dictionary) -> String:
	if recipe.is_empty():
		return "Sem receita"
	return "%s tier %d — budget %d (%s)" % [SlotName(int(recipe["slot"])), int(recipe["tier"]), int(recipe["cap"]), StockMark(recipe)]

# "Dá agora ou não dá" lido do bolso do personagem, na LINHA da lista — quem varre a
# vitrine não precisa selecionar uma receita para saber se tem o que pedir. Vitrine
# honesta, não portão: o número é a contagem local de `OwnedUnits`, e quem cobra e
# recusa (`no_stock`) continua sendo o servidor.
func StockMark(recipe : Dictionary) -> String:
	var owned : int = int(recipe.get("owned", 0))
	var units : int = int(recipe.get("material_units", 0))
	if units <= 0:
		return "faixa sem insumo declarado"
	if owned >= units:
		return "insumo %d/%d — dá" % [owned, units]
	return "insumo %d/%d — falta" % [owned, units]

# Os dois nomes vêm de dados: a lista de slots do catálogo e a célula real do
# template. Nada aqui é string de receita escrita neste arquivo.
func SlotName(slot : int) -> String:
	if slot < 0 or slot >= CraftCatalog.SLOT_NAMES.size():
		return "slot %d" % slot
	return CraftCatalog.SLOT_NAMES[slot]

func ItemName(cellHash : int) -> String:
	var cell : ItemCell = DB.ItemsDB.get(cellHash, null)
	return "? (hash %d)" % cellHash if cell == null else str(cell.name)

func ModifierLabel(keyName : String) -> String:
	var effect : int = int(CellCommons.Modifier.get(keyName, CellCommons.Modifier.None))
	if effect <= 0 or effect >= CraftCatalog.MOD_WEIGHTS.size():
		return keyName
	return "%s (peso %.1f)" % [keyName, float(CraftCatalog.MOD_WEIGHTS[effect])]

func RecipeLine(recipe : Dictionary) -> String:
	if recipe.is_empty():
		return "Sem receita no catálogo."
	var units : int = int(recipe["material_units"])
	var owned : int = int(recipe["owned"])
	var materialHash : int = int(recipe["material_hash"])
	var materialName : String = ItemName(materialHash) if materialHash > 0 else "faixa sem material declarado"
	return "Paga %d gold de taxa + %d x %s (tem %d). Máx %d submissões por dia. O item só existe depois da aprovação de GM." % [
		int(recipe["fee"]), units, materialName, owned, CraftCatalog.MAX_PER_DAY]

# ------------------------------------------------------------------ estado observado
func SelectedRecipe() -> Dictionary:
	var index : int = _recipeOption.selected if _recipeOption != null else -1
	if index < 0 or index >= _recipes.size():
		return {}
	return _recipes[index] as Dictionary

func SelectedModifiers() -> Dictionary:
	var out : Dictionary = {}
	if _modOption == null or _modOption.selected < 0:
		return out
	var index : int = _modOption.selected
	if index >= _modKeys.size():
		return out
	# A chave do payload É o nome do enum que o servidor resolve
	# (`CellCommons.Modifier.get(str(modKey))`) — nunca o rótulo exibido.
	var keyName : String = String(_modKeys[index])
	if keyName.is_empty():
		return out
	out[keyName] = int(_modValue.value) if _modValue != null else 0
	return out

func RecipeCount() -> int:
	return _recipes.size()

func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingMethod() -> String:
	return str(_pending.get("method", ""))

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

# ------------------------------------------------------------------ ações
func _on_recipe_selected(_index : int) -> void:
	_recipeLabel.text = RecipeLine(SelectedRecipe())

func _on_refresh_pressed() -> void:
	Rebuild()
	_status("Catálogo relido.")

func _on_forge_pressed() -> void:
	RequestCraft()

# Nome fora do tamanho declarado pelo serviço é erro de digitação, não regra de
# economia: a régua de verdade (blocklist, duplicata por edit-distance, budget,
# matéria-prima, taxa, cap diário) é o servidor quem decide.
func RequestCraft() -> bool:
	var recipe : Dictionary = SelectedRecipe()
	if recipe.is_empty():
		_status("Nada para submeter: o catálogo não liberou receita.")
		return false
	var itemName : String = str(_nameEdit.text).strip_edges() if _nameEdit != null else ""
	if itemName.length() < 3 or itemName.length() > 30:
		_status("O nome precisa ter entre 3 e 30 caracteres.")
		return false
	var modifiers : Dictionary = SelectedModifiers()
	if modifiers.is_empty():
		_status("Escolha um modificador — sem efeito o item não é item.")
		return false
	_pending = {
		"method" = "SubmitCraft",
		"args" = [int(recipe["slot"]), int(recipe["base_hash"]), itemName, modifiers],
		"line" = PreviewLine(recipe, itemName, modifiers),
	}
	if _confirmLabel:
		_confirmLabel.text = str(_pending["line"])
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if _confirmRow:
		_confirmRow.visible = not modal
	if modal:
		UICommons.MessageBox(str(_pending["line"]), Callable(self, "ConfirmPending"), "Confirmar")
	return true

func PreviewLine(recipe : Dictionary, itemName : String, modifiers : Dictionary) -> String:
	var effects : String = ""
	for keyName in modifiers.keys():
		effects += "%s %d, " % [String(keyName), int(modifiers[keyName])]
	return "Submeter \"%s\" (%s tier %d, %s)? Custa %d gold e %d x %s AGORA; o item só existe se um GM aprovar." % [
		itemName, SlotName(int(recipe["slot"])), int(recipe["tier"]), effects,
		int(recipe["fee"]), int(recipe["material_units"]),
		ItemName(int(recipe["material_hash"]))]

# ÚNICO caminho que fala com a rede.
func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	_status("Submissão enviada — fila de aprovação de GM.")
	_send(methodName, args)

func CancelPending() -> void:
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if _confirmLabel:
		_confirmLabel.text = ""

func _send(methodName : String, args : Array) -> void:
	if not NetworkTargets.has(methodName):
		push_error("CraftPanel: send target outside the declared table: " + methodName)
		return
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		SentTargets.append(methodName)
		return
	if NetworkSend(methodName, args):
		SentTargets.append(methodName)

# Costura de produção: o RPC em NOME LITERAL, o mesmo do `/cs_craft` autorizado.
func NetworkSend(methodName : String, args : Array) -> bool:
	match methodName:
		"SubmitCraft":
			Network.SubmitCraft(int(args[0]), int(args[1]), str(args[2]), args[3] as Dictionary)
			return true
		_:
			push_error("CraftPanel: unknown send target " + methodName)
			return false

func _status(text : String) -> void:
	if _statusLabel:
		_statusLabel.text = text

# Chamada por `Gui.OpenCraft`: a vitrine é lida do catálogo + inventário locais a
# cada abertura (sem rede — o servidor não tem RPC de leitura de receita, e o
# jogador não precisa de um: o veredito vem no toast da submissão).
func OpenCraft() -> void:
	Rebuild()
