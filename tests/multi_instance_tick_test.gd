extends SceneTree

# multi_instance_tick_test.gd — o teto do PROCESSO: quantos players SOMANDO todas
# as instâncias do mesmo processo cabem no orçamento de tick, e o que acontece
# quando esse total é confrontado com `cpus: 2` / `mem_limit: 1536M` do serviço
# `game` (deploy/docker-compose.yml). Existe por um motivo escrito no próprio
# runbook: `deploy/SCALING.md` §3 mede custo de tick por player numa ZONA e para
# em "~150 na mesma zona", e §6 confessa `[NÃO MEDIDO] o teto do compose ... Falta
# medir N instâncias x 20 no mesmo processo — o número que o beta precisa`. Este
# arquivo mede. Número que ninguém remede é boato, e a régua fica como gate.
#
# Uso:    ./scripts/test.sh fixation        (descoberto por nome; marcador == RESULT:)
#         cru:
#           env XDG_DATA_HOME=/tmp/instmeasure/data XDG_CACHE_HOME=/tmp/instmeasure/cache \
#             timeout 600 godot --headless --path . -s tests/multi_instance_tick_test.gd
# Saída:  uma linha por nível + "== RESULT: <n> checks, <m> failures =="
#         e a tabela `== TABELA (deploy/SCALING.md) ==` que vai transcrita no runbook.
#
# O que ele responde, na ordem:
#   1) A FORMA REAL: N instâncias de farm DEDICADAS, cada uma carregando exatamente
#      `WorldInstance.MAX_PLAYERS_PER_INSTANCE` players (o cap lido do fonte, não
#      digitado aqui) com sessão idle de verdade, ancoradas por dois pontos de
#      referência no MESMO processo: o piso (0 players) e 1 player. A escada é por N
#      de instâncias (1 -> 2 -> 5 -> 10 -> 15 -> 20), nunca por players numa instância
#      só: o que se pergunta é o TOTAL do processo. Como cada nível ACRESCENTA
#      instâncias ao processo (não substitui a zona, como em
#      `tests/tick_capacity_test.gd`), o total medido é literalmente N x cap convivendo
#      no mesmo thread de tick. Cada nível é medido `MeasurePasses` vezes: a régua usa
#      a mediana das passadas e cobra a convergência entre elas.
#   2) O CENSO, por autoridade própria: `world.areas -> map.instances -> inst.players`
#      — a mesma lista que o servidor usa para endereçar visão, chat e fan-out. Um
#      nível só vale se existirem N instâncias distintas, cada uma com `cap` players,
#      `cap` policies e mobs próprios, e se a soma bater com a conta dos agentes que
#      este harness criou. Isso é o que impede o "multi-instância" de ser uma
#      multiplicação na etiqueta: sem censo, 100 players numa instância só faria a
#      linha dizer "5 instâncias".
#   3) OS DOIS DETECTORES de estouro, os mesmos de `tests/tick_capacity_test.gd`
#      (mesmo orçamento, mesmo `ServerMaxFPS`, mesma janela de 120 passos, 30
#      descartados de transitório): o PERÍODO real de parede e o TRABALHO auto-relatado
#      (`Performance.TIME_PHYSICS_PROCESS` + `Performance.TIME_PROCESS`). Publicamos os
#      dois e a discordança entre eles, porque é ela que manda o número do beta ser o
#      conservador (trabalho). O período é medido na FRONTIERA DE TICK (um node comum
#      em `_physics_process`), não no instante em que `await physics_frame` acorda: a
#      acordada é a iteração do engine, e o sleep de pacing paga o atraso de um passo
#      encurtando a iteração seguinte — lida sozinha, ela dizia 33,6 ms lisos num
#      degrau em que o produto contava 16 passos fora do orçamento.
#   3b) A RÉGUA DE CAUDA nos degraus afirmados: p95 e max do TRABALHO, cobrados CONTRA
#      O ORÇAMENTO na pior passada (`CheckCeiling`); e a cauda do PERÍODO cobrada por
#      TAXA de passos acima de orçamento+folga, contra o corte lido de
#      `deploy/alerts.rules.yml` — a mesma grandeza que o alerta pagina. Antes dela o
#      verde era a mediana, e mediana dentro do orçamento convive com cauda fora: um
#      degrau cujo centro cabe e cujo p95 não cabe entrega passos estourados a jogador
#      real e ainda assim imprimia `[ok]`. Por que a cauda de parede não é um teto
#      absoluto: porque o máximo de um servidor ocioso já passava de orçamento+folga
#      (34,08 ms contra 34,33 ms) sem que nenhum passo se perdesse — um teto que fica
#      vermelho por sono do engine não mede carga; o que separa degrau é quantos passos
#      passam (0 até ~40 players, 4 em 100, 16 em 200), e a mordida dessa taxa é provada
#      na perna (b) com 40 ms/passo injetados. A mesma grandeza passa a sair por `/metrics` (`sources/launcher/Launcher.gd` +
#      `sources/system/MetricsServer.gd`), e o nível conferido: o contador exportado e
#      esta janela têm de contar o mesmo passo, senão o alerta pagina etiqueta e não
#      medição.
#   4) MEMÓRIA E CPU DO PROCESSO, lidos do próprio kernel: `VmRSS` de
#      `/proc/self/status` (é RSS, a grandeza que o `mem_limit` do compose morde —
#      `OS.get_static_memory_usage()` é só o heap do engine e é impresso junto, não
#      no lugar) e `utime+stime` de `/proc/self/stat` no mesmo janela, que dá
#      ms de CPU por passo e, dividido pelo período, o número de NÚCLEOS do laço de
#      tick — o que confronta `cpus: 2` com medição em vez de com "~1 core" dito de
#      ouvido. O `USER_HZ = 100` é ABI do Linux e não é medido aqui: por isso o
#      nível de sobrecarga com queima injetada CONFERE a unidade (40 ms/passo de
#      spin têm de aparecer como ~40 ms/passo de CPU).
#   5) A ANTI-VACUIDADE, quatro pernas, todas obrigatórias:
#      (a) CALIBRAÇÃO: 4 ms/passo queimados no processo têm de aparecer no monitor
#          de física (>= 70% do pedido), senão "trabalho medido" é ruído.
#      (b) DETECTOR DE PERÍODO: 40 ms/passo (> 33,33) têm de empurrar o período para
#          fora do orçamento. Sem isto, "nenhum nível estourou" poderia significar
#          "a régua não vê nada".
#      (c) ATRIBUIÇÃO ÀS INSTÂNCIAS: no nível mais carregado, todas as instâncias de
#          farm entram em `PROCESS_MODE_DISABLED` e o passo é remedido. O trabalho TEM
#          de cair, e a queda tem de acompanhar o custo marginal medido x players. É a
#          perna que prova que o número do nível é o das instâncias carregando players
#          — e não o piso do boot disfarçado de curva. A reabertura é cobrada na MESMA
#          moeda — fração do marginal devolvida, e não concordância absoluta com a
#          leitura de antes, que o instrumento não sustenta num degrau saturado.
#      (d) O CENSO MORDE: um player é tirado da instância A e empurrado para a B
#          (sessão idle desligada antes, devolvida depois). O censo tem de mostrar
#          A-1, B+1 e uma instância ACIMA do cap — exatamente o estado que a check de
#          lotação reprovaria. Uma régua que não vê a forma quebrada não mede nada.
#   6) O TETO, publicado como check e não como parágrafo: com a reta dos dois pontos
#      medidos (trabalho por passo vs. total de players) e com a inclinação de RSS por
#      player, o harness calcula (i) total de players dentro dos 33,33 ms, (ii) quantos
#      players cabem antes do RSS encostar nos 1536 M e (iii) o mínimo dos dois, que é
#      o número do beta. Os três saem rotulados como EXTRAPOLAÇÃO do custo medido — o
#      que foi medido é a escada; o que é reta é a projeção.
#
# Como todo harness `-s`: nada de identificador de autoload (Launcher/Network/...)
# nem `class_name` de projeto em anotação de tipo — o main-loop é compilado antes de
# eles existirem. Tudo via load()/get()/call().
#
# Nada aqui apaga dado de usuário: roda no sandbox do gate, os fixtures têm prefixo
# próprio (`MultiInst`) removido no `_finish`, e o processo não abre rede nem escreve
# em banco de produção. PENDÊNCIA DE OUTRO DONO declarada em voz alta: este harness
# ainda não tem linha em `data/conf/teardown_baseline.txt` (o teto de leak do teardown
# por harness, lido por `scripts/ci_gate_log.sh`), porque esse arquivo pertence a outra
# passada — sem linha, o teto aplicado é o do boot magro e o gate `fixation` deste
# harness sai vermelho por contagem de teardown, não por medição. Quem for dono do
# arquivo regrava com `TEARDOWN_RECORD=1` no run deste harness.

# Escada de instâncias. Cada nível ACRESCENTA instâncias ao processo, então o total
# de players do nível é N x cap. `AssertedInstances` é a régua de regressão em si:
# esses níveis TÊM de ficar dentro do orçamento de tick, e um dia vermelho significa
# "o processo piorou", não "a máquina é lenta". Os níveis acima disso (até
# `ProbeInstances`) são medidos para a curva e para as pernas de atribuição: neles a
# pergunta certa é se a régua VÊ a ruptura, não se ela cabe. O topo é 20 porque só
# existem 27 zonas de farm (`FarmZoneData.GetZoneCount()`, conferido no `_run`) e o
# shape exige uma instância dedicada por zona — e porque carregar a zona 22+ sob o
# processo já saturado não completava navegação em 200 frames, o que deixava a
# escada sem o degrau-sonda.
const CapacityInstances : Array[int] = [1, 2, 5, 10, 15, 20]
const AssertedInstances : Array[int] = [1, 2, 5]
const ProbeInstances : int = 20
const MeasurePasses : int = 3				# cada nível é remedido; a régua usa a mediana das passadas
const SampleFrames : int = 120
const WarmupFrames : int = 45			# 1,5 s a 30 Hz: os monitores são média móvel de 1 s
const SkipFrames : int = 30				# descarta o transitório do início da janela
const CalibrationBurnUs : int = 4000	# 4 ms por passo, queimados de propósito
# Captura do monitor da engine sobre queima injetada, MEDIDA nesta máquina: com 4 ms
# de spin por passo, `Performance.TIME_PHYSICS_PROCESS` devolve 2,7–3,4 ms (68–85% de
# captura, janela móvel de 1 s). O piso abaixo é 0,60 — o dobro do ruído de run e
# ainda assim exige que a maior parte da queima apareça. O teto 1,30 existe porque
# monitor que *exagera* a queima é tão inútil como monitor que a esconde.
const CalibrationFloorPct : float = 0.60
const CalibrationCeilPct : float = 1.30
const OverloadBurnUs : int = 40000		# 40 ms/passo > orçamento: tem de estourar de verdade
# Folga do predícado de estouro, em ms. É o MESMO número que o produto declara como
# `StepBudgetToleranceUs` (`sources/launcher/Launcher.gd:@StepBudgetToleranceUs`), e desde
# 2026-10-01 compra a mesma coisa nos dois instrumentos: preempção de scheduler e GC dentro
# do despacho. O sono do throttle saiu da conta porque o predícado deixou de ler o período
# de parede — o predícado em si é `StepBudgetRecord` (`sources/launcher/Launcher.gd:@StepBudgetRecord`).
const PeriodToleranceMs : float = 1.0
# Banda de concordância entre os dois instrumentos do MESMO passo de física (a
# `Cadence` deste harness e o acumulador do laço de produção): os dois abrem na
# fronteira de física e fecham no callback ocioso da mesma iteração, em nós vizinhos
# da árvore, e a diferença entre eles é o trabalho que corre entre um e outro. Seis
# passos numa janela de 120 é o que cabe dessa diferença mais a borda da janela, sem
# cobrar exatidão de relógio.
const PeriodTailAgreementSteps : int = 6
const CpuOverPeriodPct : float = 1.10	# CPU do passo nunca pode passar do muro do período
const AttributionFloorPct : float = 0.50	# a pausa tem de devolver >= 50% do custo marginal previsto
const MonotonicFloorPct : float = 0.70		# degrau mais fundo pode perder <= 30% do passo pro ruído da máquina
# RETORNO: reabrir as instâncias tem de devolver >= 70% do MESMO custo marginal, cobrado
# como (restabelecido − pausa) sobre (degrau cheio − nível 1). Antes era uma concordância
# absoluta de 15% com o degrau cheio, e ela não media "o trabalho voltou": media que uma
# JANELA ÚNICA (as pernas de pausa e retorno chamam `_measure`, uma passada) reproduzisse a
# MEDIANA DE TRÊS PASSADAS do degrau — que é o número de `top` — melhor do que o próprio
# arquivo exige de três passadas medidas em sequência uma da outra, onde `PassAgreeTolPct`
# confessa ±25%. E as duas leituras ainda estão separadas por duas outras janelas (a perna
# de sobrecarga e a de pausa), num degrau onde o runner entrega 66,49 ms de período com
# o laço colado em 1,00 núcleo. O 0,70 não é número novo: é o mesmo desconto de ruído de
# máquina que `MonotonicFloorPct` já dá a um degrau. Medido em 2026-10-01 no runner (run
# 36925101247): 123,91 -> 1,40 -> 98,64 ms, 81% do marginal devolvidos e a forma antiga
# chamou de "não voltou". Nesta máquina, no mesmo dia: 97,46 -> 1,13 -> 95,01 ms, 99% do
# marginal devolvidos, e aí a forma antiga passou — porque 2,45 ms de desvio cabem nos 15% de
# 97,46, não porque a régua tenha medido o retorno. Ela verdeava de margem, não de medição.
const ResumeRecoverFloorPct : float = 0.70
# RUÍDO EXTERNO: fração da MÁQUINA INTEIRA que trabalho de OUTRO processo come
# durante uma janela de medição. 25% não é escolha de manual: é o dobro do que o
# `cpus: 2` do compose admite num host de 12 núcleos (2/12 = 16,7%), então uma
# janela em que alheio come mais que isso já não é a máquina cuja promessa está
# sendo lida. Medido em 2026-09-28 com um jogo do usuário rodando (load 11,6-15
# num host de 12): o piso do processo saiu 60,66 ms contra 11,11 ms medidos dois
# minutos antes no mesmo harness, e a escada inteira leu 370 µs/player contra a
# fence de 340 — veredito falso, de produto, causado por vizinho.
const ForeignCpuNoisePct : float = 25.0
# Espera por janela limpa: 15 s por janela e 90 s no run inteiro. O teto curto é o
# que cabe no timeout de 300 s do gate (`gates_extra` em `scripts/test.sh` é a
# chamada real deste harness em `all`) — espera sem teto trocaria um veredito falso
# por um timeout, que é outro veredito falso. Quem quiser a régua inteira numa máquina
# tomada aumenta só o teto do run: `SHAMBLETA_NOISE_WAIT_MS` (0 desliga a espera;
# o valor é cortado em 600 s para um typo não pendurar o gate).
const NoiseWaitWindowMs : int = 15000
const NoiseWaitBudgetMs : int = 90000
const NoiseWaitCapMs : int = 600000
const NickPrefix : String = "MultiInst"
const AcctPrefix : String = "multiinst"
const ComposeMemLimitMb : int = 1536	# mem_limit do serviço `game` (deploy/docker-compose.yml)
const ComposeCpus : float = 2.0			# cpus do mesmo serviço
const RssPath : String = "/proc/self/status"
const StatPath : String = "/proc/self/stat"
const HostStatPath : String = "/proc/stat"
const LoadAvgPath : String = "/proc/loadavg"
const LimitsPath : String = "/proc/self/limits"
const FdDirPath : String = "/proc/self/fd"
const ProcReadBytes : int = 16384			# janela de leitura dos três arquivos de /proc
const ClockTicksPerSecond : int = 100	# ABI do Linux; conferida pela perna (b)

# RÉGUA DE REGRESSÃO (não é prosa: é check, e um vermelho aqui significa "o processo
# piorou", não "a máquina está ocupada"). Custo marginal MEDIDO de tempo de passo por
# player convivente no mesmo processo, em µs/passo. O valor medido nesta máquina com a
# escada toda dentro do orçamento é ~235 µs; a régua aceita até 340 µs (+45%), folga
# medida sobre o spread entre passadas e entre execuções do run. Passou disso, ou
# passou do `cpus: 2` do compose no degrau afirmado, o gate fecha.
const MarginalUsPerPlayerFence : float = 340.0
# O degrau que o beta planeja sustentar: 10 instâncias CHEIAS = 200 players no mesmo
# processo, medidos dentro do orçamento. Menos que isso é regressão de capacidade.
const CeilingFencePlayers : int = 200
const ScalingDocPath : String = "res://deploy/SCALING.md"

# RÉGUA DE CONVERGÊNCIA ENTRE PASSADAS, reescrita com os números de um host QUIETO.
# A versão antiga exigia `max − mín <= max(2 ms, 30% da mediana)` sobre as medianas das
# três passadas. Medido em 2026-09-28 num host com `NOISE-DECLARED: 0` (ou seja: as
# réguas de tempo LIDAS), o spread das medianas foi 0.06 (piso) / 0.49 (1 player) /
# 0.25 (1x20) / 2.53 (2x20) / 1.29 (5x20) / 1.55 (10x20) / 1.63 (15x20) / 10.50 ms
# (20x20); o degrau 2x20 vermelhou com passadas [5.13, 7.66, 5.52] enquanto o período
# de parede continuava 33.60 ms nos três tiros. A causa é de medição, não de produto:
# `medianMs` é a mediana de 90 amostras de MONITORES DE MÉDIA MÓVEL de 1 s
# (`TIME_PHYSICS_PROCESS`/`TIME_PROCESS`), então uma "amostra" não é independente —
# a janela inteira tem ~3 observações de fato, e o range de 3 observações não é um
# limite para nada além de si mesmo. Continuar cobrando spread ali era uma régua com
# poder estatístico ~0 e taxa de falso vermelho alta. As três perguntas que o beta
# decide, cada uma na sua régua:
const PassAgreeTolPct : float = 0.25		# maioria das passadas dentro de ±25% da mediana

