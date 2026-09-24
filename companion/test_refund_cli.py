#!/usr/bin/env python3
"""ROADMAP_COMERCIAL S1: e2e do CLI de refund-sweep (argparse → exit codes →
fail-closed). O unit test_webhook G2 cobre a FUNÇÃO refund_sweep; este cobre a
FRONTENDA CLI real que o runbook de staging executa (`--refund-sweep --dry-run`
e o guard sem opt-in). Sem pytest: python3 companion/test_refund_cli.py."""
import ast
import os
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")

FAILS = []
CHECKS = 0


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def make_db():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE grant_queue (idempotency_key TEXT UNIQUE, status TEXT, "
        "payload TEXT, refund_notified INTEGER DEFAULT 0);")
    con.execute("INSERT INTO grant_queue VALUES ('pay1', 'refunded', '{\"provider\": \"mercadopago\"}', 0);")
    con.execute("INSERT INTO grant_queue VALUES ('pay2', 'refunded', '{\"provider\": \"mercadopago\"}', 0);")
    con.execute("INSERT INTO grant_queue VALUES ('sbx1', 'refunded', '{\"provider\": \"sandbox\"}', 0);")
    con.execute("INSERT INTO grant_queue VALUES ('p0', 'processed', '{\"provider\": \"mercadopago\"}', 0);")
    con.execute("INSERT INTO grant_queue VALUES ('done1', 'refunded', '{\"provider\": \"mercadopago\"}', 1);")
    con.commit()
    con.close()
    return path


def run(args, env=None):
    e = dict(os.environ)
    e.pop("SHAMBLETA_MP_REFUNDS", None)
    e.pop("SHAMBLETA_MP_ACCESS_TOKEN", None)
    if env:
        e.update(env)
    return subprocess.run([sys.executable, SERVER] + args,
                          capture_output=True, text=True, env=e, timeout=30)


def parse_sweep(stdout):
    marker = "companion: refund sweep: "
    for line in stdout.splitlines():
        if line.startswith(marker):
            return ast.literal_eval(line[len(marker):])
    return None


db = make_db()
try:
    # 1) dry-run: lê o estado, NÃO estorna (notified=0), sem precisar de env/token.
    r = run(["--db", db, "--refund-sweep", "--dry-run"])
    ok(r.returncode == 0, "dry-run exits 0")
    res = parse_sweep(r.stdout)
    ok(res is not None, "dry-run prints a parseable result")
    if res:
        ok(res["pending"] == 3, "dry-run: 3 pending (2 mp + 1 sandbox), processed/notified excluded")
        ok(res["notified"] == 0, "dry-run: nothing notified (no API call)")
        ok(res["skipped"] == 1, "dry-run: sandbox counted as skipped")
    # dry-run não muda o banco: refund_notified continua 0 nos pendentes.
    con = sqlite3.connect(db)
    still = con.execute("SELECT COUNT(*) FROM grant_queue WHERE refund_notified = 0 AND status='refunded';").fetchone()[0]
    con.close()
    ok(still == 3, "dry-run: refund_notified untouched in DB")

    # 2) non-dry SEM opt-in: fail-closed antes de tocar em qualquer coisa.
    r = run(["--db", db, "--refund-sweep", "--mp-access-token", "tok"])
    ok(r.returncode == 2, "non-dry without SHAMBLETA_MP_REFUNDS: exit 2")
    ok("SHAMBLETA_MP_REFUNDS" in (r.stderr or ""), "non-dry without opt-in: explicit guard message")

    # 3) non-dry COM opt-in mas SEM token: fail-closed no token.
    r = run(["--db", db, "--refund-sweep"], env={"SHAMBLETA_MP_REFUNDS": "1"})
    ok(r.returncode == 2, "non-dry without token: exit 2")
    ok("ACCESS_TOKEN" in (r.stderr or ""), "non-dry without token: explicit guard message")

    # 4) DB inexistente: exit 2 (nunca traceback cru no runbook).
    r = run(["--db", os.path.join(tempfile.gettempdir(), "does_not_exist_zz.db"), "--refund-sweep", "--dry-run"])
    ok(r.returncode == 2, "missing DB: exit 2 with a clean error")
    ok("database not found" in (r.stderr or ""), "missing DB: readable message")
finally:
    os.unlink(db)

if FAILS:
    print("== REFUND CLI: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== REFUND CLI: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)
