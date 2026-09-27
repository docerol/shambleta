extends RefCounted
class_name BossLadder

# SOM-GAMEPLAY G3 (AUDITORIA §"Game Design"): a escada de bosses existia só como
# número na UI ("2/4 beaten", "gear decides"). O jogador não tinha como saber o
# requisito REAL do próximo duelo — qual número da sua build decide a luta.
#
# Este arquivo NÃO inventa balance: ele INVERTE a simulação determinística que já
# decide o duelo (BossService.Resolve). Resolve recebe attack e devolve tempo;
# aqui resolve a mesma desigualdade para attack. Consequência: a frase saída por
# RequirementLine() e o veredito da luta vêm das mesmas constantes, então o que o
# /boss mostra é exatamente o que o servidor vai aplicar.

# Multiplicador da mecânica ativa (BossService.InterruptPerfectMult): assumido
# 1.5 só na linha "ou com interrupt perfeito" — é o teto do que um jogador que
# aprende a janela ganha, não um bônus novo.
const PerfectInterruptMult : float = 1.5

# Tetos da correção de arredondamento em AttackNeeded (não é busca de balance:
# 8 passos cobrem com folga o truncamento de int() de Resolve e limitam o custo).
const CorrectionSteps : int = 8

# Ataque mínimo para o char vencer a corrida de TTK contra o boss de `bossLevel`.
# player = snapshot no formato de BossService.PlayerFightSnapshot
# ({attack, defense, maxHealth, cycle}); chaves ausentes usam os mesmos defaults de Resolve.
static func AttackNeeded(bossLevel : int, player : Dictionary, interruptMult : float = 1.0) -> int:
	var bossHP : int = BossService.GetBossMaxHealth(bossLevel)
	var bossAtk : int = BossService.GetBossAttack(bossLevel)
	var bossDef : int = BossService.GetBossDefense(bossLevel)

	var playerDef : int = int(player.get("defense", 0))
	var playerHP : int = maxi(1, int(player.get("maxHealth", 1)))
	var playerCycle : float = maxf(0.01, float(player.get("cycle", BossService.PlayerAttackCycle)))

	# Tempo que o BOSS leva para derrubar o char (mesma conta de Resolve).
	var dmgToPlayer : int = maxi(1, bossAtk - playerDef)
	var bossTTK : float = (float(playerHP) / float(dmgToPlayer)) * BossService.BossAttackCycle

	# playerTTK <= bossTTK  <=>  dmgToBoss >= bossHP * playerCycle / bossTTK
	# dmgToBoss = (attack + MeleeSkillValue - bossDef) * mult  (ordem de Resolve)
	var needDmg : int = maxi(1, ceili(float(bossHP) * playerCycle / bossTTK))
	var attack : int = maxi(1, ceili(float(needDmg) / maxf(1.0, interruptMult)) + bossDef - BossService.MeleeSkillValue)

	# Ajuste fino contra o PRÓPRIO simulador: Resolve() trunca o dano para int e
	# clampa em 1, então o analítico erra por ~1 ponto. Passos limitados (não é
	# busca: é correção de arredondamento) para o número exibido ser o número que
	# decide a luta — nunca um chute "de UX".
	var probe : Dictionary = player.duplicate()
	var steps : int = 0
	while steps < CorrectionSteps and not _wins(bossLevel, probe, attack, interruptMult):
		steps += 1
		attack += 1
	steps = 0
	while steps < CorrectionSteps and attack > 1 and _wins(bossLevel, probe, attack - 1, interruptMult):
		steps += 1
		attack -= 1
	return attack

# Veredito do MESMO duelo com um attack emprestado (só o arredondamento muda).
static func _wins(bossLevel : int, player : Dictionary, attack : int, interruptMult : float) -> bool:
	var probe : Dictionary = player.duplicate()
	probe["attack"] = attack
	return WillWin(bossLevel, probe, interruptMult)

# Mesmo número do veredito da luta (fonte única: BossService.Resolve).
static func WillWin(bossLevel : int, player : Dictionary, interruptMult : float = 1.0) -> bool:
	return bool(BossService.Resolve(player, bossLevel, interruptMult).get("win", false))

