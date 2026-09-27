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
    python3 companion/server.py --db /data/.local/share/Shambleta/live.db --port 8901
      # MP manda x-signature: ts=...,v1=... (HMAC sobre o manifest
      # id:<data.id>;request-id:<x-request-id>;ts:<ts>;). O companion valida a
      # assinatura e RE-BUSCA o pagamento na API MP (autoritativo): status
      # approved + external_reference="<account_id>:<sku>". Sem access_token usa
      # o corpo plano (só sandbox/teste). O grant usa kind/amount do CATÁLOGO.

    # alternativa Stripe (assinatura Stripe-Signature + catálogo autoritativo):
    SHAMBLETA_WEBHOOK_PROVIDER=stripe SHAMBLETA_STRIPE_WEBHOOK_SECRET=whsec_xxx \
    python3 companion/server.py --db /data/.local/share/Shambleta/live.db
      # Stripe manda Stripe-Signature: t=...,v1=... ; o checkout define
      # metadata.shambleta_sku + client_reference_id=<account_id>.

    # sandbox/dev (assinatura por segredo compartilhado, payload plano) — só
    # com opt-in explícito:
    SHAMBLETA_WEBHOOK_PROVIDER=shared SHAMBLETA_WEBHOOK_SECRET=xxx \
    SHAMBLETA_ALLOW_DEV_WEBHOOK=1 python3 companion/server.py --db /data/.local/share/Shambleta/live.db
      curl -X POST localhost:8901/webhooks/payments \
        -H 'X-Signature: <hmac-sha256-hex do body>' \
        -d '{"idempotency_key":"tx1","username":"Hero","sku":"gems.550"}'

    # Fase A — checkout sandbox (sem credencial MP): a loja pede a intenção e
    # simula o pagamento aprovado; o grant entra pela mesma fila idempotente.
    # Beta fechado: intents/preference exigem auth_token do login (prova de
    # sessão; account_id do cliente só vale se igual ao dono do token):
    curl -X POST localhost:8901/checkout/intents \
      -d '{"auth_token":"<token do login>","sku":"starter.pack"}'
      # → {external_reference: "<account_id>:starter.pack", items, price}
    curl -X POST localhost:8901/checkout/simulate \
      -H 'X-Signature: <hmac do body>' \
      -d '{"username":"Hero","sku":"starter.pack","idempotency_key":"1:starter.pack:pay1"}'
    # Produção troca o simulate pelo checkout MP (mesma external_reference):
    # POST /checkout/preference {username|account_id, sku} → {payment_url}
    # (Checkout Pro, valor do catálogo) + grant pelo webhook do provedor.

SOM-IDLE W5 — web push (banco de chegada da entrega; ver seção "web push" no
corpo do arquivo). Tables da migration 052 (push_subscription / push_outbox):
    python3 companion/server.py --db live.db --push-register --account 7 \
        --endpoint 'https://push.example/s/abc' --p256dh <KEY> --auth <VA>
    python3 companion/server.py --db live.db --push-sweep          # enfileira
    python3 companion/server.py --db live.db --push-drain          # drena
    python3 companion/server.py --db live.db --push-notify --account 7 \
        --title T --body B                                          # enfileira+drena
POST /push/test (interno: exige SHAMBLETA_PUSH_ADMIN_TOKEN; o nginx NÃO
proxya /push/) drena a fila com o sender plugável SHAMBLETA_PUSH_SENDER
(default "vapid"). O sender VAPID existe de verdade — `companion/push_vapid.py`
assina o assertion ES256 da RFC 8292 e cifra o corpo em aes128gcm (RFC 8291),
tudo na stdlib. Ele só NÃO roda sem segredo: sem SHAMBLETA_VAPID_PRIVATE_KEY
configurado levanta NotImplementedError e a fila grava 'vapid_sender_unimplemented'
(fail-closed, como antes de o módulo existir; nenhum "sucesso" silencioso). GET
/push/vapid diz se o sender está pronto e publica a chave pública (pública por
definição). Sem a chave no deploy, WebPush.CanDeliver() continua false e o
jogador não vê o toggle.

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

# Catálogo canônico (SKU -> o que comprar) é data/conf/paid_catalog.json — a
# mesma fonte que o jogo valida no boot (`EconomyCatalog.ValidatePaidCatalog`) e
# na suíte (`SuiteCatalogConsistency`), exportada nos presets porque mora em
# data/conf/. Aponte outro JSON com SHAMBLETA_CATALOG_FILE / --catalog. Este
# dicionário é o FALLBACK de desenvolvimento: se ele divergir do arquivo, a
# suíte falha (o preço que vira grant é o do catálogo carregado, nunca o do corpo
# do webhook). O preço (`price`) fica aqui só p/ auditoria/cross-check; o que
# vira grant é kind+amount.
# Bundles (starter/founder) decompõem em N grants atômicos com chaves derivadas
# "{key}:{i}:{kind}" — o game server processa linha a linha, sem código novo.
#
# `_agreements` não é SKU (todo `_` é comentário aqui): é a declaração das
# versões vigentes de ToS/privacidade/idade que a FRONTIERA DO DINHEIRO cobra.
# Mora no catálogo porque é exatamente o mesmo contrato de "uma fonte, dois
# leitores" do preço: o jogo valida o bloco contra os consts de `NetworkCommons`
# no boot (`EconomyCatalog.ValidatePaidCatalog`) e na suíte, então bumpar
# `AgreementTosVersion` sem bumpar o arquivo é erro de boot, não porta aberta.
DEFAULT_CATALOG = {
    "_agreements": {"tos": "2026-09-c", "privacy": "2026-09-b", "age": "2026-09-a"},
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
                     "title": "Recruta — VIP 7 dias + 220 gems"},
    # MONETIZATION §1 item 14: apoio no beta, título "Fundador".
    "founder.pack": {"kind": "bundle",
                     "contents": [{"kind": "gems", "amount": 1200},
                                  {"kind": "vip_days", "amount": 30}],
                     "currency": "BRL", "price": 39.90,
                     "one_time": True,
                     "title": "Fundador — 1200 gems + VIP 30 dias"},
}


def default_catalog_path():
    """Catálogo canônico do repositório: data/conf/paid_catalog.json — a MESMA
    fonte que o jogo valida no boot do servidor (EconomyCatalog.ValidatePaidCatalog)
    e na suíte. No container do companion o Dockerfile copia o arquivo para /app,
    ao lado deste server.py; na árvore de source ele está em data/conf/. Sem
    nenhum dos dois, o embutido DEFAULT_CATALOG ainda serve (dev), e a suíte
    amarra as três cópias."""
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.join(here, "paid_catalog.json"),
                      os.path.normpath(os.path.join(here, os.pardir, "data", "conf", "paid_catalog.json"))):
        if os.path.isfile(candidate):
            return candidate
    return ""


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


