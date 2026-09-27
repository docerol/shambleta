"""P-256 (secp256r1) + ECDH + ECDSA determinística (RFC 6979) em stdlib puro.

Camada mais funda do caminho de push: o primitivo assimétrico que o companion
precisa porque a stdlib do Python NÃO traz ECDSA nem ECDH, e o companion é
stdlib-only por contrato (`deploy/companion/Dockerfile` copia um arquivo e não
roda `pip install`). Trocar por `cryptography` trocaria um bloqueio por outro:
o sender funcionaria no laptop e continuaria inexistente na imagem que sobe.

O que este módulo sabe fazer:

  * aritmética de ponto em Jacobian com BLINDING de escalar (`_scalar_mul`);
  * validação de ponto affine antes de qualquer derivação (`decode_uncompressed`
    — invalid-curve é o vetor clássico contra ECDH, e aqui vira `MaterialError`
    antes de sair chave);
  * ECDH (RFC 8291 §3.3: só o X do ponto compartilhado);
  * ECDSA P-256/SHA-256 determinística (RFC 6979), no formato concatenado
    `r||s` que JWS/ES256 usa (RFC 7518 §3.1), mais o verifier.

O tradeoff, dito sem eufemismo: criptografia assimétrica escrita à mão é o que
um revisor de segurança ataca primeiro. Corretude não é suposição — os vetores
publicados (RFC 6979 A.2.5, RFC 8291 §5, RFC 8292 §2.4) são conferidos octeto
por octeto em `companion/test_push_p256.py`, e um verificador externo
(`openssl`, quando o binário existe) confere nos dois sentidos. Constant-time
NÃO é: `int` de CPython tem duração variável. A mitigação real é o blinding de
escalar — todo multiplicador passa por `k + t*n` com `t` aleatório, então o
padrão de ramificações/tempo é função de um valor aleatório, não do segredo.
Quem precisar de chave de alto valor troca esta camada por uma implementação
em C auditada: a API pública é pequena de propósito e nada acima dela conhece
primitivos.

Nenhum segredo é impresso: as mensagens de erro nomeiam o problema, nunca o
valor.
"""

import hashlib
import hmac
import os
import secrets
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from push_common import (MaterialError, PushError, b64u_decode,  # noqa: E402
                         b64u_encode)

__all__ = [
    "P256", "encode_uncompressed", "decode_uncompressed", "private_scalar",
    "generate_keypair", "public_key_from_private", "ecdh", "ecdsa_sign",
    "ecdsa_verify", "scalar_multiply",
]

# --------------------------------------------------------------------------
# P-256 (secp256r1 / prime256v1) — FIPS 186-4 D.2.3 + SEC 2
# --------------------------------------------------------------------------

class _Curve:
    p = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
    a = p - 3
    b = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
    n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
    gx = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
    gy = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5

    @staticmethod
    def generator():
        return (P256.gx, P256.gy, 1)


P256 = _Curve()
_INFINITY = (1, 1, 0)


def _is_inf(pt):
    return pt[2] % P256.p == 0


def _jac(pt):
    """Aceita affine (x,y) ou Jacobian (x,y,z)."""
    if len(pt) == 3:
        return pt
    return (pt[0], pt[1], 1)


def _double(pt):
    """Doubling em Jacobian, fórmula geral (SEC1 V2 §2.2.1 / openssl
    ec_GFp_mont_point_double), com a = -3."""
    p = P256.p
    x1, y1, z1 = pt
    if _is_inf(pt) or y1 % p == 0:
        return _INFINITY
    y1sq = y1 * y1 % p
    w = (3 * x1 * x1 + P256.a * pow(z1, 4, p)) % p
    x3 = (w * w - 8 * x1 * y1sq) % p
    y3 = (w * (4 * x1 * y1sq - x3) - 8 * y1sq * y1sq) % p
    z3 = 2 * y1 * z1 % p
    return (x3, y3, z3)


def _add(p1, p2):
    """Addition em Jacobian (SEC1 V2 §2.2.1); trata infinito, dobro e opostos."""
    p = P256.p
    x1, y1, z1 = p1
    x2, y2, z2 = p2
    if _is_inf(p1):
        return p2
    if _is_inf(p2):
        return p1
    z1z1 = z1 * z1 % p
    z2z2 = z2 * z2 % p
    u1 = x1 * z2z2 % p
    u2 = x2 * z1z1 % p
    s1 = y1 * z2 % p * z2z2 % p
    s2 = y2 * z1 % p * z1z1 % p
    if u1 == u2:
        return _double(p1) if s1 == s2 else _INFINITY
    h = (u2 - u1) % p
    r = (s2 - s1) % p
    hh = h * h % p
    hhh = h * hh % p
    x3 = (r * r - hhh - 2 * u1 * hh) % p
    y3 = (r * (u1 * hh - x3) - s1 * hhh) % p
    z3 = z1 * z2 % p * h % p
    return (x3, y3, z3)


