extends PanelContainer

#
@onready var hairstyleLabel : Label			= $Margin/VBox/Hairstyle/Name
@onready var hairstylePrev : Button			= $Margin/VBox/Hairstyle/Previous
@onready var hairstyleNext : Button			= $Margin/VBox/Hairstyle/Next

@onready var haircolorLabel : Label			= $Margin/VBox/HairColor/Name
@onready var haircolorPrev : Button			= $Margin/VBox/HairColor/Previous
@onready var haircolorNext : Button			= $Margin/VBox/HairColor/Next

@onready var genderLabel : Label			= $Margin/VBox/Gender/Name
@onready var genderPrev : Button			= $Margin/VBox/Gender/Previous
@onready var genderNext : Button			= $Margin/VBox/Gender/Next

@onready var raceLabel : Label			= $Margin/VBox/Race/Name
@onready var racePrev : Button			= $Margin/VBox/Race/Previous
@onready var raceNext : Button			= $Margin/VBox/Race/Next

@onready var skintoneLabel : Label			= $Margin/VBox/SkinTone/Name
@onready var skintonePrev : Button			= $Margin/VBox/SkinTone/Previous
@onready var skintoneNext : Button			= $Margin/VBox/SkinTone/Next

var skintoneCount : int						= 0
var hairstylesCount : int					= 0
var haircolorsCount : int					= 0
var raceCount : int							= 0

var hairstyleValue : int					= 0
var haircolorValue : int					= 0
var genderValue : int						= 0
var raceValue : int							= 0
var skintoneValue : int						= 0

signal bodyUpdate
signal hairUpdate

#
func GetValues():
	var hairstyles : PackedInt64Array = DB.HairstylesDB.keys()
	var haircolors : PackedInt64Array = DB.PalettesDB[DB.Palette.HAIR].keys()
	var races : PackedInt64Array = DB.RacesDB.keys()
	var race : RaceData = DB.GetRace(races[raceValue])
	var skins : Dictionary[String, Material] = race.skins if race else {}
	var skinsKeys : Array = skins.keys()

	return {
		"hairstyle" = hairstyles[hairstyleValue],
		"haircolor" = haircolors[haircolorValue],
		"race" = races[raceValue],
		"skintone" = skinsKeys[skintoneValue].hash(),
		"gender" = genderValue,
		"hero_class" = GetHeroClass()
	}

# Hairstyle
func RefreshHairstyle():
	var hairstyles : PackedInt64Array = DB.HairstylesDB.keys()
	if hairstyleValue >= 0 and hairstyleValue < hairstylesCount:
		hairstyleLabel.set_text(DB.GetHairstyle(hairstyles[hairstyleValue])._name)
		hairUpdate.emit()

func _on_hairstyle_prev_button():
	hairstyleValue = hairstyleValue - 1 if hairstyleValue > 0 else hairstylesCount - 1
	RefreshHairstyle()

func _on_hairstyle_next_button():
	hairstyleValue = hairstyleValue + 1 if hairstyleValue < hairstylesCount - 1 else 0
	RefreshHairstyle()

# Haircolor
func RefreshHaircolor():
	var palettes : PackedInt64Array = DB.PalettesDB[DB.Palette.HAIR].keys()
	if haircolorValue >= 0 and haircolorValue < haircolorsCount:
		haircolorLabel.set_text(DB.GetPalette(DB.Palette.HAIR, palettes[haircolorValue])._name)
		hairUpdate.emit()

func _on_haircolor_prev_button():
	haircolorValue = haircolorValue - 1 if haircolorValue > 0 else haircolorsCount - 1
	RefreshHaircolor()

func _on_haircolor_next_button():
	haircolorValue = haircolorValue + 1 if haircolorValue < haircolorsCount - 1 else 0
	RefreshHaircolor()

# Gender
func RefreshGender():
	genderLabel.set_text(ActorCommons.GetGenderName(genderValue))
	bodyUpdate.emit()

func _on_gender_prev_button():
	genderValue = genderValue - 1 if genderValue > 0 else ActorCommons.Gender.COUNT - 1
	RefreshGender()

func _on_gender_next_button():
	genderValue = genderValue + 1 if genderValue < ActorCommons.Gender.COUNT - 1 else 0
	RefreshGender()

