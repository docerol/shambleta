extends SceneTree

# gate-marker: == Benchmarks:

# SOM-IDLE P2: performance benchmark gate.
# Measures settle, XP walk, and zone catalog operations.
# Exit code: 0 = within budget, 1 = over budget.

const BudgetSettleMs: int = 500
const BudgetZoneCatalogMs: int = 200
# ---------------------------------------------------------------------------
# Réguas de REGRESSÃO — não cercas de sanidade.
#
# A régua anterior era `BudgetSettleP99Ms = 200` contra um p99 medido de 0,52 ms:
# 332× de folga, e um settle 200× mais lento fechava verde. Trocada por baseline
# gravado + fator de folga, com os dois impressos no run para o próximo leitor
# poder conferir sem acreditar em comentário.
#
# Baseline gravado (2026-09-27, 09:13): 13 runs consecutivos de
# `godot --headless --path . -s tests/benchmarks.gd` numa máquina ociosa (12
# núcleos, load average 0,31 no início da série), **o mais quieto deles** — p50
# 465 µs, p99 519 µs. A faixa das 13 passadas foi p50 465–475 µs e p99 519–645 µs
# (1,24× de run a run, e 645 µs é a primeira passada, com cache frio). Recalcule
# com `godot --headless --path . -s tests/perf_baseline.gd`, que mede, imprime a
# comparação e audita o fator.
const BaselineSettleP50Us: int = 465
const BaselineSettleP99Us: int = 519
# Folga de 4×: pega um regresso de 5× (p50 2325 µs, p99 2595 µs estouram os tetos
# de 1860 µs e 2076 µs) e continua abaixo do ruído real da máquina depois de
# normalizada — ver WorstP99NormalizadoSobCargaUs abaixo.
const RegressionHeadroom: int = 4
# O p99 bruto é a cauda, e a cauda é onde a contenção de escalonador aparece: sob
# 24 processos CPU-bound numa máquina de 12 núcleos o settle p99 medido saltou de
# 519 µs para 2366 µs sem que uma linha do caminho mudasse. Para não trocar uma
# régua frouxa por uma régua que flakeia, o gate divide pelo ruído da máquina,
# medido no mesmo processo por um laço puro de CPU (sem SQL, sem I/O): se o
# controle inflate, a leitura é corrigida; se só o settle inflate, é o código.
# 42033 µs é o controle mais quieto já medido nesta máquina: um run ocioso lê
# 42545–46762 µs, ou 1,00×–1,11× — o crédito de ruído só existe ACIMA do piso
# ocioso, nunca como desconto sobre ele.
const BaselineControlUs: int = 42033
const ControlWork: int = 2000000
const ControlReps: int = 3
# Pior p99 NORMALIZADO já medido sob carga hostil nesta máquina (2026-09-27
# 09:32, 14 processos CPU-bound + um harness godot concorrente, load 6,5): bruto
# 3098 µs (5,97× o baseline!) com o controle a 1,93× → 1601 µs normalizado. Este
# número é o que mostra por que a régua divide pelo controle: um teto de 4× batido
# no p99 bruto teria flakeado aqui (3098 > 2076) sem que o caminho do settle tivesse
# mudado uma linha. A auto-auditoria abaixo recusa qualquer folga que fique abaixo
# dele.
const WorstP99NormalizadoSobCargaUs: int = 1601
# ---------------------------------------------------------------------------
# #178 — o dispositivo em que os µs acima são julgados.
#
# Baseline, teto e controle acima são todos ABSOLUTOS, e um número absoluto só quer
# dizer alguma coisa no dispositivo onde foi gravado. O `user://` do harness era sempre
# `$PROJECT/.test-home/<script>`, i.e. o disco onde o repo mora — nesta máquina um
# WDC WD10SPZX a 5400 rpm. Medido em 2026-10-03 com o mesmo trabalho de um settle
# (SQLite CLI, `journal_mode=WAL`, `synchronous=NORMAL`, 200 commits de ~140 KB, duas
# passadas, máquina ociosa):
#   /dev/sda1 ext4, onde o repo está .... 6494 µs e 7512 µs por commit
#   /home     btrfs em nvme0n1p3 ........  845 µs e  847 µs
#   /dev/shm  tmpfs .....................  430 µs e  430 µs
# O teto que a régua cobra do settle INTEIRO é 2076 µs. Um disco que paga 6494 µs só
# para cometer o que um settle escreve não tem teto a cumprir, e o vermelho que sai
# dali acusa o código do caminho por um defeito do dispositivo — foi exatamente assim
# que esta máquina manteve o `one benchmarks` vermelho depois do #125 ter levado o
# checkpoint para fora do COMMIT (drenos sem dono: zero; hitches no settle: zero;
# p99: ainda estourado).
#
# O probe abaixo mede o dispositivo DE ONDE O RUN ESTÁ, pelo funil, no mesmo arquivo
# do banco, com a massa de um settle. Ele não afrouxa nada: onde o dispositivo cabe no
# teto, os vereditos em µs correm byte por byte como corriam antes; onde não cabe, o
# run confessa que não é mensurável e continua VERMELHO — com o motivo, o número e o
# comando que consertam. A alternativa silenciosa (dividir o p99 pela latência do disco)
# compraria verde nesta máquina e escondia a pergunta.
const IoProbePages: int = 34
const IoProbeReps: int = 5
const IoProbeTable: String = "bench_io_probe"
# Cercas de sanidade que ficam, e por quê: o one-shot de 500 ms e as duas leituras
# ordenadas (50 ms) medem um round trip com cache frio, onde a amostra única é
# dominada por aquecimento — não há baseline estável para regressar. O que nelas é
# estrutural (número de queries, transações, tamanho do catálogo) continua exato.
# Fração tolerada de settles acima de 50 ms. O auto-checkpoint do WAL é caro por
# natureza (é um fsync do arquivo) e não existe código de jogo que o barateie — o
# que se pode exigir é a *taxa* do hitch. 2% de 800 iterações são 16; o default do
# SQLite (1000 páginas) media 2 em 200, ou 1%. Acima disso, alguém afrouxou o
# checkpoint ou o colocou num caminho quente.
const BudgetSlowIterPct: int = 2
const BudgetLeaderboardMs: int = 50
const BudgetAuctionBrowseMs: int = 50
# Save/logout: três upserts em lote dentro de uma transação. O orçamento é de
# round trip, não de tempo — é o número que crescia com o progresso do jogador.
const BudgetLogoutQueries: int = 12
const BudgetLogoutTransactions: int = 1
# Crescimento de objeto ao longo dos 800 settles do probe: a régua não media
# memória antes, e foi assim que um `queue_free()` em nó fora da árvore sobreviveu
# ao beta gate.
const BudgetObjectGrowth: int = 400
const BudgetResourceGrowth: int = 200
# 800, não 200: com o auto-checkpoint em 4000 páginas, 200 settles não cruzam a
# fronteira nenhuma vez — o probe fecharia verde sem nunca pagar um checkpoint e
# estaria medindo o cache, não o servidor. 800 crosses a fronteira e devolve o
# custo real no `max`.
const LoadProbeIters: int = 800
const ExpectedZoneCount: int = 27
# Massa das duas leituras ordenadas: 60 personagens para um LIMIT 50 (a página
# tem que nascer cheia e disputada) e 200 listings para um LIMIT 20.
const LbSeedChars: int = 60
const AhSeedListings: int = 200
# As tabelas que penduram linhas num dono e que o expurgo PODE apagar. O par
# [tabela, coluna, tabela-pai, coluna-pai] existe porque o vínculo não é sempre o
# personagem: `ah_escrow_lot` pendura no ANÚNCIO, e foi a cascata da 066 (personagem
# → anúncio) que deixou de ser coberta pela 067 (anúncio → retrato do escrow). Três
# ficam de fora por serem registro, não lixo: `ledger_transaction` (append-only por
# trigger, migration 056), `telemetry_event` (poda por tempo, 065) e
# `ah_price_history` (nenhum leitor pede por anúncio — `RecentSoldPrices` e
# `AHPriceAnchor` ordenam por `item_id`/`sold_at` e `_CollectAHWashPairs` varre a
# janela de lavagem; é preço PAGO, mesma classe do ledger). O censo delas é impresso
# como informação e nunca cobrado.
const OrphanPurgable: Array[Array] = [
    ["item", "char_id", "character", "char_id"],
    ["item_instance", "char_id", "character", "char_id"],
    ["chest_instance", "char_id", "character", "char_id"],
    ["skill", "char_id", "character", "char_id"],
    ["quest", "char_id", "character", "char_id"],
    ["bestiary", "char_id", "character", "char_id"],
    ["stat", "char_id", "character", "char_id"],
    ["auction_listing", "seller_char", "character", "char_id"],
    ["ah_escrow_lot", "listing_id", "auction_listing", "id"],
]
const OrphanDurable: Array[Array] = [
    ["ledger_transaction", "char_id", "character", "char_id"],
    ["telemetry_event", "char_id", "character", "char_id"],
    ["ah_price_history", "listing_id", "auction_listing", "id"],
]
const OrphanAxisChar: String = "character"
const OrphanAxisListing: String = "auction_listing"

func _initialize():
    _run_benchmarks()

func _getAutoload(nodeName: String) -> Node:
    return root.get_node_or_null(NodePath(nodeName))

# Laço puro de CPU: mesmo interpretador, nenhum syscall, nenhum SQL. Só serve para
# dizer "quão ocupada estava esta máquina neste instante".
var _controlSink: int = 0

func _measureControl() -> int:
    var best: int = 1 << 60
    for rep in range(ControlReps):
        var controlStart: int = Time.get_ticks_usec()
        var acc: int = 0
        for i in range(ControlWork):
            acc = (acc * 31 + 7) & 0x7FFFFFFF
        _controlSink = acc
        best = mini(best, Time.get_ticks_usec() - controlStart)
    return best

# Uma transação do probe: `IoProbePages` linhas de uma página cada, escritas pelo funil
# com o writer já travado (`ExecNoLock` é o único writer permitido dentro de
# `Transaction()` — os helpers re-travam a mutex, e recursão é detalhe de implementação,
# não promessa, como a nota de `SQL.gd` em volta do `Transaction` diz).
func _ioProbeTx(sql: Node, pageSize: int) -> bool:
    for i in range(IoProbePages):
        if not sql.ExecNoLock("INSERT INTO %s (b) VALUES (randomblob(%d));" % [IoProbeTable, pageSize]):
            return false
    return true

