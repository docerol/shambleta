#!/usr/bin/env python3
"""Suíte da camada de content coding: `companion/push_aesgcm.py`.

Segundo degrau da fatia do signer (ver `test_push_common.py`): AES-128 (FIPS
197), GCM (NIST SP 800-38D), HKDF (RFC 5869) e o record `aes128gcm` de
RFC 8188/RFC 8291. Nada aqui conhece JWT, HTTP ou nomes de ambiente — é o
corpo que vai no POST, medido octeto por octeto contra os vetores publicados:

  * FIPS-197 §C.1 known-answer do AES-128 (e a S-box DERIVADA em runtime
    conferida contra a Tabela 14 do mesmo texto);
  * SP 800-38D casos 1, 2, 3 e 4 (tag do vazio, tag de um bloco, chave não-nula);
  * RFC 8291 §5 + Appendix A: a cadeia inteira de derivação (ecdh_secret,
    PRK_key, key_info, IKM, PRK, CEK, NONCE), o header de 86 octetos e o corpo
    final de 144 — cifrando E abrindo o vetor publicado;
  * RFC 8188 §3.1: o coding puro (HKDF com IKM direta, sem ECDH) e a recusa do
    corpo com keyid opaco e múltiplos registros;
  * os contratos de material de `encrypt_message` (payload vazio, rs menor que
    o registro, auth curto, keyid == chave do receptor — RFC 8292 §3.2).

Rodar: `python3 companion/test_push_aesgcm.py`. Sai !=0 se falhar.
"""

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import push_aesgcm as pa                                          # noqa: E402
import push_common as pc                                          # noqa: E402
import push_p256 as pp                                            # noqa: E402
import test_push_common as kit                                    # noqa: E402

ok, eq, raises, report = kit.ok, kit.eq, kit.raises, kit.report
und = kit.und

# ===========================================================================
# 2 — AES-128 (FIPS-197) e GCM (SP 800-38D): os primitivos do aes128gcm.
#     Os três nomes com `_` são o interior deste módulo alcançado de propósito:
#     a suíte desta camada é a única que olha para eles.
# ===========================================================================
eq(pa._encrypt_block(pa._expand_key(bytes(range(16))),
   bytes.fromhex("00112233445566778899aabbccddeeff")),
   bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a"),
   "FIPS-197 §C.1: KAT AES-128 (key 000102...0f)")
