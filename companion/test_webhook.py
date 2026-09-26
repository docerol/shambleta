#!/usr/bin/env python3
"""Testes do hardening do webhook (SOM-IDLE 1c). Sem pytest: python3
companion/test_webhook.py. Sai !=0 se falhar."""
import hashlib
import hmac
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
        ok(False, label + " (no raise)")
    except exc:
        ok(True, label)


# --- catálogo (amount autoritativo) ---
cat = server.DEFAULT_CATALOG
kind, amount = server.resolve_grant(cat, "gems.1200")
ok(kind == "gems" and amount == 1200, "catalog resolves known sku")
ok(server.resolve_grant(cat, "vip.1mo")[0] == "vip_days", "catalog vip kind")
raises(server.CatalogError, lambda: server.resolve_grant(cat, "gems.9999999"),
       "unknown sku rejected")
raises(server.CatalogError, lambda: server.resolve_grant(cat, None), "null sku rejected")
raises(server.CatalogError, lambda: server.resolve_grant(cat, "gems.550", 600),
       "amount mismatch rejected")
ok(server.resolve_grant(cat, "gems.550", 550) == ("gems", 550),
   "matching claimed amount accepted")

# --- assinatura compartilhada (sandbox) ---
body = b'{"sku":"gems.550"}'
sec = "s3cr3t"
good = hmac.new(sec.encode(), body, hashlib.sha256).hexdigest()
ok(server.verify_shared_secret(sec, good, body), "shared secret valid")
ok(not server.verify_shared_secret(sec, "deadbeef", body), "shared secret bad")
ok(not server.verify_shared_secret("", good, body), "shared secret empty -> deny")
ok(not server.verify_shared_secret(sec, good, body + b"x"), "shared secret tampered body")

# --- assinatura Stripe (esquema oficial + anti-replay) ---
whsec = "whsec_test"
ts = int(time.time())
signed = ("%d." % ts).encode() + body
v1 = hmac.new(whsec.encode(), signed, hashlib.sha256).hexdigest()
hdr = "t=%d,v1=%s" % (ts, v1)
ok(server.verify_stripe_signature(whsec, hdr, body), "stripe valid signature")
ok(not server.verify_stripe_signature(whsec, hdr, body + b" "), "stripe tampered body")
ok(not server.verify_stripe_signature(whsec, "t=%d,v1=bad" % ts, body), "stripe bad sig")
ok(not server.verify_stripe_signature(whsec, "v1=%s" % v1, body), "stripe missing t")
# replay: timestamp fora da janela
old = ts - 10_000
oldsigned = ("%d." % old).encode() + body
oldv1 = hmac.new(whsec.encode(), oldsigned, hashlib.sha256).hexdigest()
ok(not server.verify_stripe_signature(whsec, "t=%d,v1=%s" % (old, oldv1), body, 300),
   "stripe replay rejected (ts too old)")
ok(not server.verify_stripe_signature("", hdr, body), "stripe no secret -> deny")

# --- assinatura Mercado Pago (manifest oficial id:..;request-id:..;ts:..;) ---
mpsec = "mp_secret"
mpts = int(time.time())
mp_data_id = "1234567890"
mp_rid = "req-abc"
manifest = server._mp_manifest(mp_data_id, mp_rid, str(mpts))
ok(manifest == "id:%s;request-id:%s;ts:%d;" % (mp_data_id, mp_rid, mpts),
   "mp manifest format")
mpsig = hmac.new(mpsec.encode(), manifest.encode(), hashlib.sha256).hexdigest()
ok(server.verify_mercadopago_signature(mpsec, "ts=%d,v1=%s" % (mpts, mpsig), mp_rid, mp_data_id),
   "mp valid signature")
ok(not server.verify_mercadopago_signature(mpsec, "ts=%d,v1=bad" % mpts, mp_rid, mp_data_id),
   "mp bad sig")
ok(not server.verify_mercadopago_signature(mpsec, "ts=%d,v1=%s" % (mpts, mpsig), "wrong-rid", mp_data_id),
   "mp request-id mismatch")
ok(not server.verify_mercadopago_signature(mpsec, "ts=%d,v1=%s" % (mpts, mpsig), mp_rid, "other-id"),
   "mp data.id mismatch")
ok(not server.verify_mercadopago_signature("", "ts=%d,v1=%s" % (mpts, mpsig), mp_rid, mp_data_id),
   "mp no secret -> deny")
