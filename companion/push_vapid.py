#!/usr/bin/env python3
"""Fachada do Web Push do companion: chave, assertion VAPID (RFC 8292) e POST (RFC 8030).

É o ÚNICO arquivo do caminho que `companion/server.py` importa. As primitivas
morreram em `push_common.py` (erros/config/base64url), `push_p256.py` (curva,
ECDH, ECDSA) e `push_aesgcm.py` (AES-GCM, HKDF, record `aes128gcm`) porque o
arquivo único tinha 944 linhas contra o teto anti-god-node de 800, e a fachada
reexporta tudo para que nenhum consumidor precise saber em quantos arquivos a
implementação foi dividida.

POR QUE ISTO EXISTE E POR QUE É STDLIB PURO
-------------------------------------------
O companion é stdlib-only por contrato: o `deploy/companion/Dockerfile` copia
`server.py` e não roda `pip install`, e o job `companion-tests` da CI declara
"stdlib puro (sem requirements)". Uma dependência declarada (`cryptography`)
trocaria um bloqueio por outro: o sender funcionaria no laptop e continuaria
inexistente na imagem que sobe — `WebPush.CanDeliver()` viraria true num build
que não entrega. A rota escolhida é ECDSA P-256 + AES-128-GCM escritos com
`hashlib`/`hmac`/`secrets`, que rodam exatamente onde `server.py` roda, sem
tocar em build ou imagem.

O tradeoff de segurança, dito sem eufemismo: criptografia assimétrica escrita
à mão é o que um revisor de segurança ataca primeiro. O que isto mitiga, e o
que NÃO mitiga:

  * Corretude não é suposição. As camadas são medidas contra os vetores
    publicados — RFC 8291 §5/Appendix A (ecdh_secret, PRK_key, IKM, PRK, CEK,
    NONCE, header de 86 octetos e corpo final de 144 octetos, byte a byte),
    RFC 6979 A.2.5 (r e s determinísticos em P-256/SHA-256, byte a byte), RFC
    8188 §3.1 e RFC 8292 §2.4 (a `sig` publicada é aceita pelo verifier deste
    pacote contra a chave pública publicada, e rejeitada com um bit virado).
    Veja `companion/test_push_p256.py`, `test_push_aesgcm.py`,
    `test_push_common.py` e `test_push_vapid.py`.
  * Constant-time: NÃO é. A aritmética é `int` do CPython, que não tem duração
    fixa. A mitigação real é *blinding de escalar*: todo multiplicador passa
    por `k + t*n` com `t` aleatório, então o padrão de ramificações/tempo é
    função de um valor aleatório, não do segredo. Um atacante capaz de medir
    tempo no mesmo host ainda tem um caminho; isto não é uma HSM.
  * Risco material: a chave VAPID só autoriza enviar notificações push às
    assinaturas criadas para ela — não assenta dinheiro nem sessão de login.
    Quem precisar de chave de alto valor troca as camadas `push_p256.py` /
    `push_aesgcm.py` por uma implementação em C auditada (`cryptography` é a
    candidata natural): a API pública é pequena de propósito — `send`,
    `build_request`, `vapid_authorization`, `encrypt_message`,
    `decrypt_message` — e nada mais do companion sabe de primitivos.

O que NÃO está provado por nenhum dos vetores acima, e está dito aqui para não
precisar ser descoberto em produção: nenhum navegador real subscreveu este
caminho durante a escrita dele. A entrega é verificada contra um receiver local
que confere o `Authorization: vapid`, o corpo `aes128gcm` e devolve 201/410/403
como um push service — o que prova o protocolo deste lado, não um 201 da
Mozilla. Falta ainda o `pushManager.subscribe()` do lado do shell (o worker
`deploy/web/sw.js` é servido, mas nunca registrado) e a rota pública que receberia
a subscription gerada pelo navegador.

Segredo NUNCA mora aqui: o par de chaves vem do ambiente
(`SHAMBLETA_VAPID_PRIVATE_KEY`, `SHAMBLETA_VAPID_PUBLIC_KEY`,
`SHAMBLETA_VAPID_SUBJECT`) e nenhuma função deste pacote escreve chave em log,
exceção, repr ou retorno. Sem chave configurada, `push_ready()` devolve False e
o sender levanta `NotImplementedError` — fail-closed, o comportamento exato de
antes de estes arquivos existirem.

Formatos aceitos em `SHAMBLETA_VAPID_PRIVATE_KEY` (sempre via segredo de
deploy, nunca commitado):
  * base64url sem padding dos 32 octetos do escalar `d` (o que
    `generate_keypair()` / `server.py --push-vapid-keygen` produz);
  * PEM `EC PRIVATE KEY` (SEC1) ou `PRIVATE KEY` (PKCS#8): o DER é varrido
    pelo marcador `02 01 01 04 20` da estrutura SEC1 `ECPrivateKey`, que
    também aparece dentro do PKCS#8 embrulhado — sem parser ASN.1.

`SHAMBLETA_VAPID_PUBLIC_KEY`, quando presente, é a chave pública X9.62 não
comprimida (65 octetos: `0x04 || x || y`) em base64url — os mesmos 87
caracteres de `applicationServerKey` no `pushManager.subscribe()` e do
parâmetro `k` do header `Authorization: vapid`. Ela é conferida contra a
derivada da privada: divergir é erro de configuração e o sender recusa
trabalhar, em vez de assinar com uma chave que nenhum navegador aceitaria
subscrever.
"""

