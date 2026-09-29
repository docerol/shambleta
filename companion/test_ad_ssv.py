#!/usr/bin/env python3
"""Suíte do SSV de anúncio recompensado — `companion/ad_ssv.py`.

O que isto mede, na ordem em que a rota decide:

  1. ASSINATURA: HMAC-SHA256 sobre "<ts>.<corpo>" com o segredo do portal, o
     esquema da casa (`verify_stripe_signature`, companion/server.py) e nada mais;
  2. PRAZO: ts ausente, não-numérico, velho ou futuro fora da janela é recusado
     ANTES de qualquer escrita;
  3. USO ÚNICO: a ativação é um `UPDATE ... WHERE expires_at = 0` com `rowcount`,
     o mesmo formato de `Store.enqueue` (INSERT OR IGNORE + rowcount) e de
     `SQL.ConsumeTwoFactorToken`. Redelivery do portal acha `duplicate`;
  4. DONO/PLACEMENT: o `account_id` e o `placement` assinados têm de ser os da
     linha mintada — nonce de A não ativa a pendência de B, `chest` não vira
     `afkhoras`;
  5. FECHADO: sem segredo no ambiente a rota responde 503 e a linha continua
     pendente; e linha pendente NÃO é consumível pelo caminho do jogo (o `DELETE`
     de `_ConsumeAdSlot` filtra `expires_at > agora`), que é exatamente o que tira
     do client o poder de mintar crédito.

As réguas de crédito usam o MESMO SQL do jogo (`AdsCosmeticsService._ConsumeAdSlot`)
contra a migration 048 real, aplicada do arquivo — não uma colagem: tabela
inventada aqui aprovaria um verificador que não funciona no banco de verdade.

O QUE ISTO NÃO PROVA, dito sem rodeio: o `Handler` abaixo é um jacaré com os três
atributos que `ad_ssv.handle` toca (`server.store`, `server.tolerance`,
`headers`/`rfile`/`_send`), não um socket. O portal de anúncio real nunca chamou
esta rota — não há SDK no repositório (`deploy/web/ads_bridge.js` ainda devolve
`done(false)`), e o nonce ainda não viaja ao portal como `user_id` (follow-up
declarado em `sources/ads/AdProvider.gd`). Um 200 de um portal de verdade continua
NÃO medido; o que está medido é que nenhum crédito sai sem ele.

Rodar: `python3 companion/test_ad_ssv.py`. Sai !=0 se falhar. Sem pytest: o
companion é stdlib-only por contrato.
"""

import io
import json
import os
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import ad_ssv                                              # noqa: E402
import server                                              # noqa: E402

CHECKS = 0
FAILS = []


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


def report(marker):
    """Fecha com a linha que os gates lêem (§24-8: o número de falhas vem DO
    marcador). Rótulo nomeia o problema, nunca um valor de segredo."""
    if FAILS:
        print("== %s: %d failures ==" % (marker, len(FAILS)))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("== %s: %d checks, 0 failures ==" % (marker, CHECKS))
    return 0


# Fixture desta suíte, não credencial: um valor sem forma de chave, usado só para
# o HMAC local. O segredo de produção chega por ambiente e nunca por arquivo.
FIXTURE_HMAC = "valor-de-teste-desta-suite"
NONCE = "a" * 32

_SAVED = os.environ.get(ad_ssv.AD_SSV_SECRET_ENV)


def with_secret(value=FIXTURE_HMAC):
    if value is None:
        os.environ.pop(ad_ssv.AD_SSV_SECRET_ENV, None)
    else:
        os.environ[ad_ssv.AD_SSV_SECRET_ENV] = value


def restore():
    if _SAVED is None:
        os.environ.pop(ad_ssv.AD_SSV_SECRET_ENV, None)
    else:
        os.environ[ad_ssv.AD_SSV_SECRET_ENV] = _SAVED


MIG048 = os.path.join(ROOT, "data", "conf", "migrations", "048_ad_slot_nonce.sql")


def fresh_db():
    """Banco com a migration 048 REAL aplicada do arquivo — a fonte única do
    schema, a mesma regra das suítes irmãs (`test_webhook.py`, `test_security.py`)."""
    tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    tmp.close()
    con = sqlite3.connect(tmp.name)
    con.executescript(open(MIG048).read())
    con.commit()
    con.close()
    return tmp.name