def _affine(pt):
    """Jacobian -> affine; None para o infinito. p = 3 (mod 4), então o
    inverso sai de Fermat sem extended-Euclid."""
    if _is_inf(pt):
        return None
    p = P256.p
    x, y, z = pt
    zi = pow(z, p - 2, p)
    zi2 = zi * zi % p
    return (x * zi2 % p, y * zi2 % p * zi % p)


def _scalar_mul(k, pt):
    """k*pt com BLINDING de escalar: (k + t*n)*pt == k*pt porque a ordem de
    P-256 é n, mas o padrão de tempo/ramificação passa a depender de `t`.
    Isto NÃO torna a função constant-time (int de CPython não é) — fecha o
    vazamento direto de `k`, que em ECDSA é o que compromete a chave privada.
    `k` deve estar em [1, n-1]; `pt` affine ou Jacobian."""
    k %= P256.n
    if k == 0:
        return None
    p2 = _jac(pt)
    blinded = k + secrets.randbelow(1 << 64) * P256.n
    acc = _INFINITY
    for i in range(blinded.bit_length() - 1, -1, -1):
        acc = _double(acc)
        if (blinded >> i) & 1:
            acc = _add(acc, p2)
    return _affine(acc)


def scalar_multiply(k, point):
    """Nome público de `_scalar_mul` para as camadas de cima (o record
    `aes128gcm` e o assertion VAPID precisam derivar chave pública a partir de
    um escalar; nada fora deste módulo toca na aritmética de ponto)."""
    return _scalar_mul(private_scalar(k), point)


def encode_uncompressed(point):
    """X9.62 não comprimido: 0x04 || x(32) || y(32) — a forma de `keyid`
    (RFC 8291 §4), de `applicationServerKey` e do parâmetro `k` (RFC 8292 §3.2)."""
    if point is None:
        raise MaterialError("ponto no infinito não tem encoding")
    return b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")


def decode_uncompressed(data):
    """Decodifica e VALIDA affine. A lista é a de RFC 8291 §7.3 / RFC 8292
    §3.2: não infinito, coordenadas no corpo primo, solução da equação.
    Ponto fora da curva é o vetor clássico de ataque em ECDH: aqui ele vira
    `MaterialError` (um `ValueError` que também é `PushError`) antes de
    qualquer chave ser derivada.

    Aceita as duas formas em que `p256dh` chega de verdade: os 65 octetos X9.62
    e o texto base64url (que é o que o JSON da subscription traz). Um buffer de
    bytes que não é nenhuma das duas — nem ASCII legível — É material ruim: o
    `UnicodeDecodeError` do codec é traduzido em `MaterialError` em vez de
    escapar cru para a fila."""
    if not (len(data) == 65 and data[0] == 0x04):
        try:
            data = b64u_decode(data)
        except ValueError as exc:
            raise MaterialError("chave pública não é X9.62 nem base64url (%s)"
                                % exc)
    if len(data) != 65 or data[0] != 0x04:
        raise MaterialError("chave pública P-256 deve ser X9.62 não comprimida "
                            "(65 octetos iniciados por 0x04)")
    p = P256.p
    x = int.from_bytes(data[1:33], "big")
    y = int.from_bytes(data[33:65], "big")
    if x == 0 or y == 0 or x >= p or y >= p:
        raise MaterialError("coordenadas fora do corpo primo")
    if (y * y - (pow(x, 3, p) + P256.a * x + P256.b)) % p != 0:
        raise MaterialError("ponto não satisfaz a equação de P-256")
    return (x, y)


def private_scalar(value):
    """O ESCALAR privado, seja ele `int`, 32 octetos ou base64url deles — e
    sempre conferido em [1, n-1].

    O `int` entra no conferimento porque é exatamente assim que este módulo
    recebe a chave do ambiente: `load_signing_key()` devolve um inteiro, e um
    atalho `priv if isinstance(priv, int)` deixaria `0`, negativo ou `>= n`
    passarem direto para `_scalar_mul`, onde `k % n` os transformaria em outra
    coisa (0 → ponto ao infinito, `n` → de novo 0). Assinatura produzida com um
    escalar fora do intervalo não é "chave inválida descoberta depois": é
    desperdício silencioso. `MaterialError` para que tanto um `except
    ValueError` quanto um `except PushError` no caminho de entrega peguem."""
    if isinstance(value, int):
        k = value
    else:
        raw = (bytes(value) if isinstance(value, (bytes, bytearray))
               else b64u_decode(value))
        if len(raw) != 32:
            raise MaterialError("escalar privado P-256 precisa de 32 octetos")
        k = int.from_bytes(raw, "big")
    if k < 1 or k >= P256.n:
        raise MaterialError("escalar privado fora de [1, n-1]")
    return k


