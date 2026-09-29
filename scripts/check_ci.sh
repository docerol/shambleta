#!/usr/bin/env bash
# Gate de CI — lê os workflows e confere contra a ÁRVORE, não contra o doc.
#
# Existe porque a família de defeito de deploy é sempre a mesma: o workflow
# afirma uma coisa que o repo não sustenta (preset que não existe, artefato que
# nenhum job produz, imagem que ninguém builda, deploy que roda sem teste, budget
# que avisa em vez de falhar). Nada disso aparece até a pipeline quebrar no
# fuso horário do runner — e aí já é segunda-feira. Um portão que quebra com diff
# claro custa dez segundos na máquina de quem escreveu o diff.
#
# Uso:   bash scripts/check_ci.sh          # ou ./scripts/check_ci.sh
# Saída: uma linha por regra ([PASS] ou [FAIL] com ESPERADO/ENCONTRADO) e, no fim,
#        `== CI GATE: N checks, M failures ==` — o formato é o que
#        scripts/ci_gate_log.sh lê, então o script entra pelo mesmo portão dos
#        outros gates de estrutura:
#            gate_sh /tmp/shambleta-ci.log "== CI GATE:" scripts/check_ci.sh
#        Exit code = nº de falhas.
#
# O que este gate NÃO faz: ele não executa a pipeline. GitHub Actions só roda no
# runner, e correr localmente um workflow é falso trabalho — o que dá para medir
# aqui é a coerência interna do arquivo com a árvore (nomes, grafo de jobs,
# artefatos, presets, imagens, versionamento) e as réguas que decidem se um job
# tem poder de barrar. Uma pipeline declarada e nunca executada continua
# não-medida; isto prova forma, não resultado.
#
# Poder de falhar — medido em 2026-09-27 mutando os workflows (hash gravado antes,
# restaurado e conferido com `sha256sum -c` depois; verde no fim):
#   M1 tirar o `exit 1` da guarda de estouro do budget  -> 1 falha  (web-export)
#   M2 trocar `compose ... build` por `pull`             -> 5 falhas (um serviço cada)
#   M3 trocar a conclusão do `workflow_run` por `always()`-> 1 falha (deploy-staging)
#   M4 preset inexistente na matrix (`"macOS"` -> `"macOS X"`) -> 1 falha
#   M5 artefato baixado sem produtor no needs (`Linux` -> `LinuxX`) -> 1 falha
# M1 só passou a existir porque a primeira versão da regra procurava `exit 1` no
# texto do step, e o comentário do step cita `exit 1`: o gate ficou VERDE com a
# guarda arrancada. Régua lendo prosa não é régua — daí `code_of()` e o
# `all_wf_raw` descomentado. A armadilha é a mesma que já tinha derrubado a régua
# M1 do gate idle (`docs/development/testing.md`).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
WDIR=".github/workflows"

[ -d "$WDIR" ] || { echo "[FAIL] não encontrei $WDIR"; echo "== CI GATE: 1 checks, 1 failures =="; exit 1; }
$PY -c 'import yaml' 2>/dev/null || {
	echo "[FAIL] python3 + PyYAML indisponíveis — sem eles este gate não lê YAML."
	echo "       (instale python3-yaml; o gate de compose tem a mesma exigência)"
	echo "== CI GATE: 1 checks, 1 failures =="
	exit 1
}

"$PY" - "$WDIR" <<'PYEOF'
import os, re, sys, glob, yaml

wdir = sys.argv[1]
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

def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh) or {}

def triggers(doc):
    # `on:` é chave reservada do YAML 1.1 -> vira bool True. As duas formas
    # aparecem nos arquivos reais, então as duas são aceitas.
    return doc.get("on", doc.get(True, {})) or {}

docs = {}
for path in sorted(glob.glob(os.path.join(wdir, "*.yml")) + glob.glob(os.path.join(wdir, "*.yaml"))):
    try:
        docs[path] = load(path)
        check(True, "%s: parseia como YAML" % path, "YAML válido", "YAML válido")
    except yaml.YAMLError as err:
        check(False, "%s: parseia como YAML" % path, "YAML válido", str(err).splitlines()[0])
        docs[path] = {}

