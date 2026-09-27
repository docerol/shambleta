extends RefCounted
class_name StreakRows

# A CARA do streak de login (P2-retenção, AUDITORIA_2026-09-27 §6 — "sem streaks
# em lugar nenhum"): `StreakService` já carimbava o dia e já pagava o degrau no
# login server-side, mas ninguém fora de `tests/balance_test.gd` jamais leu o
# estado, então a mecânica não podia puxar jogador nenhum de volta.
#
# Este módulo não sabe nada de economia e não consulta nada: ele FORMATA o
# payload que o SERVIDOR produziu em `StreakService.View` (que lê `login_streak` e
# projeta a escada). As cinco linhas são funções puras de `Dictionary -> String`
# de propósito — é assim que `tests/balance_test.gd` confere, sem HUD e sem
# servidor, que a tela diz o dia atual, o marco seguinte e o custo de quebrar com
# os MESMOS números que o grant usa. Linha vazia/ausente nunca some da janela: a
# linha vazia é uma linha também, e diz que o servidor ainda não respondeu.

# Cabeçalho: dia vigente + o que o dia de hoje já pagou (0 quando ainda não
# logou no dia do servidor).
static func Headline(state : Dictionary) -> String:
	if state.is_empty():
		return "Streak de login: esperando o servidor..."
	var streak : int = int(state.get("current_streak", 0))
	if streak <= 0:
		return "Streak de login: dia 0 — entre hoje para começar a escada."
	var paid : int = int(state.get("today_reward", 0))
	if bool(state.get("logged_today", false)):
		return "Streak de login: dia %d (melhor %d) — hoje pagou +%d de ouro." % [streak, int(state.get("best_streak", 0)), paid]
	return "Streak de login: dia %d (melhor %d) — o dia de HOJE ainda não foi carimbado." % [streak, int(state.get("best_streak", 0))]

# O próximo marco: qual dia da escada paga o topo do ciclo e quanto.
static func NextMarkLine(state : Dictionary) -> String:
	if state.is_empty():
		return "Próximo login: —"
	return "Próximo login: dia %d paga +%d • marco no dia %d (mais %d dia(s)) libera +%d." % [
		int(state.get("next_day", 0)), int(state.get("next_reward", 0)),
		int(state.get("mark_day", 0)), int(state.get("days_to_mark", 0)), int(state.get("mark_reward", 0))]

# A perda: quebrar a sequência não custa só o degrau de amanhã — devolve a
# posição na escada. O número é o que o SERVIDOR deixa de pagar (`LossOnBreak`).
static func BreakLine(state : Dictionary) -> String:
	if state.is_empty():
		return "Custo de quebrar: —"
	var loss : int = int(state.get("loss_on_break", 0))
	if loss <= 0:
		return "Você está no topo do ciclo: quebrar não perde ouro, mas recomeça a escada do degrau 1."
	return "Quebrar a sequência custa %d de ouro até o marco e volta você ao degrau 1 (100)." % loss

# A escada inteira, para o jogador saber onde está. Vem do payload do servidor
# (mesma `LadderGold` que `RecordLogin` paga), não de uma tabela copiada aqui.
static func LadderLine(state : Dictionary) -> String:
	if state.is_empty():
		return "Escada: —"
	var parts : Array[String] = []
	for row in (state.get("ladder", []) as Array):
		var entry : Dictionary = row
		parts.append("%d:+%d" % [int(entry.get("day", 0)), int(entry.get("gold", 0))])
	if parts.is_empty():
		return "Escada: —"
	return "Escada (%s por ciclo): %s" % [str(int(state.get("cycle_total", 0))), "  ".join(parts)]

# A janela do servidor: o dia vira no divisor UTC da loja/passe, não no relógio
# do aparelho. É o que dá urgência real à linha de cima.
static func CountdownLine(state : Dictionary) -> String:
	if state.is_empty():
		return "O dia do servidor vira em —"
	var seconds : int = int(state.get("reset_in_sec", 0))
	var hours : int = seconds / 3600
	var minutes : int = int(floorf(float(seconds % 3600) / 60.0))
	return "O dia do servidor vira em %dh%02d — faça login antes para manter o streak." % [hours, minutes]

# Monta os cinco rótulos na caixa hospedeira e devolve a lista (o painel guarda a
# referência e só escreve `.text` depois). Ordem é a ordem de leitura: dia,
# próximo passo, perda, escada, relógio. `box` é `Node` (não `Container`) de
# propósito: quem chama passa `$Layout`, e o único método usado é `add_child`.
static func Build(box : Node) -> Array:
	var labels : Array = []
	for i in 5:
		var label : Label = Label.new()
		label.name = "Streak%d" % i
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(label)
		labels.append(label)
	return labels

# Redesenha a partir do estado do servidor (ou do cache vazio, nunca de número
# local). `Refresh` é chamado com o push do login e com a leitura da janela.
static func Refresh(labels : Array, state : Dictionary) -> void:
	if labels.size() < 5:
		return
	(labels[0] as Label).text = Headline(state)
	(labels[1] as Label).text = NextMarkLine(state)
	(labels[2] as Label).text = BreakLine(state)
	(labels[3] as Label).text = LadderLine(state)
	(labels[4] as Label).text = CountdownLine(state)