oldts = mpts - 100000
oldman = server._mp_manifest(mp_data_id, mp_rid, str(oldts))
oldsig = hmac.new(mpsec.encode(), oldman.encode(), hashlib.sha256).hexdigest()
ok(not server.verify_mercadopago_signature(mpsec, "ts=%d,v1=%s" % (oldts, oldsig), mp_rid, mp_data_id, 300),
   "mp replay rejected (ts too old)")
man2 = server._mp_manifest(mp_data_id, "", str(mpts))
ok(man2 == "id:%s;ts:%d;" % (mp_data_id, mpts), "mp manifest omits empty request-id")
sig2 = hmac.new(mpsec.encode(), man2.encode(), hashlib.sha256).hexdigest()
ok(server.verify_mercadopago_signature(mpsec, "ts=%d,v1=%s" % (mpts, sig2), "", mp_data_id),
   "mp valid without request-id")
ok(server._mp_manifest("ABC123", "", "5") == "id:abc123;ts:5;", "mp data.id lowercased")

# --- normalização de evento ---
stripe_evt = {
    "id": "evt_123",
    "type": "checkout.session.completed",
    "data": {"object": {
        "id": "cs_x",
        "client_reference_id": "42",
        "metadata": {"shambleta_sku": "gems.1200"},
    }},
}
n = server.normalize_event("stripe", stripe_evt)
ok(n["account_id"] == 42 and n["sku"] == "gems.1200" and n["idempotency_key"] == "evt_123",
   "stripe event -> canonical grant")
flat = {"idempotency_key": "tx1", "username": "Hero", "sku": "gems.550"}
nf = server.normalize_event("shared", flat)
ok(nf["username"] == "Hero" and nf["sku"] == "gems.550" and nf["account_id"] is None,
   "sandbox flat -> canonical grant")

# --- normalização Mercado Pago (payment re-buscado + sandbox) ---
a, s = server.parse_external_reference("42:gems.1200")
ok(a == 42 and s == "gems.1200", "parse external_reference acct:sku")
ok(server.parse_external_reference("garbage") == (None, None), "parse external_reference junk")
pay = {"id": "9001", "status": "approved", "external_reference": "1:gems.550"}
np = server.normalize_event("mercadopago", pay)
ok(np["account_id"] == 1 and np["sku"] == "gems.550" and np["idempotency_key"] == "9001",
   "mp approved payment -> grant")
pend = dict(pay); pend["status"] = "pending"
ok(server.normalize_event("mercadopago", pend) is None, "mp pending payment -> no grant")
mpflat = {"idempotency_key": "mp1", "account_id": "7", "sku": "gems.1200"}
nfmp = server.normalize_event("mercadopago", mpflat)
ok(nfmp["account_id"] == 7 and nfmp["sku"] == "gems.1200", "mp sandbox flat body -> grant")

# --- idempotência do enqueue (schema grant_queue real) ---
tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp.close()
con = sqlite3.connect(tmp.name)
con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT, created_timestamp INTEGER);")
con.execute("INSERT INTO account (account_id, username, created_timestamp) VALUES (1, 'Hero', ?);",
            (int(time.time()),))
con.execute(
    "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " idempotency_key TEXT NOT NULL UNIQUE, account_id INTEGER NOT NULL,"
    " kind TEXT NOT NULL, amount INTEGER NOT NULL, payload TEXT,"
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL,"
    " price_paid INTEGER NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT '');")
st = server.Store(tmp.name)
ok(st.account_id(con, username="Hero") == 1, "store resolves account by username")
ok(st.account_id(con, username="Ghost") is None, "store rejects unknown account")
ok(st.enqueue(con, "k1", 1, "gems", 550, {"sku": "gems.550"}) == "queued", "first enqueue queued")
ok(st.enqueue(con, "k1", 1, "gems", 550, {"sku": "gems.550"}) == "duplicate",
   "replayed key deduped")
ok(st.pending(con) == 1, "only one pending grant")
con.close()
os.unlink(tmp.name)

# --- Fase A: bundles, starter offer, catálogo real ---
items = server.resolve_grant_items(cat, "starter.pack")
ok(items == [("vip_days", 7), ("gems", 220)], "bundle starter decomposes")
ok(server.resolve_grant_items(cat, "gems.550") == [("gems", 550)],
   "simple sku still single item")
