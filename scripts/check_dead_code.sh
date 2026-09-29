#!/usr/bin/env bash
# Gate de código inalcançável — varre o GDScript do produto e dos harnesses e
# acusa linha que NÃO PODE executar porque vem depois de um terminador da mesma
# cláusula (`return` / `break` / `continue`).
#
# Por que este gate existe (2026-09-28): a reescrita mecânica `0c5cb56` trocou
# `assert(cond)` por `if cond == null: return` em 20+ arquivos e, em oito deles,
# moveu o CORPO para dentro do ramo de erro ou deixou a linha de efeito abaixo do
# `return`. O resultado era um `Map.LoadMapNode` que nunca adicionava o mapa à
# árvore e um `Map.AddChild` com a única linha de trabalho morta — código que
# compila, passa em todo o resto do portão e não faz nada. Nenhum teste olhava a
# árvore naquela hora, e um verde não distingue "a função rodou" de "a função
# existe". Esta régua fecha a classe por cima: toda linha depois de terminador é
# acusada no mesmo commit em que entra.
#
# Uso:   bash scripts/check_dead_code.sh
# Saída: uma linha por check ([PASS]/[FAIL] com ESPERADO/ENCONTRADO) e, no fim,
#        `== DEAD CODE GATE: N checks, M failures ==` — o formato lido por
#        scripts/ci_gate_log.sh, então ele entra pelo mesmo portão dos outros
#        gates de estrutura (chamado por `structure_gates()` em scripts/test.sh).
#        Exit code = nº de falhas.
#
# O que a régua NÃO é: não é verificação de null, não é análise de fluxo por
# caminho (ela não sabe se o `return` é alcançável) e não cobre terminador dentro
# de `if` de uma linha (`if x: return`), onde a linha seguinte pode estar viva —
# as duas elisões são declaradas nos controles abaixo, não escondidas.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
"$PY" - "$ROOT" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
roots = ["sources", "tests"]          # addon é terceiro: não é código deste repo
excluded = ("addons", "archive", "graphify-out", ".godot")
checks = 0
failures = 0

def check(ok, title, expected, found):
    global checks, failures
    checks += 1
    if ok:
        print("[PASS] %s" % title)
        return
    failures += 1
    print("[FAIL] %s" % title)
    print("       ESPERADO: %s" % expected)
    print("       ENCONTRADO: %s" % found)

TERMS = re.compile(r'^(return|break|continue)(\s|$|;)')
HEADER = re.compile(r'^(if|elif|else|for|while|match|func|static func)\b')
SIBLING = re.compile(r'^(elif|else|catch|finally)\b')

def indent_of(line):
    n = 0
    for ch in line:
        if ch in " \t":
            n += 1
        else:
            break
    return n

def strip_comment(text):
    out = []
    i = 0
    in_str = None
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                out.append(text[i:i + 2]); i += 2; continue
            if c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
        elif c == "#":
            break
        out.append(c); i += 1
    return "".join(out)

def depth_of(text):
    d = 0
    i = 0
    in_str = None
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2; continue
            if c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
        elif c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        i += 1
    return d

def split_statements(text):
    parts, buf, i, in_str, d = [], [], 0, None, 0
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                buf.append(text[i:i + 2]); i += 2; continue
            if c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
        elif c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        elif c == ";" and d == 0:
            parts.append("".join(buf)); buf = []; i += 1; continue
        buf.append(c); i += 1
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]

def logical_lines(text):
    # Uma linha FÍSICA não é uma instrução: GDScript continua com `\` e com colchete
    # aberto, e é exatamente assim que `return Transaction(func() -> bool: ...)` ocupa
    # 40 linhas de `SQL.gd`. Uma régua que trata a segunda linha do `return` como código
    # morto acusa 60 vezes um repo limpo, é vermelha na primeira TRIAGEM e vai embora.
    out = []
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        code = strip_comment(lines[i]).rstrip()
        if not code.strip():
            i += 1
            continue
        ind = indent_of(lines[i])
        start = i + 1
        parts = [code]
        d = depth_of(code)
        while (d > 0 or code.endswith("\\")) and i + 1 < n:
            i += 1
            code = strip_comment(lines[i]).rstrip()
            parts.append(code)
            d = depth_of(" ".join(parts))
        joined = " ".join(p.strip().rstrip("\\").strip() for p in parts).strip()
        out.append((start, ind, joined))
        i += 1
    return out

def terminator_of(code):
    stmts = split_statements(code)
    if not stmts:
        return None
    last = stmts[-1]
    if not TERMS.match(last):
        return None
    # `if x: return` — o terminador mora num bloco de uma linha e a linha seguinte pode
    # estar viva. É elisão deliberada (declarada no topo do arquivo), não buraco: sem
    # ela a régua acusa código vivo e perde a TRIAGEM inteira.
    if HEADER.match(code):
        return None
    return last

def scan(text):
    hits = []
    dead = None
    for (ln, ind, code) in logical_lines(text):
        if dead is not None:
            t_ind, t_no, t_code = dead
            if ind < t_ind:
                dead = None
            elif ind == t_ind and SIBLING.match(code):
                # `else:` do MESMO nível de um `return` dentro do `if` é ramo irmão,
                # não linha morta: quem chegou aqui pelo caminho falso ainda o percorre.
                dead = None
            else:
                hits.append((t_no, ln, t_code, code[:80]))
                continue
        term = terminator_of(code)
        if term is not None:
            dead = (ind, ln, code)
    return hits

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""

