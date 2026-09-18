#!/usr/bin/env python3
"""Testes de segurança do companion (beta fechado, sem monetização real).

Servidor HTTP REAL em porta efêmera + SQLite temporário (nunca o banco de
produção). Sem pytest: python3 companion/test_security.py. Sai !=0 se falhar.

Parte A — webhook Mercado Pago fail-closed (8 casos):
  1. webhook válido + API confirma approved → processa (grant enfileirado);
  2. provider real sem MP_ACCESS_TOKEN → 503, nada concede;
  3. payment ID inválido (API retorna None) → 502, nada concede;
  4. payment não aprovado (pending) → 200 ignorado, nada concede;
  5. replay do mesmo payment → 200, UMA linha (idempotente);
  6. SKU inválido no external_reference → 400, nada concede;
  7. valor pago != preço do catálogo → 400 amount_mismatch, nada concede;
  8. assinatura inválida → 401, nada concede.

Parte B — checkout com binding de sessão (6 casos):
  1. usuário A cria checkout p/ A (token válido) → 200, preço do catálogo;
  2. usuário A tenta checkout p/ B → 403, sem chamar a API do MP;
  3. sem token → 401;
  4. SKU válido → preço exclusivamente do catálogo/server;
  5. preço enviado pelo cliente é ignorado (não altera a preferência);
  6. external_reference permanece vinculado à conta dona do token.
"""
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

FAILS = []
CHECKS = 0
MP_SECRET = "mp-webhook-secret"
MP_TOKEN = "MP-ACCESS-TOKEN"
NOW = int(time.time())


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def mp_sign(data_id, request_id, ts):
    manifest = server._mp_manifest(data_id, request_id, str(ts))
    sig = hmac.new(MP_SECRET.encode(), manifest.encode(),
                   hashlib.sha256).hexdigest()
    return "ts=%d,v1=%s" % (ts, sig)


def make_db():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, "
                "username TEXT, created_timestamp INTEGER);")
    con.execute("INSERT INTO account VALUES (1, 'Alice', ?);", (NOW,))
    con.execute("INSERT INTO account VALUES (2, 'Bob', ?);", (NOW,))
    con.execute("CREATE TABLE grant_queue (id INTEGER PRIMARY KEY "
                "AUTOINCREMENT, idempotency_key TEXT NOT NULL UNIQUE, "
                "account_id INTEGER NOT NULL, kind TEXT NOT NULL, "
                "amount INTEGER NOT NULL, payload TEXT, "
                "status TEXT NOT NULL DEFAULT 'pending', "
                "created_at INTEGER NOT NULL);")
    con.execute("CREATE TABLE auth_token (account_id INTEGER NOT NULL, "
                "token_hash TEXT NOT NULL, ip_address TEXT NOT NULL DEFAULT '',"
                " expires_timestamp INTEGER NOT NULL DEFAULT 0);")
    tok_a = hashlib.sha256(b"tok-Alice").hexdigest()
    tok_b = hashlib.sha256(b"tok-Bob").hexdigest()
    con.execute("INSERT INTO auth_token VALUES (1, ?, '127.0.0.1', ?);",
                (tok_a, NOW + 30 * 86400))
    con.execute("INSERT INTO auth_token VALUES (2, ?, '127.0.0.1', ?);",
                (tok_b, NOW + 30 * 86400))
    con.execute("INSERT INTO auth_token VALUES (1, ?, '127.0.0.1', ?);",
                (hashlib.sha256(b"tok-expired").hexdigest(), NOW - 10))
    con.commit()
    con.close()
    return path


DB_PATH = make_db()
HTTPD = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
HTTPD.daemon_threads = True
HTTPD.store = server.Store(DB_PATH)
HTTPD.secret = ""
HTTPD.provider = "mercadopago"
HTTPD.stripe_secret = ""
HTTPD.mp_secret = MP_SECRET
HTTPD.mp_access_token = MP_TOKEN
HTTPD.allow_unverified = False
HTTPD.allow_dev = False
HTTPD.allow_dev_checkout = False
HTTPD.mp_back_urls_base = ""
HTTPD.catalog = dict(server.DEFAULT_CATALOG)
HTTPD.tolerance = 300
PORT = HTTPD.server_address[1]
threading.Thread(target=HTTPD.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % PORT


def post(path, body, headers=None):
    data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json",
                                          **(headers or {})},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.request.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except ValueError:
            return e.code, {}


