#!/usr/bin/env bash
# Gate de compose — lê o YAML e confere contra o CÓDIGO, não contra o doc.
#
# Existe porque as quatro lacunas de deploy desta área eram todas da mesma
# família: o compose afirmava uma coisa que o código (ou o bom senso) não
# sustentava — backup dentro do volume do banco, healthcheck do `web` que não
# conseguia falhar, porta de probe que nenhum processo escuta, serviço sem
# `restart`. Isso não se resolve com review; se resolve com um portão que quebra
# com diff claro.
#
# Uso:   bash scripts/check_compose.sh          # ou ./scripts/check_compose.sh
# Saída: uma linha por regra ([PASS]/[FAIL] com ESPERADO/ENCONTRADO, mais [SKIP]
#        com MOTIVO para cada fumaça externa que esta máquina não pode rodar) e, no
#        fim, `== COMPOSE GATE: N checks, M failures == (validação: …; fumaça:
#        N rodaram, N falharam, N pulados)` — o `== COMPOSE GATE: N checks, M
#        failures ==` é o formato que
#        scripts/ci_gate_log.sh:42 lê, então o script entra no gate §24-8 pela
#        mesma porta de scripts/check_god_nodes.sh:
#            gate_sh /tmp/shambleta-compose.log "== COMPOSE GATE:" scripts/check_compose.sh
#        Exit code = nº de falhas.
#
# Caminho de validação: usa `docker compose config` quando o binário existe
# (é a forma canônica — deploy/STAGING.md:72), senão valida o YAML com
# `yaml.safe_load` + mesclagem emulada (merge de `volumes` por alvo de montagem,
# que é a regra do Compose Spec). Os asserts são os mesmos nos dois caminhos; o
# caminho usado é impresso no cabeçalho.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROD="deploy/docker-compose.yml"
STG="deploy/docker-compose.staging.yml"
PY="${PYTHON:-python3}"

for f in "$PROD" "$STG"; do
	[ -r "$f" ] || { echo "[FAIL] não encontrei $f (o gate lê os dois arquivos)"; echo "== COMPOSE GATE: 1 checks, 1 failures =="; exit 1; }
done

$PY -c 'import yaml' 2>/dev/null || {
	echo "[FAIL] python3 + PyYAML indisponíveis — sem eles o fallback não valida nada."
	echo "       (instale python3-yaml, ou rode onde exista o binário docker compose)"
	echo "== COMPOSE GATE: 1 checks, 1 failures =="
	exit 1
}

# `docker compose config` é oráculo de resolução quando existe: ele decide merge
# de override, nomes de volume e interpolação de ${VAR:-default}. Sem binário, o
# python abaixo emula o merge (e diz que emulou).
COMPOSE_BIN=""
docker compose version >/dev/null 2>&1 && COMPOSE_BIN="docker compose"
[ -z "$COMPOSE_BIN" ] && command -v docker-compose >/dev/null 2>&1 && COMPOSE_BIN="docker-compose"

# ---------------------------------------------------------------- fumaça externa
# Duas ferramentas valem mais que qualquer asserção minha sobre YAML: `docker
# compose config` (o parser real, que é o que o `up` vai comer) e `amtool
# check-config` (o validador real do schema do Alertmanager). Nenhuma das duas é
# obrigatória nesta máquina — e é justamente aí que mora o defeito que este bloco
# existe para matar: um smoke que não rodou e não disse nada é indistinguível de
# um smoke que passou. Todo veredito externo vai para um arquivo TSV que o python
# replays por `check()`: falha entra na contagem e no exit code, e ausência vira
# `[SKIP]` com o MOTIVO impresso e contado na última linha.
SMOKE="$(mktemp)"
printf '' > "$SMOKE"
smoke() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$SMOKE"; }
on_smoke_exit() { [ -n "${SMOKE:-}" ] && rm -f "$SMOKE"; }
trap on_smoke_exit EXIT

RESOLVED_PROD=""
RESOLVED_MERGED=""
if [ -n "$COMPOSE_BIN" ]; then
	RESOLVED_PROD="$(mktemp)"; RESOLVED_MERGED="$(mktemp)"
	if ! $COMPOSE_BIN -p shamgate -f "$PROD" config > "$RESOLVED_PROD" 2>"$RESOLVED_PROD.err"; then
		echo "[FAIL] \`$COMPOSE_BIN -f $PROD config\` não resolveu:"; sed 's/^/       /' "$RESOLVED_PROD.err"
		echo "== COMPOSE GATE: 1 checks, 1 failures =="; exit 1
	fi
	smoke pass "smoke: \`$COMPOSE_BIN -f $PROD config\` resolveu (produção)" \
		"o parser real aceitando o arquivo que o \`up\` vai ler" "exit 0"
	if ! $COMPOSE_BIN -p shamgatestg -f "$PROD" -f "$STG" config > "$RESOLVED_MERGED" 2>"$RESOLVED_MERGED.err"; then
		echo "[FAIL] \`$COMPOSE_BIN -f $PROD -f $STG config\` não resolveu:"; sed 's/^/       /' "$RESOLVED_MERGED.err"
		echo "== COMPOSE GATE: 1 checks, 1 failures =="; exit 1
	fi
	smoke pass "smoke: \`$COMPOSE_BIN -f $PROD -f $STG config\` resolveu (base+staging mesclados)" \
		"o parser real aceitando a mesclagem" "exit 0"
else
	smoke skip "smoke: \`docker compose config\` nos dois arquivos" \
		"binário docker/compose ausente nesta máquina — o gate caiu no fallback yaml.safe_load + merge emulado, que NÃO é o parser do \`up\`" ""
fi

# `amtool check-config`: o schema do Alertmanager é maior que o YAML. Uma rota com
# chave errada parseia lindo e é rejeitada pelo binário no boot — container em
# crash-loop com "config válido" no review. Ordem de tentativa: binário no PATH,
# depois o `/bin/amtool` da própria imagem (a base do prom/alertmanager é busybox
# e o Dockerfile upstream copia o binário — ver deploy/monitoring/alertmanager.Dockerfile),
# e só então o motivo escrito.
AMCFG="deploy/alertmanager.yml"
AMIMAGE="prom/alertmanager:v0.34.1"
verdict() { # $1=saída captured; decide pass/fail/skip pelo veredito do próprio amtool
	local out="$1"
	if printf '%s' "$out" | grep -q 'FAILED'; then
		smoke fail "smoke: \`amtool check-config $AMCFG\`" \
			"o validador do schema aceitando o config (SUCCESS)" \
			"$(printf '%s' "$out" | tr '\t\n' '  ' | cut -c1-300)"
	elif printf '%s' "$out" | grep -q 'SUCCESS'; then
		smoke pass "smoke: \`amtool check-config $AMCFG\`" \
			"o validador do schema aceitando o config" "SUCCESS"
	else
		smoke skip "smoke: \`amtool check-config $AMCFG\`" \
			"amtool indisponível aqui (sem binário no PATH e sem docker/daemon para rodar $AMIMAGE): $(printf '%s' "$out" | tr '\t\n' '  ' | cut -c1-160)" ""
	fi
}
if command -v amtool >/dev/null 2>&1; then
	verdict "$(amtool check-config "$AMCFG" 2>&1)"
elif ! command -v docker >/dev/null 2>&1; then
	verdict "sem amtool no PATH e sem binário docker"
elif ! docker info >/dev/null 2>&1; then
	verdict "docker instalado mas sem daemon acessível (runner sem docker-in-docker)"
else
	verdict "$(docker run --rm --entrypoint /bin/amtool -v "$PWD:/cfg:ro" "$AMIMAGE" \
		check-config "/cfg/$AMCFG" 2>&1)"
fi

COMPOSE_BIN="$COMPOSE_BIN" RESOLVED_PROD="$RESOLVED_PROD" RESOLVED_MERGED="$RESOLVED_MERGED" \
SMOKE="$SMOKE" \
PY="$PY" "$PY" - "$PROD" "$STG" <<'PYEOF'
import glob, os, re, subprocess, sys, yaml

prod_path, stg_path = sys.argv[1], sys.argv[2]
resolved_prod = os.environ.get("RESOLVED_PROD") or ""
resolved_merged = os.environ.get("RESOLVED_MERGED") or ""
mode = "docker compose config (canônico)" if resolved_prod else "yaml.safe_load + merge emulado"

checks = 0
failures = 0

def check(ok, title, expected, found):
    global checks, failures
    checks += 1
    if ok:
        print("[PASS] %s" % title)
        return
    # Um log que imprime `[PASS]` e `[FAIL]` na mesma regra é duas coisas: o
    # `ci_gate_log.sh` ainda conta os falhos, mas quem lê o log a olho vê um
    # veredito que o run não tem. A contagem de checks continua a mesma.
    failures += 1
    print("[FAIL] %s" % title)
    print("       ESPERADO: %s" % expected)
    print("       ENCONTRADO: %s" % found)

# ------------------------------------------------------------------ fumaça: replay
# O bloco bash acima escreve um veredito por ferramenta externa neste TSV, e o
# `trap` apaga o arquivo na saída. Este é o único leitor: sem ele, o veredito do
# parser real e do `amtool` nunca chega a log nem a contagem, e o gate recai no
# defeito que o bloco existe para matar — um smoke que não rodou indistinguível
# de um que passou. Por isso o próprio replay é vigiado: TSV ausente, vazio, com
# linha malformada ou sem veredito das duas ferramentas é ACUSAÇÃO, não silêncio.
SMOKE_PATH = os.environ.get("SMOKE") or ""
smoke_rows, smoke_bad = [], []
if SMOKE_PATH and os.path.exists(SMOKE_PATH):
    with open(SMOKE_PATH) as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            cols = raw.split("\t")
            if len(cols) < 4 or cols[0] not in ("pass", "fail", "skip") or not cols[1].strip():
                smoke_bad.append(raw.replace("\t", " | ")[:200])
                continue
            smoke_rows.append(cols[:4])
check(bool(SMOKE_PATH) and not smoke_bad and len(smoke_rows) >= 2,
      "a fumaça externa entregou veredito estruturado para cada ferramenta que tentou",
      "TSV legível com >= 2 linhas nos quatro campos (compose config + amtool)",
      ("TSV %r não existe" % SMOKE_PATH) if not SMOKE_PATH or not os.path.exists(SMOKE_PATH)
      else ("linhas malformadas: %s" % "; ".join(smoke_bad) if smoke_bad
            else "só %d vereditos: %s" % (len(smoke_rows), ", ".join(r[1] for r in smoke_rows))))
smoke_ran = smoke_failed = smoke_skipped = 0
for verdict, title, expected, found in smoke_rows:
    if verdict == "skip":
        # Pular é visível: conta como check, imprime o MOTIVO e nunca vira falha —
        # a máquina não tem o binário, e fingir falha aqui trocaria uma mentira por
        # outra (um gate vermelho por ambiente também é um gate que ninguém conserta).
        smoke_skipped += 1
        checks += 1
        print("[SKIP] %s" % title)
        print("       MOTIVO: %s" % (found.strip() or expected))
        continue
    smoke_ran += 1
    if verdict == "fail":
        smoke_failed += 1
    check(verdict == "pass", title, expected, found)

def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh) or {}

def interp(value):
    """${NAME:-default} -> default (é o que `compose config` faz com env ausente)."""
    if not isinstance(value, str):
        return value
    m = re.match(r'^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}$', value)
    return m.group(1) if m else value

