extends RefCounted
class_name GuildWithdrawGate

# §14 (AUDITORIA 2026-09-27): o vault era drenável por qualquer oficial num único
# clique, sem limite e sem ninguém ver o rastro. Enquanto o limite de verdade é do
# servidor (requisito exato no relatório — `GuildService.gd` é de outra frente), o
# freio do cliente é: no máximo `MaxWithdrawPerAction` por saque e
# `MaxWithdrawActionsInWindow` saques dentro de `WindowSec`.
#
# Mora fora do painel porque é aritmética, não UI: o painel pergunta `Reason()` e
# carimba `Record()` no saque que passou. As duas chamadas vêm do mesmo `if` do
# `GuildPanel.WithdrawItem` de propósito — é isso que impede a contadora de
# divergir do rastro que o jogador vê em `GuildVaultTrail`.

const MaxWithdrawPerAction : int = 10
const MaxWithdrawActionsInWindow : int = 3
const WindowSec : int = 300

var _stamps : Array[int] = []

# "" quando o saque cabe no portão; senão, a mensagem legível do motivo.
func Reason(count : int) -> String:
	if count > MaxWithdrawPerAction:
		return "Withdraw: too many in one action (max %d per withdrawal)." % MaxWithdrawPerAction
	_Prune()
	if _stamps.size() >= MaxWithdrawActionsInWindow:
		return "Withdraw: too many withdrawals in the last %d min (max %d)." % [int(WindowSec / 60), MaxWithdrawActionsInWindow]
	return ""

# Carimba o saque aceito. Chamado só depois do service dizer sim.
func Record() -> void:
	_stamps.append(int(Time.get_unix_time_from_system()))
	_Prune()

# Quantos saques ainda contam na janela (estado observável para o painel/harness).
func CountInWindow() -> int:
	_Prune()
	return _stamps.size()

func _Prune() -> void:
	var now : int = int(Time.get_unix_time_from_system())
	var kept : Array[int] = []
	for stamp in _stamps:
		if now - int(stamp) < WindowSec:
			kept.append(int(stamp))
	_stamps = kept
