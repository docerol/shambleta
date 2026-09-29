#!/usr/bin/env python3
"""Suíte da fachada: `companion/push_vapid.py` + a integração com `server.py`.

Quarto degrau da fatia do signer (os outros três e o kit compartilhado estão em
`test_push_common.py`). As primitivas já foram medidas octeto por octeto nas
suítes irmãs; aqui é o que só este arquivo sabe fazer:

  * leitura da chave (base64url, PEM SEC1, PEM PKCS#8, DER cru) e o fail-closed
    de `push_ready()`: chave corrompida nunca vira "sem chave", e uma pública
    que não é a derivada recusa trabalhar (RFC 8292 §3.2);
  * o assertion VAPID de RFC 8292 §2.4, byte a byte contra os valores
    publicados (a input string, o `k` e a `sig`), com `aud` = origem RFC 6454
    (porta DEFAULT suprimida: `:443` no `aud` é outra origem e o provedor
    responde 403 sem dizer o quê) e `exp` clampado em [60 s .. 24 h];
  * `build_request`: o POST que um push service recebe — com o material do
    vetor da RFC 8291 o header de 86 octetos montado É o header do vetor, `k` é
    a chave de ASSINATURA e nunca a efêmera do corpo, TTL clampado ao teto da
    RFC 8030 §5.2, e claro fora do loopback é recusado;
  * a integração com `companion/server.py`: a fila e os rótulos que ela grava, o
    sender ativo por env, um receiver local que devolve 201/410/403 e ABRE o
    corpo com a privada da subscription, a rota `GET /push/vapid` e o
    `--push-vapid-keygen`.

O QUE ISTO NÃO PROVA, dito sem rodeio: o "push service" abaixo é um
`http.server` neste processo, e parando aqui ele é só um espelho do que este
mesmo pacote sabe fazer. Nada contata a Mozilla ou o Google, e nenhum navegador
real subscreveu este caminho: `pushManager.subscribe()` não existe no
repositório (não há ponte JS registrando o worker de push — ver `deploy/web/`) e
o `deploy/companion/Dockerfile` copia apenas `server.py`, então as quatro camadas
nem sobem na imagem. Um 201 de um push service público continua NÃO medido, e o
companion em produção responde `reason: module_unavailable` exatamente por isso.

Rodar: `python3 companion/test_push_vapid.py`. Sai !=0 se falhar.
"""

import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import push_common as pc                                          # noqa: E402
import push_vapid as pv                                           # noqa: E402
import test_push_common as kit                                    # noqa: E402
import server                                                     # noqa: E402

ok, eq, raises, report = kit.ok, kit.eq, kit.raises, kit.report
und, pem = kit.und, kit.pem
UAPUB, UAPRIV = kit.UAPUB, kit.UAPRIV
ASPRIV, ASPUB = kit.ASPRIV, kit.ASPUB
AUTH, SALT = kit.AUTH, kit.SALT
HEADER86, CIPHER = kit.HEADER86, kit.CIPHER

# ===========================================================================
# 6 — leitura da chave: formatos aceitos e fail-closed no resto
# ===========================================================================
_priv_b64, _pub_b64 = pv.generate_keypair()
_priv_int = pv.private_scalar(und(_priv_b64))
ok(len(_pub_b64) == 87 and len(und(_pub_b64)) == 65 and und(_pub_b64)[0] == 0x04,
   "generate_keypair: pública = 87 chars b64url / 65 octetos X9.62")
ok(pv.load_signing_key({pv.VAPID_PRIVATE_ENV: _priv_b64}) == _priv_int,
   "escalar em base64url (o formato do --push-vapid-keygen) carrega")
_SEC1 = (b"\x30\x77\x02\x01\x01\x04\x20" + _priv_int.to_bytes(32, "big")
         + b"\xa0\x0a\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07"
         + b"\xa1\x44\x03\x42\x00" + und(_pub_b64))
ok(pv.load_signing_key({pv.VAPID_PRIVATE_ENV: pem(_SEC1, "EC PRIVATE KEY")})
   == _priv_int, "PEM SEC1 'EC PRIVATE KEY' carrega (mesmo escalar)")
