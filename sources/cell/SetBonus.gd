extends RefCounted
class_name SetBonus

# D2-depth: set bonuses definidos em código (sem mudar .tres — peças usam os
# hashes registrados no DB, iguais ao Item.cellID equipado).
# Formato: id -> {label, pieces: [nomes], bonuses: {peças_equidpadas: {Modifier: valor}}}
# Bônus usam chaves Modifier existentes (+ Penetration/DeadlyChance), então
# fluem para Formula/GetDamage/DoTs sem nenhum caminho novo.

static var _hashCache : Dictionary = {}

static func _hashes(names : Array) -> Array[int]:
	var out : Array[int] = []
	for n in names:
		var key : String = str(n)
		if not _hashCache.has(key):
			_hashCache[key] = DB.GetCellHash(key)
		out.append(int(_hashCache[key]))
	return out

static func GetCatalog() -> Array:
	return [
		{
			"id": "desert_warden", "label": "Desert Warden",
			"pieces": _hashes(["Desert Shield", "Desert Armor", "Desert Hood"]),
			"bonuses": {
				2: {CellCommons.Modifier.Defense: 8},
				3: {CellCommons.Modifier.Penetration: 0.06},
			},
		},
		{
			"id": "sellsword", "label": "Sellsword",
			"pieces": _hashes(["Short Sword", "Leather Shield"]),
			"bonuses": {
				2: {CellCommons.Modifier.Attack: 4, CellCommons.Modifier.DeadlyChance: 0.08},
			},
		},
	]

# equippedIds: hashes (Item.cellID) das peças vestidas -> {Modifier: total}.
# Puro e determinístico (testável sem ator/mundo).
static func EvaluateIds(equippedIds : Array) -> Dictionary:
	var totals : Dictionary = {}
	for entry in GetCatalog():
		var pieces : Array = entry["pieces"]
		var count : int = 0
		for h in pieces:
			if equippedIds.has(int(h)):
				count += 1
		var bonuses : Dictionary = entry["bonuses"]
		for threshold in bonuses.keys():
			if count >= int(threshold):
				var grant : Dictionary = bonuses[threshold]
				for eff in grant.keys():
					totals[eff] = float(totals.get(eff, 0.0)) + float(grant[eff])
	return totals