def mint(con, nonce, account_id=7, placement="chest", created=None, expires=0,
         now=None):
    """A linha como `MintAdSlot` do jogo a escreve: em modo SSV ela nasce
    `expires_at = 0` (sem prova), e `created_at` é o carimbo do mint."""
    now = int(time.time()) if now is None else now
    con.execute(
        "INSERT INTO ad_slot (account_id, placement, nonce, created_at, "
        "expires_at) VALUES (?, ?, ?, ?, ?);",
        (account_id, placement, nonce, now if created is None else created,
         expires))
    con.commit()


def row(con, nonce):
    return con.execute("SELECT account_id, placement, nonce, created_at, "
                       "expires_at FROM ad_slot WHERE nonce = ?;",
                       (nonce,)).fetchone()


def n_rows(con):
    return con.execute("SELECT COUNT(*) FROM ad_slot;").fetchone()[0]


def consume_like_game(con, nonce, account_id=7, placement="chest", now=None):
    """O DELETE de `_ConsumeAdSlot` (sources/economy/AdsCosmeticsService.gd),
    palavra por palavra. É assim que esta suíte diz "creditou": o caminho de
    economia do jogo aceitou o token — nada aqui imita o crédito por conta própria."""
    now = int(time.time()) if now is None else now
    cur = con.execute(
        "DELETE FROM ad_slot WHERE nonce = ? AND account_id = ? AND placement = ? "
        "AND expires_at > ?;", (nonce, account_id, placement, now))
    con.commit()
    return cur.rowcount


def body_of(nonce, account_id=7, placement="chest", txn="tx-1"):
    return json.dumps({"user_id": nonce, "account_id": account_id,
                       "placement": placement, "transaction_id": txn}).encode()


def header_for(body, sec=FIXTURE_HMAC, ts=None):
    ts = int(time.time()) if ts is None else ts
    return "t=%d,v1=%s" % (ts, ad_ssv.expected_signature(sec, ts, body))


class _FakeServer(object):
    def __init__(self, db_path, tolerance=300):
        self.store = server.Store(db_path)
        self.tolerance = tolerance


class _Handler(object):
    """O mínimo de `BaseHTTPRequestHandler` que `ad_ssv.handle` toca."""

    def __init__(self, db_path, body, header=None, length=None, tolerance=300):
        self.server = _FakeServer(db_path, tolerance)
        self.headers = {"Content-Length": str(len(body) if length is None
                                              else length)}
        if header is not None:
            self.headers[ad_ssv.AD_SSV_HEADER] = header
        self.rfile = io.BytesIO(body)
        self.sent = []

    def _send(self, code, obj):
        self.sent.append((code, obj))

    @property
    def code(self):
        return self.sent[-1][0] if self.sent else None

    @property
    def obj(self):
        return self.sent[-1][1] if self.sent else {}


def call(db_path, body, header=None, **kw):
    h = _Handler(db_path, body, header, **kw)
    ad_ssv.handle(h)
    return h


# ---------------------------------------------------------------------------
# 0 — o schema real, e as portas que este módulo não pode abrir
# ---------------------------------------------------------------------------
ok(os.path.exists(MIG048), "a migration 048 existe (fonte única do schema ad_slot)")
_db = sqlite3.connect(fresh_db())
_cols = [r[1] for r in _db.execute("PRAGMA table_info(ad_slot);").fetchall()]
ok(_cols == ["id", "account_id", "placement", "nonce", "created_at", "expires_at"],
   "ad_slot tem exatamente as colunas da migration (sem DDL escondida no gateway): %s"
   % _cols)
_idx = [str(r[1]) for r in _db.execute("PRAGMA index_list(ad_slot);").fetchall()]
ok("ad_slot_nonce" in _idx,
   "o nonce é UNIQUE (o dedupe do SSV é a linha, não uma tabela nova)")
_db.close()

with_secret(None)
ok(ad_ssv.secret() == "", "sem a env, `secret()` é vazio (o default do deploy é o fechado)")
ok(not ad_ssv.verify_signature("", header_for(b"x"), b"x"),
   "verify com segredo vazio recusa (a função pública não pode mentir sozinha)")
