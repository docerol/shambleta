#!/usr/bin/env python3
"""Suíte da camada assimétrica: `companion/push_p256.py`.

Terceiro degrau da fatia do signer (ver `test_push_common.py`). É aqui que mora
a régua que sustenta a afirmação mais arriscada do pacote — "escrevemos ECDSA
P-256 à mão em stdlib":

  * RFC 6979 A.2.5, octeto por octeto: os dois exemplos publicados (mensagens
    `sample` e `test`) com o MESMO escalar de teste da RFC produzem o MESMO
    r||s. Determinismo não é "rodou sem erro": é byte igual ao texto.
  * validação de ponto (invalid-curve): o vetor clássico contra ECDH.
  * o verificador: quem escolhe o `k` do header `Authorization: vapid` é o
    aplicativo remoto, então chave pública podre responde `False` (RFC 8292 §5
    manda a verificação falhar, não o servidor estourar) e bit virado em `s`
    é recusado.
  * bloco OPCIONAL com `openssl`: verificador externo nos dois sentidos. Sem o
    binário o bloco não roda — `openssl` não é dependência de runtime nem de
    teste.

Rodar: `python3 companion/test_push_p256.py`. Sai !=0 se falhar.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import push_p256 as pp                                          # noqa: E402
import test_push_common as kit                                   # noqa: E402

ok, eq, raises, report = kit.ok, kit.eq, kit.raises, kit.report
und, pem = kit.und, kit.pem

# ===========================================================================
# 3 — ECDSA P-256/SHA-256 determinística: RFC 6979 A.2.5, byte a byte
# ===========================================================================
X69 = int("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721", 16)
PUB69 = pp.encode_uncompressed(pp.scalar_multiply(X69, pp.P256.generator()))
eq(PUB69[1:33], bytes.fromhex(
   "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6"),
   "RFC 6979 A.2.5: Ux do escalar de teste")
eq(PUB69[33:], bytes.fromhex(
   "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299"),
   "RFC 6979 A.2.5: Uy do escalar de teste")
for _msg, _r, _s in [
        ("sample", "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716",
         "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8"),
        ("test", "F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367",
         "019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083")]:
    sig = pp.ecdsa_sign(_msg.encode(), X69)
    eq(sig, bytes.fromhex(_r + _s), "RFC 6979 A.2.5 P-256/SHA-256 '%s': r||s" % _msg)
    ok(pp.ecdsa_verify(_msg.encode(), sig, PUB69),
       "RFC 6979 '%s': verifica contra a chave publicada na própria RFC" % _msg)
    bad = bytearray(sig)
    bad[40] ^= 1
    ok(not pp.ecdsa_verify(_msg.encode(), bytes(bad), PUB69),
       "RFC 6979 '%s': um bit virado em s é recusado" % _msg)
    bad2 = bytearray(sig)
    bad2[0] ^= 1
    ok(not pp.ecdsa_verify(_msg.encode(), bytes(bad2), PUB69),
       "RFC 6979 '%s': um bit virado em r é recusado" % _msg)
    ok(not pp.ecdsa_verify((_msg + "x").encode(), sig, PUB69),
       "RFC 6979 '%s': mensagem diferente é recusada" % _msg)
    ok(not pp.ecdsa_verify(_msg.encode(), sig, PUB69[:-1] + b"\x00"),
       "RFC 6979 '%s': chave pública trocada é recusada" % _msg)
eq(pp.ecdsa_sign(b"mesma coisa", X69), pp.ecdsa_sign(b"mesma coisa", X69),
   "ECDSA determinística (RFC 6979): mesma entrada, mesma assinatura")
raises(ValueError, lambda: pp.ecdsa_sign(b"x", 0),
       "escalar 0, fora de [1,n-1], é recusado antes de assinar")
raises(pp.PushError, lambda: pp.ecdsa_sign(b"x", pp.P256.n),
       "escalar == n é recusado (o atalho `int` não passa ileso)")
ok(pp.ecdsa_verify(b"", pp.ecdsa_sign(b"", X69), PUB69),
   "mensagem vazia assina e verifica (edge case 'U' da RFC 6979)")
ok(pp.ecdsa_verify(b"str em vez de bytes", pp.ecdsa_sign(
    "str em vez de bytes", X69), PUB69),
   "str é aceito como mensagem (codifica ASCII antes de hashar)")

# ===========================================================================
# 3b — o escalar privado nas três formas que o companion recebe
# ===========================================================================
_d_b64, _d_pub = pp.generate_keypair()
_d_int = pp.private_scalar(und(_d_b64))
eq(pp.private_scalar(_d_int), _d_int, "private_scalar é idempotente no int")
eq(pp.private_scalar(und(_d_b64)), _d_int, "private_scalar lê 32 octetos")
eq(pp.private_scalar(_d_b64), _d_int, "private_scalar lê base64url")
eq(pp.public_key_from_private(_d_int), _d_pub,
   "generate_keypair e public_key_from_private concordam (mesmo par)")
for _bad, _label in [(0, "0"), (pp.P256.n, "n"), (pp.P256.n + 1, "n+1"),
                     (pp.P256.p, "p (fora da ordem!)")]:
    raises(pp.MaterialError, lambda v=_bad: pp.private_scalar(v),
           "escalar %s recusado (não é a ordem do grupo)" % _label)
raises(pp.MaterialError, lambda: pp.private_scalar(b"\x01" * 31),
       "escalar com 31 octetos recusado")
raises(pp.MaterialError, lambda: pp.private_scalar("xx!!"),
       "escalar que não é base64url recusado")
# O ponto ao infinito e a chave degenerada não viram material de derivação.
ok(pp.scalar_multiply(_d_int, pp.P256.generator()) != pp.P256.generator(),
   "d*G != G para um escalar aleatório (a multiplicação não é identidade)")
eq(pp.encode_uncompressed(pp.scalar_multiply(1, pp.P256.generator())),
   pp.encode_uncompressed(pp.P256.generator()),
   "1*G == G (aritmética Jacobian -> affine confere na ponta)")

# ===========================================================================
# 4b — ECDH (RFC 8291 §3.3): só o X, e o peer validado ANTES de multiplicar
# ===========================================================================
eq(pp.ecdh(kit.und(kit.ASPRIV), und(kit.UAPUB)),
   und("kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"),
   "RFC 8291 §5: ECDH P-256 (só X) == ecdh_secret publicado")
ok(pp.ecdh(kit.und(kit.UAPRIV), und(kit.ASPUB))
   == pp.ecdh(kit.und(kit.ASPRIV), und(kit.UAPUB)),
   "ECDH é simétrico: as duas pontas derivam o mesmo segredo")
raises(pp.MaterialError, lambda: pp.ecdh(_d_int, b"\x04" + b"\x00" * 64),
       "peer fora da curva é recusado ANTES da multiplicação (invalid-curve)")

# ===========================================================================
# 5 — validação de ponto e de material público (invalid-curve, RFC 8291 §7.3)
# ===========================================================================
raises(pp.MaterialError, lambda: pp.decode_uncompressed(b"\x04" + b"\x00" * 64),
       "ponto fora da curva P-256 é recusado (invalid-curve attack)")
raises(pp.MaterialError, lambda: pp.decode_uncompressed(b"\x02" + b"\x00" * 32),
       "ponto comprimido não é aceito: X9.62 não comprimido é o contrato")
raises(pp.MaterialError, lambda: pp.decode_uncompressed(b"\x04" + b"\x00" * 31),
       "p256dh truncado é recusado")
raises(pp.MaterialError, lambda: pp.decode_uncompressed(
    b"\x05" + und(kit.UAPUB)[1:]),
       "prefixo que não é 0x04 é recusado")
raises(pp.MaterialError, lambda: pp.decode_uncompressed(
    b"\x04" + (pp.P256.p).to_bytes(32, "big") + und(kit.UAPUB)[33:]),
       "coordenada == p (fora do corpo primo) é recusada")
raises(pp.MaterialError, lambda: pp.decode_uncompressed("nao-e-base64!!"),
       "chave pública que não decodifica é recusada pelo parser, não por azar")
ok(pp.decode_uncompressed(und(kit.UAPUB)) == pp.decode_uncompressed(kit.UAPUB),
   "a mesma chave em octetos ou base64url decodifica igual (p256dh do vetor)")
# RFC 8292 §5: quem escolhe o `k` do header é o aplicativo remoto. Verificador
# que ESTOURA com entrada do atacante é bug — tem de responder False.
_sig64 = pp.ecdsa_sign(b"payload", X69)
ok(pp.ecdsa_verify(b"payload", _sig64, b"\x04" + b"\x00" * 64) is False,
   "chave pública fora da curva faz o verifier responder False (não levantar)")
ok(pp.ecdsa_verify(b"payload", _sig64, "lixo!!") is False,
   "chave pública ilegível faz o verifier responder False")
ok(not pp.ecdsa_verify(b"payload", b"\x00" * 64, PUB69),
   "r == 0 e s == 0 são recusados (fora de [1, n-1])")
ok(not pp.ecdsa_verify(b"payload", pp.P256.n.to_bytes(32, "big")
                       + _sig64[32:], PUB69),
   "r == n (fora do grupo) é recusado")
raises(ValueError, lambda: pp.ecdsa_verify(b"payload", b"\x00" * 63, PUB69),
       "assinatura com tamanho errado É erro de quem chama: ValueError")
raises(pp.MaterialError, lambda: pp.ecdsa_sign(b"payload", "nao-e-base64!!"),
       "escalar ilegível recusado antes de hashar")

# ===========================================================================
# 9 — bloco OPCIONAL com o binário `openssl` (verificador externo). Não é
#     dependência de runtime nem de teste: sem o binário nada aqui roda.
# ===========================================================================
_OSSL = shutil.which("openssl")
if not _OSSL:
    ok(True, "openssl ausente: bloco opcional pulado (não é dependência)")
else:
    _tmp = tempfile.mkdtemp(prefix="shambleta-push-p256-")
    os.chmod(_tmp, 0o700)
    try:
        _spki = (b"\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06"
                 b"\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00" + PUB69)
        _pubpem = os.path.join(_tmp, "pub.pem")
        _msg = os.path.join(_tmp, "m.bin")
        _sigbin = os.path.join(_tmp, "sig.der")
        with open(_pubpem, "wb") as _fh:
            _fh.write(pem(_spki, "PUBLIC KEY").encode())
        with open(_msg, "wb") as _fh:
            _fh.write(b"sample")
        with open(_sigbin, "wb") as _fh:
            _fh.write(kit.der_sig(pp.ecdsa_sign(b"sample", X69)))
        _v = subprocess.run([_OSSL, "dgst", "-sha256", "-verify", _pubpem,
                             "-signature", _sigbin, _msg], capture_output=True)
        ok(_v.returncode == 0 and b"Verified OK" in _v.stdout,
           "openssl dgst -verify aceita a nossa ECDSA (RFC 6979 'sample')")
        with open(_sigbin, "wb") as _fh:
            _fh.write(kit.der_sig(b"\x01" + b"\x00" * 63))
        _v2 = subprocess.run([_OSSL, "dgst", "-sha256", "-verify", _pubpem,
                              "-signature", _sigbin, _msg], capture_output=True)
        ok(_v2.returncode != 0, "openssl recusa uma assinatura adulterada")
        # Par derivado AGORA, em memória, só para o openssl ler o nosso PEM:
        # nenhuma chave de deploy passa por aqui e nada é impresso.
        _sec1 = (b"\x30\x77\x02\x01\x01\x04\x20" + _d_int.to_bytes(32, "big")
                 + b"\xa0\x0a\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07"
                 + b"\xa1\x44\x03\x42\x00" + und(_d_pub))
        _pempem = os.path.join(_tmp, "sec1.pem")
        with open(_pempem, "wb") as _fh:
            _fh.write(pem(_sec1, "EC PRIVATE KEY").encode())
        os.chmod(_pempem, 0o600)
        _der = subprocess.run([_OSSL, "ec", "-in", _pempem, "-pubout",
                               "-outform", "DER"], capture_output=True)
        ok(_der.returncode == 0 and _der.stdout == (
            b"\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06"
            b"\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00" + und(_d_pub)),
           "openssl lê o PEM SEC1 e deriva exatamente a mesma SPKI X9.62")
        _osig = os.path.join(_tmp, "ossl.der")
        _s = subprocess.run([_OSSL, "dgst", "-sha256", "-sign", _pempem,
                             "-out", _osig, _msg], capture_output=True)
        ok(_s.returncode == 0, "openssl dgst -sign com a nossa SEC1 PEM")
        if _s.returncode == 0:
            ok(pp.ecdsa_verify(b"sample", kit.raw_sig(
                open(_osig, "rb").read()), _sec1[-65:]),
               "o verifier desta camada aceita a assinatura produzida pelo openssl")
    finally:
        shutil.rmtree(_tmp, ignore_errors=True)

sys.exit(report("PUSH P-256"))