var checks : int = 0
var failures : int = 0
var launcher : Node = null
var sql : Node = null
var world : Node = null
var dbScript : GDScript = null
var worldAgentScript : GDScript = null
var worldInstanceScript : GDScript = null
var policyScript : GDScript = null
var actorCommonsScript : GDScript = null
var spawnScript : GDScript = null
var farmScript : GDScript = null
var commonsScript : GDScript = null
var suites : RefCounted = null

var budgetMs : float = 33.3
var cap : int = 20
var zoneBase : int = 1000
var bossBase : int = 9000
var serverFps : int = 30
var calib : Node = null
var cadence : Node = null
var agents : Array = []
var charIDs : Array = []
var rows : Array = []
var nextZone : int = 1
var rssFloorMb : int = 0
var procLimitMb : int = 0
var fdFloor : int = 0
var threadFloor : int = 0
var nofileSoft : int = -1
var nofileHard : int = -1
var nprocSoft : int = -1
var proofsRan : int = 0
var floorMs : float = 0.0
var alertPagePct : float = -1.0
var onePlayerMs : float = 0.0
var marginalUs : float = 0.0
var marginalInsideUs : float = 0.0
var deepestInsidePlayers : int = 0
var ceilingPlayers : int = 0
var tickCeilingPlayers : int = 0
var memCeilingPlayers : int = 0
var ceilingInstancesCount : int = 0
var noiseUnmeasured : int = 0
var noiseWaits : int = 0
var noiseWaitMs : int = 0
var noiseWindows : int = 0
var worstForeignPct : float = 0.0
var timingNoiseActive : bool = false

# Calibre: queima `us` de tempo real por passo de física dentro da MESMA árvore de
# processamento que as WorldInstance (um Node filho de `root`, sem prioridade
# especial). Mesma sonda de `tests/tick_capacity_test.gd`: se a régua não enxerga
# trabalho que ela mesma manda queimar, nada mais desta saída é medição.
class Burn extends Node:
	var us : int = 0
	var steps : int = 0
	func _physics_process(_delta : float) -> void:
		if us <= 0:
			return
		var started : int = Time.get_ticks_usec()
		steps += 1
		while Time.get_ticks_usec() - started < us:
			pass

# Fronteira de TICK e janela de DESPACHO, no mesmo node. O `_physics_process` de um
# node comum roda uma vez por passo de física, no MESMO ponto do despacho onde
# `sources/launcher/Launcher.gd` abre a sua janela, e o `_process` do mesmo node fecha
# a dela — é o que faz os dois instrumentos contarem o mesmo passo. Medido neste
# harness, degrau a degrau: o contador do produto viajava de 0 a 10 passos acima de
# orçamento+folga por janela enquanto a série de `await physics_frame` não via NENHUM —
# a régua de concordância estava lendo a própria cegueira do instrumento.
#
# A janela é `despacho`, não `período`, desde 2026-10-01: o período de parede de um
# processo com o throttle ligado é orçamento + sono, e um predícado sobre ele denuncia
# o servidor ocioso (ver o cabeçalho de `sources/launcher/Launcher.gd`). Os `marks`
# continuam saindo porque a série de período é a testemunha impressa do "30 Hz foi
# cumprido" — só deixou de ser o que a régua de cauda cobra.
class Cadence extends Node:
	var armed : bool = false
	var marks : Array = []
	var brackets : Array = []
	var openUs : int = 0
	var openPending : bool = false
	func _physics_process(_delta : float) -> void:
		if not armed:
			return
		var now : int = Time.get_ticks_usec()
		marks.append(now)
		# Dois `_physics_process` sem um `_process` entre eles é o catch-up do engine: o
		# produto registra 0 µs para o passo engolido, e registrar o bracket do vizinho
		# aqui seria a mesma mentira em espelho.
		if openPending:
			brackets.append(0)
		openUs = now
		openPending = true
	func _process(_delta : float) -> void:
		if not armed or not openPending:
			return
		brackets.append(Time.get_ticks_usec() - openUs)
		openPending = false

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(actual : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	# Comparar tipos diferentes aborta a expressão em GDScript 4 e a check abortada
	# não era contada como falha (mesma armadilha pegada em doc_facts_test.gd).
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] %s (esperado %s, atual %s)" % [label, str(expected), str(actual)])
		return false
	print("  [ok] " + label)
	return true

func Note(text : String) -> void:
	print("  . " + text)

# Réguas de TEMPO DE PAREDE (ms/passo, µs/player, players-dentro-do-orçamento) só
# podem ser lidas numa janela em que a máquina é desta medição. Quando o ruído
# externo venceu a espera, a saída honesta é `[RUIDO]` — nem `[ok]` (a régua não foi
# lida, e dizer que foi é a mentira) nem `[FAIL]` (o produto não fez nada de errado;
# quem está jogando no host também não). O censo do que ficou não-medido sai na
# linha de ruído do fim, e é ela que o portão imprime: verde com réguas não lidas é
# dito, não escondido. Retornar `true` no galho de ruído mantém o fluxo de quem
# chama no caminho de "não houve veredito", e não no de falha.
# As duas decisões de leitura, puras e portanto conferíveis por mesa (perna (e)):
# quais réguas de tempo este run pode ler? É a única parte da régua de ruído que não
# depende de medir nada — e sem mesa, uma inversão de sinal aqui (`not condition` no
# lugar de `condition`) deixaria o portão lendo vermelhos fabricados pelo vizinho, ou
# recusando verdes válidos, e nada no repo contaria qual dos dois aconteceu.
#
# `readsTiming`: sob ruído, nenhuma asserção relacional é lida (verde poderia ser
# fabricado pela janela de referência).
# `readsCeiling`: sob ruído, um teto CUMPRIDO continua sendo leitura — o vizinho só
# pode inflar o tempo desta janela, nunca deflate-la.
static func readsTiming(noisy : bool) -> bool:
	return not noisy

static func readsCeiling(condition : bool, noisy : bool) -> bool:
	return (not noisy) or condition

# Quantas passadas cabem em ±`tolPct` do valor central. É a estatística da maioria:
# com três passadas, uma outlier isolada não veto o degrau (ela é uma observação de
# um monitor de média móvel), mas duas fora significa nível bimodal e a régua morde.
static func passAgreement(medians : Array, center : float, tolPct : float) -> int:
	var agree : int = 0
	for sample in medians:
		if absf(float(sample) - center) <= absf(center) * tolPct:
			agree += 1
	return agree

# Quanto a fração da máquina atribuída a ESTE processo deve subir com uma queima
# injetada. O teto físico é um núcleo, não o orçamento: o laço de tick é um thread só,
# então `ourUs/wallUs` não passa de 1,00 quando o passo já está work-bound — e o
# período estica junto com a queima. Medido no degrau-sonda (20x20, 12 núcleos):
# 8.4% -> 8.3% da máquina com 40 ms/passo injetados, porque o processo já estava
# colado nos 8.33% = 1,00 núcleo. Prever +10 pts ali era pedir o impossível; a queima
# só é prova de numerador onde há folga (o calibre, no degrau mais leve).
static func ownRisePct(burnUs : int, periodMs : float, cores : int, ownCoresBefore : float) -> float:
	var addedCores : float = float(burnUs) / 1000.0 / maxf(periodMs, 0.001)
	var usable : float = minf(addedCores, maxf(0.0, 1.0 - ownCoresBefore))
	return 100.0 * usable / float(maxi(cores, 1))

func CheckTiming(condition : bool, label : String) -> bool:
	if readsTiming(timingNoiseActive):
		return Check(condition, label)
	noiseUnmeasured += 1
	print("  [RUIDO] " + label)
	return true

# TETO ("não estoura"): um vizinho ocupado só pode AUMENTAR o tempo que UMA janela de
# medição enxerga — preemption e fila de scheduler entram no relógio wall do passo,
# nunca saem dele. Então um teto cumprido numa janela suja continua cumprido na janela
# quieta, e essa é a única das réguas de tempo que sobrevive ao ruído: negá-la seria
# jogar fora, numa máquina de desenvolvimento, justamente as fences que o beta cuida
# (período e trabalho dentro do orçamento, Hz entregue). Vermelho dela é inconclusivo.
#
# A elegibilidade não é "a desigualdade é de menos-que": é "a grandeza sai de UMA
# janela". Uma diferença de duas janelas (custo do player = nível − piso, spread entre
# passadas, µs/player marginal, a âncora contra o número do doc) pode ENCOLHER pelo
# ruído da janela de referência, e aí o verde passa a ser fabricável pelo vizinho —
# essas continuam em `CheckTiming`, onde um verde não é lido como prova.
func CheckCeiling(condition : bool, label : String) -> bool:
	if readsCeiling(condition, timingNoiseActive):
		return Check(condition, label)
	noiseUnmeasured += 1
	print("  [RUIDO] " + label + " (teto: verde sob ruído ainda vale, vermelho não)")
	return true

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_run()

