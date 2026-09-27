extends RefCounted
class_name GuildVaultTrail

# §14 (AUDITORIA 2026-09-27): o rastro do vault (`guild_vault_log`) já era escrito
# pelo serviço em todo depósito/saque, mas nenhuma tela o mostrava — sem prova
# visível, a confiança do item "guild trust" era adjetivo.
#
# A fonte É o estado do servidor: `GuildService.GetGuildState` traz `vault_log`.
# Havia aqui um segundo ramo que ia direto à `Launcher.SQL` "no boot dev/single-
# process", e ele foi removido de propósito: uma fronteira que vale só quando
# ninguém está depurando não é fronteira — é decoração. O cliente lê o que o
# serviço autorizou, e o serviço decide o que um membro de guilda pode ver.

static func RowsFor(guildState : Dictionary) -> Array:
	return guildState.get("vault_log", [])

static func Render(box : VBoxContainer, guildState : Dictionary) -> void:
	if box == null:
		return
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	var rows : Array = RowsFor(guildState)
	if rows.is_empty():
		var empty := Label.new()
		empty.name = "None"
		empty.text = "No vault movements yet."
		box.add_child(empty)
		return
	var pos : int = 1
	for row in rows:
		var line := Label.new()
		line.name = "Log%d" % pos
		# Traduzido AQUI, e não pelo `Localizer`: a linha é composta, então o texto que
		# entraria na árvore ("saque 2 x item 5 (conta 4242)") nunca é chave de ninguém
		# — a passada da árvore traduz o que o nó carrega no instante em que ele entra,
		# e não o que uma concatenação virou. E é `TranslationServer` em vez de `tr()`
		# porque esta função é estática: sem Object, sem método `tr`.
		line.text = TranslationServer.translate("%s %d x item %d (account %d)") % [
			TranslationServer.translate(str(row.get("kind", "?"))),
			int(row.get("count", 0)), int(row.get("item_id", 0)), int(row.get("account_id", 0))]
		box.add_child(line)
		pos += 1