ok(not ad_ssv.verify_signature(FIXTURE_HMAC, "", b"x"), "verify sem cabeçalho recusa")
with_secret()
raises(ValueError, lambda: ad_ssv.claim_of({"account_id": 7, "placement": "chest",
                                            "transaction_id": "t"}),
       "claim sem nonce levanta ValueError (nada é ativado por adivinhação)")
raises(ValueError, lambda: ad_ssv.claim_of({"user_id": "zz" * 16, "account_id": 7,
                                            "placement": "chest",
                                            "transaction_id": "t"}),
       "nonce fora do hex de 16 bytes é recusado por forma, não por LIKE no SQL")
raises(ValueError, lambda: ad_ssv.claim_of({"user_id": NONCE, "account_id": "7x",
                                            "placement": "chest",
                                            "transaction_id": "t"}),
       "account_id não-inteiro é recusado")
raises(ValueError, lambda: ad_ssv.claim_of({"user_id": NONCE, "account_id": 7,
                                            "placement": "chest; DROP",
                                            "transaction_id": "t"}),
       "placement com pontuação é recusado pela forma")
raises(ValueError, lambda: ad_ssv.claim_of({"user_id": NONCE, "account_id": 7,
                                            "placement": "chest"}),
       "sem transaction_id a reivindicação é recusada (nada a correlacionar)")

# ---------------------------------------------------------------------------
# 1 — assinatura válida ativa UMA vez, e o crédito é o caminho do jogo
# ---------------------------------------------------------------------------
_tmp1 = fresh_db()
_db = sqlite3.connect(_tmp1)
mint(_db, NONCE)
ok(row(_db, NONCE)[4] == 0, "mint em modo SSV cria a linha SEM PROVA (expires_at = 0)")
ok(consume_like_game(_db, NONCE) == 0,
   "linha sem prova NÃO credita pelo caminho do jogo (a palavra do client não basta)")

_b = body_of(NONCE)
_h = call(_tmp1, _b, header_for(_b))
ok(_h.code == 200 and _h.obj.get("status") == "verified",
   "assinatura válida: 200 verified na primeira chamada (%s)" % _h.obj)
_deadline = row(_db, NONCE)[4]
ok(_deadline > int(time.time()),
   "a ativação escreveu um prazo vivo (é só isso que ela faz: prova feita, não prêmio)")
ok(consume_like_game(_db, NONCE) == 1,
   "crédito: o DELETE de `_ConsumeAdSlot` do jogo aceita o token ativado, uma vez")
ok(consume_like_game(_db, NONCE) == 0,
   "e a segunda tentativa com o mesmo token não credita (uso único do lado do jogo)")
_db.close()
os.unlink(_tmp1)

# ---------------------------------------------------------------------------
# 2 — replay: o mesmo corpo assinado não ativa uma segunda vez
# ---------------------------------------------------------------------------
_tmp2 = fresh_db()
_db = sqlite3.connect(_tmp2)
mint(_db, NONCE)
_b = body_of(NONCE, txn="tx-2")
ok(call(_tmp2, _b, header_for(_b)).obj.get("status") == "verified",
   "replay: a primeira chamada ativa")
_after = row(_db, NONCE)[4]
_r = call(_tmp2, _b, header_for(_b))
ok(_r.code == 200 and _r.obj.get("status") == "duplicate",
   "replay do MESMO payload assinado: 200 duplicate, e o portal para de reenviar (%s)"
   % _r.obj)
ok(row(_db, NONCE)[4] == _after,
   "replay não reabre a janela (o prazo ativado é o mesmo: nada é creditável de novo)")
ok(n_rows(_db) == 1, "replay não cria linha nova em ad_slot")
ok(row(_db, NONCE)[:2] == (7, "chest"), "replay não movimentou dono nem placement")
_r2 = call(_tmp2, _b, header_for(_b, ts=int(time.time()) + 5))
ok(_r2.obj.get("status") == "duplicate",
   "re-assinado com ts novo continua duplicate: a prova é da linha, não do ts")
_db.close()
os.unlink(_tmp2)