func _median(values : Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted : Array = values.duplicate()
	sorted.sort()
	return float(sorted[int(sorted.size() / 2)])

func _p(value : float, values : Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted : Array = values.duplicate()
	sorted.sort()
	var idx : int = clampi(int(ceil(float(sorted.size()) * value)) - 1, 0, sorted.size() - 1)
	return float(sorted[idx])

# Delta em milissegundos entre marcas consecutivas de `Time.get_ticks_usec()`: uma
# observação por fronteira, sem média móvel no meio. Uma marca só devolve série vazia
# (sem passo anterior não existe período), e é por isso que o censo de observações é
# impresso e conferido, não presumido.
func _periods(marks : Array) -> Array:
	var out : Array = []
	var previous : int = 0
	for mark in marks:
		var now : int = int(mark)
		if previous > 0:
			out.append(float(now - previous) / 1000.0)
		previous = now
	return out

# µs de janela -> ms por passo, sem diferenciar nada: a `Cadence` acima já emite uma
# observação por passo (e 0 para o passo que o catch-up engoliu, que é o que o produto
# registra). É por isso que o comprimento desta série tem de bater com o da série de
# período, e a check logo abaixo confere em vez de presumir.
func _msFromUs(values : Array) -> Array:
	var out : Array = []
	for value in values:
		out.append(float(int(value)) / 1000.0)
	return out

# Posição de um node numa lista de irmãos. Puro porque `Node.get_child_index` não é
# chamado por node em GDScript 4 (é método do PAI), e esta régua precisa da posição dos
# dois instrumentos na MESMA ordem de despacho que o engine usa.
func _indexOf(siblings : Array, who : Node) -> int:
	var index : int = 0
	for sibling in siblings:
		if sibling == who:
			return index
		index += 1
	return -1

# Quantas amostras de despacho NÃO cabem na parede entre as duas fronteiras do mesmo
# passo. Tem de ser zero por construção: o bracket fecha num `_process` da iteração, e
# o período do mesmo índice vai até o `_physics_process` da iteração SEGUINTE — a janela
# medida é um sub-intervalo da parede. Um índice maior que o período é a assinatura de
# que as duas séries não contam o mesmo passo (catch-up, ou um node realocado no meio
# da medição), e é exatamente a classe de defeito que deixou esta régua ler o próprio
# instrumento como se fosse o produto.
static func _bracketEscapes(windows : Array, periods : Array) -> int:
	var escapes : int = 0
	var count : int = mini(windows.size(), periods.size())
	for index in range(count):
		if float(windows[index]) > float(periods[index]):
			escapes += 1
	return escapes

# O desencontro de CENSO entre as duas séries, julgado com a única tolerância que o
# próprio instrumento tem direito: `periods` é `marks - 1` (a última fronteira ainda não
# tem sucessora), e o desarmar da janela pode pegar o último `mark` ou antes ou depois do
# `_process` que o fecha. Então `windows` tem de ser `periods` ou `periods + 1`, e mais
# que isso é população diferente. A versão anterior cobrava esse excedente legítimo DENTRO
# de `_bracketEscapes` e de novo por fora (`absi(windows - periods)`), e por isso devolvia
# `drift 2` num servidor saudável em todos os degraus medidos em 2026-10-01: a régua
# contava duas vezes o mesmo último bracket.
static func _alignmentDrift(windows : Array, periods : Array) -> int:
	var drift : int = _bracketEscapes(windows, periods)
	var surplus : int = windows.size() - periods.size()
	if surplus > 1 or surplus < 0:
		drift += 1
	return drift

# O corte de página do produto, LIDO do próprio `deploy/alerts.rules.yml` (a regra
# `PassoForaDoOrcamento`). A régua de cauda deste harness cobra a mesma grandeza com o
# mesmo número, e por isso não guarda cópia: zero expressões casadas, ou mais de uma, é
# vermelho — um `expr` que mudou de forma deixaria de ser conferido, e "conferido" que
# não lê nada é etiqueta.
static func _alertPagePct() -> float:
	var file : FileAccess = FileAccess.open("res://deploy/alerts.rules.yml", FileAccess.READ)
	if file == null:
		return -1.0
	var text : String = file.get_as_text()
	file.close()
	var regex : RegEx = RegEx.create_from_string("rate\\(shambleta_step_over_budget_total\\[5m\\]\\)\\s*/\\s*rate\\(shambleta_steps_measured_total\\[5m\\]\\)\\s*>\\s*([0-9]+\\.?[0-9]*)")
	if regex == null:
		return -1.0
	var found : Array[RegExMatch] = regex.search_all(text)
	if found.size() != 1:
		return -1.0
	return float(found[0].get_string(1)) * 100.0

func _frames(count : int) -> void:
	for i in range(count):
		await process_frame

# ------------------------------------------------------------------ kernel: RSS e CPU

# Le um arquivo de /proc. Os três leitores abaixo têm de usar `get_buffer()` e NAO
# `get_as_text()`: os arquivos de /proc reportam `st_size` 0, e um leitor que confia
# no tamanho declarado devolve string vazia — RSS lido como 0 aqui viraria
# extrapolação sobre zeros (o defeito que `tests/scale_test.gd` registra no seu
# `Pages()`, na mesma família). Os erros desta função são checks, não cosmética.
func _readProc(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes : PackedByteArray = file.get_buffer(ProcReadBytes)
	file.close()
	if bytes.is_empty():
		return ""
	return bytes.get_string_from_utf8()

# `VmRSS` de /proc/self/status, em MB inteiros; -1 quando não foi lido. É a grandeza
# que o `mem_limit` do compose morde.
func _rssMb() -> int:
	var text : String = _readProc(RssPath)
	var kb : int = -1
	for line in text.split("\n"):
		if String(line).begins_with("VmRSS:"):
			for part in String(line).split(" ", false):
				if String(part).is_valid_int():
					kb = int(String(part))
			break
	return -1 if kb < 0 else int(kb / 1024)

# utime+stime do processo em micros de CPU (todos os threads). Campos 14/15 depois
# do `comm`, que pode conter espaços — daí o rfind do parêntese.
func _cpuUs() -> int:
	var text : String = _readProc(StatPath)
	var close : int = text.rfind(")")
	if close < 0 or close + 2 >= text.length():
		return -1
	var fields : PackedStringArray = text.substr(close + 2).split("\n")[0].split(" ", false)
	# `comm` + `state` abertos: depois do parêntese, `state` é o índice 0, então
	# `utime` cai em 11 e `stime` em 12 (contados de `proc(5)`).
	if fields.size() < 13:
		return -1
	if not fields[11].is_valid_int() or not fields[12].is_valid_int():
		return -1
	var ticks : int = int(fields[11]) + int(fields[12])
	return int(ticks * 1000000 / ClockTicksPerSecond)

# µs de CPU que a MÁQUINA INTEIRA gastou (a linha `cpu ` agregada de /proc/stat, em
# jiffies de 1/100 s somados sobre todos os núcleos, menos idle e iowait). Junto com o
# wall clock da janela e o CPU deste processo, é a única grandeza que diz se esta
# janela pode ler uma régua de tempo.
func _hostBusyUs() -> int:
	var text : String = _readProc(HostStatPath)
	for raw in text.split("\n"):
		var line : String = String(raw)
		if not line.begins_with("cpu "):
			continue
		var fields : PackedStringArray = line.split(" ", false)
		if fields.size() < 5:
			return -1
		var total : int = 0
		var resting : int = 0
		for i in range(1, fields.size()):
			if not fields[i].is_valid_int():
				break
			total += int(fields[i])
			if i == 4 or i == 5:
				resting += int(fields[i])
		return int((total - resting) * 1000000 / ClockTicksPerSecond)
	return -1

func _loadavg1() -> float:
	var parts : PackedStringArray = _readProc(LoadAvgPath).split(" ", false)
	if parts.is_empty() or not String(parts[0]).is_valid_float():
		return -1.0
	return float(parts[0])

# Puro de propósito: a conta abaixo é conferida por mesa de casos na perna (e), e um
# caso construído é a única maneira de provar que a sonda subtrai a si mesma — carga
# própria não é ruído, é o produto sendo medido.
static func foreignPct(wallUs : int, hostBusyUs : int, ourUs : int, cores : int) -> float:
	if wallUs <= 0 or cores <= 0 or hostBusyUs < 0 or ourUs < 0:
		return -1.0
	var otherUs : float = float(hostBusyUs) - float(ourUs)
	if otherUs < 0.0:
		otherUs = 0.0
	# O agregado de /proc/stat é arredondado em jiffies e o delta deste processo vem da
	# mesma fonte; clampar acima em 100 é o que impede um round de virar "110% alheio".
	return minf(100.0, 100.0 * otherUs / (float(wallUs) * float(cores)))

static func isNoisy(pct : float) -> bool:
	return pct > ForeignCpuNoisePct

# Orçamento de espera lido do ambiente, com teto: o default protege o timeout do gate,
# e o override existe para quem quer a régua inteira numa máquina tomada.
func _noiseBudgetMs() -> int:
	var raw : String = ""
	if OS.has_environment("SHAMBLETA_NOISE_WAIT_MS"):
		raw = String(OS.get_environment("SHAMBLETA_NOISE_WAIT_MS"))
	if raw.is_valid_int():
		return clampi(int(raw), 0, NoiseWaitCapMs)
	return NoiseWaitBudgetMs

# O limite de memória REAL deste processo (ulimit/address space), lido de
# /proc/self/limits. Não é o `mem_limit` do compose — é a comparação honesta do que
# esta máquina impõe hoje com o que o compose vai impor no beta; impresso para o
# leitor saber qual chão está medindo. -1 quando é unlimited (o caso desta máquina),
# que também é informação.
func _procLimitMb() -> int:
	var text : String = _readProc(LimitsPath)
	var out : int = -1
	for raw in text.split("\n"):
		var line : String = String(raw).replace("\t", " ")
		if line.begins_with("Max address space") or line.begins_with("Max resident set"):
			var parts : PackedStringArray = line.split(" ", false)
			if parts.size() >= 5 and parts[3].is_valid_int():
				var value : int = int(parts[3])
				if parts[4] == "KB":
					out = value / 1024
				elif parts[4] == "bytes":
					out = value / 1048576
				elif parts[4] == "MB":
					out = value
			break
	return out

# O par (soft, hard) de uma linha de `/proc/self/limits`, procurada pelo título.
# "unlimited" vira -1 (declarado como tal na saída: é medida, não ausência). Isto é
# o chão deste processo NESTA máquina — RLIMIT_NOFILE e RLIMIT_NPROC variam por
# host/distro, então não existe constante portável aqui: só o que foi lido.
func _procLimitPair(title : String) -> Vector2i:
	var text : String = _readProc(LimitsPath)
	for raw in text.split("\n"):
		var line : String = String(raw).replace("\t", " ")
		if line.begins_with(title):
			var parts : PackedStringArray = line.split(" ", false)
			var offset : int = title.split(" ", false).size()
			if parts.size() < offset + 2:
				return Vector2i(-2, -2)
			return Vector2i(_limitToken(parts[offset]), _limitToken(parts[offset + 1]))
	return Vector2i(-2, -2)

func _limitToken(token : String) -> int:
	if token == "unlimited":
		return -1
	if token.is_valid_int():
		return int(token)
	return -2

# Descritores abertos e threads vivos deste processo, contados pelo kernel (não pelo
# engine): `OS.get_processor_count()` não diz nada sobre o custo de uma instância, e
# é o custo por instância que decide quantas instâncias o processo pode segurar antes
# de esbarrar no rlimit.
func _fdCount() -> int:
	var dir : DirAccess = DirAccess.open(FdDirPath)
	if dir == null:
		return -1
	dir.list_dir_begin()
	var count : int = 0
	var name : String = dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			count += 1
		name = dir.get_next()
	dir.list_dir_end()
	return count

func _threadCount() -> int:
	var text : String = _readProc(RssPath)
	for raw in text.split("\n"):
		var line : String = String(raw)
		if line.begins_with("Threads:"):
			var parts : PackedStringArray = line.split(":", false)
			if parts.size() >= 2 and String(parts[1]).strip_edges().is_valid_int():
				return int(String(parts[1]).strip_edges())
	return -1

# --------------------------------------------------------------------------- censo

# A autoridade é `map.instances -> inst.players`, a mesma lista com que o servidor
# endereça visão, chat e fan-out. `dedicado` conta só instâncias de zona de farm
# (id entre `ZoneInstanceBase` e `BossInstanceBase`), que é a forma multi-instância
# real do cap: uma instância dedicada por zona, e o cap de players por instância
# sendo a unidade de planejamento do processo.
func _census() -> Dictionary:
	var entries : Array = []
	var total : int = 0
	var overCap : int = 0
	var biggest : int = 0
	var policies : int = 0
	var mobs : int = 0
	var mapsWithDedicado : int = 0
	var areas : Dictionary = world.get("areas")
	for mapID in areas:
		var mapObj : Object = areas[mapID]
		if mapObj == null:
			continue
		var instances : Dictionary = mapObj.get("instances")
		var inThisMap : int = 0
		for key in instances:
			var id : int = int(key)
			if id < zoneBase or id >= bossBase:
				continue
			var inst : Object = instances[key]
			if inst == null:
				continue
			var count : int = (inst.get("players") as Array).size()
			if count == 0:
				continue
			var mobCount : int = (inst.get("mobs") as Array).size()
			var policyCount : int = (inst.get("idlePolicies") as Array).size()
			total += count
			policies += policyCount
			mobs += mobCount
			biggest = maxi(biggest, count)
			if count > cap:
				overCap += 1
			inThisMap += 1
			entries.append({"id": id, "players": count, "mobs": mobCount, "policies": policyCount, "inst": inst})
		if inThisMap > 0:
			mapsWithDedicado += 1
	entries.sort_custom(func(a, b) -> bool: return int(a["id"]) < int(b["id"]))
	var mine : int = 0
	for agent in agents:
		if agent != null and is_instance_valid(agent) and (agent.get("listedIn") as Object) != null:
			mine += 1
	return {
		"entries": entries,
		"instances": entries.size(),
		"players": total,
		"overCap": overCap,
		"biggest": biggest,
		"policies": policies,
		"mobs": mobs,
		"maps": mapsWithDedicado,
		"mine": mine,
	}

func _censusText(census : Dictionary) -> String:
	var text : String = ""
	for entry in census["entries"]:
		text += "#%d=%d " % [int(entry["id"]), int(entry["players"])]
	return text if text != "" else "(vazio)"

# --------------------------------------------------------------------------- seed

func _fixture(index : int) -> int:
	var charID : int = int(suites.call("CreateFixture", sql, "%s%03d" % [AcctPrefix, index], "%s%03d" % [NickPrefix, index]))
	if charID != 0:
		charIDs.append(charID)
	return charID

func _playerSpawn(mapObj : Object) -> Object:
	var types : Dictionary = actorCommonsScript.get_script_constant_map().get("Type", {})
	var spawnPoint : Object = spawnScript.new()
	spawnPoint.set("map", mapObj)
	spawnPoint.set("type", int(types.get("PLAYER", 0)))
	spawnPoint.set("id", int(dbScript.get("PlayerHash")))
	spawnPoint.set("is_global", false)
	spawnPoint.set("spawn_offset", Vector2i(32, 32))
	var monsterType : int = int(types.get("MONSTER", 2))
	for spawn in (mapObj.get("spawns") as Array):
		if spawn != null and int(spawn.get("type")) == monsterType:
			spawnPoint.set("spawn_position", spawn.get("spawn_position"))
			break
	return spawnPoint

# Carga (não semeadura): garante que a instância dedicada da zona existe, está pronta
# e que o mapa tem navegação. IRRUDIANTE de propósito — `_seedInstance` é corrotina
# (tem `await`), e chamar uma sem `await` entregaria um estado de coroutine no lugar
# do dicionário. `tick_capacity` resolve o mesmo problema chamando `_seedZone` na
# hora de semear cada nível; aqui o desenho é acumular instâncias, então a carga tem
# de ser separada da semeadura de players.
func _ensureZoneInstance(zoneID : int) -> Object:
	var zone : Object = farmScript.call("GetZone", zoneID)
	if zone == null:
		return null
	var mapObj : Object = world.call("GetMap", int(zone.get("mapID")))
	if mapObj == null:
		return null
	var instID : int = int(policyScript.call("GetFarmInstanceID", zoneID))
	var instances : Dictionary = mapObj.get("instances")
	var inst : Object = instances.get(instID, null)
	if inst == null:
		mapObj.call("CreateInstance", instID)
		inst = instances.get(instID, null)
	for _i in range(200):
		inst = instances.get(instID, null)
		if inst != null and bool(inst.is_node_ready()) and int(NavigationServer2D.map_get_iteration_id(mapObj.get("mapRID"))) > 0:
			return inst
		await process_frame
	return null

# Uma instância dedicada de zona carregando exatamente `count` players reais com
# sessão idle de verdade. Idêntica ao `tests/tick_capacity_test.gd` no caminho de
# spawn (WorldAgent.CreateAgent + IdlePolicyService.StartIdleSession), porque é esse
# o shape cujo custo o beta precisa conhecer. Não é corrotina até o fim do seed: o
# único `await` é o aquecimento, e é por isso que a carga do mapa vive em
# `_ensureZoneInstance`, separada daqui.
func _seedPlayers(zoneID : int, inst : Object, count : int) -> Dictionary:
	var out : Dictionary = {"inst": inst, "players": 0, "sessions": 0}
	var zone : Object = farmScript.call("GetZone", zoneID)
	if zone == null:
		out["inst"] = null
		return out
	var mapObj : Object = world.call("GetMap", int(zone.get("mapID")))
	if mapObj == null:
		out["inst"] = null
		return out
	var instID : int = int(policyScript.call("GetFarmInstanceID", zoneID))
	for i in range(count):
		var charID : int = _fixture(charIDs.size() + 1)
		if charID == 0:
			break
		var agent : Node = worldAgentScript.call("CreateAgent", _playerSpawn(mapObj), instID, "%s%03d" % [NickPrefix, charID]) as Node
		if agent == null:
			break
		agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
		agents.append(agent)
		out["players"] = int(out["players"]) + 1
		if bool(policyScript.call("StartIdleSession", agent, zoneID)):
			out["sessions"] = int(out["sessions"]) + 1
	await _frames(WarmupFrames)
	return out

func _setDedicadosPaused(paused : bool) -> int:
	var touched : int = 0
	var census : Dictionary = _census()
	for entry in census["entries"]:
		var inst : Object = entry["inst"]
		if inst == null or not is_instance_valid(inst):
			continue
		inst.call("set_process_mode", Node.PROCESS_MODE_DISABLED if paused else Node.PROCESS_MODE_INHERIT)
		touched += 1
	return touched

# ------------------------------------------------------------------------------ medição

# Amostra `SampleFrames` passos de física. Trabalho por passo = soma dos dois
# monitores que o próprio engine acumula em janela móvel de 1 s (mesma dupla e mesma
# calibração de `tests/tick_capacity_test.gd`); o que a régua de cauda cobra é a
# JANELA DE DESPACHO da `Cadence` acima (a mesma que o produto cronometra), e as três
# leituras de relógio — despacho, fronteira de tick, fronteira de iteração — saem
# impressas lado a lado. Aqui entram também RSS e ms de CPU por passo, que é o que
# confronta o total de players com `mem_limit` e `cpus` do compose.
func _measureOnce(label : String, totalPlayers : int, instances : int) -> Dictionary:
	var work : Array = []
	var physSamples : Array = []
	var idleSamples : Array = []
	# CAUDA POR PASSO. As amostras de `work` são monitores de média móvel de 1 s: a
	# p95 delas é a cauda das JANELAS, não dos passos — e foi exatamente isso que
	# deixou 42,09 ms de p95 conviver com um verde de mediana. Estes aqui são deltas
	# de parede entre duas fronteiras consecutivas: uma observação por passo, com a
	# qual um p95/max significa "quantos passos não couberam no tick".
	#
	# DUAS FRONTEIRAS, e a que a régua de cauda cobra é a JANELA DE DESPACHO.
	# `stepPeriodsMs` marca a ITERAÇÃO do engine (o instante em que `physics_frame` é
	# emitido e a corrotina acorda); `tickPeriodsMs` marca o PASSO de física, no mesmo
	# despacho onde o produto abre a sua; `workMs` é a janela física→ociosa fechada no
	# `_process` do MESMO node que marca a fronteira — a grandeza que o predícado de
	# estouro do produto lê desde 2026-10-01. A de iteração é o instrumento que deixou
	# esta régua ler-se a si mesma: quando o pacing dorme e come o atraso de um passo na
	# iteração seguinte, a série de iteração fica lisa em 33,6 ms. A de período é o que
	# responde "o tick foi cumprido", e por isso continua impressa — mas cobrá-la por
	# orçamento era paginar o sono do throttle, e foi assim que um degrau com 9 ms de
	# trabalho estourou 8,3% dos passos no runner da CI sem nenhum jogador perder passo.
	var stepPeriodsMs : Array = []
	var tickPeriodsMs : Array = []
	var workMs : Array = []
	var sqlStart : int = int(sql.call("QueryCount"))
	var mutexStart : Dictionary = sql.call("QueryMutexWaitStats")
	# Instrumento do PRODUCTO, lido na mesma janela: o acumulado que o próprio
	# processo exporta por /metrics (sources/launcher/Launcher.gd). Se a régua daqui
	# e a métrica de lá não contarem o mesmo passo, uma das duas é etiqueta.
	var prodBefore : Dictionary = launcher.call("StepBudgetSnapshot")
	# Armado colado no retrato do produto: as duas janelas têm de começar no mesmo
	# instante, senão a concordância abaixo compara contagens de janelas diferentes.
	cadence.set("marks", [])
	cadence.set("brackets", [])
	cadence.set("openPending", false)
	cadence.set("armed", true)
	var framesStart : int = int(Engine.get_physics_frames())
	var wallStart : int = Time.get_ticks_usec()
	var cpuStart : int = _cpuUs()
	var busyStart : int = _hostBusyUs()
	var wallEnd : int = wallStart
	var previousSampledFrame : int = framesStart
	var awaited : int = 0
	await physics_frame
	var lastStepUs : int = Time.get_ticks_usec()
	for i in range(SampleFrames):
		await physics_frame
		awaited += 1
		wallEnd = Time.get_ticks_usec()
		stepPeriodsMs.append(float(wallEnd - lastStepUs) / 1000.0)
		lastStepUs = wallEnd
		var frameID : int = int(Engine.get_physics_frames())
		if frameID <= previousSampledFrame:
			continue
		previousSampledFrame = frameID
		var phys : float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var idle : float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physSamples.append(phys)
		idleSamples.append(idle)
		work.append(phys + idle)
	cadence.set("armed", false)
	tickPeriodsMs = _periods(cadence.get("marks"))
	workMs = _msFromUs(cadence.get("brackets"))
	var prodAfter : Dictionary = launcher.call("StepBudgetSnapshot")
	var sqlEnd : int = int(sql.call("QueryCount"))
	var mutexEnd : Dictionary = sql.call("QueryMutexWaitStats")
	var framesEnd : int = int(Engine.get_physics_frames())
	var cpuUs : int = _cpuUs() - cpuStart
	if cpuUs < 0:
		cpuUs = 0
	# Quantos passos NÃO couberam em orçamento+folga na janela inteira, contado antes
	# de podar o transitório: é a mesma janela que o acumulador do produto viu, e é
	# com ela que a régua de concordância abaixo fala. A contagem é pela JANELA DE
	# DESPACHO, o mesmo predícado que o produto aplica; o período de tick e o de
	# iteração saem ao lado como testemunhas.
	var tailLimitMs : float = budgetMs + PeriodToleranceMs
	var stepsOverBudget : int = 0
	for workSample in workMs:
		if float(workSample) > tailLimitMs:
			stepsOverBudget += 1
	var periodOverBudget : int = 0
	for stepMs in tickPeriodsMs:
		if float(stepMs) > tailLimitMs:
			periodOverBudget += 1
	var iterOverBudget : int = 0
	for stepMs in stepPeriodsMs:
		if float(stepMs) > tailLimitMs:
			iterOverBudget += 1
	var tickSteps : int = tickPeriodsMs.size()
	# Alinhamento dos dois instrumentos, conferido antes de podar: o despacho é uma
	# sub-janela do período do MESMO índice, e o censo das duas séries difere no máximo
	# pelo último bracket ainda sem sucessora. Se um dia o Cadence for realocado, ou o
	# engine entregar um despacho sem fronteira pareada, isto quebra aqui — não num teto
	# de cauda que passaria a cobrar uma população diferente da que o produto conta.
	var instrumentDrift : int = _alignmentDrift(workMs, tickPeriodsMs)
	for cut in range(mini(SkipFrames, work.size())):
		work.pop_front()
		physSamples.pop_front()
		idleSamples.pop_front()
		if not stepPeriodsMs.is_empty():
			stepPeriodsMs.pop_front()
		if not tickPeriodsMs.is_empty():
			tickPeriodsMs.pop_front()
		if not workMs.is_empty():
			workMs.pop_front()
	var wallMs : float = float(wallEnd - wallStart) / 1000.0
	# De quanta CPU da máquina esta janela precisou, e de quanta dela não foi deste
	# processo. As duas juntas são o que decide se o número abaixo é medido ou é o
	# vizinho passando por produto.
	var coresCount : int = maxi(OS.get_processor_count(), 1)
	var wallUs : int = int(wallEnd - wallStart)
	var hostBusyDelta : int = -1 if busyStart < 0 else (_hostBusyUs() - busyStart)
	var foreignShare : float = foreignPct(wallUs, hostBusyDelta, cpuUs, coresCount)
	var ownShare : float = -1.0 if hostBusyDelta < 0 else minf(100.0, 100.0 * float(cpuUs) / float(maxi(wallUs, 1) * coresCount))
	# Terceira leitura, e a única que não depende de ninguém contar tempo por dentro:
	# quantos passos de física o processo ENTREGOU por segundo de parede. Se ela cair
	# abaixo dos 30 Hz de produção, o orçamento quebrou de verdade — não importa o que
	# digam o período medido entre sinais nem os monitores da engine (as duas leituras
	# discordam acima de ~10 instâncias, e é exatamente por isso que as três saem).
	var steps : int = maxi(framesEnd - framesStart, 1)
	var periodMs : float = wallMs / float(maxi(awaited, 1))
	var achievedHz : float = float(steps) * 1000.0 / maxf(wallMs, 0.001)
	var lateHz : bool = achievedHz < float(serverFps) - 1.0
	var median : float = _median(work)
	var census : Dictionary = _census()
	var rssMb : int = _rssMb()
	var staticMb : int = int(OS.get_static_memory_usage() / (1024 * 1024))
	var monitorMb : int = int(Performance.get_monitor(Performance.MEMORY_STATIC) / (1024 * 1024))
	var cpuMsPerStep : float = float(cpuUs) / 1000.0 / float(maxi(awaited, 1))
	var row : Dictionary = {
		"label": label,
		"instances": instances,
		"players": totalPlayers,
		"censusPlayers": int(census["players"]),
		"censusInstances": int(census["instances"]),
		"biggest": int(census["biggest"]),
		"mobs": int(census["mobs"]),
		"policies": int(census["policies"]),
		"samples": work.size(),
		"awaited": awaited,
		"medianMs": median,
		"physMs": _median(physSamples),
		"idleMs": _median(idleSamples),
		"p95Ms": _p(0.95, work),
		"maxMs": float(work.max()) if not work.is_empty() else 0.0,
		"periodP95Ms": _p(0.95, tickPeriodsMs),
		"periodMaxMs": float(tickPeriodsMs.max()) if not tickPeriodsMs.is_empty() else 0.0,
		"periodSamples": tickPeriodsMs.size(),
		"workP95Ms": _p(0.95, workMs),
		"workMaxMs": float(workMs.max()) if not workMs.is_empty() else 0.0,
		"workMedianMs": _median(workMs),
		"iterP95Ms": _p(0.95, stepPeriodsMs),
		"iterMaxMs": float(stepPeriodsMs.max()) if not stepPeriodsMs.is_empty() else 0.0,
		"iterOverBudget": iterOverBudget,
		"periodOverBudget": periodOverBudget,
		"stepsOverBudget": stepsOverBudget,
		"periodSteps": tickSteps,
		"instrumentDrift": instrumentDrift,
		"workSteps": workMs.size(),
		"prodSteps": int(prodAfter.get("steps", 0)) - int(prodBefore.get("steps", 0)),
		"prodOverBudget": int(prodAfter.get("overBudget", 0)) - int(prodBefore.get("overBudget", 0)),
		"prodLost": int(prodAfter.get("lost", 0)) - int(prodBefore.get("lost", 0)),
		"prodWorkMaxUs": int(prodAfter.get("workMaxUs", 0)),
		"periodMs": periodMs,
		"steps": steps,
		"wallMs": wallMs,
		"achievedHz": achievedHz,
		"lateHz": lateHz,
		"rssMb": rssMb,
		"staticMb": staticMb,
		"monitorMb": monitorMb,
		"cpuMsPerStep": cpuMsPerStep,
		"cores": cpuMsPerStep / maxf(periodMs, 0.001),
		"fdCount": _fdCount(),
		"threads": _threadCount(),
		"missedBudget": periodMs > budgetMs + PeriodToleranceMs or median > budgetMs or lateHz,
		"overWork": median > budgetMs,
		"overPeriod": periodMs > budgetMs + PeriodToleranceMs,
		"queriesPerTick": float(sqlEnd - sqlStart) / float(maxi(awaited, 1)),
		"mutexUsPerTick": float(int(mutexEnd.get("microseconds", 0)) - int(mutexStart.get("microseconds", 0))) / float(maxi(awaited, 1)),
		"foreignPct": foreignShare,
		"ownPct": ownShare,
		"loadavg1": _loadavg1(),
		"machineCores": coresCount,
	}
	rows.append(row)
	print("== nivel %s | %d instancias x cap %d = %d players no processo | trabalho mediana %.2f ms/passo (fisica %.2f + idle %.2f; p95 %.2f, max %.2f) | periodo %.2f ms vs budget %.2f ms | tick entregue %.2f Hz (%d passos em %.0f ms)%s | RSS %d MB (heap Godot %d, monitor %d) | CPU %.2f ms/passo = %.2f core(s) | mobs %d, policies %d | SQL %.1f rt/tick, mutex %.2f us/tick | %d nos | amostras %d | maquina: %d nucleos, %.0f%% de outro trabalho, %.0f%% nosso, loadavg %.2f ==" % [
		label, instances, cap, totalPlayers, median, float(row["physMs"]), float(row["idleMs"]),
		float(row["p95Ms"]), float(row["maxMs"]), periodMs, budgetMs,
		achievedHz, steps, wallMs,
		" TICK ATRASADO" if lateHz else "",
		rssMb, staticMb, monitorMb, cpuMsPerStep, float(row["cores"]),
		int(row["mobs"]), int(row["policies"]), float(row["queriesPerTick"]), float(row["mutexUsPerTick"]),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(row["samples"]),
		coresCount, foreignShare, ownShare, float(row["loadavg1"])])
	print("  . cauda por passo na JANELA DE DESPACHO (%d observações, uma por passo, a mesma grandeza que o predícado do produto lê): mediana %.2f ms, p95 %.2f ms, max %.2f ms | %d/%d passos acima de orçamento+folga (%.2f ms)" % [
			int(row["workSteps"]), float(row["workMedianMs"]), float(row["workP95Ms"]), float(row["workMaxMs"]),
			stepsOverBudget, tickSteps, tailLimitMs])
	print("  . testemunha de PERÍODO na fronteira de tick (%d observações, uma por `_physics_process`): p95 %.2f ms, max %.2f ms | %d/%d acima de %.2f ms — período é orçamento + sono do throttle, e por isso não é mais o que cobra" % [
			int(row["periodSamples"]), float(row["periodP95Ms"]), float(row["periodMaxMs"]),
			periodOverBudget, tickSteps, tailLimitMs])
	print("  . fronteira de ITERAÇÃO (os %d `await physics_frame`): p95 %.2f ms, max %.2f ms | %d acima de %.2f ms — é aqui que o pacing come o atraso do passo" % [
			awaited, float(row["iterP95Ms"]), float(row["iterMaxMs"]), iterOverBudget, tailLimitMs])
	print("  . instrumento do produto na MESMA janela (o que sai por /metrics): +%d passos amostrados, +%d acima do orçamento, +%d passos perdidos" % [
			int(row["prodSteps"]), int(row["prodOverBudget"]), int(row["prodLost"])])
	return row

# Uma janela com a máquina tomada por outro processo não mede nada: remede até o teto
# da janela ou do run. Se o ruído vencer, a linha voltada é a que ficou — impressa com
# o percentual alheio — e `_measurePasses` declara o nível não-medido em vez de deixar
# a régua ler o vizinho como produto.
func _measure(label : String, totalPlayers : int, instances : int) -> Dictionary:
	var budget : int = _noiseBudgetMs()
	var started : int = Time.get_ticks_msec()
	var row : Dictionary = await _measureOnce(label, totalPlayers, instances)
	while _shouldWaitForQuietWindow(row, started, budget):
		noiseWaits += 1
		print("== espera %s: %.0f%% da máquina é de outro trabalho (limite %.0f%%) — remedindo a janela ==" % [
				label, float(row["foreignPct"]), ForeignCpuNoisePct])
		rows.pop_back()
		var retryStarted : int = Time.get_ticks_msec()
		await _frames(WarmupFrames)
		row = await _measureOnce(label, totalPlayers, instances)
		noiseWaitMs += Time.get_ticks_msec() - retryStarted
	if isNoisy(float(row["foreignPct"])):
		noiseWindows += 1
		worstForeignPct = maxf(worstForeignPct, float(row["foreignPct"]))
		timingNoiseActive = true
	return row

# As três bordas da espera: a janela atual não pode passar de 15 s, o run inteiro não
# pode passar do orçamento (`SHAMBLETA_NOISE_WAIT_MS`, default 90 s), e só se espera de
# janela que a sonda declarou suja. Sem a borda do run, um host tomado trocaria um
# veredito falso por um timeout — que é outro veredito falso.
func _shouldWaitForQuietWindow(row : Dictionary, started : int, budget : int) -> bool:
	if not isNoisy(float(row["foreignPct"])):
		return false
	if Time.get_ticks_msec() - started >= NoiseWaitWindowMs:
		return false
	return noiseWaitMs + NoiseWaitWindowMs <= budget

# Uma passada não é medição: é um número com ruído de máquina dentro. Cada nível da
# escada é medido `MeasurePasses` vezes e o que entra na régua é a MEDIANA das
# passadas, com o spread (máx - mín) impresso junto — porque o número que vai para
# `deploy/SCALING.md` tem que ser o que se reproduz, não o que deu sorte. As linhas
# intermediárias são retiradas de `rows` para a escada publicada continuar sendo um
# degrau por nível.
func _measurePasses(label : String, totalPlayers : int, instances : int) -> Dictionary:
	var passes : Array = []
	for passID in range(MeasurePasses):
		passes.append(await _measure("%s p%d" % [label, passID + 1], totalPlayers, instances))
	var keep : Dictionary = passes[passes.size() - 1]
	for medianaKey in ["medianMs", "physMs", "idleMs", "p95Ms", "maxMs", "periodP95Ms", "periodMaxMs", "workP95Ms", "workMaxMs", "iterP95Ms", "iterMaxMs", "iterOverBudget", "periodOverBudget", "stepsOverBudget", "prodOverBudget", "periodMs", "achievedHz", "cpuMsPerStep", "cores", "queriesPerTick", "mutexUsPerTick", "foreignPct"]:
		var samples : Array = []
		for rowPass in passes:
			samples.append(float(rowPass[medianaKey]))
		keep[medianaKey] = _median(samples)
	# A cauda é cobrada na PIOR passada, não na mediana das passadas: o argumento de
	# que "um teto cumprido numa janela suja continua cumprido na quieta" vale para o
	# valor central; para uma cauda, a passada que a máquina entregou mais devagar é
	# justamente a que o jogador sentiu, e ela não pode ser medianada para fora.
	for tailPair in [["worstP95Ms", "p95Ms"], ["worstMaxMs", "maxMs"]]:
		var worst : float = 0.0
		for rowPass in passes:
			worst = maxf(worst, float(rowPass[tailPair[1]]))
		keep[tailPair[0]] = worst
	# O deslocamento do instrumento é um inteiro de VERDADE, não uma medida: a mediana
	# das passadas escondia a passada que quebrou, e é exatamente nela que o Cadence
	# precisaria ter escorregado do Launcher. Máximo sobre as passadas.
	var drift : int = 0
	for rowPass in passes:
		drift = maxi(drift, int(rowPass["instrumentDrift"]))
	keep["instrumentDrift"] = drift
	# A cauda de PERÍODO, porém, é cobrada como TAXA e não como valor absoluto: o corte
	# que o produto declara para paginar (`deploy/alerts.rules.yml`) é fração de passos
	# acima do orçamento, e um teto absoluto de orçamento+folga no PIOR passo da janela é
	# mais severo que o alerta — medido, o próprio piso do processo (0 players) entregava
	# 34,08 ms de máximo contra o teto de 34,33 ms, e 5x20 entregava 34,46 ms sem que
	# nenhum jogador perdesse um passo. O que discrimina carga é quantos passos passaram:
	# 0 até ~40 players, 4 em 100, 16 em 200. p95 e max do período continuam medianados,
	# impressos por passada e presentes na tabela; só deixaram de ser a régua.
	var worstOverPct : float = 0.0
	var worstOverPass : Dictionary = passes[0]
	for rowPass in passes:
		var passOverPct : float = 100.0 * float(rowPass["stepsOverBudget"]) / maxf(float(rowPass["periodSteps"]), 1.0)
		if passOverPct >= worstOverPct:
			worstOverPct = passOverPct
			worstOverPass = rowPass
	keep["worstOverPct"] = worstOverPct
	# Os numeradores impressos vêm da MESMA passada que produziu a pior taxa: medianar
	# a fração e imprimir a contagem de outra passada é contar uma janela imaginária.
	keep["worstStepsOver"] = int(worstOverPass["stepsOverBudget"])
	keep["worstWindowSteps"] = int(worstOverPass["periodSteps"])
	var medians : Array = []
	for rowPass in passes:
		medians.append(float(rowPass["medianMs"]))
	keep["label"] = label
	keep["samples"] = 0
	keep["passCount"] = passes.size()
	keep["passMedians"] = medians
	keep["passSpreadMs"] = float(medians.max()) - float(medians.min())
	keep["rssMb"] = int(passes[0]["rssMb"])
	for rowPass in passes:
		keep["rssMb"] = maxi(int(keep["rssMb"]), int(rowPass["rssMb"]))
		keep["samples"] = int(keep["samples"]) + int(rowPass["samples"])
	keep["missedBudget"] = float(keep["periodMs"]) > budgetMs + PeriodToleranceMs or float(keep["medianMs"]) > budgetMs or bool(keep["lateHz"])
	keep["overWork"] = float(keep["medianMs"]) > budgetMs
	keep["overPeriod"] = float(keep["periodMs"]) > budgetMs + PeriodToleranceMs
	# A palavra final sobre o relógio é a MEDIANA das passadas; o pior valor sai
	# impresso como `worstHz` e aparece na coluna de spread. Um spike de GC único
	# (visto no primeiro window do boot: 360 ms) não pode transformar um nível são em
	# nível "estourado" — régua que treme com um tiro não é régua.
	var worstHz : float = float(keep["achievedHz"])
	for rowPass in passes:
		worstHz = minf(worstHz, float(rowPass["achievedHz"]))
	keep["worstHz"] = worstHz
	keep["lateHz"] = float(keep["achievedHz"]) < float(serverFps) - 1.0
	# `rows` terminou com as N passadas; a que fica é a última appendada, já mutada
	# acima. Remover por `pop_back()` contando N-1 pegava exatamente a linha errada:
	# descartava `keep` (a última) e deixava na escada a passada crua `p1` — sem
	# `passSpreadMs`, sem mediana, com o rótulo "2x20 p1". Medido: os níveis afirmados
	# estavam sendo checados contra um tiro sozinho, e a check de convergência ia no
	# chão por chave ausente. Podar por rótulo é o que sobrevive à ordem de `rows`.
	var pruned : Array = []
	for candidate in rows:
		if str(candidate.get("label")).begins_with(label + " p"):
			continue
		pruned.append(candidate)
	rows = pruned
	print("== passes %s | medianas %s ms/passo | spread entre passadas %.2f ms | mediana usada %.2f ms ==" % [
			label, str(medians), float(keep["passSpreadMs"]), float(keep["medianMs"])])
	return keep

# --------------------------------------------------------------------------------- régua

# As checks de forma que todo nível tem de passar antes de qualquer número de
# capacidade ser publicado: instâncias de verdade, cada uma com o cap de players
# reais, nenhuma acima do cap, e o censo batendo com a conta dos agentes criados.
func _checkShape(level : int, setup : Dictionary, census : Dictionary) -> bool:
	var total : int = level * cap
	var ok : bool = true
	ok = CheckEq(setup["players"], cap, "nível %d: instância da zona %d recebeu %d players (== cap lido do fonte)" % [level, nextZone - 1, cap]) and ok
	ok = Check(int(setup["sessions"]) > 0, "nível %d: %d sessão(ões) idle de verdade anexada(s)" % [level, int(setup["sessions"])]) and ok
	ok = CheckEq(census["instances"], level, "censo: %d instância(s) de farm VIVAS no processo, cada uma com players (não é uma só com multiplicador)" % level) and ok
	ok = CheckEq(census["players"], total, "censo: %d players somando todas as instâncias do processo" % total) and ok
	ok = CheckEq(census["mine"], total, "censo confere com a conta própria deste harness (%d agentes listados)" % total) and ok
	ok = CheckEq(census["overCap"], 0, "nenhuma instância acima do cap %d (%s)" % [cap, _censusText(census)]) and ok
	ok = CheckEq(census["biggest"], cap, "a maior instância do processo tem exatamente o cap (%s)" % _censusText(census)) and ok
	ok = CheckEq(census["policies"], total, "%d policies idle anexadas, uma por player do processo" % total) and ok
	ok = Check(census["mobs"] >= level, "cada instância tem mobs próprios (%d mobs em %d instâncias) — a instância está viva, não é casca vazia" % [int(census["mobs"]), level]) and ok
	return ok

# -------------------------------------------------------------------------------- main
func _run() -> void:
	print("== teto do processo: N instâncias x cap de players no mesmo tick (deploy/SCALING.md §6) ==")
	launcher = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 40000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		world = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")):
			break
	if not Check(sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")),
			"SQL + World booteds (%d ms de espera)" % waited):
		await _finish()
		return

	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()"):
		await _finish()
		return

	worldAgentScript = load("res://sources/world/WorldAgent.gd")
	worldInstanceScript = load("res://sources/world/WorldInstance.gd")
	policyScript = load("res://sources/idle/IdlePolicyService.gd")
	actorCommonsScript = load("res://sources/actor/ActorCommons.gd")
	spawnScript = load("res://addons/tiled_importer/SpawnObject.gd")
	farmScript = load("res://sources/idle/FarmZoneData.gd")
	commonsScript = load("res://sources/launcher/LauncherCommons.gd")
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	suites = suitesScript.new()
	if not Check(worldAgentScript != null and worldInstanceScript != null and policyScript != null and actorCommonsScript != null
			and spawnScript != null and farmScript != null and commonsScript != null and suites != null,
			"WorldAgent + WorldInstance + IdlePolicyService + ActorCommons + SpawnObject + FarmZoneData + LauncherCommons + IdleTests carregados"):
		await _finish()
		return

	# As constantes vêm do fonte, não deste arquivo: se alguém mudar o cap, a escada
	# e o censo mudam junto, e o número publicado continua sendo o cap real.
	cap = int(worldInstanceScript.get_script_constant_map().get("MAX_PLAYERS_PER_INSTANCE", 0))
	zoneBase = int(policyScript.get_script_constant_map().get("ZoneInstanceBase", 0))
	bossBase = int(policyScript.get_script_constant_map().get("BossInstanceBase", 0))
	var zoneCount : int = int(farmScript.call("GetZoneCount"))
	if not Check(cap > 0 and zoneBase > 0 and bossBase > zoneBase and zoneCount >= ProbeInstances,
			"cap=%d, ZoneInstanceBase=%d, BossInstanceBase=%d, %d zonas de farm (preciso de %d para a escada)" % [cap, zoneBase, bossBase, zoneCount, ProbeInstances]):
		await _finish()
		return

	serverFps = int(commonsScript.get("ServerMaxFPS"))
	budgetMs = 1000.0 / float(maxi(serverFps, 1))
	# Mesma dupla que o `--server` aplica (sources/launcher/Launcher.gd): sem isto o
	# harness mediria 60 Hz (default do Godot para um SceneTree sem `--server`)
	# contra um orçamento de 30 Hz.
	Engine.set_max_fps(serverFps)
	Engine.set_physics_ticks_per_second(serverFps)
	CheckEq(int(Engine.get_physics_ticks_per_second()), serverFps,
			"tick do harness = tick de produção (%d Hz, budget %.2f ms/passo)" % [serverFps, budgetMs])
	rssFloorMb = _rssMb()
	Check(rssFloorMb > 0, "RSS legível de %s antes de semear qualquer player (%d MB)" % [RssPath, rssFloorMb])
	procLimitMb = _procLimitMb()
	fdFloor = _fdCount()
	threadFloor = _threadCount()
	var nofile : Vector2i = _procLimitPair("Max open files")
	if int(nofile.x) == -2:
		# O título impresso por `getrlimit`/`proc(5)` para RLIMIT_NOFILE é "Max open
		# files"; "Max file descriptors" é como o ulimit(1P) chama a mesma linha. Se um
		# kernel mudar a etiqueta, a medição tem que falhar ALTA, não virar -1 silencioso.
		nofile = _procLimitPair("Max file descriptors")
	nofileSoft = int(nofile.x)
	nofileHard = int(nofile.y)
	var nproc : Vector2i = _procLimitPair("Max processes")
	nprocSoft = int(nproc.x)
	Check(nofileSoft != -2 and nofileHard != -2, "RLIMIT_NOFILE lido de %s: soft %s, hard %s (-1 = unlimited, que também é medida)" % [
			LimitsPath, str(nofileSoft), str(nofileHard)])
	Check(nprocSoft != -2, "RLIMIT_NPROC (teto de threads/processos deste uid) lido: soft %s" % str(nprocSoft))
	Check(fdFloor > 0 and threadFloor > 0, "chão de recurso deste processo: %d descritores abertos, %d threads vivas" % [fdFloor, threadFloor])
	Note("chão deste processo antes da escada: RSS %d MB, static %d MB, rlimit de memória do kernel = %s, %d descritores, %d threads; RLIMIT_NOFILE soft/hard = %s/%s, RLIMIT_NPROC soft = %s; o compose pede conta contra mem_limit 1536M" % [
			rssFloorMb, int(OS.get_static_memory_usage() / (1024 * 1024)),
			"sem limite (unlimited)" if procLimitMb < 0 else "%d MB" % procLimitMb,
			fdFloor, threadFloor,
			str(nofileSoft), str(nofileHard), str(nprocSoft)])

	# O ponto "zero players" da curva: sem ele o custo por player seria sempre a
	# diferença entre dois níveis carregados e o chão do boot (mapa, SQL, nav) ficaria
	# embutido na conta de "custo do player".
	# A sonda antes da escada: se ela não lê a máquina, dizer isso ANTES de julgar
	# qualquer régua de tempo é o que impede o run de medir com instrumento quebrado.
	_proofNoiseProbe()
	calib = Burn.new()
	calib.name = "MultiInstCalibre"
	root.add_child(calib)
	cadence = Cadence.new()
	cadence.name = "MultiInstCadencia"
	root.add_child(cadence)
	# POSICÇÃO é instrumento, não estética. Os callbacks de uma iteração rodam na ordem
	# da árvore: primeiro TODOS os `_physics_process`, depois TODOS os `_process`. Um
	# Cadence acrescentado no fim da lista abriria a janela no FIM do flush de física —
	# depois do pump das WorldInstance — e mediria quase zero onde o Launcher, que é
	# autoload e abre o flush, mediria o passo inteiro. Colá-lo logo depois do Launcher
	# é o que faz os dois instrumentos cobrirem o mesmo intervalo; a régua de mordida
	# abaixo confere a vizinhança em vez de presumi-la.
	var launcherSibling : int = _indexOf(root.get_children(), launcher)
	if launcherSibling >= 0:
		root.move_child(cadence, launcherSibling + 1)
	await _frames(4)
	Check(bool(calib.is_node_ready()) and calib.get_parent() == root,
			"calibre ligado na mesma árvore das WorldInstances (us=%d desligado)" % int(calib.get("us")))
	Check(bool(cadence.is_node_ready()) and cadence.get_parent() == root,
			"fronteira de tick ligada na mesma árvore das WorldInstances (é o instrumento da régua de cauda)")
	CheckEq(_indexOf(root.get_children(), cadence), _indexOf(root.get_children(), launcher) + 1,
			"o Cadence é o vizinho imediato do Launcher: os dois brackets abrem e fecham no mesmo ponto do despacho, senão a concordância compara janelas de tamanhos diferentes")
	# A régua de alinhamento tem de MORDER, não só acusar: com séries plantadas, o
	# excedente legítimo (o último bracket ainda sem fronteira sucessora) devolve zero e
	# as três degenerações que ela existe para ver devolvem acusação. Sem isto, "drift 0
	# em todo degrau" poderia ser a régua não vendo nada — a mesma classe de falso verde
	# que o `CONTROLE NEGATIVO DO INSTRUMENTO` de `tests/step_budget_metric_test.gd` fecha
	# no lado do produto.
	CheckEq(_alignmentDrift([10.0, 20.0, 5.0], [33.0, 33.0]), 0,
			"CONTROLE: três brackets contidos na parede para dois períodos devolve drift 0 — o excedente de um, que é o último passo ainda sem sucessora, NÃO é o defeito")
	CheckEq(_alignmentDrift([40.0, 20.0], [33.0, 33.0]), 1,
			"CONTROLE: um bracket de 40 ms cabendo num período de 33 ms é acusado (drift 1) — é o índice desalinhado, não a mediana, que entrega")
	CheckEq(_alignmentDrift([10.0, 10.0, 10.0, 10.0], [33.0, 33.0]), 1,
			"CONTROLE: excedente de DOIS brackets sobre os períodos é acusado — as duas séries estão contando populações diferentes")
	CheckEq(_alignmentDrift([10.0], [33.0, 33.0]), 1,
			"CONTROLE: a série de despacho MAIS CURTA que a de período é acusada — falta bracket, sobra fronteira")
	# O corte da régua de cauda é LIDO do fonte que pagina, não digitado aqui: muda o
	# percentual em `deploy/alerts.rules.yml` e esta escada muda com ele. Não achá-lo é
	# a régua perdendo o chão, e é check — não fallback para um número órfão.
	alertPagePct = _alertPagePct()
	Check(alertPagePct > 0.0, "o corte que pagina foi lido do fonte (%.1f%% dos passos acima de orçamento+folga)" % alertPagePct)
	var floorRow : Dictionary = await _measurePasses("piso 0 players", 0, 0)
	floorMs = float(floorRow["medianMs"])
	rows.pop_back()
	CheckCeiling(floorMs > 0.0 and floorMs < budgetMs, "piso do processo (sem nenhum player): %.2f ms/passo, folga de %.2f ms sobre o orçamento" % [
			floorMs, budgetMs - floorMs])

	# O ponto "1 player" da curva, no MESMO processo e antes de qualquer lotação: sem
	# ele o custo por player seria sempre diferença entre dois níveis carregados e o
	# chão do boot (mapa, nav, SQL) ficaria embutido na conta do player. É também o
	# "1" da série 1 / 20 / 100 / 200 do runbook, medida aqui com instâncias conviventes.
	var oneSetup : Dictionary = {}
	var firstLoaded : Object = await _ensureZoneInstance(1)
	if firstLoaded != null:
		oneSetup = await _seedPlayers(1, firstLoaded, 1)
	if Check(int(oneSetup.get("players", 0)) == 1 and int(oneSetup.get("sessions", 0)) == 1,
			"1 player com sessão idle real na instância dedicada da zona 1 (âncora da curva por player)"):
		var oneRow : Dictionary = await _measurePasses("1 player", 1, 1)
		onePlayerMs = float(oneRow["medianMs"])
		rows.pop_back()
		CheckTiming(onePlayerMs > floorMs, "1 player custa MAIS que o piso (%.2f -> %.2f ms/passo) — o player aparece na medida, não no rótulo" % [
				floorMs, onePlayerMs])
		CheckTiming(onePlayerMs - floorMs < 15.0, "um único player não custa um passo inteiro (%.2f ms de custo próprio sobre o piso)" % (
				onePlayerMs - floorMs))

	var previous : Dictionary = {}
	var lastRow : Dictionary = {}
	var anchorRow : Dictionary = {}
	var firstRow : Dictionary = {}
	var insideCount : int = 0
	for li in range(CapacityInstances.size()):
		var level : int = int(CapacityInstances[li])
		var isProbe : bool = level == ProbeInstances
		var isAsserted : bool = AssertedInstances.has(level)
		# Acrescenta apenas as instâncias que faltam: o processo ACUMULA, que é
		# exatamente o que §6 dizia não estar medido.
		var newInst : Dictionary = {}
		var seededZone : int = nextZone - 1
		while nextZone <= level:
			var zoneID : int = nextZone
			nextZone += 1
			seededZone = zoneID
			var loaded : Object = await _ensureZoneInstance(zoneID)
			if loaded == null:
				newInst = {}
				break
			# Top-up, não overwrite: a âncora de 1 player já deixou um habitante na
			# zona 1, e semear `cap` em cima dela faria a instância estourar o cap — o
			# que a própria check de forma reprovaria.
			var already : int = (loaded.get("players") as Array).size()
			newInst = await _seedPlayers(zoneID, loaded, cap - already)
			newInst["players"] = already + int(newInst["players"])
			if newInst.get("inst") == null:
				break
		var total : int = level * cap
		var label : String = "%dx%d" % [level, cap]
		if not Check(bool(newInst.get("inst") != null), "nível %s: instância dedicada da zona %d pronta e carregada" % [label, seededZone]):
			continue
		var census : Dictionary = _census()
		if not _checkShape(level, newInst, census):
			continue
		var row : Dictionary = await _measurePasses(label, total, level)
		Check(int(row["samples"]) >= SampleFrames - SkipFrames - 5, "nível %s: %d amostras dos monitores (janela não truncada)" % [label, int(row["samples"])])
		Check(int(row["periodSamples"]) >= SampleFrames - SkipFrames - 5, "nível %s: %d passos na série de período por tick (sem instrumento vivo não há cauda)" % [label, int(row["periodSamples"])])
		Check(row["rssMb"] > 0, "nível %s: RSS medido com players no processo (%d MB)" % [label, int(row["rssMb"])])
		# A régua de relógio nos degraus AFIRMADOS: enquanto o trabalho couber no
		# orçamento o sleep preenche o resto e o período é o próprio orçamento. Estes
		# são os níveis que o beta planeja sustentar; um vermelho aqui é regressão.
		if isAsserted:
			# As três condições cruas primeiro, e só depois entregues à régua: é o
			# `row` cru que decide se este degrau coube no orçamento, porque sob ruído
			# `CheckCeiling` devolve `true` também no galho não-medido — contar por ali
			# inflaria `insideCount` com degraus que não couberam.
			var periodOK : bool = float(row["periodMs"]) <= budgetMs + PeriodToleranceMs
			var workOK : bool = float(row["medianMs"]) <= budgetMs
			var hzOK : bool = not bool(row["lateHz"])
			CheckCeiling(periodOK,
					"nível %s: período %.2f ms dentro do orçamento (%.2f + %.2f de folga)" % [
						label, float(row["periodMs"]), budgetMs, PeriodToleranceMs])
			CheckCeiling(workOK,
					"nível %s: trabalho %.2f ms/passo dentro do orçamento de %.2f ms" % [label, float(row["medianMs"]), budgetMs])
			Check(float(row["cores"]) < 2.0,
					"nível %s: %.2f core(s) de CPU no laço, dentro do cpus 2 do compose (%.2f ms/passo de CPU)" % [
						label, float(row["cores"]), float(row["cpuMsPerStep"])])
			CheckCeiling(hzOK,
					"nível %s: o processo entregou %.2f Hz dos %d Hz de produção (orçamento cumprido de ponta a ponta)" % [
						label, float(row["achievedHz"]), serverFps])
			# RÉGUA DE CAUDA nos degraus afirmados. Existir porque a mediana mentia:
			# num degrau em que a cauda sai do orçamento e o centro não, `medianMs`
			# continua verde e o jogador recebe passos estourados. Verde daqui significa
			# uma frase só, e é ela: em TODAS as passadas deste nível, 95% dos passos de
			# trabalho fecharam dentro do orçamento, o pior passo de trabalho também
			# coube, e a fração de passos de parede acima de orçamento+folga nunca
			# alcançou o corte que o produto pagina. Não significa "o nível coube" para a
			# mediana — significa que a cauda coube.
			#
			# Por que `CheckCeiling` e não `CheckTiming`: um teto de cauda tem a
			# assinatura de um teto. O vizinho de máquina só pode ENCOLHER a folga desta
			# janela (preemption e fila de scheduler entram no relógio do passo, nunca
			# saem), então um p95/max que coube num degrau sujo cabe no mesmo degrau
			# quieto — e é essa a régua que o beta precisa sobreviver. `CheckTiming`
			# jogaria fora, em toda máquina de desenvolvimento tomada, exatamente a
			# assertiva que não pode ser fabricada por ruído; `Check` seria pior ainda,
			# porque vermelharia o run por causa do vizinho e o veredito deixaria de ser
			# do produto. A elegibilidade é a mesma da função: é UMA janela, não a
			# diferença entre duas.
			CheckCeiling(float(row["worstP95Ms"]) <= budgetMs,
					"nível %s: p95 do trabalho por passo %.2f ms dentro do orçamento de %.2f ms na PIOR passada — o verde não é mais da mediana" % [
						label, float(row["worstP95Ms"]), budgetMs])
			CheckCeiling(float(row["worstMaxMs"]) <= budgetMs,
					"nível %s: o pior passo de trabalho da janela (%.2f ms na pior passada) cabe no orçamento" % [
						label, float(row["worstMaxMs"])])
			# A cauda de DESPACHO cobrada por TAXA, contra o mesmo número que o alerta
			# pagina. Verde aqui diz uma frase só: posto este degrau em produção,
			# `PassoForaDoOrcamento` não dispararia nele. O valor absoluto do pior passo
			# deixou de ser régua porque o relógio de um tick carrega o pacing consigo: um
			# processo ocioso já entregava máximo acima de orçamento+folga sem que nenhum
			# passo se perdesse, e um teto que fica vermelho por dormir não mede carga. O
			# que separa degrau é quantos passos passaram — e desde 2026-10-01 são os
			# passos cujo DESPACHO passou, o mesmo predícado que o produto aplica.
			CheckEq(int(row["instrumentDrift"]), 0,
					"nível %s: o bracket de despacho ficou dentro da parede do mesmo passo em todas as passadas, e o censo das duas séries difere no máximo pelo último bracket ainda sem sucessora (drift %d) — sem isto a cauda abaixo cobraria uma população diferente da que o período mede" % [
						label, int(row["instrumentDrift"])])
			CheckCeiling(float(row["worstOverPct"]) <= alertPagePct,
					"nível %s: %.1f%% dos passos da pior passada acima de orçamento+folga, contra o corte de %.1f%% que pagina (%d de %d passos; despacho p95 %.2f ms, max %.2f ms; testemunha de período: %d acima, p95 %.2f ms, max %.2f ms)" % [
						label, float(row["worstOverPct"]), alertPagePct, int(row["worstStepsOver"]), int(row["worstWindowSteps"]),
						float(row["workP95Ms"]), float(row["workMaxMs"]), int(row["periodOverBudget"]),
						float(row["periodP95Ms"]), float(row["periodMaxMs"])])
			# CONCORDÂNCIA DE INSTRUMENTO: a mesma grandeza, medida por dois caminhos — a
			# `Cadence` deste harness (o mesmo bracket física→ocioso, no node vizinho ao
			# do laço) e o acumulador do LAÇO DE PRODUTO (`sources/launcher/Launcher.gd`),
			# que é o número que sai por /metrics e que `deploy/alerts.rules.yml` pagina.
			# Seis passos de margem numa janela de 120, pela borda da janela e pelo ponto
			# de cada instrumento dentro do despacho; passa disso, a métrica exportada não é
			# o que a escada cobra e o alerta paginaria uma etiqueta. Foi medindo
			# `await physics_frame` — fronteira de ITERAÇÃO, que o sleep de pacing alisa —
			# que esta régua ficou verde enquanto o produto contava 16 passos estourados na
			# mesma janela; e foi medindo o PERÍODO de tick, que é orçamento+sono, que ela
			# discordou do produto em 8 passos num degrau que nenhum jogador sentiu.
			var overDelta : int = int(row["prodOverBudget"]) - int(row["stepsOverBudget"])
			Check(absi(overDelta) <= PeriodTailAgreementSteps,
					"nível %s: o contador que o produto exporta viu %d passos acima de orçamento+folga, esta janela viu %d (diff %d, banda %d) — /metrics e escada medem o mesmo passo" % [
						label, int(row["prodOverBudget"]), int(row["stepsOverBudget"]), overDelta, PeriodTailAgreementSteps])
			CheckCeiling(int(row["prodSteps"]) >= int(row["periodSteps"]) - PeriodTailAgreementSteps,
					"nível %s: o acumulador do produto amostrou %d passos numa janela de %d — a série existe neste processo, não é bloco morto do /metrics" % [
						label, int(row["prodSteps"]), int(row["periodSteps"])])
			Check(int(row["periodSteps"]) >= int(row["prodSteps"]) - PeriodTailAgreementSteps,
					"nível %s: a fronteira de tick deste harness amostrou %d passos numa janela onde o produto amostrou %d — o instrumento não perdeu a perna" % [
						label, int(row["periodSteps"]), int(row["prodSteps"])])
			if periodOK and workOK and hzOK:
				insideCount += 1
		else:
			# Nos degraus ALÉM do afirmado a pergunta é outra: se o trabalho estourou,
			# ALGUMA leitura de relógio tem de ver. Acima de ~10 instâncias o período
			# medido entre sinais e o trabalho auto-relatado discordam (a engine entrega
			# menos de 30 passos por segundo de parede, e a mediana do passo fica acima
			# do orçamento mesmo com o "período" ainda em 33 ms) — por isso a terceira
			# leitura, `tick entregue`, entrou: ela é o chão de reality check das duas.
			# Direção correta da implicação, e é ela que já esteve errada aqui: se o
			# RELÓGIO DE PAREDE estoura, o trabalho auto-relatado tem de estourar junto
			# (sem ruptura fantasma) — e a perna (b) é quem prova que o relógio de parede
			# enxerga estouro. O inverso ("trabalho estourado tem de aparecer no período")
			# NÃO é verificável: §2/§3 desta medição mostram o self-report da engine e o
			# wall clock discordando a partir de ~10 instâncias, e é justamente essa
			# discordança que manda o número do beta ser o do trabalho (conservador).
			CheckTiming((not bool(row["overPeriod"])) and (not bool(row["lateHz"])) or bool(row["overWork"]),
					"nível %s: ruptura de relógio de parede (período %.2f ms, tick %.2f Hz) nunca aparece sem que o trabalho (%.2f ms) também estoure — não há detector fantasma" % [
						label, float(row["periodMs"]), float(row["achievedHz"]), float(row["medianMs"])])
			if bool(row["overWork"]) and not bool(row["overPeriod"]) and not bool(row["lateHz"]):
				Note("nível %s: detectores discordando por %.2f ms (trabalho %.2f ms/passo estoura, período %.2f ms e %.2f Hz ainda dentro) — é o joelho declarado em deploy/SCALING.md §2, e o motivo do número publicado ser o do TRABALHO" % [
						label, float(row["medianMs"]) - budgetMs, float(row["medianMs"]), float(row["periodMs"]), float(row["achievedHz"])])
			if bool(row["missedBudget"]):
				Note("nível %s: %d players NÃO couberam (trabalho %.2f ms/passo, período %.2f ms, %.2f Hz entregues) — é o degrau que ancora o teto publicado" % [
						label, total, float(row["medianMs"]), float(row["periodMs"]), float(row["achievedHz"])])
		# CARGA: mais instâncias no mesmo processo têm de custar mais passo, e RSS não
		# pode encolher quando o processo acumula mundo. A tolerância é relativa porque
		# a máquina deste run está sob concorrência de outros agentes: um degrau mais
		# fundo pode perder um pouco pro ruído, mas não pode derrubar a curva.
		if previous.has("medianMs"):
			CheckTiming(float(row["medianMs"]) >= float(previous["medianMs"]) * MonotonicFloorPct - 0.5,
					"nível %s: mediana %.2f ms não desabou contra o nível anterior (%.2f ms) — a escada sobe com o total de players" % [
						label, float(row["medianMs"]), float(previous["medianMs"])])
			Check(int(row["rssMb"]) >= int(previous["rssMb"]),
					"nível %s: RSS não encolheu com as instâncias extras (%d -> %d MB)" % [
						label, int(previous["rssMb"]), int(row["rssMb"])])
		previous = row
		if li == 0:
			firstRow = row
		# O âncora do teto é o MAIOR degrau efetivamente medido dentro do orçamento, não
		# o maior que a escada pediu: se a máquina for mais lenta, o número publicado
		# encolhe com ela em vez de mentir.
		if not bool(row["missedBudget"]):
			anchorRow = row
			deepestInsidePlayers = int(row["players"])
		lastRow = row

		# (a) CALIBRAÇÃO, no nível mais leve, para o delta ser atribuível à queima.
		if li == 0:
			var physBefore : int = int(calib.get("steps"))
			calib.set("us", CalibrationBurnUs)
			await _frames(WarmupFrames)
			var calibrated : Dictionary = await _measure("%s + calibre %d us/passo" % [label, CalibrationBurnUs], total, level)
			var expectedBurn : float = float(CalibrationBurnUs) / 1000.0
			calib.set("us", 0)
			await _frames(WarmupFrames)
			Check(int(calib.get("steps")) - physBefore >= int(calibrated["steps"]) / 2,
					"o calibre queimou de verdade (%d passos de física com ele ligado)" % (int(calib.get("steps")) - physBefore))
			Check(float(calibrated["physMs"]) >= float(row["physMs"]) + expectedBurn * CalibrationFloorPct,
					"calibre: +%.2f ms de física por passo foram vistos pelo monitor (%.2f -> %.2f ms; piso %.2f ms)" % [
						expectedBurn, float(row["physMs"]), float(calibrated["physMs"]), expectedBurn * CalibrationFloorPct])
			# Conferência da unidade de CPU: com 4 ms/passo de spin o processo tem de
			# consumir ao menos metade disso em utime/stime. Se o parse de
			# `/proc/self/stat` estivesse lendo o campo errado, os ms de CPU da tabela
			# seriam ruído e o confronto com `cpus: 2` seria ficção.
			Check(float(calibrated["cpuMsPerStep"]) >= float(row["cpuMsPerStep"]) + expectedBurn * 0.5,
					"CPU por passo reage ao calibre (%.2f -> %.2f ms/passo) — a leitura de /proc está na unidade certa" % [
						float(row["cpuMsPerStep"]), float(calibrated["cpuMsPerStep"])])
			# O DENOMINADOR da sonda de ruído, conferido aqui e não no degrau-sonda: a
			# fração da máquina atribuída a este processo tem de subir com a queima. No
			# degrau mais leve há folga (0,04 núcleo de um total de 1), então o modelo
			# "CPU sobe e o período não" vale; no degrau-sonda o laço já está colado em
			# 1,00 núcleo e a queima vira período, não fração — ver `ownRisePct`, medida
			# em 2026-09-28: 8.4% -> 8.3% da máquina com 40 ms/passo injetados.
			var expectedOwnRise : float = ownRisePct(CalibrationBurnUs, float(row["periodMs"]),
					OS.get_processor_count(), float(row["cores"]))
			CheckTiming(float(calibrated["ownPct"]) >= float(row["ownPct"]) + expectedOwnRise * 0.4,
					"a queima injetada aparece como CPU deste processo (%.2f%% -> %.2f%% da máquina; previsto +%.2f pts, cobrado +%.2f)" % [
						float(row["ownPct"]), float(calibrated["ownPct"]), expectedOwnRise, expectedOwnRise * 0.4])
			rows.pop_back()	# a linha do calibre não é nível de capacidade

		# (b) DETECTOR DE PERÍODO + (c) ATRIBUIÇÃO + (d) CENSO MORDE: no degrau-sonda.
		if isProbe:
			await _proofOverload(row, total, level)
			await _proofAttribution(row, firstRow, total, level)
			await _proofCensusBites(level)
			proofsRan = 3

	CheckCeiling(insideCount > 0, "pelo menos um degrau afirmado (%dx%d) ficou dentro do orçamento nesta máquina" % [
			int(AssertedInstances[0]), cap])
	await _publish(firstRow, anchorRow, lastRow)
	_checkProcessFence(lastRow)
	_checkResourceBound(lastRow)
	_checkDocAnchors()
	await _finish()

# (b) PROVA DO DETECTOR DE ESTOURO — com o processo no degrau mais carregado, 40 ms
# de queima por passo (acima dos 33,3 ms) TEM de empurrar o período real para fora
# do orçamento. Sem esta perna, "nenhum nível estourou" poderia significar "o
# detector não vê nada".
func _proofOverload(top : Dictionary, total : int, level : int) -> void:
	print("-- perna (b): detector de período com sobrecarga real --")
	calib.set("us", OverloadBurnUs)
	await _frames(WarmupFrames)
	var overloaded : Dictionary = await _measure("%dx%d + sobrecarga %d us/passo" % [level, cap, OverloadBurnUs], total, level)
	calib.set("us", 0)
	await _frames(WarmupFrames)
	Check(bool(overloaded["missedBudget"]),
			"detector de estouro responde: %d ms/passo queimados levaram o período a %.2f ms (> budget %.2f ms)" % [
				OverloadBurnUs / 1000, float(overloaded["periodMs"]), budgetMs])
	Check(float(overloaded["periodMs"]) >= float(OverloadBurnUs) / 1000.0 * 0.6,
			"o período medido sobe com a queima injetada (%.2f ms com %d ms/passo)" % [
				float(overloaded["periodMs"]), OverloadBurnUs / 1000])
	Check(float(overloaded["cpuMsPerStep"]) >= float(OverloadBurnUs) / 1000.0 * 0.5,
			"e a CPU medida acompanha a queima (%.2f ms/passo, %.2f core(s)) — nada aqui é conta de relógio dormindo" % [
				float(overloaded["cpuMsPerStep"]), float(overloaded["cores"])])
	# A queima, no degrau saturado, NÃO pode aparecer como fração da máquina: o laço de
	# tick é um thread só e já está em 1,00 núcleo — medido neste run, 8.4% -> 8.3% dos
	# 12 núcleos com 40 ms/passo injetados, e o teto de um thread num host de 12 é
	# exatamente 100/12 = 8.33%. Cobrar +10 pontos ali era pedir o impossível; o que a
	# queima devolve num processo work-bound é PERÍODO. A conferência da fração mora na
	# perna do calibre, onde há folga — ver `ownRisePct`.
	CheckTiming(float(overloaded["periodMs"]) >= float(top["periodMs"]) + float(OverloadBurnUs) / 2000.0,
			"no degrau saturado a queima vira período, não fração: %.2f ms -> %.2f ms com %d ms/passo injetados" % [
				float(top["periodMs"]), float(overloaded["periodMs"]), OverloadBurnUs / 1000])
	# MORDIDA da régua de cauda: com 40 ms/passo injetados a FRAÇÃO de passos acima de
	# orçamento+folga tem de ULtrapassar o corte que pagina. É o lado avesso do teto
	# cobrado nos degraus afirmados, e existir porque uma régua de taxa sem mordida pode
	# ser verde para sempre: ou a queima real passa do corte, ou o número lido do fonte
	# não é o que a janela está cobrando.
	var burnOverPct : float = 100.0 * float(overloaded["stepsOverBudget"]) / maxf(float(overloaded["periodSteps"]), 1.0)
	Check(burnOverPct > alertPagePct, "a régua de cauda morde: %d ms/passo injetados deixaram %.1f%% dos passos (%d de %d) acima de orçamento+folga, contra o corte de %.1f%% que pagina" % [
			OverloadBurnUs / 1000, burnOverPct, int(overloaded["stepsOverBudget"]), int(overloaded["periodSteps"]), alertPagePct])
	# CONTENÇÃO — a perna que diz QUEM viu a queima, não só que alguém contou. Os 40 ms
	# são queimados no `_physics_process` de um node comum, e um detector de estouro só
	# vale se a janela que ele cronometra COBRE esse node: se o bracket fechasse antes
	# do despacho de física, ou se ele só contasse o pump de uma instância, a queima
	# passaria inteira por fora e a taxa acima seria verde mesmo com o laço cego. Os
	# dois instrumentos têm de confessar o número sozinho, sem a taxa: este harness na
	# sua janela, o produto no acumulado que sai por /metrics.
	CheckCeiling(float(overloaded["workMaxMs"]) >= float(OverloadBurnUs) / 1000.0 * 0.9,
			"o bracket deste harness contém a queima: pior passo de despacho %.2f ms com %d ms/passo injetados" % [
				float(overloaded["workMaxMs"]), OverloadBurnUs / 1000])
	CheckCeiling(int(overloaded["prodWorkMaxUs"]) >= OverloadBurnUs * 9 / 10,
			"e o do produto também: `shambleta_step_work_seconds_max` chegou a %.2f ms neste processo, o que prova que a janela que /metrics exporta cronometra o despacho inteiro e não uma fração dele" % [
				float(overloaded["prodWorkMaxUs"]) / 1000.0])
	CheckEq(int(overloaded["instrumentDrift"]), 0,
			"com a queima ligada o bracket continua sub-intervalo do período do mesmo índice (drift %d) — a contenção acima não é artefato de séries desalinhadas" % int(overloaded["instrumentDrift"]))
	rows.pop_back()	# sobrecarga artificial não é nível de capacidade

# A perna de retorno em puro, para poder ser mordida em mesa: `predictedMs` é o custo
# marginal do degrau (cheio menos nível 1) e `cameBackMs` é o que a reabertura devolveu
# (restabelecido menos pausa). Denominador morto é FALSO, não vazio: sem marginal não há
# o que recuperar, e uma régua que verdeia com `predictedMs` 0 verdeia por construção.
static func resumeRecovers(predictedMs : float, cameBackMs : float) -> bool:
	return predictedMs > 0.0 and cameBackMs >= predictedMs * ResumeRecoverFloorPct

# (c) ATRIBUIÇÃO: no degrau mais carregado todas as instâncias de farm vão para
# `PROCESS_MODE_DISABLED` e o passo é remedido. Se o número do nível viesse do boot
# (e não das instâncias carregando players), pausá-las não mudaria nada — e é
# exatamente isso que esta perna reprova.
func _proofAttribution(top : Dictionary, first : Dictionary, total : int, level : int) -> void:
	print("-- perna (c): trabalho atribuído às instâncias, não ao piso do boot --")
	if first.is_empty():
		Check(false, "há um nível 1 medido para comparar a atribuição")
		return
	var pausedCount : int = _setDedicadosPaused(true)
	await _frames(WarmupFrames)
	var paused : Dictionary = await _measure("%dx%d instâncias pausadas" % [level, cap], total, level)
	CheckEq(pausedCount, level, "%d instância(s) de farm pausada(s) de fato (PROCESS_MODE_DISABLED)" % pausedCount)
	var predicted : float = float(top["medianMs"]) - float(first["medianMs"])
	var recovered : float = float(top["medianMs"]) - float(paused["medianMs"])
	CheckTiming(recovered > 0.0,
			"pausar as instâncias derruba o trabalho do passo: %.2f -> %.2f ms (%.2f ms devolvidos)" % [
				float(top["medianMs"]), float(paused["medianMs"]), recovered])
	CheckTiming(recovered >= predicted * AttributionFloorPct,
			"a pausa devolve ao menos %.0f%% do custo marginal medido entre o nível 1 e este (previsto %.2f ms, devolvido %.2f ms)" % [
				AttributionFloorPct * 100.0, predicted, recovered])
	CheckTiming(float(paused["medianMs"]) <= float(first["medianMs"]) + maxf(2.0, float(first["medianMs"]) * 0.5),
			"com as instâncias paradas o processo volta perto do piso medido (%.2f ms vs. piso %.2f ms)" % [
				float(paused["medianMs"]), float(first["medianMs"])])
	rows.pop_back()	# o nível pausado é controlador, não degrau de capacidade
	_setDedicadosPaused(false)
	await _frames(WarmupFrames)
	var resumed : Dictionary = await _measure("%dx%d restabelecido" % [level, cap], total, level)
	var cameBack : float = float(resumed["medianMs"]) - float(paused["medianMs"])
	CheckTiming(resumeRecovers(predicted, cameBack),
			"e o trabalho volta quando as instâncias voltam (%.2f -> %.2f ms, %.2f ms devolvidos de %.2f ms de custo marginal, piso %.0f%%)" % [
				float(paused["medianMs"]), float(resumed["medianMs"]), cameBack, predicted, ResumeRecoverFloorPct * 100.0])
	rows.pop_back()
	# Mesa: o tripleto que derrubou o runner, os estados que esta perna existe para ver, e a
	# borda do piso. Sem o negativo, "voltou" continua sendo tão inobservável quanto era antes
	# de a régua ter um predicado próprio — e é ele que prova que a acusação existe.
	print("-- controles da perna de retorno (mesa) --")
	Check(resumeRecovers(119.40, 97.24), "controle: o que o runner mediu (123,91 -> 1,40 -> 98,64 ms) voltou: 81% do marginal devolvidos")
	Check(not resumeRecovers(119.40, 0.0), "controle: nada devolvido (instância destruída em vez de pausada) fica VERMELHO")
	Check(not resumeRecovers(119.40, 59.70), "controle: devolver metade do marginal fica VERMELHO — o piso do retorno é mais alto que o da pausa")
	Check(resumeRecovers(119.40, 83.58), "controle: devolver exatamente 70% passa — o piso é inclusivo")
	Check(not resumeRecovers(0.0, 0.0), "controle: degrau cheio igual ao nível 1 (denominador morto) não verdeja")

# (d) O CENSO MORDE: um player sai da instância A e entra na B (sessão idle desligada
# antes e reatada depois, para não deixar policy órfã). O censo tem de ver A-1, B+1 e
# uma instância ACIMA do cap — o mesmíssimo estado que `_checkShape` reprova. É o
# controle negativo da perna de forma: prova que "0 failures" não é régua cega.
func _proofCensusBites(level : int) -> void:
	print("-- perna (d): controle negativo do censo (forma quebrada tem de ser vista) --")
	var census : Dictionary = _census()
	var entries : Array = census["entries"]
	if not CheckEq(entries.size(), level, "censo íntegro antes da perturbação (%d instâncias)" % entries.size()):
		return
	var victim : Object = null
	var source : Object = entries[0]["inst"]
	var target : Object = entries[1]["inst"]
	var sourceID : int = int(entries[0]["id"])
	var targetID : int = int(entries[1]["id"])
	for player in (source.get("players") as Array):
		if player != null and is_instance_valid(player):
			victim = player
			break
	if not Check(victim != null, "há um player para perturbar na instância #%d" % sourceID):
		return
	var beforeSource : int = (source.get("players") as Array).size()
	var beforeTarget : int = (target.get("players") as Array).size()
	policyScript.call("StopIdleSession", victim)
	worldAgentScript.call("PopAgent", victim)
	worldAgentScript.call("PushAgent", victim, target)
	await _frames(6)
	var broken : Dictionary = _census()
	CheckEq(int(broken["overCap"]), 1, "forma quebrada é VISTA: instância #%d ficou com %d players, acima do cap %d (%s)" % [
			targetID, beforeTarget + 1, cap, _censusText(broken)])
	CheckEq(int(broken["players"]), int(census["players"]), "e o TOTAL do processo não mudou — o censo conta players, não instâncias (%d)" % int(census["players"]))
	CheckEq((source.get("players") as Array).size(), beforeSource - 1, "a origem perdeu exatamente um (%d -> %d)" % [beforeSource, (source.get("players") as Array).size()])
	# Devolve ao lugar: `StartIdleSession` faz o warp para a instância da zona dele e
	# reanexa a policy, então o estado volta a ser o que as checks descrevem.
	policyScript.call("StartIdleSession", victim, int(sourceID - zoneBase))
	await _frames(WarmupFrames)
	var fixed : Dictionary = _census()
	CheckEq(int(fixed["overCap"]), 0, "forma restaurada: nenhuma instância acima do cap (%s)" % _censusText(fixed))
	CheckEq(int(fixed["players"]), int(census["players"]), "e o total continua o mesmo depois de reatarr a sessão (%d)" % int(fixed["players"]))

# ------------------------------------------------------------------ o teto publicado

# Os dois números que §3/§6 dizem faltarem. A unidade da extrapolação é INSTÂNCIA
# CHEIA, porque é assim que o processo ganha players neste shape:
# `WorldInstance.MAX_PLAYERS_PER_INSTANCE` fecha a instância, então o próximo player
# real só chega com uma instância nova — fazer a conta em "players avulsos" seria
# inventar um player que a regra de lotação não deixa existir.
#
# A reta do tick é inclinada no UNIQUE ponto onde a escada cruza o orçamento: o
# degrau medido mais fundo DENTRO e o primeiro FORA. Usar os extremos da escada
# inteira daria uma reta que não passa por lugar nenhum perto da ruptura (o custo é
# convexo: cada zona traz mobs e mapa próprios), e uma reta errada perto do teto é
# exatamente o tipo de número que faz um beta lotar uma zona a mais.
const RungTolerancePct : float = 0.20		# o degrau afirmado tem de caber na reta em <= 20%

# (e) A SONDA DE RUÍDO CONFERIDA EM MESA. O galho que decide "esta janela não mede
# nada" só vale se a aritmética dele for a afirmada, e mesa construída é o único jeito
# de provar isso sem tomar a máquina do usuário de refém. O caso dos oito núcleos
# nossos é o discriminante: uma sonda que lesse ocupação da máquina sem subtrair o
# próprio processo diria 66,7% de ruído exatamente quando é o produto sendo medido, e
# o harness jogaria fora a própria medição — ruído confessado como cegueira.
# Cada linha é [caso, wall da janela em us, CPU da máquina na janela em us, CPU deste
# processo em us, núcleos, % alheio esperado, ruidoso esperado].
const NoiseCases : Array = [
	["máquina ociosa, nós 1%", 1000000, 120000, 120000, 12, 0.0, false],
	["só nós, um núcleo inteiro", 1000000, 1000000, 1000000, 12, 0.0, false],
	["só nós, OITO núcleos (discriminante)", 1000000, 8000000, 8000000, 12, 0.0, false],
	["vizinho come oito núcleos, nós 0,1", 1000000, 8100000, 100000, 12, 66.7, true],
	["vizinho exatamente na borda de 25%", 1000000, 3100000, 100000, 12, 25.0, false],
	["vizinho meio ponto acima da borda", 1000000, 3200000, 100000, 12, 25.8, true],
	["rounding: nosso delta acima do agregado", 1000000, 100000, 200000, 12, 0.0, false],
	["sem /proc/stat legível", 1000000, -1, 100000, 12, -1.0, false],
	["núcleos zero (não divide por zero)", 1000000, 1000000, 100000, 0, -1.0, false],
]

# Mesa da decisão de leitura — [rótulo, condition, ruidoso, a régua lê?].
# A linha que importa é a 2 e a 3: `quieta + estourado` é o VERMELHO real (a régua
# continua barrando regressão quando o host está livre — sem isso, a mudança seria um
# jeito de nunca falhar) e `ruidosa + cumprido` é o verde que sobrevive ao vizinho.
const CeilingReadCases : Array = [
	["quieta, teto cumprido", true, false, true],
	["quieta, teto estourado -> vermelho de verdade", false, false, true],
	["ruidosa, teto cumprido -> verde lido", true, true, true],
	["ruidosa, teto estourado -> não medido", false, true, false],
]

# [rótulo, ruidoso, lê?] — a relacional é a que NÃO tem o privilégio do teto: sob
# ruído ela não lê nem o verde, porque a janela de referência também infla.
const TimingReadCases : Array = [
	["quieta", false, true],
	["ruidosa", true, false],
]

# Mesa da convergência — [rótulo, medianas, center, tol, concordância esperada]. Os
# controles plantados: o caso real deste host ([5.13 7.66 5.52], uma outlier) e o que
# a régua tem de reprovar, um nível bimodal. Sem a linha de duas fora, a maioria seria
# uma forma de nunca falhar.
const PassAgreeCases : Array = [
	["as três batem", [5.5, 5.6, 5.4], 5.5, 0.25, 3],
	["host quieto medido: uma passada 39% acima", [5.13, 7.66, 5.52], 5.52, 0.25, 2],
	["nível bimodal: duas fora", [5.0, 9.0, 15.0], 9.0, 0.25, 1],
	["center zero não divide", [0.0, 0.0, 0.0], 0.0, 0.25, 3],
	["tolerância zero só aceita o center", [5.0, 5.0001, 6.0], 5.0, 0.0, 1],
]

# Mesa do teto de um núcleo — [rótulo, burn us, período ms, núcleos, núcleos nossos
# antes, alta esperada]. A linha discriminante é a saturada: 40 ms/passo num processo
# já em 1,00 núcleo não pode subir nada, e uma fórmula que devolvesse +10 pts ali é
# exatamente o erro que este run cometeu.
const OwnRiseCases : Array = [
	["calibre com folga: 4 ms num passo de 33,6", 4000, 33.6, 12, 0.04, 0.99],
	["degrau-sonda saturado: 40 ms com 1,00 núcleo", 40000, 50.8, 12, 1.0, 0.0],
	["metade de um núcleo de folga", 40000, 40.0, 10, 0.5, 5.0],
	["host de um núcleo", 4000, 33.6, 1, 0.0, 11.9],
]

func _proofNoiseProbe() -> void:
	print("-- perna (e): a sonda de ruído externo conferida em mesa --")
	Check(_hostBusyUs() >= 0, "sonda lê a CPU da máquina em %s — sem essa leitura nenhuma régua de tempo daqui é lida" % HostStatPath)
	Check(_loadavg1() >= 0.0, "testemunha independente legível: loadavg de %s impresso em toda linha de nível" % LoadAvgPath)
	for case in NoiseCases:
		var got : float = foreignPct(int(case[1]), int(case[2]), int(case[3]), int(case[4]))
		var noisyGot : bool = isNoisy(got)
		Check(absf(got - float(case[5])) < 0.51 and noisyGot == bool(case[6]),
				"mesa %s: esperado %.1f%% alheio / ruidoso=%s, obtido %.1f%% / ruidoso=%s" % [
					str(case[0]), float(case[5]), str(bool(case[6])), got, str(noisyGot)])
	for case in CeilingReadCases:
		Check(readsCeiling(bool(case[1]), bool(case[2])) == bool(case[3]),
				"mesa de leitura (teto) %s: régua lê=%s, obtido lê=%s" % [
					str(case[0]), str(bool(case[3])), str(readsCeiling(bool(case[1]), bool(case[2])))])
	for case in TimingReadCases:
		Check(readsTiming(bool(case[1])) == bool(case[2]),
				"mesa de leitura (relacional) %s: régua lê=%s, obtido lê=%s" % [
					str(case[0]), str(bool(case[2])), str(readsTiming(bool(case[1])))])
	for case in PassAgreeCases:
		var gotAgree : int = passAgreement(case[1], float(case[2]), float(case[3]))
		Check(gotAgree == int(case[4]),
				"mesa de convergência %s: esperada concordância %d/%d, obtida %d/%d" % [
					str(case[0]), int(case[4]), (case[1] as Array).size(), gotAgree, (case[1] as Array).size()])
	for case in OwnRiseCases:
		var gotRise : float = ownRisePct(int(case[1]), float(case[2]), int(case[3]), float(case[4]))
		Check(absf(gotRise - float(case[5])) < 0.02,
				"mesa do teto de um núcleo %s: previsto +%.2f pts da máquina, fórmula devolve +%.2f" % [
					str(case[0]), float(case[5]), gotRise])
	Note("limite declarado: %.0f%% da máquina comido por outro processo invalida a janela; o `cpus: 2` do compose num host de %d núcleos espera %.1f%%" % [
			ForeignCpuNoisePct, OS.get_processor_count(), 100.0 * float(ComposeCpus) / float(maxi(OS.get_processor_count(), 1))])

func _fitInstances(first : Dictionary, breach : Dictionary) -> Dictionary:
	var n1 : int = int(first["instances"])
	var n2 : int = int(breach["instances"])
	var slope : float = (float(breach["medianMs"]) - float(first["medianMs"])) / float(n2 - n1)
	var base : float = float(first["medianMs"]) - slope * float(n1 - 1)
	var inside : int = n1
	if slope > 0.001:
		inside = maxi(n1, int(floor((budgetMs - base) / slope)) + 1)
	return {
		"slope": slope,
		"base": base,
		"inside": inside,
		"ordered": slope > 0.001 and float(breach["medianMs"]) > float(first["medianMs"]),
	}

func _publish(first : Dictionary, anchor : Dictionary, deepest : Dictionary) -> void:
	print("-- teto do processo (número do beta) --")
	if first.is_empty() or deepest.is_empty() or int(deepest["instances"]) <= int(first["instances"]):
		Check(false, "escada com dois degraus medidos para inclinar a reta (primeiro %s, mais fundo %s)" % [
				str(first.get("label")), str(deepest.get("label"))])
		return
	# Acha o par de degraus que cruza o orçamento, na ordem em que foram medidos.
	var fit : Dictionary = {}
	var bracket : String = ""
	for i in range(rows.size() - 1):
		var below : Dictionary = rows[i]
		var above : Dictionary = rows[i + 1]
		if not bool(below["missedBudget"]) and bool(above["missedBudget"]):
			fit = _fitInstances(below, above)
			bracket = "%s -> %s" % [str(below["label"]), str(above["label"])]
			break
	var slopePerInstance : float = 0.0
	var base : float = 0.0
	var fitInstances : int = int(first["instances"])
	if fit.is_empty():
		# Nenhum degrau estourou nesta máquina: a escada inteira coube. Não dá para
		# inclinar uma reta com um ponto só, então o número AFIRMADO é o degrau mais
		# fundo medido, e a reta dos extremos vira só uma nota de leitura.
		var allFit : Dictionary = _fitInstances(first, deepest)
		slopePerInstance = float(allFit["slope"])
		base = float(allFit["base"])
		fitInstances = int(allFit["inside"])
		Check(slopePerInstance > 0.001, "custo marginal por instância-cheia medido até o fim da escada: %.2f ms/passo" % slopePerInstance)
		Check(fitInstances >= int(deepest["instances"]),
				"nenhum degrau da escada %s estourou nesta máquina: o teto de tick é LIMITADO PELA RÉGUA (>= %d players medidos), não pelo processo" % [
					str(CapacityInstances), int(deepest["players"])])
	else:
		Check(bool(fit["ordered"]),
				"o degrau que estoura custa MAIS que o degrau afirmado (%s): a reta do teto é inclinada sobre dois pontos que obedecem à ordem" % bracket)
		slopePerInstance = float(fit["slope"])
		base = float(fit["base"])
		fitInstances = int(fit["inside"])
	Check(slopePerInstance > 0.001,
			"custo marginal MEDIDO por instância-cheia no mesmo processo: %.2f ms/passo (%s)" % [
				slopePerInstance, bracket if bracket != "" else "reta dos extremos, sem ruptura na escada"])
	if base <= 0.0:
		# A reta LOCAL entre os dois degraus que cruzam o orçamento tem intercepto
		# negativo porque a escada é CONVEXA: cada instância nova traz mapa, mobs e
		# navegação próprios. Uma reta que não passa pelo chão do processo não pode
		# autorizar um número maior que o chão medido — o teto publicado volta a ser o
		# último degrau MEDIDO dentro do orçamento e a extrapolação fica como nota.
		Note("reta local (%s) com intercepto %.2f ms/passo: escada convexa, não se extrapola acima do chão medido. Teto publicado = último degrau medido dentro do orçamento (%s players), a reta fica como leitura" % [
				bracket, base, str(anchor.get("players"))])
		fitInstances = maxi(1, int(anchor.get("instances", 1)))
	else:
		Note("reta local (%s) com intercepto %.2f ms/passo de piso do processo" % [bracket, base])
	if slopePerInstance <= 0.001:
		return
	var tickCeiling : int = fitInstances * cap
	var residualMs : float = budgetMs - (base + slopePerInstance * float(fitInstances - 1))
	var partialPlayers : int = int(floor(float(cap) * residualMs / slopePerInstance))
	Check(tickCeiling >= int(anchor.get("players", 0)),
			"teto de tick >= maior degrau MEDIDO dentro do orçamento: %d players (%d instâncias x %d) contra %s medidos" % [
				tickCeiling, fitInstances, cap, str(anchor.get("players"))])

	# RSS: mesma escada, reta pelo maior número de degraus (a memória não para de
	# crescer quando o tick estoura, e é a curva inteira que confronta o mem_limit).
	var dPlayers : int = int(deepest["players"]) - int(first["players"])
	if not Check(dPlayers > 0 and int(deepest["rssMb"]) > 0 and int(first["rssMb"]) > 0,
			"escada de RSS com dois pontos medidos (%s -> %s; RSS %d -> %d MB)" % [
				str(first["label"]), str(deepest["label"]), int(first["rssMb"]), int(deepest["rssMb"])]):
		return
	var slopeRss : float = float(int(deepest["rssMb"]) - int(first["rssMb"])) / float(dPlayers)
	Check(slopeRss > 0.0, "inclinação de RSS medida: %.3f MB por player no processo (%d -> %d MB em %d -> %d players)" % [
			slopeRss, int(first["rssMb"]), int(deepest["rssMb"]), int(first["players"]), int(deepest["players"])])
	if slopeRss <= 0.001:
		return
	var floorRss : float = float(first["rssMb"]) - slopeRss * float(int(first["players"]))
	var memCeiling : int = int(floor((float(ComposeMemLimitMb) - floorRss) / slopeRss))
	var betaCeiling : int = mini(tickCeiling, memCeiling)
	Check(betaCeiling >= int(anchor.get("players", 0)),
			"teto confrontado com mem_limit %dM: %d players por tick vs %d por RSS -> planeja-se por %d (%d instâncias de %d)" % [
				ComposeMemLimitMb, tickCeiling, memCeiling, betaCeiling, int(floor(float(betaCeiling) / float(cap))), cap])
	tickCeilingPlayers = tickCeiling
	memCeilingPlayers = memCeiling
	ceilingInstancesCount = fitInstances
	# O NÚMERO que vai para a doc e para a âncora é o degrau MEDIDO mais fundo dentro do
	# orçamento, não a extrapolação: extrapolação de curva convexa é leitura, não plano
	# de lançamento. `tickCeilingPlayers`/`memCeilingPlayers` continuam saindo no log.
	ceilingPlayers = int(anchor.get("players", 0))
	Note("chão de RSS extrapola da curva medida (%d MB no degrau %s, %.3f MB/player -> %.0f MB com zero player); o teto de memória é EXTRAPOLAÇÃO DECLARADA sobre %d M — o que foi medido é a escada %s e o degrau %s" % [
			int(first["rssMb"]), str(first["label"]), slopeRss, floorRss, ComposeMemLimitMb,
			str(CapacityInstances), str(deepest["label"])])
	Note("número do beta, por EXTRAPOLAÇÃO DECLARADA da reta medida: %d players SOMANDO todas as instâncias do mesmo processo (%d instâncias cheias de %d, mais %d players de folga no próximo degrau) antes dos %.2f ms/passo; a memória diria %d players; o vinculante é %s" % [
			tickCeiling, fitInstances, cap, partialPlayers, budgetMs, memCeiling,
			"o tick" if tickCeiling <= memCeiling else "a memória"])
	Note("CPU no degrau medido mais fundo (%s): %.2f ms/passo = %.2f core(s) dos %d disponíveis; contra o `cpus: 2` do compose sobra núcleo, e o que vincula primeiro é o orçamento de %.2f ms/passo do tick de %d Hz" % [
			str(deepest["label"]), float(deepest["cpuMsPerStep"]), float(deepest["cores"]), OS.get_processor_count(), budgetMs, serverFps])

# ------------------------------------------------------------------- a régua em números

# O custo por player CONVIVENTE e o teto de instâncias, ambos como check. É isto que
# transforma a tabela em régua: um vermelho aqui significa "o processo perdeu
# capacidade", não "a máquina estava ocupada" — por isso os limiares têm folga medida
# (ver MarginalUsPerPlayerFence) e cada nível é medido `MeasurePasses` vezes.
func _checkProcessFence(lastRow : Dictionary) -> void:
	print("-- régua: custo por player convivente e teto de instâncias --")
	Check(proofsRan == 3, "as três pernas de prova (detector de período, atribuição às instâncias, censo que morde) rodaram no degrau-sonda %dx%d" % [
			ProbeInstances, cap])
	if rows.is_empty() or lastRow.is_empty() or floorMs <= 0.0 or onePlayerMs <= 0.0:
		Check(false, "escada completa medida (piso %.2f ms, 1 player %.2f ms, %d degraus)" % [floorMs, onePlayerMs, rows.size()])
		return
	marginalUs = (float(lastRow["medianMs"]) - floorMs) * 1000.0 / maxf(float(int(lastRow["players"]) - 1), 1.0)
	var insideRow : Dictionary = {}
	for row in rows:
		if not bool(row["missedBudget"]):
			insideRow = row
	if insideRow.is_empty():
		Check(false, "existe um degrau dentro do orçamento para ancorar o custo afirmado")
	else:
		marginalInsideUs = (float(insideRow["medianMs"]) - floorMs) * 1000.0 / maxf(float(int(insideRow["players"])), 1.0)
	Note("custo MEDIDO por player convivente no mesmo processo: %.0f µs/passo na escada toda (%d players no degrau mais fundo), %.0f µs/passo no trecho AFIRMADO que cabe em %.2f ms (%d players), %.0f µs/passo do 1º player sobre o piso" % [
			marginalUs, int(lastRow["players"]), marginalInsideUs, budgetMs, int(insideRow["players"]),
			(onePlayerMs - floorMs) * 1000.0])
	CheckTiming(marginalUs > 1.0, "custo marginal por player é positivo e mensurável (%.0f µs/passo)" % marginalUs)
	CheckTiming(marginalUs <= MarginalUsPerPlayerFence,
			"RÉGUA: %.0f µs de passo por player convivente <= fence de %.0f µs (medido com %.0f%% de folga; passar disso é perda de capacidade por processo)" % [
				marginalUs, MarginalUsPerPlayerFence, (MarginalUsPerPlayerFence - marginalUs) * 100.0 / MarginalUsPerPlayerFence])
	CheckCeiling(deepestInsidePlayers >= CeilingFencePlayers,
			"RÉGUA: %d players convivos em %d instâncias CHEIAS dentro de %.2f ms/passo >= fence de %d players" % [
				deepestInsidePlayers, int(floor(float(deepestInsidePlayers) / float(cap))), budgetMs, CeilingFencePlayers])
	CheckCeiling(ceilingPlayers >= CeilingFencePlayers, "teto publicado do processo (%d players) não está abaixo do degrau afirmado" % ceilingPlayers)
	for row in rows:
		if AssertedInstances.has(int(row["instances"])):
			if not Check(row.has("passSpreadMs") and row.has("passCount"),
					"nível %s: linha mesclada com as %d passadas (chave de merge presente)" % [
						str(row.get("label")), MeasurePasses]):
				continue
			var spread : float = float(row["passSpreadMs"])
			var mediana : float = float(row["medianMs"])
			var medians : Array = row.get("passMedians", [])
			Check(int(row["passCount"]) == MeasurePasses, "nível %s: %d passadas independentes (%d medidas)" % [
					str(row["label"]), MeasurePasses, int(row["passCount"])])
			# (1) A maioria das passadas tem de concordar com a mediana do degrau. É a
			# pergunta certa sobre três medianas de um monitor de média móvel: um tiro
			# sozinho não veto o nível, mas dois fora significa que o nível não é um
			# número só.
			var agree : int = passAgreement(medians, mediana, PassAgreeTolPct)
			CheckTiming(agree > MeasurePasses / 2,
					"nível %s: %d de %d passadas cabem em ±%.0f%% da mediana %.2f ms (%s) — o número do doc é reproduzível, não um tiro" % [
						str(row["label"]), agree, MeasurePasses, PassAgreeTolPct * 100.0, mediana, str(medians)])
			# (2) A PIOR passada, sozinha, tem de caber no orçamento. É a mais forte das
			# três e a única que sobrevive ao ruído: se até o tiro azarado fecha, o
			# degrau afirmado não depende de sorte de máquina.
			if not medians.is_empty():
				CheckCeiling(float(medians.max()) <= budgetMs,
						"nível %s: até a pior passada (%.2f ms de %.2f ms) cabe no orçamento — o degrau afirmado não depende de tiro feliz" % [
							str(row["label"]), float(medians.max()), budgetMs])
			# (3) Testemunha de legibilidade: divergir mais que UM período de frame entre
			# passadas significa que este host não está medindo este degrau.
			CheckTiming(spread <= budgetMs,
					"nível %s: as passadas não divergem mais que um período de frame (spread %.2f ms <= %.2f ms)" % [
						str(row["label"]), spread, budgetMs])
			Check(float(row["cpuMsPerStep"]) <= budgetMs * ComposeCpus,
					"nível %s: %.2f ms/passo de CPU <= %.2f ms dos cpus %s do compose (não dá para planejar o beta acima do core budget)" % [
						str(row["label"]), float(row["cpuMsPerStep"]), budgetMs * ComposeCpus, str(ComposeCpus)])

# O que BOUNDA N instâncias num processo além do tempo de passo: descritores e threads.
# Lidos do kernel deste processo, não de constante de manual — RLIMIT_NOFILE e
# RLIMIT_NPROC variam por host, por distro e por runtime (ulimit/container).
func _checkResourceBound(lastRow : Dictionary) -> void:
	print("-- recurso por instância: descritores e threads vs RLIMIT deste processo --")
	if lastRow.is_empty() or fdFloor <= 0 or threadFloor <= 0:
		Check(false, "contagem de descritores/threads disponível no chão e no topo da escada (fd chão %d, threads chão %d, última linha %s)" % [
				fdFloor, threadFloor, "sim" if not lastRow.is_empty() else "não"])
		return
	var fdTop : int = int(lastRow["fdCount"])
	var threadsTop : int = int(lastRow["threads"])
	var instancesTop : int = maxi(int(lastRow["instances"]), 1)
	Check(fdTop > 0, "descritores abertos no degrau %dx%d: %d (chão %d)" % [instancesTop, cap, fdTop, fdFloor])
	Check(threadsTop > 0, "threads vivas no degrau %dx%d: %d (chão %d)" % [instancesTop, cap, threadsTop, threadFloor])
	var fdPerInstance : float = float(fdTop - fdFloor) / float(instancesTop)
	var threadsPerInstance : float = float(threadsTop - threadFloor) / float(instancesTop)
	Note("custo MEDIDO por instância: %.2f descritores e %.2f threads (fd %d -> %d, threads %d -> %d entre o chão e %dx%d)" % [
			fdPerInstance, threadsPerInstance, fdFloor, fdTop, threadFloor, threadsTop, instancesTop, cap])
	Check(threadsPerInstance <= 1.0,
			"threads NÃO crescem com instâncias (%.2f por instância; WorldInstance é objeto, não thread) — o teto de threads do kernel (%s) não é o que vincula N" % [
				threadsPerInstance, str(nprocSoft)])
	Check(float(fdTop) <= float(nofileSoft) * 0.5 or nofileSoft <= 0,
			"descritores usados no topo (%d) cabem com folga de 2x no RLIMIT_NOFILE soft deste processo (%s)" % [fdTop, str(nofileSoft)])
	if nofileSoft > 0 and fdPerInstance > 0.001:
		var boundInstances : int = int(floor((float(nofileSoft) * 0.5 - float(fdFloor)) / fdPerInstance))
		Note("com o soft limit desta máquina e o custo medido por instância, o funil de descritores liberaria ~%d instâncias (= %d players) — %s o que a escada mostra como limite real (%d players por tick)" % [
				boundInstances, boundInstances * cap,
				"muito acima de" if boundInstances * cap > ceilingPlayers else "ABAIXO de", ceilingPlayers])
	else:
		Note("descritores não boundam a escada neste processo: soft %s, uso no topo %d" % [str(nofileSoft), fdTop])

# ------------------------------------------------------------------ âncora de doc
#
# Mesma mecânica de `scripts/check_doc_drift.sh:150-162`: o número mora na doc dentro
# de um comentário `<!-- DRIFT <título> <valor> <tolerância> -->` e o gate compara o
# valor contra a fonte derivada — aqui a fonte derivada é a MEDIÇÃO deste run, não um
# diretório. O script de drift não conhece estes títulos (e eu não o edito), então é
# este harness que segura a âncora: quem remede e não reescreve a doc fica vermelho.
const AnchorMarginal : String = "proc_marginal_us_per_player"
const AnchorCeiling : String = "proc_tick_ceiling_players"
const AnchorRung : String = "proc_inside_rung_players"

func _anchorNumbers(title : String) -> Array:
	var out : Array = []
	if not FileAccess.file_exists(ScalingDocPath):
		return out
	var text : String = FileAccess.get_file_as_string(ScalingDocPath)
	var needle : String = "DRIFT " + title
	for raw in text.split("\n"):
		var line : String = String(raw)
		var pos : int = line.find(needle)
		if pos < 0:
			continue
		for token in line.substr(pos + needle.length()).split(" ", false):
			if String(token).is_valid_int():
				out.append(int(token))
			else:
				break
	return out

# A âncora de degrau era unilateral: `medido >= afirmado` só enxerga capacidade CAIR.
# Um run que mede o dobro do que a doc promete passava verde, e quem provisiona o
# servidor lê a doc. A banda agora é medida em DEGRAUS da escada que o próprio run
# andou, não em players: ±100 players sobre 200 aceitava 100, ou seja um erro de 2×
# na promessa passa. Um degrau é o spread que o §3 confessa entre duas corridas (200
# na máquina concorrida, 300 na quieta); dois degraus é o dobro ou a metade do
# afirmado, e isso não é ruído de janela — é a doc mentindo sobre o degrau.
const RungOk : int = 0
const RungOutside : int = 1
const RungUnwalked : int = 2

static func rungBandOk(anchor : int, measured : int, maxSteps : int, ladder : Array) -> int:
	var ia : int = ladder.find(anchor)
	var ib : int = ladder.find(measured)
	if ia < 0 or ib < 0:
		return RungUnwalked
	if absi(ia - ib) > maxSteps:
		return RungOutside
	return RungOk

static func rungVerdict(code : int) -> String:
	if code == RungUnwalked:
		return "a âncora ou o degrau medido não está na escada que este run andou — a doc promete um degrau que a medição não conhece"
	if code == RungOutside:
		return "fora da banda: run e doc não estão no mesmo degrau, nem a um degrau de distância"
	return "no mesmo degrau, ou a um degrau — dentro do spread que a doc confessa"

# Controles plantados da régua de banda: passam pelo MESMO predicado que julga a doc.
# Se a régua voltar a ser unilateral, o controle do degrau acima morde na mesma
# passada; nada aqui é escrito em disco.
func _checkAnchorControls() -> void:
	print("-- controles da régua de degrau (banda bilateral) --")
	var escada : Array = [0, 1, 20, 40, 100, 200, 300, 400]
	Check(rungBandOk(200, 200, 1, escada) == RungOk, "controle: doc 200, run 200 — passa")
	Check(rungBandOk(200, 300, 1, escada) == RungOk, "controle: run um degrau ACIMA da doc passa, porque é o spread que a própria doc confessa")
	Check(rungBandOk(200, 100, 1, escada) == RungOk, "controle: run um degrau ABAIXO passa")
	Check(rungBandOk(200, 400, 1, escada) == RungOutside, "controle: run medindo o DOBRO do que a doc promete fica VERMELHO — era aqui que a régua unilateral passava verde")
	Check(rungBandOk(200, 40, 1, escada) == RungOutside, "controle: run três degraus abaixo da doc fica vermelho")
	Check(rungBandOk(250, 200, 1, escada) == RungUnwalked, "controle: âncora fora da escada é confessada, não tolerada")
	Check(rungBandOk(200, 400, 2, escada) == RungOk, "controle: quem alarga a banda é a doc, não a régua")

func _checkDocAnchors() -> void:
	print("-- âncora de doc: o número de deploy/SCALING.md vs. o que este run mede --")
	if not Check(FileAccess.file_exists(ScalingDocPath), "%s legível a partir do projeto (caminho %s)" % [ScalingDocPath, ScalingDocPath]):
		return
	var measuredMarginal : int = int(round(marginalUs))
	var a1 : Array = _anchorNumbers(AnchorMarginal)
	Check(a1.size() >= 2, "âncora `<!-- DRIFT %s <us> <tolerancia> -->` presente na doc" % AnchorMarginal)
	if a1.size() >= 2:
		var d1 : int = absi(measuredMarginal - a1[0])
		CheckTiming(d1 <= a1[1], "doc diz %d ±%d µs/player; este run mede %d µs (diff %d) — remeçeu, reescreve" % [
				a1[0], a1[1], measuredMarginal, d1])
	var a2 : Array = _anchorNumbers(AnchorCeiling)
	Check(a2.size() >= 2, "âncora `<!-- DRIFT %s <players> <tolerancia> -->` presente na doc" % AnchorCeiling)
	if a2.size() >= 2:
		var d2 : int = absi(ceilingPlayers - a2[0])
		CheckTiming(d2 <= a2[1], "doc diz teto de %d ±%d players por processo; este run extrapola %d (diff %d)" % [
				a2[0], a2[1], ceilingPlayers, d2])
	var a3 : Array = _anchorNumbers(AnchorRung)
	var hasBand : bool = Check(a3.size() >= 2,
			"âncora `<!-- DRIFT %s <players> <degraus> -->` presente na doc COM a banda em degraus — sem banda a régua volta a ser unilateral" % AnchorRung)
	if hasBand:
		var ladder : Array = []
		for row in rows:
			var p : int = int(row["players"])
			if not ladder.has(p):
				ladder.append(p)
		Check(not ladder.is_empty(), "a escada deste run tem degraus para ancorar (%s)" % [ladder])
		var verdict : int = rungBandOk(a3[0], deepestInsidePlayers, a3[1], ladder)
		CheckTiming(verdict == RungOk,
				"doc afirma %d players conviventes dentro do orçamento, banda de %d degrau(s), escada %s; este run mede %d dentro de %.2f ms — %s" % [
					a3[0], a3[1], ladder, deepestInsidePlayers, budgetMs, rungVerdict(verdict)])
	_checkAnchorControls()
func _finish() -> void:
	print("-- limpeza --")
	for agent in agents.duplicate():
		var node : Node = agent as Node
		if node != null and is_instance_valid(node):
			policyScript.call("StopIdleSession", node)
			worldAgentScript.call("RemoveAgent", node)
	agents.clear()
	await _frames(8)
	if sql != null and not charIDs.is_empty():
		sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE ?;", ["%s%%" % NickPrefix])
		sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE ?;", ["%s%%" % AcctPrefix])
		Note("fixtures %s* removidos (%d chars)" % [NickPrefix, charIDs.size()])
	print("== TABELA (deploy/SCALING.md) ==")
	for row in rows:
		print("  %s | %d instancias | %d players | trabalho %.2f ms/passo (fis %.2f + idle %.2f) | p95 %.2f | max %.2f | periodo %.2f ms | budget %.2f ms%s | RSS %d MB | CPU %.2f ms/passo (%.2f core) | %d mobs | %d policies | SQL %.1f rt/tick | mutex %.2f us/tick" % [
			str(row["label"]), int(row["instances"]), int(row["players"]), float(row["medianMs"]),
			float(row["physMs"]), float(row["idleMs"]), float(row["p95Ms"]), float(row["maxMs"]),
			float(row["periodMs"]), budgetMs, " ESTOURADO" if bool(row["missedBudget"]) else "",
			int(row["rssMb"]), float(row["cpuMsPerStep"]), float(row["cores"]),
			int(row["mobs"]), int(row["policies"]), float(row["queriesPerTick"]), float(row["mutexUsPerTick"])])
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	if noiseWindows > 0:
		print("== RUÍDO EXTERNO: %d janelas sem CPU livre (pico %.0f%% da máquina comido por outro processo) => %d réguas de tempo NÃO lidas; %d re-medições esperando janela limpa (%ds de espera) ==" % [
				noiseWindows, worstForeignPct, noiseUnmeasured, noiseWaits, int(noiseWaitMs / 1000)])
	else:
		print("== RUÍDO EXTERNO: zero janelas descartadas — todas as réguas de tempo foram lidas (%d re-medições até achar janela limpa) ==" % noiseWaits)
	# O gancho que `scripts/test.sh` lê é ASCII e sempre impresso, inclusive em zero:
	# ausência da linha significa "este harness não tem a régua de ruído", e um
	# `== GATES COM RUÍDO: none ==` saído de um grep que não achou nada seria a
	# mentira exatamente que o §24-8 existe para impedir. O nome é em ASCII porque a
	# régua humana de cima tem acento, e régua de portão não pode depender de normalização.
	print("== NOISE-DECLARED: %d ==" % noiseWindows)
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
