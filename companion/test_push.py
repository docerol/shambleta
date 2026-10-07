#!/usr/bin/env python3
"""Testes da FILA de web push (SOM-W5 + M-4). Abre exatamente onde o C-9
registrou a saída ("a próxima onda que crescer nesta fileira abre test_push.py,
espelhando o padrão de test_metrics.py"): a mecânica de fila — sweep, ganchos de
temporada (C-9) e de campanha (M-4), dedupe pelo corpo, sender plugável — mora
aqui; o hardening do webhook fica em `test_webhook.py`. Sem pytest: python3
companion/test_push.py. Sai !=0 se falhar.
"""
import json
import os
import sqlite3
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

FAILS = []
CHECKS = 0


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def raises(exc, fn, label):
    try:
        fn()
    except exc:
        ok(True, label)
        return
    except Exception as e:  # noqa: BLE001
        ok(False, label + " (excetou %s, não %s)" % (type(e).__name__, exc.__name__))
        return
    ok(False, label + " (não excetou)")


# --- SOM-W5: web push (migration 052 + sender plugável) — mecânica de fila
# testada na função; CLI e2e no harness Godot (tests/web_delivery_test.gd).
import glob as _glob

_w5_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "data", "conf", "migrations")
_w5_migs = sorted(_glob.glob(os.path.join(_w5_dir, "*_web_push.sql")))
ok(len(_w5_migs) == 1, "W5 exatamente uma migration *_web_push.sql")
_tmpw5 = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_tmpw5.close()
_wc = sqlite3.connect(_tmpw5.name)
_wc.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT,"
            " last_timestamp INTEGER DEFAULT 0)")
_noww = int(time.time())
_wc.execute("INSERT INTO account VALUES (1,'offline',?)", (_noww - 200000,))
_wc.execute("INSERT INTO account VALUES (2,'recente',?)", (_noww,))
_wc.execute("INSERT INTO account VALUES (3,'nunca-online',0)")
_wc.executescript(open(_w5_migs[0]).read())
_wc.commit()
_w5 = server.Store(_tmpw5.name)
ok(_w5.push_register(_wc, 1, "https://p/1", "K1", "A1", now=_noww) is True,
   "W5 push_register grava subscription de conta existente")
ok(_w5.push_register(_wc, 99, "https://p/99", "K", "A", now=_noww) is False,
   "W5 push_register recusa conta inexistente (sem linha fantasma)")
ok(_wc.execute("SELECT COUNT(*) FROM push_subscription").fetchone()[0] == 1,
   "W5 uma linha de subscription por conta")
_w5.push_register(_wc, 1, "https://p/1b", "K2", "A2", now=_noww + 1)
ok(_wc.execute("SELECT endpoint FROM push_subscription WHERE account_id = 1")
   .fetchone()[0] == "https://p/1b", "W5 re-register é upsert (troca de navegador)")
ok(_wc.execute("SELECT COUNT(*) FROM push_subscription").fetchone()[0] == 1,
   "W5 upsert não duplica a linha")
_w5.push_register(_wc, 2, "https://p/2", "K2", "A2", now=_noww)
_q = _w5.push_sweep(_wc, offline_seconds=86400, quiet_seconds=72 * 3600, now=_noww)
ok(_q == 1, "W5 sweep enfileira só a offline assinante (recente e sem-sub fora)")
ok(_wc.execute("SELECT account_id, status, title FROM push_outbox").fetchall()
   == [(1, "pending", server.Store.PUSH_DEFAULT_TITLE)],
   "W5 fila entra pending com título default (nunca enviado inline)")
ok(_w5.push_sweep(_wc, offline_seconds=86400, quiet_seconds=72 * 3600,
                  now=_noww + 60) == 0,
   "W5 janela de silêncio não repete notificação da mesma conta")
os.environ.pop("SHAMBLETA_PUSH_SENDER", None)
_s1 = _w5.push_drain(_wc, now=_noww)
ok(_s1["failed"] == 1 and _s1["sent"] == 0,
   "W5 sender default NÃO finge entrega (failed, não sent)")
_err = _wc.execute("SELECT last_error FROM push_outbox ORDER BY id LIMIT 1") \
        .fetchone()[0]
ok(str(_err).startswith("vapid_sender"),
   "W5 fila confessa o motivo técnico: vapid_sender_unimplemented")
_w5.push_enqueue(_wc, 1, title="t", body="b", now=_noww + 1)
_s2 = _w5.push_drain(_wc, sender=server.stdout_webpush_send, now=_noww + 2)
ok(_s2["sent"] == 1, "W5 sender de teste (stdout) drena o pendente novo")
_w5.push_enqueue(_wc, 7, now=_noww + 3)  # conta sem subscription
_s3 = _w5.push_drain(_wc, sender=server.stdout_webpush_send, now=_noww + 4)
ok(_s3["failed"] == 1 and _s3["sent"] == 0,
   "W5 notificação sem subscription vira failed (fila não prende)")
# C-9 (2026-10-06): o segundo gancho do jogo — "temporada fechando". A tabela é
# criada na forma da migração 018 (o teste aferiza a primitiva, não o boot).
_wc.execute("CREATE TABLE season (season_id INTEGER PRIMARY KEY AUTOINCREMENT,"
            " starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL,"
            " rules_frozen TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'active')")
_wc.execute("INSERT INTO season (starts_at, ends_at, status) VALUES (?, ?, 'active')",
            (_noww - 3 * 86400, _noww + 6 * 3600))
_wc.commit()
ok(_w5.push_season_close(_wc, lead_seconds=3600, now=_noww) == 0,
   "C-9 janela que não alcança o fim (1h p/ temporada a 6h) não notifica")
