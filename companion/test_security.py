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

Parte B — checkout com binding de sessão (9 casos):
  1. usuário A cria checkout p/ A (token válido) → 200, preço do catálogo;
  2. usuário A tenta checkout p/ B → 403, sem chamar a API do MP;
  3. sem token → 401;
  4. SKU válido → preço exclusivamente do catálogo/server;
  5. preço enviado pelo cliente é ignorado (não altera a preferência);
  6. external_reference permanece vinculado à conta dona do token;
  7. sessão HMAC do game (forma nova, AUTH-P0) → 200 — é a perna que faltava
     no P0-1: sem ela todo cliente com sessão recém-emitida tomava 401;
  8. mesmo HMAC com account_id divergente → 403 (cross-account);
  9. token sem linha em nenhuma das duas formas (forjado) → 401.
  B1-B6 mantêm viva a perna legada sha256 da migração: é ela que morre sozinha
  com a expiração de 30 dias, não com um corte de deploy.

Parte C — gate de idade/LGPD (Lei 15.211/2025) na porta do dinheiro (6 checagens):
  aceite desatualizado recusa preferência e intent sem chegar ao gateway; conta
  vigente continua comprando; catálogo sem a declaração fecha a porta; e o
  webhook continua creditando (dinheiro já tomado não se descarta).

Parte D — chave de comentário do catálogo não é SKU (12 checagens): `_agreements`
  e `_note` vivem no mesmo dict que as portas consultam; nenhuma das três que
  TOMAM dinheiro (intent, preferência, sandbox) aceita uma delas, a que CRÉDITA
  responde 400 em vez de levantar KeyError no handler, `/catalog` não publica
  nenhuma e o arquivo canônico mantém os 11 SKUs cobráveis.

Parte E — POST /push/test é interno e fail-closed (7 checagens): a fila de push
  nunca é fronteira pública, mas mesmo na rede interna do compose o endpoint exige
  token próprio e DESAPARECE (503) sem ele; autenticado, drena com o sender honesto
  e as linhas viram failed('vapid_sender_unimplemented'), nunca sent().

Parte F — a vitrine e o dinheiro respondem pela MESMA temporada (9 checagens): com
  uma linha ativa congelando `pass.s2`, o `/catalog` levantado traz veredito
  booleano em cada `pass_premium` e em nenhum outro SKU, o passe da temporada
  encerrada CONTINUA no corpo (marcado, com o SKU certo), a contagem não muda, a
  recusa do checkout devolve o MESMO motivo que a página anunciou — e as quatro
  leituras do gate no fonte passam o mesmo relógio, para a vitrine não poder ter
  uma régua paralela.

As partes usam servidores HTTP distintos de propósito: D e o arquivo canônico não
precisam de um, E e F levantam o seu (F reaproveita o handler com um banco montado
pela migration REAL de temporada). O banco do fixture principal nunca recebe a
migration de temporada: sem tabela o gate fecha, e nada aqui depende disso.
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

# P0-1 (auditoria 2026-10-04): a signing key é FIXADA aqui, antes do fixture
# montar as linhas e antes do servidor subir — os dois lados (quem grava o
# HMAC no make_db, quem confere em verify_session_token) leem a mesma env no
# mesmo processo, e o valor não depende do shell que roda a suíte.
os.environ[server.TOKEN_SIGNING_KEY_ENV] = "shambleta-test-signing-key"

