#!/usr/bin/env python3
"""Shambleta companion v0 — fronteira de dinheiro real (SOM-IDLE C1).

Recebe webhooks de pagamento (Mercado Pago / Stripe / Pix sandbox) e grava
grants idempotentes na tabela grant_queue do MESMO SQLite do game server (modo
WAL). O game server consome a fila e espelha tudo no ledger; o companion nunca
toca em outras tabelas e nunca recebe estado de jogo.

Uso:
    # produção Mercado Pago (assinatura x-signature + re-fetch autoritativo):
    SHAMBLETA_WEBHOOK_PROVIDER=mercadopago \
    SHAMBLETA_MP_WEBHOOK_SECRET=<credencial do endpoint> \
    SHAMBLETA_MP_ACCESS_TOKEN=<access_token> \
    python3 companion/server.py --db /data/live.db --port 8901
      # MP manda x-signature: ts=...,v1=... (HMAC sobre o manifest
      # id:<data.id>;request-id:<x-request-id>;ts:<ts>;). O companion valida a
      # assinatura e RE-BUSCA o pagamento na API MP (autoritativo): status
      # approved + external_reference="<account_id>:<sku>". Sem access_token usa
      # o corpo plano (só sandbox/teste). O grant usa kind/amount do CATÁLOGO.

    # alternativa Stripe (assinatura Stripe-Signature + catálogo autoritativo):
    SHAMBLETA_WEBHOOK_PROVIDER=stripe SHAMBLETA_STRIPE_WEBHOOK_SECRET=whsec_xxx \
    python3 companion/server.py --db /data/live.db
      # Stripe manda Stripe-Signature: t=...,v1=... ; o checkout define
      # metadata.shambleta_sku + client_reference_id=<account_id>.

    # sandbox/dev (assinatura por segredo compartilhado, payload plano) — só
    # com opt-in explícito:
    SHAMBLETA_WEBHOOK_PROVIDER=shared SHAMBLETA_WEBHOOK_SECRET=xxx \
    SHAMBLETA_ALLOW_DEV_WEBHOOK=1 python3 companion/server.py --db /data/live.db
      curl -X POST localhost:8901/webhooks/payments \
        -H 'X-Signature: <hmac-sha256-hex do body>' \
        -d '{"idempotency_key":"tx1","username":"Hero","sku":"gems.550"}'

    # Fase A — checkout sandbox (sem credencial MP): a loja pede a intenção e
    # simula o pagamento aprovado; o grant entra pela mesma fila idempotente:
    curl -X POST localhost:8901/checkout/intents \
      -d '{"username":"Hero","sku":"starter.pack"}'
      # → {external_reference: "<account_id>:starter.pack", items, price}
    curl -X POST localhost:8901/checkout/simulate \
      -H 'X-Signature: <hmac do body>' \
      -d '{"username":"Hero","sku":"starter.pack","idempotency_key":"1:starter.pack:pay1"}'
    # Produção troca o simulate pelo checkout MP (mesma external_reference):
    # POST /checkout/preference {username|account_id, sku} → {payment_url}
    # (Checkout Pro, valor do catálogo) + grant pelo webhook do provedor.

Contrato de promoção: reescrever em Go/Node + Postgres quando o CCU exigir
(ARCHITECTURE §11). A tabela grant_queue e a semântica de idempotência não mudam.
"""
import argparse
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

KINDS = ("gems", "gold", "vip_days", "pass_premium", "cosmetic")
DAY = 86400

# --------------------------------------------------------------------------
# SOM-IDLE (1c): webhook hardening — o companion é a fronteira de dinheiro
# real, então NÃO pode confiar num segredo compartilhado genérico nem num
# "amount" vindo do corpo (qualquer um com o segredo mintaria qualquer valor
# para qualquer conta). Duas garantias:
#   1. A assinatura é verificada com o esquema do PROVEDOR (Stripe hoje) com
#      janela anti-replay; o segredo compartilhado vira apenas "modo dev".
#   2. A quantidade concedida vem do CATÁLOGO de SKUs (server-authoritative);
#      o corpo só pode REFERENCIAR um SKU, nunca ditar o montante.
# --------------------------------------------------------------------------

# Catálogo canônico (SKU -> o que comprar). Sobrescreva com um JSON via
# SHAMBLETA_CATALOG_FILE / --catalog quando o checkout real existir. O preço
# (`price`) fica aqui só p/ auditoria/cross-check; o que vira grant é kind+amount.
# Bundles (starter/founder) decompõem em N grants atômicos com chaves derivadas
# "{key}:{i}:{kind}" — o game server processa linha a linha, sem código novo.
DEFAULT_CATALOG = {
    "gems.550":   {"kind": "gems",     "amount": 550,   "currency": "BRL", "price": 19.90},
    "gems.1200":  {"kind": "gems",     "amount": 1200,  "currency": "BRL", "price": 39.90},
    "gems.3000":  {"kind": "gems",     "amount": 3000,  "currency": "BRL", "price": 79.90},
    "vip.1mo":    {"kind": "vip_days", "amount": 30,    "currency": "BRL", "price": 24.90},
    "vip.3mo":    {"kind": "vip_days", "amount": 90,    "currency": "BRL", "price": 59.90},
    # Fase C (passe S1, BATTLE_PASS_S1 §1): premium da temporada ativa.
    "pass.s1":    {"kind": "pass_premium", "amount": 1, "currency": "BRL", "price": 24.90},
    # Follow-up Deluxe: premium + 10 níveis + emote + 150 gems (preço sugerido
    # no doc, dono confirma). O tier viaja no payload p/ o grant aplicar.
    "pass.s1.deluxe": {"kind": "pass_premium", "amount": 1, "currency": "BRL", "price": 44.90,
                       "tier": "deluxe"},
    # Fase F (doação, MONETIZATION §1 item 12): Pix direto com contrapartida
    # cosmética mínima (título Apoiador, sem poder).
    "donate.support": {"kind": "cosmetic", "amount": 1, "currency": "BRL", "price": 4.90,
                       "cosmetic_id": "title_apoiador"},
    # MONETIZATION §2.3: one-time D0–D3, VIP 7d + 220 gems + cosmético "Recruta"
    # (o cosmético entra como entitlement na Fase D; o payload marca o direito).
    "starter.pack": {"kind": "bundle",
                     "contents": [{"kind": "vip_days", "amount": 7},
                                  {"kind": "gems", "amount": 220}],
                     "currency": "BRL", "price": 9.90,
                     "one_time": True, "max_account_age": 3 * DAY,
                     "title": "Recruta (pending entitlements)"},
    # MONETIZATION §1 item 14: apoio no beta, título "Fundador".
    "founder.pack": {"kind": "bundle",
                     "contents": [{"kind": "gems", "amount": 1200},
                                  {"kind": "vip_days", "amount": 30}],
                     "currency": "BRL", "price": 39.90,
                     "one_time": True,
                     "title": "Fundador (pending entitlements)"},
}


