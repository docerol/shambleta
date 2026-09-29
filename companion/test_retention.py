#!/usr/bin/env python3
"""Suíte da retenção D1 do companion — `server.retention_d1`.

O que isto mede, na ordem:

  1. UMA DEFINIÇÃO SÓ: o D1 do painel é o D1 do servidor. A leitura é
     `SELECT ... FROM cohort_retention`, a view que a migration 045 materializa e que
     `TelemetryService.IsD1Return` aplica no funil. A view é aplicada aqui A PARTIR DO
     ARQUIVO DE MIGRATION REAL, não colada: tabela ou view inventada nesta suíte
     aprovaria uma régua que não funciona no banco de verdade.
  2. OS CASOS EM QUE A RÉGUA ATUAL E A VELHA DIVERGEM, nos dois sentidos. A régua que
     existia aqui media "voltou 20 h depois de criar" (`last_timestamp >
     created_timestamp + 72000`) sobre uma janela móvel de criação. A da migration 045
     media "login no dia calendário UTC exato +1". São números diferentes para os
     mesmos dados, e este arquivo planta exatamente as duas contas que separam as
     leituras: quem criou às 23:58 e voltou às 00:01 (D1 verdadeiro, e a janela de 20 h
     diria não) e quem criou às 00:02 e voltou 20 h depois, no MESMO dia (D1 falso, e a
     janela diria sim). A sombra antiga é recalculada aqui e o veredito novo é comparado
     com ela — reimplantar a janela deixa de ser uma troca silenciosa de definição e
     vira gate vermelho.
  3. DENOMINADOR: conta que nunca logou não entra (o `JOIN` da view faz isso, declarado
     na migration). Se alguém trocar a fatia para a tabela `account`, o número muda e
     esta régua acusa.
  4. ISOLAMENTO DE COHORT: a fatia é um dia de criação; uma conta do cohort anterior
     que é D1 não pode entrar nela.
  5. JANELA FECHADA: a fatia lida é o cohort cujo dia D1 já terminou, e o veredito NÃO
     depende da hora do dia em que o painel é lido. A fatia de ontem estaria com a
     janela aberta: o mesmo banco daria outro número às 00:01 e às 23:59.
  6. FECHADO NA FALTA: banco sem a view (pré-045) devolve `None`, não zero.

O QUE ISTO NÃO PROVA, dito sem rodeio: a comparação com o funil do jogo
(`TelemetryService.IsD1Return`) é régua TEXTUAL sobre o fonte GDScript — dividir por
86400 e comparar com `+1` — porque esta suíte roda em python e não levanta o servidor.
O que ela pega é reescrita da definição num dos lados; o que ela não pega é um bug de
runtime do lado do jogo, que é medido em `tests/ops_fix_test.gd` (suíte B), onde o
predicado roda de fato contra a mesma view.

Rodar: `python3 companion/test_retention.py`. Sai !=0 se falhar. Sem pytest: o
companion é stdlib-only por contrato.
"""

import inspect
import os
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import server                                              # noqa: E402

DAY = 86400
CHECKS = 0
FAILS = []


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def report(marker):
    """Fecha com a linha que os gates lêem (§24-8: o número de falhas vem DO
    marcador)."""
    if FAILS:
        print("== %s: %d failures ==" % (marker, len(FAILS)))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("== %s: %d checks, 0 failures ==" % (marker, CHECKS))
    return 0


MIG045 = os.path.join(ROOT, "data", "conf", "migrations", "045_cohort_view.sql")

# As duas tabelas que a view lê, nas colunas que ela lê. Tipos iguais aos da
# migration 016 (telemetry_event) e ao uso real do servidor (account.created_timestamp
# é INTEGER; `metrics()` já o lê). A view em si vem do arquivo de migration.
DDL_ACCOUNT = ("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT,"
               " created_timestamp INTEGER, last_timestamp INTEGER,"
               " vip_until INTEGER DEFAULT 0)")
