"""AES-128-GCM + HKDF + o record `aes128gcm` (RFC 8188 / RFC 8291 §3.4, §4).

Segunda camada do caminho de push. Sabe cifrar e abrir o corpo que vai no POST
de push — e só isso: não conhece JWT, HTTP nem nomes de variável de ambiente.

Por que escrito à mão: a stdlib do Python expõe `hashlib`/`hmac`, mas não expõe
AES nem GCM (o AES que existe dentro do `ssl` não é API pública). O companion é
stdlib-only por contrato, então o content coding de RFC 8291 vem daqui. A S-box
do AES é DERIVADA em runtime (inverso em GF(2^8) por log/antilog + a
transformação afim do §5.4), então não há 256 constantes mágicas para auditar
nem literal gigante no diff — e a derivação é conferida contra o known-answer
do Anexo C.1 da FIPS-197.

Camadas deste arquivo:
  * AES-128 (FIPS-197) — só a direção de cifração, que é o que GCM usa;
  * GHASH/GCM (NIST SP 800-38D) — a tag conferida ANTES de devolver octeto;
  * HKDF (RFC 5869, SHA-256);
  * a derivação de RFC 8291 §3.4, escrita octeto por octeto como o texto da
    RFC, com os intermediários (PRK_key, IKM, PRK, CEK, NONCE) devolvidos para
    o teste conferir contra o Appendix A;
  * `encrypt_message` / `decrypt_message` — a moldura de RFC 8188 §3.1
    (salt || rs || idlen || keyid || registros) com o delimiter 0x02.

Medido contra vetor publicado em `companion/test_push_aesgcm.py`: FIPS-197 C.1,
SP 800-38D casos 1/2, RFC 8188 §3.1 (corpo de 53 octetos) e RFC 8291 §5 (header
de 86, corpo de 144 — cifra e abre a cadeia inteira, octeto por octeto).
"""

import hashlib
import hmac
import os
import secrets
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from push_common import (HEADER_LEN, MAX_PAYLOAD, NONCE_LEN, RECORD_SIZE,  # noqa: E402
                         SALT_LEN, TAG_LEN, MaterialError, PushError,
                         b64u_decode)
from push_p256 import (P256, decode_uncompressed, ecdh, encode_uncompressed,  # noqa: E402
                       private_scalar, scalar_multiply)

__all__ = [
    "gcm_encrypt", "gcm_decrypt", "encrypt_message", "decrypt_message",
    "hkdf_extract", "hkdf_expand", "push_key_schedule",
]

# --------------------------------------------------------------------------
# AES-128 (FIPS-197) — só a direção de cifração, que é o que AES-GCM usa.
# A S-box é DERIVADA em runtime (inverso em GF(2^8) por log/antilog com
# gerador primitivo 3 + transformação afim do §5.4), então não há 256
# constantes mágicas para auditar nem literal gigante no diff. Conferida
# contra o known-answer do Anexo C.1 em test_push_vapid.py.
# --------------------------------------------------------------------------

def _xtime(a):
    a <<= 1
    if a & 0x100:
        a ^= 0x11B
    return a & 0xFF


def _build_sbox():
    pow_tab = [0] * 512
    log_tab = [0] * 256
    x = 1
    for i in range(255):
        pow_tab[i] = x
        log_tab[x] = i
        x = _xtime(x) ^ x              # x <- 3*x; 3 gera GF(256)*
    for i in range(255, 512):
        pow_tab[i] = pow_tab[i - 255]
    sbox = [0] * 256
    for i in range(256):
        # a * a^-1 = 1 e a = 3^log(a) com 3^255 = 1  ==>  a^-1 = 3^(255-log(a))
        inv = 0 if i == 0 else pow_tab[255 - log_tab[i]]
        s = inv
        v = inv
        for _ in range(4):             # b ^ rotl(b,1..4) ^ 0x63
            v = ((v << 1) | (v >> 7)) & 0xFF
            s ^= v
        sbox[i] = s ^ 0x63
    return sbox


_SBOX = _build_sbox()


def _expand_key(key):
    """AES-128: 16 octetos de chave -> 44 palavras de 4 (Nr = 10)."""
    if len(key) != 16:
        raise ValueError("AES-128 exige chave de 16 octetos")
    w = [list(key[4 * i:4 * i + 4]) for i in range(4)]
    rcon = 1
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _encrypt_block(w, block):
    """FIPS-197 §5; state column-major: state[r + 4c] = in[4c + r]."""
    s = list(block)
    for rnd in range(11):
        if rnd:
            s = [_SBOX[b] for b in s]                       # SubBytes
            for r in range(1, 4):                           # ShiftRows
                row = [s[r + 4 * c] for c in range(4)]
                for c in range(4):
                    s[r + 4 * c] = row[(c + r) % 4]
            if rnd != 10:                                   # MixColumns
                for c in range(4):
                    a = s[4 * c:4 * c + 4]
                    t = a[0] ^ a[1] ^ a[2] ^ a[3]
                    o = list(a)
                    for i in range(4):
                        o[i] = a[i] ^ t ^ _xtime(a[i] ^ a[(i + 1) % 4])
                    s[4 * c:4 * c + 4] = o
        off = 4 * rnd
        for c in range(4):                                  # AddRoundKey
            for r in range(4):
                s[r + 4 * c] ^= w[off + c][r]
    return bytes(s)


