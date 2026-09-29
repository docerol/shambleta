#!/usr/bin/env python3
"""Suíte da identidade de temporada no checkout — `server.season_offer_status`.

O gate de temporada já existia e respondia a uma pergunta: *há* temporada ativa?
Esta suíte mede a segunda, que é a que custava dinheiro: **de que temporada é
este passe?** Com `pass.s1` e `pass.s2` no mesmo catálogo, a resposta antiga era
"qualquer um enquanto houver linha ativa" — ou seja, na abertura da S2 o
companion continuava cobrando R$ 24,90 pelo passe da temporada encerrada, e o
grant escrevia premium na temporada nova. O jogador pagava por uma promessa que
o jogo não podia entregar, e nada em lugar nenhum gritava.

Os onze blocos abaixo são os onze blocos numerados do arquivo, na mesma ordem:

  1. A TABELA VEM DA MIGRATION REAL (`data/conf/migrations/018_guild_season_ah.sql`),
     aplicada com `executescript` do arquivo. Uma cópia colada aqui aprovaria uma
     régua sobre um `season` que não existe no banco de produção — é a mesma
     regra que a suíte de retenção aplica à view 045.
  2. SKU NÃO SAZONAL NÃO É TOCADO pelo gate, nem com a linha de temporada podre:
     o early-return é por `kind`, e gem/VIP/doação/bundle não podem ser barrados
     por um problema que não é deles.
  3. LEGADO NÃO MUDA DE MERCADORIA: linha sem a chave (toda temporada aberta antes
     do OPS-2, e todo `INSERT` cru no SQL) vende o passe do catálogo
     (`DEFAULT_PREMIUM_SKU`) e NÃO passa a vender a sucessora.
  4. A LINHA MANDA: `rules_frozen.premium_sku` é o que se vende. A sucessora no ar
     recusa o passe da anterior com `season_mismatch` (e devolve o SKU esperado,
     para o log dizer qual temporada foi lida), inclusive no deluxe. É aqui que
     mora o CONTROLE NEGATIVO, no estilo da sombra de retenção: a régua ANTIGA
     ("qualquer passe com linha ativa") é recalculada sobre as MESMAS linhas e
     comparada com o veredito novo — reimplantá-la deixa de ser troca silenciosa
     e vira gate vermelho. O SKU que a linha promete mas o catálogo não tem também
     é medido aqui: o gate responde pela temporada, quem barra o SKU é a porta de
     cima.
  5. CONGELADO ILEGÍVEL → `season_rules_unreadable`, nunca default. Vale também
     para a chave PRESENTE com `null` / número / texto vazio, onde um `str()`
     solto inventaria um SKU ("<null>" de um lado, "None" do outro).
  6. UMA LINHA SÓ É A VERDADE: com duas linhas ativas, a de maior `season_id`
     decide — inclusive quando a linha mais nova é legada e a antiga congelou um
     SKU próprio.
  7. FECHADO NA FALTA: sem tabela, sem linha ativa, com a janela vencida
     (`ends_at` não-estrito) ou `status != 'active'` → nada vendável. O status é
     medido com a janela ABERTA, senão os dois motivos se confundem.
  8. O CONTRATO ENTRE AS DUAS LINGUAGENS, por régua textual sobre os fontes
     (python não levanta o servidor, e `SeasonConfig.gd` não é importável daqui):
     o default das duas camadas é o MESMO literal, é o passe da temporada de
     rotação do calendário embarcado, todo SKU declarado no calendário é cobrável,
     `RulesJSONForEntry` continua escrevendo a chave que o companion lê, e o jogo
     escolhe a linha pela MESMA ordem (`status='active'`, `season_id DESC`) — com
     uma assimetria declarada: só o companion fecha a VENDA na janela vencida,
     porque cobrar temporada vencida é dano ao jogador e entregar para quem já
     pagou não é.
  9. A RECUSA ACONTECE ANTES DO DINHEIRO, nas três portas de cobrança
     (`_checkout_intent`, `_checkout_preference`, `_checkout_simulate`): a porta
     do catálogo vem antes do gate, o motivo do gate é o que o cliente recebe, e
     nenhum 200 de compra nova é montado antes de o gate ler a temporada (em
     sandbox, o único 200 antecipado é o replay de um payment já registrado).
  10. O CATÁLOGO QUE EMBARCA (`data/conf/paid_catalog.json`), não só o fallback:
     as rotas usam `self.server.catalog`, e é contra ele que o veredito é refeito.
  11. O CORPO DE `GET /catalog` (`server.public_catalog`): a temporada entra como
     MARCAÇÃO no item, nunca como filtro — a página de preço mostra o que existe,
     quem obedece à marca é o botão. A marca é a do MESMO gate que o checkout
     aplica (refeita SKU a SKU contra o catálogo que embarca), banco inacessível
     marca `store_unavailable` sem derrubar a página, e nem o preço nem a contagem
     mudam com a temporada. Fecha com a régua de CÓPIA EMBARCADA: nenhum literal de
     temporada (`pass.sN`, `(S1)`) em arquivo que a imagem serve, com a lista dos
     arquivos derivados do `deploy/web/Dockerfile` e não escrita à mão aqui.

O QUE ISTO NÃO PROVA, dito sem rodeio: nada sobre o provedor de pagamento — a
rota não é levantada aqui; as réguas 8 e 9 são TEXTUAIS sobre
`companion/server.py`, `sources/season/SeasonConfig.gd`, `sources/economy/SeasonService.gd`
e `data/conf/seasons.json`, então pegam reescrita do gate e poda de ramo, não o
comportamento HTTP de fim a fim (isso é `companion/test_webhook.py`). A
concordância python ⇄ GDScript sobre a MESMA linha congelada é medida de um lado
só aqui; do outro lado é `tests/pass_season_alignment_test.gd`, que roda o
`PremiumSkuOfRow` de verdade. E o consumo do grant na temporada certa continua
medido no jogo, não aqui.

Do bloco 11, duas assimetrias declaradas: o `/catalog` levantado de verdade
(HTTP, corpo, SKUs de comentário fora do display) é `companion/test_security.py`
D5/D6, e a régua de cópia mede só o que a IMAGEM serve — `landing_new/` é a loja
em rascunho, excluída pelos quatro `.dockerignore`, e carrega `pass.s1`
fixo no botão deliberadamente fora desta régua até que alguém o embarque (aí o
Dockerfile passa a listá-lo e a check fica vermelha sozinha).

Rodar: `python3 companion/test_season_offer.py`. Sai !=0 se falhar. Sem pytest:
o companion é stdlib-only por contrato.
"""