# ---------------------------------------------------------------------------
# 3 — payload adulterado: nunca credita
# ---------------------------------------------------------------------------
_tmp3 = fresh_db()
_db = sqlite3.connect(_tmp3)
mint(_db, NONCE)
_sig = header_for(body_of(NONCE))
_h = call(_tmp3, body_of(NONCE, account_id=99), _sig)
ok(_h.code == 401 and _h.obj.get("error") == "bad_signature",
   "corpo trocado depois de assinado (dono): 401 bad_signature")
ok(row(_db, NONCE)[4] == 0 and consume_like_game(_db, NONCE) == 0,
   "e nada credita: a linha continua sem prova, o jogo continua recusando o token")
ok(call(_tmp3, body_of(NONCE, placement="afkhoras"), _sig).code == 401,
   "corpo trocado depois de assinado (placement): 401")
ok(call(_tmp3, body_of(NONCE) + b" ", _sig).code == 401,
   "um byte de espaço no corpo já quebra a assinatura")
ok(call(_tmp3, body_of("b" * 32), _sig).code == 401,
   "outro nonce com a assinatura alheia: 401 (o corpo inteiro é a mensagem assinada)")
_db.close()
os.unlink(_tmp3)

# A assinatura BATE, mas a reivindicação diverge da linha mintada: é recusada pelo
# UPDATE condicionado, não pela criptografia. É o ramo que um portal mentiroso com
# segredo válido atravessaria.
_tmp3b = fresh_db()
_db = sqlite3.connect(_tmp3b)
mint(_db, NONCE, account_id=7, placement="chest")
_b = body_of(NONCE, account_id=99, placement="chest")
_h = call(_tmp3b, _b, header_for(_b))
ok(_h.code == 200 and _h.obj.get("status") == "ignored"
   and _h.obj.get("reason") == "mismatch",
   "dono divergente com assinatura válida: ignored/mismatch, sem ativação (%s)" % _h.obj)
_b = body_of(NONCE, account_id=7, placement="afkhoras")
ok(call(_tmp3b, _b, header_for(_b)).obj.get("reason") == "mismatch",
   "placement divergente com assinatura válida: mesmo veredito, sem virar hora de AFK")
ok(row(_db, NONCE)[4] == 0, "nem uma nem outra ativação aconteceu")
ok(row(_db, NONCE)[:2] == (7, "chest"), "e a pendência continua sendo de 7, em chest")
_b = body_of("e" * 32)
ok(call(_tmp3b, _b, header_for(_b)).obj.get("reason") == "unknown",
   "nonce que nunca existiu: unknown (o gateway não minte por conta própria)")
ok(n_rows(_db) == 1, "e o gateway não criou linha nenhuma para o nonce desconhecido")
_db.close()
os.unlink(_tmp3b)

# ---------------------------------------------------------------------------
# 4 — prazo: ts ausente, velho, futuro, e pendência vencida
# ---------------------------------------------------------------------------
_now = int(time.time())
ok(not ad_ssv.verify_signature(FIXTURE_HMAC, "v1=" + "0" * 64, b"x", 300, _now),
   "cabeçalho sem t=: recusado (não há o que perdoar)")
ok(not ad_ssv.verify_signature(FIXTURE_HMAC, "t=abc,v1=" + "0" * 64, b"x", 300, _now),
   "ts não-numérico: recusado")
_b = b'{"x":1}'
ok(not ad_ssv.verify_signature(FIXTURE_HMAC, header_for(_b, ts=_now - 301), _b,
                              300, _now),
   "ts 301 s velho, janela 300: recusado (anti-replay por captura velha)")
ok(ad_ssv.verify_signature(FIXTURE_HMAC, header_for(_b, ts=_now - 299), _b, 300, _now),
   "ts 299 s dentro da janela: aceito (é a mesma janela do webhook de dinheiro)")
ok(not ad_ssv.verify_signature(FIXTURE_HMAC, header_for(_b, ts=_now + 900), _b,
                              300, _now),
   "ts futuro além da janela: recusado (abs, não só para trás)")