import base64
import json
import os
import sys
import time
import http.client
import ssl
import urllib.parse

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from push_common import (CLEARTEXT_HOSTS, DEFAULT_TTL, HEADER_LEN,  # noqa: E402
                         MAX_PAYLOAD, MAX_TTL, MAX_TOKEN_TTL, NONCE_LEN,
                         PUSH_TIMEOUT_ENV, PUSH_TTL_ENV, RECORD_SIZE, SALT_LEN,
                         TAG_LEN, TOKEN_TTL, USER_AGENT, VAPID_PRIVATE_ENV,
                         VAPID_PUBLIC_ENV, VAPID_SUBJECT_ENV,
                         VAPID_TOKEN_TTL_ENV, ConfigError, MaterialError,
                         PushError, SubscriptionGone, b64u_decode, b64u_encode)
from push_p256 import (P256, decode_uncompressed, ecdh, encode_uncompressed,  # noqa: E402
                       ecdsa_sign, ecdsa_verify, generate_keypair,
                       private_scalar, public_key_from_private,
                       scalar_multiply)
from push_aesgcm import (decrypt_message, encrypt_message, gcm_decrypt,  # noqa: E402
                         gcm_encrypt)

__all__ = [
    "P256", "b64u_encode", "b64u_decode", "generate_keypair",
    "public_key_from_private", "load_signing_key", "signing_key_configured",
    "push_ready", "ecdsa_sign", "ecdsa_verify", "ecdh", "encode_uncompressed",
    "decode_uncompressed", "encrypt_message", "decrypt_message",
    "vapid_authorization", "vapid_jwt_input", "build_request", "send",
    "PushError", "ConfigError", "SubscriptionGone", "MaterialError",
    "VAPID_PRIVATE_ENV", "VAPID_PUBLIC_ENV", "VAPID_SUBJECT_ENV",
    "PUSH_TTL_ENV", "PUSH_TIMEOUT_ENV", "VAPID_TOKEN_TTL_ENV",
    "RECORD_SIZE", "MAX_PAYLOAD", "HEADER_LEN", "DEFAULT_TTL", "MAX_TTL",
    "TOKEN_TTL", "MAX_TOKEN_TTL", "SALT_LEN", "TAG_LEN", "NONCE_LEN",
    "USER_AGENT", "CLEARTEXT_HOSTS",
]


# --------------------------------------------------------------------------
# leitura da chave: formatos aceitos e fail-closed no resto
# --------------------------------------------------------------------------

