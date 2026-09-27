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
# Saída: uma linha por regra ([PASS]/[FAIL] com ESPERADO/ENCONTRADO) e, no fim,
#        `== COMPOSE GATE: N checks, M failures ==` — o formato é o que
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

RESOLVED_PROD=""
RESOLVED_MERGED=""
if [ -n "$COMPOSE_BIN" ]; then
	RESOLVED_PROD="$(mktemp)"; RESOLVED_MERGED="$(mktemp)"
	if ! $COMPOSE_BIN -p shamgate -f "$PROD" config > "$RESOLVED_PROD" 2>"$RESOLVED_PROD.err"; then
		echo "[FAIL] \`$COMPOSE_BIN -f $PROD config\` não resolveu:"; sed 's/^/       /' "$RESOLVED_PROD.err"
		echo "== COMPOSE GATE: 1 checks, 1 failures =="; exit 1
	fi
	if ! $COMPOSE_BIN -p shamgatestg -f "$PROD" -f "$STG" config > "$RESOLVED_MERGED" 2>"$RESOLVED_MERGED.err"; then
		echo "[FAIL] \`$COMPOSE_BIN -f $PROD -f $STG config\` não resolveu:"; sed 's/^/       /' "$RESOLVED_MERGED.err"
		echo "== COMPOSE GATE: 1 checks, 1 failures =="; exit 1
	fi
fi

COMPOSE_BIN="$COMPOSE_BIN" RESOLVED_PROD="$RESOLVED_PROD" RESOLVED_MERGED="$RESOLVED_MERGED" \
PY="$PY" "$PY" - "$PROD" "$STG" <<'PYEOF'
import os, re, sys, yaml

prod_path, stg_path = sys.argv[1], sys.argv[2]
resolved_prod = os.environ.get("RESOLVED_PROD") or ""
resolved_merged = os.environ.get("RESOLVED_MERGED") or ""
mode = "docker compose config (canônico)" if resolved_prod else "yaml.safe_load + merge emulado"

checks = 0
failures = 0

def check(ok, title, expected, found):
    global checks, failures
    checks += 1
    print("[PASS] %s" % title)
    if not ok:
        failures += 1
        print("[FAIL] %s" % title)
        print("       ESPERADO: %s" % expected)
        print("       ENCONTRADO: %s" % found)

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

def seconds(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.match(r'^(\d+(?:\.\d+)?)(s|m|h)?$', str(v).strip())
    if not m:
        return None
    n, unit = float(m.group(1)), m.group(2)
    return n * {"m": 60, "h": 3600}.get(unit, 1)

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
# os Dockerfiles fazem `COPY . .`. Medido aqui (e não afirmado) porque o número
# que está em deploy/OPS_RUNBOOK.md §4.2 é exatamente este par.
before_bytes = before_files = after_bytes = after_files = 0
ignored_top = []
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

shipped = ("addons", "data", "presets", "sources", "project.godot", "export_presets.cfg",
           "companion/server.py", "deploy/web/nginx.conf", "deploy/prometheus.yml",
           "deploy/alerts.rules.yml", "docs")
ignored_top = [p for p in shipped if is_ignored(p)]
check(os.path.isfile(".dockerignore"), ".dockerignore existe na raiz do contexto",
      "o único lugar que o daemon lê (build.context: .)", "ausente")
check(bool(before_bytes) and after_bytes < before_bytes,
      "contexto medido: %d bytes/%d arquivos SEM .dockerignore -> %d bytes/%d arquivos com ele (-%.1f%%)" % (
          before_bytes, before_files, after_bytes, after_files,
          100.0 * (before_bytes - after_bytes) / max(before_bytes, 1)),
      "o arquivo tira bytes reais do contexto (número impresso aqui é a prova)",
      "antes=%d depois=%d" % (before_bytes, after_bytes))
check(before_bytes - after_bytes >= 0.25 * before_bytes,
      "contexto cai pelo menos 25% com o .dockerignore",
      ">= 25% dos bytes fora (cache de import, areia de teste, docs, scratch)",
      "caiu %.1f%% (%d -> %d bytes)" % (100.0 * (before_bytes - after_bytes) / max(before_bytes, 1), before_bytes, after_bytes))
check(not ignored_top, "nada do que o build embarca é excluído pelo .dockerignore",
      "nenhum destes fora: %s" % " ".join(shipped), "excluídos: %s" % " ".join(ignored_top))

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

print("== COMPOSE GATE: %d checks, %d failures == (validação: %s)" % (checks, failures, mode))
sys.exit(failures)
PYEOF
status=$?

if [ -n "$RESOLVED_PROD" ]; then
	rm -f "$RESOLVED_PROD" "$RESOLVED_PROD.err" "$RESOLVED_MERGED" "$RESOLVED_MERGED.err"
fi

exit $status
