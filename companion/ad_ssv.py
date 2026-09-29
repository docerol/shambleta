#!/usr/bin/env python3
"""SSV de anúncio recompensado — a PROVA DE EXIBIÇÃO que faltava (gasto auditado).

O buraco que este módulo fecha (medido na auditoria de 2026-09-28): quem dizia
"o jogador assistiu ao anúncio" era o próprio jogador. `AdsCosmeticsService.gd`
mintava uma linha em `ad_slot` (migration 048) e o `DELETE` condicionado daquela
linha era o crédito — ou seja, a única coisa entre o prêmio e o client era um
nonce que o próprio client recebeu. `sources/ads/AdProvider.gd:19-24` confessava
isso com todas as letras ("Ainda sem prova de exibição").

O contrato aqui é o oposto:

    jogo  ->  MintAdSlot cria a linha `ad_slot` NASCENDO PENDENTE
              (`expires_at = 0`, nonce = id de correlação entregue ao portal)
    portal de anúncio -> POST /webhooks/ads {user_id, account_id, placement,
              transaction_id} com `X-Ad-Signature: t=<ts>,v1=<sig>`
    este módulo -> verifica a assinatura com o segredo compartilhado (HMAC-SHA256
              sobre "<ts>.<corpo>", o MESMO esquema de `verify_stripe_signature`
              em companion/server.py), recusa ts fora da janela, ativa a linha UMA
              única vez e nada mais
    jogo  ->  o caminho de sempre (`WatchAd`/`ClaimAdChest`/`ClaimAdBossKey`/
              `RerollDailyShopAd`) consome a linha ativada e credita

CRÉDITO: este módulo nunca credita nada. Ele só troca `expires_at = 0` (prova
pendente) por `expires_at = agora + janela` (prova feita). Quem entrega o baú, a
chave, o reroll ou a hora de AFK continua sendo `AdsCosmeticsService` — cap por
placement, VIP, telemetria com prova de gravação e transação permanecem exatamente
onde estão. É "creditar pelo caminho de economia que já existe" no sentido literal:
a linha ativada é a única coisa que o caminho de sempre aceita.

ANTI-REPLAY: a ativação é um `UPDATE` CONDICIONADO com `rowcount`, o mesmo
formato de `Store.enqueue` (`INSERT OR IGNORE` + rowcount → queued/duplicate) e de
`SQL.ConsumeTwoFactorToken`. A segunda chamada com a mesma assinatura acha
`expires_at = 0` falso e devolve `duplicate` — a linha já não está pendente, então
não há segunda ativação nem segunda janela.

EXPIRAÇÃO, nos dois sentidos: o ts do cabeçalho fora da janela é recusado antes de
qualquer escrita (mesma régua do webhook de dinheiro, `SHAMBLETA_WEBHOOK_TOLERANCE`);
e uma pendência que o portal nunca confirmou vence sozinha (`created_at` velho), o
que devolve a cota do dia ao jogador — sem isto, um SDK mudo travaria o placement.

FECHADO por construção (fail-closed), e é isto que torna a rota utilizável em
produção:
  * sem segredo configurado a rota responde 503 e NENHUMA linha muda;
  * assinatura ruim, corpo malformado, reivindicação malformada → nenhum crédito;
  * `account_id`/`placement` que divergem da linha mintada não ativam nada (o
    nonce é de A e do placement X: ele não vira prêmio de B nem de Y).

SEGREDO: só o NOME mora aqui (`AD_SSV_SECRET_ENV`). O valor chega pelo ambiente do
processo, exatamente como `PUSH_ADMIN_TOKEN_ENV` e as chaves VAPID de
`companion/push_common.py` (constante de NOME + `os.environ`); em deploy ele é um
secret da plataforma (Coolify). Nenhum valor, nenhum ts aceito, nenhum nonce
aparece em log ou resposta: a resposta nomeia o VEREDITO, nunca a credencial.

SCHEMA: nenhuma DDL aqui — a fonte única é `data/conf/migrations/048_ad_slot_nonce.sql`
(mesma regra das tabelas de push, no comentário de `class Store`). Banco sem a
migration 048 levanta `sqlite3.Error`, que a rota traduz em 500 com o hint.

Stdlib apenas: `hmac` + `hashlib` + `time` + `json` + `re`, como o resto do pacote.

Rodar a suíte: `python3 companion/test_ad_ssv.py`.
"""

import hashlib
import hmac
import json
import os
import re
import sqlite3
import time

# Nome da variável de ambiente (NUNCA o valor). Exigido por
# scripts/check_secrets.sh (3b): todo `*_ENV` do companion tem de estar declarado
# em `.env.example` com valor vazio.
AD_SSV_SECRET_ENV = "SHAMBLETA_AD_SSV_SECRET"

# Cabeçalho da assinatura. Um nome próprio, e não o `X-Signature` legado do modo
# sandbox de pagamento: os dois caminhos assinam coisas diferentes com segredos
# diferentes, e confundí-los seria usar o segredo do dinheiro num webhook de ads.
AD_SSV_HEADER = "X-Ad-Signature"