def grants(key=None):
    con = sqlite3.connect(DB_PATH)
    if key is None:
        rows = con.execute("SELECT idempotency_key, account_id, kind, amount,"
                           " status FROM grant_queue;").fetchall()
    else:
        rows = con.execute("SELECT idempotency_key, account_id, kind, amount,"
                           " status FROM grant_queue WHERE idempotency_key = ?;",
                           (key,)).fetchall()
    con.close()
    return rows


# --- mocks da API do MP (nunca rede real) ---
PAYMENTS = {}
PREF_CALLS = []
_real_fetch = server.mp_fetch_payment
_real_pref = server.mp_create_preference


def fake_fetch(payment_id, access_token):
    assert access_token == MP_TOKEN, "refetch deve usar o access token"
    return PAYMENTS.get(payment_id)


def fake_pref(payload, access_token):
    assert access_token == MP_TOKEN, "preference deve usar o access token"
    PREF_CALLS.append(payload)
    return {"id": "pref-1", "init_point": "https://mp.test/pay/pref-1"}


server.mp_fetch_payment = fake_fetch
server.mp_create_preference = fake_pref


def webhook_headers(data_id, request_id="req-1", bad_sig=False):
    ts = int(time.time())
    sig = mp_sign(data_id, request_id, ts)
    if bad_sig:
        sig = "ts=%d,v1=deadbeef" % ts
    return {"x-signature": sig, "x-request-id": request_id}


def approved_payment(pid, ref, amount):
    return {"id": pid, "status": "approved",
            "external_reference": ref, "transaction_amount": amount}


