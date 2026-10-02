extends SceneTree

# SOM-IDLE: E2E test for implemented gauntlet loop stages.
# Checks that the implemented methods exist (via get_script_method_list,
# since Object.has_method does not see script-defined functions).

func _has_fn(script_path : String, fn : String) -> bool:
	var scr : GDScript = load(script_path)
	if scr == null:
		return false
	for m in scr.get_script_method_list():
		if str(m.get("name", "")) == fn:
			return true
	return false

func _initialize():
	print("== E2E Implementation Verification ==")
	var failures : int = 0
	var checks : Array = [
		["res://sources/gui/Gui.gd", "AddManualSkillButtons", "Gameplay hibrido — AddManualSkillButtons"],
		["res://sources/gui/Gui.gd", "_on_manual_skill_pressed", "Gameplay hibrido — ManualCast handler"],
		["res://sources/gui/Gui.gd", "ToggleIdleMode", "UI/UX — ToggleIdleMode (P-A1)"],
		["res://sources/gui/Gui.gd", "_adjust_for_mobile_web", "UI/UX — responsive mobile/web (P-A4)"],
		["res://sources/gui/Onboarding.gd", "_highlight_node", "UI/UX — Onboarding highlight (P-A2)"],
		["res://sources/gui/Onboarding.gd", "_clear_highlight", "UI/UX — Onboarding clear highlight (P-A2)"],
		["res://sources/gui/Gui.gd", "SimulateCheckout", "Comerciais — SimulateCheckout sandbox"],
		["res://sources/gui/Gui.gd", "CheckNetworkStability", "Rede/Servidor — CheckNetworkStability"],
		["res://sources/gui/Gui.gd", "RunPerformanceBenchmark", "Performance — RunPerformanceBenchmark"],
		["res://sources/economy/EconomyService.gd", "GetCheckoutIntent", "Comerciais — GetCheckoutIntent (sandbox)"],
		["res://sources/cell/SetBonus.gd", "EvaluateIds", "D2 sets — SetBonus.EvaluateIds"],
		["res://sources/combat/ElementCommons.gd", "EffectiveResist", "D2 penetration — EffectiveResist"],
		["res://sources/economy/EconomyService.gd", "CorruptItem", "Sinks — CorruptItem"],
		["res://sources/economy/EconomyService.gd", "CubeUpcycle", "Sinks — CubeUpcycle"],
		["res://sources/economy/EconomyService.gd", "SalvageItem", "Sinks — SalvageItem"],
		["res://sources/cell/ClassBonus.gd", "ApplyClassMults", "Classes — ApplyClassMults"],
		["res://sources/cell/ClassBonus.gd", "SkillAllowed", "Classes — SkillAllowed"],
		["res://sources/cell/ClassBonus.gd", "EquipAllowed", "Classes — EquipAllowed"],
		["res://sources/idle/IdlePolicyService.gd", "NoteActivity", "Auto-idle — NoteActivity"],
		["res://sources/idle/IdlePolicyService.gd", "ShouldAutoIdle", "Auto-idle — ShouldAutoIdle"],
		["res://sources/idle/IdlePolicyService.gd", "TickAutoIdle", "Auto-idle — TickAutoIdle"],
		["res://sources/world/MobVariant.gd", "GetCatalog", "Variants — GetCatalog"],
		["res://sources/world/MobVariant.gd", "InjectZoneVariants", "Variants — InjectZoneVariants"],
		["res://sources/economy/EconomyService.gd", "GetAchievements", "Achievements — GetAchievements"],
		["res://sources/economy/EconomyService.gd", "ClaimAchievement", "Achievements — ClaimAchievement"],
		["res://sources/economy/EconomyService.gd", "SetTorment", "Torment — SetTorment"],
		["res://sources/economy/EconomyService.gd", "BuyBossKey", "Rush — BuyBossKey"],
		["res://sources/economy/EconomyService.gd", "RunBossRush", "Rush — RunBossRush"],
		["res://sources/gui/Gui.gd", "SetNotice", "Notices — SetNotice"],
		["res://sources/gui/Gui.gd", "RefreshNotices", "Notices — RefreshNotices"],
		["res://sources/gui/WindowButton.gd", "SetNotice", "Notices — WindowButton dot"],
		["res://sources/gui/Activities.gd", "RefreshTab", "Hub — RefreshTab"],
		["res://sources/gui/Activities.gd", "ShowAchievements", "Hub — ShowAchievements"],
		["res://sources/network/Network.gd", "GetAchievements", "Hub RPC — GetAchievements"],
		["res://sources/network/server/Server.gd", "ClaimAchievement", "Hub RPC — ClaimAchievement handler"],
		# Duas linhas que nasceram de runtime error real no log, não de palpite:
		# Gui.DisplayFirstLogin chamava settingsWindow.get_sessionfirstlogin(),
		# método que nunca existiu em nenhuma revisão — a chamada abortava o
		# primeiro login e o tour de onboarding não abria para ninguém.
		["res://sources/gui/Settings.gd", "get_sessionfirstlogin", "Primeiro login — getter que Gui.DisplayFirstLogin chama"],
		# E a linha de web push em Settings só existe se o gate responder.
		["res://sources/web/WebPush.gd", "CanDeliver", "Web push — gate que Settings.gd consulta para montar a linha"],
	]
	for c in checks:
		if _has_fn(c[0], c[1]):
			print("PASS: " + str(c[2]))
		else:
			print("FAIL: " + str(c[2]))
			failures += 1
	# A contagem de checks vai para a linha de resultado de propósito:
	# `scripts/ci_gate_log.sh` lê o nº de falhas DA LINHA, e uma linha que só diz
	# "0 failures" não prova que o loop acima iterou alguma coisa — um `checks` que
	# encolhe ou um `return` precoce ficariam verdes. A linha sai ANTES do drain de
	# propósito: se o próprio drain travar, o veredito continua legível no log e o
	# gate acusa a saída que não bate, em vez de perder o run inteiro.
	print("== RESULT: %d checks, %d failures ==" % [checks.size(), failures])
	# O drain vem antes do quit pelo mesmo motivo de `_initialize` (`balance_test.gd:@_initialize`): num
	# `-s` o `_initialize` roda com os autoloads pela metade, o `quit(0)` só é
	# atendido no fim do boot, e o Launcher._exit_tree pega preloads pendentes no
	# meio — SIGSEGV com o veredito já impresso (medido: exit 134 com
	# "37 checks, 0 failures"). O gate já recusa exit e veredito que não batem;
	# isto é o que faz os dois baterem.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	if dbScript != null:
		dbScript.call("DrainPendingPreloads")
	quit(failures)