def _extract_d_from_der(der):
    """VARRE o DER atrás de `02 01 01` (INTEGER 1 = version) + `04 20`
    (OCTET STRING de 32): vale para SEC1 `ECPrivateKey` e para o mesmo SEC1
    embrulhado em PKCS#8, sem precisar de parser ASN.1. Offsets:
    der[i]=0x02 der[i+1]=0x01 der[i+2]=0x01 der[i+3]=0x04 der[i+4]=0x20
    e os 32 octetos do escalar começam em der[i+5]."""
    idx = der.find(b"\x02\x01\x01\x04\x20")
    if idx < 0:
        return None
    start = idx + 5
    if len(der) < start + 32:
        return None
    return der[start:start + 32]


def _pem_body(text):
    begin = text.find("-----BEGIN")
    end = text.find("-----END", begin + 1)
    if begin < 0 or end < 0:
        return None
    line_end = text.find("\n", begin)
    if line_end < 0 or line_end > end:
        return None
    return "".join(text[line_end + 1:end].split())


def load_signing_key(env=None):
    """Lê a chave privada do ambiente. Devolve `None` quando NÃO configurada
    (fail-closed) e levanta `ConfigError` quando configurada mas ilegível —
    chave corrompida nunca vira "sem chave", nem "qualquer chave". Nenhuma
    mensagem ecoa o valor do segredo."""
    env = os.environ if env is None else env
    raw = (env.get(VAPID_PRIVATE_ENV) or "").strip()
    if not raw:
        return None
    if raw.startswith("-----BEGIN"):
        body = _pem_body(raw)
        if body is None:
            raise ConfigError("%s: PEM sem BEGIN/END" % VAPID_PRIVATE_ENV)
        try:
            der = base64.b64decode(body.encode("ascii"), validate=False)
        except Exception:
            raise ConfigError("%s: corpo PEM não é base64" % VAPID_PRIVATE_ENV)
        d = _extract_d_from_der(der)
        if d is None:
            raise ConfigError("%s: PEM sem ECPrivateKey P-256 (32 octetos)"
                              % VAPID_PRIVATE_ENV)
        try:
            return private_scalar(d)
        except ValueError as exc:
            raise ConfigError("%s: %s" % (VAPID_PRIVATE_ENV, exc))
    try:
        blob = b64u_decode(raw, strict=False)
    except ValueError:
        raise ConfigError("%s: nem base64url nem PEM" % VAPID_PRIVATE_ENV)
    if len(blob) == 32:
        try:
            return private_scalar(blob)
        except ValueError as exc:
            raise ConfigError("%s: %s" % (VAPID_PRIVATE_ENV, exc))
    if len(blob) > 40:
        d = _extract_d_from_der(blob)
        if d is not None:
            try:
                return private_scalar(d)
            except ValueError as exc:
                raise ConfigError("%s: %s" % (VAPID_PRIVATE_ENV, exc))
    raise ConfigError("%s: tamanho não reconhecido (32 octetos, SEC1 ou PKCS#8)"
                      % VAPID_PRIVATE_ENV)


def signing_key_configured(env=None):
    """Só responde se HÁ chave; a validação completa é `push_ready()`."""
    env = os.environ if env is None else env
    return bool((env.get(VAPID_PRIVATE_ENV) or "").strip())


def push_ready(env=None):
    """(ready, motivo). `motivo` é a chave pública em base64url quando pronto,
    ou um rótulo estático quando não — nunca contém segredo. É o que o sender
    e o `GET /push/vapid` consultam; do lado do jogo, `CanDeliver()` só fica
    true depois que um companion respondeu pronto daqui."""
    env = os.environ if env is None else env
    if not signing_key_configured(env):
        return False, "no_vapid_private_key"
    try:
        priv = load_signing_key(env)
        derived = public_key_from_private(priv)
    except ConfigError as exc:
        return False, "vapid_key_invalid:%s" % exc
    wanted = (env.get(VAPID_PUBLIC_ENV) or "").strip()
    if wanted:
        try:
            normalized = b64u_encode(b64u_decode(wanted))
        except ValueError:
            return False, "vapid_public_key_undecodable"
        if normalized != derived:
            return False, "vapid_key_mismatch"
    return True, derived


# --------------------------------------------------------------------------
# VAPID (RFC 8292): assertion + header Authorization
# --------------------------------------------------------------------------

_DEFAULT_PORT = {"http": 80, "https": 443}