import json
import os
import re
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import server                                              # noqa: E402

DAY = 86400
CHECKS = 0
FAILS = []


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def report(marker):
    """Fecha com a linha que os gates lêem (§24-8: o número de falhas vem DO
    marcador)."""
    if FAILS:
        print("== %s: %d failures ==" % (marker, len(FAILS)))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("== %s: %d checks, 0 failures ==" % (marker, CHECKS))
    return 0


MIG018 = os.path.join(ROOT, "data", "conf", "migrations", "018_guild_season_ah.sql")
SEASONS = os.path.join(ROOT, "data", "conf", "seasons.json")
PAID = os.path.join(ROOT, "data", "conf", "paid_catalog.json")
SEASONCFG = os.path.join(ROOT, "sources", "season", "SeasonConfig.gd")
SEASONSVC = os.path.join(ROOT, "sources", "economy", "SeasonService.gd")

CAT = server.DEFAULT_CATALOG
NOW = int(time.time())


def read(path_):
    with open(path_, encoding="utf-8") as fh:
        return fh.read()


def season_db():
    """Banco com a tabela `season` criada pela migration REAL. Retorna
    (con, path) para o chamador fechar e apagar."""
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    con = sqlite3.connect(path)
    con.executescript(read(MIG018))
    return con, path


def add(con, season_id, rules="{}", status="active", ends_at=None):
    con.execute("INSERT INTO season (season_id, starts_at, ends_at, rules_frozen,"
                " status) VALUES (?, ?, ?, ?, ?);",
                (season_id, NOW - 3600,
                 NOW + 30 * DAY if ends_at is None else ends_at, rules, status))


