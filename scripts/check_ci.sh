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
# M6..M10 (findings #83/#84/#89, 2026-09-29) deixaram de ser mutação manual: os
# canários C0..C10 no fim deste arquivo plantam a recaída numa CÓPIA dos workflows
# (mktemp + `SHAMBLETA_WF_DIR`/`SHAMBLETA_DOCKERFILE`, com corte de recursão por
# `SHAMBLETA_CI_NO_CANARY`) e rodam este mesmo script contra ela, exigindo falha
# vermelha que nomeie a regra que pegou o mutante. C0 confere que o override não muda o veredito da árvore
# real, e um `replace` cuja âncora sumiu é denunciado como canário cego — não como
# verde.
# M1 só passou a existir porque a primeira versão da regra procurava `exit 1` no
# texto do step, e o comentário do step cita `exit 1`: o gate ficou VERDE com a
# guarda arrancada. Régua lendo prosa não é régua — daí `code_of()` e o
# `all_wf_raw` descomentado. A armadilha é a mesma que já tinha derrubado a régua
# M1 do gate idle (`docs/development/testing.md`).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
# Diretório de workflows e Dockerfile web são sobrescrevíveis SÓ para os canários
# abaixo: uma régua de grafo que não pode ser apontada para uma cópia mutada não é
# provável de estar viva, é só provável de estar verde. A árvore real nunca é
# mutada por este script — os canários copiam, escrevem em $(mktemp -d) e cobram a
# própria falha. Nada aqui muda o comportamento de quem roda sem o env.
WDIR="${SHAMBLETA_WF_DIR:-.github/workflows}"
SELF="$ROOT/scripts/check_ci.sh"

[ -d "$WDIR" ] || { echo "[FAIL] não encontrei $WDIR"; echo "== CI GATE: 1 checks, 1 failures =="; exit 1; }
$PY -c 'import yaml' 2>/dev/null || {
	echo "[FAIL] python3 + PyYAML indisponíveis — sem eles este gate não lê YAML."
	echo "       (instale python3-yaml; o gate de compose tem a mesma exigência)"
	echo "== CI GATE: 1 checks, 1 failures =="
	exit 1
}

"$PY" - "$WDIR" "$SELF" <<'PYEOF'
import os, re, sys, glob, yaml, subprocess, tempfile, shutil

wdir = sys.argv[1]
self_path = sys.argv[2] if len(sys.argv) > 2 else "scripts/check_ci.sh"
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

# ---------------------------------------------------------------- o que é teste, o que é publicação
# As duas classes abaixo decidem se um job pode ir ao ar, então as duas são lidas
# do CÓDIGO EXECUTÁVEL do job (linhas de `run` descomentadas + `uses:`), nunca do
# texto do workflow: a armadilha M1 deste arquivo é exatamente uma régua que achou
# `exit 1` dentro do comentário que explicava o `exit 1` que tinha sido arrancado.
def code_of(text):
    # Régua que lê comentário é régua que acredita no que o autor escreveu: a
    # primeira versão desta procurava `exit 1` no texto do step, e o rationale do
    # próprio step cita `exit 1` — o gate ficou verde com a guarda arrancada
    # (provado por mutação em 2026-09-27). Aqui só linha executável conta.
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


# Publicar = botar artefato fora do CI: store, release, registry, endpoint de
# deploy. Detectado pelo `uses:`/comando do passo, não pelo nome do job (um job
# chamado `snap` que só empacota não vai ao ar; um chamado `misc` que roda
# `action-publish` vai).
PUBLISH_RE = re.compile(r"(snapcore/action-publish|softprops/action-gh-release|actions/deploy-pages"
                        r"|/api/v1/deploy|docker\s+push|aws\s+s3\s+cp|gh\s+release\s+create)")
# Rodar teste = exercer a suíte, não exportar nem buildar. `scripts/test.sh` é a
# porta local, `ci_gate_log.sh` o quádruplo de §24-8, `-s tests/` o harness de
# Godot e `pytest`/`gate_py` as suítes do companion. Um job que só `--export-release`
# não está aqui, e é exatamente por isso que `needs: builds` nunca foi gate.
TEST_RE = re.compile(r"(scripts/test\.sh|ci_gate_log\.sh|godot[^\n]*\s-s\s+tests/|\bpytest\b|gate_py)")