def is_sellable_sku(catalog, sku):
    """SKU cobrável: existe no catálogo E tem forma de produto.

    As três portas de dinheiro comparavam o `sku` do request por *membership* no
    dict (`sku not in self.server.catalog`). O mesmo JSON que declara os preços
    declara comentários — `_note`, e agora `_agreements`, que é um **objeto**: por
    membership ele passava, `build_preference_payload` lia `entry.get("price", 0.0)`
    e montava uma preferência de `unit_price` 0.0 para o provedor (cobrar zero é
    entregar de graça), enquanto `_note` derrubava o handler com AttributeError
    antes de qualquer resposta. A forma é a MESMA predicate que `load_catalog` usa
    para validar o arquivo, então não existe segunda regra a divergir."""
    if not sku or not isinstance(sku, str) or sku.startswith("_"):
        return False
    entry = catalog.get(sku) if isinstance(catalog, dict) else None
    if not isinstance(entry, dict):
        return False
    if entry.get("kind") == "bundle":
        contents = entry.get("contents")
        return bool(isinstance(contents, list) and contents
                    and all(_valid_item(c) for c in contents))
    return _valid_item(entry)


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
    de verdade — só como cross-check (CDC: preço anunciado = preço cobrado).

    A checagem é de FORMA, não de membership: o catálogo também carrega as
    declarações do arquivo (`_note`, `_agreements`), e chamar `resolve_grant` com
    uma delas levantava KeyError no meio do handler (KeyError 'amount' /
    AttributeError num str) em vez de um `unknown_sku` limpo."""
    if not is_sellable_sku(catalog, sku):
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
    if not is_sellable_sku(catalog, sku):
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


def season_offer_status(con, catalog, sku, now=None):
    """Elegibilidade dos SKUs presos à temporada (kind pass_premium).

    O passe NÃO EXISTE sem temporada ativa: no jogo o grant de `pass_premium`
    falha fechado quando `ActiveSeason()` está vazio (CheckoutService devolve
    false e a linha vira status='failed'). Sem este gate, o companion cobra
    R$ 24,90/44,90 e o jogo registra um grant que não entrega — é o defeito
    "cobra e não entrega" na face mais cara dele. A checagem é no mesmo SQLite
    do servidor de jogo (o companion já lê `account`/`grant_queue` aqui), e o
    `ends_at > agora` é o que impede vender um passe de temporada vencida nos
    minutos antes do relógio de temporada fechá-la. Tabela ausente (banco sem a
    migração de temporada) conta como indisponível: se não há tabela, não há
    temporada."""
    if now is None:
        now = int(time.time())
    entry = catalog.get(sku) or {}
    if entry.get("kind") != "pass_premium":
        return {"eligible": True, "reason": "not_season_bound", "season_id": 0}
    try:
        row = con.execute(
            "SELECT season_id FROM season WHERE status = 'active' AND ends_at > ? "
            "ORDER BY season_id DESC LIMIT 1;", (now,)).fetchone()
    except sqlite3.Error:
        row = None
    if row is None:
        return {"eligible": False, "reason": "no_active_season", "season_id": 0}
    return {"eligible": True, "reason": "ok", "season_id": row[0]}


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
    ou 'unknown_sku' quando o SKU não existe no catálogo. Cobrável aqui tem a
    MESMA definição das rotas: uma chave de comentário do arquivo não tem preço,
    e `entry.get("price", 0.0)` sobre ela montava uma preferência de R$ 0,00."""
    if not is_sellable_sku(catalog, sku):
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


def _paid_money(source):
    """(centavos, moeda) do que o provedor COBROU — K1: grant_queue.amount é
    unidade de JOGO (gems concedidas), então sem este par não existia nenhum
    número de receita no sistema e ARPU/ARPPU/LTV eram incomputáveis.

    O float só é tocado aqui, na borda do provedor: MP devolve transaction_amount
    em unidade maior (19.90), Stripe devolve amount_total JÁ em centavos
    (inteiro). Daqui pra dentro é sempre inteiro menor — SQLite não tem ponto
    fixo e float em caminho de dinheiro é como se perde dinheiro. Sem dado
    (sandbox explícito) → (0, ''), que não é dinheiro inventado."""
    if not source:
        return 0, ""
    currency = str(source.get("currency_id") or source.get("currency") or "").upper()
    minor = source.get("amount_total")
    if minor is not None:
        try:
            return int(minor), currency
        except (TypeError, ValueError):
            return 0, ""
    major = source.get("transaction_amount")
    if major is None:
        return 0, ""
    try:
        return int(round(float(major) * 100)), currency
    except (TypeError, ValueError):
        return 0, ""


def catalog_price_minor(catalog, sku):
    """(centavos, moeda) do PREÇO DE CATÁLOGO — o mesmo número que
    build_preference_payload manda cobrar no provedor. Usado pelo sandbox de
    checkout, que simula o pagamento aprovado sem passar pelo provedor: registrar
    0 ali deixaria a métrica de receita cega justamente no ambiente onde ela é
    exercitada."""
    entry = catalog.get(sku) or {}
    return _paid_money({"transaction_amount": entry.get("price"),
                        "currency_id": entry.get("currency")})


def check_payment_amount(catalog, sku, payment):
    """Cross-checkProdução (CDC: anunciado = cobrado): o valor pago
    (transaction_amount do payment re-buscado) deve bater com o preço do
    catálogo. Sem transaction_amount (sandbox explícito) → True (nada a
    conferir). Tolera centavos de representação float."""
    if payment is None or "transaction_amount" not in payment:
        return True
    entry = catalog.get(sku) or {}
    try:
        paid = float(payment.get("transaction_amount"))
        expected = float(entry.get("price", 0.0))
    except (TypeError, ValueError):
        return False
    return abs(paid - expected) < 0.005


def verify_session_token(con, account_id, auth_token, now=None):
    """Prova de sessão p/ checkout (beta fechado, sem migração): o client
    apresenta o auth_token recebido no login (remember-me); o companion
    confere sha256(token) contra a tabela auth_token do game server
    (account_id + expiração). Retorna o account_id DONO do token ou None.

    Regras: sem token → None; token inválido/expirado → None; account_id do
    cliente divergindo do dono do token → None (bloqueia cross-account).
    Tabela ausente (schema antigo) → None (fail-closed)."""
    import hashlib as _hl
    if not auth_token:
        return None
    if now is None:
        now = int(time.time())
    digest = _hl.sha256(str(auth_token).encode()).hexdigest()
    try:
        row = con.execute(
            "SELECT account_id FROM auth_token WHERE token_hash = ? "
            "AND expires_timestamp > ?;",
            (digest, now)).fetchone()
    except Exception:
        return None
    if row is None:
        return None
    owner = int(row[0])
    if account_id is not None:
        try:
            claimed = int(account_id)
        except (TypeError, ValueError):
            return None
        if claimed != owner:
            return None
    return owner


def required_agreements(catalog):
    """Versões vigentes declaradas no catálogo, ou None se o catálogo não
    declarar (schema de arquivo antigo). Não é parâmetro de request: quem
    apresenta o `sku` não pode escolher qual consentimento ele já tem."""
    block = catalog.get("_agreements") if isinstance(catalog, dict) else None
    if not isinstance(block, dict):
        return None
    return (str(block.get("tos") or ""), str(block.get("privacy") or ""),
            str(block.get("age") or ""))


def consent_currently_accepted(con, account_id, catalog):
    """Gate de idade/LGPD (Lei 15.211/2025, migration 046) na segunda porta do
    dinheiro. Espelho de `SQL.IsConsentAccepted`: só conta cujo aceite gravado
    é IGUAL às três versões vigentes.

    O game server já recusa login e `GetCheckoutIntent` sem aceite, mas o
    companion é uma porta própria e alcançável direto (o nginx do serviço `web`
    proxya `/checkout/` para ele): um `auth_token` emitido antes do bump continua
    válido aqui depois de o jogo barrar o jogador — a pessoa não consegue jogar e
    ainda assim consegue pagar. Conta pré-046 lê `consent_age_version = ''` e cai
    na mesma recusa. Fail-closed nos três sentidos: catálogo sem o bloco,
    tabela/coluna ausente (schema antigo) ou linha sem aceite = sem checkout. O
    `/webhooks/payments` NÃO passa por aqui de propósito: lá o dinheiro já foi
    tomado, e recusar seria descartar uma entrega paga."""
    need = required_agreements(catalog)
    if need is None or not all(need):
        return False
    try:
        row = con.execute(
            "SELECT consent_tos_version, consent_privacy_version, "
            "consent_age_version FROM account WHERE account_id = ?;",
            (account_id,)).fetchone()
    except Exception:
        return False
    if row is None:
        return False
    return str(row[0]) == need[0] and str(row[1]) == need[1] and str(row[2]) == need[2]


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