# Dicionário do próximo desafio: o que o boss é e o que falta no char.
static func Requirement(state : Dictionary, player : Dictionary) -> Dictionary:
	var next : Dictionary = _nextBoss(state)
	if next.is_empty():
		return {}
	var level : int = int(next.get("level", 1))
	var index : int = int(next.get("index", -1))
	# A janela de interrupt é a DO BOSS (BossService.GetInterruptWindow): na perna
	# nova ela é mais estreita que a legacy, e o número comunicado tem que ser o
	# mesmo que a sim aplica — senão a régua de "pronto com interrupt perfeito"
	# mente sobre o boss 9.
	var window : Dictionary = BossService.GetInterruptWindow(index)
	var have : int = int(player.get("attack", 1))
	var needed : int = AttackNeeded(level, player)
	var withPerfect : int = AttackNeeded(level, player, PerfectInterruptMult)
	return {
		"name" = str(next.get("name", "?")),
		"index" = index,
		"level" = level,
		"hp" = int(next.get("hp", 0)),
		"arena" = str(next.get("arena", "")),
		"keyCost" = int(next.get("keyCost", BossService.GetBossKeyCost(index))),
		"interruptPerfect" = float(window.get("perfect", 0.1)),
		"attackNeeded" = needed,
		"attackNeededPerfect" = withPerfect,
		"attackHave" = have,
		"gap" = maxi(0, needed - have),
		"ready" = WillWin(level, player),
		"readyWithInterrupt" = WillWin(level, player, PerfectInterruptMult),
		"seconds" = float(BossService.Resolve(player, level).get("duration", 0.0)),
	}

# Uma linha por boss + o veredito do próximo. É texto puro (o /boss manda no
# chat; a janela Boss.tscn reaproveita RequirementText para o hint).
static func RequirementLine(state : Dictionary, player : Dictionary) -> String:
	if state.is_empty():
		return "Boss ladder: no data yet"
	var beaten : int = int(state.get("beaten", 0))
	var count : int = int(state.get("count", 0))
	var lines : PackedStringArray = PackedStringArray()
	lines.append("Boss ladder — %d/%d beaten, %d key(s)" % [beaten, count, int(state.get("keys", 0))])

	if count > 0 and beaten >= count:
		lines.append("Ladder complete (%d/%d) — Torment tier 1 unlocked. Set it with /torment 1." % [beaten, count])
		return "\n".join(lines)

	for boss in state.get("bosses", []):
		var tag : String = "beaten" if bool(boss.get("beaten", false)) else ("NEXT  " if bool(boss.get("next", false)) else "locked")
		var text : String = "  %s  %-11s Lv %d  (%d HP)" % [tag, str(boss.get("name", "?")), int(boss.get("level", 1)), int(boss.get("hp", 0))]
		var arena : String = str(boss.get("arena", ""))
		if arena != "":
			text += "  @ " + arena
		if int(boss.get("keyCost", 1)) > 1:
			text += "  [%d chaves]" % int(boss.get("keyCost", 1))
		if bool(boss.get("next", false)):
			text += " — " + RequirementText(Requirement(state, player))
		lines.append(text)
	return "\n".join(lines)

# A frase de requisito em si — usada pelo /boss e pelo hint da janela de boss.
static func RequirementText(need : Dictionary) -> String:
	if need.is_empty():
		return "no pending duel"
	var have : int = int(need.get("attackHave", 0))
	# A meia-janela do boss (0.10 = a legacy; a perna nova aperta) é comunicada
	# junto: é o timing que o servidor vai cobrar, não um enfeite.
	var window : float = float(need.get("interruptPerfect", 0.1))
	var hint : String = "" if absf(window - 0.1) < 0.0005 else " (janela ±%.2f)" % window
	if bool(need.get("ready", false)):
		return "ready — win in ~%.0fs at attack %d%s" % [float(need.get("seconds", 0.0)), have, hint]
	if bool(need.get("readyWithInterrupt", false)):
		return "needs attack %d (you have %d) — winnable ONLY by hitting the interrupt window (x%.2f)%s" % [int(need.get("attackNeeded", 0)), have, PerfectInterruptMult, hint]
	return "needs attack %d (you have %d, short %d) — or %d if you land perfect interrupts%s" % [int(need.get("attackNeeded", 0)), have, int(need.get("gap", 0)), int(need.get("attackNeededPerfect", 0)), hint]

# Próximo boss não-vencido da escada (a escada é sequencial — mesmo índice que
# BossProgressionService.ChallengeBoss desafia).
static func _nextBoss(state : Dictionary) -> Dictionary:
	for boss in state.get("bosses", []):
		if bool(boss.get("next", false)):
			return boss
	return {}