raises(server.CatalogError, lambda: server.resolve_grant(cat, "starter.pack"),
       "legacy resolve rejects bundle (use_grant_items)")
raises(server.CatalogError,
       lambda: server.resolve_grant_items(cat, "starter.pack", 999),
       "bundle claimed_amount rejected")

filecat = server.load_catalog(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                            "data", "conf", "paid_catalog.json"))
ok("starter.pack" in filecat and "founder.pack" in filecat,
   "paid_catalog.json loads with starter/founder")
ok(server.resolve_grant_items(filecat, "founder.pack")
   == [("gems", 1200), ("vip_days", 30)], "paid_catalog.json founder bundle")
ok(server.default_catalog_path().replace("\\", "/").endswith("data/conf/paid_catalog.json"),
   "default --catalog resolves to the canonical source file")
fd, badpath = tempfile.mkstemp(suffix=".json")
os.write(fd, b'{"x": {"kind": "bundle", "contents": []}}')
os.close(fd)
try:
    server.load_catalog(badpath)
    ok(False, "empty bundle rejected (no raise)")
except ValueError:
    ok(True, "empty bundle rejected")
os.unlink(badpath)

tmp2 = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp2.close()
con = sqlite3.connect(tmp2.name)
con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT, created_timestamp INTEGER);")
con.execute("INSERT INTO account (account_id, username, created_timestamp) VALUES (1, 'Hero', ?);",
            (int(time.time()),))
con.execute(
    "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " idempotency_key TEXT NOT NULL UNIQUE, account_id INTEGER NOT NULL,"
    " kind TEXT NOT NULL, amount INTEGER NOT NULL, payload TEXT,"
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL,"
    " price_paid INTEGER NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT '');")
st = server.Store(tmp2.name)
offer = server.starter_offer_status(con, cat, 1)
ok(offer["eligible"] and offer["reason"] == "ok", "fresh account starter eligible")
ok(offer["expires_at"] > int(time.time()), "starter expiry in future")

# compra prévia bloqueia (one-time)
st.enqueue(con, "1:starter.pack:pay1:0:vip_days", 1, "vip_days", 7,
           {"sku": "starter.pack", "provider": "sandbox", "kind": "vip_days"})
offer2 = server.starter_offer_status(con, cat, 1)
ok(not offer2["eligible"] and offer2["reason"] == "already_claimed",
   "starter one-time enforced")
con.execute("DELETE FROM grant_queue WHERE idempotency_key LIKE '1:starter.pack%';")
con.commit()

# conta velha (>72h) expira
con.execute("INSERT INTO account (account_id, username, created_timestamp) VALUES (2, 'Old', ?);",
            (int(time.time()) - 10 * 86400,))
offer3 = server.starter_offer_status(con, cat, 2)
ok(not offer3["eligible"] and offer3["reason"] == "expired", "starter expires D3+")
offer4 = server.starter_offer_status(con, cat, 999)
ok(not offer4["eligible"] and offer4["reason"] == "unknown_account",
   "starter unknown account rejected")
con.close()
os.unlink(tmp2.name)

# --- Fase C: passe S1 ---
ok(server.resolve_grant(cat, "pass.s1") == ("pass_premium", 1),
   "pass.s1 resolves to pass_premium")
ok(server.resolve_grant_items(cat, "pass.s1") == [("pass_premium", 1)],
   "pass.s1 items single")

# --- G1: gate de temporada no checkout ---
# O grant de pass_premium falha fechado no jogo sem temporada ativa; a recusa
# tem que acontecer ANTES de o Mercado Pago cobrar.
SEASON_DDL = ("CREATE TABLE season (season_id INTEGER PRIMARY KEY AUTOINCREMENT,"
              " starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL,"
              " rules_frozen TEXT NOT NULL DEFAULT '{}',"
              " status TEXT NOT NULL DEFAULT 'active');")
nowS = int(time.time())
bare = sqlite3.connect(":memory:")
ok(server.season_offer_status(bare, cat, "vip.1mo")["eligible"],
   "gate não toca sku não sazonal")
bare.execute(SEASON_DDL)
gate = server.season_offer_status(bare, cat, "pass.s1")
ok(not gate["eligible"] and gate["reason"] == "no_active_season",
   "passe indisponível sem temporada")
missing = sqlite3.connect(":memory:")
ok(not server.season_offer_status(missing, cat, "pass.s1.deluxe")["eligible"],
   "banco sem a tabela season também recusa (fail-closed)")
