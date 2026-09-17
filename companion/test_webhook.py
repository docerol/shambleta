#!/usr/bin/env python3
"""Testes do hardening do webhook (SOM-IDLE 1c). Sem pytest: python3
companion/test_webhook.py. Sai !=0 se falhar."""
import hashlib
import hmac
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
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL);")
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

filecat = server.load_catalog(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                           "catalog.json"))
ok("starter.pack" in filecat and "founder.pack" in filecat,
   "catalog.json loads with starter/founder")
ok(server.resolve_grant_items(filecat, "founder.pack")
   == [("gems", 1200), ("vip_days", 30)], "catalog.json founder bundle")
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
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL);")
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

# resumo
if FAILS:
    print("== COMPANION: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== COMPANION: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)
