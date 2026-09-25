extends Node
# PWA update (beta web): o worker do engine (index.service.worker.js) não tem
# skipWaiting no install — um deploy novo deixa um worker pendente que só assume
# quando recebe postMessage("update"), e aí faz skipWaiting + clients.claim() +
# navigate (medido em build/Web/index.service.worker.js, 2026-09-25). Sem este
# pulso o jogador web ficava no build velho até fechar a aba.
#
# Sem class_name de propósito: o autoload já se chama PwaUpdate (mesma razão de
# WebPush.gd — class_name homônima esconde o autoload e quebra o parse estrito).
# Sem Launcher.gd de propósito: autoload liga sozinho no _ready; o boot não ganha
# mais uma linha. O que esta fiação NÃO faz (decisão registrada): registrar worker
# próprio (deslocaria o do engine e mataria o cache do primeiro load), pedir update
# fora do login (descartaria sessão no meio da partida) nem perguntar duas vezes
# na mesma sessão.

var _asked : bool = false

const POLL_SEC : float = 60.0

func _ready() -> void:
	if not LauncherCommons.isWeb:
		return
	_loop()

func _loop() -> void:
	_pulse()
	while true:
		await get_tree().create_timer(POLL_SEC).timeout
		_pulse()

func _pulse() -> void:
	if _asked:
		return
	if not FSM.IsLoginState():
		return
	if not bool(JavaScriptBridge.pwa_needs_update()):
		return
	# O one-shot só é consumido quando o diálogo pode abrir: `UICommons.MessageBox` é no-op
	# silencioso sem a caixa montada (`sources/gui/UICommons.gd:78-81`), e marcar `_asked`
	# antes de testar custaria a notificação à sessão inteira se o pulso pegasse o GUI fora
	# do ar. A porta de login acima já torna isso raro; aqui é o custo de errar.
	if not (Launcher.GUI and Launcher.GUI.messageBox):
		return
	_asked = true
	UICommons.MessageBox(
		tr("A new version of the game is ready. Update now to keep playing on the latest build."),
		Callable(self, "_confirm_update"), tr("Update now"),
		Callable(self, "_dismiss"), tr("Later"))

func _confirm_update() -> void:
	# A guarda se repete de propósito: entre o diálogo abrir e o botão ser
	# pressionado o jogador pode ter entrado no jogo — aplicar o update ali
	# recarregaria a página no meio da partida, que é exatamente o que a porta
	# de entrada acima proíbe.
	if not FSM.IsLoginState():
		return
	JavaScriptBridge.pwa_update()

func _dismiss() -> void:
	_asked = true