# ---------------------------------------------------------------------------
# SOM-IDLE W5 — web push: sender plugável + mecânica de fila (migration 052).
#
# O que EXISTE aqui e roda sem rede: registro de subscription (CLI
# --push-register), varredura de contas offline que ENFILEIRA sem nunca enviar
# inline (--push-sweep), drenagem da fila contra um sender plugável (CLI
# --push-drain / --push-notify e o endpoint interno POST /push/test).
#
# O sender real mora em `companion/push_vapid.py` — FACHADA de quatro arquivos
# (push_common/push_p256/push_aesgcm/push_vapid) porque o arquivo único estourou
# o teto anti-god-node. Assertion VAPID (RFC 8292) e corpo `aes128gcm` (RFC 8291
# + 8188) escritos com hashlib/hmac/secrets: o companion é stdlib-only por
# contrato (o Dockerfile copia um arquivo e não roda pip). As primitivas são
# medidas contra os vetores publicados das RFCs em
# `companion/test_push_{common,p256,aesgcm,vapid}.py`. Fail-closed nos dois
# sentidos: sem `SHAMBLETA_VAPID_PRIVATE_KEY`, ou com qualquer das quatro camadas
# fora da imagem, o sender levanta `NotImplementedError` com o motivo e a fila
# marca 'vapid_sender_unimplemented' (nenhum segredo vai para log). Sender
# desconhecido em `SHAMBLETA_PUSH_SENDER` cai no vapid, nunca no stdout.
# ---------------------------------------------------------------------------

PUSH_SENDER_ENV = "SHAMBLETA_PUSH_SENDER"
PUSH_ADMIN_TOKEN_ENV = "SHAMBLETA_PUSH_ADMIN_TOKEN"

_push_vapid_module = "unset"
_push_vapid_import_error = ""


def load_push_vapid():
    """Importa a fachada `push_vapid` uma vez, ou devolve None. TARDIO e
    defensivo de propósito: o `deploy/companion/Dockerfile` copia `server.py`
    sozinho, e uma `ImportError` no topo do arquivo derrubaria o webhook de
    pagamento inteiro por causa de uma função opcional. A fachada importa as três
    camadas de baixo, então `ModuleNotFoundError` de QUALQUER delas cai aqui: o
    nome que faltou é guardado para o motivo da fila dizê-lo — nome de módulo não
    é segredo, valor de chave é. O que NÃO pode acontecer é fingir sucesso."""
    global _push_vapid_module, _push_vapid_import_error
    if _push_vapid_module == "unset":
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        try:
            import push_vapid
            _push_vapid_module = push_vapid
        except ImportError as exc:
            _push_vapid_module = None
            _push_vapid_import_error = str(exc)
    return _push_vapid_module


class PushSubscriptionGone(Exception):
    """HTTP 404/410 do provedor (RFC 8030 §5.4): a subscription morreu. A fila
    apaga o registro em vez de re-tentar para sempre. Mora aqui (e não vem do
    módulo) para o `push_drain` funcionar mesmo sem `push_vapid` importado."""

    def __init__(self, status=410, endpoint_host=""):
        super().__init__("push subscription gone (HTTP %s @ %s)"
                         % (status, endpoint_host))
        self.status = int(status)
        self.endpoint_host = endpoint_host


# Rótulos de motivo que podem aparecer na rota pública GET /push/vapid. Lista
# fechada de propósito: um motivo fino ("chave ilegível: <detalhe do parser>")
# nunca sai do processo — só sai o nome coarse, o resto vira 'not_configured'.
_PUSH_PUBLIC_REASONS = frozenset([
    "no_vapid_private_key", "vapid_key_mismatch", "vapid_public_key_undecodable",
])


def vapid_webpush_send(subscription, title, body):
    """Sender real de Web Push (VAPID) — default, e continua FECHADO.

    Devolve True em 2xx (RFC 8030 §4.3 espera 201). Levanta:
      * `NotImplementedError` quando NÃO há como entregar — camada ausente da
        imagem ou chave não configurada/ilegível, com o motivo na exceção. É o
        estado de qualquer deploy sem segredo, e a fila o grava como
        'vapid_sender_unimplemented' (rótulo de antes de este sender existir:
        credencial ausente nunca vira sucesso silencioso).
      * `PushSubscriptionGone` em 404/410 → o registro morto sai do banco.
      * `PushError` em qualquer outra falha de rede/HTTP: a linha fica 'failed'
        com o motivo, sem retry automático. Nenhum segredo sai na mensagem."""
    pv = load_push_vapid()
    if pv is None:
        raise NotImplementedError(
            "vapid sender indisponivel: companion/push_vapid.py e suas camadas "
            "(push_common/push_p256/push_aesgcm) nao acompanharam server.py no "
            "deploy (deploy/companion/Dockerfile copia um unico arquivo)%s"
            % ((" [" + _push_vapid_import_error + "]")
               if _push_vapid_import_error else ""))
    ready, reason = pv.push_ready()
    if not ready:
        raise NotImplementedError(
            "vapid sender sem configuracao: %s" % reason)
    try:
        status = pv.send(subscription, title, body)
    except pv.SubscriptionGone as exc:
        raise PushSubscriptionGone(exc.status, exc.endpoint_host)
    return 200 <= int(status) < 300


def stdout_webpush_send(subscription, title, body):
    """Sender de TESTE (SHAMBLETA_PUSH_SENDER=stdout): imprime e finge sucesso.
    Prova a mecânica da fila (pending -> sent, dedupe, ordem FIFO) — nunca
    entrega nada a um navegador. Nunca default."""
    print("companion: push(stub-stdout) acct=%s title=%r body=%r endpoint=%s"
          % (subscription.get("account_id"), title, body,
             subscription.get("endpoint")), flush=True)
    return True


PUSH_SENDERS = {
    "vapid": vapid_webpush_send,
    "stdout": stdout_webpush_send,
}


def push_sender():
    """Sender ativo: default FECHADO (vapid — que só entrega com chave VAPID
    configurada, e levanta NotImplementedError sem ela). Nome desconhecido em
    SHAMBLETA_PUSH_SENDER cai no default, nunca no stdout."""
    name = os.environ.get(PUSH_SENDER_ENV, "vapid")
    return PUSH_SENDERS.get(name, vapid_webpush_send)


def push_sweep(db_path, offline_seconds=86400, quiet_seconds=3 * 86400,
               title=None, body=None):
    """Uma passada de varredura (CLI --push-sweep): ENFILEIRA aviso de retorno
    para contas offline com subscription registrada e silenciosas na janela.
    Nunca envia inline — a entrega é do --push-drain/POST /push/test. Retorna
    {scanned, queued}."""
    store = Store(db_path)
    with store.connect() as con:
        return {"scanned": store.push_subscribed_count(con),
                "queued": store.push_sweep(
                    con, offline_seconds=offline_seconds,
                    quiet_seconds=quiet_seconds, title=title, body=body)}


def push_drain(db_path, limit=20, sender=None):
    """Drena até `limit` linhas pendentes contra o sender plugável. Retorna o
    resumo {pending, sent, failed, skipped}. Exaustivo é responsabilidade do
    operador (cron/flag), não do request."""
    store = Store(db_path)
    with store.connect() as con:
        return store.push_drain(con, limit=limit, sender=sender)