# Janela do corredor, em segundos, quando o servidor não diz a sua. Espelha
# `EconomyCatalog.AD_SLOT_TTL_SECONDS` (sources/economy/EconomyCatalog.gd) — o
# tempo entre mintar o slot e o portal confirmar. Em runtime a janela lida é a do
# próprio processo (`server.tolerance`, SHAMBLETA_WEBHOOK_TOLERANCE), para que ts
# recusado e pendência vencida não sejam dois relógios diferentes no mesmo deploy.
DEFAULT_WINDOW = 300

# Teto de corpo: o nginx do serviço `web` já corta em 16k (deploy/web/nginx.conf,
# bloco `^~ /webhooks/`). Conferir aqui de novo custa uma comparação e fecha a
# porta para quem falar direto com o companion na porta 8901.
MAX_BODY = 16384

# Formas aceitas. O nonce é o hex de 16 bytes que `AdsCosmeticsService._NewAdNonce`
# gera (`Crypto.generate_random_bytes(16).hex_encode()`); placement é chave de
# `EconomyCatalog.AD_PLACEMENTS`; o transaction_id é opaco, mas entra na pergunta
# porque sem ele o portal não tem como a gente correlacionar a chamada.
_NONCE_RE = re.compile(r"\A[0-9a-f]{32}\Z")
_PLACEMENT_RE = re.compile(r"\A[a-z][a-z0-9]{0,15}\Z")
_TXN_RE = re.compile(r"\A[A-Za-z0-9_.:\-]{1,128}\Z")


def secret():
    """O segredo compartilhado do portal, lido do ambiente a CADA chamada. Vazio =
    rota desligada (é o default: um deploy sem o secret não credita anúncio
    nenhum). Ler no uso e não no import é o que deixa a suíte testar os dois
    estados sem reiniciar processo."""
    return os.environ.get(AD_SSV_SECRET_ENV, "").strip()


def _const_time(a, b):
    """Cópia de `server._const_time`: comparar HMAC com `==` é comparar tempo de
    resposta. O import reverso (ad_ssv → server) fecharia um ciclo, então o
    primitivo é daqui — três linhas que não mutam estado."""
    return hmac.compare_digest(a.encode() if isinstance(a, str) else a,
                               b.encode() if isinstance(b, str) else b)


def expected_signature(sec, ts, raw_body):
    """O que o portal tem de mandar: hex(HMAC-SHA256(segredo, "<ts>.<corpo>")).
    Exportado para que o contrato seja uma pergunta respondível, não folclore — é
    a mesma string que `verify_stripe_signature` monta no webhook de dinheiro."""
    return hmac.new(sec.encode(), ("%d." % int(ts)).encode() + raw_body,
                    hashlib.sha256).hexdigest()


def parse_header(header_value):
    """'t=<ts>,v1=<sig>[,v1=<sig>...]' → (ts:int|None, [sig...]). Nada de ts
    flutuante, nada de vírgula dentro do valor: a gramática é a do Stripe."""
    ts = None
    sigs = []
    for part in (header_value or "").split(","):
        part = part.strip()
        if part.startswith("t="):
            ts = part[2:]
        elif part.startswith("v1="):
            sigs.append(part[3:])
    if ts is None or not sigs:
        return None, []
    try:
        return int(ts), sigs
    except ValueError:
        return None, []


def verify_signature(sec, header_value, raw_body, window=DEFAULT_WINDOW, now=None):
    """Autentica a ORIGEM da chamada e o PRAZO dela. Recusa segredo vazio (a rota
    sem secret nem chega aqui, mas a função é pública e tem de mentir sozinha),
    ts ausente/não-numérico/fora da janela (abs, isto é, futuro demais também) e
    assinatura que não bate byte a byte."""
    if not sec:
        return False
    ts, sigs = parse_header(header_value)
    if ts is None or not sigs:
        return False
    if now is None:
        now = int(time.time())
    if window <= 0 or abs(now - ts) > window:
        return False
    expect = expected_signature(sec, ts, raw_body)
    return any(_const_time(s, expect) for s in sigs)


def claim_of(data):
    """(nonce, account_id, placement, transaction_id) da reivindicação, ou ValueError.

    `user_id` é o nome que os portais de anúncios usam para "o dado que EU passei
    lá atrás": aqui é o nonce do `ad_slot` mintado pelo jogo. `nonce` é aceito como
    sinônimo, porque o contrato é nosso e um SDK próprio vai nomear o campo do jeito
    próprio. Os quatro campos são obrigatórios: o `account_id` e o `placement` não
    vêm para confiar no portal — vêm para a ativação EXIGIR que a linha seja daquele
    dono e daquele placement (ver `activate`)."""
    nonce = str(data.get("user_id") or data.get("nonce") or "").strip().lower()
    if not _NONCE_RE.match(nonce):
        raise ValueError("bad_nonce")
    raw_account = data.get("account_id")
    if not isinstance(raw_account, int) and not (isinstance(raw_account, str)
                                                 and raw_account.isdigit()):
        raise ValueError("bad_account")
    account_id = int(raw_account)
    if account_id <= 0:
        raise ValueError("bad_account")
    placement = str(data.get("placement") or "").strip().lower()
    if not _PLACEMENT_RE.match(placement):
        raise ValueError("bad_placement")
    txn = str(data.get("transaction_id") or "").strip()
    if not _TXN_RE.match(txn):
        raise ValueError("bad_transaction")
    return nonce, account_id, placement, txn