def clear(con):
    con.execute("DELETE FROM season;")


def gate(con, sku, now=None):
    return server.season_offer_status(con, CAT, sku, now)


# A régua que existia antes: "qualquer passe enquanto houver linha ativa". Ela é
# recalculada sobre a MESMA linha, para que a diferença entre as duas seja um
# número impresso e não uma nota de release.
def old_rule(con, sku, now=None):
    if (CAT.get(sku) or {}).get("kind") != "pass_premium":
        return True
    at = NOW if now is None else now
    try:
        row = con.execute("SELECT 1 FROM season WHERE status = 'active'"
                          " AND ends_at > ? LIMIT 1;", (at,)).fetchone()
    except sqlite3.Error:
        row = None
    return row is not None


# ---------------------------------------------------------------------------
# 1. A tabela vem do arquivo de migration, não desta suíte
# ---------------------------------------------------------------------------
con, path = season_db()
cols = set(r[1] for r in con.execute("PRAGMA table_info(season);").fetchall())
ok({"season_id", "starts_at", "ends_at", "rules_frozen", "status"} <= cols,
   "a migration 018 cria o `season` com as cinco colunas que o gate lê")
ok(gate(con, "pass.s1")["reason"] == "no_active_season",
   "tabela recém-criada e vazia: nada vendável, e o motivo é a temporada")
add(con, 1)
row = con.execute("SELECT rules_frozen, status FROM season WHERE season_id = 1;").fetchone()
ok(row[0] == "{}" and row[1] == "active",
   "linha inserida sem os dois campos chega como legado ativo: `'{}'`/`'active'` são os defaults do DDL")

# ---------------------------------------------------------------------------
# 2. SKU não sazonal não passa pelo gate — nem com a temporada podre
# ---------------------------------------------------------------------------
add(con, 2, rules='{"premium_sku": ]')
for sku in ["vip.1mo", "gems.550", "donate.support", "starter.pack"]:
    got = gate(con, sku)
    ok(got["eligible"] and got["reason"] == "not_season_bound" and got["season_id"] == 0,
       "%s não é tocado pelo gate (linha podre incluída)" % sku)
ok(not gate(con, "pass.s1")["eligible"],
   "e o mesmo banco podre RECUSA o passe: o gate lê a linha ativa mais nova")

# ---------------------------------------------------------------------------
# 3. Linha legada vende o default das duas camadas, e nada além dele
# ---------------------------------------------------------------------------
for legacy in ["{}", "", "   "]:
    clear(con)
    add(con, 10, rules=legacy)
    got = gate(con, "pass.s1")
    ok(got["eligible"] and got["reason"] == "ok" and got["season_id"] == 10,
       "legado (%r): o passe do catálogo é vendável" % legacy)
    off = gate(con, "pass.s2")
    ok(not off["eligible"] and off["reason"] == "season_mismatch"
       and off["premium_sku"] == server.DEFAULT_PREMIUM_SKU,
       "legado (%r): a sucessora NÃO entra pela janela do default" % legacy)
    ok(gate(con, "pass.s1.deluxe")["eligible"],
       "legado (%r): o deluxe do passe da temporada é vendável" % legacy)
    ok(gate(con, "pass.s2.deluxe")["reason"] == "not_season_bound",
       "legado (%r): o gate não inventa regra para SKU que o catálogo não tem" % legacy)
    ok(gate(con, "pass.s1.deluxe")["season_id"] == 10,
       "legado (%r): e o deluxe responde pela mesma linha da temporada" % legacy)

# ---------------------------------------------------------------------------
# 4. A linha congelada manda: a temporada nova no ar não vende o passe da antiga
# ---------------------------------------------------------------------------
clear(con)
add(con, 41, rules='{"config_id": "s2", "premium_sku": "pass.s2"}')
live = gate(con, "pass.s2")
ok(live["eligible"] and live["season_id"] == 41 and live["premium_sku"] == "pass.s2",
   "S2 no ar vende o passe da S2, com a temporada devolvida no veredito")
