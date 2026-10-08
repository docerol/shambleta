extends CellScript

# M-6 (2026-10-07): "Town Portal Scroll" — o pergaminho que leva À cidade, e a
# volta de graça. A auditoria dizia a linha exata (AUDITORIA_COMPLETA, seção de
# mundo): "login warps to farm; no town portal" — quests, o treinador e guild-
# mates eram inalcançáveis por construção. Este item é a porta para Tulimshar.
# A VOLTA não é vendida: `AutoFarmOnLogin` e o auto-idle já religam a zona salva
# de graça — vender o que o produto entrega de graça seria o golpe, não o scroll.
#
# Usado do inventário: `Server.UseItem` → `Inventory.UseItem` → este script,
# SEMPRE no servidor (o cliente não executa caminho de item). O consumo acontece
# ANTES do `Execute` — o freio está no `UseItem` de `sources/actor/Inventory.gd:@UseItem` —,
# então toda recusa devolve o scroll pelo `_Rollback` — o `AddItem` da casa (memória E
# banco, lote com uid, push ao cliente), o mesmo caminho que o `BottleScript`
# usa para encher.
#
# O `farm_zone` NÃO é tocado: a zona escolhida continua sendo a casa do char;
# o warp apenas para a política viva (o `_exit_tree` do warp é o dono desse
# halt, e o login re-anexa de graça). Vender "parar de farmar" seria outro
# produto; aqui se compra cidade.

# Hash do nome "Town Portal Scroll" — a MESMA chave que `_GrantStackRaw` vê
# quando o vendor entrega a oferta `portal` (`EconomyCatalog.VENDOR_CATALOG`).
const ScrollCellHash : int = 3727406510

static func Verdict(inTown : bool, townMapOK : bool) -> String:
	if inTown:
		return "already_in_town"
	if not townMapOK:
		return "town_unreachable"
	return ""

func Execute(agent : BaseAgent):
	if not (agent is PlayerAgent):
		return
	var player : PlayerAgent = agent as PlayerAgent
	var peerID : int = player.peerID
	if peerID == NetworkCommons.PeerUnknownID:
		return
	var townMap : WorldMap = null
	if Launcher.World != null:
		townMap = Launcher.World.GetMap(LauncherCommons.DefaultStartMapID)
	var currentMap : WorldMap = WorldAgent.GetMapFromAgent(player)
	var verdict : String = Verdict(townMap != null and currentMap == townMap, townMap != null)
	if verdict != "":
		_Rollback(player)
		Network.FarmZoneFeedback(0, false, verdict, peerID)
		return
	var charID : int = Peers.GetCharacter(peerID)
	if charID != NetworkCommons.PeerUnknownID:
		Presence.Report(Launcher.SQL, charID, maxi(0, Peers.GetAccount(peerID)), player.nick, 0, SQLCommons.Timestamp())
	IdlePolicyService.StopIdleSession(player)
	Launcher.World.Warp(player, townMap, LauncherCommons.DefaultStartPos, ActorCommons.Direction.UNKNOWN, 0)
	Network.FarmZoneFeedback(0, true, "in_town", peerID)

# Recusa devolve a ração: o consumo aconteceu no UseItem antes deste Execute.
func _Rollback(player : PlayerAgent) -> void:
	var scroll : ItemCell = DB.GetItem(ScrollCellHash)
	if scroll != null and player.inventory:
		player.inventory.AddItem(scroll, 1)