try:
    # ============ Parte A — webhook fail-closed ============
    # A1: válido + approved → processa
    PAYMENTS["pay-ok"] = approved_payment("pay-ok", "1:gems.550", 19.90)
    code, res = post("/webhooks/payments?data.id=pay-ok", {},
                     webhook_headers("pay-ok"))
    ok(code == 200 and res.get("status") in ("queued", "duplicate", "ok"),
       "A1 válido+approved → 200 e processa")
    rows = grants("pay-ok")
    ok(len(rows) == 1 and rows[0][1] == 1 and rows[0][2] == "gems"
       and rows[0][3] == 550, "A1 grant gems.550 p/ conta 1 enfileirado")

    # A2: provider real sem token → 503, nada concede
    HTTPD.mp_access_token = ""
    n_before = len(grants())
    PAYMENTS["pay-notoken"] = approved_payment("pay-notoken", "1:gems.550",
                                               19.90)
    code, res = post("/webhooks/payments?data.id=pay-notoken", {},
                     webhook_headers("pay-notoken"))
    ok(code == 503 and res.get("error") == "checkout_unavailable",
       "A2 sem MP_ACCESS_TOKEN → 503 (fail-closed)")
    ok(len(grants()) == n_before, "A2 nada concedido sem token")
    HTTPD.mp_access_token = MP_TOKEN

    # A3: payment ID inválido (API retorna None) → 502
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-ghost", {},
                     webhook_headers("pay-ghost"))
    ok(code == 502 and res.get("error") == "refetch_failed",
       "A3 payment inexistente → 502")
    ok(len(grants()) == n_before, "A3 nada concedido com refetch falho")

    # A4: pending → 200 ignorado
    PAYMENTS["pay-pend"] = {"id": "pay-pend", "status": "pending",
                            "external_reference": "1:gems.550",
                            "transaction_amount": 19.90}
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-pend", {},
                     webhook_headers("pay-pend"))
    ok(code == 200 and res.get("status") == "ignored",
       "A4 pending → 200 ignored")
    ok(len(grants()) == n_before, "A4 pending não concede")

    # A5: replay do mesmo payment → idempotente
    code, res = post("/webhooks/payments?data.id=pay-ok", {},
                     webhook_headers("pay-ok", request_id="req-2"))
    ok(code == 200, "A5 replay → 200")
    ok(len(grants("pay-ok")) == 1, "A5 replay não duplica (1 linha)")

    # A6: SKU inválido → 400
    PAYMENTS["pay-badsku"] = approved_payment("pay-badsku", "1:nope", 1.0)
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-badsku", {},
                     webhook_headers("pay-badsku"))
    ok(code == 400, "A6 SKU inválido → 400")
    ok(len(grants()) == n_before, "A6 SKU inválido não concede")

    # A7: valor != catálogo → 400 amount_mismatch
    PAYMENTS["pay-cheap"] = approved_payment("pay-cheap", "1:gems.550", 0.01)
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-cheap", {},
                     webhook_headers("pay-cheap"))
    ok(code == 400 and res.get("error") == "amount_mismatch",
       "A7 preço divergente → 400 amount_mismatch")
    ok(len(grants()) == n_before, "A7 preço divergente não concede")

    # A8: assinatura inválida → 401
    PAYMENTS["pay-forged"] = approved_payment("pay-forged", "1:gems.550",
                                              19.90)
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-forged", {},
                     webhook_headers("pay-forged", bad_sig=True))
    ok(code == 401, "A8 assinatura inválida → 401")
    ok(len(grants()) == n_before, "A8 assinatura inválida não concede")

    # ============ Parte B — checkout com binding de sessão ============
    # B1: A cria p/ A → 200, preço do catálogo
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Alice", "account_id": 1,
                      "sku": "gems.550"})
    ok(code == 200 and res.get("external_reference") == "1:gems.550"
       and abs(float(res.get("price", 0)) - 19.90) < 0.001
       and res.get("payment_url") == "https://mp.test/pay/pref-1",
       "B1 A→A permitido, preço do catálogo, payment_url")

    # B2: A tenta p/ B → 403, sem chamar a API do MP
    n_pref = len(PREF_CALLS)
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Alice", "account_id": 2,
                      "sku": "gems.550"})
    ok(code == 403, "B2 A→B rejeitado (403)")
    ok(len(PREF_CALLS) == n_pref, "B2 cross-account não chama a API do MP")

    # B3: sem token → 401
    code, res = post("/checkout/preference",
                     {"account_id": 1, "sku": "gems.550"})
    ok(code == 401, "B3 sem token → 401")

    # B4+B5: preço do cliente ignorado (envia 0.01, vale o catálogo)
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Bob", "account_id": 2,
                      "sku": "gems.550", "price": 0.01})
    ok(code == 200 and abs(float(res.get("price", 0)) - 19.90) < 0.001,
       "B4/B5 preço do cliente ignorado, vale o catálogo")
    ok(abs(PREF_CALLS[-1]["items"][0]["unit_price"] - 19.90) < 0.001,
       "B5 preferência enviada ao MP com preço do catálogo")

    # B6: external_reference vinculado ao dono do token (+ mismatch rejeitado)
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Bob", "sku": "gems.550"})
    ok(code == 200 and res.get("external_reference") == "2:gems.550",
       "B6 identidade vem do token (sem account_id)")
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Bob", "account_id": 2,
                      "sku": "gems.550",
                      "external_reference": "1:gems.550"})
    ok(code == 400 and res.get("error") == "external_reference_mismatch",
       "B6 external_reference de outra conta rejeitado")

    # Token expirado → 401
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-expired", "account_id": 1,
                      "sku": "gems.550"})
    ok(code == 401, "token expirado → 401")
finally:
    server.mp_fetch_payment = _real_fetch
    server.mp_create_preference = _real_pref
    HTTPD.shutdown()
    try:
        os.unlink(DB_PATH)
    except OSError:
        pass

if FAILS:
    print("== SECURITY: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== SECURITY: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)