ok(gate(con, "pass.s2.deluxe")["eligible"],
   "e o deluxe dela, pela convenção <sku>.deluxe")
for old in ["pass.s1", "pass.s1.deluxe"]:
    got = gate(con, old)
    ok(not got["eligible"] and got["reason"] == "season_mismatch"
       and got["premium_sku"] == "pass.s2" and got["season_id"] == 41,
       "%s (passe da temporada ENCERRADA) é recusado na régua nova" % old)
    ok(old_rule(con, old) and not got["eligible"],
       "controle negativo: a RÉGUA ANTIGA venderia %s — era isto que cobrava o passe errado" % old)

# Uma chave que aponta para um SKU que não existe no catálogo NÃO é venda, mas a
# recusa não vem deste gate: ele responde só a pergunta da temporada ("este SKU é
# o passe que esta linha promete?"). Quem barra o SKU inexistente é a porta do
# catálogo, que roda ANTES na rota (régua 9) — os dois papéis medidos separados.
clear(con)
add(con, 42, rules='{"premium_sku": "pass.s9"}')
ghost = gate(con, "pass.s9")
ok(ghost["reason"] == "not_season_bound",
   "SKU que o catálogo não tem não é passe para o gate: ele não inventa kind")
ok(not server.is_sellable_sku(CAT, "pass.s9"),
   "e `pass.s9` morre na porta do catálogo: a rota devolve unknown_sku, nunca 200")
ok(not gate(con, "pass.s2")["eligible"]
   and gate(con, "pass.s2")["reason"] == "season_mismatch"
   and gate(con, "pass.s2")["premium_sku"] == "pass.s9",
   "num mundo cuja linha promete pass.s9, o pass.s2 legível é recusado pelo nome congelado")
ok(not server.is_sellable_sku(CAT, "pass.s2.deluxe"),
   "a convenção do deluxe não cria SKU: `pass.s2.deluxe` não está no catálogo")

# ---------------------------------------------------------------------------
# 5. Congelado ilegível é recusa com motivo próprio, nunca default
# ---------------------------------------------------------------------------
BROKEN = ["nada de json", "[]", "{}]", '{"premium_sku": ]', '{"premium_sku": null}',
          '{"premium_sku": 7}', '{"premium_sku": ""}', '{"premium_sku": "   "}',
          '"pass.s2"', "null", '{"premium_sku": ["pass.s2"]}']
for bad in BROKEN:
    clear(con)
    add(con, 77, rules=bad)
    for sku in ["pass.s1", "pass.s2", "pass.s1.deluxe"]:
        got = gate(con, sku)
        ok(not got["eligible"] and got["reason"] == "season_rules_unreadable"
           and got["season_id"] == 77,
           "congelado ilegível (%r) não vira venda de %s" % (bad, sku))

# ---------------------------------------------------------------------------
# 6. Com duas linhas ativas, a mais nova é a verdade — nos dois sentidos
# ---------------------------------------------------------------------------
clear(con)
add(con, 3, rules='{"premium_sku": "pass.s1"}')
add(con, 9, rules='{"premium_sku": "pass.s2"}')
ok(gate(con, "pass.s2")["season_id"] == 9 and gate(con, "pass.s2")["eligible"],
   "duas ativas: a de maior season_id decide (a sucessora vende)")
ok(not gate(con, "pass.s1")["eligible"]
   and gate(con, "pass.s1")["premium_sku"] == "pass.s2",
   "e o passe da linha de baixo é recusado pela linha de cima")
clear(con)
add(con, 3, rules='{"premium_sku": "pass.s2"}')
add(con, 9, rules='{}')
off = gate(con, "pass.s2")
ok(not off["eligible"] and off["reason"] == "season_mismatch"
   and off["premium_sku"] == server.DEFAULT_PREMIUM_SKU,
   "inserir a congelada primeiro não a torna autoridade: a linha 9, legada, manda")
ok(gate(con, "pass.s1")["eligible"],
   "e é ela que dá o default, porque foi ela que o gate leu")