def normalize_event(provider, data):
    """Reduz o corpo (formato do provedor OU flat sandbox) a um grant canônico:
    {idempotency_key, account_id, username, sku, price_paid, currency}.
    price_paid está em CENTAVOS (ver _paid_money). Retorna None se não aplicável."""
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
        paid, currency = _paid_money(obj)
        return {"idempotency_key": key, "account_id": acct,
                "username": user, "sku": sku,
                "price_paid": paid, "currency": currency}
    if provider == "mercadopago":
        # sandbox/teste: corpo plano já traz os campos.
        if data.get("account_id") is not None or data.get("sku") is not None:
            acct = data.get("account_id")
            paid, currency = _paid_money(data)
            return {"idempotency_key": data.get("idempotency_key") or data.get("id"),
                    "account_id": int(acct) if acct is not None else None,
                    "username": data.get("username"), "sku": data.get("sku"),
                    "price_paid": paid, "currency": currency}
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
        paid, currency = _paid_money(data)
        return {"idempotency_key": str(key) if key is not None else "",
                "account_id": acct, "username": meta.get("shambleta_username"),
                "sku": sku, "price_paid": paid, "currency": currency}
    # sandbox / dev / pix-notify simples: payload plano
    acct = data.get("account_id")
    if acct is not None:
        acct = int(acct)
    paid, currency = _paid_money(data)
    return {"idempotency_key": data.get("idempotency_key", ""),
            "account_id": acct, "username": data.get("username"),
            "sku": data.get("sku"), "price_paid": paid, "currency": currency}


# P1-6b — quais eventos do provedor mandam REVERTER o que já foi entregue.
#
# `charged_back` é prova por si só: o MP só abre chargeback sobre payment
# capturado, logo houve dinheiro e houve entrega (o grant saiu de `approved`).
#
# A recusa (`refused`/`rejected`/`cancelled`) é o contrário: não há valor
# capturado nenhum e o MP emite esse status em TODA tentativa de cartão negada.
# Então status nenhum autoriza débito — a única coisa que autoriza é a EVIDÊNCIA
# de que aquele mesmo payment gerou grant nosso, que mora na nossa própria fila
# (`grant_queue`, consultada por `granted_check`). O caso é real porque
# `normalize_event` também concede em `authorized_payment`: uma autorização pode
# ser recusada/cancelada depois de já termos entregue e sem nunca virar captura —
# sem este ramo o jogador ficava com as gems de um dinheiro que nunca entrou.
#
# `granted_check` é callable (não bool) de propósito: o chargeback não paga o
# lookup, e a pergunta nunca é feita para um status que não precisa dela.
# Assinatura pura -> testável sem servidor HTTP (companion/test_webhook.py).
RefusalStatuses = ("refused", "rejected", "cancelled")