# ---------------------------------------------------------------- job básico
for path, doc in docs.items():
    jobs = doc.get("jobs") or {}
    check(bool(jobs), "%s: tem `jobs:` não-vazio" % path,
          "ao menos um job", "jobs vazio ou ausente")
    # Chave duplicada no YAML não é erro: a última vence e o job some em silêncio.
    raw = open(path).read()
    names = re.findall(r'^  ([A-Za-z0-9_-]+):\s*$', raw, re.M)
    dup = sorted({n for n in names if names.count(n) > 1})
    check(not dup, "%s: nenhum nome de job duplicado" % path,
          "nomes de job únicos", "duplicado: %s" % (", ".join(dup) or "-"))
    for name, job in jobs.items():
        job = job or {}
        check("runs-on" in job, "%s/%s: declara `runs-on`" % (os.path.basename(path), name),
              "runs-on presente", "ausente")
        check(bool(job.get("steps") or job.get("uses")),
              "%s/%s: tem steps (ou usa um reusable workflow)" % (os.path.basename(path), name),
              "steps não-vazio", "sem steps")

# ---------------------------------------------------------------- grafo de needs
def needs_list(job):
    needs = job.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    return list(needs)

for path, doc in docs.items():
    jobs = doc.get("jobs") or {}
    for name, job in jobs.items():
        for target in needs_list(job or {}):
            check(target in jobs, "%s/%s: o `needs: %s` aponta para um job que existe"
                  % (os.path.basename(path), name, target),
                  "job %r definido no mesmo arquivo" % target,
                  "nenhum job %r em %s" % (target, path))

# ---------------------------------------------------------------- artefato: produtor x consumidor
PRESET_MATRIX = {}
for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        inc = ((job or {}).get("strategy") or {}).get("matrix") or {}
        PRESET_MATRIX["%s/%s" % (path, name)] = [e.get("name") for e in (inc.get("include") or [])]

def uploads_of(doc, job_name):
    out = []
    for step in ((doc.get("jobs") or {}).get(job_name, {}) or {}).get("steps") or []:
        uses = str(step.get("uses") or "")
        if "upload-artifact" in uses:
            out.append(str((step.get("with") or {}).get("name", "")))
    return out

def closure(doc, job_name, seen=None):
    """needs transitivo: um artefato pode vir de um job que eu preciso, ou de um
    que meu needs precisa (snap -> builds; um job novo -> snap)."""
    seen = seen or set()
    job = (doc.get("jobs") or {}).get(job_name) or {}
    for target in needs_list(job):
        if target in seen or target not in (doc.get("jobs") or {}):
            continue
        seen.add(target)
        closure(doc, target, seen)
    return seen

for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            uses = str(step.get("uses") or "")
            if "download-artifact" not in uses:
                continue
            want = str((step.get("with") or {}).get("name", ""))
            if not want:
                continue  # sem `name:` é "baixa todos os artefatos" — não tem produtor a nomear
            producers = {}
            for other in (doc.get("jobs") or {}):
                for got in uploads_of(doc, other):
                    if "${{" in got:
                        # nome de matrix: expande para os nomes declarados no strategy
                        for entry in PRESET_MATRIX.get("%s/%s" % (path, other), []):
                            if entry:
                                producers.setdefault(entry, set()).add(other)
                    else:
                        producers.setdefault(got, set()).add(other)
            reachable = producers.get(want, set()) & (closure(doc, name) | {name})
            check(bool(reachable),
                  "%s/%s: o artefato baixado %r é produzido por um job do próprio needs"
                  % (os.path.basename(path), name, want),
                  "produtor de %r alcançável via needs" % want,
                  "produzido por: %s; needs alcança: %s"
                  % (", ".join(sorted(producers.get(want, set()))) or "ninguém",
                     ", ".join(sorted(closure(doc, name))) or "ninguém"))