bare.execute("INSERT INTO season (starts_at, ends_at, status) VALUES (?, ?, 'active');",
             (nowS - 3600, nowS + 30 * 86400))
live = server.season_offer_status(bare, cat, "pass.s1")
ok(live["eligible"] and live["season_id"] > 0, "passe vendável com temporada ativa")
bare.execute("UPDATE season SET status = 'settled';")
ok(not server.season_offer_status(bare, cat, "pass.s1")["eligible"],
   "temporada liquidada não vende passe")
bare.execute("UPDATE season SET status = 'active', ends_at = ?;", (nowS - 10,))
ok(not server.season_offer_status(bare, cat, "pass.s1")["eligible"],
   "temporada vencida não vende passe no intervalo até o fechamento")
bare.execute("UPDATE season SET status = 'active', ends_at = ?;", (nowS + 3600,))
ok(server.season_offer_status(bare, cat, "pass.s1")["eligible"],
   "volta a vender quando há temporada dentro do prazo")
bare.close()
missing.close()

# --- Fase F: doação vira cosmético ---
ok(server.resolve_grant(cat, "donate.support") == ("cosmetic", 1),
   "donate.support resolves to cosmetic")
fd2, badpath2 = tempfile.mkstemp(suffix=".json")
os.write(fd2, b'{"x": {"kind": "cosmetic", "amount": 1}}')
os.close(fd2)
try:
    server.load_catalog(badpath2)
    ok(False, "cosmetic without id rejected (no raise)")
except ValueError:
    ok(True, "cosmetic without id rejected")
os.unlink(badpath2)

# --- Follow-up Deluxe ---
ok(server.resolve_grant(cat, "pass.s1.deluxe") == ("pass_premium", 1),
   "deluxe resolves to pass_premium")

# --- Follow-up G2: refund sweep (fail-closed, dry-run, sucesso mockado) ---
os.environ.pop("SHAMBLETA_MP_REFUNDS", None)
try:
    server.refund_sweep(":memory:", "tok")
    ok(False, "sweep without opt-in rejected (no raise)")
except RuntimeError:
    ok(True, "sweep without opt-in rejected")
os.environ["SHAMBLETA_MP_REFUNDS"] = "1"
try:
    server.refund_sweep(":memory:", "")
    ok(False, "sweep without token rejected (no raise)")
except RuntimeError:
    ok(True, "sweep without token rejected")

tmp3 = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp3.close()
con3 = sqlite3.connect(tmp3.name)
con3.execute("CREATE TABLE grant_queue (idempotency_key TEXT UNIQUE, status TEXT, payload TEXT, refund_notified INTEGER DEFAULT 0);")
con3.execute("INSERT INTO grant_queue VALUES ('pay1', 'refunded', '{\"provider\": \"mercadopago\"}', 0);")
con3.execute("INSERT INTO grant_queue VALUES ('tx9', 'refunded', '{\"provider\": \"sandbox\"}', 0);")
con3.execute("INSERT INTO grant_queue VALUES ('pay0', 'processed', '{\"provider\": \"mercadopago\"}', 0);")
con3.commit()
dry = server.refund_sweep(tmp3.name, "tok", dry_run=True)
ok(dry == {"pending": 2, "notified": 0, "skipped": 1}, "dry-run lists MP pending, skips sandbox")

import urllib.request as _urlreq
_calls = []
_real_urlopen = _urlreq.urlopen


class _Resp:
    status = 201

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return b"{}"


def _fake_ok(req, timeout=10):
    _calls.append(getattr(req, "full_url", req))
    return _Resp()


def _fake_fail(req, timeout=10):
    raise IOError("down")


_urlreq.urlopen = _fake_ok
live = server.refund_sweep(tmp3.name, "tok")
ok(live["notified"] == 1 and len(_calls) == 1 and "pay1/refunds" in _calls[0],
   "success calls MP refunds API once")
