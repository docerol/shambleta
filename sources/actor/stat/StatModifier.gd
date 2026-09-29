extends Resource
class_name StatModifier

#
@export var _effect : CellCommons.Modifier	= CellCommons.Modifier.None
@export var _value : Variant				= 0.0
@export var _persistent : bool				= false
var _command : bool							= false

#
func Parse(data : Array):
	var arraySize : int = data.size()

	if arraySize != 3:
		push_error("Could not parse stat modifier from array, size mismatches")
		return
	# SOM-IDLE (auditoria 2026-09-28): os quatro `push_error` e as quatro atribuições
	# tinham ficado ABAIXO do `return` quando `0c5cb56` trocou o `assert` pelo guard —
	# `Parse()` de um array válido devolvia um modificador inteiro de defaults, e quem
	# ligasse o chamador (hoje zero, os cinco `StatModifier.new()` setam direto) ia
	# receber um bônus que não faz nada.
	if data[0] is not CellCommons.Modifier:
		push_error("Stat modifier first parameter is not a StringName, could not parse from array")
		return
	if data[2] is not bool:
		push_error("Stat modifier third parameter is not a bool, could not parse from array")
		return

	_effect = data[0]
	_value = data[1]
	_persistent = data[2]
	_command = false