# ---------------------------------------------------------------- réguas externas: gate obrigatório
CRED = re.compile(r"(COOLIFY_[A-Z_]*TOKEN|SNAPCRAFT_STORE_CREDENTIALS|STORE_CREDENTIALS)")
for path, doc in docs.items():
    trig = triggers(doc)
    raw = "\n".join(l for l in open(path).read().splitlines() if not l.lstrip().startswith("#"))
    for name, job in (doc.get("jobs") or {}).items():
        body = yaml.dump(job or {})
        if not CRED.search(body):
            continue
        job_if = str((job or {}).get("if") or "")
        gated = bool(needs_list(job or {})) or "success()" in job_if
        workflow_guarded = ("workflow_run" in yaml.dump(trig)) and re.search(
            r"workflow_run\.conclusion\s*==\s*'success'", raw)
        check(gated or bool(workflow_guarded),
              "%s/%s: publica lá fora, então precisa de gate antes de rodar"
              % (os.path.basename(path), name),
              "`needs:` em job de teste, ou `if:` com success(), ou workflow disparado por workflow_run com conclusão conferida",
              "needs=%s if=%r trigger=%s" % (needs_list(job or {}) or "-",
                                             job_if or "-",
                                             ",".join(k for k in (trig or {}) if k != "secrets") or "-"))

# ---------------------------------------------------------------- presets de export x CI
presets_cfg = open("export_presets.cfg").read() if os.path.exists("export_presets.cfg") else ""
preset_names = set(re.findall(r'^name="([^"]+)"', presets_cfg, re.M))
check(bool(preset_names), "export_presets.cfg: declara presets",
      "ao menos um `name=`", "nenhum preset lido")
declared_templates = []
for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        for entry in (((job or {}).get("strategy") or {}).get("matrix") or {}).get("include") or []:
            tpl = entry.get("export_template")
            if tpl:
                declared_templates.append((os.path.basename(path), name, entry.get("name"), tpl))
for wf, job, label, tpl in declared_templates:
    check(tpl in preset_names, "%s/%s: o preset %r que a matrix exporta existe no export_presets.cfg"
          % (wf, job, tpl),
          "preset declarado em export_presets.cfg", "nomes disponíveis: %s" % ", ".join(sorted(preset_names)))
web_export = re.compile(r'--export-(?:debug|release)\s+"?Web"?')
raws = {p: open(p).read() for p in docs}
# Linha de comentário NÃO é código: os comentários destes workflows citam
# `docker compose build`, `docker build` e `exit 1` exatamente para explicar o
# que o passo faz. Nada que procure comportamento pode casar com prosa — as duas
# réguas abaixo (budget e imagens) já foram provadas mortas por mutação lendo
# comentário, e é por isto que o texto aqui é sempre a versão descomentada.
all_wf_raw = "\n".join(l for p, txt in raws.items() for l in txt.splitlines()
                       if not l.lstrip().startswith("#"))
web_built = any(web_export.search(raw) or
                any(e.get("export_template") == "Web"
                    for job in (docs[p].get("jobs") or {}).values()
                    for e in (((job or {}).get("strategy") or {}).get("matrix") or {}).get("include") or [])
                for p, raw in raws.items())
check(bool(web_built), "algum job exporta o preset Web (a plataforma de lançamento)",
      "export do preset `Web` em algum workflow", "nenhum export Web declarado")

# ---------------------------------------------------------------- imagens: compose builda, CI tem de buildar
# A fonte é o compose (ele declara contexto + dockerfile de cada serviço), não um
# glob de arquivos: um Dockerfile que ninguém referencia no compose é morto, e um
# serviço que o compose builda e a CI nunca construiu é o defeito que interesa.
compose = load("deploy/docker-compose.yml") if os.path.exists("deploy/docker-compose.yml") else {}
services = compose.get("services") or {}
builds = []
for svc, spec in services.items():
    b = (spec or {}).get("build")
    if isinstance(b, dict) and b.get("dockerfile"):
        builds.append((svc, str(b.get("context", ".")), str(b["dockerfile"])))