_q2 = _w5.push_season_close(_wc, lead_seconds=24 * 3600, now=_noww)
ok(_q2 == 2, "C-9 fechamento na janela enfileira os dois assinantes")
ok(_w5.push_season_close(_wc, lead_seconds=24 * 3600, now=_noww + 30) == 0,
   "C-9 dedupe vive na fila: a MESMA temporada não avisa duas vezes (nem depois de restart)")
_r2 = _wc.execute("SELECT body FROM push_outbox WHERE body LIKE 'season:%'").fetchall()
ok(len(_r2) == 2 and str(_r2[0][0]).startswith("season:"),
   "C-9 corpo carrega a chave da temporada — o marcador de dedupe é dado, não memória")
_wc.execute("UPDATE season SET status = 'closed'")
ok(_w5.push_season_close(_wc, lead_seconds=24 * 3600, now=_noww + 60) == 0,
   "C-9 temporada fechada não anuncia nada novo")
ok(hasattr(server, "push_scheduler_tick") and hasattr(server, "_push_scheduler_loop"),
   "C-9 o heartbeat existe como função nomeada (o flag SHAMBLETA_PUSH_SCHED liga o laço)")
raises(NotImplementedError,
       lambda: server.vapid_webpush_send(
           {"account_id": 1, "endpoint": "https://x", "p256dh": "k", "auth": "a"},
           "t", "b"),
       "W5 vapid_webpush_send levanta NotImplementedError (ECDSA ausente da stdlib)")
ok(server.push_sender() is server.vapid_webpush_send,
   "W5 sem env, o sender ativo é o honesto (vapid)")
os.environ["SHAMBLETA_PUSH_SENDER"] = "nome-que-nao-existe"
ok(server.push_sender() is server.vapid_webpush_send,
   "W5 env desconhecido cai no honesto, nunca no stdout (default fechado)")
os.environ.pop("SHAMBLETA_PUSH_SENDER", None)
# M-4 (2026-10-07): o terceiro gancho — "campanha abrindo", lido do MESMO
# calendário LiveOps que o servidor consome. A fixture é um arquivo próprio
# (o caminho entra por parâmetro, como o override SHAMBLETA_LIVEOPS_FILE do
# boot); o calendário embarcado do repo não é fixture de teste — janela real
# que vence amanhã mudaria o veredito daqui.
_w6cal = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
_w6cal.write(json.dumps({"events": [
    {"kind": "double_xp", "key": "w6_alpha", "start_unix": _noww + 6 * 3600,
     "end_unix": _noww + 8 * 3600, "value": 2.0, "label": "W6 sprint"},
    {"kind": "chest_bonus", "key": "w6_alpha_x", "start_unix": _noww + 3 * 3600,
     "end_unix": _noww + 5 * 3600, "value": 1.5, "label": "W6 baús"},
    {"kind": "tournament", "key": "w6_copa", "start_unix": _noww + 2 * 3600,
     "end_unix": _noww + 9 * 3600, "value": 1.25, "label": "W6 copa"},
    {"kind": "double_xp", "key": "w6_passada", "start_unix": _noww - 36 * 3600,
     "end_unix": _noww - 34 * 3600, "value": 2.0, "label": "W6 já abriu"},
]}).encode("utf-8"))
_w6cal.close()
ok(_w5.push_campaign_open(_wc, lead_seconds=3600, now=_noww,
                          calendar_path=_w6cal.name) == 0,
   "M-4 janela de antecedência que não alcança a abertura (1h p/ campanha a 6h) não notifica")
_q3 = _w5.push_campaign_open(_wc, lead_seconds=24 * 3600, now=_noww,
                             calendar_path=_w6cal.name)
ok(_q3 == 4, "M-4 as duas janelas na antecedência enfileiram os dois assinantes (2 × 2)")
ok(_w5.push_campaign_open(_wc, lead_seconds=24 * 3600, now=_noww + 30,
                          calendar_path=_w6cal.name) == 0,
   "M-4 dedupe vive na fila: a MESMA campanha não avisa duas vezes (nem depois de restart)")
_r3 = [r[0] for r in _wc.execute("SELECT body FROM push_outbox WHERE body LIKE 'campaign:%'").fetchall()]
ok(sorted(set(_r3)) == ["campaign:w6_alpha", "campaign:w6_alpha_x"],
   "M-4 `w6_alpha` e `w6_alpha_x` são campanhas DISTINTAS — dedupe por igualdade, "
   "não por LIKE, porque `_` é curinga e engoliria a segunda")
ok(all(not b.startswith("campaign:w6_copa") for b in _r3)
   and _wc.execute("SELECT COUNT(*) FROM push_outbox WHERE body = 'campaign:w6_passada'")
       .fetchone()[0] == 0,
   "M-4 torneio e campanha já aberta ficam fora: gancho é de ABERTURA na janela")
ok(_w5.push_campaign_open(_wc, lead_seconds=24 * 3600, now=_noww,
                          calendar_path="/caminho/que/nao/existe.json") == 0,
   "M-4 calendário ilegível é silencioso (fail-closed, nunca push de chute)")
ok(hasattr(server, "push_campaign_open") and hasattr(server, "default_liveops_calendar_path"),
   "M-4 o gancho tem porta de módulo e resolvedor de caminho nomeados (o tick chama por eles)")
_w6row = _wc.execute("SELECT title FROM push_outbox WHERE body = 'campaign:w6_alpha'").fetchone()
ok(_w6row is not None and "6h" in str(_w6row[0]) and "W6 sprint" in str(_w6row[0]),
   "M-4 o letreiro do push carrega a janela (~6h) e o rótulo do calendário, não texto corrido")
os.unlink(_w6cal.name)
_wc.close()
os.unlink(_tmpw5.name)
# resumo
if FAILS:
    print("== PUSH: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== PUSH: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)