def _valid_item(e):
    if not (isinstance(e, dict) and e.get("kind") in KINDS
            and isinstance(e.get("amount"), int) and e["amount"] > 0):
        return False
    if e.get("kind") == "cosmetic" and not e.get("cosmetic_id"):
        return False
    return True


def load_catalog(path):
    if not path:
        return dict(DEFAULT_CATALOG)
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    for sku, e in raw.items():
        if sku.startswith("_"):
            continue  # comentário/documentação, não SKU
        if not isinstance(e, dict):
            raise ValueError("catalog entry %r invalid" % sku)
        if e.get("kind") == "bundle":
            contents = e.get("contents")
            if (not isinstance(contents, list) or not contents
                    or not all(_valid_item(c) for c in contents)):
                raise ValueError("catalog bundle %r invalid" % sku)
        elif not _valid_item(e):
            raise ValueError("catalog entry %r invalid" % sku)
    return raw


class CatalogError(Exception):
    pass


# (3c) hook de alerta/uptime opt-in: se SHAMBLETA_ALERT_WEBHOOK estiver setado
# (ex.: healthchecks.io/Discord), melhor-esforço um POST JSON. Nunca bloqueia o
# request (thread própria + timeout curto) nem levanta — alertas são side-channel.
ALERT_URL = os.environ.get("SHAMBLETA_ALERT_WEBHOOK", "")


def alert(message, level="warn"):
    if not ALERT_URL:
        return
    import threading
    from urllib.request import Request, urlopen

    def _send():
        try:
            payload = json.dumps({"source": "shambleta-companion",
                                  "level": level, "message": message,
                                  "at": int(time.time())}).encode()
            req = Request(ALERT_URL, data=payload,
                          headers={"Content-Type": "application/json"})
            urlopen(req, timeout=5).read()
        except Exception:
            pass  # alertas nunca derrubam o serviço

    threading.Thread(target=_send, daemon=True).start()



def resolve_grant(catalog, sku, claimed_amount=None):
    """Devolve (kind, authoritative_amount). Nunca usa claimed_amount como fonte
    de verdade — só como cross-check (CDC: preço anunciado = preço cobrado)."""
    if not sku or sku not in catalog:
        raise CatalogError("unknown_sku")
    entry = catalog[sku]
    if entry.get("kind") == "bundle":
        raise CatalogError("use_grant_items")
    amount = entry["amount"]
    if claimed_amount is not None and claimed_amount != amount:
        raise CatalogError("amount_mismatch")
    return entry["kind"], amount


def resolve_grant_items(catalog, sku, claimed_amount=None):
    """Devolve [(kind, amount), ...] — 1 item p/ SKU simples, N p/ bundle.
    Chaves derivadas ficam com o chamador: '{key}' p/ item único,
    '{key}:{i}:{kind}' p/ bundles (redelivery gera as mesmas chaves)."""
    if not sku or sku not in catalog:
        raise CatalogError("unknown_sku")
    entry = catalog[sku]
    if entry.get("kind") == "bundle":
        if claimed_amount is not None:
            raise CatalogError("amount_mismatch")
        return [(c["kind"], c["amount"]) for c in entry["contents"]]
    return [resolve_grant(catalog, sku, claimed_amount)]


def starter_offer_status(con, catalog, account_id, sku="starter.pack", now=None):
    """Elegibilidade da oferta one-time (starter D0–D3). Retorna
    {eligible, reason, expires_at}. Sem migração: idade via
    account.created_timestamp + compra prévia via grant_queue payload."""
    if now is None:
        now = int(time.time())
    entry = catalog.get(sku) or {}
    if not entry.get("one_time"):
        return {"eligible": True, "reason": "not_limited", "expires_at": 0}
    row = con.execute("SELECT created_timestamp FROM account WHERE account_id = ?;",
                      (account_id,)).fetchone()
    if row is None:
        return {"eligible": False, "reason": "unknown_account", "expires_at": 0}
    created = row[0] or now
    prior = con.execute(
        "SELECT COUNT(*) FROM grant_queue WHERE account_id = ? AND payload LIKE ? "
        "AND status IN ('pending', 'processed');",
        (account_id, '%"sku": "' + sku + '"%')).fetchone()
    if prior and prior[0] > 0:
        return {"eligible": False, "reason": "already_claimed", "expires_at": 0}
    max_age = int(entry.get("max_account_age") or 0)
    expires_at = created + max_age if max_age else 0
    if max_age and now > expires_at:
        return {"eligible": False, "reason": "expired", "expires_at": expires_at}
    return {"eligible": True, "reason": "ok", "expires_at": expires_at}