def job_code(doc, name):
    job = (doc.get("jobs") or {}).get(name) or {}
    parts = []
    for step in job.get("steps") or []:
        parts.append(code_of(str(step.get("run") or "")))
        parts.append(str(step.get("uses") or ""))
    return "\n".join(parts)


def runs_tests(doc, name):
    return bool(TEST_RE.search(job_code(doc, name)))


def publishes(doc, name):
    return bool(PUBLISH_RE.search(job_code(doc, name)))


def tests_in_closure(doc, name):
    """Jobs que RODAM TESTES dentro do fecho transitivo de `needs` de `name`."""
    return sorted(j for j in closure(doc, name) if runs_tests(doc, j))


# ---------------------------------------------------------------- finding #83: quem publica
# precisa do fecho de needs de um job que roda teste de verdade
# O defeito medido: `snap` (godot-ci.yml) publicava `release: edge` no push à master
# com `needs: builds` — um job de export, sem um teste dentro — e a régua antiga
# achava isso suficiente porque aceitava QUALQUER `needs` como gate. "Tem needs" não
# é a pergunta; a pergunta é se o que tem antes de publicar MEDIR ALGO.
for path, doc in docs.items():
    for name in (doc.get("jobs") or {}):
        if not publishes(doc, name):
            continue
        trig = triggers(doc)
        raw = "\n".join(l for l in open(path).read().splitlines() if not l.lstrip().startswith("#"))
        wf_guarded = ("workflow_run" in yaml.dump(trig)) and re.search(
            r"workflow_run\.conclusion\s*==\s*'success'", raw)
        tested = tests_in_closure(doc, name)
        ok = bool(tested) or bool(wf_guarded)
        check(ok,
              "%s/%s: publica lá fora, então o fecho transitivo de `needs` tem de conter um job que rode testes"
              % (os.path.basename(path), name),
              "`needs:` (direto ou transitivo) apontando para um job com scripts/test.sh | ci_gate_log.sh | godot -s tests/ | pytest; ou workflow disparado por workflow_run com conclusão conferida",
              "fecho=%s; jobs de teste no fecho=%s" % (", ".join(sorted(closure(doc, name))) or "vazio",
                                                       ", ".join(tested) or "nenhum"))

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
        # Finding #83, metade credencial: `bool(needs)` era a régua que deixava
        # `snap: needs: builds` passar como "gated". Um segredo de store atrás de um
        # needs sem teste é a mesma publicação com testes vermelhos, agora com
        # credencial. A pergunta passa a ser a mesma de cima: o fecho roda teste?
        tested = tests_in_closure(doc, name)
        gated = bool(tested) or "success()" in job_if
        workflow_guarded = ("workflow_run" in yaml.dump(trig)) and re.search(
            r"workflow_run\.conclusion\s*==\s*'success'", raw)
        check(gated or bool(workflow_guarded),
              "%s/%s: usa credencial externa, então precisa de gate com teste antes de rodar"
              % (os.path.basename(path), name),
              "`needs:` transitivo alcançando um job que roda testes, ou `if:` com success(), ou workflow disparado por workflow_run com conclusão conferida",
              "needs=%s testes-no-fecho=%s if=%r trigger=%s" % (needs_list(job or {}) or "-",
                                                                ", ".join(tested) or "nenhum",
                                                                job_if or "-",
                                                                ",".join(k for k in (trig or {}) if k != "secrets") or "-"))

# ---------------------------------------------------------------- finding #84: release assinado
# com a debug key do Android não é release assinado por nós
# Medido em 2026-09-29: release.yml exportava o preset Android com `--export-release`
# e apontava os três knobs de assinatura para `/root/debug.keystore`,
# `androiddebugkey`, `android` — o par de chaves de debug do Android, que está no
# AOSP e que qualquer pessoa que clone este repo regenera byte a byte. O APK sai
# "de release" e é assinado por ninguém. A régua vale para todo job que roda
# `--export-release` mexendo no Android; o job de `--export-debug` da godot-ci fica
# de fora de propósito (ali debug é o que se pede, e não vai loja nenhuma).
DEBUG_KEY_RE = re.compile(r"(debug\.keystore|androiddebugkey|storepass\s+android\b|keypass\s+android\b)")
KS_KNOB_RE = re.compile(r"^GODOT_ANDROID_KEYSTORE_RELEASE_(PATH|USER|PASSWORD)$")
KS_INLINE_RE = re.compile(r'GODOT_ANDROID_KEYSTORE_RELEASE_(PATH|USER|PASSWORD)=["\']?([^"\'\s;]*)')
KS_GUARD_RE = re.compile(r'if \[ -z "\$\{?([A-Za-z0-9_]*KEYSTORE[A-Za-z0-9_]*)\}?"(.*?)\]; then(.*?)\n[ \t]*fi', re.S)