# Melhor das `IoProbeReps` transações, em µs — o MESMO melhor-de-N do controle de CPU,
# pela mesma razão: o que se quer saber é o piso do dispositivo, não o pico da disputa.
# Devolve -1 se o probe não mediu nada (DDL que não entra, transação que não comete):
# ausência de leitura não é "dispositivo rápido", é ausência.
func _measureDeviceCommitUs(sql: Node, pageSize: int) -> int:
    if pageSize <= 0:
        return -1
    if not sql.TryExec("CREATE TABLE IF NOT EXISTS %s (id INTEGER PRIMARY KEY, b BLOB);" % IoProbeTable):
        return -1
    var best: int = -1
    var falhou: bool = false
    for rep in range(IoProbeReps):
        var started: int = Time.get_ticks_usec()
        if not sql.Transaction(_ioProbeTx.bind(sql, pageSize)):
            falhou = true
            break
        var took: int = Time.get_ticks_usec() - started
        if best < 0 or took < best:
            best = took
    if not sql.TryExec("DROP TABLE %s;" % IoProbeTable):
        return -1
    # Uma repetição que não comite não é "runha mais lenta": o probe perdeu a capacidade
    # de escrever a classe de trabalho que ele mesmo julga, e um piso vindo de 2 de 5
    # tentativas seria ler o dispositivo pela metade.
    return -1 if falhou else best

# Por que os vereditos em µs não podem ser julgados aqui, em uma frase — separada da
# impressão para que o controle plantado exercite cada ramo, mesma forma de
# `_motivoAtribuicaoImpossivel`.
func _motivoDispositivoImpossivel(ioUs: int, ceilingUs: int) -> String:
    if ioUs < 0:
        return "o probe do dispositivo não mediu nada (a transação de %d páginas não comitou)" % IoProbePages
    if ioUs > ceilingUs:
        return "um commit de %d páginas custa %d µs neste dispositivo, acima dos %d µs que a régua cobra do settle inteiro" % [IoProbePages, ioUs, ceilingUs]
    return ""