_tmp4 = fresh_db()
_db = sqlite3.connect(_tmp4)
mint(_db, NONCE, created=_now)
_b = body_of(NONCE)
_h = call(_tmp4, _b, header_for(_b, ts=_now - 9999), tolerance=300)
ok(_h.code == 401 and row(_db, NONCE)[4] == 0,
   "ts velho na rota: 401 e a linha continua sem prova (nenhum crédito)")
_db.execute("UPDATE ad_slot SET created_at = ? WHERE nonce = ?;", (_now - 4000, NONCE))
_db.commit()
_act = ad_ssv.activate(_db, NONCE, 7, "chest", _now, 300)
ok(_act == "expired",
   "pendência velha (created_at fora do corredor): expired, não ativa (%s)" % _act)
ok(row(_db, NONCE)[4] == 0, "e o prazo continua 0: depois do corredor nada credita")
ok(consume_like_game(_db, NONCE) == 0, "e o jogo ainda recusa o token (crédito zero)")
_db.close()
os.unlink(_tmp4)

# ---------------------------------------------------------------------------
# 5 — sem segredo a rota FECHA: 503 e nenhum banco tocado
# ---------------------------------------------------------------------------
with_secret(None)
_tmp5 = fresh_db()
_db = sqlite3.connect(_tmp5)
mint(_db, NONCE)
_b = body_of(NONCE)
# Um portal que assina com o valor que ELE acha que é o segredo, contra um deploy
# sem segredo configurado: a rota nem olha a assinatura.
_ok_header = "t=%d,v1=%s" % (int(time.time()), ad_ssv.expected_signature(
    FIXTURE_HMAC, int(time.time()), _b))
_h = call(_tmp5, _b, _ok_header)
ok(_h.code == 503 and _h.obj.get("error") == "ad_ssv_disabled",
   "deploy sem secret: 503 (a rota existe e não credita — fail-closed) (%s)" % _h.obj)
ok(row(_db, NONCE)[4] == 0, "nenhuma linha mudou sem segredo configurado")
ok(consume_like_game(_db, NONCE) == 0, "e sem ativação não há crédito no caminho do jogo")
_db.close()
os.unlink(_tmp5)
with_secret()

# ---------------------------------------------------------------------------
# 6 — forma do request, e o que a resposta nunca mostra
# ---------------------------------------------------------------------------
_tmp6 = fresh_db()
_db = sqlite3.connect(_tmp6)
mint(_db, NONCE)
_b = body_of(NONCE)
ok(call(_tmp6, b"", header_for(b"")).code == 400,
   "corpo vazio: 400 bad_body (nada é lido de um request sem corpo)")
ok(call(_tmp6, _b, header_for(_b), length=ad_ssv.MAX_BODY + 1).code == 400,
   "corpo acima do teto do corredor (16k): 400 — o mesmo teto que o nginx impõe")
# Content-Length MENOR que o corpo assinado: o gateway lê só o prefixo, e a
# assinatura de um corpo truncado não bate. Recusa, não "leo o que der".
ok(call(_tmp6, _b, header_for(_b), length=len(_b) - 10).code == 401,
   "Content-Length truncado: o prefixo lido não passa na assinatura (401)")
ok(row(_db, NONCE)[4] == 0, "e a tentativa truncada deixou a pendência sem prova")
_trunc = b'{"user_id": "' + NONCE.encode() + b'", "account_id": 7, "placement":'
ok(call(_tmp6, _trunc, header_for(_trunc)).code == 400,
   "JSON quebrado, assinado como está: 400 bad_json depois de 200 na assinatura")
_no_txn = json.dumps({"user_id": NONCE, "account_id": 7,
                      "placement": "chest"}).encode()
_h = call(_tmp6, _no_txn, header_for(_no_txn))
ok(_h.code == 400 and _h.obj.get("error") == "bad_claim",
   "reivindicação malformada assinada corretamente: 400 bad_claim, sem escrita (%s)"
   % _h.obj)
ok(row(_db, NONCE)[4] == 0, "e a pendência continua pendente depois de tudo acima")
_all = json.dumps([o for _c, o in _h.sent])
ok(FIXTURE_HMAC not in _all and NONCE not in _all,
   "a resposta não ecoa segredo nem nonce: nomeia só o veredito")