DDL_TELEMETRY = ("CREATE TABLE telemetry_event (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                 " created_at INTEGER, account_id INTEGER, char_id INTEGER,"
                 " kind TEXT, value INTEGER, meta TEXT DEFAULT '{}',"
                 " fingerprint TEXT DEFAULT '')")


def db(with_view=True, tables=(DDL_ACCOUNT, DDL_TELEMETRY)):
    tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    tmp.close()
    con = sqlite3.connect(tmp.name)
    for ddl in tables:
        con.execute(ddl)
    if with_view:
        con.executescript(open(MIG045).read())
    return con, tmp.name


def seed(con, account_id, created, logins):
    con.execute("INSERT INTO account (account_id, username, created_timestamp,"
                " last_timestamp) VALUES (?, ?, ?, ?);",
                (account_id, "a%d" % account_id, created, max(logins) if logins else 0))
    for at in logins:
        con.execute("INSERT INTO telemetry_event (created_at, account_id, char_id,"
                    " kind, value) VALUES (?, ?, 0, 'login', 0);", (at, account_id))


# ---------------------------------------------------------------------------
# Cenário: o relógio de trabalho é um índice de dia UTC fixo, porque a régua é
# aritmética de dia. T = hoje; a fatia fechada é o cohort T-2, medida em T-1.
# ---------------------------------------------------------------------------
T = int(time.time()) // DAY
NOW = T * DAY + 43210
COHORT = T - 2
D1DAY = COHORT + 1

# id, criado, logins, d1 esperado pela definição da casa, motivo
FIXTURES = [
    (1, (COHORT + 1) * DAY - 100, [D1DAY * DAY + 100], 1,
     "criada 23:58 do dia do cohort, voltou 00:01 do dia seguinte: D1 verdadeiro,"
     " e a janela de 20 h diria que não"),
    (2, COHORT * DAY + 100, [COHORT * DAY + 73000], 0,
     "criada 00:02, voltou 20 h 16 min depois no MESMO dia: D1 falso pela régua da"
     " casa, e a janela de 20 h diria que sim"),
    (3, COHORT * DAY + 3000, [D1DAY * DAY + 3600], 1,
     "caso limpo: criou num dia, logou no dia calendário seguinte"),
    (4, COHORT * DAY + 3000, [T * DAY + 3600], 0,
     "só voltou em D2: não é D1, por mais que o tempo decorrido passe de 20 h"),
    (5, (COHORT - 1) * DAY + 500, [(COHORT)*DAY + 500], 1,
     "D1 verdadeiro, mas de OUTRO cohort (criada em T-3) — não entra na fatia"),
    (6, COHORT * DAY + 900, [], None,
     "nunca logou: fora do denominador por construção do JOIN da view"),
    (7, 0, [COHORT * DAY + 1000, D1DAY * DAY + 1000], 1,
     "created_timestamp == 0: dia-zero é o login mais antigo, e voltar no dia"
     " seguinte conta"),
    (8, COHORT * DAY + 500, [COHORT * DAY + 600], 0,
     "logou só no próprio dia: entra no denominador, não é retida"),
]

con, path = db()
for aid, created, logins, _want, _why in FIXTURES:
    seed(con, aid, created, logins)