func _run_benchmarks():
    print("== Performance Benchmarks ==")

    var launcher: Node = _getAutoload("Launcher")
    if launcher == null:
        print("FATAL: Launcher autoload missing")
        quit(1)
        return

    var waited: int = 0
    var sqlNode: Node = null
    var worldNode: Node = null
    while waited < 30000:
        await create_timer(0.25).timeout
        waited += 250
        sqlNode = launcher.SQL
        worldNode = launcher.World
        if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
            break

    if sqlNode == null or worldNode == null or not sqlNode.isInitialized or not worldNode.isInitialized:
        print("FATAL: Services not initialized within timeout")
        quit(1)
        return

    print("Services initialized after %d ms" % waited)

    # Beta fechado: duck-typed (ver run_idle_tests.gd) — sem refs estáticas.
    var sql: Node = sqlNode
    var economy: Node = launcher.Economy
    var failures: int = 0
    # Linha de largada do censo de órfãos: lida ANTES de qualquer fixture, para que
    # o que for cobrado no fim seja lixo mintado por esta corrida, não herança.
    var orphansBefore: Array[int] = _orphanCounts(sql)

    # Benchmark: settle (single character) — caminho real OfflineSettle.
    # (Antes chamava EconomyService.SettleCharacter, que não existe: o
    # benchmark nunca rodou. Beta fechado: usa SettlePending duck-typed.)
    var settleScript: GDScript = load("res://sources/idle/OfflineSettle.gd")
    sql.AddAccount("bench_settle", "testpass", "bench_settle@test.local")
    var benchAcct: int = sql.GetAccountID("bench_settle")
    # ActorCommons via load() em runtime (ref estática no -s quebra o compile
    # antes dos autoloads — mesma regra de run_idle_tests.gd).
    var commons: GDScript = load("res://sources/actor/ActorCommons.gd")
    sql.AddCharacter(benchAcct, "BenchSettle", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var benchChar: int = sql.GetCharacterID(benchAcct, "BenchSettle")
    sql.SetCharacterFarmZone(benchChar, 1)
    sql.UpdateSettleAnchor(benchChar, 1750000000, 1.0)
    sql.ResetCounters()
    var settleStart: int = Time.get_ticks_msec()
    var settleResult: Dictionary = settleScript.SettlePending(benchChar)
    var settleMs: int = Time.get_ticks_msec() - settleStart
    var settleQueries: int = sql.QueryCount()
    var settleTx: int = sql.TransactionCount()
    # Expurgo pela API de produção, não pelo `delete_rows` cru: é o `RemoveCharacter`
    # que dispara a cascata da migration 066, e o delete cru era exatamente o defeito
    # que ela fecha — o gate mintia 40 lotes por settle e levava só a ficha embora.
    sql.RemoveCharacter(benchChar)
    sql.RemoveAccount(benchAcct)
    print("Settle benchmark: %d ms, %d queries, %d tx (budget: %d ms)" % [settleMs, settleQueries, settleTx, BudgetSettleMs])
    if settleResult.is_empty():
        print("FAIL: settle returned empty")
        failures += 1
    if settleMs > BudgetSettleMs:
        print("FAIL: settle exceeded budget")
        failures += 1

    # Benchmark: zone catalog — o laço ia até 41 numa coleção de 24; agora o
    # tamanho esperado é asserção, não coincidência de print.
    var catalogStart: int = Time.get_ticks_msec()
    var zoneCount: int = 0
    var farmZones: GDScript = load("res://sources/idle/FarmZoneData.gd")
    for zoneID in range(1, ExpectedZoneCount + 1):
        if farmZones.GetZone(zoneID):
            zoneCount += 1
    var catalogMs: int = Time.get_ticks_msec() - catalogStart
    print("Zone catalog benchmark: %d ms for %d zones (budget: %d ms)" % [catalogMs, zoneCount, BudgetZoneCatalogMs])
    if catalogMs > BudgetZoneCatalogMs:
        print("FAIL: zone catalog exceeded budget")
        failures += 1
    if zoneCount != ExpectedZoneCount:
        print("FAIL: zona faltando no catálogo (%d de %d)" % [zoneCount, ExpectedZoneCount])
        failures += 1

    # Benchmark: as duas leituras ordenadas quentes do produto, com linhas reais na
    # mesa e o plano de execução conferido. Antes era o "XP walk" de `totalXp += 10`
    # sobre zero linhas: sem dados, o ORDER BY não compete com nada e um índice
    # ausente imprime exatamente a mesma coisa. O índice da migration 047 sem
    # asserção de plano é arquivo que ninguém usa.
    var lbSeed: Array[int] = []
    sql.AddAccount("bench_lb", "testpass", "bench_lb@test.local")
    var lbAcct: int = sql.GetAccountID("bench_lb")
    for i in range(LbSeedChars):
        sql.AddCharacter(lbAcct, "BenchLb%d" % i, commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
        var seedChar: int = sql.GetCharacterID(lbAcct, "BenchLb%d" % i)
        lbSeed.append(seedChar)
        # Potência esparsa e fora de ordem de inserção: se o índice não existir,
        # o SQLite paga temp B-tree e o time/plan mostram.
        sql.UpdatePowerScore(seedChar, (i * 7919) % (LbSeedChars * 3))
    # Realce nas 20 linhas MAIS ANTIGAS: se a ordenação esquecer `highlight`, o
    # LIMIT 20 devolve as 20 mais novas e a asserção cai. Sem o índice, o plano
    # paga temp B-tree. As duas falhas são distinguishable.
    for i in range(AhSeedListings):
        sql.ExecuteBindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, status, highlight, created_at) VALUES (?, ?, ?, ?, ?, 'open', ?, ?);", [
            lbSeed[i % lbSeed.size()], lbAcct, 1234 + i, 1, 1000 + i, 1 if i < 20 else 0, 1750000000 + i])

    var lbStart: int = Time.get_ticks_msec()
    var lbRows: Array[Dictionary] = sql.GetLeaderboard(50)
    var lbMs: int = Time.get_ticks_msec() - lbStart
    var lbPlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN SELECT c.char_id, s.level, c.power_score, a.username FROM character AS c INNER JOIN account AS a ON c.account_id = a.account_id INNER JOIN stat AS s ON s.char_id = c.char_id ORDER BY c.power_score DESC, c.char_id ASC LIMIT 50;"):
        lbPlan += String(row.get("detail", "")) + " | "
    print("Leaderboard: %d ms, %d de %d personagens, plan: %s" % [lbMs, lbRows.size(), LbSeedChars, lbPlan])
    if lbMs > BudgetLeaderboardMs:
        print("FAIL: leaderboard exceeded budget")
        failures += 1
    var lbOrdered: bool = true
    for i in range(1, lbRows.size()):
        if int(lbRows[i - 1].get("power_score", 0)) < int(lbRows[i].get("power_score", 0)):
            lbOrdered = false
    if lbRows.size() != 50:
        print("FAIL: leaderboard devolveu %d linhas com %d personagens semeados" % [lbRows.size(), LbSeedChars])
        failures += 1
    if not lbOrdered:
        print("FAIL: leaderboard fora de ordem em power_score DESC")
        failures += 1
    if lbPlan.find("TEMP B-TREE") >= 0:
        print("FAIL: leaderboard ordenando em temp B-tree — idx_character_leaderboard não está sendo usado")
        failures += 1
    if lbPlan.find("idx_character_leaderboard") < 0:
        print("FAIL: leaderboard sem o índice de cobertura da migration 047")
        failures += 1

    var ahStart: int = Time.get_ticks_msec()
    var ahRows: Array[Dictionary] = economy.BrowseListings(20)
    var ahMs: int = Time.get_ticks_msec() - ahStart
    var ahPlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE status = 'open' ORDER BY highlight DESC, id DESC LIMIT 20;"):
        ahPlan += String(row.get("detail", "")) + " | "
    print("Auction browse: %d ms, %d de %d listing(s), plan: %s" % [ahMs, ahRows.size(), AhSeedListings, ahPlan])
    if ahMs > BudgetAuctionBrowseMs:
        print("FAIL: browse do leilão excedeu o orçamento")
        failures += 1
    # São exatamente 20 realces e o LIMIT é 20: "todas as linhas voltadas têm
    # highlight=1" só é verdade se a ordenação usou o destaque, e os id
    # estritamente decrescentes provam o segundo termo do ORDER BY.
    var ahOk: bool = ahRows.size() == 20
    for i in range(ahRows.size()):
        if int(ahRows[i].get("highlight", 0)) != 1:
            ahOk = false
        if i > 0 and int(ahRows[i - 1].get("id", 0)) <= int(ahRows[i].get("id", 0)):
            ahOk = false
    if not ahOk:
        print("FAIL: browse não devolveu os 20 realces em id DESC")
        failures += 1
    if ahPlan.find("TEMP B-TREE") >= 0:
        print("FAIL: browse do leilão em temp B-tree — idx_auction_browse não está sendo usado")
        failures += 1
    if ahPlan.find("idx_auction_browse") < 0:
        print("FAIL: browse sem o índice de cobertura da migration 047")
        failures += 1
    # A cascata da migration 066 apaga anúncio por `seller_char` a cada personagem
    # removido. Sem índice nessa coluna, o expurgo de UM personagem varre a tabela de
    # anúncios inteira — e o `auction_listing` é justamente a tabela que este gate
    # enche (200 linhas). O plano é lido com as linhas da fixture na mesa, porque
    # plano sobre tabela vazia não prova nada.
    var purgePlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN DELETE FROM auction_listing WHERE seller_char = %d;" % int(lbSeed[0])):
        purgePlan += String(row.get("detail", ""))
    print("Plano do purge de anúncio por seller_char: %s" % purgePlan)
    if purgePlan.find("idx_auction_listing_seller_char") < 0:
        print("FAIL: purge de anúncio por seller_char não usa o índice da migration 066 — cada personagem apagado varre os %d anúncios" % AhSeedListings)
        failures += 1

    for seedChar in lbSeed:
        sql.RemoveCharacter(int(seedChar))
    sql.RemoveAccount(lbAcct)

    # Benchmark: save/logout — round trips de UpdateProgress com o progresso de
    # um jogador razoavelmente avançado (30 quests, 80 mobs, 40 skills). Antes:
    # três statements por entrada, cada um no próprio BEGIN/END.
    sql.AddAccount("bench_progress", "testpass", "bench_progress@test.local")
    var progAcct: int = sql.GetAccountID("bench_progress")
    sql.AddCharacter(progAcct, "BenchProgress", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var progChar: int = sql.GetCharacterID(progAcct, "BenchProgress")
    var progress = load("res://sources/actor/Progress.gd").new(null, false)
    for q in range(30):
        progress.quests["quest%d".hash() + q] = q % 3
    for b in range(80):
        progress.bestiary["mob%d".hash() + b] = b * 7
    for s in range(40):
        progress.skills["skill%d".hash() + s] = 1
    sql.ResetCounters()
    var progStart: int = Time.get_ticks_msec()
    var progOk: bool = sql.UpdateProgress(progChar, progress)
    var progMs: int = Time.get_ticks_msec() - progStart
    var progQueries: int = sql.QueryCount()
    var progTx: int = sql.TransactionCount()
    var readBack: int = sql.GetQuests(progChar).size() + sql.GetBestiaries(progChar).size() + sql.GetSkills(progChar).size()
    sql.RemoveCharacter(progChar)
    sql.RemoveAccount(progAcct)
    print("Progress save: %d ms, %d queries, %d tx para 150 entradas (budget: <= %d queries, <= %d tx)" % [progMs, progQueries, progTx, BudgetLogoutQueries, BudgetLogoutTransactions])
    if not progOk:
        print("FAIL: UpdateProgress devolveu false")
        failures += 1
    if readBack != 150:
        print("FAIL: upsert perdeu linha (%d de 150 lidas de volta)" % readBack)
        failures += 1
    if progQueries > BudgetLogoutQueries:
        print("FAIL: save com round trips demais")
        failures += 1
    if progTx > BudgetLogoutTransactions:
        print("FAIL: save não está numa transação única")
        failures += 1

    # ROADMAP_COMERCIAL S3: load probe real — 800 settles sequenciais no mesmo
    # char (rewind de 1h no anchor por iteração), P50/P99 medidos em µs e julgados
    # contra o baseline gravado no topo do arquivo (não contra um número redondo).
    # Substitui o print-only anterior; mede latência de transação real.
    sql.AddAccount("bench_load", "testpass", "bench_load@test.local")
    var loadAcct: int = sql.GetAccountID("bench_load")
    sql.AddCharacter(loadAcct, "BenchLoad", commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
    var loadChar: int = sql.GetCharacterID(loadAcct, "BenchLoad")
    sql.SetCharacterFarmZone(loadChar, 1)
    var memBefore: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
    var resBefore: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
    # µs, não ms: `get_ticks_msec()` tem resolução de 1 ms e o settle fechava em
    # "1 ms" — a distribuição inteira era arredondamento. O que o gate decide é o
    # p99, e um p99 lido com resolução de 1 ms é um número inventado.
    var probeUs: Array[int] = []
    var probeErrors: int = 0
    var probeQueries: int = 0
    var slowCount: int = 0
    var slowIdx: String = ""
    # Índice + duração de cada hitch, na ordem em que caíram: sem o índice o
    # `sort()` abaixo apaga a única coisa que distingue um hitch periódico (o
    # checkpoint do WAL) de um hitch que aparece onde não deveria.
    var hitchIdx: Array[int] = []
    var hitchUs: Array[int] = []
    # Toda amostra acima do teto do p99, com o índice: é o que permite medir a
    # distância de cada settle lento ao dreno mais próximo em vez de argumentar
    # que "deve ser o checkpoint". O teto é o piso porque é em volta exatamente
    # dessa linha que a régua abaixo fica vermelha ou verde.
    var tailIdx: Array[int] = []
    var tailUs: Array[int] = []
    # Amostra do `-wal` a cada settle: tamanho e o salt-1 do cabeçalho. O salt
    # muda quando um checkpoint drena o arquivo inteiro e o SQLite recomeça a
    # gravação no frame 1 — é essa drenagem que custa os hitches de ~400 ms, e
    # aqui ela é OBSERVADA, não predita. Predizer pelo crescimento do arquivo não
    # dá, e foi medido: depois do primeiro checkpoint o `-wal` encalha no topo
    # (16.698.392 bytes no settle 250, 16.706.632 no 750, delta positivo quase
    # nulo no meio) porque os frames são reescritos no mesmo lugar, e a taxa de
    # bytes por settle ainda cresce com o inventário (77 KB no settle 25, 140 KB
    # no 125). O TRUNCATE antes do probe não é decoração: é o que prova que o
    # arquivo desce a zero e que a série tem um estado inicial lido. Se ele não
    # truncar (leitor ativo), a atribuição fica impossível — e a régua lê isso
    # como vermelho, nunca como "nenhum stall".
    var walSizes: Array[int] = []
    var walSalts: Array[int] = []
    # #125: em quais settles o DONO do checkpoint disparou. Um dreno observado do `-wal` só
    # é absolvido se o dono estiver numa de suas duas bordas, e quem calcula isso é
    # `_drenosSemDono` (tests/benchmarks.gd:@_drenosSemDono). Sem esta série a régua não
    # distingue o fsync que o servidor paga no tick ocioso daquele que ainda cai dentro do
    # COMMIT de um jogador — que é o defeito, não o dreno em si.
    var ownerFired: Array[bool] = []
    var pageSize: int = _pragmaOne(sql, "PRAGMA page_size;")
    var autoCkPages: int = _pragmaOne(sql, "PRAGMA wal_autocheckpoint;")
    var dbPath: String = String(load("res://sources/sql/SQLCommons.gd").call("GetDBPath"))
    var walPath: String = dbPath + "-wal"
    # #178 — o DISPOSITIVO em que os µs abaixo serão julgados, medido antes do probe e
    # antes do TRUNCATE de propósito: as páginas do probe entram no `-wal` e o
    # `wal_checkpoint(TRUNCATE)` logo abaixo as devolve a zero, então a série de saltos
    # continua tendo o mesmo estado inicial lido que `_motivoAtribuicaoImpossivel` cobra.
    # O probe usa o funil inteiro (`Transaction()` + `ExecNoLock`) com os pragmas já
    # ligados — é a classe de escrita do settle, não um fsync genérico de outro processo.
    var ioCommitUs: int = _measureDeviceCommitUs(sql, pageSize)
    var deviceCeilingUs: int = BaselineSettleP99Us * RegressionHeadroom
    var motivoDispositivo: String = _motivoDispositivoImpossivel(ioCommitUs, deviceCeilingUs)
    # Nada aqui afrouxa teto, baseline ou folga: `mensuravel == false` custa UMA falha
    # vermelha com motivo, número e comando, e as réguas de taxa (hitches, drenos,
    # ownership, censo de trabalho) e os invariantes do #125 correm do mesmo jeito. Um run
    # que não pode medir não é um run verde — é um run que confessa o que falta.
    var mensuravel: bool = motivoDispositivo == ""
    var ckRows: Array = sql.Query("PRAGMA wal_checkpoint(TRUNCATE);")
    var ckBusy: int = -1
    if not ckRows.is_empty():
        ckBusy = int((ckRows[0] as Dictionary).values()[0])
    var walStart: int = _walProbe(walPath)[0]
    var controlBefore: int = _measureControl()
    sql.ResetCounters()
    for i in range(LoadProbeIters):
        sql.UpdateSettleAnchor(loadChar, int(Time.get_unix_time_from_system()) - 3600, 1.0)
        var probeStart: int = Time.get_ticks_usec()
        var probeResult: Dictionary = settleScript.SettlePending(loadChar)
        probeUs.append(Time.get_ticks_usec() - probeStart)
        var walProbe: Array[int] = _walProbe(walPath)
        walSizes.append(walProbe[0])
        walSalts.append(walProbe[1])
        # O dono do checkpoint é chamado DEPOIS da amostra e FORA do bracket cronometrado,
        # que é o espelho exato da produção, onde quem o dispara é `_process` (sources/world/World.gd:@_process)
        # no tick de 1 s, não dentro de um settle. Media-lo dentro da amostra seria cobrar
        # do jogador um custo que ele não paga; omiti-lo inteiro seria o tick revertido em
        # 2026-09-26, que nunca dispara sob `-s`. O dreno aparece no salt do settle
        # SEGUINTE, e é por isso que o dono é procurado nas duas bordas.
        ownerFired.append(bool(sql.MaybeCheckpoint().get("fired", false)))
        if probeUs[-1] > TailFloorUs:
            tailIdx.append(i)
            tailUs.append(probeUs[-1])
        if probeUs[-1] > 50000:
            slowCount += 1
            hitchIdx.append(i)
            hitchUs.append(probeUs[-1])
            if slowCount <= 24:
                slowIdx += "%d:%dms " % [i, probeUs[-1] / 1000]
        if probeResult.is_empty():
            probeErrors += 1
    # Contador lido ainda dentro do probe: os `delete_rows` abaixo não passam pelo
    # chokepoint contado, mas ler aqui deixa o número inequívoco.
    probeQueries = sql.QueryCount()
    # Leituras do dono, ainda dentro do probe: `runs` é a prova de que o dono disparou
    # (um dono que não dispara é o tick de `_process` revertido com outro nome) e
    # `busy` é a fração de disparos que o SQLite devolveu sem drenar nada.
    var ckStats: Dictionary = sql.CheckpointStats()
    # O denominador de tudo abaixo é TRABALHO, e trabalho tem que ser contado: sem
    # isto, um settle que deixasse de mintar lotes pareceria 40× mais rápido.
    var probeLots: int = _scalar(sql, "SELECT count(*) FROM item_instance WHERE char_id = ? AND reason = ?", [loadChar, "settle"])
    var controlAfter: int = _measureControl()
    var probeTx: int = sql.TransactionCount()
    var memAfter: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
    var resAfter: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
    sql.RemoveCharacter(loadChar)
    sql.RemoveAccount(loadAcct)
    probeUs.sort()
    var p50Us: int = probeUs[LoadProbeIters / 2]
    var p99Us: int = probeUs[LoadProbeIters * 99 / 100]
    var maxUs: int = probeUs[LoadProbeIters - 1]
    # O fator de ruído é o MELHOR controle medido ao redor do probe: crédito só é
    # dado pela máquina mais quieta adjacente ao probe, nunca pela mais ocupada —
    # senão "estava tudo rodando" vira licença para ignorar a régua.
    var loadFactor: float = maxf(1.0, float(mini(controlBefore, controlAfter)) / float(BaselineControlUs))
    var p50AdjUs: int = int(float(p50Us) / loadFactor)
    var p99AdjUs: int = int(float(p99Us) / loadFactor)
    print("Load probe: %d settles — p50 %d µs, p99 %d µs, max %d µs (budget p99: %d µs), erros: %d, %d queries, %d tx" % [LoadProbeIters, p50Us, p99Us, maxUs, BaselineSettleP99Us * RegressionHeadroom, probeErrors, probeQueries, probeTx])
    print("Régua de regressão do settle: baseline gravado p50 %d µs / p99 %d µs (run mais quieto de 13, máquina ociosa, load 0,31, 12 núcleos, 2026-09-27) × folga %d× → tetos p50 %d µs / p99 %d µs" % [BaselineSettleP50Us, BaselineSettleP99Us, RegressionHeadroom, BaselineSettleP50Us * RegressionHeadroom, BaselineSettleP99Us * RegressionHeadroom])
    print("   neste run: controle %d/%d µs vs %d µs gravados → máquina a %.2f×; normalizado p50 %d µs (%.2f× o baseline), p99 %d µs (%.2f× o baseline)" % [controlBefore, controlAfter, BaselineControlUs, loadFactor, p50AdjUs, float(p50AdjUs) / float(BaselineSettleP50Us), p99AdjUs, float(p99AdjUs) / float(BaselineSettleP99Us)])
    print("   dispositivo do settle: um commit de %d páginas custa %d µs (piso de %d tentativas) e a régua cobra o settle inteiro em %d µs — %s em %s" % [IoProbePages, ioCommitUs, IoProbeReps, deviceCeilingUs, "mensurável" if mensuravel else "NÃO MENSURÁVEL", OS.get_user_data_dir()])
    print("   rode `godot --headless --path . -s tests/perf_baseline.gd` para recalcular o baseline e auditar o fator")
    print("Load probe hitches: %d de %d settles acima de 50 ms (budget: %d)" % [slowCount, LoadProbeIters, BudgetSlowIterPct * LoadProbeIters / 100])
    if slowIdx != "":
        print("Load probe iterações lentas: %s%s" % [slowIdx, "(truncado em 24) " if slowCount > 24 else ""])
    print("Load probe memória: %d objetos (+%d), %d recursos (+%d) no probe (budget: +%d / +%d)" % [memAfter, memAfter - memBefore, resAfter, resAfter - resBefore, BudgetObjectGrowth, BudgetResourceGrowth])
    # Auto-auditoria da régua: a cercinha de baixo é o que impede o próximo
    # leitor de afrouxar o fator de volta a uma cerca de sanidade, ou de apertá-lo
    # a ponto de o gate virar flake.
    if RegressionHeadroom > 4:
        print("FAIL: folga de %d× não é mais régua — um regresso de 5× no settle passaria verde" % RegressionHeadroom)
        failures += 1
    if RegressionHeadroom < 2:
        print("FAIL: folga de %d× é menor que o ruído medido do próprio run ocioso (1,24×) — o gate flakeia" % RegressionHeadroom)
        failures += 1
    if BaselineSettleP99Us * RegressionHeadroom <= WorstP99NormalizadoSobCargaUs:
        print("FAIL: teto de %d µs não fica acima do pior p99 normalizado já medido sob carga (%d µs)" % [BaselineSettleP99Us * RegressionHeadroom, WorstP99NormalizadoSobCargaUs])
        failures += 1
    if probeErrors > 0:
        print("FAIL: settle devolveu vazio em %d iterações" % probeErrors)
        failures += 1
    if not mensuravel:
        # A falha é UMA e é a confissão, não o número do settle: sem um dispositivo que
        # caiba no teto, "p50 estourou" é medida do arquivo, não do código. As réguas de
        # taxa continuam correndo, e o run continua VERMELHO até alguém mudar o root do
        # sandbox — que é exatamente o que `scripts/test.sh` já faz quando `/dev/shm` é
        # utilizável, e o root do sandbox é o `home` que `_reap_interrupted_sandbox` limpa
        # (scripts/test.sh:@_reap_interrupted_sandbox).
        print("FAIL: settle NÃO MENSURÁVEL — %s. Nada foi afrouxado: tetos, baseline e folga seguem os mesmos, e este é o preço de medir onde não dá para medir." % motivoDispositivo)
        failures += 1
    elif p50AdjUs > BaselineSettleP50Us * RegressionHeadroom:
        print("FAIL: p50 do settle estourou a régua de regressão (%d µs normalizado vs teto %d µs; baseline %d µs × %d)" % [p50AdjUs, BaselineSettleP50Us * RegressionHeadroom, BaselineSettleP50Us, RegressionHeadroom])
        failures += 1
    # O p99 sozinho absolve um checkpoint que só aparece uma vez a cada cem
    # iterações: com 800 amostras, 1% de hitch cai exatamente no furo do p99. Esta
    # é a conta que enxerga o checkpoint, e ela é lida na taxa, não no pico.
    if slowCount * 100 > BudgetSlowIterPct * LoadProbeIters:
        print("FAIL: %d de %d settles acima de 50 ms, orçamento é %d por cento" % [slowCount, LoadProbeIters, BudgetSlowIterPct])
        failures += 1
    if memAfter - memBefore > BudgetObjectGrowth:
        print("FAIL: vazamento de objeto no loop de load")
        failures += 1
    if resAfter - resBefore > BudgetResourceGrowth:
        print("FAIL: vazamento de recurso no loop de load")
        failures += 1
    # O p99 passa a ser julgado na cauda que o código controla. Um hitch que
    # COINCIDE com um dreno observado do WAL é o fsync do arquivo — a prosa deste
    # gate já o declarava caro por natureza ("não existe código de jogo que o
    # barateie") e cobrava a TAXA, não o pico; ele continua cobrado pela régua de
    # taxa acima e pela contagem de drenos, que é nova. Um hitch que não coincide
    # com dreno nenhum não é checkpoint e vai inteiro no p99, contra o mesmo teto
    # de sempre: BaselineSettleP99Us × RegressionHeadroom, intocado.
    failures += _atribuirStalls(probeUs, hitchIdx, hitchUs, tailIdx, tailUs, walSizes, walSalts, ownerFired, ckStats, pageSize, autoCkPages, ckBusy, walStart, probeQueries, probeLots, loadFactor, mensuravel)
    failures += _controlesAtribuicao()
    failures += _controlesOwnership()
    failures += _controlesDispositivo()

    # Censo na chegada, depois de todo teardown: o que sobrou é o que ESTA corrida
    # mintou e não levou embora.
    var orphansAfter: Array[int] = _orphanCounts(sql)
    var unreadable: String = ""
    for i in range(orphansAfter.size()):
        if int(orphansAfter[i]) < 0 or int(orphansBefore[i]) < 0:
            unreadable += "%s " % OrphanPurgable[i][0]
    if unreadable != "":
        print("FAIL: censo de órfãos ilegível em (%s) — ausência de leitura NÃO é 'zero órfãos'" % unreadable.strip_edges())
        failures += 1
    else:
        failures += _vereditoCenso(sql, orphansBefore, orphansAfter, OrphanAxisChar, "char_id", true)
        failures += _vereditoCenso(sql, orphansBefore, orphansAfter, OrphanAxisListing, "listing_id", false)
    failures += _controleCensoOrfaos(sql, orphansAfter)

    print("== Benchmarks: %d failures ==" % failures)
    quit(failures)

# ---------------------------------------------------------------------------
# #125 — atribuição do stall.
#
# O gate dizia "10 de 800 settles acima de 50 ms" e parava aí: o p99 acusava
# regressão sem nomear o culpado, e a única pista de que era o checkpoint do WAL
# era um comentário em SQL.gd. Aqui a culpa é OBSERVADA no próprio arquivo: o
# cabeçalho do `-wal` troca de salt quando um checkpoint drena tudo e o SQLite
# recomeça a gravação no frame 1, e é essa escrita (o threshold abaixo, ~16 MB)
# que custa os hitches. Hitch no dreno é o fsync do arquivo, cobrado pela régua
# de taxa; hitch fora de qualquer dreno é inexplicado e continua valendo o p99
# inteiro, contra o mesmo teto de sempre.
func _walProbe(walPath: String) -> Array[int]:
    # [bytes, salt-1]; salt -1 quando não há arquivo ou o header não veio inteiro.
    var fa: FileAccess = FileAccess.open(walPath, FileAccess.READ)
    if fa == null:
        return [-1, -1]
    var size: int = int(fa.get_length())
    var raw: PackedByteArray = fa.get_buffer(32)
    fa.close()
    if raw.size() < 32:
        return [size, -1]
    # Big-endian, como todo o SQLite: salt-1 mora em 16..19.
    return [size, (int(raw[16]) << 24) | (int(raw[17]) << 16) | (int(raw[18]) << 8) | int(raw[19])]

func _pragmaOne(sql: Node, pragma: String) -> int:
    var rows: Array = sql.Query(pragma)
    if rows.is_empty():
        return -1
    var first: Dictionary = rows[0]
    if first.is_empty():
        return -1
    return int(first.values()[0])

func _scalar(sql: Node, query: String, params: Array) -> int:
    var rows: Array = sql.QueryBindings(query, params)
    if rows.is_empty():
        return -1
    return int((rows[0] as Dictionary).values()[0])

# Linha órfã = pendurada num dono que não existe mais, em qualquer um dos dois eixos
# que a lista conhece: `character` (a cascade da 066) e `auction_listing` (o retrato
# do escrow, 067). A régua cobra o DELTA da
# corrida, não o absoluto: um banco que sobreviveu de antes da migration 066 já
# tinha lixo dentro quando este run começou, e isso não é culpa dele. O que não pode
# é este run mintar órfão — foi assim que UMA corrida deixou 33.922 `item_instance`
# com zero personagens vivos, e o probe do settle passou a medir latência por cima
# de um inventário morto: mais lento a cada passada sem que uma linha do caminho
# tivesse mudado. Leitura inválida (-1) derruba o censo — ausência de leitura NÃO é
# "zero órfãos", mesma doutrina da atribuição de stall abaixo.
func _orphanQuery(check: Array) -> String:
    return "SELECT count(*) FROM %s WHERE NOT EXISTS (SELECT 1 FROM %s p WHERE p.%s = %s.%s);" % [check[0], check[2], check[3], check[0], check[1]]

func _orphanCounts(sql: Node) -> Array[int]:
    var out: Array[int] = []
    for check in OrphanPurgable:
        out.append(_scalar(sql, _orphanQuery(check), []))
    return out

# Um veredito por eixo, não um número somado: órfão de anúncio e órfão de
# personagem são cascatas diferentes (a 066 e a 067) e um crescendo escondido
# dentro do total do outro é exatamente como um defeito novo passa verde.
func _orphanAxisSum(counts: Array[int], axis: String) -> int:
    var total: int = 0
    for i in range(counts.size()):
        if String(OrphanPurgable[i][2]) == axis:
            total += int(counts[i])
    return total

# Só o que cresceu entra na frase: "item_instance +33922" é diagnóstico, a lista
# inteira repetida é ruído.
func _orphanGrowth(before: Array[int], after: Array[int], axis: String) -> String:
    var out: String = ""
    for i in range(before.size()):
        if String(OrphanPurgable[i][2]) != axis:
            continue
        var d: int = int(after[i]) - int(before[i])
        if d > 0:
            out += "%s +%d " % [OrphanPurgable[i][0], d]
    return out.strip_edges()

func _vereditoCenso(sql: Node, orphansBefore: Array[int], orphansAfter: Array[int], axis: String, label: String, withDurable: bool) -> int:
    var grew: int = _orphanAxisSum(orphansAfter, axis) - _orphanAxisSum(orphansBefore, axis)
    var line: String = "Censo de órfãos do %s: %d na largada, %d na chegada (delta %d, orçamento 0)." % [label, _orphanAxisSum(orphansBefore, axis), _orphanAxisSum(orphansAfter, axis), grew]
    if withDurable:
        line += " Registro que sobrevive por design e não é cobrado: %s" % _durableOrphanText(sql)
    print(line)
    if grew <= 0:
        return 0
    print("FAIL: a corrida deixou %d linhas órfãs em %s (%s) — alguém apagou o dono sem levar os filhos, e o próximo run mede latência por cima de lixo" % [grew, label, _orphanGrowth(orphansBefore, orphansAfter, axis)])
    return 1

func _durableOrphanText(sql: Node) -> String:
    var out: String = ""
    for check in OrphanDurable:
        out += "%s=%d " % [check[0], _scalar(sql, _orphanQuery(check), [])]
    return out.strip_edges()

# Controle plantado do censo, nos dois sentidos. Só o sentido "órfão é visto" não
# prova nada: no fim do run não existe personagem vivo nenhum, e aí QUALQUER coluna
# que a query casar devolve "tudo é órfão" e o controle passa com o censo quebrado —
# foi exatamente o que aconteceu na primeira versão desta função, trocando
# `seller_char` por `id` e vendo o veredito continuar verde. Então o controle planta
# as duas metades do quadrado: uma linha pendurada num personagem VIVO (não pode ser
# contada) e uma pendurada num char_id que nunca existiu (tem que ser contada), nas
# duas formas de coluna que existiam na lista naquele momento (`char_id` e o apelido
# `seller_char`), e confere que arrancar as duas devolve o número anterior.
#
# Desde a 067 o quadrado tem uma terceira perna, e ela é a única que exercita a
# NESTEADA: o lote de escrow pendura num anúncio, o anúncio pendura num personagem,
# e nada no caminho de `SQL.RemoveCharacter` menciona `ah_escrow_lot` — quem tem que
# levar o lote é o DELETE do anúncio disparado dentro do trigger do personagem. É
# aqui que se mede se um DELETE emitido dentro do corpo de um trigger dispara o
# trigger da outra tabela, em vez de assumir.
func _controleCensoOrfaos(sql: Node, base: Array[int]) -> int:
    var failures: int = 0
    var idxItem: int = -1
    var idxAh: int = -1
    var idxLot: int = -1
    for i in range(OrphanPurgable.size()):
        if String(OrphanPurgable[i][0]) == "item":
            idxItem = i
        if String(OrphanPurgable[i][0]) == "auction_listing":
            idxAh = i
        if String(OrphanPurgable[i][0]) == "ah_escrow_lot":
            idxLot = i
    if idxItem < 0 or idxAh < 0 or idxLot < 0:
        print("FAIL: controle do censo — `item`, `auction_listing` ou `ah_escrow_lot` sumiu de OrphanPurgable (%s); o censo que roda não é o censo que este controle assina" % str(OrphanPurgable))
        return failures + 1
    if int(base[idxItem]) < 0 or int(base[idxAh]) < 0 or int(base[idxLot]) < 0:
        print("FAIL: controle do censo — ilegível na chegada (%d / %d / %d), nada a plantar contra" % [base[idxItem], base[idxAh], base[idxLot]])
        return failures + 1
    var vivo: int = 900010
    var morto: int = 900011
    # `listing_id` não é AUTOINCREMENT em `ah_escrow_lot` e anúncios reais deste run
    # têm rowid baixo; 900099 é o id que declara "anúncio que nunca existiu".
    var semDono: int = 900099
    sql.ExecuteBindings("DELETE FROM item WHERE char_id = ? OR char_id = ?;", [vivo, morto])
    sql.ExecuteBindings("DELETE FROM auction_listing WHERE seller_char = ? OR seller_char = ?;", [vivo, morto])
    sql.ExecuteBindings("DELETE FROM ah_escrow_lot WHERE uid = ? OR uid = ? OR uid = ?;", [909101, 909102, 909103])
    sql.ExecuteBindings("DELETE FROM ah_escrow_lot WHERE listing_id = ?;", [semDono])
    sql.ExecuteBindings("DELETE FROM character WHERE char_id = ? OR char_id = ?;", [vivo, morto])
    var antes: Array[int] = _orphanCounts(sql)
    var entrouChar: bool = sql.ExecuteBindings("INSERT INTO character (char_id, account_id, nickname, created_timestamp) VALUES (?, ?, 'CensoVivo', 1);", [vivo, vivo])
    var entrouItem: bool = sql.ExecuteBindings("INSERT INTO item (item_id, char_id, count, storage, customfield) VALUES (909001, ?, 1, 1, 'censo');", [vivo])
    var entrouAh: bool = sql.ExecuteBindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, created_at) VALUES (?, ?, 100001, 1, 1, 1);", [vivo, vivo])
    var ahVivo: int = sql.LastInsertRowIDRaw()
    var entrouLot: bool = sql.ExecuteBindings("INSERT INTO ah_escrow_lot (listing_id, uid, item_id, count, bound, customfield, parent_uid, creator_account_id, reason, lot_created_at) VALUES (?, ?, 100001, 1, 0, '', 0, ?, 'censo', 1);", [ahVivo, 909101, vivo])
    var vivoLido: Array[int] = _orphanCounts(sql)
    sql.ExecuteBindings("DELETE FROM character WHERE char_id = ?;", [vivo])
    var mortoLido: Array[int] = _orphanCounts(sql)
    var entrouMuertoItem: bool = sql.ExecuteBindings("INSERT INTO item (item_id, char_id, count, storage, customfield) VALUES (909002, ?, 1, 1, 'censo');", [morto])
    var entrouMuertoAh: bool = sql.ExecuteBindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, created_at) VALUES (?, ?, 100001, 1, 1, 1);", [morto, morto])
    var ahMorto: int = sql.LastInsertRowIDRaw()
    var entrouLotMorto: bool = sql.ExecuteBindings("INSERT INTO ah_escrow_lot (listing_id, uid, item_id, count, bound, customfield, parent_uid, creator_account_id, reason, lot_created_at) VALUES (?, ?, 100001, 1, 0, '', 0, ?, 'censo', 1);", [ahMorto, 909102, morto])
    var entrouLotOrfao: bool = sql.ExecuteBindings("INSERT INTO ah_escrow_lot (listing_id, uid, item_id, count, bound, customfield, parent_uid, creator_account_id, reason, lot_created_at) VALUES (?, ?, 100001, 1, 0, '', 0, ?, 'censo', 1);", [semDono, 909103, morto])
    var plantado: Array[int] = _orphanCounts(sql)
    # O plano é lido com as linhas plantadas na mesa, pela mesma razão da 066: plano
    # sobre tabela vazia não prova nada.
    var lotPlan: String = ""
    for row in sql.Query("EXPLAIN QUERY PLAN DELETE FROM ah_escrow_lot WHERE listing_id = %d;" % semDono):
        lotPlan += String(row.get("detail", ""))
    print("Plano do purge de escrow por listing_id: %s" % lotPlan)
    if lotPlan.find("idx_ah_escrow_lot_listing") < 0:
        print("FAIL: purge de escrow por listing_id não usa `idx_ah_escrow_lot_listing` (063) — cada anúncio apagado varre os lotes de todos os outros, e o trigger desta cascade paga o mesmo SCAN em cada um")
        failures += 1
    sql.ExecuteBindings("DELETE FROM item WHERE char_id = ?;", [morto])
    sql.ExecuteBindings("DELETE FROM auction_listing WHERE seller_char = ?;", [morto])
    sql.ExecuteBindings("DELETE FROM ah_escrow_lot WHERE listing_id = ?;", [semDono])
    var depois: Array[int] = _orphanCounts(sql)
    if not entrouChar or not entrouItem or not entrouAh or not entrouLot or not entrouMuertoItem or not entrouMuertoAh or not entrouLotMorto or not entrouLotOrfao:
        print("FAIL: controle do censo — o INSERT plantado não entrou (char=%s item=%s ah=%s lote=%s morto=%s/%s/%s/%s); controle que não planta não prova nada" % [str(entrouChar), str(entrouItem), str(entrouAh), str(entrouLot), str(entrouMuertoItem), str(entrouMuertoAh), str(entrouLotMorto), str(entrouLotOrfao)])
        failures += 1
    if int(vivoLido[idxItem]) != int(antes[idxItem]) or int(vivoLido[idxAh]) != int(antes[idxAh]) or int(vivoLido[idxLot]) != int(antes[idxLot]):
        print("FAIL: controle do censo — linha pendurada num personagem VIVO foi contada como órfã (item %d→%d, auction_listing %d→%d, ah_escrow_lot %d→%d); a query casa uma coluna que não é o vínculo, e os anúncios do run entrariam no próximo veredito" % [antes[idxItem], vivoLido[idxItem], antes[idxAh], vivoLido[idxAh], antes[idxLot], vivoLido[idxLot]])
        failures += 1
    if int(mortoLido[idxItem]) != int(antes[idxItem]) or int(mortoLido[idxAh]) != int(antes[idxAh]) or int(mortoLido[idxLot]) != int(antes[idxLot]):
        print("FAIL: controle do censo — apagar o personagem não levou os filhos (sobraram item=%d, auction_listing=%d, ah_escrow_lot=%d depois do DELETE, antes era %d/%d/%d); item e anúncio fecham na cascade da migration 066, o lote fecha na 067 DISPARADA DENTRO dela — se só o lote sobrou, é o DELETE do anúncio dentro do trigger que não disparou o trigger do anúncio" % [mortoLido[idxItem], mortoLido[idxAh], mortoLido[idxLot], antes[idxItem], antes[idxAh], antes[idxLot]])
        failures += 1
    if int(plantado[idxItem]) != int(mortoLido[idxItem]) + 1 or int(plantado[idxAh]) != int(mortoLido[idxAh]) + 1 or int(plantado[idxLot]) != int(mortoLido[idxLot]) + 1:
        print("FAIL: controle do censo — linha plantada num dono que nunca existiu não foi contada (item %d→%d, auction_listing %d→%d, ah_escrow_lot %d→%d); um censo que lê 0 do nada absolveria os 34.409 de novo" % [mortoLido[idxItem], plantado[idxItem], mortoLido[idxAh], plantado[idxAh], mortoLido[idxLot], plantado[idxLot]])
        failures += 1
    if int(depois[idxItem]) != int(antes[idxItem]) or int(depois[idxAh]) != int(antes[idxAh]) or int(depois[idxLot]) != int(antes[idxLot]):
        print("FAIL: controle do censo — o órfão arrancado não saiu da contagem (item %d→%d, auction_listing %d→%d, ah_escrow_lot %d→%d); a régua está contando outra coisa, e um lote que virou órfão junto com o anúncio apagado é o achado #168 na mesa" % [antes[idxItem], depois[idxItem], antes[idxAh], depois[idxAh], antes[idxLot], depois[idxLot]])
        failures += 1
    return failures

