extends RefCounted
class_name MobVariant

# Variantes elite (paleta + resist + stats): definidas como entidades com
# _parent (mesmo padrão de Red Scorpion/Salt Slime) e injetadas nos mapas onde
# o mob base spawna — sem editar mapa. Idempotente (re-init não duplica).

static func GetCatalog() -> Array:
	return [
		{"name": "Frost Croc", "parent": "Croc"},
		{"name": "Ember Turtle", "parent": "Turtle"},
		{"name": "Dune Bat", "parent": "Bat"},
	]

# Entidades vivem em EntitiesDB por id (hashDB nunca tem nomes de entidade),
# então a resolução é por varredura de nome — sem spam de erro se ausente.
static func EntityHashByName(nm : String) -> int:
	for key in DB.EntitiesDB.keys():
		var e = DB.EntitiesDB[key]
		if e != null and str(e._name) == nm:
			return int(key)
	return DB.UnknownHash

static func VariantHash(entry : Dictionary) -> int:
	return EntityHashByName(str(entry.get("name", "")))

# Varre os mapas: onde o pai spawna como MONSTER, adiciona a variante (count 2).
# Retorna quantas injeções novas foram feitas.
static func InjectZoneVariants() -> int:
	if Launcher.World == null:
		return 0
	var injected : int = 0
	for entry in GetCatalog():
		var variantHash : int = VariantHash(entry)
		if variantHash == DB.UnknownHash:
			continue
		var parentHash : int = EntityHashByName(str(entry["parent"]))
		for mapID in Launcher.World.areas.keys():
			var map = Launcher.World.GetMap(mapID)
			if map == null:
				continue
			var hasParent : bool = false
			var hasVariant : bool = false
			for sp in map.spawns:
				if int(sp.id) == parentHash and int(sp.type) == ActorCommons.Type.MONSTER:
					hasParent = true
				if int(sp.id) == variantHash:
					hasVariant = true
			if hasParent and not hasVariant:
				var so := SpawnObject.new()
				so.id = variantHash
				so.nick = ""
				so.type = ActorCommons.Type.MONSTER
				so.count = 2
				so.map = map
				map.spawns.append(so)
				injected += 1
	return injected
