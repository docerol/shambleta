@tool
extends BaseCell
class_name ItemCell

@export var slot : ActorCommons.Slot			= ActorCommons.Slot.NONE
@export var tier : int							= 1
# D2-depth: classe exigida ("warden"|"rogue"|"scholar"; "" = universal).
@export var classReq : String					= ""
@export var textures : Array[Texture2D]			= []
@export var shader : Resource					= null
@export var customfield : String				= ""
@export var animationOverrides : AnimationLibrary	= null
@export var spriteHframes : int				= 0
@export var spriteVframes : int				= 0

#
func StripClient():
	super.StripClient()
	textures = []
	shader = null
	animationOverrides = null

func Use():
	if usable:
		super.Use()
	elif slot >= ActorCommons.Slot.FIRST_EQUIPMENT and slot < ActorCommons.Slot.LAST_EQUIPMENT and Launcher.Player and Launcher.Player.inventory:
		# Hero class: feedback imediato no client (o servidor revalida).
		if not classReq.is_empty() and not NetClient.MyHeroClass.is_empty() and classReq != NetClient.MyHeroClass:
			return
		var equipmentCell : ItemCell = Launcher.Player.inventory.GetEquipmentCell(slot)
		if CellCommons.IsSameCell(self, equipmentCell):
			Network.UnequipItem(id, customfield)
		else:
			var itemIndex : int = Launcher.Player.inventory.FindItemIndex(self)
			Network.EquipItem(id, customfield, itemIndex)

#
func _init():
	super._init()
	if slot >= ActorCommons.Slot.FIRST_EQUIPMENT and slot < ActorCommons.Slot.LAST_EQUIPMENT:
		textures.resize(ActorCommons.Gender.COUNT)