def _const_time(a, b):
    return hmac.compare_digest(a.encode() if isinstance(a, str) else a,
                               b.encode() if isinstance(b, str) else b)


def verify_shared_secret(secret, header_value, raw_body):
    """Esquema legado/sandbox: X-Signature = hex(HMAC-SHA256(secret, body))."""
    if not secret:
        return False
    expect = hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return _const_time(header_value or "", expect)


def verify_stripe_signature(secret, header_value, raw_body, tolerance=300, now=None):
    """Esquema oficial Stripe: Stripe-Signature: 't=<ts>,v1=<sig>' onde
    sig = hex(HMAC-SHA256(secret, '<ts>.<body>')). Recusa ts fora da janela
    (anti-replay). Aceita se QUALQUER v1 bater."""
    if not secret or not header_value:
        return False
    ts = None
    v1 = []
    for part in header_value.split(","):
        part = part.strip()
        if part.startswith("t="):
            ts = part[2:]
        elif part.startswith("v1="):
            v1.append(part[3:])
    if ts is None or not v1:
        return False
    try:
        ts_int = int(ts)
    except ValueError:
        return False
    if now is None:
        now = int(time.time())
    if abs(now - ts_int) > tolerance:
        return False
    signed = ("%d." % ts_int).encode() + raw_body
    expect = hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
    return any(_const_time(s, expect) for s in v1)


def _mp_manifest(data_id, request_id, ts):
    """Mercado Pago: 'id:<data.id>;request-id:<x-request-id>;ts:<ts>;' — cada
    seção termina em ';' e é OMITIDA se o valor estiver ausente (esquema oficial).
    data.id é minúsculo se alfanumérico."""
    if data_id and data_id.isalnum():
        data_id = data_id.lower()
    parts = []
    if data_id:
        parts.append("id:%s;" % data_id)
    if request_id:
        parts.append("request-id:%s;" % request_id)
    if ts:
        parts.append("ts:%s;" % ts)
    return "".join(parts)


def verify_mercadopago_signature(secret, header_value, request_id, data_id,
                                 tolerance=300, now=None):
    """Esquema oficial MP (x-signature: 'ts=<ts>,v1=<sig>'):
    sig = hex(HMAC-SHA256(secret, _mp_manifest(data_id, request_id, ts))).
    Recusa ts fora da janela (anti-replay). Aceita se QUALQUER v1 bater."""
    if not secret or not header_value:
        return False
    ts = None
    v1 = []
    for part in header_value.split(","):
        part = part.strip()
        if part.startswith("ts="):
            ts = part[3:]
        elif part.startswith("v1="):
            v1.append(part[3:])
    if ts is None or not v1:
        return False
    try:
        ts_int = int(ts)
    except ValueError:
        return False
    if now is None:
        now = int(time.time())
    if abs(now - ts_int) > tolerance:
        return False
    expect = hmac.new(secret.encode(),
                      _mp_manifest(data_id, request_id, ts).encode(),
                      hashlib.sha256).hexdigest()
    return any(_const_time(s, expect) for s in v1)


def parse_external_reference(external_reference):
    """Checkout define external_reference = '<account_id>:<sku>'. Retorna
    (account_id:int|None, sku:str|None)."""
    if not external_reference or ":" not in str(external_reference):
        return None, None
    acct, _, sku = str(external_reference).partition(":")
    acct = acct.strip()
    sku = sku.strip()
    return (int(acct) if acct.isdigit() else None), (sku or None)


def mp_fetch_payment(payment_id, access_token):
    """Re-fetch autoritativo na API MP (padrão oficial): o corpo do webhook só traz
    data.id; o status/valor/external_reference vêm daqui (TLS MP). Retorna dict ou None."""
    if not payment_id or not access_token:
        return None
    import urllib.request
    import urllib.parse
    url = ("https://api.mercadopago.com/v1/payments/%s?access_token=%s"
           % (urllib.parse.quote(str(payment_id)), urllib.parse.quote(access_token)))
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:  # rede/JSON/HTTP → None (MP reenvia)
        alert("mercadopago refetch failed: %s" % e)
        return None