check(bool(builds), "deploy/docker-compose.yml: declara serviços com `build:`",
      "ao menos um", "nenhum serviço buildado pelo compose")
# Um job que roda `docker compose -f <arquivo> build` builda todo serviço com
# `build:` daquele arquivo — é a forma fiel (mesmo contexto, mesmos args, mesmo
# merge). `-f <Dockerfile>` em `docker build` solto também conta, mas aí o
# contexto e os args ficam por conta de quem escreveu o passo.
compose_build_files = set()
for m in re.finditer(r'docker\s+compose([^\n;|]*)\bbuild\b', all_wf_raw):
    compose_build_files.update(re.findall(r'-f\s+(\S+)', m.group(1)))
for svc, ctx, df in builds:
    check(os.path.exists(df), "%s: o dockerfile %s que o compose aponta existe" % (svc, df),
          "arquivo presente na árvore", "ausente")
    explicit = re.search(r"docker\s+build[^\n]*-f\s+%s" % re.escape(df), all_wf_raw)
    via_compose = "deploy/docker-compose.yml" in compose_build_files
    check(bool(explicit) or via_compose,
          "%s: o compose builda %s (contexto %s), então um job de CI tem de buildar a mesma imagem"
          % (svc, df, ctx),
          "`docker compose -f deploy/docker-compose.yml build`, ou `docker build -f %s`" % df,
          "nenhum workflow constrói esta imagem (compose build visto: %s)"
          % (", ".join(sorted(compose_build_files)) or "nenhum"))

# ---------------------------------------------------------------- budget tem de poder falhar
# ---------------------------------------------------------------- budget tem de poder falhar
def code_of(text):
    # Régua que lê comentário é régua que acredita no que o autor escreveu: a
    # primeira versão desta procurava `exit 1` no texto do step, e o rationale do
    # próprio step cita `exit 1` — o gate ficou verde com a guarda arrancada
    # (provado por mutação em 2026-09-27). Aqui só linha executável conta.
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

budget_step = None
for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            if re.search(r"gzip|first-load", str(step.get("name") or "") + str(step.get("run") or "")):
                budget_step = (os.path.basename(path), name, str(step.get("run") or ""))
if budget_step:
    wf, job, run = budget_step
    m_guard = re.search(r'if\s+\[\s*"\$\{?total\}?"\s+-(?:ge|gt|lt|le|eq|ne)\s+"\$\{?CEILING\}?"\s*\];\s*then(.*?)\n[ \t]*fi',
                        code_of(run), re.S)
    check(bool(m_guard) and "exit 1" in (m_guard.group(1) if m_guard else ""),
          "%s/%s: o budget de first-load falha o job quando estourado (aviso não barra)" % (wf, job),
          "um bloco `if [ \"$total\" -ge \"$CEILING\" ]; then ... exit 1 ... fi` em linha executável",
          "nenhum `exit 1` dentro da guarda de estouro" if m_guard else "nenhuma comparação com o CEILING encontrada")
else:
    check(False, "existe um step de budget de first-load no export Web",
          "step que mede gzip e compara com a meta", "nenhum step de budget encontrado")

# O número do ratchet mora no workflow; a explicação dele mora no doc. Sem uma
# régua ligando os dois, o teto sobe em silêncio num commit e o doc continua
# contando o pacote antigo — que é exatamente como um ratchet deixa de valer.
m_ceiling = re.search(r"CEILING=\$\(\((\d+)\*1024\*1024\)\)", all_wf_raw)
check(bool(m_ceiling), "o budget de first-load tem teto numérico declarado (`CEILING=$((N*1024*1024))`)",
      "um teto explícito no workflow", "nenhum CEILING encontrado")