for path, doc in docs.items():
    for name, job in (doc.get("jobs") or {}).items():
        code = job_code(doc, name)
        if "--export-release" not in code:
            continue
        touches_android = ("GODOT_ANDROID_KEYSTORE_RELEASE" in code
                           or "Android" in yaml.dump(job))
        if not touches_android:
            continue
        label = "%s/%s: exporta RELEASE do Android" % (os.path.basename(path), name)
        debug_hits = sorted({m.group(0) for m in DEBUG_KEY_RE.finditer(code)})
        check(not debug_hits,
              "%s: nenhuma referência à chave de debug do Android em linha executável" % label,
              "nenhum `debug.keystore`/`androiddebugkey`/`storepass android` — a debug key é pública (AOSP) e assinar release com ela equivale a não assinar",
              ", ".join(debug_hits))
        # Os três knobs podem vir do `env:` de um step (dict, lido como dado) ou de
        # uma atribuição inline no `run` (export). Um `env:` montado como texto teria
        # o dict repr numa linha só e leria o valor do PATH como sobra de linha — é
        # por isso que aqui o YAML parseado é consultado como estrutura.
        ks_vals = {}
        for s in (job or {}).get("steps") or []:
            for k, v in ((s.get("env") or {}) or {}).items():
                m = KS_KNOB_RE.match(str(k))
                if m:
                    ks_vals[m.group(1)] = str(v).strip()
            for m in KS_INLINE_RE.finditer(code_of(str(s.get("run") or ""))):
                ks_vals.setdefault(m.group(1), m.group(2))
        for knob in ("PATH", "USER", "PASSWORD"):
            val = ks_vals.get(knob)
            if val is None:
                # Sem o knob o Godot cai no default do preset; em release é
                # exatamente o silêncio que gerou o defeito.
                check(False, "%s: declara GODOT_ANDROID_KEYSTORE_RELEASE_%s" % (label, knob),
                      "o knob declarado com valor vindo de secret/env", "ausente no job")
                continue
            from_expr = val.startswith("${{") and ("secrets." in val or "env." in val)
            check(from_expr,
                  "%s: GODOT_ANDROID_KEYSTORE_RELEASE_%s vem de secret (ou de um env escrito por um guarda), nunca de literal" % (label, knob),
                  "`${{ secrets.… }}` ou `${{ env.… }}` exportado por um passo que falha sem o secret",
                  "valor literal no workflow (%d caracteres, não impresso)" % len(val))
        guards = [m for m in KS_GUARD_RE.finditer(code)]
        armed = [m for m in guards if "exit 1" in m.group(3)]
        check(bool(armed),
              "%s: o job FALHA quando o secret do keystore falta (sem fallback)" % label,
              "um `if [ -z \"$…KEYSTORE…\" ]; then … exit 1 … fi` em linha executável",
              "guardas encontradas=%d, com exit 1=%d" % (len(guards), len(armed)))

# ---------------------------------------------------------------- finding #89: o nginx.conf tem
# de ser validado pelo nginx, em algum lugar que rode
# O par defeito/mentira medido: `deploy/web/Dockerfile` fazia `COPY deploy/web/nginx.conf`
# sem `nginx -t`, e `tests/nginx_hardening_test.gd:570-574`, quando não havia binário
# no host, passava a GREPAR no próprio conf a frase que diz que a validação é de build.
# Ou seja: o harness virou leitor de documentação, e o verde significava "o arquivo
# afirma que alguém valida" — ninguém validava. O fecho tem duas metades, e as duas
# são código:
#   (a) o build da imagem roda `nginx -t` (uma imagem que existe foi validada);
#   (b) a CI tem um job/step que roda `nginx -t` na IMAGEM BUILDADA, não no host —
#       é a única parte que sobrevive a um runner sem nginx e é por isso que a
#       ausência de binário local é SKIP NOMEADO, nunca `[ok]`.
def command_code(code):
    # Linha que só IMPRIME texto não executa nada. Sem este filtro, um passo cujo
    # `echo "::error::…"` cite a própria commanda pelo nome engana a régua: foi o
    # que aconteceu com a de `nginx -t` (a mensagem de erro do passo contém a
    # frase) e o canário C6 ficou verde com o `-t` arrancado. O filtro é aplicado
    # SÓ onde a frase é uma palavra de comando; a detecção de publicação/deploy lê
    # inclusive URLs dentro de aspas (staging.yml), e por isso não passa por aqui.
    return "\n".join(l for l in code.splitlines()
                     if not re.match(r'^(echo|printf|print|console\.log)\b', l.strip()))