# ---------------------------------------------------------------------------
# 7. Tempo e status: a recusa diz o que faltou
# ---------------------------------------------------------------------------
clear(con)
add(con, 55, rules='{"premium_sku": "pass.s2"}', ends_at=NOW)
ok(not gate(con, "pass.s2")["eligible"]
   and gate(con, "pass.s2")["reason"] == "no_active_season",
   "janela fechando em `now` (ends_at NÃO-estrito) já não vende, e o motivo é a temporada")
ok(gate(con, "pass.s2", NOW - 1)["eligible"],
   "um segundo antes a mesma linha era vendável: o gate respeita o `now` que recebe")
# Status medido com a janela ABERTA: com o `ends_at` vencido a recusa não
# provaria nada sobre o status — os dois motivos se confundiriam.
con.execute("UPDATE season SET ends_at = ?;", (NOW + 30 * DAY,))
ok(gate(con, "pass.s2")["eligible"], "linha ativa e dentro do prazo vende")
for st in ["closed", "settled"]:
    con.execute("UPDATE season SET status = ?;", (st,))
    got = gate(con, "pass.s2")
    ok(not got["eligible"] and got["reason"] == "no_active_season",
       "temporada '%s' não vende passe, com a janela aberta" % st)
con.execute("UPDATE season SET status = 'active';")
ok(gate(con, "pass.s2")["eligible"], "e volta a vender com a linha ativa e no prazo")
con.close()
os.unlink(path)

# Banco sem a tabela: fail-closed declarado na docstring da função.
bare = sqlite3.connect(":memory:")
ok(not gate(bare, "pass.s1")["eligible"]
   and gate(bare, "pass.s1")["reason"] == "no_active_season",
   "banco sem a migration de temporada recusa o passe (sem tabela, não há temporada)")
ok(gate(bare, "vip.1mo")["eligible"], "e não toca os não sazonais")

# ---------------------------------------------------------------------------
# 8. O contrato entre as duas linguagens (régua textual; do outro lado roda
#    tests/pass_season_alignment_test.gd, que executa o PremiumSkuOfRow)
# ---------------------------------------------------------------------------
seasonCfgSrc = read(SEASONCFG)
routeSrc = read(os.path.join(HERE, "server.py"))


def py_literal(name):
    at = routeSrc.find(name + " = ")
    if at < 0:
        return None
    open_ = at + len(name) + 3
    if open_ >= len(routeSrc) or routeSrc[open_] not in "\"'":
        return None
    quote = routeSrc[open_]
    close = routeSrc.find(quote, open_ + 1)
    return routeSrc[open_ + 1:close] if close > open_ else None


def gd_literal(name):
    at = seasonCfgSrc.find("const %s : String" % name)
    if at < 0:
        return None
    quote = seasonCfgSrc.find("\"", at)
    close = seasonCfgSrc.find("\"", quote + 1)
    return seasonCfgSrc[quote + 1:close] if quote > 0 and close > quote else None


ok(py_literal("DEFAULT_PREMIUM_SKU") == server.DEFAULT_PREMIUM_SKU,
   "o default do companion é lido do fonte, não de memória: %r" % server.DEFAULT_PREMIUM_SKU)
gd_default = gd_literal("DefaultPremiumSku")
ok(gd_default is not None and gd_default == server.DEFAULT_PREMIUM_SKU,
   "as duas camadas partilham o MESMO literal de passe default (GDScript: %r)" % gd_default)
ok(CAT.get(server.DEFAULT_PREMIUM_SKU, {}).get("kind") == "pass_premium"
   and CAT[server.DEFAULT_PREMIUM_SKU].get("price", 0) > 0,
   "o default é um passe cobrável do catálogo: linha legada nunca aponta para nada")

calendar = json.loads(read(SEASONS))["seasons"]
rolling = [e for e in calendar if not e.get("start_unix")]
declared = [str(e["premium_sku"]) for e in calendar if e.get("premium_sku")]
ok(len(rolling) == 1, "há exatamente uma temporada de rotação no calendário embarcado")
ok(len(rolling) == 1
   and rolling[0].get("premium_sku") == server.DEFAULT_PREMIUM_SKU,
   "e o default das duas camadas é o passe que a rotação do beta vende hoje (%s)"
   % (rolling[0].get("premium_sku") if rolling else None))