def mp_refund_payment(payment_id, access_token):
    """Estorno do DINHEIRO no Mercado Pago (follow-up do RequestGemRefund, que
    reverte as gems no jogo). Retorna True se a API aceitou (2xx). Fail-closed
    sem token; nunca levanta (chamador registra e tenta de novo no próximo
    sweep)."""
    if not payment_id or not access_token:
        return False
    import urllib.request
    import urllib.parse
    url = ("https://api.mercadopago.com/v1/payments/%s/refunds?access_token=%s"
           % (urllib.parse.quote(str(payment_id)), urllib.parse.quote(access_token)))
    try:
        req = urllib.request.Request(url, data=b"{}",
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except Exception as e:
        alert("mercadopago refund failed: %s" % e)
        return False


def build_preference_payload(catalog, sku, external_reference, back_urls_base=""):
    """Monta o corpo da preferência Checkout Pro (puro, testável sem rede).

    O valor vem do CATÁLOGO (nunca do cliente). Retorna (payload, error):
    payload é o dict p/ POST /checkout/preferences; error é None em sucesso
    ou 'unknown_sku' quando o SKU não existe no catálogo."""
    if not sku or sku not in catalog:
        return None, "unknown_sku"
    entry = catalog[sku]
    title = str(entry.get("title") or entry.get("label") or sku)
    price = float(entry.get("price", 0.0))
    currency = str(entry.get("currency", "BRL"))
    item = {"title": "%s (%s)" % (title, sku), "quantity": 1,
            "unit_price": price, "currency_id": currency}
    payload = {"items": [item], "external_reference": external_reference}
    base = (back_urls_base or "").strip().rstrip("/")
    if base:
        ret = base + "/checkout_return.html"
        payload["back_urls"] = {"success": ret, "pending": ret,
                                "failure": ret}
        payload["auto_return"] = "approved"
    return payload, None


def mp_create_preference(payload, access_token):
    """Cria a preferência real na API do Mercado Pago (Checkout Pro).

    Retorna o dict da resposta (com init_point/sandbox_init_point) ou None
    em falha (o chamador responde 502; o MP/webhook re-tenta do lado cliente).
    Fail-closed sem token; nunca levanta."""
    if not payload or not access_token:
        return None
    import urllib.request
    url = "https://api.mercadopago.com/checkout/preferences"
    try:
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + access_token},
            method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        alert("mercadopago preference failed: %s" % e)
        return None


def refund_sweep(db_path, access_token, dry_run=False):
    """Uma passada de estornos: grants 'refunded' (CDC, jogo já reverteu as
    gems) ainda não notificados ao MP. Retorna {pending, notified, skipped}.
    Só toca provider=mercadopago (sandbox/shared não têm dinheiro de verdade).
    Exige opt-in explícito (SHAMBLETA_MP_REFUNDS=1) — dinheiro real nunca se
    move por acidente."""
    if os.environ.get("SHAMBLETA_MP_REFUNDS", "") != "1" and not dry_run:
        raise RuntimeError("refunds require SHAMBLETA_MP_REFUNDS=1")
    if not access_token and not dry_run:
        raise RuntimeError("refunds require SHAMBLETA_MP_ACCESS_TOKEN")
    store = Store(db_path)
    result = {"pending": 0, "notified": 0, "skipped": 0}
    with store.connect() as con:
        try:
            rows = con.execute(
                "SELECT idempotency_key, payload FROM grant_queue "
                "WHERE status = 'refunded' AND refund_notified = 0;").fetchall()
        except sqlite3.Error:
            return result  # schema pré-026: nada a fazer
        result["pending"] = len(rows)
        for key, payload in rows:
            try:
                meta = json.loads(payload or "{}")
            except ValueError:
                meta = {}
            if meta.get("provider") != "mercadopago":
                result["skipped"] += 1
                continue
            if dry_run:
                continue
            if mp_refund_payment(key, access_token):
                con.execute("UPDATE grant_queue SET refund_notified = 1 "
                            "WHERE idempotency_key = ?;", (key,))
                con.commit()
                result["notified"] += 1
    return result


def normalize_event(provider, data):
    """Reduz o corpo (formato do provedor OU flat sandbox) a um grant canônico:
    {idempotency_key, account_id, username, sku}. Retorna None se não aplicável."""
    if provider == "stripe":
        # checkout.session.completed → entrega o SKU + a conta no metadata.
        obj = (data.get("data") or {}).get("object") or {}
        meta = obj.get("metadata") or {}
        sku = meta.get("shambleta_sku") or obj.get("sku")
        acct = obj.get("client_reference_id") or meta.get("shambleta_account_id")
        key = data.get("id") or obj.get("id")  # event id = chave idempotente
        user = meta.get("shambleta_username")
        if acct is not None:
            acct = int(acct)
        else:
            acct = None
        return {"idempotency_key": key, "account_id": acct,
                "username": user, "sku": sku}
    if provider == "mercadopago":
        # sandbox/teste: corpo plano já traz os campos.
        if data.get("account_id") is not None or data.get("sku") is not None:
            acct = data.get("account_id")
            return {"idempotency_key": data.get("idempotency_key") or data.get("id"),
                    "account_id": int(acct) if acct is not None else None,
                    "username": data.get("username"), "sku": data.get("sku")}
        # produção: `data` é o PAYMENT re-buscado na API MP (autoritativo).
        status = str(data.get("status", ""))
        if status and status not in ("approved", "authorized_payment"):
            return None  # pendente/recusado/estornado → sem grant
        meta = data.get("metadata") or {}
        acct, sku = parse_external_reference(data.get("external_reference"))
        if sku is None:
            sku = meta.get("shambleta_sku")
        if acct is None and meta.get("shambleta_account_id") is not None:
            acct = int(meta.get("shambleta_account_id"))
        key = data.get("id")  # payment id = chave idempotente
        return {"idempotency_key": str(key) if key is not None else "",
                "account_id": acct, "username": meta.get("shambleta_username"),
                "sku": sku}
    # sandbox / dev / pix-notify simples: payload plano
    acct = data.get("account_id")
    if acct is not None:
        acct = int(acct)
    return {"idempotency_key": data.get("idempotency_key", ""),
            "account_id": acct, "username": data.get("username"),
            "sku": data.get("sku")}