FAILS = []
CHECKS = 0
MP_SECRET = "mp-webhook-secret"
MP_TOKEN = "MP-ACCESS-TOKEN"
NOW = int(time.time())
AGR = server.DEFAULT_CATALOG["_agreements"]


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
    # As três colunas de aceite são as reais (migrations 020 + 046): a porta do
    # dinheiro compara igualdade com o bloco `_agreements` do catálogo, então o
    # fixture declara as versões vindas de lá — copiar literal aqui deixaria o
    # teste passando depois de um bump.
    con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, "
                "username TEXT, created_timestamp INTEGER, "
                "consent_tos_version TEXT NOT NULL DEFAULT '', "
                "consent_privacy_version TEXT NOT NULL DEFAULT '', "
                "consent_age_version TEXT NOT NULL DEFAULT '');")
    con.execute("INSERT INTO account VALUES (1, 'Alice', ?, ?, ?, ?);",
                (NOW, AGR["tos"], AGR["privacy"], AGR["age"]))
    con.execute("INSERT INTO account VALUES (2, 'Bob', ?, ?, ?, ?);",
                (NOW, AGR["tos"], AGR["privacy"], AGR["age"]))
    # Carol é a conta do cenário real: token de sessão ainda válido, aceite na
    # versão anterior ao bump — o jogo já a barra no login, a porta do dinheiro
    # não pode deixar passar.
    con.execute("INSERT INTO account VALUES (3, 'Carol', ?, ?, ?, ?);",
                (NOW, AGR["tos"], AGR["privacy"], "2026-01-a"))
    con.execute("CREATE TABLE grant_queue (id INTEGER PRIMARY KEY "
                "AUTOINCREMENT, idempotency_key TEXT NOT NULL UNIQUE, "
                "account_id INTEGER NOT NULL, kind TEXT NOT NULL, "
                "amount INTEGER NOT NULL, payload TEXT, "
                "status TEXT NOT NULL DEFAULT 'pending', "
                "created_at INTEGER NOT NULL, "
                "price_paid INTEGER NOT NULL DEFAULT 0, "
                "currency TEXT NOT NULL DEFAULT '');")
    con.execute("CREATE TABLE auth_token (account_id INTEGER NOT NULL, "
                "token_hash TEXT NOT NULL, ip_address TEXT NOT NULL DEFAULT '',"
                " expires_timestamp INTEGER NOT NULL DEFAULT 0);")
    tok_a = hashlib.sha256(b"tok-Alice").hexdigest()
    tok_b = hashlib.sha256(b"tok-Bob").hexdigest()
    con.execute("INSERT INTO auth_token VALUES (1, ?, '127.0.0.1', ?);",
                (tok_a, NOW + 30 * 86400))
    con.execute("INSERT INTO auth_token VALUES (2, ?, '127.0.0.1', ?);",
                (tok_b, NOW + 30 * 86400))
    con.execute("INSERT INTO auth_token VALUES (3, ?, '127.0.0.1', ?);",
                (hashlib.sha256(b"tok-Carol").hexdigest(), NOW + 30 * 86400))
    con.execute("INSERT INTO auth_token VALUES (1, ?, '127.0.0.1', ?);",
                (hashlib.sha256(b"tok-expired").hexdigest(), NOW - 10))
    # P0-1: linha NOVA no formato que o game grava desde a onda AUTH-P0 —
    # HMAC-SHA256 do token com a signing key, não sha256 cru. O checkout
    # aceitava só a forma antiga e morria para toda sessão recém-emitida.
    tok_hmac = hmac.new(os.environ[server.TOKEN_SIGNING_KEY_ENV].encode("utf-8"),
                        b"tok-HMAC", hashlib.sha256).hexdigest()
    con.execute("INSERT INTO auth_token VALUES (1, ?, '127.0.0.1', ?);",
                (tok_hmac, NOW + 30 * 86400))
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
            "external_reference": ref, "transaction_amount": amount,
            "currency_id": "BRL"}


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
    # K1: amount é o que o JOGO concede; price_paid é o que o provedor COBROU.
    # Sem a segunda coluna nenhuma métrica de receita existe (ARPU/ARPPU/LTV).
    con = sqlite3.connect(DB_PATH)
    paid = con.execute("SELECT price_paid, currency FROM grant_queue "
                       "WHERE idempotency_key = 'pay-ok';").fetchone()
    con.close()
    ok(paid[0] == 1990 and paid[1] == "BRL",
       "A1 o valor pago (centavos + moeda) é registrado junto do grant")

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

    # P0-1 (auditoria 2026-10-04): a perna que faltava. A sessão que o game
    # emite HOJE é HMAC-SHA256 com a signing key (AUTH-P0); B1..B6 acima provam
    # a perna legada (sha256, linhas anteriores à onda) e estas três provam a
    # nova forma, o cross-account dela e o negativo (forjado sem linha).
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-HMAC", "account_id": 1,
                      "sku": "gems.550"})
    ok(code == 200 and res.get("external_reference") == "1:gems.550",
       "B7 sessão HMAC do game é aceita no checkout (P0-1)")
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-HMAC", "account_id": 2,
                      "sku": "gems.550"})
    ok(code == 403, "B8 HMAC cross-account → 403")
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-forged", "account_id": 1,
                      "sku": "gems.550"})
    ok(code == 401, "B9 token forjado (sem linha em nenhuma das duas formas) → 401")

    # P1-A (auditoria 2026-10-06): a perna legada tem data de desmonte. Direto
    # na função — a rota HTTP usa o relógio real e a data é outra coisa; aqui
    # `now` é parâmetro. O fixture grava expiração relativa ao run, então as
    # três linhas valem em qualquer dia: o que muda é a perna, não a janela.
    con_leg = sqlite3.connect(DB_PATH)
    DEADLINE = server.LEGACY_SHA256_LEG_RETIRE_UNIX
    ok(server.verify_session_token(con_leg, 1, "tok-Alice", now=DEADLINE - 60) == 1,
       "B10 antes do desmonte, linha legada ainda compra (janela de expiração natural)")
    ok(server.verify_session_token(con_leg, 1, "tok-Alice", now=DEADLINE) is None,
       "B11 no dia do desmonte a perna legada está morta (ninguém compra com sha256 cru)")
    ok(server.verify_session_token(con_leg, 1, "tok-HMAC", now=DEADLINE + 3600) == 1,
       "B12 HMAC sobrevive ao desmonte da perna (a TTL continua cobrada no SQL)")
    con_leg.close()

    # ===== Parte C — gate de idade/LGPD (Lei 15.211/2025) na porta do dinheiro =====
    # Carol tem token de sessão válido e aceite de antes do bump: o game server a
    # barra no login, então a outra porta não pode abrir checkout para ela.
    n_pref = len(PREF_CALLS)
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Carol", "account_id": 3,
                      "sku": "gems.550"})
    ok(code == 403 and res.get("error") == "consent_required",
       "C1 aceite desatualizado → 403 consent_required")
    ok(len(PREF_CALLS) == n_pref,
       "C1 recusa acontece antes de abrir preferência no gateway")
    code, res = post("/checkout/intents",
                     {"auth_token": "tok-Carol", "sku": "gems.550"})
    ok(code == 403 and res.get("error") == "consent_required",
       "C2 intent também recusa sem aceite vigente")
    code, res = post("/checkout/preference",
                     {"auth_token": "tok-Alice", "account_id": 1,
                      "sku": "gems.550"})
    ok(code == 200, "C3 conta com o aceite vigente continua comprando")

    # Fail-closed dos dois lados do contrato: catálogo sem a declaração não é
    # "nenhuma cobrança" — é porta fechada até alguém declarar a versão vigente.
    saved_catalog = HTTPD.catalog
    try:
        HTTPD.catalog = {k: v for k, v in saved_catalog.items()
                         if k != "_agreements"}
        code, res = post("/checkout/preference",
                         {"auth_token": "tok-Alice", "account_id": 1,
                          "sku": "gems.550"})
        ok(code == 403, "C4 catálogo sem _agreements fecha a porta (fail-closed)")
    finally:
        HTTPD.catalog = saved_catalog

    # Assimétrico de propósito: o webhook NÃO é gated. Lá o dinheiro já foi
    # tomado, e recusar seria descartar a entrega de quem pagou.
    PAYMENTS["pay-carol"] = approved_payment("pay-carol", "3:gems.550", 19.90)
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-carol", {},
                     webhook_headers("pay-carol"))
    ok(code == 200 and len(grants()) > n_before,
       "C5 webhook de conta sem aceite vigente ainda credita (pago não se descarta)")

    # ===== Parte D — chave de comentário do catálogo não é SKU cobrável =====
    # O `_agreements` que o gate de aceite passou a ler vive no MESMO dict que as
    # três portas consultavam por membership (`sku not in catalog`). Medido antes
    # da correção: `build_preference_payload(cat, "_agreements")` devolvia payload
    # com `unit_price` 0.0 — cobrar zero é entregar de graça, e sem `kind`/
    # `amount` não há o que conceder — e `_note` derrubava o handler com
    # AttributeError antes de qualquer resposta. Hoje a porta exige forma de
    # produto, com a mesma predicate que `load_catalog` usa no arquivo.
    for ghost in ("_agreements", "_note"):
        n_pref = len(PREF_CALLS)
        n_grants = len(grants())
        code, res = post("/checkout/preference",
                         {"auth_token": "tok-Alice", "account_id": 1,
                          "sku": ghost})
        ok(code == 400 and res.get("error") == "unknown_sku",
           "D1 %s não abre preferência no gateway" % ghost)
        ok(len(PREF_CALLS) == n_pref and len(grants()) == n_grants,
           "D1 %s não cria preferência nem enfileira grant" % ghost)
        code, res = post("/checkout/intents",
                         {"auth_token": "tok-Alice", "sku": ghost})
        ok(code == 400 and res.get("error") == "unknown_sku",
           "D2 intent recusa %s" % ghost)

    saved_dev, saved_secret = HTTPD.allow_dev_checkout, HTTPD.secret
    try:
        HTTPD.allow_dev_checkout = True
        HTTPD.secret = "dev-shared"
        body = {"sku": "_agreements", "account_id": 1,
                "idempotency_key": "ghost-1"}
        raw = json.dumps(body).encode()
        code, res = post("/checkout/simulate", body, {"X-Signature": hmac.new(
            b"dev-shared", raw, hashlib.sha256).hexdigest()})
        ok(code == 400 and res.get("error") == "unknown_sku",
           "D3 sandbox também não aceita chave de comentário")
        ok(not grants("ghost-1"), "D3 nenhuma grant row nascida do SKU fantasma")
    finally:
        HTTPD.allow_dev_checkout, HTTPD.secret = saved_dev, saved_secret

    # A porta que CRÉDITA vale igual: um evento cujo `external_reference` apontasse
    # para a declaração levantava KeyError dentro do handler — o provedor reenvia
    # para sempre um evento que nunca vai passar — em vez de um 400 limpo.
    PAYMENTS["pay-ghost"] = approved_payment("pay-ghost", "1:_agreements", 19.90)
    n_before = len(grants())
    code, res = post("/webhooks/payments?data.id=pay-ghost", {},
                     webhook_headers("pay-ghost"))
    ok(code == 400 and res.get("error") == "unknown_sku",
       "D4 webhook com SKU de comentário responde 400 limpo (não KeyError)")
    ok(len(grants()) == n_before, "D4 nada concedido pelo SKU fantasma")

    with urllib.request.urlopen(BASE + "/catalog", timeout=10) as resp:
        pub = json.loads(resp.read().decode())["catalog"]
    ok(not [k for k in pub if k.startswith("_")],
       "D5 /catalog não publica declaração de comentários como item de loja")
    ok(len(pub) == len([k for k in HTTPD.catalog
                        if not k.startswith("_")]),
       "D5 /catalog continua publicando todos os SKUs cobráveis")