DOCKERFILE_WEB = os.environ.get("SHAMBLETA_DOCKERFILE", "deploy/web/Dockerfile")
df_text = open(DOCKERFILE_WEB).read() if os.path.exists(DOCKERFILE_WEB) else ""
df_code = code_of(df_text)
check(bool(df_text), "%s: existe para a régua de validação do nginx" % DOCKERFILE_WEB,
      "arquivo presente", "ausente")
check(bool(re.search(r"RUN[^\n]*\bnginx\b[^\n]*\s--?(t|test)\b", df_code)),
      "%s: o build valida o conf com `nginx -t` (COPY sem validação = deploy que quebrar no boot)" % DOCKERFILE_WEB,
      "uma linha `RUN nginx -t` executável", "nenhuma")
nginx_validators = []
for path, doc in docs.items():
    for name in (doc.get("jobs") or {}):
        code = command_code(job_code(doc, name))
        # `-t` pode vir depois de argumentos (a imagem entra entre o binário e a
        # flag: `nginx "shambleta/web:tag" -t`). Exigir o par nginx+flag NA LINHA
        # do comando, não colados: foi a regex colada que deixou o passo real da
        # CI invisível até o canário C6 denunciar o eco.
        if re.search(r"\bnginx\b[^\n]*\s--?(t|test)\b", code):
            nginx_validators.append((os.path.basename(path), name, "shambleta/web" in code))
check(bool(nginx_validators),
      "um job da CI roda `nginx -t` (linha executável, não prosa de doc)",
      "job com step cujo `run` execute nginx -t", "nenhum job valida o nginx.conf")
check(any(v[2] for v in nginx_validators),
      "a validação `nginx -t` é feita DENTRO da imagem web buildada (shambleta/web), não no binário do host",
      "um step referenciando a imagem `shambleta/web`",
      "validadores: %s" % (", ".join("%s/%s" % (w, j) for w, j, _ in nginx_validators) or "nenhum"))
# A mentira da metade (a): o harness não pode voltar a transformar o próprio conf em
# prova. A régua lê o CÓDIGO do harness e recusa `_check(` cuja condição procure a
# frase do doc — o que ficou no lugar é SKIP nomeado + a estrutura acima.
hard_src = open("tests/nginx_hardening_test.gd").read() if os.path.exists("tests/nginx_hardening_test.gd") else ""
hard_code = code_of(hard_src)


def doc_grep_hits(code_text):
    """O detector da mentira #89, em função própria para o canário poder exercitá-lo
    sem que alguém precise committar um harness que mente de volta."""
    return [l.strip() for l in code_text.splitlines()
            if "_check(" in l and "VALIDADO ONDE" in l]


def skip_accounted(code_text):
    return ("[SKIP]" in code_text) and ("SKIPS" in code_text)


check(not doc_grep_hits(hard_code),
      "tests/nginx_hardening_test.gd: nenhum `_check(` valida o conf grepando a frase do próprio doc (#89)",
      "nenhuma asserção dependendo de `VALIDADO ONDE`",
      "linha(s): %s" % (doc_grep_hits(hard_code)[0][:80] if doc_grep_hits(hard_code) else "-"))
check(skip_accounted(hard_code),
      "tests/nginx_hardening_test.gd: skip de `nginx -t` é contabilizado por nome (não é [ok] silencioso)",
      "um `[SKIP]` impresso e uma linha de contabilidade `SKIPS`", "nenhuma contabilidade de skip")

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
# (`code_of` vive logo acima da seção #83: as duas réguas de grafo e esta leem o
# mesmo texto executável, e cópia de função é a primeira fonte de divergência.)
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