# Settles em que o WAL reiniciou = um checkpoint drenou o arquivo inteiro. Uma
# leitura inválida (-1) NUNCA conta como dreno: ausência de leitura não absolve.
func _drenagens(walSalts: Array[int]) -> Array[int]:
    var out: Array[int] = []
    for i in range(1, walSalts.size()):
        if walSalts[i] >= 0 and walSalts[i - 1] >= 0 and walSalts[i] != walSalts[i - 1]:
            out.append(i)
    return out

# Dreno SEM dono é autocheckpoint pago dentro do COMMIT de um settle — o defeito que
# o #125 fecha. Um `-wal` que reinicia na borda de um disparo do dono é o fsync que o
# servidor paga fora do caminho quente: `ownerFired[d-1]` porque a amostra do settle
# é lida ANTES do dono no mesmo índice (o dreno aparece um settle depois), e
# `ownerFired[d]` como folga de uma amostra. Fora das duas bordas não há quem tenha
# chamado o checkpoint, e aí o pagante é o jogador.
func _drenosSemDono(drainIdx: Array[int], ownerFired: Array[bool]) -> Array[int]:
    var out: Array[int] = []
    for d in drainIdx:
        var dono: bool = (d > 0 and d <= ownerFired.size() and ownerFired[d - 1]) or (d < ownerFired.size() and ownerFired[d])
        if not dono:
            out.append(d)
    return out

