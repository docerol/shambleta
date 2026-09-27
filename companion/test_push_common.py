#!/usr/bin/env python3
"""Kit das suítes do caminho de push + as réguas de base64url (RFC 4648 §5).

`companion/push_vapid.py` media 944 linhas contra o teto anti-god-node de 800 e
foi fatiado pelas costuras que já existiam no arquivo:

    push_common.py   erros, nomes de config, base64url
    push_p256.py     P-256, ECDH, ECDSA determinística (RFC 6979)
    push_aesgcm.py   AES-128-GCM, HKDF e o record `aes128gcm` (RFC 8188/8291)
    push_vapid.py    chave, assertion VAPID (RFC 8292) e o POST HTTP (RFC 8030)

Os testes seguiram a MESMA divisão — um arquivo de teste de 807 linhas é o
mesmo god-node com nome de teste:

    test_push_common.py   base64url + este kit compartilhado
    test_push_p256.py     RFC 6979 A.2.5, validação de ponto, openssl (opcional)
    test_push_aesgcm.py   FIPS-197, SP 800-38D, RFC 8188 §3.1, RFC 8291 §5
    test_push_vapid.py    chave, RFC 8292 §2.4, build_request, server.py

Cada um é autônomo (`python3 companion/test_push_p256.py`); os três de cima
importam este arquivo pelo kit: `ok`/`eq`/`raises`, o instantâneo de ambiente
(`no_keys`/`restore_env`), o fechamento com marcador (`report`) e os VETORES
PUBLICADOS das RFCs, que são mais de um teste cada.

Sem pytest de propósito: o companion é stdlib-only por contrato e o CI não
instala nada. Sai !=0 se falhar.

Segredo: nada aqui gera chave de deploy. Os escalares privados que aparecem são
os EXEMPLOS IMPRESSOS no texto das próprias RFCs (públicos por definição, e o
único meio de conferir a derivação octeto por octeto) — e nenhum deles é
impresso por `eq()`: as réguas comparam material público (chave pública,
ciphertext, header) ou usam `ok()`, que não ecoa valor.
"""

import base64
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import push_common as pc                                          # noqa: E402

# O nome da variável que escolhe o sender é de `server.py`; repetido aqui para
# que o kit não precise importar o monolito (só `test_push_vapid.py` importa).
PUSH_SENDER_ENV = "SHAMBLETA_PUSH_SENDER"

FAILS = []
CHECKS = 0

# Instantâneo do ambiente REAL antes de qualquer mutação: `restore_env()` devolve
# exatamente isto no fim. Sem isso, um deploy com chave no ambiente do
# desenvolvedor faria estas suítes tentarem uma entrega de verdade — e as
# réguas fail-closed, que dependem de NÃO haver chave, mentiriam.
_ENV_KEYS = (pc.VAPID_PRIVATE_ENV, pc.VAPID_PUBLIC_ENV, pc.VAPID_SUBJECT_ENV,
             pc.PUSH_TTL_ENV, pc.PUSH_TIMEOUT_ENV, pc.VAPID_TOKEN_TTL_ENV,
             PUSH_SENDER_ENV)
_SAVED_ENV = {k: os.environ.get(k) for k in _ENV_KEYS}


def restore_env():
    for k, v in _SAVED_ENV.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


def no_keys():
    """Deixa o ambiente no estado de um deploy SEM segredo (fail-closed)."""
    for k in _ENV_KEYS:
        os.environ.pop(k, None)


no_keys()


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def eq(got, want, label):
    """Comparação byte a byte com o hex dos dois lados no FAIL. Nenhum valor
    comparado aqui é segredo: é vetor publicado, chave pública ou ciphertext."""
    same = got == want
    if not same:
        g = got.hex() if isinstance(got, (bytes, bytearray)) else repr(got)
        w = want.hex() if isinstance(want, (bytes, bytearray)) else repr(want)
        print("        got =%s\n        want=%s" % (g[:200], w[:200]))
    ok(same, label)


def raises(exc, fn, label):
    try:
        fn()
        ok(False, label + " (no raise)")
    except exc:
        ok(True, label)
    except Exception as e:                                      # noqa: BLE001
        ok(False, "%s (levantou %s: %s)" % (label, type(e).__name__, e))


def report(marker):
    """Fecha a suíte com a linha que os gates lêem (§24-8: o número de falhas é
    lido DO marcador, não do exit code). Não imprime segredo: os rótulos das
    réguas nomeiam o problema, nunca o valor."""
    restore_env()
    if FAILS:
        print("== %s: %d failures ==" % (marker, len(FAILS)))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("== %s: %d checks, %d failures ==" % (marker, CHECKS, len(FAILS)))
    return 0


# ---------------------------------------------------------------------------
# leitura de vetor publicado
# ---------------------------------------------------------------------------

def norm(s):
    """Junta as quebras de linha do texto da RFC e joga fora o que não é
    base64url — os vetores são quebrados no meio para caber na coluna."""
    return re.sub(r"[^A-Za-z0-9_\-]", "", s)


def und(s):
    """Octetos de um valor base64url publicado (tolerante: é leitura de vetor,
    não entrada de atacante)."""
    return pc.b64u_decode(norm(s), strict=False)