flag = con3.execute("SELECT refund_notified FROM grant_queue WHERE idempotency_key = 'pay1';").fetchone()
ok(flag[0] == 1, "notified flag persisted")
again = server.refund_sweep(tmp3.name, "tok")
ok(again == {"pending": 1, "notified": 0, "skipped": 1}, "notified row drops out, sandbox stays")
con3.execute("INSERT INTO grant_queue VALUES ('pay2', 'refunded', '{\"provider\": \"mercadopago\"}', 0);")
con3.commit()
_urlreq.urlopen = _fake_fail
down = server.refund_sweep(tmp3.name, "tok")
ok(down["notified"] == 0, "API failure not marked")
flag2 = con3.execute("SELECT refund_notified FROM grant_queue WHERE idempotency_key = 'pay2';").fetchone()
ok(flag2[0] == 0, "failure leaves flag clear")
_urlreq.urlopen = _real_urlopen
ok(server.mp_refund_payment("", "tok") is False, "refund without id refused")
ok(server.mp_refund_payment("pay1", "") is False, "refund without token refused")
con3.close()
os.unlink(tmp3.name)
os.environ.pop("SHAMBLETA_MP_REFUNDS", None)

# --- Produção: POST /checkout/preference (Checkout Pro, valor do catálogo) ---
payload, err = server.build_preference_payload(cat, "gems.550", "42:gems.550")
ok(err is None and payload["external_reference"] == "42:gems.550",
   "preference payload carries external_reference")
ok(payload["items"][0]["unit_price"] == 19.90
   and payload["items"][0]["quantity"] == 1
   and payload["items"][0]["currency_id"] == "BRL",
   "preference price comes from catalog (never client)")
ok("back_urls" not in payload, "no back_urls without base")
payload2, err2 = server.build_preference_payload(
    cat, "vip.1mo", "7:vip.1mo", "https://jogo.exemplo.com")
ok(err2 is None and payload2["back_urls"]["success"] ==
   "https://jogo.exemplo.com/checkout_return.html"
   and payload2["auto_return"] == "approved",
   "back_urls point at static return page")
badpay, baderr = server.build_preference_payload(cat, "nope", "1:nope")
ok(badpay is None and baderr == "unknown_sku",
   "preference rejects unknown sku")

# O título do item é o que o pagador lê no Checkout Pro e no extrato — e é a
# linha que uma contestação cita. "pending entitlements" estava nesse texto
# (placeholder de engenharia prometendo algo não entregue): risco de chargeback,
# não cosmética. Varre as DUAS cópias cobráveis (o arquivo canônico e o fallback
# do companion) e amarra os títulos entre elas, porque a régua de preço já
# existia e a de rótulo não — foi exatamente assim que o placeholder sobreviveu.
for _name, _cat in (("paid_catalog.json", filecat), ("DEFAULT_CATALOG", cat)):
    for _sku in sorted(k for k in _cat if not k.startswith("_")):
        _p, _e = server.build_preference_payload(_cat, _sku, "1:%s" % _sku)
        ok(_e is None, "preferência montável para %s em %s" % (_sku, _name))
        _title = _p["items"][0]["title"]
        ok("pending" not in _title.lower() and "tbd" not in _title.lower(),
           "título da cobrança sem placeholder de engenharia: %s/%s" % (_name, _sku))
        ok(_title.endswith("(%s)" % _sku),
           "título da cobrança nomeia o SKU: %s/%s" % (_name, _sku))
        if _name == "DEFAULT_CATALOG" and _sku in filecat:
            ok(_title == server.build_preference_payload(
                   filecat, _sku, "1:%s" % _sku)[0]["items"][0]["title"],
               "o fallback imprime o rótulo do arquivo canônico: %s" % _sku)

# mp_create_preference: mock da API do MP (nunca bate na API real nos testes)
import urllib.request as _urlreq2
_real2 = _urlreq2.urlopen


class _PrefResp:
    status = 201

    def __init__(self, body):
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self._body


_calls2 = []


def _fake_pref(req, timeout=10):
    _calls2.append({"url": getattr(req, "full_url", req),
                    "auth": req.get_header("Authorization"),
                    "body": __import__("json").loads(req.data.decode())})
    return _PrefResp(b'{"id": "pref-1", "init_point": "https://mp/checkout/abc"}')


_urlreq2.urlopen = _fake_pref
pref = server.mp_create_preference(payload, "TOKEN123")
ok(pref is not None and pref.get("init_point") == "https://mp/checkout/abc",
   "preference returns init_point (mocked MP API)")
ok(_calls2 and _calls2[0]["url"].endswith("/checkout/preferences")
   and _calls2[0]["auth"] == "Bearer TOKEN123",
   "preference posts to MP with bearer token")
ok(_calls2[0]["body"]["external_reference"] == "42:gems.550"
   and _calls2[0]["body"]["items"][0]["unit_price"] == 19.90,
   "preference body uses catalog price + external_reference")