def _gmul(x, y):
    """Produto em GF(2^128) (NIST SP 800-38D Algoritmo 1, ordem refletida,
    R = 0xe1 || 0^120)."""
    z = 0
    v = y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ (0xE1 << 120) if v & 1 else v >> 1
    return z


def _ghash(h, data, acc):
    """GHASH em cadeia. `data` precisa ser múltiplo de 16 octetos."""
    if len(data) % 16:
        raise ValueError("GHASH: bloco não alinhado a 16 octetos")
    for i in range(0, len(data), 16):
        acc ^= int.from_bytes(data[i:i + 16], "big")
        acc = _gmul(acc, h)
    return acc


def _pad16(data):
    rem = len(data) % 16
    return data if rem == 0 else data + b"\x00" * (16 - rem)


def _gctr(w, j0, data):
    """CTR do GCM: o contador começa em inc32(J0) e só a parte de 32 bits
    cresce (SP 800-38D §6.5)."""
    out = bytearray()
    ctr = j0
    for off in range(0, len(data), 16):
        ctr = (ctr & ~0xFFFFFFFF) | ((ctr + 1) & 0xFFFFFFFF)
        ks = _encrypt_block(w, ctr.to_bytes(16, "big"))
        chunk = data[off:off + 16]
        out += bytes(a ^ b for a, b in zip(chunk, ks))
    return bytes(out)


def _gcm_tag_input(aad, ct):
    return _pad16(aad) + _pad16(ct) + struct.pack(">QQ", 8 * len(aad), 8 * len(ct))


def gcm_encrypt(key, nonce, plaintext, aad=b""):
    """AES-128-GCM (IV de 12 octetos, que é o único que Web Push usa):
    devolve ciphertext||tag."""
    if len(nonce) != NONCE_LEN:
        raise ValueError("AES-GCM neste módulo suporta IV de 12 octetos")
    w = _expand_key(key)
    h = int.from_bytes(_encrypt_block(w, b"\x00" * 16), "big")
    j0 = int.from_bytes(nonce + b"\x00\x00\x00\x01", "big")
    ct = _gctr(w, j0, plaintext)
    s = _ghash(h, _gcm_tag_input(aad, ct), 0)
    mask = int.from_bytes(_encrypt_block(w, j0.to_bytes(16, "big")), "big")
    return ct + (s ^ mask).to_bytes(TAG_LEN, "big")


def gcm_decrypt(key, nonce, ciphertext, aad=b""):
    """Abre AES-128-GCM conferindo a tag ANTES de devolver qualquer octeto."""
    if len(nonce) != NONCE_LEN:
        raise ValueError("AES-GCM neste módulo suporta IV de 12 octetos")
    if len(ciphertext) < TAG_LEN:
        raise PushError("AES-GCM: ciphertext curto demais (sem tag)")
    body, tag = ciphertext[:-TAG_LEN], ciphertext[-TAG_LEN:]
    w = _expand_key(key)
    h = int.from_bytes(_encrypt_block(w, b"\x00" * 16), "big")
    j0 = int.from_bytes(nonce + b"\x00\x00\x00\x01", "big")
    s = _ghash(h, _gcm_tag_input(aad, body), 0)
    mask = int.from_bytes(_encrypt_block(w, j0.to_bytes(16, "big")), "big")
    if not hmac.compare_digest(((s ^ mask).to_bytes(TAG_LEN, "big")), tag):
        raise PushError("AES-GCM: tag de autenticação não confere")
    return _gctr(w, j0, body)


# --------------------------------------------------------------------------
# HKDF (RFC 5869, SHA-256) e a derivação de RFC 8291 §3.4, literal
# --------------------------------------------------------------------------

def hkdf_extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk, info, length):
    out = b""
    t = b""
    counter = 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


