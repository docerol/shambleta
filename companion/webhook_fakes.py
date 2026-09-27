"""Dublês HTTP dos testes do companion.

Vivem separados de `test_webhook.py` porque o mesmo par (registrar o que saiu /
responder como se o gateway estivesse vivo) aparecia três vezes no arquivo da
suíte, e a suíte tinha estourado o teto anti-god-node do repo
(`scripts/check_god_nodes.sh`). Nada aqui conhece o servidor nem o banco: é só a
cara que `urllib.request.urlopen` tem quando a gente não quer bater na API real.

Regra que importa e que estes dublês precisam continuar honrando: NENHUM deles
abre socket. Se um teste vir a fazer uma chamada real, é o `recorder` abaixo que
vai registrar a URL — e a asserção em cima dela é o que denuncia.
"""

import json


class FakeResponse:
    """O mínimo que `mp_refund_payment`/`mp_create_preference` lêem de uma resp."""

    status = 201

    def __init__(self, body=b"{}"):
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self._body


def recorder(calls, body=b"{}", full=False):
    """Fake que anota o request em `calls` e devolve `body`.

    `full=True` anota o triplete (url, Authorization, JSON do corpo) — é o que
    permite asserir preço do catálogo e bearer token, não só "chamou".
    """

    def _fake(req, timeout=10):
        if full:
            calls.append({"url": getattr(req, "full_url", req),
                          "auth": req.get_header("Authorization"),
                          "body": json.loads(req.data.decode())})
        else:
            calls.append(getattr(req, "full_url", req))
        return FakeResponse(body)

    return _fake


def failure(exc=None):
    """Fake do gateway fora do ar: mesmo tipo de erro que a urllib levanta."""

    def _fake(req, timeout=10):
        raise (exc if exc is not None else IOError("down"))

    return _fake