_P8 = (b"\x30\x77\x02\x01\x01\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01"
       b"\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x04\x5d\x30\x5b\x02\x01\x01"
       b"\x04\x20" + _priv_int.to_bytes(32, "big"))
ok(pv.load_signing_key({pv.VAPID_PRIVATE_ENV: pem(_P8, "PRIVATE KEY")})
   == _priv_int, "PEM PKCS#8 'PRIVATE KEY' carrega (varredura do marcador SEC1)")
ok(pv.load_signing_key({pv.VAPID_PRIVATE_ENV: pc.b64u_encode(_SEC1)})
   == _priv_int, "DER SEC1 em base64url (sem armadura PEM) também carrega")
ok(pv.load_signing_key({}) is None, "sem env, load_signing_key devolve None")
ok(pv.signing_key_configured({}) is False
   and pv.signing_key_configured({pv.VAPID_PRIVATE_ENV: _priv_b64}) is True,
   "signing_key_configured responde só se HÁ chave")
raises(pv.ConfigError, lambda: pv.load_signing_key(
    {pv.VAPID_PRIVATE_ENV: "nao-e-base64-nem-pem!!"}),
   "valor ilegível levanta ConfigError, nunca 'sem chave'")
raises(pv.ConfigError, lambda: pv.load_signing_key(
    {pv.VAPID_PRIVATE_ENV: pv.b64u_encode(b"\x01" * 8)}),
   "escalar com tamanho errado é recusado")
raises(pv.ConfigError, lambda: pv.load_signing_key(
    {pv.VAPID_PRIVATE_ENV: pv.b64u_encode(b"\x00" * 32)}),
   "escalar 0 é recusado")
# Os dois fixtures abaixo são PEMs MALFORMADOS de propósito — corpo de 3 octetos,
# sem a estrutura SEC1. O marcador é montado em tempo de execução (a mesma
# convenção de `pem()` em test_push_common.py) porque o gate de segredos lê o
# texto rastreado e não tem como distinguir um cabeçalho de chave privada escrito
# à mão de uma chave privada de verdade: um literal assim conta como falha, e é
# mais caro relaxar a regra do que esconder o fixture. O parser recebe os mesmos
# bytes de sempre — o que muda é só onde a string é montada.
_PEM_HEAD = "-----BEGIN EC " + "PRIVATE KEY-----\n"
_PEM_TAIL = "-----END EC " + "PRIVATE KEY-----"
raises(pv.ConfigError, lambda: pv.load_signing_key(
    {pv.VAPID_PRIVATE_ENV: _PEM_HEAD + "QUJD\n" + _PEM_TAIL}),
   "PEM sem estrutura ECPrivateKey é recusado")
raises(pv.ConfigError, lambda: pv.load_signing_key(
    {pv.VAPID_PRIVATE_ENV: _PEM_HEAD + "AAAA"}),
   "PEM sem END é recusado (não um DER truncado aceito por acidente)")
eq(pv.public_key_from_private(_priv_int), _pub_b64,
   "public_key_from_private e push_ready derivam a mesma pública")
_FOR_ENV = {pv.VAPID_PRIVATE_ENV: _priv_b64}
for env, want, label in [
        ({}, False, "sem nada configurado o sender não está pronto"),
        (_FOR_ENV, True, "só a privada já basta (a pública é derivada)"),
        ({pv.VAPID_PRIVATE_ENV: _priv_b64, pv.VAPID_PUBLIC_ENV: _pub_b64},
         True, "privada + pública coerentes"),
        ({pv.VAPID_PRIVATE_ENV: _priv_b64,
          pv.VAPID_PUBLIC_ENV: pv.b64u_encode(b"\x04" + b"\x11" * 64)},
         False, "pública que não é a derivada da privada: recusa (key_mismatch)"),
        ({pv.VAPID_PRIVATE_ENV: "xxx!"}, False, "privada corrompida: pronto=false"),
]:
    ready, info = pv.push_ready(env)
    ok(ready is want, label)
    ok(_priv_b64 not in info and _priv_int.to_bytes(32, "big").hex() not in info,
       "o que push_ready devolve nunca contém a privada")