# Hitch → dreno, com a folga de amostragem de `_tol` settles (a série é lida logo
# depois do COMMIT). Pura de propósito: é a única parte da régua que o controle
# plantado consegue exercitar.
func _atribuirHitches(hitchIdx: Array[int], drainIdx: Array[int], tol: int) -> Dictionary:
    var attributed: int = 0
    var inexplicado: Array[int] = []
    for h in hitchIdx:
        var achou: bool = false
        for d in drainIdx:
            if absi(h - d) <= tol:
                achou = true
                break
        if achou:
            attributed += 1
        else:
            inexplicado.append(h)
    return {"attributed": attributed, "inexplicado": inexplicado}

# Por que a atribuição pode falhar, em uma frase — separado da impressão para que
# o controle plantado exercite cada ramo sem sujar o veredito do run.
func _motivoAtribuicaoImpossivel(pageSize: int, autoCkPages: int, ckBusy: int, walStart: int) -> String:
    if pageSize <= 0 or autoCkPages <= 0:
        return "pragmas ilegíveis (page_size %d, wal_autocheckpoint %d)" % [pageSize, autoCkPages]
    var threshold: int = pageSize * autoCkPages
    if ckBusy != 0:
        return "o wal_checkpoint(TRUNCATE) devolveu busy=%d com %d de %d bytes no `-wal'" % [ckBusy, walStart, threshold]
    if walStart >= threshold / 4:
        return "o `-wal` não voltou a zero (%d bytes de %d): o probe começou com o arquivo quase cheio e a série de drenos não tem estado inicial" % [walStart, threshold]
    return ""