def is_reversal_event(status, granted_check):
    """True se o webhook é de reversão (clawback), não de entrega."""
    if str(status or "") == "charged_back":
        return True
    if str(status or "") in RefusalStatuses:
        return bool(granted_check())
    return False


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

    def enqueue(self, con, key, account_id, kind, amount, payload,
                price_paid=0, currency=""):
        # amount = unidade de jogo concedida; price_paid = centavos cobrados
        # (K1 — os dois são coisas diferentes e as duas precisam aparecer).
        cur = con.execute(
            "INSERT OR IGNORE INTO grant_queue "
            "(idempotency_key, account_id, kind, amount, payload, status, created_at, "
            "price_paid, currency) "
            "VALUES (?, ?, ?, ?, ?, 'pending', strftime('%s','now'), ?, ?)",
            (key, account_id, kind, amount, json.dumps(payload),
             int(price_paid), currency))
        con.commit()
        return "queued" if cur.rowcount == 1 else "duplicate"

    def pending(self, con):
        return con.execute(
            "SELECT COUNT(*) FROM grant_queue WHERE status = 'pending';").fetchone()[0]

    # ---- SOM-IDLE W5: web push (migration 052) ----------------------------
    # Registro/dedupe/fila aqui, sender plugável lá em cima. Toda função assume
    # as tabelas existentes: banco sem a migration 052 levanta sqlite3.Error e
    # o chamador (CLI/HTTP) traduz em erro explícito — nada de DDL escondido no
    # companion (a fonte do schema é única: data/conf/migrations/).

    PUSH_DEFAULT_TITLE = "Shambleta"
    PUSH_DEFAULT_BODY = "Sua colheita continua te esperando."

    def push_register(self, con, account_id, endpoint, p256dh, auth, now=None):
        """Upsert da subscription (uma por conta). A conta precisa existir no
        banco do jogo — registration de conta fantasma é lixo na fila. Retorna
        True se gravou, False se a conta não existe."""
        if self.account_id(con, account_id) is None:
            return False
        if now is None:
            now = int(time.time())
        con.execute(
            "INSERT INTO push_subscription (account_id, endpoint, p256dh, auth, "
            "updated_at) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(account_id) DO UPDATE SET endpoint = excluded.endpoint, "
            "p256dh = excluded.p256dh, auth = excluded.auth, "
            "updated_at = excluded.updated_at;",
            (int(account_id), str(endpoint), str(p256dh), str(auth), now))
        con.commit()
        return True

    def push_enqueue(self, con, account_id, title=None, body=None, now=None):
        """Enfileira uma notificação (status pending). Não envia nada."""
        if not account_id:
            raise ValueError("push_enqueue: account_id required")
        if now is None:
            now = int(time.time())
        cur = con.execute(
            "INSERT INTO push_outbox (account_id, title, body, status, created_at) "
            "VALUES (?, ?, ?, 'pending', ?);",
            (int(account_id),
             title or self.PUSH_DEFAULT_TITLE,
             body or self.PUSH_DEFAULT_BODY, now))
        con.commit()
        return cur.lastrowid

    def push_subscribed_count(self, con):
        return con.execute(
            "SELECT COUNT(*) FROM push_subscription;").fetchone()[0]

    def push_sweep(self, con, offline_seconds=86400, quiet_seconds=3 * 86400,
                   title=None, body=None, now=None):
        """Job único de varredura: contas COM subscription, offline há mais de
        `offline_seconds` (last_timestamp velho — 0/null nunca notifica), e sem
        QUALQUER linha na janela de silêncio `quiet_seconds`. Só enfileira;
        nunca envia inline. Retorna quantas linhas novas entraram na fila."""
        if now is None:
            now = int(time.time())
        rows = con.execute(
            "SELECT s.account_id FROM push_subscription s "
            "JOIN account a ON a.account_id = s.account_id "
            "WHERE a.last_timestamp > 0 "
            "AND a.last_timestamp < ? "
            "AND NOT EXISTS (SELECT 1 FROM push_outbox o "
            "                WHERE o.account_id = s.account_id "
            "                AND o.created_at > ?);",
            (now - int(offline_seconds), now - int(quiet_seconds))).fetchall()
        for (acct,) in rows:
            self.push_enqueue(con, acct, title=title, body=body, now=now)
        return len(rows)

    def push_drain(self, con, limit=20, sender=None, now=None):
        """Drena até `limit` linhas pending contra o sender plugável. Sucesso
        (retorno truthy) -> sent; NotImplementedError/qualquer exceção ->
        failed com last_error estável para o gate ler ('vapid_sender_' prefix).
        Sem subscription -> failed('no_subscription') (a fila não pode ficar
        presa por registro apagado). 404/410 do provedor -> o registro morto é
        apagado de push_subscription e a linha fica 'push_subscription_gone_N'
        (re-tentar subscription morta para sempre é pior que perder o aviso).
        Retry de failed é decisão de operador, não
        daqui. Retorna resumo; nunca levanta erro de envio para o chamador."""
        fn = sender or push_sender()
        if now is None:
            now = int(time.time())
        summary = {"pending": 0, "sent": 0, "failed": 0, "skipped": 0}
        rows = con.execute(
            "SELECT o.id, o.account_id, o.title, o.body, "
            "       s.endpoint, s.p256dh, s.auth "
            "FROM push_outbox o LEFT JOIN push_subscription s "
            "     ON s.account_id = o.account_id "
            "WHERE o.status = 'pending' ORDER BY o.id LIMIT ?;",
            (int(limit),)).fetchall()
        total_pending = con.execute(
            "SELECT COUNT(*) FROM push_outbox WHERE status = 'pending';"
        ).fetchone()[0]
        summary["pending"] = total_pending
        for oid, acct, title, body, endpoint, p256dh, auth in rows:
            if not endpoint:
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = 'no_subscription' WHERE id = ?;",
                    (oid,))
                con.commit()
                summary["failed"] += 1
                continue
            sub = {"account_id": acct, "endpoint": endpoint,
                   "p256dh": p256dh, "auth": auth}
            try:
                delivered = bool(fn(sub, title, body))
            except NotImplementedError:
                # Mensagem do gate no harness: prefixo estável + detalhe só do
                # lado de fora do SQL (bind, nunca concatenação).
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    ("vapid_sender_unimplemented", oid))
                con.commit()
                summary["failed"] += 1
                continue
            except PushSubscriptionGone as exc:
                # 404/410 (RFC 8030 §5.4): a subscription morreu no provedor.
                # Re-tentar para sempre é pior que perder o aviso — o registro
                # sai do banco e a linha confessa o motivo. Bind, nunca
                # concatenação de SQL.
                con.execute("DELETE FROM push_subscription WHERE account_id = ?;",
                            (acct,))
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    ("push_subscription_gone_%d" % exc.status, oid))
                con.commit()
                summary["failed"] += 1
                continue
            except Exception as e:
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    (str(type(e).__name__) + ": " + str(e)[:180], oid))
                con.commit()
                summary["failed"] += 1
                continue
            if delivered:
                con.execute(
                    "UPDATE push_outbox SET status = 'sent', attempts = "
                    "attempts + 1, sent_at = ?, last_error = NULL WHERE id = ?;",
                    (now, oid))
                con.commit()
                summary["sent"] += 1
            else:
                con.execute(
                    "UPDATE push_outbox SET attempts = attempts + 1, "
                    "last_error = 'sender_refused' WHERE id = ?;", (oid,))
                con.commit()
                summary["skipped"] += 1
        return summary


    def multi_account_suspicions(self, con):
        # A impressão digital é COLUNA de telemetry_event (migration 030), não uma
        # tabela: a consulta selecionava 'fp' — que só existia na tabela
        # device_fingerprint criada aqui e nunca populada por ninguém — e
        # estourava "no such column: fp", derrubando o /metrics inteiro (500) em
        # qualquer banco migrado. Alias explícito + nada de DDL morto.
        now = int(time.time())
        rows = con.execute("""
            SELECT fingerprint AS fp, COUNT(DISTINCT account_id) as acct_count
            FROM telemetry_event
            WHERE kind = 'login' AND created_at > ? AND fingerprint != ''
            GROUP BY fingerprint HAVING acct_count >= 3;
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
            for sku_row, n, tot, gross, cur in con.execute(
                    "SELECT json_extract(payload, '$.sku'), COUNT(*), "
                    "COALESCE(SUM(amount), 0), COALESCE(SUM(price_paid), 0), "
                    "COALESCE(MAX(currency), '') FROM grant_queue "
                    "WHERE status = 'processed' GROUP BY 1;").fetchall():
                # units = gem/itens concedidos; gross_minor = dinheiro de verdade
                # (centavos, K1). As duas coisas não são intercambiáveis.
                sales[sku_row or "unknown"] = {"grants": n, "units": tot,
                                               "gross_minor": gross,
                                               "currency": cur}
        except sqlite3.Error:
            pass
        # Receita por moeda (nunca somada entre moedas — BRL e USD não são o
        # mesmo número). arppu = bruto / pagantes únicos; arpu é esta divideda
        # por accounts.active_24h/total, que já estão nesta resposta.
        money = {}
        try:
            for cur, gross, buys, payers in con.execute(
                    "SELECT currency, COALESCE(SUM(price_paid), 0), COUNT(*), "
                    "COUNT(DISTINCT account_id) FROM grant_queue "
                    "WHERE status = 'processed' AND price_paid > 0 "
                    "GROUP BY currency;").fetchall():
                money[cur or "unknown"] = {
                    "gross_minor": gross, "purchases": buys, "payers": payers,
                    "arppu_minor": int(round(gross / float(payers))) if payers else 0,
                }
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
        # K1: coorte D1/D7/D30 lida da view `cohort_retention` (migration 045) — é
        # a régua reescrita de ROADMAP_COMERCIAL §Semana 2 medida em contas. Não é
        # o `retention_d1` ali embaixo, que compara janelas móveis de 24 h e
        # responde outra pergunta. View ausente (DB pré-045) = bloco vazio:
        # indisponível não é zero.
        cohort = {}
        try:
            c_n, c_d1, c_d7, c_d30 = con.execute(
                "SELECT COUNT(*), COALESCE(SUM(d1), 0), COALESCE(SUM(d7), 0), "
                "COALESCE(SUM(d30), 0) FROM cohort_retention;").fetchone()
            cohort = {"accounts": c_n, "d1": c_d1, "d7": c_d7, "d30": c_d30}
        except sqlite3.Error:
            pass
        return {
            "gems": {"mint": gems[0], "burn": gems[1], "stock": stock[0]},
            "gold_7d": {"faucet": gold7[0]},
            "trades_7d": {"count": trades7[0], "fees_burned": fees7[0]},
            "vip_active": vip[0],
            "accounts": {"total": accts[0], "active_24h": accts[1]},
            "retention_d1": {"cohort": d1[0], "retained": d1[1]},
            "retention_cohort": cohort,
            "settles_24h": {"count": settles[0], "avg_eff": round(settles[1], 3)},
            "logins_24h": logins[0],
            "reconcile": {"divergences": recon[0], "at": recon[1]} if recon else None,
            "grants_pending": self.pending(con),
            "guilds": guilds[0],
            "ah_open": ah[0],
            "season_active": season[0] if season else None,
            "sales_by_sku": sales,
            "revenue_by_currency": money,
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
                if sku.startswith("_"):
                    continue  # declaração/comentário do arquivo, não item de loja
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
        if path == "/push/vapid":
            # Readiness do sender + a chave pública VAPID. Nada aqui é segredo:
            # `public_key` é exatamente o `applicationServerKey` que o service
            # worker precisa conhecer para assinar, e o header `k` da RFC 8292
            # é público por definição. NÃO toca o banco e nunca ecoa a privada;
            # sem chave configurada responde apenas ready=false + o rótulo do
            # motivo. O nginx do serviço `web` não proxya /push/*; esta rota é
            # para o caminho direto do deploy (e para o harness).
            return self._push_vapid_status()
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/checkout/intents":
            return self._checkout_intent()
        if parsed.path == "/checkout/preference":
            return self._checkout_preference()
        if parsed.path == "/checkout/simulate":
            return self._checkout_simulate()
        if parsed.path == "/push/test":
            # SOM-W5: fila de push NUNCA é rota pública — o proxy do nginx só
            # conhece /checkout/ e /webhooks/; mesmo assim o endpoint exige
            # token próprio e some quando o token não está configurado.
            return self._push_test()
        if parsed.path != "/webhooks/payments":
            return self._send(404, {"error": "not_found"})
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        provider = self.server.provider
        # True só quando o payment foi re-buscado na API do provedor (dado
        # autoritativo p/ o cross-check de valor; corpo plano nunca é).
        payload_verified = False
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
                payload_verified = True
            elif getattr(self.server, "allow_unverified", False):
                # Sandbox EXPLÍCITO (só com SHAMBLETA_MP_ALLOW_UNVERIFIED=1):
                # corpo plano já traz account_id/sku. NUNCA em produção.
                try:
                    payload_data = json.loads(raw.decode()) if raw else {}
                except (ValueError, UnicodeDecodeError):
                    return self._send(400, {"error": "bad_json"})
                payload_verified = False
            else:
                # Fail-closed: provider real sem access token → o corpo NÃO é
                # confiável; nenhum grant sai de payload não verificado.
                # O MP reenvia; o operador configura o token e o próximo
                # webhook processa normalmente (idempotente por payment id).
                return self._send(503, {"error": "checkout_unavailable"})
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
        if norm is None and provider == "mercadopago" and payload_verified:
            status = str(payload_data.get("status", ""))
            # charged_back NÃO é evento de entrega: o provedor já tirou o
            # dinheiro e nenhum webhook de "refund" nosso o precede. Sem clawback
            # aqui, a conta fica com as gems pagas e o prejuízo só no provedor.
            # O amount NÃO vem do provedor: resolve_grant_items re-deriva do
            # catálogo (mesmo caminho do grant original, CDC).
            if is_reversal_event(status,
                                 lambda: self._payment_was_granted(
                                     str(payload_data.get("id") or ""))):
                return self._chargeback_clawback(payload_data)
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
        # Beta fechado: pagamento verificado com valor divergente do catálogo
        # (anunciado = cobrado, CDC) não concede — operador investiga.
        if payload_verified and not check_payment_amount(
                self.server.catalog, norm["sku"], payload_data):
            alert("webhook amount mismatch sku=%r" % (norm.get("sku"),))
            return self._send(400, {"error": "amount_mismatch"})
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
                    con, account_id, norm["sku"], items, key, provider,
                    norm.get("price_paid", 0), norm.get("currency", ""))
        except sqlite3.Error as e:
            alert("webhook DB error: %s" % e, "error")
            return self._send(500, {"error": "db_error", "detail": str(e)})
        if len(statuses) == 1:
            self._send(200, {"status": statuses[0]})
        else:
            self._send(200, {"status": "ok", "items": statuses})

    def _enqueue_items(self, con, account_id, sku, items, key, provider,
                       price_paid=0, currency=""):
        """Enfileira 1 grant por item (bundle = N linhas). Item único mantém a
        chave original (ledger `grant:<key>` estável); bundle usa chaves
        derivadas determinísticas (redelivery = duplicate, sem crédito duplo).

        O dinheiro de UMA compra vai inteiro na primeira linha: as N linhas do
        bundle são a mesma transação, e preço por linha faria SUM(price_paid)
        contar a venda N vezes. Todas compartilham o mesmo sku no payload, então
        a receita por SKU continua saindo certa do GROUP BY."""
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
                con, k, account_id, kind, amount, payload,
                price_paid if i == 0 else 0, currency if i == 0 else ""))
        return statuses

    def _payment_was_granted(self, payment_id):
        """Evidence de que ESTE payment gerou grant nosso (linha original da fila).

        Só é chamada no ramo `refused`/`rejected`/`cancelled`, onde o status do
        provedor não diz nada sobre entrega. A chave do grant original é o próprio
        payment id (`normalize_event` → `idempotency_key`), e bundle escreve pernas
        derivadas '<payment>:<i>:<kind>' — daí o prefixo. `LIKE` com um id que não
        é puro dígito seria wildcard solto em consulta de dinheiro, então id
        estranho responde 'não concedido' (fail-closed: sem clawback).

        Leitura: o companion lê `account`/`grant_queue`/`season` desde sempre e
        NUNCA escreve estado de saldo — ver _chargeback_clawback."""
        if not payment_id or not payment_id.isdigit():
            return False
        try:
            with self.server.store.connect() as con:
                row = con.execute(
                    "SELECT 1 FROM grant_queue WHERE kind <> 'chargeback' "
                    "AND (idempotency_key = ? OR idempotency_key LIKE ?) LIMIT 1;",
                    (payment_id, payment_id + ':%')).fetchone()
            return row is not None
        except sqlite3.Error as e:
            alert("chargeback lookup DB error: %s" % e, "error")
            return False

    def _chargeback_clawback(self, payload_data):
        """Registra o clawback na fila do jogo. NÃO debit nada: quem move saldo é
        o servidor de jogo (CheckoutService._ApplyGrantRaw), único writer de
        `wallet`/`ledger_transaction` sob o queryMutex — a mesma divisão que o
        estorno do art.49 já usa (o jogo reverte as gems e marca 'refunded'; o
        companion só chama a API do provedor no --refund-sweep).

        O payload do provedor não carrega o que decidiria o débito: `status`,
        `id`, `external_reference` ('<account>:<sku>'), `metadata.shambleta_sku` e
        `transaction_amount` (o cobrado, em centavos via _paid_money). Não existe
        campo "gems consumidas" nem "saldo pago" — e nada aqui inventa um: o
        amount re-derivado do catálogo é a DÍVIDA pedida, e quanto disso ainda
        existe como gem paga decidido pelo jogo na hora de aplicar, que é também
        onde o rombo vira linha visível (grant_queue.error + fila de revisão)."""
        key = str(payload_data.get("id") or "")
        if not key:
            return self._send(400, {"error": "bad_grant"})
        acct, sku = parse_external_reference(payload_data.get("external_reference"))
        if sku is None:
            sku = (payload_data.get("metadata") or {}).get("shambleta_sku")
        try:
            items = resolve_grant_items(self.server.catalog, sku, None)
        except CatalogError as e:
            alert("chargeback sku rejeitado (%s) sku=%r" % (str(e), sku))
            return self._send(400, {"error": str(e)})
        claw = [it for it in items if it[0] == "gems"]
        amount = int(claw[0][1]) if claw else 0
        # amount 0 não é "nada a fazer": SKU de tempo/passe não tem o que debitar
        # em gem, e a linha mesmo assim grava o clawback no ledger do jogo, que é
        # o que fecha a porta do art.49 para o mesmo payment. O produto entregue é
        # decisão de operador, não deste handler.
        paid, currency = _paid_money(payload_data)
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(con, acct)
                if account_id is None:
                    alert("chargeback sem conta para payment %s (sku=%r)" % (key, sku))
                    return self._send(200, {"status": "ignored"})
                status = self.server.store.enqueue(
                    con, "%s:chargeback" % key, account_id, "chargeback", amount,
                    {"sku": sku, "provider": "mercadopago", "kind": "chargeback",
                     "payment_id": key},
                    price_paid=paid, currency=currency)
        except sqlite3.Error as e:
            alert("chargeback DB error: %s" % e, "error")
            return self._send(500, {"error": "db_error", "detail": str(e)})
        # `enqueue` responde queued|duplicate: numa redelivery do mesmo charged_back
        # a linha UNIQUE devolve duplicate e o provedor precisa ver o 200, não um
        # retry infinito. O distinguishing fica no corpo para o operador.
        return self._send(200, {"status": "chargeback_queued", "enqueue": status})

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            return json.loads(raw.decode()) if raw else {}, raw
        except (ValueError, UnicodeDecodeError):
            return None, raw

    def _push_test(self):
        """POST /push/test — consome a fila push_outbox contra o sender
        plugável e devolve o resumo. Fail-closed nos dois sentidos: sem
        SHAMBLETA_PUSH_ADMIN_TOKEN configurado o endpoint não existe (503);
        com ele, exige X-Push-Token igual (const-time). Corpo opcional
        {"limit": N}. Sem chave VAPID no deploy nada é entregue: as linhas
        viram failed('vapid_sender_unimplemented') — é isso que CanDeliver()
        espera antes de o toggle aparecer para o jogador. Com a chave, o POST
        é o sender real (push_vapid) e a linha vira sent apenas com 2xx do
        provedor."""
        token = getattr(self.server, "push_admin_token", "")
        if not token:
            return self._send(503, {"error": "push_disabled"})
        if not _const_time(self.headers.get("X-Push-Token", ""), token):
            return self._send(401, {"error": "bad_token"})
        data, _raw = self._read_json()
        if data is None:
            return self._send(400, {"error": "bad_json"})
        try:
            limit = int(data.get("limit", 20))
        except (TypeError, ValueError):
            return self._send(400, {"error": "bad_grant"})
        limit = max(1, min(limit, 100))
        try:
            with self.server.store.connect() as con:
                summary = self.server.store.push_drain(con, limit=limit)
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e),
                                    "hint": "apply migration 052_web_push"})
        return self._send(200, {"status": "ok", "sender": os.environ.get(
            PUSH_SENDER_ENV, "vapid"), "drain": summary})

    def _push_vapid_status(self):
        """GET /push/vapid — o readiness do sender + a chave pública VAPID.
        É o handshake que `WebPush.CanDeliver()` espelha do lado do jogo: sem
        segredo configurado responde ready=false com um rótulo coarse e NENHUMA
        chave; com segredo, devolve a pública (os 87 caracteres de
        `applicationServerKey`, pública por definição — é o `k` do header
        `Authorization: vapid` da RFC 8292). A privada, o subject e qualquer
        mensagem de erro fina nunca saem daqui."""
        pv = load_push_vapid()
        sender = os.environ.get(PUSH_SENDER_ENV, "vapid")
        if pv is None:
            return self._send(200, {"ready": False, "sender": sender,
                                    "reason": "module_unavailable"})
        ready, info = pv.push_ready()
        if not ready:
            reason = info if info in _PUSH_PUBLIC_REASONS else "not_configured"
            return self._send(200, {"ready": False, "sender": sender,
                                    "reason": reason})
        return self._send(200, {"ready": True, "sender": sender,
                                "public_key": info,
                                "content_encoding": "aes128gcm"})

    def _resolve_checkout_account(self, con, data):
        """Identidade da conta p/ checkout, a partir da SESSÃO (beta fechado):
        o client apresenta o auth_token do login; o dono do token é a conta —
        account_id do cliente só é aceito se igual ao dono (anti cross-account).
        Retorna (account_id, None) ou (None, motivo): 'missing_token'/'expired'
        → 401; 'mismatch' (token válido, conta alheia) → 403. Exceção explícita
        de dev: allow_dev_checkout (curl de staging) resolve por username."""
        token = data.get("auth_token")
        if not token:
            if getattr(self.server, "allow_dev_checkout", False):
                legacy = self.server.store.account_id(
                    con, data.get("account_id"), data.get("username"))
                if legacy is not None:
                    return legacy, None
            return None, "missing_token"
        owner = verify_session_token(con, data.get("account_id"), token)
        if owner is not None:
            return owner, None
        if data.get("account_id") and verify_session_token(con, None, token):
            return None, "mismatch"
        return None, "expired"

    def _checkout_intent(self):
        """Fase A (sandbox): a loja pede {auth_token, sku} (+ account_id
        opcional p/ conferência) e recebe o external_reference + preço do
        catálogo. O pagamento real (MP checkout pro) usa esse
        external_reference; o grant entra pelo webhook idempotente. Sem
        chamada ao MP aqui. Conta sem prova de sessão → 401/403."""
        data, _raw = self._read_json()
        if data is None:
            return self._send(400, {"error": "bad_json"})
        sku = data.get("sku")
        if not is_sellable_sku(self.server.catalog, sku):
            return self._send(400, {"error": "unknown_sku"})
        try:
            items = resolve_grant_items(self.server.catalog, sku)
        except CatalogError as e:
            return self._send(400, {"error": str(e)})
        try:
            with self.server.store.connect() as con:
                account_id, auth_err = self._resolve_checkout_account(con, data)
                if account_id is None:
                    code = 403 if auth_err == "mismatch" else 401
                    return self._send(code, {"error": auth_err})
                if not consent_currently_accepted(con, account_id,
                                                  self.server.catalog):
                    return self._send(403, {"error": "consent_required"})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
                # G1: passe sem temporada ativa não é vendável — o grant falha
                # fechado dentro do jogo, então a recusa tem que acontecer antes
                # de o Mercado Pago cobrar, não depois.
                season = season_offer_status(con, self.server.catalog, sku)
                if not season["eligible"]:
                    return self._send(409, {"error": season["reason"],
                                            "season_offer": season})
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
            "season_offer": season,
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
        if not is_sellable_sku(self.server.catalog, sku):
            return self._send(400, {"error": "unknown_sku"})
        try:
            with self.server.store.connect() as con:
                account_id, auth_err = self._resolve_checkout_account(con, data)
                if account_id is None:
                    code = 403 if auth_err == "mismatch" else 401
                    return self._send(code, {"error": auth_err})
                # A preferência é o ponto onde o cartão/Pix é aberto: o mesmo
                # gate da intent vale aqui, porque esta rota é alcançável sem
                # passar pelo game server (mesma origem, sem sessão de jogo).
                if not consent_currently_accepted(con, account_id,
                                                  self.server.catalog):
                    return self._send(403, {"error": "consent_required"})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
                # G1: passe sem temporada ativa não é vendável — o grant falha
                # fechado dentro do jogo, então a recusa tem que acontecer antes
                # de o Mercado Pago cobrar, não depois.
                season = season_offer_status(con, self.server.catalog, sku)
                if not season["eligible"]:
                    return self._send(409, {"error": season["reason"],
                                            "season_offer": season})
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
        if not is_sellable_sku(self.server.catalog, sku):
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
                # Replay do mesmo pagamento: chaves derivadas já existem →
                # idempotente (não é nova compra; pula o gate one-time).
                prior = con.execute(
                    "SELECT status FROM grant_queue WHERE idempotency_key = ? "
                    "OR idempotency_key LIKE ? ORDER BY id;",
                    (key, key + ":%")).fetchall()
                if prior:
                    return self._send(200, {"status": "ok", "replay": True,
                                            "items": [r[0] for r in prior]})
                # Compra nova (não replay): o sandbox cria um grant com
                # `price_paid` do mesmo jeito que o webhook criaria, então vale o
                # mesmo gate das outras duas portas — inclusive em staging, onde
                # `allow_dev_checkout` deixa resolver conta por username.
                if not consent_currently_accepted(con, account_id,
                                                  self.server.catalog):
                    return self._send(403, {"error": "consent_required"})
                offer = starter_offer_status(con, self.server.catalog,
                                             account_id, sku)
                if not offer["eligible"] and (self.server.catalog[sku].get("one_time")):
                    return self._send(409, {"error": offer["reason"],
                                            "starter_offer": offer})
                # G1: passe sem temporada ativa não é vendável — o grant falha
                # fechado dentro do jogo, então a recusa tem que acontecer antes
                # de o Mercado Pago cobrar, não depois.
                season = season_offer_status(con, self.server.catalog, sku)
                if not season["eligible"]:
                    return self._send(409, {"error": season["reason"],
                                            "season_offer": season})
                paid, currency = catalog_price_minor(self.server.catalog, sku)
                statuses = self._enqueue_items(
                    con, account_id, sku, items, key, "sandbox", paid, currency)
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e)})
        self._send(200, {"status": "ok", "items": statuses})



def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", default="",
                    help="caminho do live.db do game server (obrigatório em "
                         "todo modo salvo --push-vapid-keygen)")
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
                    default=os.environ.get("SHAMBLETA_CATALOG_FILE", "") or default_catalog_path(),
                    help="JSON de catálogo SKU->grant; default: data/conf/paid_catalog.json "
                         "(/app/paid_catalog.json no container); sem o arquivo, o embutido")
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
    ap.add_argument("--mp-allow-unverified",
                    default=(os.environ.get("SHAMBLETA_MP_ALLOW_UNVERIFIED", "") == "1"),
                    action="store_true",
                    help="SANDBOX EXPLÍCITO: aceitar corpo plano no webhook "
                         "mercadopago sem re-fetch (sem access token). NUNCA em "
                         "produção — sem ele, provider real sem token responde "
                         "503 e nenhum grant sai de payload não verificado")
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
    # ---- SOM-IDLE W5: web push (migration 052; sender default é o VAPID real
    # de push_vapid.py, que continua honesto: NotImplementedError sem chave
    # configurada — credencial ausente nunca vira envio) ----
    ap.add_argument("--push-register", action="store_true",
                    help="grava/upsert a subscription de push de uma conta "
                         "(exige --account --endpoint --p256dh --auth) e sai")
    ap.add_argument("--push-sweep", action="store_true",
                    help="varre contas offline com subscription e ENFILEIRA "
                         "aviso de retorno (nunca envia inline); exige a "
                         "migration 052 aplicada e sai")
    ap.add_argument("--push-drain", action="store_true",
                    help="drena a fila push_outbox contra o sender plugável "
                         "(SHAMBLETA_PUSH_SENDER; default vapid -> failed) e sai")
    ap.add_argument("--push-notify", action="store_true",
                    help="enfileira UMA notificação para --account e drena na "
                         "hora (exit 2 se o sender não entregou — com o sender "
                         "default nunca entrega)")
    ap.add_argument("--account", type=int, default=None,
                    help="account_id para as ações --push-*")
    ap.add_argument("--endpoint", default="",
                    help="URL do provedor de push (campo `endpoint` da subscription)")
    ap.add_argument("--p256dh", default="",
                    help="chave pública ECDH da subscription (base64url)")
    ap.add_argument("--auth", default="",
                    help="auth secret da subscription (base64url)")
    ap.add_argument("--title", default="", help="título da notificação --push-notify")
    ap.add_argument("--body", default="", help="corpo da notificação --push-notify")
    ap.add_argument("--offline-hours", type=int, default=24,
                    help="janela offline do --push-sweep (h; default 24)")
    ap.add_argument("--quiet-hours", type=int, default=72,
                    help="silêncio mínimo entre notificações da mesma conta (h; "
                         "default 72)")
    ap.add_argument("--push-admin-token",
                    default=os.environ.get(PUSH_ADMIN_TOKEN_ENV, ""),
                    help="token do endpoint interno POST /push/test "
                         "(vazio = endpoint desligado; nunca publicar /push/ no nginx)")
    ap.add_argument("--push-vapid-keygen", action="store_true",
                    help="gera um par VAPID P-256 descartável: a PRIVADA vai para "
                         "--push-vapid-key-out (modo 0600, nunca stdout/log) e só a "
                         "PÚBLICA é impressa; pare o resultado no segredo de deploy")
    ap.add_argument("--push-vapid-key-out", default="",
                    help="arquivo onde --push-vapid-keygen grava a chave privada "
                         "(obrigatório; não sobrescreve)")
    args = ap.parse_args()
    if not args.db and not args.push_vapid_keygen:
        # '--push-vapid-keygen' é o único modo que não toca o banco: o par
        # VAPID nasce antes de existir deploy, muitas vezes no laptop de quem
        # vai colar a pública no shell. Os demais modos exigem --db como antes.
        ap.error("the following arguments are required: --db")
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
    if args.push_vapid_keygen:
        # Gera um par VAPID descartável SEM tocar o banco. A privada nunca sai
        # por stdout (que viraria log): vai para --push-vapid-key-out com 0600 e
        # a saída pública traz só a pública + o caminho. O operador publica a
        # pública no shell (applicationServerKey) e guarda a privada no segredo.
        pv = load_push_vapid()
        if pv is None:
            sys.stderr.write("companion: push_vapid.py indisponivel para keygen\n")
            return 2
        if not args.push_vapid_key_out:
            sys.stderr.write("companion: --push-vapid-keygen exige "
                             "--push-vapid-key-out ARQUIVO (a privada nao vai "
                             "para stdout)\n")
            return 2
        try:
            priv, pub = pv.generate_keypair()
            fd = os.open(args.push_vapid_key_out,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(priv)
        except OSError as e:
            sys.stderr.write("companion: keygen falhou: %s\n" % e)
            return 2
        print("companion: VAPID keygen privada=%s (0600) publica=%s"
              % (args.push_vapid_key_out, pub), flush=True)
        return 0
    if (args.push_register or args.push_sweep or args.push_drain
            or args.push_notify):
        if not os.path.exists(args.db):
            sys.stderr.write("companion: database not found: %s\n" % args.db)
            return 2
        store = Store(args.db)
        try:
            if args.push_register:
                if not (args.account and args.endpoint and args.p256dh
                        and args.auth):
                    sys.stderr.write(
                        "companion: --push-register exige --account --endpoint "
                        "--p256dh --auth\n")
                    return 2
                with store.connect() as con:
                    if not store.push_register(con, args.account, args.endpoint,
                                               args.p256dh, args.auth):
                        sys.stderr.write("companion: unknown account %s\n"
                                         % args.account)
                        return 2
                print("companion: push registered account=%s" % args.account,
                      flush=True)
                return 0
            if args.push_notify:
                if not args.account:
                    sys.stderr.write("companion: --push-notify exige --account\n")
                    return 2
                with store.connect() as con:
                    if store.account_id(con, args.account) is None:
                        sys.stderr.write("companion: unknown account %s\n"
                                         % args.account)
                        return 2
                    oid = store.push_enqueue(con, args.account,
                                             title=args.title or None,
                                             body=args.body or None)
                    summary = store.push_drain(con, limit=100)
                print("companion: push notify id=%s drain=%s" % (oid, summary),
                      flush=True)
                # Honesto: sem sender implementado nada saiu do prédio.
                return 0 if summary["sent"] > 0 else 2
            if args.push_sweep:
                res = push_sweep(args.db,
                                 offline_seconds=args.offline_hours * 3600,
                                 quiet_seconds=args.quiet_hours * 3600,
                                 title=args.title or None,
                                 body=args.body or None)
                print("companion: push sweep: %s" % res, flush=True)
                return 0
            res = push_drain(args.db)
            print("companion: push drain: %s" % res, flush=True)
            return 0
        except sqlite3.Error as e:
            sys.stderr.write("companion: push tables missing? apply migration "
                             "052_web_push (%s)\n" % e)
            return 2
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
    server.allow_unverified = bool(args.mp_allow_unverified)
    server.mp_back_urls_base = args.mp_back_urls_base
    server.catalog = catalog
    server.tolerance = args.tolerance
    server.allow_dev = bool(args.allow_dev)
    server.allow_dev_checkout = bool(args.allow_dev_checkout or args.allow_dev)
    server.push_admin_token = args.push_admin_token
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