if m_ceiling:
    n = m_ceiling.group(1)
    slim = open("deploy/WEB_SLIM.md").read() if os.path.exists("deploy/WEB_SLIM.md") else ""
    check(re.search(r"\b%s\s*Mi?B" % n, slim) is not None,
          "deploy/WEB_SLIM.md declara o mesmo ratchet de %s MiB que a CI cobra" % n,
          "o número do teto aparecer no doc do payload", "ausente em deploy/WEB_SLIM.md")
    exporter = open("scripts/export_web.sh").read() if os.path.exists("scripts/export_web.sh") else ""
    m_local = re.search(r"CEILING=\$\(\((\d+)\*1024\*1024\)\)", exporter)
    check(m_local and m_local.group(1) == n,
          "scripts/export_web.sh cobra o MESMO ratchet de %s MiB que a CI" % n,
          "local e CI com o mesmo número (senão o export caseiro vale menos que o push)",
          "CEILING local: %s" % (m_local.group(1) if m_local else "ausente"))

# ---------------------------------------------------------------- versão do engine pinada de forma coerente
envs = {}
for path, doc in docs.items():
    for k, v in (doc.get("env") or {}).items():
        envs[k] = str(v)
godot_env = envs.get("GODOT_VERSION")
check(godot_env is not None, "o workflow declara GODOT_VERSION", "env GODOT_VERSION presente", "ausente")
images = sorted({m.group(1) for m in re.finditer(r"image:\s*barichello/godot-ci:([0-9.]+)", all_wf_raw)})
for tag in images:
    check(tag == godot_env, "a imagem `barichello/godot-ci:%s` casa com GODOT_VERSION=%s" % (tag, godot_env),
          "uma versão só (o export e os testes têm de rodar no mesmo engine)", "divergente")
check(bool(images), "algum job roda em container godot-ci", "imagem barichello/godot-ci pinada", "nenhuma encontrada")
features = ""
if os.path.exists("project.godot"):
    m = re.search(r'config/features=PackedStringArray\("([0-9.]+)"', open("project.godot").read())
    features = m.group(1) if m else ""
check(bool(features) and godot_env and godot_env.startswith(features),
      "GODOT_VERSION=%s é do mesmo minor do projeto (config/features %s)" % (godot_env, features or "?"),
      "pin do CI no mesmo 4.minor do project.godot", "divergente")

# ---------------------------------------------------------------- hygiene de actions
uses_all = re.findall(r'^\s*uses:\s*(\S+)', all_wf_raw, re.M)
# `uses: ./caminho` é action local do próprio repo: ela é pinada pelo conteúdo do
# commit, não por tag, então exige `@` não. Externa sem pin (ou @latest) é flutuante.
external = [u for u in uses_all if not u.startswith("./")]
check(not any(u.endswith("@latest") or "@" not in u for u in external),
      "nenhuma action externa usada sem pin (sem `@latest`, sem tag ausente)",
      "todo `uses:` externo com @versão explícita; locais são `./caminho`",
      ", ".join(sorted({u for u in external if u.endswith("@latest") or "@" not in u})) or "-")
checkout_majors = sorted({u.split("@")[1] for u in uses_all if u.startswith("actions/checkout")})
check(len(checkout_majors) <= 1, "actions/checkout com um major só em todos os workflows",
      "um major consistente", ", ".join(checkout_majors) or "-")

# ---------------------------------------------------------------- godot -s exige import antes
for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        steps = (job or {}).get("steps") or []
        ran_script = any(re.search(r"godot\s+--headless[^\n]*\s-s\s", str(s.get("run") or "")) for s in steps)
        if not ran_script:
            continue
        imported = any(re.search(r"godot\s+--headless[^\n]*--import", str(s.get("run") or ""))
                       or "Import assets" == str(s.get("name") or "") for s in steps)
        check(imported, "%s/%s: roda harness com `-s`, então importa os assets antes"
              % (os.path.basename(path), name),
              "um step `--import` (cache de class_name velho = Parse Error em tudo)",
              "nenhum import antes do -s")