def push_key_schedule(ua_public, as_public, auth_secret, ecdh_secret, salt):
    """RFC 8291 §3.4 passo a passo. Devolve (CEK, NONCE, IKM, PRK, PRK_key) —
    os intermediários existem para o teste conferir contra o Appendix A."""
    key_info = b"WebPush: info\x00" + ua_public + as_public
    prk_key = hmac.new(auth_secret, ecdh_secret, hashlib.sha256).digest()
    ikm = hkdf_expand(prk_key, key_info, 32)
    prk = hkdf_extract(salt, ikm)
    cek = hkdf_expand(prk, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = hkdf_expand(prk, b"Content-Encoding: nonce\x00", 12)
    return cek, nonce, ikm, prk, prk_key


def _as_bytes(value, minimum, label):
    """Material de subscription (auth, keyid) em octetos, com o piso de
    tamanho da RFC. `MaterialError` nos dois sentidos: curto demais é dado
    ruim, e `b64u_decode` de um valor degenerado ('A') também — um sender
    que só reclama de tamanho não mede é o parser deixando passar lixo."""
    try:
        raw = (b64u_decode(value, strict=False) if isinstance(value, str)
               else bytes(value))
    except MaterialError:
        raise MaterialError("%s não é base64url" % label)
    if len(raw) < minimum:
        raise MaterialError("%s curto demais (%d octetos)" % (label, len(raw)))
    return raw


def encrypt_message(ua_public, auth, plaintext, as_private, salt=None,
                    record_size=RECORD_SIZE):
    """Corpo `Content-Encoding: aes128gcm` de uma mensagem de push.

    ua_public/auth = `keys.p256dh` e `keys.auth` da subscription; as_private =
    escalar do REMETENTE. A RFC 8292 §3.2 proíbe reusar a chave de assinatura
    VAPID na troca de chaves, então `send()`/`build_request()` geram um par
    efêmero por mensagem — é ele que viaja em `keyid`. Devolve
    header(86) || ciphertext||tag; um navegador abre com `decrypt_message()`.
    """
    if isinstance(plaintext, str):
        plaintext = plaintext.encode("utf-8")
    if not plaintext:
        raise PushError("payload de push vazio")
    ua_point = decode_uncompressed(ua_public)
    ua_public = encode_uncompressed(ua_point)
    auth_raw = _as_bytes(auth, 13, "keys.auth")     # RFC 8291 §3.2 pede 16
    d = private_scalar(as_private)
    as_public = encode_uncompressed(scalar_multiply(d, P256.generator()))
    if as_public == ua_public:
        # RFC 8292 §3.2: um push service DEVE recusar keyid == chave da subscription.
        raise PushError("chave efêmera igual à do receptor (RFC 8292 §3.2)")
    ecdh_secret = ecdh(d, ua_point)
    if salt is None:
        salt = secrets.token_bytes(SALT_LEN)
    elif isinstance(salt, str):
        salt = b64u_decode(salt)
    if len(salt) != SALT_LEN:
        raise MaterialError("salt do content coding precisa de 16 octetos")
    padded = plaintext + b"\x02"                    # delimiter: último registro
    if len(padded) + TAG_LEN > record_size:
        raise PushError("payload não cabe num único registro (RFC 8291 §4)")
    if len(padded) + TAG_LEN + HEADER_LEN > RECORD_SIZE:
        raise PushError("payload excede os %d octetos que um push service deve aceitar"
                        % MAX_PAYLOAD)
    cek, nonce, _ikm, _prk, _prk_key = push_key_schedule(
        ua_public, as_public, auth_raw, ecdh_secret, salt)
    header = salt + struct.pack(">I", record_size) + bytes([len(as_public)]) + as_public
    return header + gcm_encrypt(cek, nonce, padded)


def decrypt_message(body, ua_private, auth):
    """Lado do receptor (user agent / teste): abre um corpo `aes128gcm` e
    devolve o payload sem padding. É o que prova que um navegador real abre o
    que este módulo cifra — e o que abre o corpo publicado na RFC 8291 §5."""
    if len(body) < HEADER_LEN + TAG_LEN:
        raise PushError("corpo aes128gcm curto demais")
    salt = body[:SALT_LEN]
    record_size = struct.unpack(">I", body[16:20])[0]
    idlen = body[20]
    if idlen != 65:
        raise PushError("keyid aes128gcm precisa de 65 octetos (X9.62 P-256)")
    keyid = body[21:21 + idlen]
    as_public = decode_uncompressed(keyid)
    ua_priv = private_scalar(ua_private)
    ua_public = encode_uncompressed(scalar_multiply(ua_priv, P256.generator()))
    auth_raw = _as_bytes(auth, 13, "keys.auth")
    ecdh_secret = ecdh(ua_priv, as_public)
    cek, nonce, _ikm, _prk, _prk_key = push_key_schedule(
        ua_public, keyid, auth_raw, ecdh_secret, salt)
    padded = gcm_decrypt(cek, nonce, body[21 + idlen:])
    if record_size < len(padded) + TAG_LEN:
        raise PushError("rs declarado menor que o registro")
    if padded[-1] != 0x02:
        raise PushError("padding delimiter ausente/inválido (RFC 8291 §4)")
    return padded[:-1].rstrip(b"\x00")