def norm_mount(m):
    """'src:dst[:ro]' ou {type/source/target} -> (source, target)."""
    if isinstance(m, dict):
        return (str(m.get("source", "")), str(m.get("target", "")))
    parts = str(m).split(":")
    if len(parts) >= 2:
        return (parts[0], parts[1])
    return ("", parts[0])

def mounts_by_target(svc):
    out = {}
    for m in (svc or {}).get("volumes") or []:
        src, dst = norm_mount(m)
        out[dst] = src
    return out

def merge_list_by_target(base, over):
    """Merge do Compose Spec para `volumes`: por alvo de montagem."""
    out = {}
    for m in base or []:
        src, dst = norm_mount(m)
        out[dst] = src
    for m in over or []:
        src, dst = norm_mount(m)
        out[dst] = src
    return ["%s:%s" % (s, d) if s else d for d, s in out.items()]

def env_pairs(env):
    """environment como lista OU como mapa -> lista 'K=V' (as duas formas são válidas)."""
    out = []
    if isinstance(env, dict):
        out += ["%s=%s" % (k, v) for k, v in env.items()]
    elif isinstance(env, list):
        out += [e for e in env if isinstance(e, str)]
    return out

def merge_env(base, over):
    out = {}
    for e in env_pairs(base) + env_pairs(over):
        if "=" in e:
            k, v = e.split("=", 1)
            out[k] = v
    return out