# ---------------------------------------------------------------- rollback executável
# O bloco acima prova que a CI builda; este prova que a DOC do operador manda fazer o
# que o compose serve, e que a CI pisa o nome do artefato. As três ficções que o juízo
# de DevOps nomeou eram todas daqui: um `docker compose pull game` como procedimento
# de rollback (nenhum serviço buildado tinha `image:`, logo não havia nada para
# puxar), uma seção de rollback no Coolify que nunca existiu, e um runbook afirmando
# que o `/metrics` não expõe a espera da `queryMutex` enquanto `MetricsServer` emite a
# série e `deploy/alerts.rules.yml` pagina sobre ela. Prosa não segura nenhuma das
# três; o que está abaixo lê as duas pontas.
#
# Escopo das docs: os quatro arquivos desta área de cuja escrita este gate pode
# cobrar (`deploy/ROLLBACK.md`, `COOLIFY.md`, `OPS_RUNBOOK.md`, `LAUNCH_HANDOFF.md`).
# `BACKUP_RUNBOOK.md` e `STAGING.md` têm outros donos — a régua não põe fogo no portão
# por texto de outra posse, mas continua conferindo o compose inteiro.
built_services = sorted(svc for svc, _ctx, _df in builds)
ROLLBACK_DOCS = ["deploy/ROLLBACK.md", "deploy/COOLIFY.md", "deploy/OPS_RUNBOOK.md",
                 "deploy/LAUNCH_HANDOFF.md"]


def fenced_blocks(text):
    """Blocos ``` ... ``` — é o que o operator cola. Prosa fica fora de propósito: a
    própria doc precisa NOMEAR o comando que ela proíbe (`docker compose pull game`
    está escrita lá para dizer que não funciona), e régua que lê a proibição como
    instrução é régua que se auto-acusa."""
    out, cur = [], None
    for line in text.splitlines():
        if line.strip().startswith("```"):
            if cur is None:
                cur = []
            else:
                out.append("\n".join(cur))
                cur = None
            continue
        if cur is not None:
            cur.append(line)
    return out


def headings(text):
    return [l.strip() for l in text.splitlines() if re.match(r'^#{2,4}\s', l)]


for doc in ROLLBACK_DOCS:
    text = open(doc).read() if os.path.exists(doc) else ""
    check(bool(text), "%s: existe e foi lido pelo gate de rollback" % doc,
          "arquivo presente na árvore", "ausente ou vazio")
    if not text:
        continue
    blocks = fenced_blocks(text)
    # (i) nenhum bloco manda puxar o que o compose builda.
    bad_pull = []
    for i, b in enumerate(blocks, 1):
        for m in re.finditer(r'docker\s+compose[^\n]*?\bpull\b([^\n]*)', b):
            for svc in re.findall(r'\b(%s)\b' % "|".join(built_services), m.group(1)):
                bad_pull.append("bloco #%d: pull %s" % (i, svc))
    check(not bad_pull,
          "%s: nenhum bloco de comando manda `pull` de serviço que o compose builda (%s)"
          % (doc, " ".join(built_services)),
          "nenhum — não há registry: os serviços buildados declaram `pull_policy: never` (deploy/ROLLBACK.md, \"Artefato versionado\")",
          "; ".join(bad_pull) if bad_pull else "-")
    # (ii) todo bloco que MUDA o que roda (build / up -d) de um serviço versionado é
    # acompanhado do knob que dá nome ao artefato. Sem isso o bloco produz um deploy
    # sem alvo de rollback — o estado que a doc existe para evitar.
    unpinned = []
    for i, b in enumerate(blocks, 1):
        if not re.search(r'docker\s+compose[^\n]*\b(build|up)\b', b):
            continue
        svcs = sorted(set(re.findall(r'\b(%s)\b' % "|".join(built_services), b)))
        if not svcs:
            continue
        if "SHAMBLETA_TAG" not in b:
            unpinned.append("bloco #%d (%s)" % (i, ",".join(svcs)))
    check(not unpinned,
          "%s: bloco que builda/sobe serviço versionado nomeia o artefato com SHAMBLETA_TAG" % doc,
          "`export SHAMBLETA_TAG=<sha>` no mesmo bloco (ou o `--no-build` do deploy pinado)",
          "; ".join(unpinned) if unpinned else "-")