eq(pa._encrypt_block(pa._expand_key(bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")),
   bytes.fromhex("6bc1bee22e409f96e93d7e117393172a")),
   bytes.fromhex("3ad77bb40d7a3660a89ecaf32466ef97"),
   "FIPS-197 §B.1: o exemplo do AES-128 com chave 2b7e1516... (não só o anexo C.1)")
eq([pa._SBOX[0], pa._SBOX[1], pa._SBOX[0x53], pa._SBOX[0xFF]],
   [0x63, 0x7C, 0xED, 0x16], "FIPS-197 Table 14: S-box derivada (pontas+exemplo)")
eq(pa.gcm_encrypt(b"\x00" * 16, b"\x00" * 12, b""),
   bytes.fromhex("58e2fccefa7e3061367f1d57a4e7455a"),
   "SP 800-38D case 1: tag GCM do vazio (só GHASH, nada cifrado)")
eq(pa.gcm_encrypt(b"\x00" * 16, b"\x00" * 12, b"\x00" * 16),
   bytes.fromhex("0388dace60b6a392f328c2b971b2fe78"
                 "ab6e47d42cec13bdf53a67b21257bddf"),
   "SP 800-38D case 2: ciphertext||tag de um bloco zero (key/IV zero)")
_key, _iv = bytes(range(16)), bytes(range(12))
# Os dois casos publicados acima (SP 800-38D C.1, casos 1 e 2) só cobrem chave e
# IV nulos. Para chave não-nula a suíte NÃO usa número decorado: usa a
# IDENTIDADE de que, com AAD e claro vazios, o GHASH é zero e a tag é exatamente
# E_K(IV||0^31 1) — e o bloco do openssl abaixo confere esse valor contra uma
# implementação independente do AES.
eq(pa.gcm_encrypt(b"\x11" * 16, b"\x00" * 12, b""),
   pa._encrypt_block(pa._expand_key(b"\x11" * 16), b"\x00" * 15 + b"\x01"),
   "GCM: tag do vazio com chave 11..11 == E_K(J0) (GHASH de nada é zero)")
eq(pa.gcm_encrypt(b"\x11" * 16, b"\x00" * 12, b""),
   bytes.fromhex("93c25119975f5efca9f4fb08462e7ec5"),
   "GCM: a mesma tag de chave não-nula, valor fixado (conferido com o openssl "
   "no bloco abaixo)")
ok(pa.gcm_encrypt(b"\x11" * 16, b"\x00" * 12, b"\x00" * 16)[:16]
   != pa.gcm_encrypt(b"\x00" * 16, b"\x00" * 12, b"\x00" * 16)[:16],
   "a chave entra no ciphertext (não é o keystream de chave zero)")
ok(pa.gcm_encrypt(_key, _iv, b"x" * 100)
   != pa.gcm_encrypt(_key, b"\x00" * 12, b"x" * 100),
   "nonce diferente, corpo diferente (o salt de 16 octetos é o que garante isso)")
# A aritmética de GF(2^128) do GCM é de ordem REFLETIDA (SP 800-38D §1): o
# elemento identidade não é o inteiro 1, é o bit de ordem alta. Errar isso é
# justamente o bug clássico, e a régua pega o bug — não o número decorado.
eq(pa._gmul(0x69c4e0d86a7b0430d8cdb78070b4c55a, 1 << 127),
   0x69c4e0d86a7b0430d8cdb78070b4c55a,
   "SP 800-38D Algoritmo 1: X*1 == X com 1 = 0x8000...0 (ordem refletida)")
ok(pa._gmul(0x69c4e0d86a7b0430d8cdb78070b4c55a, 1)
   != 0x69c4e0d86a7b0430d8cdb78070b4c55a,
   "e o inteiro 1 NÃO é a identidade (a armadilha da ordem refletida)")
eq(pa._gmul(0, 0x66234f102e96d920a1cb96bfc2307f3c), 0,
   "SP 800-38D Algoritmo 1: 0*H == 0 (o argumento de que GHASH do vazio é zero)")
_ct = pa.gcm_encrypt(_key, _iv, b"x" * 100, aad=b"adicional")
eq(pa.gcm_decrypt(_key, _iv, _ct, aad=b"adicional"), b"x" * 100,
   "GCM abre o que cifrou (com AAD)")
raises(pc.PushError, lambda: pa.gcm_decrypt(_key, _iv, _ct, aad=b"outro"),
       "GCM recusa AAD diferente (autenticidade)")
_tampered = bytearray(_ct)
_tampered[10] ^= 0x80
raises(pc.PushError, lambda: pa.gcm_decrypt(_key, _iv, bytes(_tampered),
                                            aad=b"adicional"),
       "GCM recusa ciphertext adulterado")
_flip = bytearray(_ct)
_flip[-1] ^= 0x01
raises(pc.PushError, lambda: pa.gcm_decrypt(_key, _iv, bytes(_flip),
                                            aad=b"adicional"),
       "GCM recusa um bit virado na TAG (nada é devolvido antes de conferir)")
eq(len(pa.gcm_encrypt(_key, _iv, b"")), pc.TAG_LEN,
   "GCM do vazio devolve só a tag (16 octetos)")
raises(ValueError, lambda: pa.gcm_encrypt(_key, b"\x00" * 8, b"x"),
       "IV de 8 octetos é recusado: o módulo só conhece o IV de 12 que Web Push usa")

# ===========================================================================
# 4 — RFC 8291 §5 + Appendix A: a derivação inteira, octeto por octeto
# ===========================================================================
as_priv = pp.private_scalar(und(kit.ASPRIV))
ua_priv = pp.private_scalar(und(kit.UAPRIV))
eq(pp.encode_uncompressed(pp.scalar_multiply(as_priv, pp.P256.generator())),
   und(kit.ASPUB), "RFC 8291: as_private deriva exatamente a as_public do vetor")
eq(pp.encode_uncompressed(pp.scalar_multiply(ua_priv, pp.P256.generator())),
   und(kit.UAPUB), "RFC 8291: ua_private deriva exatamente a ua_public do vetor")
ECDH_SECRET = und("kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs")
cek, nonce, ikm, prk, prk_key = pa.push_key_schedule(
    und(kit.UAPUB), und(kit.ASPUB), und(kit.AUTH), ECDH_SECRET, und(kit.SALT))
eq(prk_key, und("Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k"),
   "RFC 8291 §3.4: PRK_key = HMAC-SHA-256(auth_secret, ecdh_secret)")
eq(b"WebPush: info\x00" + und(kit.UAPUB) + und(kit.ASPUB), und(
   "V2ViUHVzaDogaW5mbwAEJXGyvs3942BVGq8e0PTNNmwRzr5VX4m8t7GGpTM5FzFo7OLr4Bh"
   "Ze9MEebhuPI-OztV3ylkYfpJGmQ22ggCLDgT-M_SrDepxkU21WCP3O1SUj0EwbZIHMtu5pZp"
   "TKGSCIA5Zent7wmC6HCJ5mFgJkuk5cwAvMBKiiujwa7t45ewP"),
   "RFC 8291 §3.4: key_info = 'WebPush: info'||0||ua_public||as_public")
eq(ikm, und("S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"), "RFC 8291: IKM")
eq(prk, und("09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc"), "RFC 8291: PRK")
eq(cek, und("oIhVW04MRdy2XN9CiKLxTg"), "RFC 8291: CEK (16 octetos = AES-128)")
eq(nonce, und("4h_95klXJ5E_qnoN"), "RFC 8291: NONCE (12 octetos)")
_rfc_body = pa.encrypt_message(kit.UAPUB, kit.AUTH, und(kit.PLAINTEXT),
                               as_priv, salt=und(kit.SALT))
eq(_rfc_body, und(kit.BODY), "RFC 8291 §5: corpo aes128gcm completo, 144 octetos")
eq(len(_rfc_body), 144, "RFC 8291 §5: o comprimento do corpo publicado")
eq(_rfc_body[:86], und(kit.HEADER86),
   "RFC 8291 Appendix A: header de 86 octetos")
eq(_rfc_body[86:], und(kit.CIPHER),
   "RFC 8291 Appendix A: ciphertext||tag (58 octetos)")
eq(und("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24C"),
   und(kit.PLAINTEXT) + b"\x02", "RFC 8291 §4: padding delimiter 0x02 no fim")
eq(pa.decrypt_message(und(kit.BODY), und(kit.UAPRIV), kit.AUTH),
   und(kit.PLAINTEXT), "o lado do receptor abre o corpo PUBLICADO da RFC 8291")
ok(_rfc_body[:16] == und(kit.SALT)
   and int.from_bytes(_rfc_body[16:20], "big") == 4096
   and _rfc_body[20] == 65 and _rfc_body[21] == 0x04,
   "header decodifica: salt(16) || rs(4 BE)=4096 || idlen(1)=65 || keyid X9.62")
eq(pc.HEADER_LEN, 86, "o comprimento do header é a soma das partes (pc.HEADER_LEN)")
# O salt pode vir como texto (é como um chamador o guardaria em config): os
# dois caminhos produzem o MESMO corpo, o que também prova que não há
# aleatoriedade escondida dentro de `encrypt_message` além do salt/par efêmero.
eq(pa.encrypt_message(kit.UAPUB, kit.AUTH, und(kit.PLAINTEXT), as_priv,
                      salt=kit.SALT), _rfc_body,
   "salt em base64url e salt em octetos produzem corpos idênticos")
_a = pa.encrypt_message(kit.UAPUB, kit.AUTH, b"mesmo claro", as_priv)
_b = pa.encrypt_message(kit.UAPUB, kit.AUTH, b"mesmo claro", as_priv)
ok(_a != _b and _a[:16] != _b[:16],
   "sem salt fixo cada chamada é um corpo novo (salt e par efêmero aleatórios)")
ok(pa.decrypt_message(_b, und(kit.UAPRIV), kit.AUTH) == b"mesmo claro",
   "e o receptor abre qualquer um dos dois")

# ===========================================================================
# 4b — RFC 8188 §3.1: o coding puro, com a cadeia de HKDF publicada no próprio
#      texto (IKM direta, sem ECDH). Prova extract/expand e o enquadramento do
#      header longe do caminho WebPush.
# ===========================================================================
_I8188 = "yqdlZ-tYemfogSmv7Ws5PQ"
_S8188 = "I1BsxtFttlv3u_Oo94xnmw"
_BODY8188 = ("I1BsxtFttlv3u_Oo94xnmwAAEAAA-NAVub2qFgBEuQKRapoZu-IxkIva3MEB1PD-"
             "ly8Thjg")
_p8188 = pa.hkdf_extract(und(_S8188), und(_I8188))
_eq8188 = pa.hkdf_expand(_p8188, b"Content-Encoding: aes128gcm\x00", 16)
_n8188 = pa.hkdf_expand(_p8188, b"Content-Encoding: nonce\x00", 12)
eq(pc.b64u_encode(_p8188), "zyeH5phsIsgUyd4oiSEIy35x-gIi4aM7y0hCF8mwn9g",
   "RFC 8188 §3.1: PRK = HKDF-Extract(salt, IKM) publicado")
eq(pc.b64u_encode(_eq8188), "_wniytB-ofscZDh4tbSjHw",
   "RFC 8188 §3.1: CEK com o info 'Content-Encoding: aes128gcm\\0'")
eq(pc.b64u_encode(_n8188), "Bcs8gkIRKLI8GeI8",
   "RFC 8188 §3.1: NONCE com o info 'Content-Encoding: nonce\\0'")
eq(und("SSBhbSB0aGUgd2FscnVzAg"), b"I am the walrus" + b"\x02",
   "RFC 8188 §3.1: 'unencrypted data' publicado = texto + delimiter 0x02")
eq(pc.b64u_encode(und(_S8188) + (4096).to_bytes(4, "big") + b"\x00"
                  + pa.gcm_encrypt(_eq8188, _n8188, b"I am the walrus" + b"\x02")),
   _BODY8188,
   "RFC 8188 §3.1: corpo completo octeto por octeto (53; o texto da RFC diz "
   "54 — o que confere é a string publicada)")
raises(pc.PushError, lambda: pa.decrypt_message(
    pc.b64u_decode("uNCkWiNYzKTnBN9ji3-qWAAAABkCYTHOG8chz_gnvgOqdGYovxyjuqRyJF"
                   "jEDyoF1Fvkj6hQPdPHI51OEUKEpgz3SsLWIqS_uA", strict=False),
    und(kit.UAPRIV), kit.AUTH),
   "RFC 8188 §3.2 (keyid opaco 'a1', rs=25, múltiplos registros) é recusado: "
   "este decoder só abre subscription de push (keyid X9.62 de 65, 1 registro)")
# HKDF (RFC 5869) já está medido OCTETO POR OCTETO pelas duas cadeias
# publicadas acima (o PRK/CEK/NONCE de RFC 8188 §3.1 e os seis intermediários de
# RFC 8291 §3.4, que usam extract e expand). O bloco abaixo NÃO é um vetor
# copiado de memória: é conferência contra uma implementação independente, o
# `openssl kdf` — binário opcional, e sem ele o bloco não roda.
_OSSL = shutil.which("openssl")
if not _OSSL:
    ok(True, "openssl ausente: cross-check de HKDF pulado (não é dependência)")
else:
    _salt, _ikm, _info = bytes.fromhex("000102030405060708090a0b0c"), \
        bytes.fromhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), \
        bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
    _mine = pa.hkdf_expand(pa.hkdf_extract(_salt, _ikm), _info, 42)
    _r = subprocess.run([_OSSL, "kdf", "-keylen", "42",
                         "-kdfopt", "digest:SHA256",
                         "-kdfopt", "hexkey:" + _ikm.hex(),
                         "-kdfopt", "hexsalt:" + _salt.hex(),
                         "-kdfopt", "hexinfo:" + _info.hex(),
                         "-binary", "HKDF"], capture_output=True)
    ok(_r.returncode == 0, "openssl kdf HKDF rodou (cross-check de implementações)")
    if _r.returncode == 0:
        eq(_mine, _r.stdout,
           "HKDF-Extract+Expand coincide com o openssl nos 42 octetos")
    # O AES por conta própria, com chave NÃO-nula: `openssl enc -aes-128-ecb` é
    # uma implementação independente do mesmo bloco, e é ela que sustenta o
    # valor da tag de chave 11..11 medido lá em cima.
    _blk = b"\x00" * 15 + b"\x01"
    _r3 = subprocess.run([_OSSL, "enc", "-aes-128-ecb", "-nopad", "-K",
                          "11111111111111111111111111111111"],
                         input=_blk, capture_output=True)
    ok(_r3.returncode == 0 and pa._encrypt_block(
        pa._expand_key(b"\x11" * 16), _blk) == _r3.stdout,
       "AES-128 do módulo == openssl ECB bloco a bloco (chave 11..11)")
    # O GCM em si NÃO tem cross-check com o openssl: `enc` recusa cifras AEAD
    # ("Multiple cipher or unknown options"), e isso está dito em vez de virar
    # régua silenciosa. O que ancora o GCM aqui é (a) os dois casos publicados de
    # SP 800-38D, (b) o corpo de 144 octetos da RFC 8291 §5 — uma conta GCM real,
    # com GHASH+CTR+tag, cujo valor está no texto da RFC, e (c) a identidade
    # tag=vazio == E_K(J0) conferida contra o AES do openssl acima.

