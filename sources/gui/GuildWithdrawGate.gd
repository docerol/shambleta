extends RefCounted
class_name GuildWithdrawGate

# §14 (AUDITORIA 2026-09-27): o vault era drenável por qualquer oficial num único
# clique, sem limite e sem ninguém ver o rastro. O freio tem DUAS metades, e a ordem
# importa:
#
#   - o SERVIDOR é a verdade (`GuildService.WithdrawFromVault`), porque um limitador que
#     só existe no cliente é decoração: quem modifica o cliente nunca passa por aqui;
#   - este portão é a antecedência — ele dá a mensagem legível antes do clique e evita
#     uma ida ao banco que já se sabe recusada.
#
# Os números moram em `GuildVaultLimits` (uma fonte para as duas metades) e o relógio é
# PARÂMETRO OPCIONAL: `Time.get_unix_time_from_system()` lido dentro da aritmética
# tornava a janela injogável em teste — o que é uma régua de 300 s que ninguém mede é um
# número de comentário. Com `nowSec` injetado, `tests/guild_vault_gate_test.gd` move o
# tempo e confere corte, permanência e o off-by-one da fronteira.
#
# Mora fora do painel porque é aritmética, não UI: o painel pergunta `Reason()` e
# carimba `Record()` no saque que passou, as duas chamadas vindo do mesmo `if` de
# `GuildPanel.WithdrawItem` — é isso que impede a contadora de divergir do rastro que o
# jogador vê em `GuildVaultTrail`.

var _stamps : Array[int] = []

func _now(nowSec : int) -> int:
	return nowSec if nowSec > 0 else int(Time.get_unix_time_from_system())

# "" quando o saque cabe no portão; senão, a mensagem legível do motivo.
func Reason(count : int, nowSec : int = 0) -> String:
	if count > GuildVaultLimits.MaxWithdrawPerAction:
		return "Withdraw: too many in one action (max %d per withdrawal)." % GuildVaultLimits.MaxWithdrawPerAction
	_Prune(_now(nowSec))
	if _stamps.size() >= GuildVaultLimits.MaxWithdrawActionsInWindow:
		return "Withdraw: too many withdrawals in the last %d min (max %d)." % [int(GuildVaultLimits.WindowSec / 60), GuildVaultLimits.MaxWithdrawActionsInWindow]
	return ""

# Carimba o saque aceito. Chamado só depois do service dizer sim.
func Record(nowSec : int = 0) -> void:
	_stamps.append(_now(nowSec))
	_Prune(_now(nowSec))

# Quantos saques ainda contam na janela (estado observável para o painel/harness).
func CountInWindow(nowSec : int = 0) -> int:
	_Prune(_now(nowSec))
	return _stamps.size()

# O carimbo sai da janela quando `WindowSec` é diferença ESTRITA: um saque exatamente
# `WindowSec` atrás já não conta, e `WindowSec - 1` ainda conta — é a fronteira que o
# harness confere nos dois sentidos.
func _Prune(now : int) -> void:
	var kept : Array[int] = []
	for stamp in _stamps:
		if now - int(stamp) < GuildVaultLimits.WindowSec:
			kept.append(int(stamp))
	_stamps = kept