# (iii) as seções que o operador procura no meio do incêndio têm de EXISTIR. Uma doc
# de deploy sem seção de rollback é o buraco, não um detalhe de formatação.
roll_doc = open("deploy/ROLLBACK.md").read() if os.path.exists("deploy/ROLLBACK.md") else ""
cool_doc = open("deploy/COOLIFY.md").read() if os.path.exists("deploy/COOLIFY.md") else ""
for label, text in (("deploy/ROLLBACK.md", roll_doc), ("deploy/COOLIFY.md", cool_doc)):
    hs = headings(text)
    check(any(re.search(r'rollback|voltar atrás', h, re.I) for h in hs),
          "%s: tem seção de rollback em cabeçalho (procurável no meio do incêndio)" % label,
          "um `## ... Rollback ...`", "cabeçalhos: %s" % (" | ".join(hs[:8]) or "-"))
check(any(re.search(r'fronteira|forward-only', h, re.I) for h in headings(roll_doc)),
      "deploy/ROLLBACK.md: declara a fronteira do schema em seção própria (binário volta, schema não)",
      "um cabeçalho com \"fronteira\" ou \"forward-only\"", "ausente")
check(any(re.search(r'morra no meio|meio caminho|pela metade', h, re.I) for h in headings(roll_doc)),
      "deploy/ROLLBACK.md: tem seção para deploy/build interrompido e para migration meia-aplicada",
      "dois cabeçalhos (deploy no meio + migration pela metade)", "ausente")

# (iv) contradição doc x código: a doc não pode negar uma série que o server emite.
# O guard é o código — se a série sair do MetricsServer a frase volta a ser verdade e
# a régua deixa de acusar. É por isto que ela olha a fonte, não uma lista de frases.
metrics_src = open("sources/system/MetricsServer.gd").read() if os.path.exists("sources/system/MetricsServer.gd") else ""
emits_mutex = "shambleta_sql_query_mutex_waits" in metrics_src
denies = []
for d in ["deploy/ROLLBACK.md", "deploy/OPS_RUNBOOK.md", "deploy/COOLIFY.md",
          "deploy/SCALING.md", "docs/development/testing.md"]:
    t = open(d).read() if os.path.exists(d) else ""
    if re.search(r'[Nn]ão existe métrica de espera do .{0,2}queryMutex|nenhum .{0,2}/metrics. o expõe', t):
        denies.append(d)
check(not (emits_mutex and denies),
      "nenhuma doc nega a métrica de espera da `queryMutex` que o /metrics emite",
      "a série `shambleta_sql_query_mutex_waits`/`_wait_seconds`/`_wait_over_100ms` tratada como existente (emitida por sources/system/MetricsServer.gd, paginada por deploy/alerts.rules.yml)",
      "negações em: %s" % ", ".join(denies) if (emits_mutex and denies)
      else "ok (server %s a série)" % ("emite" if emits_mutex else "NÃO emite — régua dormente"))

# (v) a CI pisa o tag: um `docker compose build` sem SHAMBLETA_TAG produz
# `local-unpinned`, exatamente o estado que a doc manda o operador recusar.
tagless = []
for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        steps = (job or {}).get("steps") or []
        if not any(re.search(r'docker\s+compose[^\n]*\b(build|config)\b', code_of(str(s.get("run") or "")))
                   for s in steps):
            continue
        envs = dict((job or {}).get("env") or {})
        for s in steps:
            envs.update(s.get("env") or {})
        inline = any("SHAMBLETA_TAG" in str(s.get("run") or "") for s in steps)
        if "SHAMBLETA_TAG" not in envs and not inline:
            tagless.append("%s/%s" % (os.path.basename(path), name))
check(not tagless,
      "todo job que roda `docker compose build|config` define SHAMBLETA_TAG (senão o artefato não tem nome)",
      "`env: SHAMBLETA_TAG: ...` no job/step, ou o knob no comando",
      "; ".join(tagless) if tagless else "-")

print("== CI GATE: %d checks, %d failures ==" % (checks, failures))
sys.exit(0 if failures == 0 else min(failures, 125))
PYEOF
