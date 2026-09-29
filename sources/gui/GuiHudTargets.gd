extends RefCounted
class_name GuiHudTargets

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, mesmos
# precedentes de `ManualHudBar`/`HudWindows`/`GuildPanelRows`): a TABELA que
# traduz um `UICommons.UITarget` no controle vivo que o highlight do tour e o
# `Client` devem abrir/pintar.
#
# É a única place onde os ~20 alvos de UI são nomeados de uma vez, e é por isso
# que vive separada: adicionar um painel novo ao HUD é uma linha aqui, não um
# `match` perdido no meio do `Gui`. O `Gui` continua expondo `GetUITarget` (o
# `tests/IdleTests.gd` percorre os alvos pelo método da instância, e o
# `HighlightUI`/`OpenUI` que decide o que fazer com o resultado é dele).
#
# Comportamento idêntico: mesmos alvos, mesmos nós, o mesmo `push_error` para
# alvo não tratado e o mesmo `null` de fallback.

static func Resolve(gui : Node, target : UICommons.UITarget) -> Control:
	match target:
		UICommons.UITarget.NONE:			return null
		UICommons.UITarget.MENUINDICATOR:	return gui.menu as Control
		UICommons.UITarget.STATINDICATOR:	return gui.stats as Control
		UICommons.UITarget.HEALTHBAR:		return (gui.stats as Control).hpStat as Control
		UICommons.UITarget.MANABAR:			return (gui.stats as Control).manaStat as Control
		UICommons.UITarget.STAMINABAR:		return (gui.stats as Control).staminaStat as Control
		UICommons.UITarget.STAT:			return gui.statWindow as Control
		UICommons.UITarget.INVENTORY:		return gui.inventoryWindow as Control
		UICommons.UITarget.CHAT:			return gui.chatWindow as Control
		UICommons.UITarget.SKILL:			return gui.skillWindow as Control
		UICommons.UITarget.MINIMAP:			return gui.minimapWindow as Control
		UICommons.UITarget.PROGRESS:		return gui.progressWindow as Control
		UICommons.UITarget.SOCIAL:			return gui.socialWindow as Control
		UICommons.UITarget.EMOTE:			return gui.emoteWindow as Control
		UICommons.UITarget.SETTINGS:		return gui.settingsWindow as Control
		UICommons.UITarget.ACTION_BAR:		return gui.actionBoxes as Control
		_: push_error("Unhandled UITarget")
	return null