# (0) Auto-vigilância: os fixtures são relativos a `T`, calculado do relógio real.
# Se o run atravessar a meia-noite UTC, a comparação abaixo perde o sentido e tem
# de acusar isso em vez de aprovar um número por acaso.
ok(int(time.time()) // DAY == T, "o run não atravessou a meia-noite UTC (T vale ainda)")

# (1) A view é a régua: cada fixture confere com o que a migration 045 calcula.
by_id = {row[0]: row[1] for row in con.execute(
    "SELECT account_id, d1 FROM cohort_retention;").fetchall()}


def eff_cohort_day(created, logins):
    """Mesmo dia-zero da view: `created_timestamp`, ou o login mais antigo quando
    ele é zero. Sem isto o fixture 7 cairia fora da fatia por arithmetic errada."""
    if created > 0:
        return created // DAY
    if logins:
        return min(logins) // DAY
    return None


# A fatia esperada, calculada da DEFINIÇÃO (não do código do companion): só conta
# com login entra, porque é o `JOIN` da view que faz o denominador.
in_slice = [f for f in FIXTURES if f[2] and eff_cohort_day(f[1], f[2]) == COHORT]
want_cohort = len(in_slice)
want_retained = sum(f[3] for f in in_slice)
wrong = [(aid, want, by_id.get(aid)) for aid, _c, _l, want, _w in FIXTURES
         if (None if want is None else want) != by_id.get(aid, None)]
ok(not wrong, "a view da migration real dá o veredito esperado para cada fixture (%s)"
   % (wrong or "ok"))

# (2) O companion lê a view, e o número da fatia é o da régua da casa.
got = server.retention_d1(con, NOW)
ok(got is not None, "retention_d1 devolve número (view existe) — não None")
if got is None:
    con.close()
    os.unlink(path)
    sys.exit(report("RETENTION"))
ok(got["cohort"] == want_cohort,
   "denominador = %d: contas do cohort que têm algum login (excluir a de 'nunca"
   " logou' é o JOIN da view; um denominador da tabela account daria %d)"
   % (got["cohort"], want_cohort + 1))
ok(got["retained"] == want_retained,
   "numerador = %d: exatamente os fixtures cujo dia calendário +1 tem login"
   % got["retained"])
ok(got["cohort_day"] == COHORT and got["d1_day"] == D1DAY,
   "a fatia nomeia os dois dias UTC que produzem o número (cohort %d, medido em %d)"
   % (got["cohort_day"], got["d1_day"]))

# (3) A sombra: o que a régua velha de 20 h diria sobre as MESMAS contas. Esta é a
#     peça que acusa a definição divergente — não é retórica, é o número que a
#     fórmula antiga devolveria neste banco.
def old_rolling_20h(created, logins):
    return bool(logins) and max(logins) > (created or 0) + 72000


shadow = sum(1 for aid, c, l, _w, _why in in_slice if old_rolling_20h(c, l))
ok(shadow != got["retained"],
   "a régua da casa e a janela móvel de 20 h DIVERGEM nestes dados: %d vs %d — se"
   " alguém voltar a fórmula antiga o painel muda de significado"
   % (got["retained"], shadow))
f1 = [f for f in FIXTURES if f[0] == 1][0]
f2 = [f for f in FIXTURES if f[0] == 2][0]
ok(by_id[1] == 1 and not old_rolling_20h(f1[1], f1[2]),
   "sentido 1 da divergência: id 1 (criada 23:58, voltou 00:01) é D1 pela régua da"
   " casa e a janela de 20 h a negaria")
ok(by_id[2] == 0 and old_rolling_20h(f2[1], f2[2]),
   "sentido 2 da divergência: id 2 (criada 00:02, voltou 20 h depois no mesmo dia)"
   " não é D1 pela régua da casa e a janela de 20 h a conteria")
body = "".join(inspect.getsource(server.retention_d1).split('"""')[2:])
ok("72000" not in body and "last_timestamp" not in body,
   "corpo de retention_d1 não contém a fórmula de 20 h nem last_timestamp"
   " (a definição antiga não pode voltar dentro dela)")

# (4) Isolamento de cohort: id 5 é D1, mas de outro dia de criação.
whole = con.execute("SELECT COALESCE(SUM(d1), 0) FROM cohort_retention;").fetchone()[0]
ok(whole > got["retained"],
   "a fatia não é a visão de população inteira: o rollup diz %d, a fatia do cohort"
   " T-2 diz %d" % (whole, got["retained"]))
ok(by_id.get(5) == 1, "id 5 é D1 no rollup mas não pertence à fatia lida")

# (5) Janela fechada e independente da hora do painel.
ok(got["window_closed"] is True and D1DAY < T,
   "o dia medido já fechou antes de 'agora' (janela aberta mudaria de número com a hora)")
at_midnight = server.retention_d1(con, T * DAY + 60)
at_late = server.retention_d1(con, T * DAY + DAY - 60)
ok(at_midnight == at_late == got,
   "00:01 e 23:59 do mesmo dia UTC devolvem o MESMO veredito (nada de número que"
   " depende de quando o painel foi aberto)")

# (6) Fechado na falta: banco sem a view (pré-045) é indisponível, não zero.
con_noview, path_noview = db(with_view=False)
seed(con_noview, 1, COHORT * DAY, [D1DAY * DAY])
ok(server.retention_d1(con_noview, NOW) is None,
   "sem a view o D1 é None: indisponível não é zero")
con_noview.close()
os.unlink(path_noview)

con_empty, path_empty = db()
ok(server.retention_d1(con_empty, NOW) == {"cohort": 0, "retained": 0,
                                           "cohort_day": COHORT, "d1_day": D1DAY,
                                           "window_closed": True},
   "view presente e cohort vazio: zeros verdadeiros, com a faixa nomeada")
con_empty.close()
os.unlink(path_empty)

# (7) A definição não pode ser reescrita num lado só: a migration e o predicado do
#     jogo dividem o dia por 86400 e comparam com +1. Régua textual (ver docstring).
mig = open(MIG045).read()
tele = open(os.path.join(ROOT, "sources", "economy", "TelemetryService.gd")).read()
ok("day_index - cohort_day = 1" in mig and "/ 86400" in mig,
   "a migration define D1 como diferença de dia calendário (= 1) a partir de / 86400")
ok("var dayIndex : int = now / 86400" in tele and "dayIndex - 1" in tele,
   "o funil do jogo usa a mesma aritmética (IsD1Return compara com dayIndex - 1)")
ok("72000" not in tele, "e o funil do jogo nunca conheceu a janela de 20 h")

# (8) Ponta a ponta: o /metrics do painel serve exatamente este veredito, e a
#     resposta continua dizendo em que faixa ele foi medido.
con.close()
os.unlink(path)
con8, path8 = db(tables=(
    DDL_ACCOUNT, DDL_TELEMETRY,
    "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " idempotency_key TEXT UNIQUE, account_id INTEGER, kind TEXT, amount INTEGER,"
    " payload TEXT, status TEXT DEFAULT 'pending', created_at INTEGER,"
    " price_paid INTEGER DEFAULT 0, currency TEXT DEFAULT '')",
    "CREATE TABLE ledger_transaction (kind TEXT, amount INTEGER, reason TEXT,"
    " created_at INTEGER)",
    "CREATE TABLE wallet (gems INTEGER)",
    "CREATE TABLE reconcile_run (id INTEGER PRIMARY KEY, divergences INTEGER,"
    " created_at INTEGER)",
    "CREATE TABLE guild (guild_id INTEGER)",
    "CREATE TABLE auction_listing (status TEXT)",
    "CREATE TABLE season (season_id INTEGER, status TEXT)"))
for aid, created, logins, _want, _why in FIXTURES:
    seed(con8, aid, created, logins)
m = server.Store(path8).metrics(con8)
ok(m["retention_d1"] == got,
   "o /metrics serve o mesmo veredito da função (cohort %d, retidas %d)"
   % (got["cohort"], got["retained"]))
rollup = m["retention_cohort"]
ok(rollup["d1"] == whole and rollup["accounts"] == len(by_id),
   "o rollup da população inteira continua outro número, da MESMA view (d1 %d de %d"
   " contas) — duas janelas, uma definição" % (rollup["d1"], rollup["accounts"]))
con8.close()
os.unlink(path8)

sys.exit(report("RETENTION"))