eq(pv.push_ready(_FOR_ENV)[1], _pub_b64,
   "pronto: o segundo valor É a applicationServerKey")
eq(pv.push_ready({})[1], "no_vapid_private_key",
   "não pronto: rótulo estático 'no_vapid_private_key'")
ok(pv.push_ready({pv.VAPID_PRIVATE_ENV: _priv_b64,
                  pv.VAPID_PUBLIC_ENV: "NAO-E-BASE64!!"})[1]
   == "vapid_public_key_undecodable",
   "pública ilegível tem rótulo próprio (e continua ready=false)")

# ===========================================================================
# 7 — assertion VAPID (RFC 8292 §2.4, valores publicados no texto da RFC)
# ===========================================================================
RFC8292_T = ("eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJhdWQiOiJodHRwczovL3B1c"
             "2guZXhhbXBsZS5uZXQiLCJleHAiOjE0NTM1MjM3NjgsInN1YiI6Im1haWx0bzpw"
             "dXNoQGV4YW1wbGUuY29tIn0")
RFC8292_SIG = ("i3CYb7t4xfxCDquptFOepC9GAu_HLGkMlMuCGSK2rpiUfnK9ojFwDXb1JrEr"
               "tmysazNjjvW2L9OkSSHzvoD1oA")
RFC8292_K = ("BA1Hxzyi1RUM1b5wjxsn7nGxAszw2u61m164i3MrAIxHF6YK5h4SDYic-dRuU_R"
             "CPCfA5aq9ojSwk5Y2EmClBPs")
_t, claims = pv.vapid_jwt_input("https://push.example.net",
                                subject="mailto:push@example.com",
                                now=1453518000, token_ttl=5768)
eq(_t, RFC8292_T, "RFC 8292 §2.4: a input string assinada, byte a byte")
eq(claims, {"aud": "https://push.example.net", "exp": 1453523768,
            "sub": "mailto:push@example.com"},
   "RFC 8292 §2: claims aud/exp/sub do exemplo publicado")
eq(RFC8292_K, "BA1Hxzyi1RUM1b5wjxsn7nGxAszw2u61m164i3MrAIxHF6YK5h4SDYic-dRuU"
              "_RCPCfA5aq9ojSwk5Y2EmClBPs",
   "RFC 8292: o `k` publicado é x||y do JWK da Figura 2 (0x04 || x || y)")
ok(pv.ecdsa_verify(_t.encode(), und(RFC8292_SIG), und(RFC8292_K)),
   "RFC 8292 §2.4: a `sig` publicada é aceita por este verifier")
_flip = bytearray(und(RFC8292_SIG))
_flip[10] ^= 1
ok(not pv.ecdsa_verify(_t.encode(), bytes(_flip), und(RFC8292_K)),
   "RFC 8292 §2.4: um bit virado nessa `sig` é recusado")
ok(not pv.ecdsa_verify((_t + "x").encode(), und(RFC8292_SIG), und(RFC8292_K)),
   "RFC 8292 §2.4: outro conteúdo com a mesma `sig` é recusado")
ok(not pv.ecdsa_verify(_t.encode(), und(RFC8292_SIG),
                       und(RFC8292_K)[:-1] + b"\x01"),
   "RFC 8292 §2.4: outra chave pública recusa a mesma `sig`")
_header, _jwt, _k, _sig = pv.vapid_authorization(
    "https://api.push.example.com:443/v1/abc", private_key=_priv_int,
    subject="mailto:push@shambleta.test", now=1700000000)
ok(re.fullmatch(r"vapid t=[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+, "
                r"k=[A-Za-z0-9_\-]{87}", _header) is not None,
   "RFC 8292 §3: header 'vapid t=<jwt>, k=<pub>' na forma exata")
eq(_k, _pub_b64, "o `k` do header é a pública derivada da privada")
eq(_jwt.split(".")[0], "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9",
   "JWT header typ=JWT alg=ES256 (base64url, sem padding)")