class Store:
    def __init__(self, db_path):
        self.db_path = db_path

    def connect(self):
        con = sqlite3.connect(self.db_path, timeout=5.0)
        con.execute("PRAGMA journal_mode=WAL;")
        con.execute("PRAGMA busy_timeout=5000;")
        return con

    def account_id(self, con, account_id=None, username=None):
        if account_id is not None:
            row = con.execute("SELECT account_id FROM account WHERE account_id = ?;",
                              (account_id,)).fetchone()
            return row[0] if row else None
        if username:
            row = con.execute("SELECT account_id FROM account WHERE username = ?;",
                              (username,)).fetchone()
            return row[0] if row else None
        return None

    def enqueue(self, con, key, account_id, kind, amount, payload):
        cur = con.execute(
            "INSERT OR IGNORE INTO grant_queue "
            "(idempotency_key, account_id, kind, amount, payload, status, created_at) "
            "VALUES (?, ?, ?, ?, ?, 'pending', strftime('%s','now'))",
            (key, account_id, kind, amount, json.dumps(payload)))
        con.commit()
        return "queued" if cur.rowcount == 1 else "duplicate"

    def pending(self, con):
        return con.execute(
            "SELECT COUNT(*) FROM grant_queue WHERE status = 'pending';").fetchone()[0]

    def multi_account_suspicions(self, con):
        con.execute("""
            CREATE TABLE IF NOT EXISTS device_fingerprint (
                fp TEXT PRIMARY KEY,
                account_id INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
        """)
        con.execute("""
            CREATE INDEX IF NOT EXISTS idx_device_fp
            ON device_fingerprint(fp, last_seen);
        """)
        con.commit()
        now = int(time.time())
        rows = con.execute("""
            SELECT fp, COUNT(DISTINCT account_id) as acct_count
            FROM telemetry_event
            WHERE kind = 'login' AND created_at > ? AND fingerprint != ''
            GROUP BY fp HAVING acct_count >= 3;
        """, (now - 7 * DAY,)).fetchall()
        suspicious = []
        for fp, acct_count in rows:
            suspicious.append({"fingerprint": fp, "account_count": acct_count})
        return suspicious

    def metrics(self, con):
        # SOM-IDLE D2: dashboard mínimo — economia (ledger) x comportamento
        # (telemetry). Tudo derivado; nada é escrito aqui.
        now = int(time.time())
        gems = con.execute(
            "SELECT COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0), "
            "COALESCE(SUM(CASE WHEN amount < 0 THEN -amount END), 0) "
            "FROM ledger_transaction WHERE kind = 'gems';").fetchone()
        stock = con.execute("SELECT COALESCE(SUM(gems), 0) FROM wallet;").fetchone()
        gold7 = con.execute(
            "SELECT COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0) "
            "FROM ledger_transaction WHERE kind = 'gold' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        trades7 = con.execute(
            "SELECT COUNT(*) FROM ledger_transaction "
            "WHERE reason LIKE 'trade_out:%' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        fees7 = con.execute(
            "SELECT COALESCE(SUM(-amount), 0) FROM ledger_transaction "
            "WHERE reason = 'trade_fee' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        vip = con.execute("SELECT COUNT(*) FROM account WHERE vip_until > ?;",
                          (now,)).fetchone()
        accts = con.execute(
            "SELECT COUNT(*), COALESCE(SUM(last_timestamp > ?), 0) FROM account;",
            (now - DAY,)).fetchone()
        d1 = con.execute(
            "SELECT COUNT(*), COALESCE(SUM(last_timestamp > created_timestamp + 72000), 0) "
            "FROM account WHERE created_timestamp BETWEEN ? AND ?;",
            (now - 2 * DAY, now - DAY)).fetchone()
        settles = con.execute(
            "SELECT COUNT(*), COALESCE(AVG(CAST(json_extract(meta, '$.eff') AS REAL)), 0) "
            "FROM telemetry_event WHERE kind = 'settle' AND created_at > ?;",
            (now - DAY,)).fetchone()
        logins = con.execute(
            "SELECT COUNT(*) FROM telemetry_event "
            "WHERE kind = 'login' AND created_at > ?;", (now - DAY,)).fetchone()
        recon = con.execute(
            "SELECT divergences, created_at FROM reconcile_run "
            "ORDER BY id DESC LIMIT 1;").fetchone()
        guilds = con.execute("SELECT COUNT(*) FROM guild;").fetchone()
        ah = con.execute(
            "SELECT COUNT(*) FROM auction_listing WHERE status = 'open';").fetchone()
        season = con.execute(
            "SELECT season_id FROM season WHERE status = 'active' "
            "ORDER BY season_id DESC LIMIT 1;").fetchone()
        sales = {}
        try:
            for sku_row, n, tot in con.execute(
                    "SELECT json_extract(payload, '$.sku'), COUNT(*), "
                    "COALESCE(SUM(amount), 0) FROM grant_queue "
                    "WHERE status = 'processed' GROUP BY 1;").fetchall():
                sales[sku_row or "unknown"] = {"grants": n, "units": tot}
        except sqlite3.Error:
            pass
        funnel = {}
        try:
            funnel = {
                "starter_claimed": con.execute(
                    "SELECT COUNT(*) FROM grant_queue WHERE payload LIKE ? "
                    "AND status = 'processed';",
                    ('%"sku": "starter.pack"%%',)).fetchone()[0],
                "starter_eligible": con.execute(
                    "SELECT COUNT(*) FROM account WHERE created_timestamp > ?;",
                    (now - 3 * DAY,)).fetchone()[0],
            }
        except sqlite3.Error:
            pass
        return {
            "gems": {"mint": gems[0], "burn": gems[1], "stock": stock[0]},
            "gold_7d": {"faucet": gold7[0]},
            "trades_7d": {"count": trades7[0], "fees_burned": fees7[0]},
            "vip_active": vip[0],
            "accounts": {"total": accts[0], "active_24h": accts[1]},
            "retention_d1": {"cohort": d1[0], "retained": d1[1]},
            "settles_24h": {"count": settles[0], "avg_eff": round(settles[1], 3)},
            "logins_24h": logins[0],
            "reconcile": {"divergences": recon[0], "at": recon[1]} if recon else None,
            "grants_pending": self.pending(con),
            "guilds": guilds[0],
            "ah_open": ah[0],
            "season_active": season[0] if season else None,
            "sales_by_sku": sales,
            "starter_funnel": funnel,
            "multi_account_suspicions": self.multi_account_suspicions(con),
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "ShambletaCompanion/0.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        sys.stderr.write("companion: %s\n" % (args[0] % args[1:]))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            with self.server.store.connect() as con:
                self._send(200, {"ok": True,
                                 "pending": self.server.store.pending(con)})
            return
        if path == "/catalog":
            # Catálogo público p/ a loja exibir preços (grants continuam
            # server-authoritative no webhook; preço aqui é display).
            pub = {}
            for sku, e in self.server.catalog.items():
                pub[sku] = {k: e[k] for k in
                            ("kind", "contents", "currency", "price",
                             "one_time", "max_account_age", "title",
                             "tier", "cosmetic_id")
                            if k in e}
            self._send(200, {"catalog": pub})
            return
        if path == "/metrics":
            try:
                with self.server.store.connect() as con:
                    self._send(200, self.server.store.metrics(con))
            except sqlite3.Error as e:
                self._send(500, {"error": "db_error", "detail": str(e)})
            return
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/checkout/intents":
            return self._checkout_intent()
        if parsed.path == "/checkout/preference":
            return self._checkout_preference()
        if parsed.path == "/checkout/simulate":
            return self._checkout_simulate()
        if parsed.path != "/webhooks/payments":
            return self._send(404, {"error": "not_found"})
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        provider = self.server.provider
        # (1c) autentica a ORIGEM pelo esquema do provedor, não por segredo único.
        if provider == "mercadopago":
            # MP assina sobre o QUERY param data.id (não o corpo); o corpo do
            # webhook só traz o id → status/valor/external_reference são
            # autoritativos via re-fetch na API MP (padrão oficial) quando há token.
            data_id = (parse_qs(parsed.query).get("data.id") or [None])[0]
            # nem todo formato do MP coloca data.id na query; fallback: corpo plano
            if data_id is None and raw:
                try:
                    _d = json.loads(raw.decode())
                except (ValueError, UnicodeDecodeError):
                    _d = {}
                _dat = _d.get("data")
                if isinstance(_dat, dict):
                    data_id = _dat.get("id")
                else:
                    data_id = _d.get("data.id") or _d.get("resource")
            ok = verify_mercadopago_signature(
                self.server.mp_secret,
                self.headers.get("x-signature", ""),
                self.headers.get("x-request-id", ""),
                data_id, self.server.tolerance)
            if not ok:
                return self._send(401, {"error": "bad_signature"})
            if self.server.mp_access_token and data_id:
                payload_data = mp_fetch_payment(data_id, self.server.mp_access_token)
                if payload_data is None:
                    return self._send(502, {"error": "refetch_failed"})  # MP reenvia
            else:
                # sandbox/teste sem token: corpo plano já traz account_id/sku.
                try:
                    payload_data = json.loads(raw.decode()) if raw else {}
                except (ValueError, UnicodeDecodeError):
                    return self._send(400, {"error": "bad_json"})
        else:
            if provider == "stripe":
                ok = verify_stripe_signature(self.server.stripe_secret,
                                             self.headers.get("Stripe-Signature", ""),
                                             raw, self.server.tolerance)
            elif provider == "shared":
                # modo sandbox: só permitido explicitamente (nunca em produção).
                ok = self.server.allow_dev and verify_shared_secret(
                    self.server.secret, self.headers.get("X-Signature", ""), raw)
            else:
                ok = False
            if not ok:
                return self._send(401, {"error": "bad_signature"})
            try:
                payload_data = json.loads(raw.decode())
            except (ValueError, UnicodeDecodeError):
                return self._send(400, {"error": "bad_json"})
        norm = normalize_event(provider, payload_data)
        if not norm:
            # evento legítimo de não-entrega (ex.: MP pendente/estornado) → ACK 200
            # para o provedor parar de reenviar; nada é concedido.
            return self._send(200, {"status": "ignored"})
        # (1c) o montante vem do CATÁLOGO — nunca do corpo.
        try:
            items = resolve_grant_items(
                self.server.catalog, norm["sku"], norm.get("amount"))
        except CatalogError as e:
            alert("webhook grant rejected (%s) sku=%r" % (str(e), norm.get("sku")))
            return self._send(400, {"error": str(e)})
        key = norm["idempotency_key"]
        if not key:
            return self._send(400, {"error": "bad_grant"})
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, norm.get("account_id"), norm.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                statuses = self._enqueue_items(
                    con, account_id, norm["sku"], items, key, provider)
        except sqlite3.Error as e:
            alert("webhook DB error: %s" % e, "error")
            return self._send(500, {"error": "db_error", "detail": str(e)})
        if len(statuses) == 1:
            self._send(200, {"status": statuses[0]})
        else:
            self._send(200, {"status": "ok", "items": statuses})

    def _enqueue_items(self, con, account_id, sku, items, key, provider):
        """Enfileira 1 grant por item (bundle = N linhas). Item único mantém a
        chave original (ledger `grant:<key>` estável); bundle usa chaves
        derivadas determinísticas (redelivery = duplicate, sem crédito duplo)."""
        entry = self.server.catalog.get(sku) or {}
        statuses = []
        for i, (kind, amount) in enumerate(items):
            k = key if len(items) == 1 else "%s:%d:%s" % (key, i, kind)
            payload = {"sku": sku, "provider": provider, "kind": kind}
            if entry.get("title"):
                payload["title"] = entry["title"]
            if entry.get("cosmetic_id"):
                payload["cosmetic_id"] = entry["cosmetic_id"]
            if entry.get("tier"):
                payload["tier"] = entry["tier"]
            statuses.append(self.server.store.enqueue(
                con, k, account_id, kind, amount, payload))
        return statuses

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            return json.loads(raw.decode()) if raw else {}, raw
        except (ValueError, UnicodeDecodeError):
            return None, raw

    def _checkout_intent(self):
        """Fase A (sandbox): a loja pede {account_id|username, sku} e recebe o
        external_reference + preço do catálogo. O pagamento real (MP checkout
        pro, onboarding pendente — handoff §2) usa esse external_reference; o
        grant entra pelo webhook idempotente. Sem chamada ao MP aqui."""
        data, _raw = self._read_json()
        if data is None:
            return self._send(400, {"error": "bad_json"})
        sku = data.get("sku")
        if not sku or sku not in self.server.catalog:
            return self._send(400, {"error": "unknown_sku"})
        try:
            items = resolve_grant_items(self.server.catalog, sku)
        except CatalogError as e:
            return self._send(400, {"error": str(e)})
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, data.get("account_id"), data.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e)})
        entry = self.server.catalog[sku]
        return self._send(200, {
            "external_reference": "%d:%s" % (account_id, sku),
            "account_id": account_id,
            "sku": sku,
            "items": [{"kind": k, "amount": a} for k, a in items],
            "price": entry.get("price"), "currency": entry.get("currency", "BRL"),
            "starter_offer": offer,
            "sandbox": "pague via POST /checkout/simulate (allow_dev) com "
                       "idempotency_key=<external_reference>:<payment_id>",
        })

    def _checkout_preference(self):
        """Produção (Checkout Pro): dado {account_id|username, sku} (+
        external_reference opcional p/ conferência), cria uma preferência real
        na API do Mercado Pago e devolve a URL de pagamento (init_point).

        O valor vem do CATÁLOGO (nunca do cliente). O grant continua entrando
        pelo webhook idempotente (grant_queue, chave = payment id) — esta rota
        nunca credita nada. Fail-closed sem SHAMBLETA_MP_ACCESS_TOKEN (503).
        Sandbox continua em POST /checkout/simulate (allow_dev)."""
        data, _raw = self._read_json()
        if data is None:
            return self._send(400, {"error": "bad_json"})
        sku = data.get("sku")
        if not sku or sku not in self.server.catalog:
            return self._send(400, {"error": "unknown_sku"})
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, data.get("account_id"), data.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e)})
        external_reference = "%d:%s" % (account_id, sku)
        if data.get("external_reference"):
            # Conferência: o cliente pode ecoar, nunca inventar (preço/grant
            # continuam autoritativos no catálogo + webhook).
            if str(data.get("external_reference")) != external_reference:
                return self._send(400, {"error": "external_reference_mismatch"})
        if not self.server.mp_access_token:
            return self._send(503, {"error": "checkout_unavailable"})
        payload, err = build_preference_payload(
            self.server.catalog, sku, external_reference,
            getattr(self.server, "mp_back_urls_base", ""))
        if err:
            return self._send(400, {"error": err})
        pref = mp_create_preference(payload, self.server.mp_access_token)
        if not pref:
            return self._send(502, {"error": "preference_failed"})
        payment_url = (pref.get("init_point")
                       or pref.get("sandbox_init_point") or "")
        if not payment_url:
            return self._send(502, {"error": "preference_failed"})
        entry = self.server.catalog[sku]
        return self._send(200, {
            "external_reference": external_reference,
            "account_id": account_id,
            "sku": sku,
            "price": entry.get("price"), "currency": entry.get("currency", "BRL"),
            "payment_url": payment_url,
            "preference_id": pref.get("id"),
        })

    def _checkout_simulate(self):
        """Sandbox explícito (allow_dev + shared secret): simula o pagamento
        aprovado e enfileira os grants. Produção usa o webhook do provedor."""
        allow_checkout = bool(getattr(self.server, "allow_dev_checkout", False)
                              or (self.server.allow_dev
                                  and self.server.provider == "shared"))
        if not allow_checkout:
            return self._send(403, {"error": "sandbox_only"})
        data, raw = self._read_json()
        if data is None:
            return self._send(400, {"error": "bad_json"})
        if not verify_shared_secret(self.server.secret,
                                     self.headers.get("X-Signature", ""), raw):
            return self._send(401, {"error": "bad_signature"})
        sku = data.get("sku")
        key = data.get("idempotency_key") or ""
        if not sku or not key:
            return self._send(400, {"error": "bad_grant"})
        try:
            items = resolve_grant_items(self.server.catalog, sku)
        except CatalogError as e:
            return self._send(400, {"error": str(e)})
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, data.get("account_id"), data.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                # Replay do mesmo pagamento: chaves derivadas já existem →
                # idempotente (não é nova compra; pula o gate one-time).
                prior = con.execute(
                    "SELECT status FROM grant_queue WHERE idempotency_key = ? "
                    "OR idempotency_key LIKE ? ORDER BY id;",
                    (key, key + ":%")).fetchall()
                if prior:
                    return self._send(200, {"status": "ok", "replay": True,
                                            "items": [r[0] for r in prior]})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
                statuses = self._enqueue_items(
                    con, account_id, sku, items, key, "sandbox")
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e)})
        self._send(200, {"status": "ok", "items": statuses})