# Race
func RefreshRace():
	var races : PackedInt64Array = DB.RacesDB.keys()
	if raceValue >= 0 and raceValue < raceCount:
		var data : RaceData = DB.GetRace(races[raceValue])
		raceLabel.set_text(data.name)
		RefreshSkintone()
		bodyUpdate.emit()

func _on_race_prev_button():
	raceValue = raceValue - 1 if raceValue > 0 else raceCount - 1
	RefreshRace()

func _on_race_next_button():
	raceValue = raceValue + 1 if raceValue < raceCount - 1 else 0
	RefreshRace()

# Skin tone
func RefreshSkintone():
	var races : PackedInt64Array = DB.RacesDB.keys()
	if raceValue >= 0 and raceValue < raceCount:
		var data : RaceData = DB.GetRace(races[raceValue])
		var skins : Dictionary[String, Material] = data.skins
		var skinsKeys : PackedStringArray = skins.keys()
		skintoneCount = data.skins.size()
		if skintoneValue < 0 or skintoneValue >= skintoneCount:
			skintoneValue = 0
		if skintoneValue >= 0 and skintoneValue < skintoneCount:
			skintoneLabel.set_text(skinsKeys[skintoneValue])
			bodyUpdate.emit()

func _on_skintone_prev_button():
	skintoneValue = skintoneValue - 1 if skintoneValue > 0 else skintoneCount - 1
	RefreshSkintone()

func _on_skintone_next_button():
	skintoneValue = skintoneValue + 1 if skintoneValue < skintoneCount - 1 else 0
	RefreshSkintone()

# Hero class (runtime row, mirrors the Race cycler; class is mandatory).
var classValue : int = 0
var _classNameLabel : Label = null

func _ready() -> void:
	EnsureClassRow()

func _class_ids() -> Array:
	var ids : Array = []
	for entry in ClassBonus.GetCatalog():
		ids.append(str(entry.get("id", "")))
	return ids

func EnsureClassRow() -> void:
	if _classNameLabel != null or _class_ids().is_empty():
		return
	var row := HBoxContainer.new()
	row.name = "Class"
	var prev := Button.new()
	prev.name = "Previous"
	prev.text = "<"
	prev.pressed.connect(_on_class_prev_button)
	var nameLabel := Label.new()
	nameLabel.name = "Name"
	nameLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nameLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var next := Button.new()
	next.name = "Next"
	next.text = ">"
	next.pressed.connect(_on_class_next_button)
	row.add_child(prev)
	row.add_child(nameLabel)
	row.add_child(next)
	($Margin/VBox as VBoxContainer).add_child(row)
	($Margin/VBox as VBoxContainer).move_child(row, 0)
	_classNameLabel = nameLabel
	RefreshClass()

func RefreshClass():
	EnsureClassRow()
	if _classNameLabel == null:
		return
	var ids : Array = _class_ids()
	if classValue < 0 or classValue >= ids.size():
		classValue = 0
	_classNameLabel.set_text(str(ClassBonus.GetClass(ids[classValue]).get("label", ids[classValue])))

func GetHeroClass() -> String:
	var ids : Array = _class_ids()
	if ids.is_empty():
		return ""
	if classValue < 0 or classValue >= ids.size():
		classValue = 0
	return ids[classValue]

func _on_class_prev_button():
	var n : int = _class_ids().size()
	if n <= 0:
		return
	classValue = classValue - 1 if classValue > 0 else n - 1
	RefreshClass()

func _on_class_next_button():
	var n : int = _class_ids().size()
	if n <= 0:
		return
	classValue = classValue + 1 if classValue < n - 1 else 0
	RefreshClass()

#
func Randomize():
	if hairstylesCount == 0:
		hairstylesCount = DB.HairstylesDB.size()
	if haircolorsCount == 0:
		haircolorsCount = DB.PalettesDB[DB.Palette.HAIR].size()
	if raceCount == 0:
		raceCount = DB.RacesDB.size()

	hairstyleValue = randi() % hairstylesCount
	RefreshHairstyle()
	haircolorValue = randi() % haircolorsCount
	RefreshHaircolor()
	genderValue = randi() % ActorCommons.Gender.COUNT
	RefreshGender()
	raceValue = randi() % raceCount
	RefreshRace()
	classValue = randi() % maxi(_class_ids().size(), 1)
	RefreshClass()
	skintoneValue = randi() % skintoneCount
	RefreshSkintone()