finally:
    server.mp_fetch_payment = _real_fetch
    server.mp_create_preference = _real_pref
    HTTPD.shutdown()
    try:
        os.unlink(DB_PATH)
    except OSError:
        pass

# O arquivo canônico é a fonte das duas coisas: o `_agreements` que o gate lê e
# os SKUs que a loja pode cobrar. Um guard que confunda as duas tranca a loja —
# medido aqui, no caminho de leitura real (`load_catalog`), não no dict embutido.
_file_cat = server.load_catalog(os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "conf", "paid_catalog.json"))
_real_skus = [k for k in _file_cat if not k.startswith("_")]
ok(_real_skus and all(server.is_sellable_sku(_file_cat, k) for k in _real_skus),
   "D6 todo SKU do arquivo canônico continua cobrável (guard não fecha a loja)")
ok(not any(server.is_sellable_sku(_file_cat, k)
           for k in _file_cat if k.startswith("_")),
   "D6 nenhuma chave de comentário do arquivo é cobrável")
ok(isinstance(_file_cat.get("_agreements"), dict)
   and all(_file_cat["_agreements"].get(v)
           for v in ("tos", "privacy", "age")),
   "D6 o arquivo canônico declara as três versões vigentes")

# ---- Parte E — SOM-W5: POST /push/test é interno e fail-closed (7 checagens)
# A fila de push nunca é fronteira pública (o nginx proxya /checkout, /webhooks e
# as duas leituras GET — /push/vapid e /catalog — nunca /push/test), mas mesmo na
# rede interna do compose o endpoint exige token próprio e DESAPARECE (503) quando
# o token não foi configurado — nada roda "por padrão". O caminho autenticado drena
# com o sender honesto: as linhas viram failed('vapid_sender_unimplemented'),
# nunca sent().
import glob as _globw5
import io as _iow5

