extends WindowPanel

# SOM-IDLE Fase D: Coleção de cosméticos (MONETIZATION §2.4 + §2.7). Lista o
# possuído por tipo com Equip, a vitrine comprável em gems (com trava de
# marco) e o estado do renascimento. Visuais (sprites/partículas) são
# follow-up de arte — aqui viaja identidade (rótulos), nunca poder.
@onready var rebirthLabel : Label = $Layout/RebirthInfo
@onready var ownedBox : VBoxContainer = $Layout/OwnedScroll/OwnedList
@onready var shopBox : VBoxContainer = $Layout/ShopScroll/ShopList

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshCosmetics()

func _on_visibility_changed():
	if is_visible():
		RefreshCosmetics()

func RefreshCosmetics():
	ShowCosmetics(NetClient.LastCosmetics)
	Network.GetCosmetics()

func ShowCosmetics(data : Dictionary):
	for c in ownedBox.get_children():
		c.queue_free()
	for c in shopBox.get_children():
		c.queue_free()
	if data.is_empty() or not bool(data.get("ok", false)):
		rebirthLabel.text = "Collection: unavailable"
		return
	rebirthLabel.text = "Rebirths: %d — style the number you earned" % int(data.get("rebirths", 0))
	var equipped : Dictionary = data.get("equipped", {})
	var ownedIds : Array = []
	for o in data.get("owned", []):
		ownedIds.append(str((o as Dictionary).get("id", "")))
	var catalog : Array = data.get("catalog", [])
	for e in catalog:
		if not (e is Dictionary) or not ownedIds.has(str(e.get("id", ""))):
			continue
		var cid : String = str(e.get("id", ""))
		var slot : String = str(e.get("type", ""))
		var isEq : bool = str(equipped.get(slot, "")) == cid
		var b := Button.new()
		b.text = "%s [%s]%s" % [str(e.get("label", cid)), slot, " — equipped" if isEq else ""]
		b.disabled = isEq
		if not isEq:
			b.pressed.connect(func() -> void: Network.EquipCosmetic(cid))
		ownedBox.add_child(b)
	if ownedBox.get_children().is_empty():
		var none := Label.new()
		none.text = "Empty — earn titles in the pass, the 1st rebirth, or the shop below."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ownedBox.add_child(none)
	var rebirths : int = int(data.get("rebirths", 0))
	for e in catalog:
		if not (e is Dictionary):
			continue
		var price : int = int(e.get("price", 0))
		# Fail-closed no flag do servidor: sem `rendered` o botão some, mas a
		# recusa de verdade é do `BuyCosmetic` (`not_rendered`), não daqui.
		if price <= 0 or not bool(e.get("rendered", false)):
			continue
		var cid : String = str(e.get("id", ""))
		var req : int = int(e.get("req_rebirths", 0))
		var sb := Button.new()
		if ownedIds.has(cid):
			sb.text = "%s — owned" % str(e.get("label", cid))
			sb.disabled = true
		elif rebirths < req:
			sb.text = "%s — locked (rebirths %d)" % [str(e.get("label", cid)), req]
			sb.disabled = true
		else:
			sb.text = "%s — %d gems" % [str(e.get("label", cid)), price]
			sb.pressed.connect(func() -> void: Network.BuyCosmetic(cid))
		shopBox.add_child(sb)