def _origin(url):
    """Origem RFC 6454 do endpoint — o valor de `aud` da RFC 8292 §2.

    A porta Default é SUPRIMIDA na serialização: o `aud` do exemplo publicado da
    RFC 8292 é `https://apns.example.com` sem `:443`, e é assim que o push
    service calcula a própria origem para conferir o token. Manter `:443` não é
    "mais explícito": é uma origem diferente, e a recusa chega como 403 sem
    dizer o quê. Portas não-padrão continuam viajando, porque elas são parte da
    origem."""
    parts = urllib.parse.urlsplit(url)
    if not parts.scheme or not parts.netloc:
        raise ConfigError("endpoint sem origem absoluta: recusa assinar")
    scheme = parts.scheme.lower()
    host = parts.netloc.lower()
    try:
        port = parts.port
    except ValueError:
        raise ConfigError("endpoint com porta não-numérica: recusa assinar")
    if port is not None and _DEFAULT_PORT.get(scheme) == port:
        host = host.rsplit(":", 1)[0]
    return "%s://%s" % (scheme, host)


def vapid_jwt_input(endpoint, subject=None, now=None, token_ttl=None):
    """A input string assinável (ASCII `base64url(header).base64url(claims)`),
    mais as claims. Exposta para o teste poder reproduzir byte a byte o
    exemplo da RFC 8292 §2.4."""
    aud = _origin(endpoint)
    now = int(time.time()) if now is None else int(now)
    if token_ttl is None:
        token_ttl = int(os.environ.get(VAPID_TOKEN_TTL_ENV) or TOKEN_TTL)
    token_ttl = max(60, min(int(token_ttl), MAX_TOKEN_TTL))    # RFC 8292 §2
    if subject is None:
        subject = (os.environ.get(VAPID_SUBJECT_ENV) or "").strip() or None
    header = {"typ": "JWT", "alg": "ES256"}
    claims = {"aud": aud, "exp": now + token_ttl}
    if subject:
        claims["sub"] = subject
    seg_h = b64u_encode(json.dumps(header, separators=(",", ":")).encode("ascii"))
    seg_p = b64u_encode(json.dumps(claims, separators=(",", ":")).encode("ascii"))
    return "%s.%s" % (seg_h, seg_p), claims


def vapid_authorization(endpoint, private_key=None, subject=None, now=None,
                        token_ttl=None):
    """`Authorization: vapid t=<JWT completo>, k=<chave pública X9.62>`
    (RFC 8292 §3.1/§3.2). `k` é público por definição — é como o push service
    escolhe a chave que verifica `t`.

    Devolve (header_value, jwt, public_key_b64u, sig_b64u).
    """
    if private_key is None:
        private_key = load_signing_key()
        if private_key is None:
            raise ConfigError("chave VAPID ausente: nada é assinado")
    d = private_scalar(private_key)
    signing_input, _claims = vapid_jwt_input(endpoint, subject=subject, now=now,
                                             token_ttl=token_ttl)
    sig = ecdsa_sign(signing_input, d)
    pub = public_key_from_private(d)
    if not ecdsa_verify(signing_input, sig, b64u_decode(pub, strict=False)):
        # Autoconfere antes de sair pela porta: assinar errado e descobrir no
        # 403 do provedor é a pior forma de falha possível aqui.
        raise PushError("assertion VAPID não se auto-verificou")
    jwt = "%s.%s" % (signing_input, b64u_encode(sig))
    return "vapid t=%s, k=%s" % (jwt, pub), jwt, pub, b64u_encode(sig)


# --------------------------------------------------------------------------
# HTTP (RFC 8030) — o POST que um push service real recebe
# --------------------------------------------------------------------------