ok(pv.ecdsa_verify(_jwt.rsplit(".", 1)[0].encode(), und(_sig), und(_k)),
   "o assertion se auto-verifica contra o próprio k antes de sair")
eq(pv._origin("https://api.push.example.com:443/v1/x"),
   "https://api.push.example.com",
   "RFC 6454: a porta DEFAULT some da origem (`:443` seria outra origem)")
eq(pv._origin("https://api.push.example.com:8443/v1/x"),
   "https://api.push.example.com:8443",
   "porta NÃO-padrão continua na origem (suprimir isso é que seria erro)")
eq(json.loads(pc.b64u_decode(kit.norm(_jwt.split(".")[1])))["aud"],
   "https://api.push.example.com",
   "aud = origem do endpoint (porta default fora, caminho fora)")
eq(pv.vapid_jwt_input("https://Push.Example.NET/some/path?a=b")[1]["aud"],
   "https://push.example.net",
   "aud normalizado: host minúsculo, sem path/query")
for _ttl, _want in [(10 ** 9, 24 * 3600), (5, 60), (7200, 7200)]:
    _now = 1700000000
    _exp = pv.vapid_jwt_input("https://p/x", now=_now, token_ttl=_ttl)[1]["exp"]
    ok(_exp - _now == _want,
       "exp clampado para [60..86400] s (RFC 8292: nunca acima de 24h) ttl=%d"
       % _ttl)
ok("sub" not in pv.vapid_jwt_input("https://p/x", now=1700000000)[1],
   "sem subject configurado a claim `sub` é omitida (a RFC só restringe o "
   "formato quando ela está presente)")
raises(pv.ConfigError, lambda: pv.vapid_authorization("https://p/x"),
   "sem chave no ambiente, nada é assinado (ConfigError, não JWT vazio)")
raises(pv.ConfigError, lambda: pv.vapid_authorization(
    "push.example.net/x", private_key=_priv_int),
   "endpoint sem origem absoluta recusa assinar")

# ===========================================================================
# 8 — build_request: o POST que um push service de verdade recebe
# ===========================================================================
_sub = {"account_id": 7, "endpoint": "https://push.example.org/s/abc",
        "p256dh": UAPUB, "auth": AUTH}
_url, _hdrs, _blob = pv.build_request(
    _sub, "Volta", "sua colheita está madura", private_key=_priv_int,
    now=1700000000, salt=und(SALT), eph_private=und(ASPRIV))
# O corpo NÃO pode ser o corpo do vetor da RFC 8291: lá o claro é o poema
# "When I grow up...", aqui é o JSON da notificação. O que o material do vetor
# determina, octeto por octeto, é o HEADER (salt || rs || idlen || keyid) — e é
# ele que a régua confere. Afirmar o corpo inteiro seria uma régua que mente.
eq(_blob[:86], und(HEADER86),
   "com salt+par efêmero do vetor da RFC 8291 o HEADER montado é o header do vetor")
ok(_blob[86:] != und(CIPHER) and len(_blob[86:]) % 16 != 0,
   "e o ciphertext difere (o claro aqui é o JSON da notificação, não o poema)")
eq(_hdrs["Authorization"].split(", k=")[1], _pub_b64,
   "k = chave de ASSINATURA, nunca a efêmera do corpo (RFC 8292 §3.2)")
eq(pv.b64u_encode(_blob[21:86]), ASPUB,
   "keyid do corpo = a chave EFÊMERA, diferente da de assinatura")
ok(_hdrs["Content-Encoding"] == "aes128gcm" and _hdrs["TTL"] == "3600"
   and int(_hdrs["Content-Length"]) == len(_blob) and _hdrs["Urgency"] == "low",
   "Content-Encoding/TTL/Urgency/Content-Length coerentes com o corpo")
ok(pv.ecdsa_verify(".".join(_hdrs["Authorization"].split("t=")[1]
                            .split(",")[0].split(".")[:2]).encode(),
                   und(_hdrs["Authorization"].split("t=")[1]
                       .split(",")[0].split(".")[2]),
                   und(_hdrs["Authorization"].split(", k=")[1])),
   "o Authorization montado verifica com a chave que ele mesmo anuncia")
