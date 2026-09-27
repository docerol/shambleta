extends Label

#
var timeLeft : float						= 3.0
var fadingTime : float						= 1.0
var velocity : Vector2						= Vector2.ZERO
var criticalHit : bool						= false
var HSVA : Vector4							= Vector4.ZERO
var floorPosition : float					= 0.0
var bounce : bool							= false

const gravityRedux : float					= 180.0
const maxVelocityAngle : float				= 36
const minVelocitySpeed : float				= 24.0
const maxVelocitySpeed : float				= 60.0
const overheadOffset : int					= -10

#
# SOM-GAMEPLAY G2 (AUDITORIA §"Core Gameplay"): fraqueza/resistência elemental
# existia só no número calculado no servidor. Aqui o dano ganha CARA: DoT
# (poison/bleed/burn) finalmente renderiza — antes caía no "_" e só fazia
# push_error — e o selo WEAK/RES marca de onde veio o dano.
# O selo é HEURÍSTICA DE EXIBIÇÃO derivada das stats que o cliente já tem
# (ElementCommons.AffinityForAlteration); o protocolo não mudou um byte. Os
# valores de afinidade vêm de ElementCommons.Affinity e chegam aqui como int —
# não se declara um enum espelho de propósito: este script é pré-carregado por
# ActorCommons e referenciar constants em ciclo dá erro de resolução no parse.

const PoisonHue : float						= 0.28
const BleedHue : float						= 0.97
const BurnHue : float						= 0.08
const WeakScale : float						= 1.25	# número "estoura" quando o alvo é fraco ao elemento
const ResistedValue : float					= 0.65	# número apaga quando o alvo resiste

func SetPosition(startPos : Vector2, floorPos : Vector2):
	position = startPos
	floorPosition = floorPos.y

func SetValue(dealer : Entity, value : int, alteration : ActorCommons.Alteration, affinity : int = -1):
	velocity.x = randf_range(-maxVelocityAngle, maxVelocityAngle)
	velocity.y = randf_range(minVelocitySpeed, maxVelocitySpeed)

	var hue : float = 0.0
	var saturation : float = 0.8
	match alteration:
		ActorCommons.Alteration.CRIT:
			criticalHit = true
			bounce = true
			set_text(str(value))
		ActorCommons.Alteration.DEADLY:
			criticalHit = true
			bounce = true
			hue = ActorCommons.LocalAttackColor
			set_text(str(value))
		ActorCommons.Alteration.DODGE:
			hue = ActorCommons.DodgeAttackColor
			bounce = true
			set_text("dodge")
		ActorCommons.Alteration.HIT:
			bounce = true
			if dealer == Launcher.Player:
				hue = ActorCommons.LocalAttackColor
			elif dealer.type == ActorCommons.Type.PLAYER:
				hue = ActorCommons.PlayerColor
			else:
				hue = ActorCommons.MonsterColor
			set_text(str(value))
		ActorCommons.Alteration.MISS:
			bounce = true
			hue = ActorCommons.MissAttackColor
			set_text("miss")
		ActorCommons.Alteration.HEAL:
			bounce = true
			hue = ActorCommons.HealColor
			set_text(str(value))
		ActorCommons.Alteration.EXP:
			velocity = Vector2(0.0, 12)
			floorPosition = -100000.0
			hue = ActorCommons.ExpColor
			set_text("%d xp" % value)
		ActorCommons.Alteration.GP:
			velocity = Vector2(0.0, 12)
			hue = ActorCommons.GPColor
			set_text("%d GP" % value)
	# SOM-GAMEPLAY G2: os três DoTs do combate elemental — antes caíam no "_" e só
	# faziam push_error, então veneno/sangue/fogo não apareciam na tela. bounce =
	# o número quica como um HIT (é dano acontecendo agora) e cada um tem matiz
	# própria (verde/vermelho/laranja).
		ActorCommons.Alteration.POISON:

			bounce = true
			hue = PoisonHue
			set_text(_StatusText(value, "poison", affinity))
		ActorCommons.Alteration.BLEED:
			bounce = true
			hue = BleedHue
			set_text(_StatusText(value, "bleed", affinity))
		ActorCommons.Alteration.BURN:
			bounce = true
			hue = BurnHue
			set_text(_StatusText(value, "burn", affinity))
		_:
			push_error("Alteration type not handled: " + str(alteration))

	# Fraqueza = saturação máxima + número maior; resistência = dessaturado e
	# escuro. Só mexe na APRESENTAÇÃO de um dano que já foi decidido no servidor.
	# Os helpers de ElementCommons evitam referenciar constants do outro script
	# dentro de pattern de match (composição cíclica de preload quebra no parse).
	if ElementCommons.IsWeak(affinity):
		saturation = 1.0
		scale = Vector2(WeakScale, WeakScale)
	elif ElementCommons.IsResisted(affinity):
		saturation = 0.45

	HSVA = Vector4(hue, saturation, ResistedValue if ElementCommons.IsResisted(affinity) else 1.0, 1.0)

	add_theme_color_override("font_color", Color.from_hsv(HSVA.x, HSVA.y, HSVA.z, HSVA.w))
	add_theme_color_override("font_outline_color", Color.from_hsv(HSVA.x, HSVA.y, 0.0, HSVA.w))

# Texto do DoT com o selo de afinidade. WEAK/RESISTED só aparecem quando existe
# elemento em jogo (ver ElementCommons.AffinityForAlteration), senão é número limpo.
static func _StatusText(value : int, statusName : String, affinity : int) -> String:
	if ElementCommons.IsWeak(affinity):
		return "%d %s WEAK" % [value, statusName]
	if ElementCommons.IsResisted(affinity):
		return "%d %s res" % [value, statusName]
	return "%d %s" % [value, statusName]

#
func _process(delta):
	timeLeft -= delta
	if timeLeft <= 0.0: 
		queue_free()
		return

	if timeLeft < fadingTime:
		modulate.a = timeLeft / fadingTime

	if velocity != Vector2.ZERO:
		var deltaVelocity : Vector2 = velocity * delta
		if bounce:
			if position.y - deltaVelocity.y >= floorPosition:
				velocity.y = -velocity.y
				velocity.y *= 0.66
			velocity.y -= gravityRedux * delta
		position -= deltaVelocity

	if criticalHit:
		HSVA.x = HSVA.x + delta * 2
		if HSVA.x > 1.0:
			HSVA.x = 0.0
		if HSVA.x > 0.3 and HSVA.x < 0.7:
			HSVA.x = 0.7

		add_theme_color_override("font_color", Color.from_hsv(HSVA.x, HSVA.y, HSVA.z, HSVA.w))
		add_theme_color_override("font_outline_color", Color.from_hsv(HSVA.x, HSVA.y, 0.2, HSVA.w))