# Banco sem a migration 048: o erro é do banco, traduzido — nunca uma porta aberta
# nem um DDL inventado pelo webhook.
_bare = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
_bare.close()
_h = call(_bare.name, _b, header_for(_b))
ok(_h.code == 500 and _h.obj.get("error") == "db_error"
   and "048" in str(_h.obj.get("hint", "")),
   "banco sem ad_slot: 500 com hint da migration 048 (nada de DDL escondida no gateway)")
ok("SHAMBLETA" not in json.dumps(_h.obj), "nem o nome do segredo vaza na resposta")
_db.close()
os.unlink(_tmp6)
os.unlink(_bare.name)

# ---------------------------------------------------------------------------
# 7 — o pacote continua stdlib, e a rota está onde o gate espera
# ---------------------------------------------------------------------------
_src = open(os.path.join(HERE, "ad_ssv.py")).read()
_imports = sorted(set(l.split()[1] for l in _src.splitlines() if l.startswith("import ")))
ok(_imports and set(_imports) <= {"hashlib", "hmac", "json", "os", "re",
                                  "sqlite3", "time"},
   "ad_ssv é stdlib-only como o resto do companion: %s" % _imports)
ok("os.environ.get(AD_SSV_SECRET_ENV" in _src,
   "o segredo é lido do ambiente; o arquivo guarda só o NOME (nunca o valor)")
_srv = open(os.path.join(HERE, "server.py")).read()
ok("/webhooks/ads" in _srv and "ad_ssv.handle(self)" in _srv,
   "server.py roteia POST /webhooks/ads ao módulo (o hook de custo zero)")
# O teto é do gate, não deste arquivo: `== 2068` era um número copiado, e copiou-se
# obsoleto na primeira vez que um commit legítimo encostou no roteador (o ratchet do
# `check_god_nodes.sh` subiu para 2222 com a sucessora de temporada, e esta régua
# vermelha não era regressão de ninguém — era ela apontando para um run velho).
_ceil = 0
with open(os.path.join(ROOT, "scripts", "check_god_nodes.sh")) as _gate:
    for _l in _gate:
        if '["companion/server.py"]' in _l:
            _ceil = int(_l.rsplit("=", 1)[1].strip())
            break
ok(_ceil > 0, "o ratchet do gate nomeia um teto para companion/server.py (sem ele esta check é enfeite)")
_srvLines = len(_srv.splitlines())
ok(_ceil > 0 and _srvLines <= _ceil,
   "companion/server.py mede %d linhas <= teto %d lido do ratchet do gate (folga %d)"
   % (_srvLines, _ceil, _ceil - _srvLines))
_df = open(os.path.join(ROOT, "deploy", "companion", "Dockerfile")).read()
ok("ad_ssv.py" in _df, "deploy/companion/Dockerfile copia ad_ssv.py para a imagem")
_env = open(os.path.join(ROOT, ".env.example")).read()
_decl = [l for l in _env.splitlines() if l.startswith(ad_ssv.AD_SSV_SECRET_ENV + "=")]
ok(len(_decl) == 1, "%s está declarado uma vez no template (check_secrets 3b)"
   % ad_ssv.AD_SSV_SECRET_ENV)
ok(_decl and _decl[0].split("=", 1)[1].strip() == "",
   "e com valor VAZIO: o template documenta a porta, nunca a credencial (seção 3)")
_ngx = open(os.path.join(ROOT, "deploy", "web", "nginx.conf")).read()
ok("/webhooks/ads" in _ngx,
   "nginx.conf documenta o corredor do /webhooks/ads (mesmo bloco, sem location nova)")
ok(_ngx.count("location ^~ /webhooks/") == 1,
   "e o bloco proxied continua um só: a fronteira é checkout + push + webhooks")
_ads = open(os.path.join(ROOT, "sources", "ads", "AdProvider.gd")).read()
ok("companion/ad_ssv.py" in _ads,
   "o client confessa no fonte quem é a autoridade de produção do crédito")
_econ = open(os.path.join(ROOT, "sources", "economy", "AdsCosmeticsService.gd")).read()
ok("SHAMBLETA_AD_SSV" in _econ and "expires_at = 0" in _econ,
   "o mint do jogo cria a pendência que só o gateway ativa (modo SSV ligado)")

restore()
sys.exit(report("AD SSV"))