# ===========================================================================
# 5b — contratos de material em `encrypt_message`: o que um sender DEVE recusar
#      antes de gastar um POST (e antes de assinar qualquer coisa).
# ===========================================================================
raises(pc.PushError, lambda: pa.encrypt_message(
    kit.UAPUB, kit.AUTH, b"oi", as_priv, salt=und(kit.SALT), record_size=8),
   "payload maior que o rs declarado é recusado")
raises(pc.PushError, lambda: pa.encrypt_message(
    kit.ASPUB, kit.AUTH, b"oi", as_priv),
   "RFC 8292 §3.2: keyid == chave do receptor é recusado")
raises(pc.PushError, lambda: pa.encrypt_message(
    kit.UAPUB, "A", b"oi", as_priv),
   "keys.auth curto demais é recusado")
raises(pc.PushError, lambda: pa.encrypt_message(
    kit.UAPUB, kit.AUTH, b"", as_priv),
   "payload vazio é recusado")
raises(pc.PushError, lambda: pa.encrypt_message(
    kit.UAPUB, kit.AUTH, b"z" * (pc.MAX_PAYLOAD + 1), as_priv),
   "payload acima dos %d octetos que um push service DEVE aceitar"
   % pc.MAX_PAYLOAD)
ok(len(pa.encrypt_message(kit.UAPUB, kit.AUTH,
                          b"z" * pc.MAX_PAYLOAD, as_priv))
   == pc.HEADER_LEN + pc.MAX_PAYLOAD + 1 + 16,
   "o teto MAX_PAYLOAD é atingível exatamente (header+claro+delimiter+tag)")
raises(pc.MaterialError, lambda: pa.encrypt_message(
    kit.UAPUB, kit.AUTH, b"oi", as_priv, salt=b"\x00" * 8),
   "salt com tamanho errado é recusado (16 octetos, RFC 8188 §3.1)")
raises(pc.MaterialError, lambda: pa.encrypt_message(
    b"\x04" + b"\x00" * 64, kit.AUTH, b"oi", as_priv),
   "p256dh fora da curva nunca vira derivação de chave")
raises(pc.MaterialError, lambda: pa.encrypt_message(
    kit.UAPUB, kit.AUTH, b"oi", 0),
   "escalar efêmero fora de [1,n-1] é recusado")
raises(pc.PushError, lambda: pa.decrypt_message(b"\x00" * 110,
                                                und(kit.UAPRIV), kit.AUTH),
   "corpo aes128gcm com keyid que não é X9.62 de 65 é recusado")
raises(pc.PushError, lambda: pa.decrypt_message(
    _rfc_body[:-1] + b"\x00", und(kit.UAPRIV), kit.AUTH),
   "tag adulterada no corpo: o receptor não abre (autenticidade ponta a ponta)")

sys.exit(report("PUSH AES128GCM"))