def build_request(subscription, title, body, icon=None, url=None, ttl=None,
                  private_key=None, now=None, salt=None, eph_private=None):
    """Monta (url, headers, corpo) de um POST de push de verdade. Separado do
    `send()` para que o teste confira os octetos sem tocar na rede.
    `eph_private`/`salt`/`now` só existem para teste determinístico."""
    if not isinstance(subscription, dict):
        raise ConfigError("subscription deve ser dict com endpoint/p256dh/auth")
    endpoint = (subscription.get("endpoint") or "").strip()
    p256dh = (subscription.get("p256dh") or "").strip()
    auth = (subscription.get("auth") or "").strip()
    if not (endpoint and p256dh and auth):
        raise ConfigError("subscription incompleta: endpoint/p256dh/auth obrigatórios")
    parts = urllib.parse.urlsplit(endpoint)
    if parts.scheme not in ("https", "http"):
        raise ConfigError("endpoint de push fora de http(s)")
    if parts.scheme == "http" and parts.hostname not in CLEARTEXT_HOSTS:
        raise ConfigError("recusa enviar credencial VAPID em claro para %s" % parts.hostname)
    payload = {"title": title or "Shambleta", "body": body or "",
               "icon": icon or "index.144x144.png", "url": url or "/"}
    plaintext = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if eph_private is None:
        eph_private = b64u_decode(generate_keypair()[0])
    blob = encrypt_message(p256dh, auth, plaintext, eph_private, salt=salt)
    authz, _jwt, _pub, _sig = vapid_authorization(endpoint, private_key=private_key,
                                                  now=now)
    if ttl is None:
        try:
            ttl = int(os.environ.get(PUSH_TTL_ENV) or DEFAULT_TTL)
        except ValueError:
            ttl = DEFAULT_TTL
    ttl = max(0, min(ttl, MAX_TTL))
    headers = {
        "Authorization": authz,
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/json",
        "TTL": str(ttl),
        "Urgency": "low",
        "User-Agent": USER_AGENT,
        "Content-Length": str(len(blob)),
    }
    return endpoint, headers, blob


def send(subscription, title, body, icon=None, url=None, ttl=None, timeout=None,
         private_key=None):
    """POST real no endpoint de push. Devolve o status HTTP em 2xx (RFC 8030
    §4.3 espera 201); 404/410 levantam `SubscriptionGone` para a fila apagar a
    subscription; qualquer outra falha levanta `PushError`. Nunca um sucesso
    silencioso.

    `http.client` e não `urllib`: primeiro porque `urllib` segue redirecionamento
    sozinho e reenviaria o `Authorization` VAPID para um host que o endpoint não
    escolheu — credencial de assinatura não viaja por 302; segundo porque
    `Request.add_header()` canibaliza o nome (`"TTL"` virava `"Ttl"`), e o
    header que a RFC 8030 §5.2 documenta é `TTL`.
    """
    ready, _reason = push_ready()
    if not ready:
        raise ConfigError("vapid sender não configurado")
    endpoint, headers, blob = build_request(subscription, title, body, icon=icon,
                                            url=url, ttl=ttl,
                                            private_key=private_key)
    parts = urllib.parse.urlsplit(endpoint)
    host = parts.netloc
    if timeout is None:
        try:
            timeout = float(os.environ.get(PUSH_TIMEOUT_ENV) or 10)
        except ValueError:
            timeout = 10.0
    path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
    if parts.scheme == "https":
        conn = http.client.HTTPSConnection(
            parts.hostname, parts.port or 443, timeout=timeout,
            context=ssl.create_default_context())
    else:
        conn = http.client.HTTPConnection(parts.hostname, parts.port or 80,
                                          timeout=timeout)
    try:
        conn.putrequest("POST", path, skip_accept_encoding=True)
        for name, value in headers.items():
            conn.putheader(name, value)
        conn.endheaders(blob, encode_chunked=False)
        resp = conn.getresponse()
        status = int(resp.status)
        resp.read()                       # drena o corpo; nunca vai para log
    except OSError as exc:
        raise PushError("falha de transporte no push (%s) @ %s"
                        % (type(exc).__name__, host))
    finally:
        conn.close()
    if 200 <= status < 300:
        return status
    if status in (404, 410):
        raise SubscriptionGone(status, host)
    if status in (301, 302, 303, 307, 308):
        raise PushError("endpoint de push redireciona (%d @ %s): recusa "
                        "reenviar a credencial VAPID" % (status, host))
    raise PushError("push service respondeu HTTP %d @ %s" % (status, host))
