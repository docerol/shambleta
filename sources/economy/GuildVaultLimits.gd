extends RefCounted
class_name GuildVaultLimits

# Os três números do portão anti-dreno de §14, num lugar só. A mora separada do painel
# porque o limite é do SERVIDOR (`GuildService.WithdrawFromVault` confere a janela antes
# de entregar o item) e o painel só quer avisar antes de gastar o clique — duas metades
# que nunca podem divergir sobre o mesmo número. Com a constante dentro de
# `sources/gui/GuildWithdrawGate.gd`, o servidor teria de importar uma classe de UI
# (camada errada) ou repetir o valor (drift).
#
# `MaxWithdrawActionsInWindow`/`WindowSec` delimitam AÇÕES, não unidades: drenar o vault
# em três saques de dez move 30 por janela de cinco minutos. É freio contra abuso
# oportunista, não política de guild — o rastro completo fica em `guild_vault_log`.

const MaxWithdrawPerAction : int = 10
const MaxWithdrawActionsInWindow : int = 3
const WindowSec : int = 300