def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True, help="caminho do live.db do game server")
    ap.add_argument("--port", type=int, default=8901)
    ap.add_argument("--provider",
                    default=os.environ.get("SHAMBLETA_WEBHOOK_PROVIDER", "shared"),
                    choices=("mercadopago", "stripe", "shared"),
                    help="esquema de assinatura a verificar (mercadopago = produção)")
    ap.add_argument("--secret",
                    default=os.environ.get("SHAMBLETA_WEBHOOK_SECRET", ""),
                    help="segredo do modo sandbox (provider=shared)")
    ap.add_argument("--stripe-secret",
                    default=os.environ.get("SHAMBLETA_STRIPE_WEBHOOK_SECRET", ""),
                    help="whsec_... do endpoint Stripe (provider=stripe)")
    ap.add_argument("--mp-secret",
                    default=os.environ.get("SHAMBLETA_MP_WEBHOOK_SECRET", ""),
                    help="segredo (credencial) do webhook Mercado Pago (provider=mercadopago)")
    ap.add_argument("--mp-access-token",
                    default=os.environ.get("SHAMBLETA_MP_ACCESS_TOKEN", ""),
                    help="access_token MP p/ re-fetch autoritativo do pagamento "
                         "(provider=mercadopago; sem ele usa o corpo plano p/ sandbox)")
    ap.add_argument("--catalog",
                    default=os.environ.get("SHAMBLETA_CATALOG_FILE", ""),
                    help="JSON de catálogo SKU->grant; default: embutido")
    ap.add_argument("--tolerance", type=int,
                    default=int(os.environ.get("SHAMBLETA_WEBHOOK_TOLERANCE", "300")),
                    help="janela anti-replay (s)")
    ap.add_argument("--allow-dev",
                    default=os.environ.get("SHAMBLETA_ALLOW_DEV_WEBHOOK", "") == "1",
                    action="store_true",
                    help="permitir provider=shared (sandbox); NUNCA em produção")
    ap.add_argument("--allow-dev-checkout",
                    default=(os.environ.get("SHAMBLETA_ALLOW_DEV_CHECKOUT", "") == "1"),
                    action="store_true",
                    help="permitir POST /checkout/simulate em staging/teste "
                         "(padrão: só com --allow-dev + provider=shared); "
                         "NUNCA em produção")
    ap.add_argument("--mp-back-urls-base",
                    default=os.environ.get("SHAMBLETA_MP_BACK_URLS_BASE", ""),
                    help="base pública da página de retorno do checkout "
                         "(back_urls success/pending/failure apontam p/ "
                         "<base>/checkout_return.html); vazio = sem back_urls")
    ap.add_argument("--refund-sweep", action="store_true",
                    help="uma passada de estornos MP (grants 'refunded' ainda não "
                         "notificados) e sai; exige SHAMBLETA_MP_REFUNDS=1 + token "
                         "(cron diário sugerido)")
    ap.add_argument("--dry-run", action="store_true",
                    help="com --refund-sweep: só lista pendentes, sem chamar a API")
    args = ap.parse_args()
    if args.refund_sweep:
        if not os.path.exists(args.db):
            sys.stderr.write("companion: database not found: %s\n" % args.db)
            return 2
        try:
            res = refund_sweep(args.db, args.mp_access_token,
                               dry_run=args.dry_run)
        except RuntimeError as e:
            sys.stderr.write("companion: %s\n" % e)
            return 2
        print("companion: refund sweep: %s" % res, flush=True)
        return 0
    try:
        catalog = load_catalog(args.catalog)
    except (ValueError, OSError, json.JSONDecodeError) as e:
        sys.stderr.write("companion: bad catalog: %s\n" % e)
        return 2
    if args.provider == "stripe" and not args.stripe_secret:
        sys.stderr.write("companion: provider=stripe exige --stripe-secret "
                         "(SHAMBLETA_STRIPE_WEBHOOK_SECRET)\n")
        return 2
    if args.provider == "mercadopago" and not args.mp_secret:
        sys.stderr.write("companion: provider=mercadopago exige --mp-secret "
                         "(SHAMBLETA_MP_WEBHOOK_SECRET)\n")
        return 2
    if args.provider == "shared" and not (args.secret and args.allow_dev):
        sys.stderr.write("companion: provider=shared exige --secret E --allow-dev "
                         "(modo sandbox explícito; use provider=mercadopago em produção)\n")
        return 2
    if not os.path.exists(args.db):
        sys.stderr.write("companion: database not found: %s\n" % args.db)
        return 2
    host = os.environ.get("SHAMBLETA_COMPANION_HOST", "127.0.0.1")
    # (3c) servidor de produção: multi-thread (webhooks concorrentes não bloqueiam
    # /health nem entre si). Cada request abre a própria conexão SQLite (WAL), então
    # a troca HTTPServer→ThreadingHTTPServer não cruza conexões entre threads.
    server = ThreadingHTTPServer((host, args.port), Handler)
    server.daemon_threads = True   # não segura o processo em requests pendurados
    server.request_queue_size = 128
    server.store = Store(args.db)
    server.secret = args.secret
    server.provider = args.provider
    server.stripe_secret = args.stripe_secret
    server.mp_secret = args.mp_secret
    server.mp_access_token = args.mp_access_token
    server.mp_back_urls_base = args.mp_back_urls_base
    server.catalog = catalog
    server.tolerance = args.tolerance
    server.allow_dev = bool(args.allow_dev)
    server.allow_dev_checkout = bool(args.allow_dev_checkout or args.allow_dev)
    print("companion: listening on %s:%d (db %s, provider %s, %d SKUs)"
          % (host, args.port, args.db, args.provider, len(catalog)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0



if __name__ == "__main__":
    sys.exit(main())