def merge(a, b):
    """Override deep-merge; `volumes` por alvo, `environment` por chave, resto substitui."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            if k == "volumes":
                out[k] = merge_list_by_target(a.get("volumes"), v)
            elif k == "environment":
                out[k] = merge_env(a.get("environment"), v)
            else:
                out[k] = merge(a.get(k), v) if k in a else v
        return out
    return b

def env_map(svc):
    env = (svc or {}).get("environment") or {}
    if isinstance(env, list):
        out = {}
        for e in env:
            if isinstance(e, str) and "=" in e:
                k, v = e.split("=", 1); out[k] = v
        return out
    return dict(env)

def hc_test(svc):
    hc = (svc or {}).get("healthcheck") or {}
    t = hc.get("test")
    if isinstance(t, list):
        return " ".join(str(x) for x in t)
    return str(t or "")

def hc_port(svc):
    url = re.search(r'(https?://[^\s"\']+)', hc_test(svc))
    if not url:
        return None
    hostport = url.group(1).split("//", 1)[1]
    m = re.search(r':(\d{2,5})', hostport)
    if m:
        return m.group(1)
    return "443" if url.group(1).startswith("https") else "80"

DUR_UNIT = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0, "m": 60.0, "h": 3600.0}


def seconds(v):
    # `docker compose config` — o validador canônico, que é o que roda onde há
    # docker — imprime duração na forma que o daemon aceita, e `75` sai de lá como
    # `1m15s`. Uma régua que só sabe ler o número que ela mesma escreveu devolve
    # "ausente" para um knob correto: no run de 2026-09-29 as duas leituras de
    # `stop_grace_period` fecharam vermelhas com `stop_grace_period='1m15s'`
    # contra um `>= 68s`, enquanto o mesmo compose lido por `yaml.safe_load` (o
    # caminho sem docker, desta máquina) lia 75 e passava. `None` é acusação,
    # nunca 0: 0 passaria em `>= 0` e é exatamente como um healthcheck fictício
    # nasce.
    if v is None:
        return None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    s = str(v).strip()
    if not s:
        return None
    if re.match(r'^-?\d+(?:\.\d+)?$', s):
        return float(s)
    total = 0.0
    rest = s
    while rest:
        m = re.match(r'^(\d+(?:\.\d+)?)(ns|us|ms|s|m|h)', rest)
        if not m:
            return None
        total += float(m.group(1)) * DUR_UNIT[m.group(2)]
        rest = rest[m.end():]
    return total

def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return ""

# --- portas que EXISTEM no código (nada de lista manual: deriva dos arquivos) ---
port_origins = {}
def note_port(port, origin):
    port_origins.setdefault(str(port), []).append(origin)

for root, dirs, files in os.walk("sources"):
    dirs[:] = [d for d in dirs if d not in (".godot", "bin")]
    for fn in files:
        if not fn.endswith(".gd"):
            continue
        p = os.path.join(root, fn)
        for i, line in enumerate(read(p).splitlines(), 1):
            # `const ...Port... : int = N` (sources/network/NetworkCommons.gd:5-6) e
            # `static var ...Port... : int = N` (mesmo arquivo:12-13) — as duas
            # formas são usadas no projeto.
            m = re.search(r'(?:const|static var)\s+([A-Za-z0-9_]*Port[A-Za-z0-9_]*)\s*:\s*int\s*=\s*(\d+)', line)
            if m:
                note_port(m.group(2), "%s:%d (%s)" % (p, i, m.group(1)))
for p, pat in (("companion/server.py", r'add_argument\("--port",\s*type=int,\s*default=(\d+)'),
               ("deploy/companion/Dockerfile", r'EXPOSE\s+(\d+)'),
               ("deploy/companion/Dockerfile", r'"--port",\s*"(\d+)"'),
               ("deploy/server/Dockerfile", r'EXPOSE\s+(\d+)'),
               ("deploy/web/nginx.conf", r'listen\s+(\d+)'),
               ("deploy/web/nginx.conf", r'http://companion:(\d+)')):
    for i, line in enumerate(read(p).splitlines(), 1):
        for m in re.finditer(pat, line):
            note_port(m.group(1), "%s:%d" % (p, i))

prod_doc = load(prod_path)
stg_doc = load(stg_path)
prod = (load(resolved_prod) if resolved_prod else prod_doc) or {}
merged = (load(resolved_merged) if resolved_merged else merge(prod_doc, stg_doc)) or {}
stg_services = (stg_doc.get("services") or {})
prod_services = (prod.get("services") or {})
merged_services = (merged.get("services") or {})

def named_volume_ok(source, doc):
    """Volume 'nomeado' = não-bind, não-anônimo: sem caminho e declarado em volumes:."""
    if not source:
        return False
    if source.startswith(".") or source.startswith("/") or source.startswith("~"):
        return False
    if len(source) >= 2 and source[1] == ":":  # id de volume anônimo (hex) montado sem nome
        return False
    declared = doc.get("volumes") or {}
    base = re.sub(r'^[a-z0-9]+_', "", source)  # `compose config` prefixa com o projeto
    return base in declared or source in declared

# --- portas que os próprios services declaram no command (Prometheus/Alertmanager) ---
# `--web.listen-address=:9090` É a porta que aquele processo escuta; ela existe
# porque a linha existe no arquivo que o compose roda. Sem isto, o healthcheck do
# `prometheus` aponta para uma porta que o gate não conhece e o check (c) vira
# falso-positivo — que foi exatamente a falha encontrada na primeira rodada deste
# gate (9090 não estava em lugar nenhum da lista derivada). Precisa rodar ANTES
# do laço (a)/(b)/(c) abaixo, senão a porta é registrada depois de conferida.
for p in (prod_path, stg_path):
    for i, line in enumerate(read(p).splitlines(), 1):
        for m in re.finditer(r'--web\.listen-address=:(\d{2,5})', line):
            note_port(m.group(1), "%s:%d (--web.listen-address)" % (p, i))

STATEFUL = ("/data", "/data-backups")

for label, doc, services in (("produção", prod, prod_services),
                             ("mesclado(base+staging)", merged, merged_services)):
    # (a) persistência: todo caminho de estado tem volume nomeado, declarado no arquivo.
    for svc in ("game", "companion"):
        m = mounts_by_target(services.get(svc))
        src = m.get("/data", "")
        check(named_volume_ok(src, doc),
              "%s/%s: live.db vive em volume nomeado (senão rebuild = estado perdido)" % (label, svc),
              "volumes: <volume>:/data com <volume> declarado no bloco volumes: do arquivo",
              "volumes=%s" % (services.get(svc, {}).get("volumes") or "ausentes"))
    # paridade game/companion: o grant tem de entrar no banco que o jogo abre.
    g = mounts_by_target(services.get("game")).get("/data")
    c = mounts_by_target(services.get("companion")).get("/data")
    check(bool(g) and g == c, "%s: game e companion montam o MESMO /data" % label,
          "game./data == companion./data", "game=%s companion=%s" % (g or "-", c or "-"))

    # (b) restart em todo serviço (sem ele, um OOM/crash fica morto até alguém olhar).
    for name, svc in sorted(services.items()):
        r = (svc or {}).get("restart")
        check(bool(r) and r != "no", "%s/%s: tem restart" % (label, name),
              "restart: unless-stopped (ou on-failure/always)", "restart=%r" % (r,))

    # (c) healthcheck: porta existe no código, e os três serviços que o operator
    # olha têm probe. cloudflared é a exceção declarada (imagem sem shell/wget).
    for name, svc in sorted(services.items()):
        port = hc_port(svc)
        if port is None:
            if name in ("game", "companion", "web"):
                check(False, "%s/%s: tem healthcheck com URL" % (label, name),
                      "healthcheck.test apontando para http://<host>:<porta>/...",
                      "test=%r" % hc_test(svc))
            continue
        check(port in port_origins,
              "%s/%s: porta do healthcheck (%s) é uma porta que algum processo escuta" % (label, name, port),
              "porta declarada no código — conhecidas: %s" % " ".join("%s(%s)" % (p, port_origins[p][0]) for p in sorted(port_origins)),
              "nenhuma das portas declaradas em sources/**/*.gd, companion/server.py, EXPOSE/listen dos Dockerfiles e nginx.conf bate com %s" % port)
    for name in ("game", "companion", "web"):
        check(bool(hc_port(services.get(name))),
              "%s/%s: healthcheck presente" % (label, name),
              "probe próprio (web = shell servido, game = /healthz:9400, companion = /health:8901)",
              "sem healthcheck resolvido")

# staging: volume próprio (não o da produção) e volume de backup próprio.
stg_data = mounts_by_target(stg_services.get("game")).get("/data")
check(bool(stg_data) and stg_data != mounts_by_target(prod_services.get("game")).get("/data"),
      "staging: /data do game não é o volume da produção",
      "game-data-staging:/data", "staging=/data -> %r" % (stg_data or "-",))

# (4) backup separado do banco, com o env apontando para o destino montado.
for label, services, doc in (("produção", prod_services, prod), ("mesclado", merged_services, merged)):
    m = mounts_by_target(services.get("game"))
    data, backup = m.get("/data"), m.get("/data-backups")
    check(bool(backup) and named_volume_ok(backup, doc),
          "%s: game: backup em volume nomeado /data-backups" % label,
          "<volume>:/data-backups declarado em volumes: — sql-backups/ nasce dentro de user:// (sources/sql/SQLCommons.gd:8 + sources/system/Path.gd:55), então sem este mount o histórico morre junto com o banco",
          "volumes=%s" % (services.get("game", {}).get("volumes") or "-"))
    check(bool(backup) and backup != data, "%s: volume de backup != volume do banco" % label,
          "fontes diferentes", "data=%r backups=%r" % (data or "-", backup or "-"))
    offsite = interp(env_map(services.get("game")).get("SHAMBLETA_OFFSITE_BACKUPS", ""))
    check(offsite == "/data-backups", "%s: SHAMBLETA_OFFSITE_BACKUPS aponta para o mount do backup" % label,
          "/data-backups (vazio desliga o push: sources/sql/SQLBackups.gd:37-38 lê GetOffsiteBackupPath)",
          "%r" % (offsite,))

# (3) ordem de boot: banco de pé antes da frente do dinheiro e antes do site.
for label, services in (("produção", prod_services), ("mesclado", merged_services)):
    dep = ((services.get("companion") or {}).get("depends_on") or {})
    cond = dep.get("game") if isinstance(dep, dict) else None
    cond = cond.get("condition") if isinstance(cond, dict) else None
    check(cond == "service_healthy", "%s: companion espera o game healthy" % label,
          "depends_on.game.condition: service_healthy (o companion sai com exit 2 se live.db não existe — companion/server.py:2032-2034)",
          "%r" % (cond,))
    wdep = ((services.get("web") or {}).get("depends_on") or {})
    wcond = wdep.get("game") if isinstance(wdep, dict) else None
    wcond = wcond.get("condition") if isinstance(wcond, dict) else None
    check(wcond == "service_healthy", "%s: web espera o game healthy" % label,
          "depends_on.game.condition: service_healthy", "%r" % (wcond,))

# (3) stop_grace_period compatível com o drain + join do worker de backup.
canary_src = read("sources/world/ShutdownCanary.gd")
block = re.search(r'shutdownDelays[^=]*=\s*\[([^\]]*)\]', canary_src)
delays = [float(x) for x in re.findall(r'[\d.]+', block.group(1))] if block else []
join = int(re.search(r'BackupCheckIntervalSec\s*:\s*int\s*=\s*(\d+)',
                     read("sources/sql/SQLCommons.gd")).group(1))
drain = sum(delays)
for label, services in (("produção", prod_services), ("mesclado", merged_services)):
    grace = seconds((services.get("game") or {}).get("stop_grace_period"))
    check(grace is not None and grace >= drain + join,
          "%s: game stop_grace_period cobre o drain do canary" % label,
          ">= %.0fs (sources/world/ShutdownCanary.gd:10-13 soma %s) + %ds de join do worker (sources/sql/SQLCommons.gd:10)" % (drain + join, delays, join),
          "stop_grace_period=%r" % ((services.get("game") or {}).get("stop_grace_period"),))

# caminhos: o que o companion abre TEM de ser o user:// do game com HOME=/data.
def grab(rx, path):
    m = re.search(rx, read(path))
    return m.group(1) if m else ""

db_name = grab(r'const\s+DBName\s*:\s*String\s*=\s*"([^"]+)"', "sources/sql/SQLCommons.gd")
user_dir = grab(r'config/custom_user_dir_name="([^"]+)"', "project.godot")
home = grab(r'ENV\s+HOME=(\S+)', "deploy/server/Dockerfile")
xdg = re.search(r'ENV\s+XDG_DATA_HOME', read("deploy/server/Dockerfile"))
expected_db = "%s/.local/share/%s/%s" % (home, user_dir, db_name)
found_db = grab(r'"--db",\s*"([^"]+)"', "deploy/companion/Dockerfile")
game_mount = mounts_by_target(prod_services.get("game")).get("/data")
check(bool(db_name) and bool(user_dir) and bool(home),
      "o gate leu as constantes de caminho (SQLCommons.DBName, custom_user_dir_name, ENV HOME)",
      "as três regex casando", "DBName=%r user_dir=%r HOME=%r" % (db_name, user_dir, home))
check(found_db == expected_db and xdg is None,
      "CMD do companion abre o live.db no user:// que HOME=/data produz",
      "%s (e nenhum ENV XDG_DATA_HOME em deploy/server/Dockerfile — com ele o layout muda: OS.get_data_dir() passa a ser $XDG_DATA_HOME/%s, medido em tests/deploy_ops_test.gd)" % (expected_db, user_dir),
      "--db %r" % (found_db,))
check(bool(found_db) and found_db.startswith("/data/"),
      "o banco que o companion abre está dentro do volume montado (/data)",
      "caminho sob /data", "--db %r, game monta %r em /data" % (found_db, game_mount))

# (as portas `--web.listen-address` já foram registradas antes do laço (a)/(b)/(c))
def svc_ports(svc):
    """Portas que um serviço declara escutar: healthcheck + command."""
    out = set()
    hp = hc_port(svc)
    if hp:
        out.add(hp)
    cmd = (svc or {}).get("command")
    lines = cmd if isinstance(cmd, list) else ([str(cmd)] if cmd else [])
    for entry in lines:
        m = re.search(r'--web\.listen-address=:?(\d{2,5})', str(entry))
        if m:
            out.add(m.group(1))
    return out

# (6) Observação — o leitor de `deploy/alerts.rules.yml`.
# Existe porque as regras foram escritas antes de existir quem as avaliasse: regra
# sem evaluator não é alerta quebrado, é alerta absurdo (dispara nunca, e "sem
# incêndio" é indistinguível de "ninguém olhando"). Os checks abaixo amarram as
# três pontas: o config embarcado referencia o arquivo de regras, todo alvo de
# scrape é uma porta que algum processo escuta num serviço declarado, e o
# alerting service existe.
prom_path = "deploy/prometheus.yml"
am_path = "deploy/alertmanager.yml"
prom_df_path = "deploy/monitoring/prometheus.Dockerfile"
prom_doc = None
try:
    prom_doc = yaml.safe_load(read(prom_path))
except Exception as e:
    prom_doc = None
    print("[FAIL] %s não parseia como YAML: %s" % (prom_path, e))
check(isinstance(prom_doc, dict) and bool(prom_doc),
      "%s: parseia como YAML (é o --config.file do serviço prometheus)" % prom_path,
      "um mapping YAML legível", "ok" if prom_doc else "parse falhou ou vazio")

rule_files = (prom_doc or {}).get("rule_files") or []
prom_df = read(prom_df_path)
check(bool(rule_files), "%s: declara rule_files — sem evaluator as regras não disparam" % prom_path,
      "rule_files: [ /etc/prometheus/<arquivo> ]", "rule_files=%r" % (rule_files,))
for rf in rule_files:
    base = os.path.basename(str(rf))
    repo = "deploy/" + base
    copied = [ln.strip() for ln in prom_df.splitlines()
              if ln.strip().upper().startswith("COPY") and repo in ln.split()[-2:]]
    check(os.path.isfile(repo) and bool(copied),
          "%s: %s é embarcado por %s (bind-mount de host não viaja no release)" % (prom_path, repo, prom_df_path),
          "uma linha `COPY %s %s` no Dockerfile" % (repo, rf),
          "COPY encontrada: %s; arquivo no repo: %s" % (copied or "-", os.path.isfile(repo)))

# as regras em si: severidade declarada em cada alerta (é o que a rota do
# alertmanager usa para decidir quem acorda).
rules_doc = None
try:
    rules_doc = yaml.safe_load(read("deploy/alerts.rules.yml"))
except Exception as e:
    print("[FAIL] deploy/alerts.rules.yml não parseia como YAML: %s" % e)
severities, no_sev = set(), []
for grp in (rules_doc or {}).get("groups") or []:
    for rule in grp.get("rules") or []:
        sev = ((rule.get("labels") or {}).get("severity") or "")
        if sev:
            severities.add(sev)
        else:
            no_sev.append(str(rule.get("alert", "?")))
check(bool(severities) and not no_sev,
      "deploy/alerts.rules.yml: todo alerta tem labels.severity (%s)" % " ".join(sorted(severities)),
      "severity em 100% das regras", "sem severity: %s" % (no_sev or "-"))

# alertmanager: serviço declarado + rotas batendo com as severidades das regras.
for label, services in (("produção", prod_services), ("mesclado", merged_services)):
    for name in ("prometheus", "alertmanager"):
        check(bool(services.get(name)), "%s: o serviço `%s` está declarado" % (label, name),
              "bloco `%s:` em services:" % name, "ausente")

am_doc = None
try:
    am_doc = yaml.safe_load(read(am_path))
except Exception as e:
    print("[FAIL] %s não parseia como YAML: %s" % (am_path, e))
route = (am_doc or {}).get("route") or {}
receivers = {r.get("name") for r in (am_doc or {}).get("receivers") or []}
routed = set()
for sub in route.get("routes") or []:
    sev = (sub.get("match") or {}).get("severity") or ""
    if sev:
        routed.add(sev)
    check(sub.get("receiver") in receivers,
          "%s: rota severity=%s aponta para um receiver declarado" % (am_path, sev or "-"),
          "receiver existente em receivers:", "receiver=%r" % (sub.get("receiver"),))
check(route.get("receiver") in receivers,
      "%s: o receiver default (%r) existe" % (am_path, route.get("receiver")),
      "declarado em receivers:", "receivers=%s" % sorted(x for x in receivers if x))
for sev in sorted(severities):
    check(sev in routed,
          "%s: a severidade %r usada em alerts.rules.yml tem rota própria" % (am_path, sev),
          "uma routes[].match.severity == %r" % sev, "rotas=%s" % sorted(routed))

# alvos de scrape e de alerting: host = serviço declarado, porta = escutada.
def target_ok(label, job, target, services, doc_services):
    host, _, port = str(target).rpartition(":")
    if not port.isdigit():
        check(False, "%s [%s/%s]: alvo %r tem porta numérica" % (prom_path, label, job, target),
              "<host>:<porta>", str(target))
        return
    known = ", ".join("%s(%s)" % (p, port_origins[p][0]) for p in sorted(port_origins))
    check(port in port_origins,
          "%s [%s/%s]: porta do alvo %s é uma porta que algum processo escuta" % (prom_path, label, job, target),
          "porta declarada no código/Dockerfiles/compose — conhecidas: %s" % known,
          "nada bate com %s" % port)
    if host in ("127.0.0.1", "localhost"):
        owners = [n for n, s in doc_services.items() if port in svc_ports(s)]
        if "prometheus" in owners:
            return
        pm_mode = str((services.get("prometheus") or {}).get("network_mode") or "")
        check(any(pm_mode == "service:" + o for o in owners),
              "%s [%s/%s]: alvo de loopback %s só alcança o %s se o scraper compartilha o namespace dele" % (prom_path, label, job, target, owners or "?"),
              "network_mode: service:<dono da porta> no serviço prometheus",
              "network_mode=%r; donos da porta=%s" % (pm_mode or "-", owners or "-"))
    else:
        check(host in doc_services,
              "%s [%s/%s]: host do alvo %s é um serviço declarado no compose" % (prom_path, label, job, target),
              "serviço `%s:` existe em services:" % host, "ausente")
        if host in doc_services:
            check(port in svc_ports(doc_services[host]),
                  "%s [%s/%s]: porta do alvo %s bate com o que o serviço `%s` escuta" % (prom_path, label, job, target, host),
                  "healthcheck/porta do comando de `%s`" % host,
                  "svc_ports=%s" % sorted(svc_ports(doc_services[host])))

jobs = (prom_doc or {}).get("scrape_configs") or []
check(bool(jobs), "%s: declara scrape_configs" % prom_path, "pelo menos um job", "jobs=%d" % len(jobs))
for job in jobs:
    name = str(job.get("job_name", "?"))
    targets = []
    for sc in job.get("static_configs") or []:
        targets += sc.get("targets") or []
    check(bool(targets), "%s: job `%s` tem alvo de scrape" % (prom_path, name),
          "static_configs[].targets[] não vazio", "-")
    for label, services in (("produção", prod_services), ("mesclado", merged_services)):
        for t in targets:
            target_ok(label, name, t, services, services)

# alerting: para onde o alerta vai tem de ser o serviço declarado.
atargets = []
alerting = (prom_doc or {}).get("alerting") or {}
for entry in (alerting.get("alertmanagers") if isinstance(alerting, dict) else alerting) or []:
    for sc in (entry or {}).get("static_configs") or []:
        atargets += sc.get("targets") or []
check(bool(atargets), "%s: declara alerting.alertmanagers (senão a regra avalia e não conta a ninguém)" % prom_path,
      "um target de alertmanager", "targets=%s" % (atargets or "-"))
for t in atargets:
    target_ok("produção", "alerting", t, prod_services, prod_services)

# (7) Contexto de build — o `.dockerignore` da RAÍZ é o único que o daemon lê, e
# os Dockerfiles fazem `COPY . .`. Medido aqui, e medido contra o ÍNDICE: num clone
# limpo — que é o que a CI builda — índice e árvore são o mesmo conjunto, e nesta
# máquina não são. A régua antiga (`contexto cai pelo menos 25%`) lia a árvore e por
# isso era verde aqui, vermelha na CI: os 25% que ela cobrava são a sujeira de quem
# rodou (`.godot` 70 MB de cache de import, `build/` 92 MB, areia `.test-*` 70 MB,
# `graphify-out` 11 MB — os ~243 MB que o check de leak abaixo soma e que nenhum
# clone tem), não o efeito do arquivo. Sobre o que está rastreado o efeito é de um
# punhado de porcento: os 226 MB de que o export precisa (addons 143 + data 61 +
# presets 22) têm de continuar dentro, e o par exato é o que as linhas abaixo
# imprimem — um número copiado aqui envelhece com o tamanho do que está rastreado.
# O que se cobra do arquivo, então, é a função dele e não um percentual: cada classe
# de dirt coberta pelo caminho como o Docker o lê, nada do que o build embarca
# excluído, e o contexto que sobe abaixo de um teto medido. A armadilha de semântica
# está na linha 14 (padrão sem `/` interno casa só no nível raiz): a linha
# `__pycache__` nunca pegou `tools/__pycache__/*.pyc`, que está nesta máquina e que
# nenhum gate via — DIRT é a lista das classes, um caminho por classe.
before_bytes = before_files = after_bytes = after_files = 0
leaks = []
def di_matcher(text):
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        neg = s.startswith("!")
        pat = s.lstrip("!").strip().strip("/")
        if not pat:
            continue
        segs = []
        for part in pat.split("/"):
            if part == "**":
                segs.append(".*")
            else:
                segs.append("".join("[^/]*" if c == "*" else ("[^/]" if c == "?" else re.escape(c)) for c in part))
        out.append((neg, re.compile("^" + "/".join(segs) + "$")))
    return out

DIPAT = di_matcher(read(".dockerignore"))
def is_ignored(rel):
    verdict = False
    parts = rel.split("/")
    for i in range(1, len(parts) + 1):
        probe = "/".join(parts[:i])
        for neg, rx in DIPAT:
            if rx.match(probe):
                verdict = not neg
    return verdict

# O índice é o contexto de um clone limpo — o que a CI builda. Medido por
# `git ls-files`, nunca por lista manual.
INDEX = set()
tracked_bytes = tracked_files = ship_bytes = ship_files = 0
git_err = ""
try:
    _r = subprocess.run(["git", "ls-files", "-z"], capture_output=True)
    _paths = [x.decode("utf-8", "replace") for x in _r.stdout.split(b"\0") if x]
    if _r.returncode != 0 or not _paths:
        git_err = "saiu com código %d e %d caminhos" % (_r.returncode, len(_paths))
    INDEX = set(_paths)
except OSError as exc:
    git_err = "git indisponível (%s)" % exc
for p in sorted(INDEX):
    try:
        sz = os.path.getsize(p)
    except OSError:
        continue
    tracked_bytes += sz
    tracked_files += 1
    if not is_ignored(p):
        ship_bytes += sz
        ship_files += 1

for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d != ".git"]
    for fn in files:
        p = os.path.relpath(os.path.join(root, fn), ".")
        try:
            sz = os.path.getsize(p)
        except OSError:
            continue
        before_bytes += sz
        before_files += 1
        if not is_ignored(p):
            after_bytes += sz
            after_files += 1
            if p not in INDEX:
                leaks.append((p, sz))

# Teto: o índice congelado na expressão ao nascer esta régua (230.725.456) mais a
# mesma folga de 25% do gate de teardown (data/conf/teardown_baseline.txt). Não é a
# régua de performance — é o alarme de "alguém commitou um binário": os 226 MB que
# o export precisa já estão contados aqui, e nada mais tem 8 zeros de crescimento
# legítimo.
SHIP_CEILING = 230725456 + 230725456 // 4

# Uma classe de dirt por caminho: três são arquivos reais medidos nesta máquina
# (`tools/__pycache__/*.pyc`, `companion/__pycache__/*.pyc`, `.godot/*.cfg`), o resto
# nomeia a classe onde só o prefixo importa (`tmp/x`). Percentual não é régua nunca.
DIRT = [
    ".git/config", ".github/workflows/godot-ci.yml", ".editorconfig", ".qoder/settings.json",
    ".godot/global_script_class_cache.cfg", "build/Web/libgdsqlite.web.template_release.wasm32.wasm",
    ".test-home/IdleTests/.booting", ".test-home2/data/Shambleta/logs/godot.log",
    ".test-k8/IdleTests/.booting", "logs/godot.log", "tmp/x", ".tmp/x", "testing.db-wal",
    "run.log", "server.pem", "server.crt", "server.key", ".env",
    "tests/perf_fix_test.gd", "test_scratch.gd", "scripts/census.gd", "e.autotest-entity",
    "graphify-out/2026-09-24/cost.json", "snap/snapcraft.yaml", "archive/SEASONS_GAP.md",
    "designs/x", "publishing/x", "landing_new/x",
    "__pycache__/x.pyc", "companion/__pycache__/server.cpython-314.pyc",
    "tools/__pycache__/extract_i18n.cpython-314.pyc", ".pytest_cache/x", ".venv/x", ".idea/x",
    "README.md", "docs/contracts/why.md", "docs/quality/why.md", "node_modules/left-pad/index.js",
]
uncovered = [p for p in DIRT if not is_ignored(p)]

shipped = ("addons", "data", "presets", "sources", "project.godot", "export_presets.cfg",
           "companion/server.py", "deploy/web/nginx.conf", "deploy/prometheus.yml",
           "deploy/alerts.rules.yml", "docs")
ignored_top = [p for p in shipped if is_ignored(p)]
check(os.path.isfile(".dockerignore"), ".dockerignore existe na raiz do contexto",
      "o único lugar que o daemon lê (o contexto é a raiz — `build.context: ..` visto de deploy/)", "ausente")
check(not git_err and tracked_files > 0,
      "o índice do git foi lido (%d caminhos, %d bytes)" % (tracked_files, tracked_bytes),
      "`git ls-files -z` devolvendo caminhos — é o contexto de um clone limpo",
      git_err or "índice lido")
check(tracked_files > 0 and ship_bytes < tracked_bytes,
      "contexto medido no ÍNDICE: %d bytes/%d arquivos SEM .dockerignore -> %d bytes/%d arquivos com ele (-%.2f%%)" % (
          tracked_bytes, tracked_files, ship_bytes, ship_files,
          100.0 * (tracked_bytes - ship_bytes) / max(tracked_bytes, 1)),
      "o arquivo tira bytes reais do que está rastreado (o número impresso aqui é a prova)",
      "antes=%d depois=%d" % (tracked_bytes, ship_bytes))
check(ship_files > 0 and ship_bytes <= SHIP_CEILING,
      "contexto que sobe para o daemon cabe o teto medido (%d bytes <= %d)" % (ship_bytes, SHIP_CEILING),
      "<= medido + 25%% — crescimento de contexto é re-medido de propósito, nunca de carona",
      "%d bytes em %d arquivos (%.0f%% do teto)" % (ship_bytes, ship_files, 100.0 * ship_bytes / SHIP_CEILING))
check(not uncovered,
      "cada classe de dirt está coberta pelo .dockerignore (%d caminhos, %d classes)" % (len(DIRT), len(set(p.split("/")[0] for p in DIRT))),
      "todos os caminhos de DIRT excluídos pelo .dockerignore como o Docker os lê",
      "não cobertos: %s" % " ".join(uncovered))
check(not leaks,
      "nenhum arquivo fora do índice escapa do .dockerignore e sobe para o daemon (%d arquivos/%d bytes na árvore a mais que o índice)" % (
          before_files - tracked_files, max(before_bytes - tracked_bytes, 0)),
      "zero leak: o que a máquina tem a mais que o clone fica fora do contexto",
      "sobem: %s" % " ".join("%s (%d B)" % (p, sz) for p, sz in leaks[:8]))
check(not ignored_top, "nada do que o build embarca é excluído pelo .dockerignore",
      "nenhum destes fora: %s" % " ".join(shipped), "excluídos: %s" % " ".join(ignored_top))
print("[INFO] árvore de trabalho desta máquina (medida, não é régua — um clone limpo "
      "não tem nada disto): %d bytes/%d arquivos -> %d bytes/%d com o .dockerignore (-%.1f%%)" % (
          before_bytes, before_files, after_bytes, after_files,
          100.0 * (before_bytes - after_bytes) / max(before_bytes, 1)))

# todo COPY explícito dos Dockerfiles precisa sobreviver ao ignore.
copy_missing = []
for df in ("deploy/server/Dockerfile", "deploy/web/Dockerfile", "deploy/companion/Dockerfile",
           prom_df_path, "deploy/monitoring/alertmanager.Dockerfile"):
    for i, line in enumerate(read(df).splitlines(), 1):
        s = line.strip()
        if not s.upper().startswith(("COPY", "ADD")):
            continue
        args = [a for a in s.split()[1:] if not a.startswith("--")]
        if len(args) < 2 or "--from=" in s:
            continue
        src = args[0]
        if src in (".", "./") or "://" in src or "$" in src:
            continue
        rel = src.rstrip("/")
        if not os.path.exists(rel):
            copy_missing.append("%s:%d copia %s, que não existe" % (df, i, src))
        elif is_ignored(rel):
            copy_missing.append("%s:%d copia %s, que o .dockerignore exclui" % (df, i, src))
check(not copy_missing, "todo COPY explícito dos Dockerfiles existe e não é excluído",
      "nenhum COPY apontando para caminho ausente ou ignorado",
      "; ".join(copy_missing) if copy_missing else "COPYs conferidos")

# (8) Artefato versionado — o alvo do rollback. Um serviço com `build:` e sem
# `image:` não tem o que voltar: `docker compose up -d` reconstroi o fonte
# corrente e o "rollback" escrito em deploy/ROLLBACK.md vira prosa. A régua lê o
# YAML BRUTO (não o resolvido) porque o que importa é a forma do knob: imagem
# nomeada por serviço, tag vinda de UMA variável (o knob do release,
# `SHAMBLETA_TAG`), default que não é `latest` — tag mutável não endereça build
# nenhum — e `pull_policy: never`, já que não existe registry: `pull` num serviço
# buildado ou dá 404 no Docker Hub ou finge que baixou versão. Os cinco serviços
# buildados de hoje (web, game, companion, prometheus, alertmanager) são o chão
# da contagem; um serviço novo que nasça sem imagem cai aqui, não num 3h da manhã.
raw_services = (prod_doc.get("services") or {}) if isinstance(prod_doc, dict) else {}
built_names = sorted(n for n, s in raw_services.items()
                     if isinstance(s, dict) and s.get("build"))
check(len(built_names) >= 5,
      "rollback: o gate identificou %d serviços buildados pelo compose (%s)" % (
          len(built_names), " ".join(built_names)),
      "ao menos os cinco de hoje: alertmanager companion game prometheus web",
      "nenhum serviço com `build:` — ou o parse falhou, ou o stack foi reescrito")
UNPINNED_TAG = "local-unpinned"
TAG_VAR = "SHAMBLETA_TAG"
IMG_RX = re.compile(r'^([a-z0-9._-]+(?:/[a-z0-9._-]+)+):\$\{([A-Z0-9_]+):-([a-zA-Z0-9._-]+)\}$')
for svc in built_names:
    spec = raw_services.get(svc) or {}
    img = str(spec.get("image") or "")
    m = IMG_RX.match(img)
    check(bool(m), "rollback/%s: serviço buildado declara imagem versionável" % svc,
          "`image: shambleta/%s:${%s:-%s}` (deploy/ROLLBACK.md \"Artefato versionado\")" % (svc, TAG_VAR, UNPINNED_TAG),
          "image=%s" % (("ausente" if not img else "não-parseável: %r" % img)))
    if not m:
        continue
    repo, var, default = m.group(1), m.group(2), m.group(3)
    check(repo == "shambleta/%s" % svc,
          "rollback/%s: o repositório da imagem é um só por serviço" % svc,
          "repo=shambleta/%s" % svc, "repo=%s" % repo)
    check(var == TAG_VAR, "rollback/%s: a tag vem do knob único %s" % (svc, TAG_VAR),
          "${%s:-...}" % TAG_VAR, "${%s:-...}" % var)
    check(default not in ("latest", "master", "main", "stable"),
          "rollback/%s: o default não é tag mutável (tag mutável não é alvo de rollback)" % svc,
          "um default que se nomeie como o que ele é", "default=%s" % default)
    check(default == UNPINNED_TAG,
          "rollback/%s: o default é o sentinela %r que a doc manda o operator recusar" % (svc, UNPINNED_TAG),
          "default=%s" % UNPINNED_TAG, "default=%s" % default)
    pp = str(spec.get("pull_policy") or "")
    check(pp == "never",
          "rollback/%s: pull_policy never — não há registry para onde este serviço olhar" % svc,
          "pull_policy: never (o artefato é local, nasce do `docker compose build`)",
          "pull_policy=%s" % (pp or "ausente"))
# Um serviço de terceiro (cloudflared) não pode tomar o namespace nem o knob do
# release: se tomasse, `docker compose images` leria duas coisas iguais sendo uma
# delas puxada de registry, e o `pull_policy: never` dele quebraria o boot.
for svc, spec in sorted(raw_services.items()):
    if isinstance(spec, dict) and not spec.get("build"):
        img = str(spec.get("image") or "")
        check(not img.startswith("shambleta/") and TAG_VAR not in img,
              "rollback/%s: serviço não-buildado não usa o namespace nem o knob do release" % svc,
              "imagem de terceiro com tag própria (cloudflare/cloudflared:latest)",
              "image=%r" % img)
# O caminho canônico, quando existe binário docker: o arquivo RESOLVIDO tem de
# terminar com uma tag explícita. `image: shambleta/web` sem tag é `:latest` por
# spec — exatamente a ficção que esta seção existe para matar.
if resolved_prod:
    for svc in built_names:
        rimg = str((prod_services.get(svc) or {}).get("image") or "")
        head, _, tail = rimg.rpartition(":")
        check(bool(head) and "/" in head and tail not in ("", "latest"),
              "rollback/%s: no compose resolvido a imagem tem repositório E tag explícita" % svc,
              "shambleta/%s:<tag>, com tag não-vazia" % svc, "resolvido=%r" % rimg)

# --------------------------- (9) TETO DE LOG em todo serviço que fala no stdout --
# O driver padrão do docker (json-file) NÃO tem teto: o `<id>-json.log` cresce até
# o filesystem acabar, e o filesystem é o mesmo do volume nomeado —
# <data-root>/containers de um lado, <data-root>/volumes/ do outro, um disco só.
# Ou seja: log sem cota come o espaço do live.db + `-wal` + sql-backups, e o
# `mem_limit` do serviço `game` não protege nada disso. O teto é a única coisa
# neste repo que faz um beta verboso não ser um incidente de disponibilidade.
MAX_SIZE_RX = re.compile(r'^\d+[kKmMgG]?$')


def log_ceiling_problems(services):
    bad = []
    for name, svc in sorted((services or {}).items()):
        lg = (svc or {}).get("logging")
        if not isinstance(lg, dict):
            bad.append("%s: sem bloco logging:" % name)
            continue
        if lg.get("driver") != "json-file":
            bad.append("%s: driver=%r (json-file precisa estar DECLARADO — o default silencioso é justamente o que não tem teto)"
                       % (name, lg.get("driver")))
            continue
        opts = lg.get("options") or {}
        ms = str(opts.get("max-size") or "")
        mf = str(opts.get("max-file") or "")
        if not MAX_SIZE_RX.match(ms):
            bad.append("%s: max-size=%r" % (name, opts.get("max-size")))
        if not re.match(r'^\d+$', mf) or int(mf) < 2:
            bad.append("%s: max-file=%r (inteiro >= 2; com 1 o arquivo é riscado por cima do próprio histórico)"
                       % (name, opts.get("max-file")))
    return bad


for label, services in (("produção", prod_services), ("mesclado(base+staging)", merged_services)):
    probs = log_ceiling_problems(services)
    check(not probs,
          "%s: todo serviço tem json-file com max-size E max-file (%d serviços conferidos)" % (label, len(services)),
          "logging.driver=json-file + options.max-size=<n>[kMG] + options.max-file>=2 em cada serviço",
          "; ".join(probs) if probs else "todos com teto")

# O staging não repete o bloco de propósito (o compose mescla `logging` por chave);
# a régua acima roda no doc MESCLADO exatamente para isso continuar sendo escolha e
# não esquecimento — se alguém apagar o teto do base, o mesclado cai aqui.
check(not log_ceiling_problems({n: s for n, s in merged_services.items()
                                if n in (stg_services or {})}),
      "mesclado: os serviços que o staging toca continuam com teto de log",
      "nenhum serviço do override sem logging resolvido",
      "staging=%s" % sorted(stg_services or {}))

NEG_LOG = {
    "a-sem-bloco": {},
    "b-driver-sem-opcoes": {"logging": {"driver": "json-file"}},
    "c-sem-max-file": {"logging": {"driver": "json-file", "options": {"max-size": "10m"}}},
    "d-max-file-1": {"logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "1"}}},
    "e-syslog": {"logging": {"driver": "syslog", "options": {}}},
    "f-max-size-sem-unidade-grande": {"logging": {"driver": "json-file", "options": {"max-size": "10mb", "max-file": "3"}}},
}
neg_accused = sorted({p.split(":")[0] for p in log_ceiling_problems(NEG_LOG)})
check(len(neg_accused) == len(NEG_LOG),
      "controle negativo (teto de log): os %d serviços inventados SEM teto são acusados" % len(NEG_LOG),
      "acusação em 100%% dos casos plantados (%s)" % " ".join(sorted(NEG_LOG)),
      "acusados=%s" % " ".join(neg_accused))

# O motivo tem de estar ESCRITO no arquivo que o operator abre às 3h — um teto sem
# razão vira "número mágico" e é a primeira linha apagada num diff de performance.
LOG_REASON_NEEDLES = ["json-file", "<data-root>/containers", "<data-root>/volumes/", "live.db"]


def log_reason_missing(text):
    return [n for n in LOG_REASON_NEEDLES if n not in text]


compose_header = read(prod_path).split("\nservices:", 1)[0]
missing_reason = log_reason_missing(compose_header)
check(not missing_reason,
      "%s: o cabeçalho diz POR QUE o teto existe (mesmo filesystem do banco)" % prod_path,
      "o bloco antes de `services:` mencionando %s" % " ".join(LOG_REASON_NEEDLES),
      "faltando: %s" % ", ".join(missing_reason))
check(bool(log_reason_missing("logging:\n  options:\n    max-size: 10m\n    max-file: 3\n")),
      "controle negativo (motivo do teto): um cabeçalho só com o número é acusado",
      "o predito reclama quando a razão não está escrita", "ficou mudo")

# ------------------ (10) DESTINO HUMANO do `severity: page` (a régua que acusa) --
# O schema do Alertmanager não interpola env, e a URL de webhook É credencial — o
# valor não pode morar num repo open source. A ponte é um marcador por receiver,
# materializado no boot por deploy/monitoring/render-alertmanager-config.sh. O que
# este bloco garante é que a ponte não é ficção: todo receiver que alguma rota
# alcança tem exatamente UM marcador, com um nome que o render aceita, declarado
# em `.env.example` e VAZIO lá (valor no template seria segredo committado).
MARKER_PREFIX = "@@ALERTWEBHOOK:"
MARKER_LINE = re.compile(r'^(\s*)webhook_configs:\s*\[\]\s*#\s*@@ALERTWEBHOOK:([A-Za-z0-9_]+)@@\s*$')
MARKER_NAME = re.compile(r'^SHAMBLETA_ALERT_[A-Z0-9_]*WEBHOOK_URL$')
ENV_TEMPLATE = ".env.example"


def receiver_blocks(text):
    """name -> linhas do bloco, lidas do TEXTO (o YAML descarta comentário)."""
    blocks, cur, in_recv = {}, None, False
    for ln in text.splitlines():
        if re.match(r'^receivers:\s*$', ln):
            in_recv = True
            continue
        if not in_recv:
            continue
        if ln.strip() and not ln[0].isspace():
            break
        m = re.match(r'^\s*-\s+name:\s*([A-Za-z0-9_.-]+)\s*$', ln)
        if m:
            cur = m.group(1)
            blocks[cur] = []
            continue
        if cur is not None:
            blocks[cur].append(ln)
    return blocks


def dotenv_values(path):
    out = {}
    for ln in read(path).splitlines():
        m = re.match(r'^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*)$', ln)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def destination_problems(text, routed, declared):
    probs = []
    blocks = receiver_blocks(text)
    for name in sorted(routed):
        if name not in blocks:
            probs.append("%s: receiver roteado não existe em receivers:" % name)
            continue
        hits = [ln for ln in blocks[name] if MARKER_PREFIX in ln and not ln.lstrip().startswith("#")]
        if len(hits) != 1:
            probs.append("%s: %d marcadores de destino (precisa de exatamente 1, na linha do webhook_configs:)"
                         % (name, len(hits)))
            continue
        m = MARKER_LINE.match(hits[0])
        if not m:
            probs.append("%s: marcador fora da forma `<espacos>webhook_configs: [] # @@ALERTWEBHOOK:<NOME>@@` -> %r"
                         % (name, hits[0].strip()))
            continue
        var = m.group(2)
        if not MARKER_NAME.match(var):
            probs.append("%s: marcador aponta para %r, fora de SHAMBLETA_ALERT_*_WEBHOOK_URL (o render recusa o nome e o container não sobe)"
                         % (name, var))
            continue
        if var not in declared:
            probs.append("%s: %s não está declarado em %s — ninguém no deploy sabe que precisa preencher"
                         % (name, var, ENV_TEMPLATE))
            continue
        if declared[var] != "":
            probs.append("%s: %s tem VALOR em %s (URL de webhook é credencial; o repo é open source)"
                         % (name, var, ENV_TEMPLATE))
    for name in sorted(blocks):
        if name not in routed and any(MARKER_PREFIX in ln for ln in blocks[name]):
            probs.append("%s: tem marcador mas nenhuma rota aponta para ele (receiver órfão = destino que ninguém usa)" % name)
    return probs


DOTENV = dotenv_values(ENV_TEMPLATE)
check(len(DOTENV) >= 20,
      "%s: lido pelo gate (%d nomes declarados)" % (ENV_TEMPLATE, len(DOTENV)),
      "o template existir e carregar os nomes que o compose usa", "nomes=%d" % len(DOTENV))

am_text = read(am_path)
routed_receivers = set(x for x in [route.get("receiver")] + [s.get("receiver") for s in (route.get("routes") or [])] if x)
dest_probs = destination_problems(am_text, routed_receivers, DOTENV)
marker_names = sorted({MARKER_LINE.match(ln).group(2)
                       for blk in receiver_blocks(am_text).values() for ln in blk
                       if MARKER_LINE.match(ln)})
check(not dest_probs,
      "%s: todo receiver roteado tem marcador de destino com env declarada e vazia (%s)" % (am_path, ", ".join(marker_names) or "nenhum"),
      "1 marcador `@@ALERTWEBHOOK:SHAMBLETA_ALERT_*_WEBHOOK_URL@@` por receiver roteado, nome em %s com valor vazio" % ENV_TEMPLATE,
      "; ".join(dest_probs) if dest_probs else "%d receivers roteados, %d marcadores" % (len(routed_receivers), len(marker_names)))

NEG_DEST = [
    ("sem-marcador", "route:\n  receiver: x\nreceivers:\n  - name: x\n    webhook_configs: []\n",
     {"x"}, {"SHAMBLETA_ALERT_PAGE_WEBHOOK_URL": ""}),
    ("marcador-na-linha-errada",
     "route:\n  receiver: x\nreceivers:\n  - name: x\n    extra: []  # @@ALERTWEBHOOK:SHAMBLETA_ALERT_PAGE_WEBHOOK_URL@@\n",
     {"x"}, {"SHAMBLETA_ALERT_PAGE_WEBHOOK_URL": ""}),
    ("nome-fora-do-padrao",
     "route:\n  receiver: x\nreceivers:\n  - name: x\n    webhook_configs: []  # @@ALERTWEBHOOK:MEU_WEBHOOK@@\n",
     {"x"}, {"MEU_WEBHOOK": ""}),
    ("nome-nao-declarado",
     "route:\n  receiver: x\nreceivers:\n  - name: x\n    webhook_configs: []  # @@ALERTWEBHOOK:SHAMBLETA_ALERT_PAGE_WEBHOOK_URL@@\n",
     {"x"}, {}),
    ("declarado-com-valor",
     "route:\n  receiver: x\nreceivers:\n  - name: x\n    webhook_configs: []  # @@ALERTWEBHOOK:SHAMBLETA_ALERT_PAGE_WEBHOOK_URL@@\n",
     {"x"}, {"SHAMBLETA_ALERT_PAGE_WEBHOOK_URL": "https://hooks.invalid.test/nunca"}),
    ("receiver-roteado-inexistente", "route:\n  receiver: fantasma\nreceivers:\n  - name: x\n    webhook_configs: []  # @@ALERTWEBHOOK:SHAMBLETA_ALERT_PAGE_WEBHOOK_URL@@\n",
     {"fantasma"}, {"SHAMBLETA_ALERT_PAGE_WEBHOOK_URL": ""}),
    ("marcador-orfao-sem-rota", "route:\n  receiver: x\nreceivers:\n  - name: x\n    webhook_configs: []\n  - name: y\n    webhook_configs: []  # @@ALERTWEBHOOK:SHAMBLETA_ALERT_TICKET_WEBHOOK_URL@@\n",
     {"x"}, {"SHAMBLETA_ALERT_TICKET_WEBHOOK_URL": ""}),
]
neg_mute = [name for name, text, routed, declared in NEG_DEST
            if not destination_problems(text, routed, declared)]
check(not neg_mute,
      "controle negativo (destino do pager): os %d casos inventados são acusados" % len(NEG_DEST),
      "acusação em 100%% dos plantados (%s)" % " ".join(n[0] for n in NEG_DEST),
      "ficaram mudos: %s" % ", ".join(neg_mute) if neg_mute else "%d/%d acusados" % (len(NEG_DEST), len(NEG_DEST)))

# O veredito em voz alta — e é AQUI que este gate diz o que o repo não pode dizer.
if dest_probs:
    print("[AVISO] %s: destino do pager quebrado (%s) — veja o ENCONTRADO acima." % (am_path, "; ".join(dest_probs)))
else:
    sem_valor = [v for v in marker_names if not os.environ.get(v)]
    print("[AVISO] %s: %d receivers roteados com destino vindo de env (%s). %s" % (
        am_path, len(marker_names), " ".join(marker_names),
        "ALERTA SEM DESTINO HUMANO É CONFIGURAÇÃO INCOMPLETA, NÃO É CONFIGURAÇÃO SEGURA: o `severity: page` "
        "avalia, entra no /api/v2/alerts do alertmanager e morre lá sem acordar ninguém. O repositório não pode "
        "conter o valor (URL de webhook é credencial e o repo é open source), então a medição honesta é no host: "
        "`docker compose exec alertmanager sh -c 'grep -c \"      - url:\" /etc/alertmanager/alertmanager.yml'` — "
        "zero é stack sem pager. Desde #90 esse zero deixou de ser aceitável em silêncio: o render sai != 0 e só o "
        "container do alertmanager não sobe, a menos que o operador DECLARE o ambiente sem on-call com "
        "SHAMBLETA_ALERT_NO_PAGER_ACK=1 (a decisão, com o custo dos dois lados, está no header de "
        "deploy/monitoring/render-alertmanager-config.sh; deploy/OPS_RUNBOOK.md não tem a §2.1 que arquivos desta "
        "área citavam — pendência pedida ao dono do doc). Os três estados são conferidos rodando o render de fato, "
        "no bloco 'TRÊS ESTADOS DO PAGER'. "
        "Ausente no ambiente deste gate: %s" % (" ".join(sem_valor) or "-")))

# -------------- (11) ENV DE CREDENCIAL interpolada precisa estar DECLARADA -------
# `${VAR:-}` num compose é um pedido de credencial que ninguém fez: o stack sobe
# mudo com o valor vazio. O nome declarado em `.env.example` é o que transforma o
# vazio em "falta preencher" — no painel do Coolify e na cabeça de quem faz o
# primeiro deploy.
CRED_NAME = re.compile(r'(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)|WEBHOOK_URL$')
INTERP = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}')


def undeclared_cred_problems(names, declared):
    out = []
    for n in sorted(set(names)):
        if not CRED_NAME.search(n):
            continue
        if n not in declared:
            out.append("%s: interpolada no compose e ausente de %s" % (n, ENV_TEMPLATE))
        elif declared[n] != "":
            out.append("%s: declarada com VALOR em %s (credencial versionada)" % (n, ENV_TEMPLATE))
    return out


interp_names = [m.group(1) for p in (prod_path, stg_path) for m in INTERP.finditer(read(p))]
und_probs = undeclared_cred_problems(interp_names, DOTENV)
check(not und_probs,
      "toda env de credencial interpolada pelos composes está declarada vazia em %s (%d nomes vistos)" % (
          ENV_TEMPLATE, len(set(interp_names))),
      "nome presente no template com `=` vazio",
      "; ".join(und_probs) if und_probs else " ".join(sorted({n for n in interp_names if CRED_NAME.search(n)})))
neg_und = undeclared_cred_problems(["SHAMBLETA_NOVO_SECRET", "OUTRO_TOKEN", "SHAMBLETA_CATALOG_FILE"],
                                   {"SHAMBLETA_NOVO_SECRET": "https://x.invalid/valor"})
check(len(neg_und) == 2,
      "controle negativo (env de credencial): ausente e com-valor são acusados, nome não-credencial é poupado",
      "2 acusações de 3 inventados (SHAMBLETA_NOVO_SECRET com valor, OUTRO_TOKEN ausente, SHAMBLETA_CATALOG_FILE fora do padrão)",
      "acusados=%d: %s" % (len(neg_und), "; ".join(neg_und)))

# --------- (12) FIAÇÃO do pager e do SIGTERM: env -> render -> config -> binário --
# Uma corrente dessas quebra no meio e continua parecendo inteira: o nome pode
# estar no `.env.example` sem estar no `environment:` do serviço (aí o valor do
# painel nunca chega ao container), o `--config.file` pode apontar para um caminho
# que nada escreve, o `ENTRYPOINT` pode ficar sem o script. Cada uma das pontas
# abaixo é uma dessas formas.
RENDER_SH = "deploy/monitoring/render-alertmanager-config.sh"
ENTRY_SH = "deploy/server/entrypoint.sh"
AM_DF = "deploy/monitoring/alertmanager.Dockerfile"
SRV_DF = "deploy/server/Dockerfile"
render_text = read(RENDER_SH)
entry_text = read(ENTRY_SH)
am_df_text = read(AM_DF)
srv_df_text = read(SRV_DF)


def grab1(rx, text, default=""):
    m = re.search(rx, text)
    return m.group(1) if m else default


render_out = grab1(r'ALERTMANAGER_CONFIG:-([^}]*)\}', render_text)
render_tmpl = grab1(r'ALERTMANAGER_TEMPLATE:-([^}]*)\}', render_text)
am_cmd_cfg = grab1(r'--config\.file=(\S+)', " ".join(str(x) for x in ((merged_services.get("alertmanager") or {}).get("command") or [])))
check(render_out and am_cmd_cfg == render_out,
      "o `--config.file` do compose é exatamente o caminho que o render escreve",
      "config.file=%s (o default de ALERTMANAGER_CONFIG em %s)" % (render_out or "?", RENDER_SH),
      "config.file=%r renderiza=%r" % (am_cmd_cfg, render_out))
check(render_tmpl and ("COPY deploy/alertmanager.yml %s" % render_tmpl) in am_df_text,
      "%s: o template do render é o config versionado, montado no caminho que o script lê" % AM_DF,
      "uma linha `COPY deploy/alertmanager.yml %s`" % (render_tmpl or "?"),
      "COPY encontrada=%s" % ("sim" if render_tmpl and render_tmpl in am_df_text else "não"))
# O exemplo de HA que vem na imagem oficial mora no MESMO caminho do --config.file.
# Sem o `rm`, um container que por qualquer motivo não rodasse o render subiria
# configurado para falar com peers de outro cluster — pior que sem destino.
check(re.search(r'RUN\s+rm\s+-f\s+/etc/alertmanager/alertmanager\.yml', am_df_text),
      "%s: o config de exemplo da imagem oficial é apagado no build" % AM_DF,
      "`RUN rm -f /etc/alertmanager/alertmanager.yml`",
      "linha ausente — o container pode subir com o exemplo de HA dos docs")
for needle, why in (('ENTRYPOINT ["/bin/sh", "/etc/alertmanager/render-config.sh"]' in am_df_text,
                    "o render roda antes do binário"),
                   ('"render-alertmanager-config.sh"' in am_df_text or "/etc/alertmanager/render-config.sh" in am_df_text,
                    "o script é embarcado")):
    check(bool(needle), "%s: %s" % (AM_DF, why), "a linha presente no Dockerfile", "não encontrada")
# Nome no marcador sem env no serviço = o valor do painel nunca chega ao container.
am_env_names = sorted({e.split("=", 1)[0] for e in env_pairs((merged_services.get("alertmanager") or {}).get("environment"))})
check(all(v in am_env_names for v in marker_names),
      "compose: o serviço `alertmanager` repassa ao container cada env que o marcador nomeia",
      "environment com %s" % (" ".join(marker_names) or "(nenhum marcador)"),
      "environment=%s" % (am_env_names or "ausente"))


def env_marco_problems(env_names, wanted):
    return ["%s: marcador exige a env, ausente no `environment:` do serviço" % w for w in wanted if w not in env_names]


check(len(env_marco_problems(["SHAMBLETA_ALERT_PAGE_WEBHOOK_URL"], ["SHAMBLETA_ALERT_PAGE_WEBHOOK_URL",
                                                                   "SHAMBLETA_ALERT_TICKET_WEBHOOK_URL"])) == 1,
      "controle negativo (repassar a env): um marcador sem env no serviço é acusado",
      "1 acusação de 2 nomes", "acusou %d" % len(env_marco_problems(["A"], ["A", "B"])))

# ---- SIGTERM: o orçamento do entrypoint contra o stop_grace_period do compose ----
canary_detect = grab1(r'SHAMBLETA_CANARY_DETECT_SEC:-([^}]*)\}', entry_text)
drain_timeout = grab1(r'SHAMBLETA_DRAIN_TIMEOUT_SEC:-([^}]*)\}', entry_text)
kill_grace = grab1(r'KILL_GRACE_SEC=(\d+)', entry_text)
canary_internal = float(grab1(r'checkInternalSec\s*:\s*float\s*=\s*([\d.]+)', canary_src, "0"))
entry_home = grab1(r'USER_DIR="\$\{HOME:-([^}]*)\}', entry_text)
canary_file = grab1(r'CANARY_FILE="\$USER_DIR/([^"]+)"', entry_text)
budget = drain_timeout and kill_grace and canary_detect
check(budget, "%s: o gate leu detect/teto/grace do kill" % ENTRY_SH,
      "SHAMBLETA_CANARY_DETECT_SEC, SHAMBLETA_DRAIN_TIMEOUT_SEC e KILL_GRACE_SEC no arquivo",
      "detect=%r timeout=%r kill=%r" % (canary_detect, drain_timeout, kill_grace))
if budget:
    detect_s, timeout_s, kill_s = float(canary_detect), float(drain_timeout), float(kill_grace)
    check(detect_s >= 2 * canary_internal,
          "%s: a janela de detecção cobre 2 batidas do CheckCanary (%.0fs)" % (ENTRY_SH, 2 * canary_internal),
          "SHAMBLETA_CANARY_DETECT_SEC >= %.0f (sources/world/ShutdownCanary.gd:5)" % (2 * canary_internal),
          "%s" % canary_detect)
    check(timeout_s >= detect_s + drain + join,
          "%s: o teto de drain cabe o canary inteiro (detect %.0f + avisos %.0f + join %d)" % (
              ENTRY_SH, detect_s, drain, join),
          ">= %.0fs" % (detect_s + drain + join),
          "SHAMBLETA_DRAIN_TIMEOUT_SEC=%s" % drain_timeout)
    for label, services in (("produção", prod_services), ("mesclado", merged_services)):
        grace = seconds((services.get("game") or {}).get("stop_grace_period"))
        check(grace is not None and grace >= timeout_s + kill_s,
              "%s: stop_grace_period sobrevive ao entrypoint inteiro (%.0f + %.0f = %.0fs de pior caso)" % (
                  label, timeout_s, kill_s, timeout_s + kill_s),
              ">= %.0fs — quem mata por fora tem de ser o docker, não este script" % (timeout_s + kill_s),
              "stop_grace_period=%r" % ((services.get("game") or {}).get("stop_grace_period"),))


def budget_problems(detect_s, timeout_s, kill_s, grace_s, drain_s, join_s, internal_s):
    out = []
    if detect_s < 2 * internal_s:
        out.append("detect %.0f < 2 batidas de %.0fs" % (detect_s, 2 * internal_s))
    if timeout_s < detect_s + drain_s + join_s:
        out.append("teto %.0f < drain inteiro %.0fs" % (timeout_s, detect_s + drain_s + join_s))
    if grace_s < timeout_s + kill_s:
        out.append("grace %.0f < teto+kill %.0fs" % (grace_s, timeout_s + kill_s))
    return out


neg_budget = [budget_problems(*c) for c in (
    (10, 62, 6, 75, 47, 2, 5),      # o estado de hoje: tem de ser o único LIMPO
    (4, 62, 6, 75, 47, 2, 5),       # detecção menor que 2 batidas do timer
    (10, 40, 6, 75, 47, 2, 5),      # teto menor que o drain que ele espera
    (10, 74, 6, 75, 47, 2, 5),      # teto+kill estourando o grace do compose
)]
check(budget_problems(10, 62, 6, 75, 47, 2, 5) == [] and sum(1 for x in neg_budget[1:] if x) == 3,
      "controle negativo (orçamento do drain): os 3 casos quebrados são acusados e o atual não",
      "1 lote limpo + 3 acusados", "resultado=%s" % ([bool(x) for x in neg_budget],))

# O parser de duração é o olho das réguas de tempo: `docker compose config` — o
# validador canônico, que é o que roda onde há docker — reimprime `stop_grace_period:
# 75` como `1m15s`, e um parser que só sabe ler o número que ele mesmo escreveu
# devolve "ausente" para um knob correto. Foi isso que, no run de 2026-09-29, fechou
# as duas leituras de grace em vermelho na CI (`'1m15s'` contra `>= 68s`) com o mesmo
# compose verde nesta máquina, onde `yaml.safe_load` lê 75. Controle negativo: cada
# forma que o canônico emite vira segundos, e o que não é duração é acusação (`None`)
# — nunca 0, que passaria em qualquer `>= 0` e é como um healthcheck fictício nasce.
DUR_GOOD = {"75": 75.0, "1m15s": 75.0, "1m": 60.0, "45s": 45.0, "2h": 7200.0,
            "1h15m30s": 4530.0, "75.5": 75.5}
DUR_BAD = [None, "", "   ", "15x", "1m15", "s", "1w", True]
dur_wrong = ["%r -> %r, esperado %r" % (k, seconds(k), v)
             for k, v in DUR_GOOD.items() if seconds(k) != v]
dur_soft = [repr(x) for x in DUR_BAD if seconds(x) is not None]
check(not dur_wrong and not dur_soft and seconds(75) == 75.0,
      "controle negativo (parser de duração): as formas do validador canônico viram segundos e o que não é duração é acusação, nunca 0",
      "75/'75'/'1m15s'/'1h15m30s' lidos como número; None/''/'15x'/'1m15'/'s'/'1w'/True -> None",
      "; ".join(dur_wrong + ["não é None: %s" % x for x in dur_soft]) or "as 8 formas e os 8 rejeitos conferem")

# O entrypoint tem de ser o que o Dockerfile chama, e o compose não pode passar por
# cima dele (um `entrypoint:` ou `user:` no serviço desarma o SIGTERM sem ninguém
# ver — o sintoma é o exit 143 antigo, não um erro).
check('ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]' in srv_df_text
      and "COPY deploy/server/entrypoint.sh /app/entrypoint.sh" in srv_df_text,
      "%s: o ENTRYPOINT é o script do drain (chamado por /bin/sh, sem depender de mode bit)" % SRV_DF,
      "as duas linhas no Dockerfile", "uma delas falta")
for label, services in (("produção", prod_services), ("mesclado", merged_services)):
    g = services.get("game") or {}
    check(not g.get("entrypoint") and not g.get("user"),
          "%s: o compose não sobrescreve entrypoint/user do `game`" % label,
          "nenhum dos dois (o override desligaria o drain)",
          "entrypoint=%r user=%r" % (g.get("entrypoint"), g.get("user")))
docker_home = grab1(r'ENV\s+HOME=(\S+)', srv_df_text)
expected_user_dir = "%s/.local/share/%s" % (docker_home, user_dir)
check(entry_home == docker_home and canary_file == os.path.basename(grab1(r'const\s+CanaryFile\s*:\s*String\s*=\s*Local\s*\+\s*"([^"]+)"', read("sources/system/Path.gd"), "canary")),
      "%s: o canary que o script toca é o user:// que o container abre" % ENTRY_SH,
      "USER_DIR=%s e arquivo %r (sources/system/Path.gd:56 + project.godot + ENV HOME em %s)" % (
          expected_user_dir, "canary", SRV_DF),
      "HOME no script=%r vs Dockerfile=%r; arquivo=%r" % (entry_home, docker_home, canary_file))

# ---- (7b) Resolução do contexto — o que o compose FAZ com `build.context` ----
# Medido no runner, 2026-09-29: com `context: .` o job container-images morreu em
# `resolve : lstat /home/runner/work/shambleta/shambleta/deploy/deploy: no such file
# or directory` (commits 126b086 e 1f540a1) e NENHUM check deste gate viu o defeito:
# `docker compose config -q` não resolve contexto nem testa existência de caminho, e
# a régua de imagens de scripts/check_ci.sh lia o `dockerfile:` contra o CWD. A
# semântica, ela: diretório do projeto = diretório do PRIMEIRO `-f` (aqui `deploy/`)
# enquanto ninguém passar `--project-directory`; `build.context` é relativo a esse
# diretório; `build.dockerfile` é relativo ao CONTEXTO resolvido. Então `context: .`
# + `dockerfile: deploy/web/Dockerfile` = `deploy/deploy/web/Dockerfile` — o caminho
# dobrado do log. Os cinco Dockerfiles copiam da RAIZ (`COPY . .`,
# `COPY data/conf/paid_catalog.json .`, `COPY deploy/web/nginx.conf ...`), logo o
# contexto tem de ser o repositório, e os COPY são a prova cruzada: só com a raiz
# aqueles caminhos existem dentro do contexto. `..` é o único valor que faz a CI
# (`-f deploy/docker-compose.yml` da raiz), o README (`cd deploy && docker compose
# up -d`) e o import do Coolify resolverem o mesmo lugar sem flag.
PROJ_DIR = os.path.dirname(os.path.abspath(prod_path))
REPO_ROOT = os.getcwd()

def resolve_ctx(ctx, df):
    """Igual ao compose: contexto contra o diretório do projeto, dockerfile contra o
    contexto. Contexto absoluto ou URI (`git://`, `http://`) fica como veio."""
    if os.path.isabs(ctx) or re.match(r"^[A-Za-z0-9+.-]+://", ctx):
        c = os.path.normpath(ctx)
    else:
        c = os.path.abspath(os.path.join(PROJ_DIR, ctx))
    return c, (df if os.path.isabs(df) else os.path.normpath(os.path.join(c, df)))

COPY_RX = re.compile(r'^\s*(?:COPY|ADD)\s+(.*\S)\s*$')

def copy_sources(df_text):
    """Fontes de COPY/ADD que vêm do CONTEXTO. `--from=` é outro estágio, flag tem
    `=`, fonte absoluta não é lícita no contexto e `$VAR` não é caminho."""
    out = []
    for ln in df_text.splitlines():
        if ln.lstrip().startswith("#"):
            continue
        m = COPY_RX.match(ln)
        if not m or "--from=" in m.group(1):
            continue
        toks = [t for t in m.group(1).split() if "=" not in t]
        if len(toks) < 2:
            continue
        out += [t for t in toks[:-1] if not t.startswith("/") and not t.startswith("$")]
    return out

builds_ctx = []
for label, svcs in (("produção", prod_services), ("mesclado", merged_services)):
    for svc, spec in sorted(svcs.items()):
        b = (spec or {}).get("build")
        if not isinstance(b, dict) or not b.get("dockerfile"):
            continue
        raw = str(b.get("context", "."))
        c, d = resolve_ctx(raw, str(b["dockerfile"]))
        builds_ctx.append((label, svc, raw, c, d))
check(len(builds_ctx) >= 10,
      "os dois arquivos declaram os blocos `build:` de %d serviços (%s)" % (
          len(builds_ctx), ", ".join(sorted(set("%s/%s" % (l, s) for l, s, _, _, _ in builds_ctx)))),
      ">= 10 (cinco serviços com build nos dois caminhos de leitura)",
      "%d blocos" % len(builds_ctx))
wrong_root = ["%s/%s: `context: %r` resolve para %s, e o build precisa da raiz (%s)"
              % (l, s, raw, c, REPO_ROOT) for l, s, raw, c, _ in builds_ctx if c != REPO_ROOT]
check(not wrong_root,
      "todo contexto de build resolvido COMO O COMPOSE resolve é a raiz do repositório (%d blocos)" % len(builds_ctx),
      "abspath(diretório-do-primeiro--f + build.context) == %s" % REPO_ROOT,
      "; ".join(wrong_root) if wrong_root else "os %d resolvem para %s" % (len(builds_ctx), REPO_ROOT))
missing_df = ["%s/%s: %s (contexto %s)" % (l, s, d, c)
              for l, s, _, c, d in builds_ctx if not os.path.isfile(d)]
check(not missing_df,
      "todo `dockerfile:` existe no caminho que o compose abre, relativo ao CONTEXTO",
      "arquivo presente", "; ".join(missing_df) if missing_df else "os %d dockerfiles conferidos" % len(builds_ctx))
bad_copy = []
copy_checked = 0
for l, s, _, c, d in builds_ctx:
    for src in copy_sources(read(d)):
        copy_checked += 1
        if "*" in src or "?" in src:
            if not glob.glob(os.path.join(c, src)):
                bad_copy.append("%s/%s: %s: %r não casa nada no contexto %s" % (l, s, d, src, c))
        elif not os.path.exists(os.path.join(c, src)):
            bad_copy.append("%s/%s: %s: %r não existe no contexto %s" % (l, s, d, src, c))
check(copy_checked > 0 and not bad_copy,
      "cada fonte de COPY dos Dockerfiles resolve dentro do contexto resolvido (%d fontes, %d blocos)" % (
          copy_checked, len(builds_ctx)),
      "todo caminho relativo do COPY existe sob o contexto — é isto que prova que o contexto é a raiz",
      "; ".join(bad_copy) if bad_copy else "%d fontes conferidas" % copy_checked)

# `--project-directory` é a única flag que muda o que `..` significa: com ela apontando
# para a raiz, o contexto viria o PAI do repositório. Varrida em quem chama o compose de
# verdade (CI, runbooks, docs, scripts), com comentário fora — linha de comentário explica
# o knob, não o usa. E só conta linha que CHAMA o binário: a própria régua nomeia o knob
# para proibi-lo, e nomear não é usar.
pd_hits = []
pd_scanned = 0

def pd_use(ln):
    return (not ln.lstrip().startswith("#") and bool(re.search(r'docker[\s-]+compose', ln))
            and "--project-directory" in ln)

for p in sorted(set(glob.glob(".github/workflows/*.yml") + glob.glob("deploy/*.md")
                    + glob.glob("docs/**/*.md", recursive=True) + glob.glob("scripts/*.sh")
                    + ["README.md"])):
    pd_scanned += 1
    for n, ln in enumerate(read(p).splitlines(), 1):
        if pd_use(ln):
            pd_hits.append("%s:%d" % (p, n))
check(not pd_hits,
      "nenhum comando compose dos %d arquivos varridos passa `--project-directory` (moveria o `..` para fora do repo)" % pd_scanned,
      "zero ocorrências em linha de comando", "; ".join(pd_hits) if pd_hits else "zero")
# O fixture do controle é montado por partes: este arquivo está na varredura, e uma
# linha literal com o binário e a flag seria o próprio falso positivo. Concatenar o
# nome da flag não afrouxa nada — `pd_use` recebe a mesma string de comando.
PD = "--project-" "directory"
check(pd_use("run: docker compose -f deploy/docker-compose.yml " + PD + " . build")
      and not pd_use("\t# docker compose " + PD + " explica o knob")
      and not pd_use("docker compose -f deploy/docker-compose.yml build")
      and not pd_use("a régua proíbe " + PD + " sem chamar o binário"),
      "controle negativo (--project-directory): só linha que chama o binário com a flag é acusada — comentário, comando sem flag e prosa que nomeia o knob são poupados",
      "1 acusada, 3 poupadas", "uso=%s" % [pd_use(x) for x in (
          "docker compose -f deploy/docker-compose.yml " + PD + " . build",
          "# docker compose " + PD,
          "docker compose -f deploy/docker-compose.yml build",
          "proíbe " + PD)])

# Controle negativo: a forma EXATA do log da CI. Rebobinar um bloco para `context: .`
# tem de acusar os três sintomas de uma vez — o contexto fora da raiz, o dockerfile no
# caminho dobrado e o COPY da raiz invisível. Régua que só confere o valor escrito não
# pega nada disso, e foi por isso que o defeito chegou ao runner.
lie_ctx, lie_df = resolve_ctx(".", "deploy/web/Dockerfile")
lie_copy = os.path.join("data", "conf", "paid_catalog.json")
check(lie_ctx != REPO_ROOT and not os.path.exists(lie_df)
      and os.path.exists(os.path.join(REPO_ROOT, lie_copy))
      and not os.path.exists(os.path.join(lie_ctx, lie_copy)),
      "controle negativo (contexto): `context: .` é acusado — fora da raiz, dockerfile %s inexistente e o COPY da raiz some" % lie_df,
      "os três sintomas juntos, como no log do runner",
      "ctx=%s df existe=%s copy existe no ctx=%s" % (
          lie_ctx, os.path.exists(lie_df), os.path.exists(os.path.join(lie_ctx, lie_copy))))
ok_ctx, ok_df = resolve_ctx("..", "deploy/web/Dockerfile")
check(ok_ctx == REPO_ROOT and os.path.isfile(ok_df),
      "o estado de hoje (`context: ..`) resolve para a raiz e o dockerfile abre",
      "%s + deploy/web/Dockerfile" % REPO_ROOT, "ctx=%s df=%s" % (ok_ctx, ok_df))

# O oráculo, quando existe: `docker compose config` reimprime o contexto que o loader
# resolveu — a segunda leitura do MESMO valor. Ele NÃO pegou o defeito de 2026-09-29
# (não toca o disco), então nunca é a única régua; em modo emulado o TSV acima já
# registrou o pulo com o motivo, e é ele que responde por esta régua não estar aqui.
if resolved_prod and os.path.isfile(resolved_prod):
    oracle_ctx = sorted(set(str(((s or {}).get("build") or {}).get("context"))
                            for s in ((load(resolved_prod) or {}).get("services") or {}).values()
                            if isinstance(((s or {}).get("build")), dict)))
    bad_oracle = [v for v in oracle_ctx if resolve_ctx(v, "Dockerfile")[0] != REPO_ROOT]
    check(bool(oracle_ctx) and not bad_oracle,
          "oráculo: todo `context:` impresso pelo `docker compose config` resolve para a raiz (%d valores)",
          "os valores resolvidos == %s" % REPO_ROOT,
          "; ".join(bad_oracle) if bad_oracle else ", ".join(oracle_ctx))

# (5) Auto-evidência: toda citação `arquivo:linha` escrita pelos arquivos desta
# posse tem de resolver para uma linha útil. sources/ e companion/ mudam de linha
# o dia inteiro nas mãos de outros agentes; quando a linha citada some, o runbook
# vira estória — e "cada afirmação com arquivo:linha" é justamente o que se
# recusa a aceitar isso. Este check é o único que vigia o próprio gate.
OWNED = ["deploy/docker-compose.yml", "deploy/docker-compose.staging.yml",
         "deploy/OPS_RUNBOOK.md", "deploy/BACKUP_RUNBOOK.md", "deploy/SCALING.md",
         "deploy/prometheus.yml", "deploy/alertmanager.yml",
         "deploy/monitoring/prometheus.Dockerfile",
         "deploy/monitoring/alertmanager.Dockerfile", ".dockerignore",
         "scripts/check_compose.sh", "tests/deploy_ops_test.gd"]
CITE = re.compile(r'([A-Za-z0-9_./-]+\.(?:gd|py|sh|yml|yaml|md|conf|godot|html|js|ts)):(\d+)(?:-(\d+))?')
broken, cited = [], 0
for own in OWNED:
    src = read(own)
    for m in CITE.finditer(src):
        target, first, last = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2))
        where = "%s:%d" % (own, src[:m.start()].count("\n") + 1)
        if not os.path.isfile(target):
            broken.append("%s aponta %s, que não existe" % (where, target))
            continue
        lines = read(target).splitlines()
        cited += 1
        window = [ln.strip() for ln in lines[max(first - 1, 0):max(last, 0)]]
        if first < 1 or last > len(lines) or not any(window):
            broken.append("%s aponta %s:%s, linha fora do útil (arquivo tem %d)"
                          % (where, target, m.group(0).split(":")[-1], len(lines)))
check(not broken, "as citações arquivo:linha desta posse resolvem",
      "todo `arquivo:N` citado é um arquivo existente e o intervalo cai em linha com texto",
      "; ".join(broken) if broken else "%d citações conferidas" % cited)

# --- hardening (auditoria 2026-10-06 §20/P1-DevOps): o que entrou no compose fica ---
# Regra que ninguém cobra é linha que morre no refactor de outro dono. Cada
# serviço declara no-new-privileges e cap_drop ALL; `web` é a única exceção de
# cap_add — nginx nasce root, binda a porta do container e descafeina os
# workers por setuid, e cada um desses atos exige o privilégio nominal
# correspondente. `user:` (rootless de verdade) é dívida pós-beta declarada:
# exige re-chown dos volumes nameados, e volume sem dono não é segurança.
HARD_SERVICES = sorted(raw_services.keys())
check(len(HARD_SERVICES) >= 6, "hardening: o gate vê %d serviços" % len(HARD_SERVICES),
      "a stack de hoje tem 6 (web game companion cloudflared prometheus alertmanager)",
      "%d" % len(HARD_SERVICES))
for svc in HARD_SERVICES:
    spec = raw_services.get(svc) or {}
    so = [str(x) for x in (spec.get("security_opt") or [])]
    check("no-new-privileges:true" in so,
          "hardening/%s: no-new-privileges declarado" % svc,
          "security_opt contém no-new-privileges:true",
          "security_opt=%r" % (so,))
    cd = [str(x) for x in (spec.get("cap_drop") or [])]
    check("ALL" in cd, "hardening/%s: cap_drop ALL declarado" % svc,
          "cap_drop: [ALL]", "cap_drop=%r" % (cd,))
    ca = [str(x) for x in (spec.get("cap_add") or [])]
    if svc == "web":
        for c in ("NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"):
            check(c in ca, "hardening/web: %s devolvido (nginx faz este ato de verdade)" % c,
                  "cap_add contém %s" % c, "cap_add=%r" % (ca,))
    else:
        check(not ca, "hardening/%s: sem cap_add (nada aqui porta privilegiada nem setuid)" % svc,
              "nenhum cap_add", "cap_add=%r" % (ca,))

print("== COMPOSE GATE: %d checks, %d failures == (validação: %s; fumaça: %d rodaram, "
      "%d falharam, %d pulados)" % (checks, failures, mode, smoke_ran, smoke_failed, smoke_skipped))
sys.exit(failures)
PYEOF
status=$?

if [ -n "$RESOLVED_PROD" ]; then
	rm -f "$RESOLVED_PROD" "$RESOLVED_PROD.err" "$RESOLVED_MERGED" "$RESOLVED_MERGED.err"
fi

exit $status
