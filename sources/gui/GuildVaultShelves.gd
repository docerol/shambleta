extends RefCounted
class_name GuildVaultShelves

# As prateleiras do vault na tela do `GuildPanel`: pilha de item + (para oficial ou
# líder) o botão de sacar. É a outra metade do §14 — `GuildWithdrawGate` decide se o
# saque cabe, `GuildVaultTrail` mostra o que já aconteceu, e este arquivo é só o
# desenho da pilha atual, que vem de `vault_stacks` no estado do servidor.
#
# O botão de saque chama o `onWithdraw` que o painel passa: a linha nunca decide
# sozinha se gasta, e é por isso que a contadora do portão e o rastro continuam
# vindo do mesmo caminho.

static func Render(box : VBoxContainer, stacks : Array, canManage : bool, onWithdraw : Callable) -> void:
	GuildPanelRows.Clear(box)
	if box == null:
		return
	if stacks.is_empty():
		GuildPanelRows.LabelOf(box, "Empty", "Vault is empty.")
		return
	for row in stacks:
		var stack : Dictionary = row
		var itemID : int = int(stack.get("item_id", 0))
		var count : int = int(stack.get("count", 0))
		var line := HBoxContainer.new()
		var label := Label.new()
		label.text = "item %d x %d" % [itemID, count]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(label)
		if canManage and onWithdraw.is_valid():
			var withdraw := Button.new()
			withdraw.text = "Withdraw"
			withdraw.pressed.connect(func() -> void: onWithdraw.call(itemID, count))
			line.add_child(withdraw)
		box.add_child(line)
