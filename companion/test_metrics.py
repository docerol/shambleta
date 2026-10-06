#!/usr/bin/env python3
"""Testes da exposition Prometheus (`/metrics/prometheus`, P0-9 2026-10-04).

O JSON em `/metrics` já existia e era inválido para scrape (companion não expunha
texto-parseável). Este teste valida que `metrics_prometheus` devolve texto no
formato 0.0.4 do Prometheus e que os gauges principais do funnel de monetização
(gold faucet, gems, revenue, starter_funnel) aparecem. Sem pytest:
`python3 companion/test_metrics.py`. Sai !=0 se falhar.
"""
import os, sqlite3, time

HERE = os.path.dirname(os.path.abspath(__file__))
import server

FAILS = []
CHECKS = 0

def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)

def make_db():
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, "
                "username TEXT, created_timestamp INTEGER, "
                "email TEXT, email_verified INTEGER DEFAULT 0, "
                "permission INTEGER DEFAULT 0, "
                "failed_attempts INTEGER DEFAULT 0, locked_until INTEGER DEFAULT 0, "
                "consent_tos_version TEXT NOT NULL DEFAULT '', "
                "consent_privacy_version TEXT NOT NULL DEFAULT '', "
                "consent_age_version TEXT NOT NULL DEFAULT '', "
                "last_timestamp INTEGER DEFAULT 0, "
                "vip_until INTEGER DEFAULT 0);")
    con.execute("CREATE TABLE wallet (account_id INTEGER PRIMARY KEY, gems INTEGER DEFAULT 0);")
    con.execute("CREATE TABLE ledger_transaction (account_id INTEGER, char_id INTEGER, kind TEXT, "
                "amount INTEGER, balance_after INTEGER, reason TEXT, created_at INTEGER);")
    con.execute("CREATE TABLE telemetry_event (kind TEXT, account_id INTEGER, created_at INTEGER, "
                "payload TEXT, fingerprint TEXT, meta TEXT DEFAULT '{}');")
    con.execute("CREATE TABLE auction_listing (status TEXT);")
    con.execute("CREATE TABLE guild (guild_id INTEGER PRIMARY KEY);")
    con.execute("CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "account_id INTEGER, kind TEXT, amount INTEGER, payload TEXT, "
                "status TEXT, created_at INTEGER, price_paid INTEGER DEFAULT 0, "
                "currency TEXT, sku TEXT);")
    con.execute("CREATE TABLE season (season_id INTEGER, status TEXT);")
    con.execute("CREATE TABLE password_reset_request (account_id INTEGER, code_hash TEXT, "
                "created_at INTEGER);")
    con.execute("CREATE TABLE reconcile_run (id INTEGER PRIMARY KEY, divergences INTEGER, created_at INTEGER);")
    con.execute("CREATE TABLE cohort_retention (cohort_day INTEGER, d1 INTEGER, d7 INTEGER, d30 INTEGER);")
    con.execute("INSERT INTO grant_queue (account_id, kind, amount, payload, status, "
                "created_at, price_paid, currency, sku) VALUES "
                "(1, 'grant', 1, '{}', 'processed', ?, 9900, 'USD', 'starter.pack');",
                (int(time.time()) - 100,))
    con.execute("INSERT INTO cohort_retention (cohort_day, d1, d7, d30) VALUES (0, 10, 7, 5);")
    con.commit()
    return path

if __name__ == "__main__":
    db = make_db()
    store = server.Store(db)
    con = sqlite3.connect(db)
    text = store.metrics_prometheus(con)
    con.close()

    ok("# HELP" in text and "# TYPE" in text, "exposition tem cabeçalhos HELP/TYPE do Prometheus 0.0.4")
    ok("shambleta_uptime_seconds" in text, "expõe shambleta_uptime_seconds (gauge)")
    ok("shambleta_gem_balance{" in text, "expõe shambleta_gem_balance com rótulo dir={stock,mint,burn}")
    ok("shambleta_gold_faucet_7d " in text, "expõe shambleta_gold_faucet_7d")
    ok("shambleta_trades_7d" in text, "expõe shambleta_trades_7d")
    ok("shambleta_vip_active " in text, "expõe shambleta_vip_active")
    ok("shambleta_accounts{" in text, "expõe shambleta_accounts com rótulo state={total,active_24h}")
    ok("shambleta_retention_d1" in text, "expõe shambleta_retention_d1 (cohort/retained/window_closed)")
    ok("shambleta_logins_24h " in text, "expõe shambleta_logins_24h")
    ok("shambleta_grants_pending " in text, "expõe shambleta_grants_pending")
    ok("shambleta_ah_open " in text, "expõe shambleta_ah_open")
    ok("shambleta_revenue_gross_minor{" in text, "expõe shambleta_revenue_gross_minor com rótulo currency")
    ok("shambleta_starter_funnel{" in text, "expõe shambleta_starter_funnel com rótulo state={claimed,eligible}")
    ok("shambleta_revenue_gross_minor{currency=\"USD\"} 9900" in text, "expõe shambleta_revenue_gross_minor com rótulo currency (receita do fixture)")

    # Validação leve de formato: cada linha de métrica é `name{labels} value` ou `name value`.
    for line in text.strip().split("\n"):
        if line.startswith("#") or line == "":
            continue
        parts = line.rsplit(" ", 1)
        ok(len(parts) == 2, "linha métrica bem formada: %r" % line[:50])

    # HTTP route: GET /metrics/prometheus devolve text/plain
    from http.client import HTTPConnection
    from threading import Thread
    from http.server import ThreadingHTTPServer
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    httpd.daemon_threads = True
    httpd.store = server.Store(db)
    httpd.secret = ""
    httpd.provider = "mercadopago"
    httpd.mp_secret = "x"
    httpd.mp_access_token = ""
    httpd.allow_unverified = False
    httpd.allow_dev = False
    httpd.allow_dev_checkout = False
    httpd.mp_back_urls_base = ""
    httpd.catalog = dict(server.DEFAULT_CATALOG)
    httpd.tolerance = 300
    port = httpd.server_address[1]
    Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        c = HTTPConnection("127.0.0.1", port, timeout=5)
        c.request("GET", "/metrics/prometheus")
        r = c.getresponse()
        body = r.read().decode()
        ok(r.status == 200, "/metrics/prometheus responde 200")
        ok("text/plain" in r.getheader("Content-Type"), "content-type é text/plain (prometheus)")
        ok("shambleta_accounts{" in body, "body HTTP contém shambleta_accounts")
        c.close()
    finally:
        httpd.shutdown()

    if FAILS:
        print("== METRICS: %d failures ==" % len(FAILS))
        for f in FAILS:
            print("  - " + f)
        sys_exit = __import__("sys"); sys_exit.exit(1)
    print("== METRICS: %d checks, 0 failures ==" % CHECKS)
    sys_exit = __import__("sys"); sys_exit.exit(0)