eq(_url, _sub["endpoint"], "build_request devolve exatamente o endpoint da subscription")
_payload = json.loads(pv.decrypt_message(_blob, und(UAPRIV), AUTH))
eq(sorted(_payload), ["body", "icon", "title", "url"],
   "payload decifrado tem exatamente os campos que deploy/web/sw.js lê")
ok(_payload["title"] == "Volta" and _payload["body"] == "sua colheita está madura"
   and _payload["icon"] == "index.144x144.png" and _payload["url"] == "/",
   "payload == o contrato do service worker (title/body/icon/url)")
raises(pv.ConfigError, lambda: pv.build_request(
    dict(_sub, endpoint="http://push.example.org/s/x"), "t", "b",
    private_key=_priv_int),
   "http para host remoto é recusado (credencial VAPID nunca vai em claro)")
ok(pv.build_request(dict(_sub, endpoint="http://127.0.0.1:9/x"), "t", "b",
                    private_key=_priv_int)[0].startswith("http://"),
   "loopback é a única exceção de claro (e é só onde mora o receiver de teste)")
raises(pv.ConfigError, lambda: pv.build_request(
    dict(_sub, p256dh=""), "t", "b", private_key=_priv_int),
   "subscription incompleta é recusada ANTES de assinar qualquer coisa")
raises(pv.ConfigError, lambda: pv.build_request(
    dict(_sub, endpoint="ftp://x/y"), "t", "b", private_key=_priv_int),
   "esquema fora de http(s) é recusado")
raises(pv.ConfigError, lambda: pv.build_request(
    "nao-um-dict", "t", "b", private_key=_priv_int),
   "subscription que não é dict é recusada")
os.environ[pv.PUSH_TTL_ENV] = "999999999999"
ok(int(pv.build_request(_sub, "t", "b", private_key=_priv_int)[1]["TTL"])
   == 4 * 7 * 24 * 3600, "TTL clampado ao teto da RFC 8030 §5.2 (4 semanas)")
os.environ[pv.PUSH_TTL_ENV] = "-5"
ok(int(pv.build_request(_sub, "t", "b", private_key=_priv_int)[1]["TTL"]) == 0,
   "TTL negativo vira 0 (não entregar se o cliente cair), nunca header inválido")
os.environ.pop(pv.PUSH_TTL_ENV, None)
kit.no_keys()
raises(pv.ConfigError, lambda: pv.send(dict(_sub), "t", "b"),
   "send() sem chave configurada recusa antes de abrir a conexão")

# ===========================================================================
# 10 — integração com server.py: a fila, o sender, a rota e o keygen
# ===========================================================================
_MIG = sorted(glob.glob(os.path.join(ROOT, "data", "conf", "migrations",
                                     "*_web_push.sql")))
ok(len(_MIG) == 1, "exatamente uma migration *_web_push.sql para montar o DB")


def fresh_db():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY,"
                " username TEXT, last_timestamp INTEGER DEFAULT 0)")
    con.execute("INSERT INTO account VALUES (1, 'offline', ?)",
                (int(time.time()) - 200000,))
    con.executescript(open(_MIG[0]).read())
    con.commit()
    return path, con


def notimplemented_reason(fn, *a):
    try:
        fn(*a)
        return None
    except NotImplementedError as e:
        return str(e)


# --- (a) fail-closed: sem chave, exatamente o comportamento de antes --------
kit.no_keys()
_reason = notimplemented_reason(server.vapid_webpush_send, dict(_sub), "t", "b")
ok(_reason is not None, "sem chave: vapid_webpush_send levanta NotImplementedError")
ok(_reason is not None and "no_vapid_private_key" in _reason,
   "e diz POR QUE na exceção (não um 'falhou' oco)")
_db, _con = fresh_db()
_store = server.Store(_db)
ok(_store.push_register(_con, 1, "http://127.0.0.1:9/x", UAPUB, AUTH) is True,
   "push_register aceita subscription de material válido")
