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
	]
	for c in checks:
		if _has_fn(c[0], c[1]):
			print("PASS: " + str(c[2]))
		else:
			print("FAIL: " + str(c[2]))
			failures += 1
	print("== RESULT: %d failures ==" % failures)
	quit(failures)