ok(bool(declared) and all(CAT.get(s, {}).get("kind") == "pass_premium" for s in declared),
   "todo premium_sku do calendário existe no catálogo como passe cobrável (%s)"
   % ",".join(declared))
paid = json.loads(read(PAID))
ok(all(paid[s]["price"] == CAT[s]["price"] for s in declared if s in CAT and s in paid),
   "o fallback do companion e o arquivo que o gateway cobram o mesmo preço dos passes")
ok('rules["premium_sku"] = str(entry["premium_sku"])' in seasonCfgSrc,
   "`RulesJSONForEntry` continua congelando a chave que o companion lê")
ok('"premium_sku" in parsed' in routeSrc,
   "e o companion continua distinguindo 'sem a chave' de 'chave ilegível'")

# A mesma linha, lida pelos dois lados — com UMA assimetria de propósito, que
# precisa continuar escrita em algum lugar senão vira "corrige-se" num diff.
seasonSvcSrc = read(SEASONSVC)
at = seasonSvcSrc.find("func ActiveSeason()")
active = seasonSvcSrc[at:seasonSvcSrc.find("\n\n", at)] if at >= 0 else ""
ok(bool(active) and "status = 'active'" in active
   and "ORDER BY season_id DESC" in active,
   "o jogo escolhe a linha pela MESMA ordem que o gate lê (ativa, maior season_id)")
ok(bool(active) and "ends_at >" not in active,
   "e o jogo não fecha a linha vencida na leitura: entrega para quem já pagou")
ok("AND ends_at > ?" in routeSrc,
   "quem fecha a VENDA na janela vencida é o companion: cobrar temporada vencida"
   " é dano ao jogador, e isso não se alinha na direção do jogo")

# ---------------------------------------------------------------------------
# 9. A recusa vem antes do dinheiro, nas TRÊS portas de cobrança
# ---------------------------------------------------------------------------
def body_of(name):
    at = routeSrc.find("def %s(self)" % name)
    if at < 0:
        return ""
    nxt = [i for i in (routeSrc.find("\n    def ", at + 1),
                       routeSrc.find("\ndef ", at + 1)) if i > at]
    return routeSrc[at:min(nxt)] if nxt else routeSrc[at:]


for route in ["_checkout_intent", "_checkout_preference", "_checkout_simulate"]:
    b = body_of(route)
    ok(bool(b), "a rota %s existe no fonte do companion" % route)
    gate_at = b.find("season_offer_status")
    ok(0 <= b.find("is_sellable_sku") < gate_at,
       "%s: a porta do catálogo vem antes do gate de temporada" % route)
    ok('return self._send(409, {"error": season["reason"]' in b,
       "%s: a recusa devolve o MOTIVO do gate ao cliente, não um erro genérico" % route)
    if route == "_checkout_simulate":
        before = b[:gate_at]
        ok(before.count("self._send(200") == before.count('"replay": True'),
           "%s: o único 200 antes do gate é o replay de um payment já registrado" % route)
        ok(b.find("_enqueue_items") > gate_at,
           "%s: e o grant só é enfileirado depois de o gate ler a temporada" % route)
    else:
        ok(b.find("self._send(200") > gate_at,
           "%s: nenhuma resposta 200 é montada antes de o gate ler a temporada" % route)
bare.close()

# ---------------------------------------------------------------------------
# 10. O catálogo que embarca, não o fallback: as rotas usam `self.server.catalog`,
#     que vem de `data/conf/paid_catalog.json` (ou SHAMBLETA_CATALOG_FILE)
# ---------------------------------------------------------------------------
shipped = server.load_catalog(PAID)
ok(shipped.get("pass.s1", {}).get("kind") == "pass_premium"
   and shipped.get("pass.s2", {}).get("kind") == "pass_premium",
   "paid_catalog.json declara os dois passes como pass_premium (é o kind que liga o gate)")
