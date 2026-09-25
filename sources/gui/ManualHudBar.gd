# Fatia 2 do HUD (gate anti-god-node — ROADMAP_COMERCIAL S3): a construção da
# barra de ações rápidas que o `Gui` monta em runtime — skills manuais, atalhos
# de hub e o toggle do HUD idle. Sem `class_name` de propósito (mesma regra de
# `sources/ads/AdProvider.gd`): o módulo é carregado por `preload`, só expõe
# função estática e nunca nasce de `.new()`. O ESTADO (a barra, os botões) e o
# QUE CADA BOTÃO FAZ continuam no `Gui` — é de lá que `_input`,
# `ToggleIdleMode`, a suíte de idle e o harness e2e leem.
extends RefCounted

# Monta a barra sob o pai de `actionBoxes` e devolve o estado para o dono
# guardar: `bar` (o nó), `skillButtons` (botões de cast, na ordem dos skills) e
# `idleButton` (o toggle do HUD). `bar` nulo é o mesmo "não há onde pendurar"
# que o chamador já tratava antes da fatia.
static func Build(gui : Node) -> Dictionary:
	var skillButtons : Array[Button] = []
	if gui.actionBoxes == null:
		return {"bar": null, "skillButtons": skillButtons, "idleButton": null}
	# Barra própria (HBox auto-layout) sob a ButtonBar: buttonBoxes é a barra
	# de diálogo (oculta in-game) e ActionBoxes é cena instanciada de slots.
	var bar : HBoxContainer = HBoxContainer.new()
	bar.name = "ManualSkills"
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 36.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gui.actionBoxes.get_parent().add_child(bar)
	gui.actionBoxes.get_parent().move_child(bar, 0)

	# Main skills (Melee + Run): quick-cast sem ocupar os 10 slots + nomes reais.
	var skills : Array = [
		["Melee", DB.GetCellHash("Melee")],
		["Run", DB.GetCellHash("Run")],
	]
	var touchSize : Vector2 = Vector2(48, 48) if (LauncherCommons.isMobile or LauncherCommons.isWeb) else Vector2(60, 30)

	for entry in skills:
		var btn : Button = Button.new()
		btn.name = "ManualSkill_" + str(entry[1])
		btn.text = str(entry[0])
		btn.custom_minimum_size = touchSize
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.add_theme_color_override("font_color", Color(1, 1, 0, 1))
		btn.pressed.connect(Callable(gui, "_on_manual_skill_pressed").bind(int(entry[1])))
		bar.add_child(btn)
		skillButtons.append(btn)
	# Hub Atividades (entra sem fricção; mesmos backends dos comandos).
	var eventsBtn : Button = Button.new()
	eventsBtn.name = "ActivitiesButton"
	eventsBtn.text = "Eventos"
	eventsBtn.custom_minimum_size = touchSize
	eventsBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	eventsBtn.pressed.connect(Callable(gui, "_on_activities_pressed"))
	bar.add_child(eventsBtn)
	# Botão Guilda — acesso rápido ao painel Social.gd (guildList, membros, vault, ações líder).
	var guildBtn : Button = Button.new()
	guildBtn.name = "GuildButton"
	guildBtn.text = "Guilda"
	guildBtn.custom_minimum_size = touchSize
	guildBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	guildBtn.pressed.connect(Callable(gui, "_on_guild_pressed"))
	bar.add_child(guildBtn)
	# Botão AH — acesso à Auction House (UI gráfica P1 em desenvolvimento; comandos /ah funcionam via EconomyService).
	var ahBtn : Button = Button.new()
	ahBtn.name = "AHButton"
	ahBtn.text = "AH"
	ahBtn.custom_minimum_size = touchSize
	ahBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	ahBtn.pressed.connect(Callable(gui, "_on_ah_pressed"))
	bar.add_child(ahBtn)
	# Botão de acesso rápido à Auction House Window (P1 Social — UI gráfica de leilão).
	if not bar.has_node("AuctionHouseAccess"):
		var ahAccessBtn : Button = Button.new()
		ahAccessBtn.name = "AuctionHouseAccess"
		ahAccessBtn.text = "Leilão"
		ahAccessBtn.custom_minimum_size = touchSize
		ahAccessBtn.mouse_filter = Control.MOUSE_FILTER_STOP
		ahAccessBtn.pressed.connect(Callable(gui, "_on_ah_pressed"))
		bar.add_child(ahAccessBtn)
	# HUD idle na barra de HUD: `ToggleIdleMode` tinha um único chamador no repositório
	# — a tecla crua F12 em `_input` — e Web/celular não têm essa tecla. O botão é
	# `toggle_mode` para que o estado do modo apareça sem ler texto nenhum.
	var idleBtn : Button = Button.new()
	idleBtn.name = "IdleHudButton"
	idleBtn.text = "Idle"
	idleBtn.tooltip_text = "HUD mínima de idle (F12)"
	idleBtn.toggle_mode = true
	idleBtn.custom_minimum_size = touchSize
	idleBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	idleBtn.set_pressed_no_signal(gui.idleMode)
	idleBtn.pressed.connect(Callable(gui, "_on_idle_hud_pressed"))
	bar.add_child(idleBtn)
	return {"bar": bar, "skillButtons": skillButtons, "idleButton": idleBtn}
