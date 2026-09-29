extends RefCounted
class_name RateLimit

# Orçamento de RPC no CAMINHO DE RECEBIMENTO do servidor (auditoria 2026-09-29, #86).
#
# O que existia antes desta classe: `Peers.Footprint`, chamado por `Network.CallServer`.
# Ele é um intervalo MÍNIMO por (peer, método) — a primeira chamada sempre passa e a
# segunda vale se `carimbo + actionDelta <= now`. Não é cota: quem manda 20 linhas por
# segundo para sempre, manda. E com `actionDelta = NetworkCommons.DelayInstant` (0) ele
# devolve `true` SEMPRE — é o caso de `SetMovePos` e `SetViewportSize`. Somado a isso, o
# próprio `CallServer` é a porta errada para cobrar: quem escreve o pacote escolhe se
# passa por lá, e os handlers do servidor são alcançáveis por dentro do processo
# (`server.TriggerChat(...)`) sem tocar aquela porta nenhuma.
#
# Decisão: a cota mora no RECEBIMENTO, isto é, na primeira linha de cada handler que tem
# efeito sobre OUTRA pessoa ou trabalho caro no servidor. Um pacote não pode comprar
# difusão ilimitada, e um cliente modificado não pode pular a cobrança escolhendo outro
# caminho — o caminho é o handler.
#
# 1) IDENTIDADE. A chave do ledger é `peerID` — o mesmo inteiro que o handler já usa em
#    `Peers.GetAgent(peerID)`, derivado do transporte por `Network.AuthPeerID`
#    (`tests/run_rpc_identity_test.gd` é a régua que guarda isso). Nada aqui lê
#    argumento de pacote para decidir QUEM está sendo cobrado: nem canal, nem nick, nem
#    `characterID`. Esta classe também não deriva identidade de ninguém — ela só conta
#    contra a chave que recebeu. Se um dia o limiter precisar de identidade, ele pede a
#    `Peers`, nunca ao pacote.
# 2) FALHA FECHADA EM VOLUME. Método cobrado que não está na tabela recebe
#    `DefaultBudget`, não "livre": um dígito errado no nome do guard abre uma cota
#    apertada, nunca um buraco.
# 3) ORÇAMENTO COM JANELA, NÃO BANIMENTO. Balde fixo de `WindowSec` segundos; virou o
#    balde, a contagem volta a zero. Recusa é cedo e silenciosa (contador, não log por
#    linha: negar 20 por segundo geraria 20 linhas de log por segundo — o log é
#    amortecido a um por balde por chave).
# 4) A LIÇÃO DO #85 APLICADA AQUI. Um ledger keyed por (sessão, método) é um dicionário
#    que cresce ANTES de qualquer cota fazer efeito, e o #85 é exatamente um dicionário
#    pré-auth sem poda. Então: teto duro de entradas + poda por idade + LRU tocado a
#    cada cobrança, com histerese para o custo ser O(1) amortizado.
# 5) peerID é reciclado pelo transporte, por isso o servidor chama `Forget` na queda da
#    sessão: sem isso o próximo dono do id herdaría a contagem do antecessor (e a
#    herança seria no sentido de punir o inocente).

# Janela fixa de cobrança. 30 s é o compromisso: curto o bastante para um jogador real
# nunca esbarra (ninguém fala 12 linhas em 30 s por 10 minutos seguidos), longo o
# bastante para um flood de 20/s encher o balde em menos de um segundo.
const WindowSec : int			= 30
# Teto do ledger, em ENTRADAS. Conta: `NetworkCommons.MaxPlayerCount` (128) sessões ×
# métodos cobráveis. 2048 = 128 × 16, ou seja, folga para a tabela quadruplicar sem
# nunca deixar este dicionário virar o segundo #85. Custo por entrada medido no mesmo
# formato do #85 (chave String + Array [balde, contagem] + slot): ordem de 100 B, então
# o pior caso é ~200 KiB dentro do teto de 1536 MiB do serviço `game`.
const MaxBuckets : int			= 2048
const EvictBatch : int			= 512
# Cota de um método cobrado que não está na tabela (ver decisão 2): apertada, nunca livre.
const DefaultBudget : int		= 120

# Seam do harness (mesmo formato de `Admission.ClockOverride`): 0 = relógio real.
static var clockOverride : int	= 0

static var buckets : Dictionary = {}	# "peerID|método" -> [balde, contagem], ordem = LRU
static var logBuckets : Dictionary = {}	# chave -> último balde com linha de log escrito
static var allowed : Dictionary = {}	# método -> cobranças aceitas
static var refused : Dictionary = {}	# método -> cobranças recusadas
static var PrunePasses : int	= 0
static var lastPruneWindow : int = -1