_w5dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "data", "conf", "migrations")
_w5migs = sorted(_globw5.glob(os.path.join(_w5dir, "*_web_push.sql")))


def _w5db(with_tables=True):
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY,"
                " last_timestamp INTEGER DEFAULT 0)")
    if with_tables:
        con.executescript(open(_w5migs[0]).read())
        con.execute("INSERT INTO account VALUES (1, ?)", (int(time.time()),))
        con.execute("INSERT INTO push_subscription VALUES "
                    "(1, 'https://p/1', 'K', 'A', 0)")
        con.execute("INSERT INTO push_outbox (account_id, title, body, status,"
                    " created_at) VALUES (1, 't', 'b', 'pending',"
                    " strftime('%s','now'))")
    con.commit()
    con.close()
    return path


class _PushSent:
    code = None
    obj = None


class _PushSrv:
    def __init__(self, token, db):
        self.store = server.Store(db)
        self.push_admin_token = token


def _push_call(token, db, headers=None, body=b""):
    os.environ.pop("SHAMBLETA_PUSH_SENDER", None)  # sender default = honesto
    _PushSent.code = None
    _PushSent.obj = None
    h = server.Handler.__new__(server.Handler)
    h.server = _PushSrv(token, db)
    h.headers = dict(headers or {})
    h.rfile = _iow5.BytesIO(body)
    h._send = lambda code, obj: (setattr(_PushSent, "code", code),
                                 setattr(_PushSent, "obj", obj))
    h._push_test()
    return _PushSent.code, _PushSent.obj