con2, path2 = season_db()
add(con2, 61, rules='{"premium_sku": "pass.s2"}')
got = server.season_offer_status(con2, shipped, "pass.s1")
ok(not got["eligible"] and got["reason"] == "season_mismatch"
   and got["premium_sku"] == "pass.s2",
   "com o catálogo do pacote: a S2 no ar recusa o passe da S1")
ok(server.season_offer_status(con2, shipped, "pass.s2")["eligible"],
   "e vende o dela")
add(con2, 62)
ok(not server.season_offer_status(con2, shipped, "pass.s2")["eligible"]
   and server.season_offer_status(con2, shipped, "pass.s1")["eligible"],
   "linha legada com o catálogo do pacote: vende o default e nada além dele")
con2.close()
os.unlink(path2)

# ---------------------------------------------------------------------------
# 11. O corpo de GET /catalog: a temporada MARCA o item, não faz ele sumir
# ---------------------------------------------------------------------------
# Aqui é onde o defeito que cobrava caro morava: o checkout já recusava
# `pass.s1` com a S2 no ar (bloco 4), mas `/catalog` — a única rota pública lida
# pelo browser que TOCA o banco — mostrava o passe estrangeiro sem nenhum sinal.
# A página de preço continuou exibindo tudo (é a régua D5 de `test_security.py`:
# item que some calado da vitrine é dano de confiança, não filtro inteligente);
# o que mudou é que cada passe agora carrega o veredito do MESMO gate.
con3, path3 = season_db()
add(con3, 71, rules='{"config_id": "s2", "premium_sku": "pass.s2"}')
pub = server.public_catalog(shipped, con3)

ok(pub["pass.s2"]["season_eligible"] is True and pub["pass.s2"]["season_id"] == 71,
   "o passe da temporada no ar sai vendável, com a temporada devolvida no corpo")
ok(pub["pass.s1"]["season_eligible"] is False
   and pub["pass.s1"]["season_reason"] == "season_mismatch",
   "o passe da temporada ENCERRADA sai marcado como tal — não some da vitrine")
ok("season_id" not in pub["pass.s1"],
   "e a resposta não inventa temporada para o que foi recusado (só o SKU esperado)")
ok(pub["pass.s1"]["season_premium_sku"] == "pass.s2",
   "o corpo diz qual SKU a temporada espera, senão a página não tem como corrigir o botão")
ok("season_eligible" not in pub["vip.1mo"],
   "gem/VIP/doação não recebem veredito de temporada: o gate deles é outro e está vazio")

sellable = [k for k in shipped if not k.startswith("_")]
ok(sorted(pub) == sorted(sellable),
   "a temporada não muda a CONTAGEM da vitrine (%d itens cobráveis, %d no corpo)"
   % (len(sellable), len(pub)))
ok(not [k for k in pub if k.startswith("_")],
   "e as chaves de declaração do arquivo (`_note`, `_agreements`) não viram item de loja")
ok(all(pub[k].get("price") == shipped[k].get("price")
       and pub[k].get("currency") == shipped[k].get("currency") for k in pub),
   "preço e moeda passam ilesos pela marcação (é display, a fonte do preço não muda)")

# A régua de identidade, SKU a SKU: o corpo não pode contar uma elegância que o
# gate nega, nem negar a que ele concede — as duas perguntas têm uma resposta só.
# Itens fora do gate não têm o que divergir (saem sem veredito, régua logo acima),
# então a identidade é medida sobre os passes anotados + a cobertura da anotação.
passes = [k for k in sellable if shipped[k].get("kind") == "pass_premium"]
disagree = [k for k in pub if "season_eligible" in pub[k]
            and pub[k]["season_eligible"]
            != server.season_offer_status(con3, shipped, k)["eligible"]]
ok(not disagree,
   "nenhum item do catálogo embarcado expõe no /catalog elegância diferente da que o "
   "checkout aplica (%d SKUs conferidos): %s" % (len(sellable), disagree))