def _fake_pref_down(req, timeout=10):
    raise IOError("down")


_urlreq2.urlopen = _fake_pref_down
ok(server.mp_create_preference(payload, "TOKEN123") is None,
   "preference API failure returns None (caller 502s)")
_urlreq2.urlopen = _real2
ok(server.mp_create_preference(payload, "") is None,
   "preference without token refused (fail-closed)")

# --- K1: preço pago na fila (receita em dinheiro, não unidade de jogo) ---
stripe_paid = {"id": "evt_9", "data": {"object": {
    "id": "cs_9", "client_reference_id": "42",
    "metadata": {"shambleta_sku": "gems.550"},
    "amount_total": 1990, "currency": "brl"}}}
nsp = server.normalize_event("stripe", stripe_paid)
ok(nsp["price_paid"] == 1990 and nsp["currency"] == "BRL",
   "stripe: amount_total (já em centavos) vira price_paid")
mp_paid = {"id": "9002", "status": "approved", "external_reference": "1:gems.550",
           "transaction_amount": 19.9, "currency_id": "BRL"}
npm = server.normalize_event("mercadopago", mp_paid)
ok(npm["price_paid"] == 1990,
   "mp: transaction_amount float da borda vira inteiro em centavos")
ok(server.normalize_event("mercadopago", {"id": "9003", "status": "approved",
   "external_reference": "1:gems.550"})["price_paid"] == 0,
   "payment sem valor não inventa receita")
ok(server.normalize_event("shared", {"idempotency_key": "t",
   "sku": "gems.550"})["currency"] == "",
   "sandbox sem moeda não chuta uma moeda")
ok(server.catalog_price_minor(cat, "gems.550") == (1990, "BRL"),
   "preço de catálogo sai na mesma unidade menor da fila")
ok(server.catalog_price_minor(cat, "nao.existe") == (0, ""),
   "sku inexistente não tem preço")

# O writer: bundle = N linhas de grant, UMA linha de dinheiro (senão
# SUM(price_paid) contaria a mesma compra N vezes).
tmp4 = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp4.close()
con4 = sqlite3.connect(tmp4.name)
con4.execute(
    "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " idempotency_key TEXT NOT NULL UNIQUE, account_id INTEGER NOT NULL,"
    " kind TEXT NOT NULL, amount INTEGER NOT NULL, payload TEXT,"
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL,"
    " price_paid INTEGER NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT '');")
st4 = server.Store(tmp4.name)
handler = server.Handler.__new__(server.Handler)  # sem request real: só o writer
handler.server = type("S", (), {"catalog": cat, "store": st4})()
bundle = server.resolve_grant_items(cat, "starter.pack")
statuses = handler._enqueue_items(con4, 1, "starter.pack", bundle, "pay7",
                                  "mercadopago", 1990, "BRL")
ok(statuses == ["queued"] * len(bundle), "bundle: um grant por item")
ok(con4.execute("SELECT COALESCE(SUM(price_paid), 0) FROM grant_queue;").fetchone()[0]
   == 1990, "bundle: o preço entra uma única vez na soma")
ok(con4.execute("SELECT COUNT(*) FROM grant_queue WHERE price_paid > 0;").fetchone()[0]
   == 1, "bundle: uma compra é uma linha com dinheiro")
ok(con4.execute("SELECT amount FROM grant_queue ORDER BY id;").fetchall()
   == [(7,), (220,)], "bundle: as unidades de jogo continuam por item")
# redelivery do mesmo payment: idempotente por chave derivada, sem preço extra
again = handler._enqueue_items(con4, 1, "starter.pack", bundle, "pay7",
                               "mercadopago", 1990, "BRL")
ok(again == ["duplicate"] * len(bundle) and con4.execute(
    "SELECT COALESCE(SUM(price_paid), 0) FROM grant_queue;").fetchone()[0] == 1990,
   "redelivery não duplica o dinheiro")
con4.close()
os.unlink(tmp4.name)