_db_e = _w5db()
_c, _o = _push_call("", _db_e)
ok(_c == 503 and _o.get("error") == "push_disabled",
   "E1 /push/test sem token configurado não existe (503, default fechado)")
_c, _o = _push_call("sekret", _db_e)
ok(_c == 401 and _o.get("error") == "bad_token",
   "E2 token configurado, header ausente -> 401")
_c, _o = _push_call("sekret", _db_e, {"X-Push-Token": "errado"})
ok(_c == 401, "E3 header errado -> 401 (nada drena)")
_c, _o = _push_call("sekret", _db_e, {"X-Push-Token": "sekret"})
ok(_c == 200 and _o.get("sender") == "vapid" and _o["drain"]["failed"] == 1
   and _o["drain"]["sent"] == 0,
   "E4 autenticado: drena com o sender honesto (failed, nunca sent)")
_c, _o = _push_call("sekret", _db_e, {"X-Push-Token": "sekret",
                                      "Content-Length": str(len(b'{"limit":"x"}'))},
                    body=b'{"limit":"x"}')
ok(_c == 400 and _o.get("error") == "bad_grant", "E5 limit inválido -> 400")
_c, _o = _push_call("sekret", _w5db(with_tables=False),
                    {"X-Push-Token": "sekret"})
ok(_c == 500 and "052" in str(_o.get("hint", "")),
   "E6 banco sem a migration 052 -> db_error com hint, nunca sucesso silencioso")
_cone = sqlite3.connect(_db_e)
ok(_cone.execute("SELECT status, last_error FROM push_outbox").fetchone()
   == ("failed", "vapid_sender_unimplemented"),
   "E7 a fila registra o motivo técnico da não-entrega (auditável)")
_cone.close()
os.unlink(_db_e)