def der_int(n):
    raw = n.to_bytes(max(1, (n.bit_length() + 7) // 8), "big")
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return b"\x02" + bytes([len(raw)]) + raw


def der_sig(raw):
    """r||s (IEEE P1363, o formato `sig` da RFC 8292) -> DER ECDSA-Sig-Value,
    único formato que o `openssl dgst -verify` aceita."""
    body = (der_int(int.from_bytes(raw[:32], "big"))
            + der_int(int.from_bytes(raw[32:], "big")))
    return b"\x30" + bytes([len(body)]) + body


def raw_sig(der):
    """DER ECDSA-Sig-Value -> r||s (o caminho inverso, p/ o check openssl->nos)."""
    i = der.find(b"\x30") + 2
    rlen = der[i + 1]
    r = int.from_bytes(der[i + 2:i + 2 + rlen], "big")
    j = i + 2 + rlen
    slen = der[j + 1]
    s = int.from_bytes(der[j + 2:j + 2 + slen], "big")
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def pem(der, kind):
    return ("-----BEGIN %s-----\n%s-----END %s-----\n"
            % (kind, base64.encodebytes(der).decode(), kind))


# ---------------------------------------------------------------------------
# os vetores publicados — RFC 8291 §5 / Appendix A (a cadeia inteira)
# ---------------------------------------------------------------------------

UAPRIV = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
UAPUB = ("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPj"
         "s7Vd8pZGH6SRpkNtoIAiw4")
ASPRIV = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
ASPUB = ("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6"
         "TlzAC8wEqKK6PBru3jl7A8")
SALT = "DGv6ra1nlYgDCS1FRnbzlw"
AUTH = "BTBZMqHH6r4Tts7J_aSIgg"
PLAINTEXT = "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"
HEADER86 = ("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27"
            "mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
CIPHER = ("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEs"
          "bI_0LpXMuGvnzQ")
BODY = ("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlml"
        "MoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mq"
        "gkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")

# ---------------------------------------------------------------------------
# 1 — base64url (RFC 4648 §5 / RFC 7515 §2): o parser tem de ser tão rígido
#     quanto o dos provedores, senão "aceita qualquer coisa" — e é ele que lê
#     `p256dh`, `auth` e o `k` do header que o aplicativo remoto escolhe.
# ---------------------------------------------------------------------------


def check_base64url():
    eq(pc.b64u_encode(b"\x00\x01\xff"), "AAH_",
       "b64u sem padding (RFC 4648 §5)")
    ok(pc.b64u_decode("AAH_") == b"\x00\x01\xff", "b64u decodifica sem padding")
    # O padding é ACEITO quando tem a forma da RFC 4648: 1 octeto -> "AA==",
    # 2 octetos -> "AAE=". Isto é o que um provedor que manda o quantum cheio
    # produz, e recusá-lo seria recusar entrega válida.
    eq(pc.b64u_decode("AA=="), b"\x00",
       "padding com fundo de verdade é aceito (1 octeto -> 'AA==')")
    eq(pc.b64u_decode("AAE="), b"\x00\x01",
       "padding com fundo de verdade é aceito (2 octetos -> 'AAE=')")
    raises(ValueError, lambda: pc.b64u_decode("aa++"),
           "b64u recusa o alfabeto padrão (+/): não é url-safe")
    raises(ValueError, lambda: pc.b64u_decode("AAAA="),
           "b64u recusa padding mal posicionado (quantum cheio + '=')")
    raises(ValueError, lambda: pc.b64u_decode("AAH_="),
           "b64u recusa padding sobre o quantum cheio ('AAH_' já é 3 octetos)")
    raises(ValueError, lambda: pc.b64u_decode("A"),
           "b64u recusa comprimento impossível")
    raises(ValueError, lambda: pc.b64u_decode("BB"),
           "strict: bit-cauda não-canônica é recusada (chave pública com lixo nos "
           "bits baixos é vetor contra parser ingênuo)")
    eq(pc.b64u_decode("BB", strict=False), b"\x04",
       "strict=False mantém o comportamento tolerante usado dentro do módulo")
    # O round-trip é a régua que impede o parser de virar um "aceita tudo":
    # todo vetor publicado das RFCs precisa sobreviver a decode -> encode.
    ok(pc.b64u_encode(und(UAPUB)) == norm(UAPUB),
       "round-trip do vetor publicado (p256dh da RFC 8291) é estável")
    ok(pc.b64u_encode(und(AUTH)) == norm(AUTH),
       "round-trip do auth secreto (16 octetos) é estável")
    raises(pc.MaterialError, lambda: pc.b64u_decode("\x00\x01"),
           "bytes não-ascii no alfabeto são recusados, não decodificados")
    ok(issubclass(pc.MaterialError, pc.PushError)
       and issubclass(pc.MaterialError, ValueError),
       "MaterialError é PushError E ValueError ao mesmo tempo (as duas leituras "
       "do mesmo dado ruim: a fila classifica, o verifier devolve False)")


if __name__ == "__main__":
    check_base64url()
    sys.exit(report("PUSH COMMON"))