def activate(con, nonce, account_id, placement, now=None, window=DEFAULT_WINDOW):
    """A ÚNICA escrita deste módulo: troca o pendente por provado, uma vez.

    `expires_at = 0` é o marcador de "mintado, sem prova" — o `WHERE` por ele é o
    cadeado do uso único, do mesmo jeito que o `DELETE ... WHERE nonce = ?` do lado
    do jogo é. A linha ativada recebe `now + window` de vida: é a janela do
    jogador ir ao servidor reclamar o prêmio (`WatchAd`), não uma nova janela de
    confirmação do portal.

    Vereditos: `verified` (ativou agora), `duplicate` (já estava ativada — redelivery
    do portal), `unknown` (nonce que nunca existiu), `expired` (pendência velha: o
    portal chamou depois do corredor), `mismatch` (dono/placement divergentes). Os
    três últimos não creditam nada e não mudam nada.

    `transaction_id` NÃO é chave de dedupe aqui: a migration 048 não tem coluna para
    isso e não se inventa DDL escondida num webhook. O dedupe é o nonce, que é
    UNIQUE (`ad_slot_nonce`) — registrar o id do portal seria uma migration nova.
    """
    if now is None:
        now = int(time.time())
    cur = con.execute(
        "UPDATE ad_slot SET expires_at = ? "
        "WHERE nonce = ? AND account_id = ? AND placement = ? "
        "AND expires_at = 0 AND created_at >= ?;",
        (now + window, nonce, account_id, placement, now - window))
    con.commit()
    if cur.rowcount == 1:
        return "verified"
    row = con.execute(
        "SELECT account_id, placement, expires_at, created_at FROM ad_slot "
        "WHERE nonce = ?;", (nonce,)).fetchone()
    if row is None:
        return "unknown"
    if int(row[2]) > 0:
        return "duplicate"
    if int(row[3]) < now - window:
        return "expired"
    if int(row[0]) != int(account_id) or str(row[1]) != placement:
        return "mismatch"
    return "ignored"


def handle(handler):
    """POST /webhooks/ads — a rota, montada por `server.Handler.do_POST`.

    Ordem que importa: segredo → corpo → assinatura → forma → banco. Assinatura
    ANTES de qualquer parse de conteúdo, porque o corpo assinado é a única
    autoridade sobre o que foi afirmado (um JSON que só existe depois da
    verificação não pode influir nela); e ANTES de qualquer escrita.

    Códigos, espelhando o webhook de dinheiro no `do_POST` de `server.py`:
      503 sem segredo (rota desligada, fail-closed — nada muda no banco);
      401 assinatura ausente/ruim/fora do prazo;
      400 corpo ilegível ou reivindicação malformada;
      500 sqlite indisponível (hint aponta a migration 048);
      200 com `verified`/`duplicate`/`ignored`+motivo — ACK é de propósito: um
          veredito terminal reenviado para sempre pelo portal só enche a zona de
          rate-limit do `/webhooks/`, e nada muda por causa disso.
    """
    sec = secret()
    if not sec:
        return handler._send(503, {"error": "ad_ssv_disabled"})
    try:
        length = int(handler.headers.get("Content-Length", 0) or 0)
    except ValueError:
        return handler._send(400, {"error": "bad_body"})
    if length <= 0 or length > MAX_BODY:
        return handler._send(400, {"error": "bad_body"})
    raw = handler.rfile.read(length)
    window = int(getattr(handler.server, "tolerance", DEFAULT_WINDOW)
                 or DEFAULT_WINDOW)
    if not verify_signature(sec, handler.headers.get(AD_SSV_HEADER, ""),
                            raw, window):
        return handler._send(401, {"error": "bad_signature"})
    try:
        data = json.loads(raw.decode())
    except (ValueError, UnicodeDecodeError):
        return handler._send(400, {"error": "bad_json"})
    if not isinstance(data, dict):
        return handler._send(400, {"error": "bad_json"})
    try:
        nonce, account_id, placement, _txn = claim_of(data)
    except ValueError:
        return handler._send(400, {"error": "bad_claim"})
    now = int(time.time())
    try:
        with handler.server.store.connect() as con:
            status = activate(con, nonce, account_id, placement, now, window)
    except sqlite3.Error as e:
        return handler._send(500, {"error": "db_error", "detail": str(e),
                                  "hint": "apply migration 048_ad_slot_nonce"})
    if status in ("verified", "duplicate"):
        return handler._send(200, {"status": status})
    return handler._send(200, {"status": "ignored", "reason": status})