files = []
for r in roots:
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, r)):
        dirnames[:] = [d for d in dirnames if d not in excluded]
        for f in filenames:
            if f.endswith(".gd"):
                files.append(os.path.relpath(os.path.join(dirpath, f), root))
files.sort()

all_hits = []
terminators = 0
for path in files:
    src = read(os.path.join(root, path))
    terminators += len([1 for (_, _, code) in logical_lines(src) if terminator_of(code)])
    for (t_no, ln, t_code, code) in scan(src):
        all_hits.append("%s:%d (%s) depois de `%s` em :%d" % (path, ln, code, t_code, t_no))

# (1) Cobertura: uma varredura muda tem o mesmo verde de uma varredura limpa, então o
#     censo é check, não rodapé. Os números são medidos aqui, não prometidos.
check(len(files) >= 350,
      "cobertura: a varredura lê o GDScript do produto e dos harnesses",
      ">= 350 arquivos sob sources/ e tests/ (medido em 2026-09-28: 396; addons é terceiro e fica fora, por projeto)",
      "%d arquivos lidos, %d terminadores vistos" % (len(files), terminators))
check(terminators >= 6000,
      "cobertura: o predicado tem matéria-prima (um repo sem `return` não provaria nada)",
      ">= 6000 statements de terminador no corpus (medido em 2026-09-28: 6714)",
      "%d terminadores reconhecidos em %d arquivos" % (terminators, len(files)))

# (2) A acusação.
check(len(all_hits) == 0,
      "nenhuma linha de código depois de `return`/`break`/`continue` na mesma cláusula",
      "0 linhas inalcançáveis",
      "%d: %s" % (len(all_hits), " | ".join(all_hits[:12])))

# (3) Controles em memória, pelos MESMOS predicados acima — é o que faz o `0` de (2)
#     significar algo. Cada controle vem em par: o plantado tem que ser acusado e o
#     vizinho vivo tem que sair limpo, senão "acusou" pode ser um predicado que acusa
#     tudo (a rodada cega de 2026-09-28 já viu régua com essa forma).
PLANTED = [
    ("morte depois de return",
     'func f() -> int:\n\treturn 1\n\tprint("MORTA")\n', 1),
    ("morte depois de continue dentro do laço",
     'func f() -> void:\n\twhile true:\n\t\tcontinue\n\t\tprint("MORTA")\n', 1),
    ("linha viva depois de ramo que retorna",
     'func f() -> int:\n\tif true:\n\t\treturn 1\n\tprint("VIVA")\n\treturn 2\n', 0),
    ("`else:` irmão de um `return` no `if`",
     'func f(x : int) -> int:\n\tif x > 0:\n\t\treturn 1\n\telse:\n\t\treturn 2\n', 0),
    ("continuação por colchete aberto (a forma de `SQL.gd`)",
     'func f() -> bool:\n\treturn Transaction(func() -> bool:\n\t\tfor q in ["A", "B"]:\n\t\t\tQuery(q)\n\t\treturn true)\n', 0),
    ("continuação por barra (`CellCommons.gd`)",
     'func f() -> bool:\n\treturn true and \\\n\t\tfalse\n', 0),
    ("comentário e linha em branco no meio do ramo morto",
     'func f() -> int:\n\treturn 1\n\t# comentário\n\n\tprint("MORTA")\n', 1),
    ("linha morta com duas instruções separadas por `;` conta como uma",
     'func f() -> int:\n\treturn 1\n\tprint("MORTA"); print("MORTA2")\n', 1),
]
for (nome, src, esperado) in PLANTED:
    achado = len(scan(src))
    if esperado:
        check(achado == esperado, "controle: %s é acusado" % nome,
              "%d linha(s) inalcançável(is)" % esperado, "%d" % achado)
    else:
        check(achado == 0, "controle: %s NÃO é acusado (código vivo)" % nome,
              "0 linhas", "%d" % achado)

# (4) O predado lê o arquivo real, não uma cópia dele: os dois sítios que a primeira
#     versão da régua apontou como suspeitos são conferidos pelo nome, e se algum deles
#     um dia virar morte de verdade este check nomeia o culpado.
TRIAGEM = [
    ("sources/sql/SQL.gd", "return Transaction(func() -> bool:"),
    ("sources/idle/OfflineSettle.gd", "if sqlNode.Transaction(func() -> bool:"),
    ("sources/cell/CellCommons.gd", "return cell and \\"),
]
for (path, shape) in TRIAGEM:
    src = read(os.path.join(root, path))
    check(shape in src,
          "triagem: %s tem a instrução multi-linha que a régua aprendeu a não acusar" % path,
          "a forma `%s` no arquivo" % shape,
          "encontrado" if shape in src else "FORMA AUSENTE — a régua de (3) precisa de um novo par")

print("== DEAD CODE GATE: %d checks, %d failures ==" % (checks, failures))
sys.exit(failures)
PYEOF