# Assinada: negativo = o settle veio ANTES do dreno, positivo = depois. Sem dreno
# na série devolve -999999, número que nenhum delta real confunde (a série tem
# 800 settles) e que o controle abaixo casa.
func _distanciaDreno(idx: int, drainIdx: Array[int]) -> int:
    var melhor: int = -999999
    for d in drainIdx:
        if melhor == -999999 or absi(idx - d) < absi(melhor):
            melhor = idx - d
    return melhor

func _atribuirStalls(probeUs: Array[int], hitchIdx: Array[int], hitchUs: Array[int], tailIdx: Array[int], tailUs: Array[int], walSizes: Array[int], walSalts: Array[int], ownerFired: Array[bool], ckStats: Dictionary, pageSize: int, autoCkPages: int, ckBusy: int, walStart: int, probeQueries: int, probeLots: int, loadFactor: float, mensuravel: bool) -> int:
    var failures: int = 0
    var threshold: int = pageSize * autoCkPages
    print("Atribuição de stall: page_size %d × wal_autocheckpoint %d páginas = dreno a cada %d bytes; `-wal` devolvido a %d bytes antes do probe" % [pageSize, autoCkPages, threshold, walStart])
    var motivo: String = _motivoAtribuicaoImpossivel(pageSize, autoCkPages, ckBusy, walStart)
    if motivo != "":
        print("FAIL: atribuição impossível — %s. Ausência de leitura NÃO é 'sem stall'." % motivo)
        return failures + 1
    var lidos: int = 0
    for s in walSalts:
        if s >= 0:
            lidos += 1
    if lidos != walSalts.size() or walSalts.size() != probeUs.size():
        print("FAIL: atribuição impossível — cabeçalho do `-wal` lido em %d de %d settles; sem a série inteira nenhum hitch pode ser absolvido" % [lidos, walSalts.size()])
        return failures + 1

    var drainIdx: Array[int] = _drenagens(walSalts)
    # Série de ownership na MESMA largura da série do `-wal`: sem as duas, "todo dreno
    # tem dono" é conta sobre o que não foi observado — a mesma régua de completude de
    # cima, agora aplicada ao disparo do dono.
    if ownerFired.size() != walSalts.size():
        print("FAIL: atribuição impossível — dono registrado em %d settles contra %d amostras do `-wal`; com as séries de larguras diferentes nenhum dreno pode ser absolvido" % [ownerFired.size(), walSalts.size()])
        return failures + 1
    # Invariante 1 — o dono tem que EXISTIR no laço medido. Um dono que nunca disparou
    # é o tick de `_process` revertido com outro nome: sob `-s` não há frame nenhum, e
    # foi assim que o gate ficou verde sobre a ausência do remédio (a passada de
    # 2026-09-26 de deploy/LAUNCH_HANDOFF.md registra o fato).
    var ckRuns: int = int(ckStats.get("runs", -1))
    var semDono: Array[int] = _drenosSemDono(drainIdx, ownerFired)
    print("   dono do checkpoint: %d disparos (cadência %d tx, busy %d, %d frames drenados, pico %d µs) — %d drenos observados, %d sem dono" % [ckRuns, int(ckStats.get("every", -1)), int(ckStats.get("busy", -1)), int(ckStats.get("frames", -1)), int(ckStats.get("maxMicroseconds", -1)), drainIdx.size(), semDono.size()])
    if ckRuns <= 0:
        print("FAIL: o dono do checkpoint não disparou em %d settles — ausência de disparo NÃO é 'nenhum stall no commit': quem paga o fsync voltou a ser o commit que cruza as %d páginas" % [LoadProbeIters, autoCkPages])
        failures += 1
    # Invariante 2 — dreno fora das duas bordas do disparo É autocheckpoint dentro do
    # COMMIT de um jogador. É este, e não o p99, que o #125 promete fechar.
    if not semDono.is_empty():
        print("FAIL: %d drenos do WAL sem dono (%s) — cada um caiu dentro do COMMIT de um settle, que é o defeito que o #125 fecha; nenhum disparo de `MaybeCheckpoint()` precede a borda dele" % [semDono.size(), str(semDono.slice(0, 8))])
        failures += 1
    var grade: Dictionary = _atribuirHitches(hitchIdx, drainIdx, DrainTolSettles)
    var attributed: int = int(grade.get("attributed", 0))
    var inexplicado: Array = grade.get("inexplicado", [])
    print("   drenos: %d (%s), pico do `-wal` %d bytes; hitches %d de %d (maior %d ms), atribuídos %d, inexplicados %d" % [drainIdx.size(), str(drainIdx), walSizes.max(), hitchIdx.size(), LoadProbeIters, (hitchUs.max() / 1000) if not hitchUs.is_empty() else 0, attributed, inexplicado.size()])
    if not inexplicado.is_empty():
        print("FAIL: %d hitches sem dreno do WAL (%s) — nada no arquivo explica a cauda, então ela vale como regressão" % [inexplicado.size(), str(inexplicado.slice(0, 8))])
        failures += 1

    # Medição antes de argumento: cada settle acima do teto é impresso com a
    # distância AO DRENO MAIS PRÓXIMO. Sem isto a frase "a cauda é o aftermath do
    # checkpoint" é opinião; com isto é um número que o próprio run desmente, e foi
    # exatamente por não ter este número que a régua de hitches quase absolveu o
    # que não podia.
    var dist: Array[String] = []
    for k in tailIdx.size():
        var delta: int = _distanciaDreno(tailIdx[k], drainIdx)
        dist.append("%d:%s%d@%d" % [tailIdx[k], "antes" if delta < 0 else "depois", absi(delta), tailUs[k]])
    print("   cauda acima do teto de %d µs: %d amostras — %s" % [TailFloorUs, tailIdx.size(), str(dist)])
    # Medido nos três runs deste disco (2026-09-30, 800 settles, máquina a 1,00×):
    # 46, 51 e 65 amostras acima do teto de 2076 µs, com 9, 10 e 10 drenos, e
    # absolvido tudo o que fica a ±5 settles de um dreno sobram 2, 4 e 10 — contra 8, 7
    # e 7 que o p99 dos sobreviventes toleraria, teto esse deduzido de 11 settles por
    # dreno com as janelas disjuntas nas três séries (o run de cima imprime o dele). Nos dois primeiros o contrafactual fica
    # verde; no terceiro não. Então "a cauda é o aftermath do checkpoint" é verdade para
    # o grosso e mentira para o resto: as dez que sobraram estão a 6–26 settles ANTES
    # (ou 6 depois) do dreno, em dois grupos de 3 e 4 settles seguidos e quatro
    # isoladas, entre 2078 µs e 2401 µs — 2 a 325 µs acima do teto — e não têm causa
    # confirmada. A régua abaixo NÃO absolve a janela: remove só os hitches que ELA
    # atribui (tol = `DrainTolSettles`) e julga o resto, porque alargar a tolerância
    # para ficar verde é a régua escolhendo o veredito. O contrafactual impresso logo
    # abaixo existe para a próxima rodada não adivinhar se o que falta é #125 ou outra
    # coisa: se ele continuasse vermelho com a janela toda absolvida, o #125 não fecha.

    # A cauda julgada pelo p99 remove SÓ o que foi atribuído, e só quando nada
    # sobrou: com um inexplicado na mesa a série é conferida inteira, porque
    # absolver por tabela é exatamente o afrouxamento disfarçado de escopo.
    var drop: int = attributed if inexplicado.is_empty() else 0
    var tail: Array[int] = probeUs.slice(0, maxi(LoadProbeIters - drop, 1))
    var tailP99Us: int = tail[tail.size() * 99 / 100]
    var tailP99Adj: int = int(float(tailP99Us) / loadFactor)
    print("   cauda sem checkpoint: p99 %d µs (%d µs normalizado, %.2f× o baseline) vs teto %d µs — %d de %d amostras removidas" % [tailP99Us, tailP99Adj, float(tailP99Adj) / float(BaselineSettleP99Us), BaselineSettleP99Us * RegressionHeadroom, drop, LoadProbeIters])
    if not mensuravel:
        # Só esta linha e a do p50 deixam de morder, e o run continua VERMELHO pela
        # confissão do dispositivo, contada uma vez no chamador. O que continua julgado é
        # o que NÃO depende do disco: drenos sem dono, hitches acima de 50 ms contra
        # orçamento de taxa, completude das séries e o censo de trabalho do settle.
        print("   cauda NÃO julgada em µs absolutos: um teto que não cabe no arquivo não pode ficar verde nem vermelho por esta linha — a causa seria o dispositivo, não o código")
    elif tailP99Adj > BaselineSettleP99Us * RegressionHeadroom:
        print("FAIL: p99 do settle estourou a régua de regressão (%d µs normalizado vs teto %d µs; baseline %d µs × %d)" % [tailP99Adj, BaselineSettleP99Us * RegressionHeadroom, BaselineSettleP99Us, RegressionHeadroom])
        failures += 1

    # O contrafactual, medido em vez de argumentado: se TUDO que fica na janela do
    # dreno fosse absolvido, o vermelho sobreviveria? Este número NÃO entra no
    # veredito — é impresso para a próxima rodada não adivinhar onde o custo mora, e
    # a janela é a que a série de distâncias acima mostrou (5 settles), não a que
    # compra verde. Retirar o ramo de diagnóstico não muda um `failures` daqui.
    # A pergunta é «quantos acima do teto SOBRAVAM se a janela fosse absolvida», e ela
    # só pode ser respondida com índice de settle na mão: `probeUs` chega aqui JÁ
    # ORDENADA pelo `sort()` do p99, então posição nesse array é ordem de duração, não
    # ordem do tempo. Foi assim que a primeira versão desta linha imprimiu um p99 de
    # 412.717 µs — o hitch de 551 ms lido como se fosse o settle 683. Os índices vêm
    # de `tailIdx`/`tailUs`, coletados no loop do probe antes de qualquer ordenação.
    var cobertos: int = 0
    for i in range(LoadProbeIters):
        if absi(_distanciaDreno(i, drainIdx)) <= DrainAftermathSettles:
            cobertos += 1
    var foraJanela: int = 0
    var piorFora: int = 0
    for k in tailIdx.size():
        if absi(_distanciaDreno(tailIdx[k], drainIdx)) > DrainAftermathSettles:
            foraJanela += 1
            piorFora = maxi(piorFora, tailUs[k])
    var restantes: int = LoadProbeIters - cobertos
    # O p99 é o elemento de índice `restantes*99/100` na série ordenada: com
    # `restantes - restantes*99/100` amostras acima do teto ele ainda cai acima dele.
    var sobrevvem: int = restantes - restantes * 99 / 100
    print("   DIAGNÓSTICO (não é veredito): absolvido tudo a %d settles de um dreno (%d amostras cobertas), sobram %d de %d acima do teto de %d µs, pior %d µs — o vermelho sobreviveria a partir de %d" % [DrainAftermathSettles, cobertos, foraJanela, restantes, TailFloorUs, piorFora, sobrevvem])

    # O denominador é trabalho CONTADO, com piso: sem piso, um settle que parasse
    # de mintar lotes — ou que escrevesse tudo por fora do contador, já que as
    # chamadas diretas de `libgdsqlite` não passam por `Query/TryExec/ExecuteBindings`
    # — leria zero e fecharia verde.
    var lotsPerSettle: float = float(probeLots) / float(LoadProbeIters)
    var queriesPerSettle: float = float(probeQueries) / float(LoadProbeIters)
    print("   censo do settle: %.1f lotes e %.2f queries contadas por settle (orçamento %d–%d lotes, %d–%d queries)" % [lotsPerSettle, queriesPerSettle, MinLotsPerSettle, MaxLotsPerSettle, MinSettleCountedQueries, MaxSettleCountedQueries])
    if probeLots < 0 or lotsPerSettle < float(MinLotsPerSettle):
        print("FAIL: o probe mintou %.1f lotes por settle, abaixo do piso de %d — o settle não está mais fazendo o trabalho que esta régua julga" % [lotsPerSettle, MinLotsPerSettle])
        failures += 1
    if lotsPerSettle > float(MaxLotsPerSettle):
        print("FAIL: %.1f lotes por settle acima do teto de %d — a torneira de drop mudou de taxa sem ninguém recontar a régua" % [lotsPerSettle, MaxLotsPerSettle])
        failures += 1
    if queriesPerSettle > float(MaxSettleCountedQueries):
        print("FAIL: %.2f queries contadas por settle acima do teto de %d — round trips voltaram ao caminho quente" % [queriesPerSettle, MaxSettleCountedQueries])
        failures += 1
    if queriesPerSettle < float(MinSettleCountedQueries):
        print("FAIL: %.2f queries contadas por settle abaixo do piso de %d — ou o settle perdeu trabalho, ou passou a escrever por fora do contador" % [queriesPerSettle, MinSettleCountedQueries])
        failures += 1
    return failures