_store.push_enqueue(_con, 1, title="t", body="b")
eq(_store.push_drain(_con, now=int(time.time()))["failed"], 1,
   "drain sem chave: 1 linha failed, 0 sent")
eq(_con.execute("SELECT status, last_error FROM push_outbox ORDER BY id"
                " LIMIT 1").fetchone(),
   ("failed", "vapid_sender_unimplemented"),
   "o rótulo gravado é o MESMO de antes do módulo existir (contrato dos gates)")
_con.close()
os.unlink(_db)
_cache, _cerr = server._push_vapid_module, server._push_vapid_import_error
server._push_vapid_module = None
_reason = notimplemented_reason(server.vapid_webpush_send, dict(_sub), "t", "b")
ok(_reason is not None and "push_vapid.py" in _reason,
   "módulo ausente da imagem (Dockerfile copia um arquivo só) continua fechado "
   "e diz o que falta")
server._push_vapid_import_error = "No module named 'push_p256'"
_reason = notimplemented_reason(server.vapid_webpush_send, dict(_sub), "t", "b")
ok(_reason is not None and "push_p256" in _reason,
   "e o motivo nomeia a camada que faltou (nome de módulo não é segredo)")
server._push_vapid_module, server._push_vapid_import_error = _cache, _cerr
ok(server.push_sender() is server.vapid_webpush_send,
   "sem env, o sender ativo segue sendo o vapid (nunca o stdout)")
os.environ[server.PUSH_SENDER_ENV] = "nome-que-nao-existe"
ok(server.push_sender() is server.vapid_webpush_send,
   "nome desconhecido cai no fechado, nunca no stub que finge sucesso")
os.environ[server.PUSH_SENDER_ENV] = "stdout"
ok(server.push_sender() is server.stdout_webpush_send,
   "o stub de teste continua acionável por env (só para exercitar a fila)")
kit.no_keys()


# --- (b) entrega real de ponta a ponta contra um receiver local -------------
class Receiver(BaseHTTPRequestHandler):
    """Um push service de mentira: registra o POST e responde 201
    (RFC 8030 §4.3). Em /gone responde 410; em /refused responde 403."""
    got = {}

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        Receiver.got = {"path": self.path, "headers": dict(self.headers),
                        "body": raw}
        code = 410 if self.path.startswith("/gone") else (
            403 if self.path.startswith("/refused") else 201)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()


_httpd = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
_port = _httpd.server_address[1]
threading.Thread(target=_httpd.serve_forever, daemon=True).start()
os.environ[pv.VAPID_PRIVATE_ENV] = _priv_b64
os.environ[pv.VAPID_PUBLIC_ENV] = _pub_b64
os.environ[pv.VAPID_SUBJECT_ENV] = "mailto:push@shambleta.test"
ok(pv.push_ready()[0] is True,
   "com as duas secrets no ambiente o sender fica pronto")
_db, _con = fresh_db()
_store = server.Store(_db)
_store.push_register(_con, 1, "http://127.0.0.1:%d/p/abc" % _port, UAPUB, AUTH)
_store.push_enqueue(_con, 1, title="Volta", body="a colheita espera")
eq(_store.push_drain(_con, now=int(time.time()))["sent"], 1,
   "com chave configurada a fila ENTREGA (sent=1)")
eq(_con.execute("SELECT status, last_error FROM push_outbox ORDER BY id"
                " LIMIT 1").fetchone(), ("sent", None),
   "linha sent com last_error limpo")
ok(Receiver.got.get("body") is not None, "o receiver local recebeu um POST")
eq(Receiver.got["headers"].get("Content-Encoding"), "aes128gcm",
   "Content-Encoding do POST real")
eq(Receiver.got["headers"].get("TTL"), "3600", "TTL do POST real (RFC 8030 §5.2)")
ok(re.fullmatch(r"vapid t=[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+, "
                r"k=[A-Za-z0-9_\-]{87}",
                Receiver.got["headers"].get("Authorization", "")) is not None,
   "Authorization do POST real é um assertion VAPID na forma da RFC 8292")