def generate_keypair():
    """Par descartável (privado_b64u, publico_b64u). Usado por teste e por
    `server.py --push-vapid-keygen`; este módulo nunca imprime o privado."""
    d = secrets.randbelow(P256.n - 1) + 1
    return b64u_encode(d.to_bytes(32, "big")), public_key_from_private(d)


def public_key_from_private(priv):
    """Chave pública X9.62 em base64url a partir do escalar (int ou 32 octetos
    ou base64url deles) — o `applicationServerKey` e o `k` do header VAPID."""
    d = private_scalar(priv)
    return b64u_encode(encode_uncompressed(_scalar_mul(d, P256.generator())))


# --------------------------------------------------------------------------
# ECDH (RFC 8291 §3.3) — o segredo compartilhado que alimenta o HKDF
# --------------------------------------------------------------------------

def ecdh(priv, peer_public):
    """Segredo compartilhado [ECDH] = X de priv*peer (RFC 8291 §3.3). Peer
    validado ANTES de qualquer multiplicação: ponto fora da curva é o vetor
    clássico contra ECDH, e aqui ele não chega à aritmética."""
    d = private_scalar(priv)
    point = peer_public if isinstance(peer_public, tuple) else decode_uncompressed(peer_public)
    shared = _scalar_mul(d, (point[0], point[1], 1))
    if shared is None:
        raise PushError("ECDH produziu o ponto ao infinito")
    return shared[0].to_bytes(32, "big")


# --------------------------------------------------------------------------
# ECDSA P-256/SHA-256 determinístico (RFC 6979) + verifier
# --------------------------------------------------------------------------

def _bits2int(octets):
    value = int.from_bytes(octets, "big")
    return value >> max(0, len(octets) * 8 - P256.n.bit_length())


def _rfc6979_candidates(digest, priv_int):
    """RFC 6979 §3.2 (HMAC-SHA-256, P-256): `h1` já tem qlen bits, então não
    há truncamento. Gera (k, r) por candidato; o chamador fecha `s`."""
    n = P256.n
    x = priv_int.to_bytes(32, "big")
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + digest, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + digest, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        t = b""
        while len(t) < 32:
            v = hmac.new(k, v, hashlib.sha256).digest()
            t += v
        candidate = _bits2int(t[:32])
        if 1 <= candidate < n:
            point = _scalar_mul(candidate, P256.generator())
            if point is not None:
                yield candidate, point[0] % n
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def ecdsa_sign(message, private_key):
    """ES256: 64 octetos `r||s` (RFC 7518 §3.1 — JWS usa a forma concatenada,
    não DER). Sem normalização de S de propósito: o output é byte a byte o
    vetor da RFC 6979, que é alta-S."""
    d = private_scalar(private_key)
    if isinstance(message, str):
        message = message.encode("ascii")
    digest = hashlib.sha256(message).digest()
    e = _bits2int(digest)
    n = P256.n
    for k, r in _rfc6979_candidates(digest, d):
        if r == 0:
            continue
        s = (pow(k, -1, n) * ((e + r * d) % n)) % n
        if s == 0:
            continue
        return r.to_bytes(32, "big") + s.to_bytes(32, "big")
    raise PushError("ECDSA: impossível produzir assinatura")


def ecdsa_verify(message, signature, public_key):
    """Verifica r||s contra uma chave X9.62. Sem atalho: r/s fora de [1, n-1],
    ponto inválido ou resultado ao infinito são recusados.

    Uma chave pública que não decodifica (fora da curva, truncada, alfabeto
    errado) responde `False`, não levanta: verificador que estoura com entrada
    do atacante é bug — quem escolhe o `k` do header `Authorization` é o
    aplicativo remoto, e RFC 8292 §5 manda a verificação falhar, não o
    servidor cair. Assinatura com tamanho errado continua ValueError (é erro de
    quem chama, não dado de rede)."""
    if isinstance(message, str):
        message = message.encode("ascii")
    if isinstance(signature, str):
        signature = b64u_decode(signature, strict=False)
    if len(signature) != 64:
        raise ValueError("assinatura ES256 precisa de 64 octetos")
    try:
        point = decode_uncompressed(public_key)
    except ValueError:
        return False
    n = P256.n
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    if not (1 <= r < n and 1 <= s < n):
        return False
    e = _bits2int(hashlib.sha256(message).digest())
    w = pow(s, -1, n)
    total = _add(_jac(_scalar_mul((e * w) % n, P256.generator())),
                 _jac(_scalar_mul((r * w) % n, point)))
    affine = _affine(total)
    if affine is None:
        return False
    return affine[0] % n == r