# Controles plantados: cada ramo da régua nova tem que morder, e isso é medido a
# cada run. Uma atribuição que absolve o plantado fora do dreno é enfeite — e o
# gate passa a ficar vermelho contra si mesma, que é como se pega um falso-verde.
func _controlesAtribuicao() -> int:
    var failures: int = 0
    var hOn: Array[int] = [5, 10, 15]
    var dOn: Array[int] = [5, 10, 15]
    var a1: Dictionary = _atribuirHitches(hOn, dOn, 1)
    if int(a1.get("attributed", 0)) != 3 or not (a1.get("inexplicado", []) as Array).is_empty():
        print("FAIL: controle do dreno — condenou hitch que caiu exatamente no dreno (%s)" % str(a1))
        failures += 1
    var hOff: Array[int] = [5, 10]
    var dOff: Array[int] = [5]
    var a2: Dictionary = _atribuirHitches(hOff, dOff, 1)
    if int(a2.get("attributed", 0)) != 1 or (a2.get("inexplicado", []) as Array) != [10]:
        print("FAIL: controle do dreno — hitch plantado sem dreno foi absolvido (%s)" % str(a2))
        failures += 1
    var hFar: Array[int] = [5]
    var dFar: Array[int] = [0]
    var a3: Dictionary = _atribuirHitches(hFar, dFar, 1)
    if (a3.get("inexplicado", []) as Array) != [5]:
        print("FAIL: controle do dreno — a folga de amostragem comeu um hitch plantado a 5 settles do dreno (%s)" % str(a3))
        failures += 1
    var sal: Array[int] = [7, 7, 8, 8, 9]
    if _drenagens(sal) != [2, 4]:
        print("FAIL: controle do dreno — série %s deveria dar drenos em [2, 4] e deu %s" % [str(sal), str(_drenagens(sal))])
        failures += 1
    var salRuim: Array[int] = [7, -1, 8]
    if not _drenagens(salRuim).is_empty():
        print("FAIL: controle do dreno — leitura inválida contada como dreno (%s)" % str(_drenagens(salRuim)))
        failures += 1
    if _distanciaDreno(12, [5, 10, 15]) != 2 or _distanciaDreno(13, [5, 10, 15]) != -2:
        print("FAIL: controle de distância — 12 está 2 settles DEPOIS do dreno 10 e 13 está 2 ANTES do dreno 15; a régua leu %d e %d" % [_distanciaDreno(12, [5, 10, 15]), _distanciaDreno(13, [5, 10, 15])])
        failures += 1
    if _distanciaDreno(10, [5, 10, 15]) != 0:
        print("FAIL: controle de distância — settle exatamente no dreno não leu zero (%d)" % _distanciaDreno(10, [5, 10, 15]))
        failures += 1
    if _distanciaDreno(10, []) != -999999:
        print("FAIL: controle de distância — série sem dreno devolveu %d em vez do sentinel; ausência lida como proximidade absolveria a cauda" % _distanciaDreno(10, []))
        failures += 1
    for plantado in [[-1, 4000, 0, 0], [4096, 4000, 1, 0], [4096, 4000, 0, 5000000]]:
        if _motivoAtribuicaoImpossivel(int(plantado[0]), int(plantado[1]), int(plantado[2]), int(plantado[3])) == "":
            print("FAIL: controle de impossibilidade — ramo %s absolvido como legível" % str(plantado))
            failures += 1
    if _motivoAtribuicaoImpossivel(4096, 4000, 0, 0) != "":
        print("FAIL: controle de impossibilidade — estado bom (4096/4000/busy 0/wal 0) declarado ilegível")
        failures += 1
    return failures

