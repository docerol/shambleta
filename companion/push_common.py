#!/usr/bin/env python3
"""Vocabulário comum do caminho de push: erros, nomes de config e base64url.

É o primeiro degrau da fatia do signer (RFC 8292/8291/8188). `push_vapid.py`
media 944 linhas num único arquivo — acima do teto anti-god-node do repositório
(800) — e a alternativa era crescer o teto, o que é exatamente como o
`EconomyService` de 3839 linhas nasceu. As costuras escolhidas são as que já
existiam no arquivo, não divisões arbitrárias:

    push_common.py   erros + nomes de ambiente/constantes + base64url  (este)
    push_p256.py     o primitivo: P-256, ECDH e ECDSA determinística
    push_aesgcm.py   AES-128-GCM, HKDF e o record `aes128gcm` (RFC 8188/8291)
    push_vapid.py    chave, assertion VAPID (RFC 8292) e o POST HTTP (RFC 8030)

Cada camada só olha para baixo: `push_p256` não sabe o que é um `keyid`,
`push_aesgcm` não sabe o que é um JWT, e nada além de `push_vapid.py` sabe o
que é `http.client`. O público do companion continua sendo `push_vapid.py`, que
reexporta tudo — `server.py` não precisa saber em quantos arquivos a
implementação foi dividida.

Tudo aqui é stdlib puro por contrato (o `deploy/companion/Dockerfile` copia um
arquivo e não roda `pip`).
"""

import base64

__all__ = [
    "PushError", "ConfigError", "SubscriptionGone", "MaterialError",
    "VAPID_PRIVATE_ENV", "VAPID_PUBLIC_ENV", "VAPID_SUBJECT_ENV",
    "PUSH_TTL_ENV", "PUSH_TIMEOUT_ENV", "VAPID_TOKEN_TTL_ENV",
    "RECORD_SIZE", "TAG_LEN", "NONCE_LEN", "SALT_LEN", "HEADER_LEN",
    "MAX_PAYLOAD", "DEFAULT_TTL", "MAX_TTL", "TOKEN_TTL", "MAX_TOKEN_TTL",
    "USER_AGENT", "CLEARTEXT_HOSTS",
    "b64u_encode", "b64u_decode",
]

# --------------------------------------------------------------------------
# nomes de segredo/config — a única fonte; nenhum valor mora aqui.
# --------------------------------------------------------------------------
VAPID_PRIVATE_ENV = "SHAMBLETA_VAPID_PRIVATE_KEY"
VAPID_PUBLIC_ENV = "SHAMBLETA_VAPID_PUBLIC_KEY"
VAPID_SUBJECT_ENV = "SHAMBLETA_VAPID_SUBJECT"
PUSH_TTL_ENV = "SHAMBLETA_PUSH_TTL"
PUSH_TIMEOUT_ENV = "SHAMBLETA_PUSH_TIMEOUT"
VAPID_TOKEN_TTL_ENV = "SHAMBLETA_VAPID_TOKEN_TTL"

RECORD_SIZE = 4096           # RFC 8291 §4: "rs"; 4096 é o valor mínimo
TAG_LEN = 16
NONCE_LEN = 12
SALT_LEN = 16
HEADER_LEN = 86              # salt(16) rs(4) idlen(1) keyid(65)
MAX_PAYLOAD = 3993           # RFC 8291 §4: o que um push service DEVE aceitar
DEFAULT_TTL = 3600           # RFC 8030 §5.2 (TTL em segundos)
MAX_TTL = 4 * 7 * 24 * 3600  # RFC 8030 §5.2: quatro semanas
TOKEN_TTL = 7200             # RFC 8292 §2: "exp" nunca a mais de 24h
MAX_TOKEN_TTL = 24 * 3600
USER_AGENT = "shambleta-companion/1.0 (web push)"

# Um sender de verdade não manda credencial VAPID em claro. Loopback é a
# única exceção, porque é onde o harness e2e (e só ele) finge um push service.
CLEARTEXT_HOSTS = frozenset(["127.0.0.1", "localhost", "::1"])


class PushError(Exception):
    """Falha de entrega (rede, HTTP, payload). Nunca contém segredo."""


class ConfigError(PushError):
    """Configuração ausente ou incoerente: fail-closed, nunca um envio pela metade."""


class SubscriptionGone(PushError):
    """404/410 do provedor: a subscription morreu (RFC 8030 §5.4)."""

    def __init__(self, status, endpoint_host):
        super().__init__("push subscription gone (HTTP %d @ %s)"
                         % (status, endpoint_host))
        self.status = status
        self.endpoint_host = endpoint_host


class MaterialError(PushError, ValueError):
    """Material criptográfico malformado: chave, ponto, salt, auth, IV.

    Duas bases porque duas leituras são legítimas e nenhuma das duas pode
    perder: para quem trata a entrada como "valor ruim" isto É um `ValueError`
    (o verifier de `ecdsa_verify` captura ValueError e devolve False, como
    RFC 8292 §5 manda); para a fila do companion isto É um `PushError`, porque
    um `ValueError` cru escapando de `send()` viraria linha 'failed' sem
    classificação e, pior, sem a garantia de que não ecoa segredo.
    `ConfigError` fica de fora de propósito: chave ilegível no ambiente é erro
    de operador, não dado de rede, e é a exceção que o sender traduz em
    fail-closed."""


# --------------------------------------------------------------------------
# base64url sem padding (RFC 4648 §5 / RFC 7515 §2)
# --------------------------------------------------------------------------

_B64U_ALPHABET = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")


def b64u_encode(data):
    """base64url SEM padding, como JWT e Web Push exigem."""
    return base64.urlsafe_b64encode(bytes(data)).rstrip(b"=").decode("ascii")


def b64u_decode(text, strict=True):
    """Decodifica base64url. Aceita o padding da RFC 4648, mas só na forma
    válida: `=` existe para fechar o quantum de 4 caracteres, então
    `'AAAA='` (grupo cheio + padding) é malformed e `'AA=='` não é. Um
    decodificador que engole padding fora do lugar aceita credencial que
    nenhum provedor produziu — e é o parser, não a criptografia, que costuma
    ser o furo.

    `strict` rejeita bit-cauda não-canônica: chave pública com lixo nos
    bits de ordem baixa é vetor de ataque contra implementações descuidadas,
    então conferimos o round-trip."""
    if isinstance(text, (bytes, bytearray)):
        text = bytes(text).decode("ascii")
    text = text.strip()
    pad = len(text) - len(text.rstrip("="))
    if pad:
        body = text[:-pad]
        if pad > 2 or len(text) % 4 or (-len(body)) % 4 != pad:
            raise MaterialError("base64url: padding fora da forma da RFC 4648")
        text = body
    if any(c not in _B64U_ALPHABET for c in text):
        raise MaterialError("base64url: alfabeto inválido")
    if len(text) % 4 == 1:
        raise MaterialError("base64url: comprimento impossível")
    try:
        raw = base64.urlsafe_b64decode(text + "=" * ((-len(text)) % 4))
    except Exception:
        raise MaterialError("base64url: decodificação inválida")
    if strict and b64u_encode(raw) != text:
        raise MaterialError("base64url: codificação não-canônica")
    return raw