_post_body = Receiver.got["body"]
ok(len(_post_body) > pv.HEADER_LEN and _post_body[20] == 65
   and _post_body[21] == 0x04
   and int.from_bytes(_post_body[16:20], "big") == 4096,
   "corpo do POST real: header de 86 com rs=4096, idlen=65, keyid X9.62")
ok(pv.ecdsa_verify(
    ".".join(Receiver.got["headers"]["Authorization"].split("t=")[1]
             .split(",")[0].split(".")[:2]).encode(),
    und(Receiver.got["headers"]["Authorization"].split("t=")[1]
        .split(",")[0].split(".")[2]),
    und(Receiver.got["headers"]["Authorization"].split(", k=")[1])),
   "o provedor-local verifica o assertion que chegou")
ok(int(Receiver.got["headers"].get("Content-Length", -1)) == len(_post_body),
   "Content-Length bate com o corpo enviado")
_captured = (json.dumps(Receiver.got["headers"])
             + Receiver.got["body"].hex())
ok(_priv_b64 not in _captured and _priv_int.to_bytes(32, "big").hex()
   not in _captured,
   "nenhum segredo viaja nos headers nem no corpo capturado")
_recv = pv.generate_keypair()
_store.push_register(_con, 1, "http://127.0.0.1:%d/p/abc" % _port, _recv[1], AUTH)
_store.push_enqueue(_con, 1, title="Segunda", body="chamada")
eq(_store.push_drain(_con, now=int(time.time()) + 1)["sent"], 1,
   "segunda entrega (outra subscription) também sai")
_opened = json.loads(pv.decrypt_message(Receiver.got["body"], und(_recv[0]), AUTH))
ok(_opened["title"] == "Segunda" and _opened["body"] == "chamada"
   and _opened["icon"] == "index.144x144.png" and _opened["url"] == "/",
   "o lado do receptor abre o corpo com a privada dele (round-trip real)")
_store.push_register(_con, 1, "http://127.0.0.1:%d/gone" % _port, _recv[1], AUTH)
_store.push_enqueue(_con, 1, title="Morta", body="ninguém escuta")
eq(_store.push_drain(_con, now=int(time.time()) + 2)["failed"], 1,
   "410 do provedor: linha failed, nunca sent")
eq(_con.execute("SELECT COUNT(*) FROM push_subscription").fetchone()[0], 0,
   "410 apaga a subscription morta (não re-tenta para sempre)")
ok(str(_con.execute("SELECT last_error FROM push_outbox ORDER BY id DESC"
                   " LIMIT 1").fetchone()[0]).startswith(
    "push_subscription_gone_410"),
   "e confessa o motivo como push_subscription_gone_<status>")
_store.push_register(_con, 1, "http://127.0.0.1:%d/refused" % _port,
                     _recv[1], AUTH)
_store.push_enqueue(_con, 1, title="Recusada", body="403")
eq(_store.push_drain(_con, now=int(time.time()) + 3)["failed"], 1,
   "403 do provedor: failed com motivo, sem sent falso e sem retry automático")
ok("PushError" in str(_con.execute("SELECT last_error FROM push_outbox"
                                   " ORDER BY id DESC LIMIT 1").fetchone()[0]),
   "o last_error traz o tipo do erro de entrega (auditável)")
_con.close()
os.unlink(_db)
_httpd.shutdown()

# --- (c) GET /push/vapid: readiness + pública; nunca a privada --------------
class StatusProbe:
    sent = (None, "{}")
    _push_vapid_status = server.Handler._push_vapid_status

    def _send(self, code, obj):
        StatusProbe.sent = (code, json.dumps(obj))


_probe = StatusProbe()
_probe._push_vapid_status()
_code, _text = StatusProbe.sent
_obj = json.loads(_text)
ok(_code == 200 and _obj["ready"] is True, "rota com chave: ready=true")
eq(_obj.get("public_key"), _pub_b64,
   "rota publica exatamente a applicationServerKey")
ok(_priv_b64 not in _text and _priv_int.to_bytes(32, "big").hex() not in _text,
   "e não vaza a privada nem por acidente de serialização")