ok(sorted(k for k in pub if "season_eligible" in pub[k]) == sorted(passes),
   "e todo `pass_premium` do catálogo sai anotado (%d passes), nenhum a mais" % len(passes))

# Banco inacessível: a página de preço levanta, o botão é que morre. Fail-closed
# na mesma direção do checkout, nunca um 500 e nunca "elegível por omissão".
pub0 = server.public_catalog(shipped, None)
ok(all(pub0[k]["season_eligible"] is False
       and pub0[k]["season_reason"] == "store_unavailable"
       and "season_premium_sku" not in pub0[k]
       for k in pub0 if shipped[k].get("kind") == "pass_premium"),
   "com `con=None` todo passe sai `store_unavailable` (o display não deduz elegibilidade)")
ok(all({a: b for a, b in pub0[k].items() if not a.startswith("season_")}
       == {a: b for a, b in shipped[k].items() if a in pub0[k]}
       for k in pub0),
   "e tirar o banco do ar não muda nenhum campo de preço exibido")
empty = sqlite3.connect(":memory:")
nok = server.public_catalog(shipped, empty)["pass.s1"]
ok(nok["season_reason"] == "no_active_season"
   and "season_premium_sku" not in nok,
   "sem linha ativa o motivo é o do gate (`no_active_season`) e NÃO sai SKU a comprar:"
   " sem temporada confirmada não há botão honesto, inventar um é a mesma mentira")
empty.close()

# A rota usa a função, e usa o catálogo que embarca: se alguém voltar a montar o
# corpo inline, ou a marcar com `DEFAULT_CATALOG`, o /catalog volta a poder
# divergir do checkout sem que nenhuma das duas camadas esteja errada sozinha.
cat_body = routeSrc[routeSrc.find('if path == "/catalog":'):]
cat_body = cat_body[:cat_body.find("\n        if path ==")]
ok("public_catalog(self.server.catalog, con)" in cat_body
   and "public_catalog(self.server.catalog, None)" in cat_body,
   "o handler monta o corpo por `public_catalog` com o CATÁLOGO DO PACOTE nas duas portas")
ok("except sqlite3.Error" in cat_body,
   "e o caminho do banco tem fail-closed, não 500")

# CÓPIA EMBARCADA: a página que o browser abre não pode prometer uma temporada
# literal, porque a temporada muda por linha de banco e o gate passa a recusar o
# SKU escrito à mão. A lista de arquivos vem do Dockerfile, não desta suíte.
def served_text():
    out = []
    for line in read(os.path.join(ROOT, "deploy", "web", "Dockerfile")).splitlines():
        m = re.match(r"\s*COPY\s+(?:--from=\S+\s+)?(\S+)\s+(/usr/share/nginx/html\S*)\s*$",
                     line)
        if not m or not m.group(1).startswith("deploy/web/"):
            continue      # `--from=build` é o binário do jogo, e nginx.conf não é cópia
        base = os.path.join(ROOT, m.group(1))
        names = sorted(os.listdir(base)) if os.path.isdir(base) else [""]
        for n in names:
            p = os.path.join(base, n) if n else base
            if os.path.isfile(p) and p.endswith((".html", ".js", ".css", ".md")):
                out.append(p)
    return out


served = served_text()
ok(any(p.endswith("landing/index.html") for p in served)
   and any(p.endswith("sw.js") for p in served)
   and any(p.endswith("checkout_return.html") for p in served),
   "a lista derivada cobre o que o navegador abre (%d arquivos de texto)" % len(served))
ok(not [p for p in served if "landing_new" in p],
   "e `landing_new/` está fora por estar excluída do contexto de build — rascunho")
bad = ["%s:%d" % (os.path.relpath(p, ROOT), no) for p in served
       for no, ln in enumerate(read(p).splitlines(), 1)
       if re.search(r"pass\.s\d+|\([Ss]\d+\)", ln)]
ok(not bad,
   "nenhum literal de temporada na cópia embarcada (a página não pode oferecer S1 "
   "quando a linha do banco pode estar vendendo S2): %s" % bad)
con3.close()
os.unlink(path3)

sys.exit(report("SEASON OFFER"))