# Controles do #125: cada ramo de `_drenosSemDono` (tests/benchmarks.gd:@_drenosSemDono)
# tem que morder em série plantada. Sem isso a asserção "todo dreno tem dono" é enfeite —
# e o verde de amanhã seria o mesmo falso-verde do tick que só disparava em frame.
func _controlesOwnership() -> int:
    var failures: int = 0
    var drenos: Array[int] = [2]
    var nenhuma: Array[bool] = [false, false, false, false]
    # Borda de baixo: a amostra do `-wal` é lida ANTES do dono no mesmo índice, então o
    # dreno do disparo de `d-1` aparece em `d`. Condenar isto é acusar o remédio certo.
    var bordaBaixa: Array[bool] = [false, true, false, false]
    if not _drenosSemDono(drenos, bordaBaixa).is_empty():
        print("FAIL: controle de ownership — dreno na borda do disparo do dono foi condenado (%s)" % str(_drenosSemDono(drenos, bordaBaixa)))
        failures += 1
    # Borda de cima: o dono que dispara no mesmo settle em que o arquivo reinicia.
    var mesmoIndice: Array[bool] = [false, false, true, false]
    if not _drenosSemDono(drenos, mesmoIndice).is_empty():
        print("FAIL: controle de ownership — dreno no índice do próprio disparo foi condenado (%s)" % str(_drenosSemDono(drenos, mesmoIndice)))
        failures += 1
    # O ramo que tem que morder: dreno sem nenhum disparo por perto É o autocheckpoint
    # dentro do COMMIT. Se este plantado for absolvido, a régua não existe.
    var condenados: Array[int] = _drenosSemDono(drenos, nenhuma)
    if condenados != [2]:
        print("FAIL: controle de ownership — dreno plantado sem dono nenhum foi absolvido (%s); um autocheckpoint pago dentro do COMMIT de um jogador passaria verde nesta régua" % str(condenados))
        failures += 1
    # A borda não é elástica: dois settles de distância do disparo não é o dono drenando,
    # é o commit que cruzou as páginas.
    var longe: Array[int] = [3]
    var disparo0: Array[bool] = [true, false, false, false]
    if _drenosSemDono(longe, disparo0) != [3]:
        print("FAIL: controle de ownership — dreno a dois settles do disparo foi absolvido (%s); borda elástica é a régua escolhendo o veredito" % str(_drenosSemDono(longe, disparo0)))
        failures += 1
    # Índice 0 não pode ler `-1`: sem borda de baixo disponível, o dreno é condenado.
    var primeiro: Array[int] = [0]
    if _drenosSemDono(primeiro, nenhuma) != [0]:
        print("FAIL: controle de ownership — dreno no primeiro settle absolvido por leitura de índice negativo (%s)" % str(_drenosSemDono(primeiro, nenhuma)))
        failures += 1
    var vazio: Array[int] = []
    if not _drenosSemDono(vazio, bordaBaixa).is_empty():
        print("FAIL: controle de ownership — série sem dreno devolveu condenação; ausência de dreno lida como dreno sem dono acusaria o remédio")
        failures += 1
    return failures

# Controles do #178: a régua que decide "este run pode julgar µs?" é a única linha do gate
# que pode ser afrouxada sem tocar em teto, baseline ou folga, então cada ramo dela morder
# é obrigatório. Os três números plantados são medidos, não inventados: 6494 µs é o commit
# de 34 páginas no HDD de 5400 rpm onde este repo mora, 430 µs é o mesmo commit em tmpfs,
# e a borda é o teto real da régua do settle.
func _controlesDispositivo() -> int:
    var failures: int = 0
    var teto: int = BaselineSettleP99Us * RegressionHeadroom
    # Ausência de leitura JAMAIS é "dispositivo rápido": é o ramo que, se absolvido,
    # transformaria um probe quebrado em verde.
    if _motivoDispositivoImpossivel(-1, teto) == "":
        print("FAIL: controle de dispositivo — probe que não mediu nada foi absolvido como mensurável; um `page_size` ilegível passaria verde sem medir disco nenhum")
        failures += 1
    if _measureDeviceCommitUs(null, 0) >= 0:
        print("FAIL: controle de dispositivo — page_size 0 devolveu leitura em vez de ausência; o probe contaria páginas que não existem")
        failures += 1
    if _motivoDispositivoImpossivel(6494, teto) == "":
        print("FAIL: controle de dispositivo — um commit de 6494 µs sob teto de %d µs foi absolvido (é o HDD medido em 2026-10-03)" % teto)
        failures += 1
    if _motivoDispositivoImpossivel(430, teto) != "":
        print("FAIL: controle de dispositivo — o piso medido em tmpfs (430 µs) foi declarado impossível; a régua estaria confessando um dispositivo que cabe no teto")
        failures += 1
    # A borda não é elástica para nenhum dos dois lados: no teto cabe, 1 µs acima não.
    if _motivoDispositivoImpossivel(teto, teto) != "":
        print("FAIL: controle de dispositivo — o valor exatamente no teto de %d µs foi declarado impossível" % teto)
        failures += 1
    if _motivoDispositivoImpossivel(teto + 1, teto) == "":
        print("FAIL: controle de dispositivo — 1 µs acima do teto de %d µs foi absolvido" % teto)
        failures += 1
    # O probe tem que medir alguma coisa: com zero páginas ele não escreve, e com uma
    # repetição não existe "piso do dispositivo", só o pico da disputa.
    if IoProbePages < 1 or IoProbeReps < 2:
        print("FAIL: controle de dispositivo — probe configurado com %d páginas e %d repetições; sem escrita não há commit e sem duas leituras não há piso" % [IoProbePages, IoProbeReps])
        failures += 1
    return failures

# A série é lida logo depois do COMMIT, então o dreno é visto no mesmo settle que
# o pagou; a folga de um settle cobre a única forma de perder a leitura (outro
# writer ter reiniciado o arquivo antes da nossa amostra). O controle acima
# recusa folga elástica: um hitch a 5 settles do dreno é inexplicado.
const DrainTolSettles: int = 1
# Janela do POST-dreno, só para o ramo de diagnóstico: os settles que pagam a
# reabertura do `-wal` depois de um truncate. Cinco é o que a série de distâncias
# deste disco mede como cauda coloada ao dreno — 44, 47 e 55 das 46, 51 e 65
# amostras acima do teto dos três runs registrados caem dentro de ±5 settles — não
# o que compra verde: o veredito continua julgando a série com `DrainTolSettles`,
# e o contrafactual abaixo mostra que a janela inteira absolvida ainda deixa
# vermelho no terceiro run.
const DrainAftermathSettles: int = 5
# Censo do settle: 39–44 lotes por settle de 1 h medidos no probe (o #95 mudou a
# taxa de um lote por hora para ~40 identidades). O teto dá folga para a janela
# do probe; o piso de 1 é o que impede a régua de ser satisfeita por um settle
# que parou de trabalhar.
const MinLotsPerSettle: int = 1
const MaxLotsPerSettle: int = 200
# Statements CONTADAS por settle: 12,00 medidos depois do lote do #109 (antes
# dele eram ~4 statements por identidade, e o contador nem via isso). O teto é o
# mesmo do save (`BudgetLogoutQueries`); o piso é o trabalho mínimo que ainda tem
# que aparecer na frente do contador.
const MinSettleCountedQueries: int = 8
const MaxSettleCountedQueries: int = 16
# Piso da captura de cauda: o teto do p99. Acima dele cada settle é guardado com
# índice, porque a pergunta que sobra depois de atribuir os hitches não é "quantos
# passam do teto" — é "o dreno explica os que passam?". Um settle que paga o
# fsync do checkpoint no settle SEGUINTE ao dreno é o mesmo custo, e fingir que é
# regressão de código seria cobrar do autor errado.
const TailFloorUs: int = BaselineSettleP99Us * RegressionHeadroom