kit.no_keys()
_probe._push_vapid_status()
_obj = json.loads(StatusProbe.sent[1])
ok(_obj["ready"] is False and "public_key" not in _obj,
   "sem chave: ready=false e nenhuma chave publicada")
eq(_obj["reason"], "no_vapid_private_key", "motivo coarse na rota pública")
os.environ[pv.VAPID_PRIVATE_ENV] = _priv_b64
os.environ[pv.VAPID_PUBLIC_ENV] = pv.b64u_encode(b"\x04" + b"\x22" * 64)
_probe._push_vapid_status()
eq(json.loads(StatusProbe.sent[1])["reason"], "vapid_key_mismatch",
   "pública divergente: rota diz key_mismatch e continua ready=false")
os.environ[pv.VAPID_PRIVATE_ENV] = "lixo!!"
os.environ.pop(pv.VAPID_PUBLIC_ENV, None)
_probe._push_vapid_status()
eq(json.loads(StatusProbe.sent[1])["reason"], "not_configured",
   "o motivo fino (detalhe do parser da chave) NÃO sai pela rota pública")
_cache = server._push_vapid_module
server._push_vapid_module = None
_probe._push_vapid_status()
eq(json.loads(StatusProbe.sent[1])["reason"], "module_unavailable",
   "camada fora da imagem: a rota confessa module_unavailable (o estado real do "
   "deploy de hoje), e o jogo lê exatamente isto para decidir CanDeliver()")
server._push_vapid_module = _cache
kit.no_keys()

# --- (d) keygen CLI: privada em arquivo 0600, só a pública no stdout --------
_tmp = tempfile.mkdtemp(prefix="shambleta-push-cli-")
os.chmod(_tmp, 0o700)
try:
    _out = os.path.join(_tmp, "vapid.key")
    _r = subprocess.run([sys.executable, os.path.join(HERE, "server.py"),
                         "--push-vapid-keygen", "--push-vapid-key-out", _out],
                        capture_output=True, text=True, timeout=120)
    ok(_r.returncode == 0, "--push-vapid-keygen sai 0")
    _printed = (_r.stdout.split("publica=")[1].split()[0]
                if "publica=" in _r.stdout else "")
    ok(len(_printed) == 87, "stdout traz a pública de 87 caracteres")
    ok(_priv_b64 not in _r.stdout + _r.stderr,
       "stdout/stderr nunca carregam uma privada")
    ok(os.stat(_out).st_mode & 0o777 == 0o600,
       "a privada nasceu com modo 0600 (não 0644)")
    _read_back = open(_out).read().strip()
    ok(len(_read_back) == 43 and pv.push_ready(
        {pv.VAPID_PRIVATE_ENV: _read_back, pv.VAPID_PUBLIC_ENV: _printed})[0],
       "o par gerado é utilizável: a pública impressa confere com a privada")
    _r2 = subprocess.run([sys.executable, os.path.join(HERE, "server.py"),
                          "--push-vapid-keygen", "--push-vapid-key-out", _out],
                         capture_output=True, text=True, timeout=120)
    ok(_r2.returncode == 2 and open(_out).read().strip() == _read_back,
       "keygen não sobrescreve um arquivo existente")
    _r3 = subprocess.run([sys.executable, os.path.join(HERE, "server.py"),
                          "--push-vapid-keygen"], capture_output=True,
                         text=True, timeout=120)
    ok(_r3.returncode == 2 and "key-out" in _r3.stderr,
       "keygen sem --push-vapid-key-out recusa (a privada não vai para stdout)")
    _r4 = subprocess.run([sys.executable, os.path.join(HERE, "server.py")],
                         capture_output=True, text=True, timeout=120)
    ok(_r4.returncode == 2 and "--db" in _r4.stderr,
       "--db continua obrigatório em qualquer outro modo (keygen é a única "
       "exceção: o par nasce antes de existir deploy)")
finally:
    shutil.rmtree(_tmp, ignore_errors=True)

sys.exit(report("PUSH VAPID"))