# ------------------------------------------------- canários: régua que não morre num
# mutante é régua que não existe
# Zero falhas não prova que as réguas acima estão vivas — prova que nada foi mutado.
# Este bloco copia os workflows para um diretório temporário, planta a recaída de
# cada finding na CÓPIA, roda este mesmo script apontado para ela
# (`SHAMBLETA_WF_DIR`, com `SHAMBLETA_CI_NO_CANARY=1` cortando a recursão) e exige
# que o veredito do mutante seja VERMELHO nomeando a regra que o pegou. A árvore
# real não é tocada: nada aqui escreve em `.github/`, e o canário de identidade
# abaixo confere justamente que o run aninhado sem mutação devolve o MESMO número
# deste run — se o env fizesse a régua ler outra coisa, ele denunciaria.
if os.environ.get("SHAMBLETA_CI_NO_CANARY") != "1":
    def gate_in(env_extra):
        env = dict(os.environ)
        env["SHAMBLETA_CI_NO_CANARY"] = "1"
        env["PY"] = sys.executable
        env.update(env_extra)
        try:
            p = subprocess.run(["bash", self_path], env=env,
                               capture_output=True, text=True, timeout=300)
        except Exception as err:
            return "", (0, -2), -9
        out = p.stdout + p.stderr
        m = re.search(r"^== CI GATE: (\d+) checks, (\d+) failures ==$", out, re.M)
        return out, ((int(m.group(1)), int(m.group(2))) if m else (0, -1)), p.returncode

    # (C0) identidade: o override não muda o veredito da árvore real
    _out, _cnt, _rc = gate_in({})
    check(_cnt == (checks, failures),
          "canário C0: o run aninhado sem mutação devolve o mesmo veredito (%d checks, %d falhas)"
          % (checks, failures),
          "verdict idêntico ao deste run", "aninhado=%s rc=%s" % (str(_cnt), _rc))

    wf_files = {os.path.basename(p): raws[p] for p in raws}

    def mutant(label, expect, wf_mut=None, dockerfile=None):
        tmp = tempfile.mkdtemp(prefix="shambleta-ci-canary-")
        try:
            changed = False
            for fname, txt in wf_files.items():
                new = wf_mut(fname, txt) if wf_mut else txt
                changed = changed or (new != txt)
                with open(os.path.join(tmp, fname), "w") as fh:
                    fh.write(new)
            if dockerfile is not None:
                changed = changed or (dockerfile != _df)
            # Sem isto o canário morre mudo: um `replace` cuja âncora mudou de
            # grafia deixa de mutar, o veredito do "mutante" fica verde e a régua
            # é declarada morta por um texto que nunca existiu. A âncora é conferida
            # antes de qualquer asserção sobre o veredito.
            if not changed:
                check(False, "canário %s: a mutação foi APLICADA" % label,
                      "o texto do mutante diferir da árvore",
                      "nenhuma âncora casou — o canário está cego")
                return
            env_extra = {}
            if wf_mut:
                env_extra["SHAMBLETA_WF_DIR"] = tmp
            if dockerfile is not None:
                dpath = os.path.join(tmp, "Dockerfile.web")
                with open(dpath, "w") as fh:
                    fh.write(dockerfile)
                env_extra["SHAMBLETA_DOCKERFILE"] = dpath
            out, cnt, rc = gate_in(env_extra)
            caught = expect in out
            check(cnt[1] > 0 and caught,
                  "canário %s: o mutante é REPROVADO por uma falha vermelha" % label,
                  "falhas>0 e a regra %r na saída" % expect,
                  "falhas=%d rc=%s regra-o-denunciou=%s" % (cnt[1], rc, "sim" if caught else "NÃO"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def _set_needs(base, old, new):
        return base.replace(old, new, 1)

    # (C1) #83: `snap` voltando a precisar só do export, com a prosa de teste ao lado
    mutant(
        "C1 (snap -> needs: builds, e um comentário citando scripts/test.sh no builds)",
        "godot-ci.yml/snap: publica lá fora",
        wf_mut=lambda f, t: (t.replace(
            "    needs:\n      - builds\n      - test-gate\n", "    needs: builds\n", 1)
            .replace("          apt-get install -y libfontconfig1 unzip",
                     "          # scripts/test.sh all  <-- só prosa: não pode virar gate", 1)
            if f == "godot-ci.yml" else t))
    # (C2) #83: GitHub Release sem teste no fecho
    mutant(
        "C2 (release.yml/release -> needs: builds)",
        "release.yml/release: publica lá fora",
        wf_mut=lambda f, t: (t.replace(
            "    needs:\n      - builds\n      - tests\n", "    needs: builds\n", 1)
            if f == "release.yml" else t))
    # (C3) #84: a debug key de volta no export de release
    mutant(
        "C3 (keystore de debug voltando no --export-release)",
        "nenhuma referência à chave de debug do Android",
        wf_mut=lambda f, t: (t.replace(
            "GODOT_ANDROID_KEYSTORE_RELEASE_PATH: ${{ env.ANDROID_RELEASE_KEYSTORE }}",
            "GODOT_ANDROID_KEYSTORE_RELEASE_PATH: /root/debug.keystore", 1).replace(
            "GODOT_ANDROID_KEYSTORE_RELEASE_USER: ${{ env.ANDROID_RELEASE_KEYSTORE_ALIAS }}",
            "GODOT_ANDROID_KEYSTORE_RELEASE_USER: androiddebugkey", 1)
            if f == "release.yml" else t))
    # (C4) #84: guarda invertida — o job passa a FALHAR quando o secret existe
    mutant(
        "C4 (guarda `-z` virando `-n`: o exit 1 continua lá, a condição não)",
        "o job FALHA quando o secret do keystore falta",
        wf_mut=lambda f, t: (t.replace(
            'if [ -z "$RELEASE_KEYSTORE_BASE64" ]', 'if [ -n "$RELEASE_KEYSTORE_BASE64" ]', 1)
            if f == "release.yml" else t))
    # (C5) #84: knob vindo de literal em vez de secret
    mutant(
        "C5 (GODOT_ANDROID_KEYSTORE_RELEASE_PATH literial)",
        "vem de secret (ou de um env escrito por um guarda)",
        wf_mut=lambda f, t: (t.replace(
            "GODOT_ANDROID_KEYSTORE_RELEASE_PATH: ${{ env.ANDROID_RELEASE_KEYSTORE }}",
            "GODOT_ANDROID_KEYSTORE_RELEASE_PATH: /tmp/keystore-release.keystore", 1)
            if f == "release.yml" else t))
    # (C6) #89: arrancar o `-t` do step que valida a imagem (o step continua lá,
    # levantando nginx — é exatamente a forma de "smoke que não smoke-a")
    mutant(
        "C6 (step de validação presente mas sem `nginx -t`)",
        "um job da CI roda `nginx -t`",
        wf_mut=lambda f, t: (t.replace('" -t; then', '" ; then', 1)
                             if f == "godot-ci.yml" else t))
    # (C7) #89: Dockerfile voltando a ser COPY puro
    _df = open("deploy/web/Dockerfile").read() if os.path.exists("deploy/web/Dockerfile") else ""
    mutant(
        "C7 (Dockerfile sem `RUN nginx -t`)",
        "o build valida o conf com `nginx -t`",
        dockerfile="\n".join(l for l in _df.splitlines() if l.strip() != "RUN nginx -t"))
    # (C8) #89: o harness voltando a grepár a frase do próprio doc — em processo,
    # porque a recaída mora no texto do harness e a árvore não pode ser mutada aqui.
    _velho = '_check(text.contains("nginx -t") and text.contains("VALIDADO ONDE"),'
    check(len(doc_grep_hits(_velho)) == 1 and not doc_grep_hits(hard_code),
          "canário C8: o detector da doc-grep pega a linha velha (#89) e poupa o harness de hoje",
          "1 hit no texto plantado, 0 no arquivo real",
          "plantado=%d real=%d" % (len(doc_grep_hits(_velho)), len(doc_grep_hits(hard_code))))
    check(skip_accounted(hard_code) and not skip_accounted('print("  [ok] nada medido")'),
          "canário C9: a contabilidade de skip é exigida só quando há skip nomeado no código",
          "verdadeiro no harness atual, falso num harness sem skip", "-")
    # (C10) classificador de "roda teste" não lê prosa, e o de "publica" não dorme
    _syn = {"jobs": {"comento": {"steps": [{"run": "# bash scripts/test.sh all\necho nada\n"}]},
                     "rodo": {"steps": [{"run": "bash scripts/test.sh structure\n"}]},
                     "publico": {"steps": [{"uses": "snapcore/action-publish@v1"}]}}}
    check(not runs_tests(_syn, "comento") and runs_tests(_syn, "rodo")
          and publishes(_syn, "publico") and not publishes(_syn, "rodo"),
          "canário C10: TEST_RE/PUBLISH_RE só enxergam código executável (comentário citando test.sh não vira gate)",
          "comento=False rodo=True publico=True rodo-publica=False", "classificador cego ou crédulo")

print("== CI GATE: %d checks, %d failures ==" % (checks, failures))
sys.exit(0 if failures == 0 else min(failures, 125))
PYEOF