# ===== Parte F — a vitrine e o dinheiro respondem pela MESMA temporada (9 checagens)
# O gate que RECUSA (`season_offer_status`) já existia, e `/catalog` já mostrava
# preço; o que não existia era a temporada dentro do corpo público. O defeito
# medido aqui é o par que essa ausência abre: a página anunciando `pass.s1` — e o
# botão apontando para ele — enquanto o checkout devolve 409 `season_mismatch`. Na
# frente do dinheiro, 409 não é erro do usuário: é a loja errando no preço.
# Diferente da parte D, isto precisa de servidor vivo, então o `HTTPD` lá de cima
# é REAPROVEITADO contra um banco novo, montado pela migration REAL de temporada e
# derrubado no fim. O primeiro banco não recebeu a migration de propósito: sem
# tabela, o gate fecha (é a régua 7 de `test_season_offer.py`) e nada aqui depende
# de um season row que o fixture não tem.
DB_F = make_db()
HTTPD_F = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
HTTPD_F.daemon_threads = True
HTTPD_F.store = server.Store(DB_F)
HTTPD_F.secret = ""
HTTPD_F.provider = "mercadopago"
HTTPD_F.stripe_secret = ""
HTTPD_F.mp_secret = MP_SECRET
HTTPD_F.mp_access_token = MP_TOKEN
HTTPD_F.allow_unverified = False
HTTPD_F.allow_dev = False
HTTPD_F.allow_dev_checkout = False
HTTPD_F.mp_back_urls_base = ""
HTTPD_F.catalog = dict(server.DEFAULT_CATALOG)
HTTPD_F.tolerance = 300
_PORT_F = HTTPD_F.server_address[1]
_BASE_SAVED = BASE
BASE = "http://127.0.0.1:%d" % _PORT_F
threading.Thread(target=HTTPD_F.serve_forever, daemon=True).start()
try:
    _conF = sqlite3.connect(DB_F)
    _conF.executescript(open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "data", "conf", "migrations", "018_guild_season_ah.sql"),
        encoding="utf-8").read())
    _conF.execute("INSERT INTO season (season_id, starts_at, ends_at, rules_frozen,"
                  " status) VALUES (?, ?, ?, ?, 'active');",
                  (91, NOW - 3600, NOW + 30 * 86400,
                   '{"config_id": "s2", "premium_sku": "pass.s2"}'))
    _conF.commit()
    _conF.close()

    with urllib.request.urlopen(BASE + "/catalog", timeout=10) as resp:
        bodyF = json.loads(resp.read().decode())["catalog"]
    passesF = [k for k, v in HTTPD_F.catalog.items()
               if v.get("kind") == "pass_premium" and not k.startswith("_")]
    ok(passesF and all(isinstance(bodyF[k].get("season_eligible"), bool)
                       for k in passesF),
       "F1 /catalog traz veredito booleano para cada um dos %d passes" % len(passesF))
    ok(not [k for k in bodyF if k not in passesF and "season_eligible" in bodyF[k]],
       "F1 e nenhum SKU fora do gate de temporada sai anotado")
    ok(bodyF["pass.s1"]["season_eligible"] is False
       and bodyF["pass.s1"]["season_reason"] == "season_mismatch"
       and bodyF["pass.s1"]["season_premium_sku"] == "pass.s2",
       "F2 o passe da temporada encerrada CONTINUA na vitrine, marcado e com o SKU certo")
    ok(bodyF["pass.s2"]["season_eligible"] is True and bodyF["pass.s2"]["season_id"] == 91,
       "F2 e o da temporada no ar sai elegível, com a temporada no corpo")
    ok(len(bodyF) == len([k for k in HTTPD_F.catalog if not k.startswith("_")]),
       "F3 temporada ativa não esconde item nenhum da vitrine (%d no corpo)" % len(bodyF))
    code, res = post("/checkout/intents",
                     {"auth_token": "tok-Alice", "sku": "pass.s1"})
    ok(code == 409 and res.get("error") == bodyF["pass.s1"]["season_reason"],
       "F4 a recusa do dinheiro é o MESMO motivo que a vitrine anuncia")
    code, res = post("/checkout/intents",
                     {"auth_token": "tok-Alice", "sku": "pass.s2"})
    ok(code == 200 and res.get("season_offer", {}).get("season_id") == 91,
       "F5 o verde da vitrine é real: o passe da temporada no ar passa pela porta do dinheiro")
finally:
    BASE = _BASE_SAVED
    HTTPD_F.shutdown()
    try:
        os.unlink(DB_F)
    except OSError:
        pass

# Uma resposta, quatro leituras: a marca que a página mostra e o veredito que cobra
# têm de vir da MESMA chamada, com o MESMO catálogo e o MESMO relógio. É a régua que
# impede alguém "consertar" a vitrine com uma segunda implementação paralela — o
# jeito mais fácil de voltar a mentir sem que nenhum dos dois lados esteja errado
# sozinho.
_srcF = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py"),
             encoding="utf-8").read()
_callsF = [ln.strip() for ln in _srcF.splitlines()
           if "season_offer_status(" in ln and not ln.strip().startswith("def ")]
ok(len(_callsF) == 4,
   "F6 quatro leituras do gate no companion: uma vitrine e três portas de dinheiro (%d)"
   % len(_callsF))
ok(all(c.split("season_offer_status(")[1].split(")")[0].count(",") == 2 for c in _callsF),
   "F6 nenhuma delas passa relógio próprio: as quatro decidem no mesmo `now`")

if FAILS:
    print("== SECURITY: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== SECURITY: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)