# /metrics: a resposta tem de dizer quanto entrou, em qual moeda, e por pagante.
tmp5 = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp5.close()
con5 = sqlite3.connect(tmp5.name)
for ddl in (
        "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " idempotency_key TEXT UNIQUE, account_id INTEGER, kind TEXT, amount INTEGER,"
        " payload TEXT, status TEXT DEFAULT 'pending', created_at INTEGER,"
        " price_paid INTEGER DEFAULT 0, currency TEXT DEFAULT '')",
        "CREATE TABLE ledger_transaction (kind TEXT, amount INTEGER, reason TEXT,"
        " created_at INTEGER)",
        "CREATE TABLE wallet (gems INTEGER)",
        "CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT,"
        " created_timestamp INTEGER, last_timestamp INTEGER, vip_until INTEGER)",
        "CREATE TABLE telemetry_event (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " created_at INTEGER, account_id INTEGER, char_id INTEGER, kind TEXT,"
        " value INTEGER, meta TEXT DEFAULT '{}', fingerprint TEXT DEFAULT '')",
        "CREATE TABLE reconcile_run (id INTEGER PRIMARY KEY, divergences INTEGER,"
        " created_at INTEGER)",
        "CREATE TABLE guild (guild_id INTEGER)",
        "CREATE TABLE auction_listing (status TEXT)",
        "CREATE TABLE season (season_id INTEGER, status TEXT)"):
    con5.execute(ddl)
nowts = int(time.time())
con5.execute("INSERT INTO account VALUES (1, 'Hero', ?, ?, 0);", (nowts, nowts))
con5.execute("INSERT INTO account VALUES (2, 'Payer', ?, ?, 0);", (nowts, nowts))
con5.execute("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount,"
             " payload, status, created_at, price_paid, currency)"
             " VALUES ('p1:0:vip_days', 2, 'vip_days', 7, ?,"
             " 'processed', ?, 1990, 'BRL');",
             (json.dumps({"sku": "vip.1mo"}), nowts))
con5.execute("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount,"
             " payload, status, created_at, price_paid, currency)"
             " VALUES ('p1:1:gems', 2, 'gems', 220, ?, 'processed', ?, 0, '');",
             (json.dumps({"sku": "vip.1mo"}), nowts))
con5.execute("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount,"
             " payload, status, created_at, price_paid, currency)"
             " VALUES ('p2', 1, 'gems', 550, ?, 'processed', ?, 2500, 'USD');",
             (json.dumps({"sku": "gems.550"}), nowts))
con5.execute("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount,"
             " payload, status, created_at, price_paid, currency)"
             " VALUES ('p3', 1, 'gems', 550, ?, 'pending', ?, 9999, 'BRL');",
             (json.dumps({"sku": "gems.550"}), nowts))
st5 = server.Store(tmp5.name)
# Multi-account: a digital é COLUNA de telemetry_event (migration 030). A
# consulta selecionava 'fp' — coluna que só existia numa tabela que este próprio
# código criava e ninguém populava — e o OperationalError derrubava o /metrics
# inteiro (500) em qualquer banco migrado. Este bloco é o guarda-chuva disso.
for acct, fp in ((1, "maquina-compartilhada"), (2, "maquina-compartilhada"),
                 (3, "maquina-compartilhada"), (4, "casa-do-joao")):
    con5.execute("INSERT INTO telemetry_event (created_at, account_id, char_id,"
                 " kind, value, meta, fingerprint) VALUES (?, ?, 0, 'login', 0,"
                 " '{}', ?);", (nowts, acct, fp))
m = st5.metrics(con5)
rev = m["revenue_by_currency"]
ok(rev["BRL"]["gross_minor"] == 1990 and rev["USD"]["gross_minor"] == 2500,
   "metrics: receita por moeda, sem somar moedas diferentes")
ok(rev["BRL"]["payers"] == 1 and rev["BRL"]["arppu_minor"] == 1990,
   "metrics: ARPPU sai da fila (1 pagante = bruto)")
ok(rev["BRL"]["purchases"] == 1,
   "metrics: grant pendurado no mesmo payment não vira duas compras")
ok("9999" not in json.dumps(rev),
   "metrics: grant ainda não processado não conta como receita")
ok(m["sales_by_sku"]["vip.1mo"]["gross_minor"] == 1990
   and m["sales_by_sku"]["vip.1mo"]["units"] == 227,
   "metrics: por SKU o dinheiro e a unidade de jogo aparecem separados")
ok(m["multi_account_suspicions"] == [{"fingerprint": "maquina-compartilhada",
                                      "account_count": 3}],
   "metrics: a suspeita de multi-conta roda na coluna real (não derruba /metrics)")
con5.close()
os.unlink(tmp5.name)

# resumo
if FAILS:
    print("== COMPANION: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== COMPANION: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)