# A tabela é o inventário do que tem efeito. Cobrar "tudo" seria negar o jogo: mover o
# dedo, abrir painel, pedir lista. Os números abaixo são por balde de `WindowSec`.
static func BudgetFor(methodName : String) -> int:
	match methodName:
		"TriggerChat":
			# Difusão real (vizinhos, global, guild, whisper). `Peers.Footprint` deixa
			# 20 linhas/s; aqui são 12 por 30 s = 0,4/s sustentado, um corte de 50× no
			# pior caso e invisível para quem joga.
			return 12
		"TriggerEmote":
			return 20
		"TriggerCommand":
			# `CommandManager.Handle` faz trabalho (busca, moderação, painel).
			return 10
		"SetMovePos":
			# `DelayInstant`: hoje não há NENHUM intervalo mínimo. 300/30 s = 10/s,
			# generoso para teclado (uma linha por mudança de direção) e um corte de
			# ~1000× sobre o martelar livre.
			return 300
		"SetViewportSize":
			# Também `DelayInstant`, e cada chamada recalcula a meia-visibility do
			# agente. Janela/redimensionamento legítimo não chega a 2/s.
			return 60
		_:
			return DefaultBudget

# O guard dos handlers. `true` = pode executar o efeito; `false` = o servidor cortou.
static func Charge(peerID : int, methodName : String) -> bool:
	var key : String = "%d|%s" % [peerID, methodName]
	var window : int = int(NowSec() / WindowSec)
	var state : Array = buckets.get(key, [window, 0])
	if int(state[0]) != window:
		state = [window, 0]
	state[1] = int(state[1]) + 1
	# LRU de verdade, mesma régua do #85: sem o toque, a evicção por teto soltaria o
	# agressor ativo primeiro e a poda financiaria o flood.
	buckets.erase(key)
	buckets[key] = state
	if window != lastPruneWindow or buckets.size() > MaxBuckets:
		Prune(window)
	var budget : int = BudgetFor(methodName)
	var over : bool = int(state[1]) > budget
	if over:
		refused[methodName] = int(refused.get(methodName, 0)) + 1
		if int(logBuckets.get(key, -1)) != window:
			logBuckets[key] = window
			Util.PrintLog("RateLimit", "peer %d cortado em %s (%d/%d por balde de %ds)" % [peerID, methodName, int(state[1]), budget, WindowSec])
		return false
	allowed[methodName] = int(allowed.get(methodName, 0)) + 1
	return true

# Queda de sessão: solta as cotas do id antes que o transporte o recicle. O harness
# confere que isto não é decorativo medindo `LedgerSize()` antes e depois.
static func Forget(peerID : int) -> void:
	var prefix : String = "%d|" % peerID
	var stale : Array = []
	for key in buckets:
		if String(key).begins_with(prefix):
			stale.append(key)
	for key in stale:
		buckets.erase(key)
		logBuckets.erase(key)

static func Prune(window : int) -> void:
	PrunePasses += 1
	var stale : Array = []
	for key in buckets:
		if int((buckets[key] as Array)[0]) != window:
			stale.append(key)
	for key in stale:
		buckets.erase(key)
		logBuckets.erase(key)
	if buckets.size() > MaxBuckets:
		var excess : int = buckets.size() - MaxBuckets + EvictBatch
		var keys : Array = buckets.keys()
		for i in range(mini(excess, keys.size())):
			buckets.erase(keys[i])
			logBuckets.erase(keys[i])
	lastPruneWindow = window

static func NowSec() -> int:
	return clockOverride if clockOverride > 0 else int(Time.get_unix_time_from_system())

static func AllowedCount(methodName : String) -> int:
	return int(allowed.get(methodName, 0))

static func RefusalCount(methodName : String) -> int:
	return int(refused.get(methodName, 0))

static func LedgerSize() -> int:
	return buckets.size()

static func WindowOf() -> int:
	return int(NowSec() / WindowSec)

# Só o harness: relógio preso em segundos (0 = relógio real). Sem isto a janela de
# 30 s seria o relógio de parede e a régua teria de dormir 30 segundos por teste.
# `-> void` porque chamar função com retorno como statement é RETURN_VALUE_DISCARDED
# e o projeto trata warning como erro.
static func SetClock(sec : int) -> void:
	clockOverride = sec

# Só o harness: estado limpo e relógio devolvido ao real.
static func Reset() -> void:
	buckets.clear()
	logBuckets.clear()
	allowed.clear()
	refused.clear()
	PrunePasses = 0
	lastPruneWindow = -1
	clockOverride = 0
