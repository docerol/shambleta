# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-09-30

### Removed
- Eight dead forwarders out of `sources/economy/EconomyService.gd`
  (`CraftBudgetCap`, `CraftRarityForUsage`, `CraftSubmitFee`, `CraftNormName`,
  `CraftEditDistance`, `_FlagOpen`, `_FlagTradeBursts`, `_FlagLevelVelocity`): zero
  references anywhere in `sources/`, `tests/`, `companion/`, `scripts/`, `docs/` or
  `data/`, checked by name over every file of those trees, and no internal caller.
  The facade had walked into the `repo_layout_test` near-fence band (794 of an 800
  ceiling) and the house answer to that is to cut, not to register an excuse — 775
  lines now, out of the band, with `NEAR_FENCE` still empty.
- `ZonePolicy` (the "O(1) tick per zone" of the 0.0.9 entry above). Measured on
  2026-09-27: `AttachPolicy` had zero callers, so the policy map was always empty
  and every player allocated its own policy anyway. The doc and the ruler now say
  the measured thing instead of the intended thing.

### Fixed
- Five compose gates were red in CI and green here, and they were two different defects.
  Four were the duration parser: `docker compose config` — the canonical path, which only
  exists where docker exists, i.e. the runner — reprints `stop_grace_period: 75` as the Go
  duration `1m15s`, and `seconds()` in `scripts/check_compose.sh` matched
  `^(\d+(?:\.\d+)?)(s|m|h)?$`, so it returned `None` for a knob that was correct and the
  grace readings failed against their own `>= 68s` fence. On this machine the same compose
  goes through `yaml.safe_load`, which yields the int, so the ruler was green exactly where
  it could not see. It now reads every form the canonical validator emits (`75`, `'75'`,
  `1m15s`, `1h15m30s`, fractional units) and still answers `None` — never `0`, which would
  pass any `>= 0` and is how a fictitious healthcheck is born — for what is not a duration:
  `''`, `'   '`, `'15x'`, `'1m15'` (unit-less tail), `'s'`, `'1w'` (unit docker rejects),
  `True`. A negative control pins both halves (`DUR_GOOD`/`DUR_BAD`, 8 shapes accepted, 8
  rejected), so the parser is judged and not trusted.
  The fifth gate was the build-context ruler — `contexto cai pelo menos 25%` — and it was
  measuring the developer's dirt. It walked the working tree, so it charged `.dockerignore`
  for what this machine happens to have: `.godot` 70 MB of import cache, `build/` 92 MB,
  `.test-*` sandboxes 70 MB, `graphify-out` 11 MB, ~243 MB that no clone contains. Here it
  printed −51.7% and passed; on the runner, whose checkout has nothing to hide, the same
  file could not reach 25% and check 94 of 158 was red. The fence now reads the git INDEX
  (`git ls-files -z`) — the context a clean clone actually uploads, and identical to the tree
  on the runner — over five checks: the index was readable, the file removes bytes from what
  is tracked, what uploads fits a measured ceiling, every dirt class is covered by the path
  as Docker reads it, and nothing outside the index escapes. The percentage is gone because
  it was never a property of the file: the honest figure is small (−1.66% here today) since
  the 226 MB the export needs must stay in the context — addons 143 MB + data 61 MB + presets
  22 MB — and the working-tree number is printed as `[INFO]`, measured and declared not a
  ruler. Reading the index is itself fenced, not assumed: with `git` stubbed to exit 128 the
  gate prints four accusations and no silent green.
  The leak check paid for itself on its first run. `tools/__pycache__/extract_i18n.
  cpython-314.pyc` (13,295 B) was uploading to the daemon and no gate could see it, because
  a `.dockerignore` pattern without an internal `/` matches only at the context root — so
  the line `__pycache__` never covered a nested package. `tools/__pycache__` is now named in
  the file, `DIRT` carries the path, and the coverage check reproduces those three Docker
  semantics in python, which makes the next nested cache a red line instead of an upload.
  Every claim above was produced by breaking it and reverted: dropping the `.godot` line
  prints the dirt-class failure plus the leak; dropping `tools/__pycache__` prints the same
  two; a 60 MB tracked probe file trips only the ceiling (`293646553 bytes <= 288406820`);
  an int-only parser reproduces the CI set exactly — 4 grace failures plus the control, 5,
  which is what the runner counted. Locally after the change: `== COMPOSE GATE: 156 checks,
  0 failures == (validação: yaml.safe_load + merge emulado; fumaça: 0 rodaram, 0 falharam,
  2 pulados)`.
- Ten harnesses were measuring a catalogue that did not exist yet, and only CI noticed.
  `admission_gate_test`, `d1_return_metric_test`, `economy_invariant_fuzz`,
  `faucet_census_test`, `marketplace_depth_test`, `ops_fix_test`, `read_pool_test`,
  `season_race_delta_test`, `telemetry_census_test` and `test_backup_restore` waited for
  `SQL.isInitialized` (plus `Economy`/`Telemetry`) and then ran and `quit()` synchronously.
  The content catalogue is not loaded there: `DB.Preload()` only issues
  `ResourceLoader.load_threaded_request` for every preset path, and `PreloadUpdate()` —
  re-armed on `Launcher.get_tree().process_frame` — is what closes the preload, calls
  `Load()` and lights `isInitialized` (`sources/db/DB.gd:233-235`). The dictionaries therefore
  exist only after enough FRAMES. Here the frames land before the harness quits (~1747
  objects measured); on the CI runner, whose `.godot/` the workflow regenerates, they do
  not (30–31 measured against the 2247 ceiling recorded from a full local boot), and
  `scripts/ci_gate_log.sh:120-124` called that exactly what it is — a measurement taken
  before the thing it measures exists. Same class as a wall-clock assertion. Each harness
  now waits on `DB.isInitialized` at its own boot-wait site and records a NAMED check
  (`DB initialized (entities/maps/items carregados)`), the shape already proven by
  `tests/content_hygiene_test.gd`: a light boot is a visible red, not a silent partial
  measurement. No ceiling was touched, no metric re-tuned. Measured after the change, ten
  `one <harness>` runs, all `Gate §24-8 OK`: backup restore `9 checks, 0 failures` / leaked
  1747 (was 8 checks), d1_return 17 / 1747, faucet 63 / 1747, season_race 34 / 1747,
  economy fuzz 21892 / 1748, telemetry census 29 / 1748, admission 97 / 1747, marketplace
  248 / 1747, ops_fix 212 / 1747, read_pool 113 / 1747. Starving the wait so it cannot
  succeed (`for i in 0`) prints `  [FAIL] DB initialized (entities/maps/items carregados)`
  and `== Backup Restore Probe: 3 checks, 1 failures ==` with the gate red — the check
  gates the finish path, it is not decoration. `admission_gate_test` needed a second half:
  its S3 machine runs in `_process`, which the engine starts turning while `_initialize()`
  is suspended in the boot `await`, so `_bootReady` now releases S3 only after the
  synchronous suites and `frames` — the clock of the S3 timeouts — no longer counts the
  wait. Pointers moved with the lines they name:
  `deploy/ROLLBACK.md` → `tests/admission_gate_test.gd:691-796`,
  `deploy/BACKUP_RUNBOOK.md` → `tests/test_backup_restore.gd:86-113`, and
  `marketplace_depth_test.gd:300` in `tests/auction_house_wiring_test.gd` was already stale
  by 43 lines (it points at `panel.contains("\"GetAuctionPage\"")`, which lives in `:343`);
  all three now land on the code the prose claims.
- The pointer ruler then ate what the round that fed it had left behind: every citation the
  entries above moved out of date was accused by the suite that checks citations, and all of
  them were mine. `sources/db/DB.gd:228` — cited by ten harnesses as the boot wait — named
  `PreloadUpdate()`, which is not the line the sentence describes; the sentence says the call
  closes the preload, calls `Load()` and lights `isInitialized`, and that is `:233-235`, so
  all ten moved in place, one line each, without shifting a file another citation reads. The
  eleventh named a harness that this round deleted: the `ZonePolicy` entry above removed
  `tests/zone_policy_test.gd`, and the prose in `scripts/check_compose.sh` still cited it as
  the file that measures the thing — the harness-citation arm caught it as `1 vs 0`
  (`scripts/check_compose.sh → tests/zone_policy_test.gd`). Two more moved to the lines that
  actually hold the code (`tiled_map_reader.gd:627-628` for `spawn_position`/`spawn_offset`)
  and one header comment was rewritten so the bare word `name` stops being offered to the
  ruler as a symbol. Verdict read from the marker, not from the file count: `== RESULT: 3236
  checks, 0 failures ==` with the sweep's own census in the log — `538 referências
  arquivo:linha (159 em prosa fora de `.md`), 138 com símbolo nomeado na cláusula` — and
  `== GATES VERMELHOS: none ==`, `== FLAKES: none ==`. One stale pointer of the same class
  was still live in `BLIND_JUDGE_PROTOCOL.md`: it cited `.github/workflows/godot-ci.yml:415`
  for a job's `needs`, and the `+68` that the `nginx -t` step added to that workflow moved
  the number without the prose noticing. `scripts/check_doc_drift.sh` does not accuse it (the
  target is a `.yml` line and line 415 is not blank), which is the honest limit of that
  ruler, recorded rather than patched around: the citation now reads `:521-524`, names the
  shift that broke it, and says plainly that the finding it records was closed by #83.
- Two gates were red on the runner because the runner refuses them their tools, and both
  printed the shape of a product regression while saying something about the environment.
  `repo_layout_test` counted `== RESULT: 52 checks, 6 failures ==` (`##[error]6 checks falhos
  em 52`) with `índice do git lido (0 arquivos)` — the job runs in
  `container: barichello/godot-ci:4.7.1`, where the checkout belongs to the runner's uid and
  the harness process speaks as another, so git's ownership guard answered nothing; a harness
  that cannot read the repository was reporting zero files, which is indistinguishable from an
  emptied one, and all six failures were measurements taken through that index (including the
  three `tests/*.gd` accused of being dead and a stale `NEAR_FENCE` reason that is green here).
  `web_delivery_test` counted `== WEB DELIVERY: 125 checks, 6 failures ==` including
  `e2e python (estatica + sender + fila + CLI) exit 0 (rc=127)`: `OS.execute("python3", …)`
  found no interpreter because the image ships none, and "program not found" arrived dressed
  as a regression. Both halves closed on both sides. The workflow now authorizes the index
  through the scope the harness actually inherits — job-level `GIT_CONFIG_COUNT`/`KEY_0`/
  `VALUE_0=safe.directory=${{ github.workspace }}`, since a step's `git config --global` only
  reaches processes sharing that HOME — plus `--global` for `$GITHUB_WORKSPACE` and `$(pwd -P)`,
  `--system` where writable, and a preflight that fails the JOB when `git ls-files --cached`
  answers ≤ 200 files, with git's stderr in the log; and `apt-get install -y python3` followed
  by a preflight importing the stdlib the leg leans on (`glob, json, os, re, sqlite3,
  subprocess, sys, tempfile, threading, time, http.server`). The harnesses stopped trusting
  their tools: `_git()` keeps rc and stderr, `_gitWhy()` names the cause and `_gitBlame()`
  hangs it on every label that counts index files, so the same failure reads `… || ÍNDICE NÃO
  LIDO — git RECUSOU ler este diretório: rc=128, fatal: detected dubious ownership …` instead
  of a bare `0 arquivos`; `web_delivery_test` names the interpreter that ran (`perna executada
  por Python 3.14.7 | ambiente: Linux | máquina local, sem container`), counts legs that did
  not run as visible `[SKIP]` lines plus `== WEB DELIVERY SKIPS: %d (%s) ==`, and pins the CI
  provisioning with a ruler that reads the `idle-tests` job block for an executable
  `apt-get install … python3` line. Each new ruler ate the lie in situ: `git` stubbed to exit
  128 with the runner's own message reproduces the CI exactly — `52 checks, 6 failures`, six
  labels each carrying the reason — and deleting the provisioning line prints `linha
  executável do job idle-tests: AUSENTE` with `== WEB DELIVERY: 126 checks, 1 failures ==` and
  the gate red. Restored, both are green: `52 checks, 0 failures` (teardown 30/64) and `126
  checks, 0 failures`, `== WEB DELIVERY SKIPS: 0 (nenhum) ==` (teardown 30/101). One
  reservation kept in the open: in that same minute the FIRST attempt of both gates died of
  signal 11 sharing six backtrace frames (`godot+0x48252fc`, `+0x4825af8`, `+0x6c4a345`,
  `+0x6c4a58c`, `+0x6564175`, `+0x6ee90b9`), the runner retried and the retry was green
  (`== FLAKES: repo_layout_test ==`, `== FLAKES: web_delivery_test ==`); a second session
  crashed neither (`godot exit=0`, `== FLAKES: none ==`). Engine crash, not a check failure,
  not reproduced — tracked as a defect, not smoothed into the verdict.
- `content_hygiene_test` printed `0 failures` on this machine and `== RESULT: 7167 checks, 33
  failures ==` on the runner (run 36634640820, commit `1f540a1`), and the gap was not the
  harness: it was two copies of the same content, one of which nothing read.
  `presets/maps/server/**` is an ARTIFACT — `addons/tiled_import_plugin.gd:162` regenerates the
  `MapServerData` and its `SpawnObject`s from `data/maps/**.tmx` and `:169` links the `MapData`
  that becomes `MapsDB` (`sources/db/DB.gd:8`). With a warm `.godot` the engine skips a `.tmx`
  whose md5 did not change, so here the game read the committed `.tres`; CI regenerates `.godot`
  and runs `godot --headless --editor --import --quit` (`.github/workflows/godot-ci.yml`, step
  "Import assets"), which overwrites the artifact with the source. The mob roster and the boss
  ladder had been hand-written into the artifacts of ten maps and the `.tmx` had been left
  behind, so the CI import handed back 13 spawns in zone 17 (Drazil) resolving to nothing
  (`3851394706`, `4085786187`), a census of 16 phantom spawn groups, zones 25/26/27 with no mob
  group at all (`0 >= 19` on the deepest tier), the farm at 24 species against a fence of 27
  (Lynx, Goblin, Bandit gone) and bosses 4..9 missing from their own arenas — 30 `[FAIL]` lines
  in the log for 33 failures. The product fix went to the source, not the artifact: 18 spawn
  groups written back into the nine `.tmx` files that were short (12 for zones 25/26/27, 6 for
  the boss arenas) and Drazil's object list renumbered onto the artifact the game ships. Nine
  `presets/maps/server/*.tres` came along as the deterministic importer writes them. The ten
  `presets/maps/layers/*.tscn` the same edit produced were REVERTED: after normalizing
  `unique_id`, instance names and particle data the diff against `HEAD` is empty — that
  directory is a committed generated file whose ids change on every import, so the edit was
  noise and noise does not get a commit. The ruler is a fourth suite in
  `tests/content_hygiene_test.gd`: for every map in `MapsDB` it compares the MULTISET of
  monster spawns parsed out of the `.tmx` against the loaded artifact, field by field — id,
  count, `respawn_delay`, position and offset, the last two recomputed the way the import
  computes them (`tiled_map_reader.gd:627-628`, `:928`) — so divergence means the CI import is
  about to rewrite this map. Floors measure the sweep itself (40 maps paired, 269 mob groups in
  the source, both counted visible) and the verdict is `divergent == 0`; six `_multisetDiff`
  controls cover both directions (group only in source, only in artifact, count off, delay off,
  position off, offset off). Bite measured on the real file: reverting only
  `data/maps/ship/ship-hold.tmx` to its `HEAD` bytes printed 2 failures naming `'Ship Hold'`
  and listing the three groups CI would delete (`== RESULT: 7259 checks, 2 failures ==`, gate
  red); with the source current, `== RESULT: 7258 checks, 0 failures ==` and `Gate §24-8 OK`.
  The fixed point was then measured rather than inferred: a cold copy of the 3714 files named by
  `git ls-files -z`, with no `.godot`, run through the same `--import` (Godot 4.7.2 here, 4.7.1
  on the runner) returned `presets/maps/server/**` and `presets/maps/data/**` byte-identical to
  the checkout — while all 40 `presets/maps/layers/**` files moved on their own, which is what
  the ruler refuses to judge and why it reads the spawn-carrying artifacts.
- The compose build died on the runner and every gate that could have seen it was green,
  because they were all reading a value instead of resolving it. Five services declared
  `build.context: .` in `deploy/docker-compose.yml`; compose takes the project directory from
  the directory of the FIRST `-f` file — `deploy/` — resolves a relative `context` against
  that, and then resolves a relative `dockerfile` against the resolved context. So the build
  daemon was asked for `deploy/deploy/web/Dockerfile`. Same bytes in two runner logs, on two
  different commits (`126b086095d0`, `1f540a1c21a9`): `resolve : lstat
  /home/runner/work/shambleta/shambleta/deploy/deploy: no such file or directory`. Neither CI
  `config` step nor the 156-check compose gate could see it: `docker compose config -q`
  resolves neither the context nor the existence of any path, and the image ruler in
  `scripts/check_ci.sh` was checking the written `dockerfile:` against the current directory.
  The product fix is the value, not a flag: `context: ..` on all five services
  (`deploy/docker-compose.yml:45`, `:100`, `:209`, `:317`, `:372`), the only spelling that
  makes CI (checkout root plus `-f deploy/docker-compose.yml`), the README's `cd deploy &&
  docker compose up -d` and Coolify's "import this file" land on the same directory — and it
  has to be the repository root, because the Dockerfiles copy out of it (`COPY . .` at
  `deploy/server/Dockerfile:17` and `deploy/web/Dockerfile:17`). The reasoning, the runner
  error verbatim and the three invocation styles are now in the file itself, in the block that
  starts at `deploy/docker-compose.yml:442`, because this is the second round in a row where a
  runbook and a workflow disagreed about a path and only the log knew.
- Two rulers were added so the class cannot come back silently, and each was proven to bite
  before its green was believed. Section (7b) of `scripts/check_compose.sh` reimplements the
  resolution — project dir = directory of the first `-f`, dockerfile relative to the resolved
  context — and turns it into four checks: the sweep found at least ten `build:` blocks (10
  measured, across the production file and the staging merge), every resolved context equals
  the repository root, every `dockerfile:` exists at the path compose actually opens, and every
  relative `COPY` source of those Dockerfiles resolves inside the resolved context (40 sources,
  `%d` printed from the run, not from the prose). A fifth scan walks 36 files — `.github/workflows/*.yml`,
  `deploy/*.md`, `docs/**/*.md`, `scripts/*.sh`, `README.md` — and refuses `--project-directory`
  on any command line, because that flag is the one knob that would move `..` outside the
  repository; it spares comments, flag-less commands and prose that only names the knob, and
  both halves are pinned by negative control. The fixture strings are assembled as
  `"--project-" "directory"` so the ruler cannot accuse its own test, which is the second time
  this round a self-accusing ruler had to be separated from its fixture without weakening
  either. `scripts/check_ci.sh` got the same resolver on its image leg. Bite, measured by
  breaking it in place: reverting a SINGLE service's `context` to `.` printed the doubled
  `deploy/deploy/<…>Dockerfile` name and `2 failures` in each of the two gates; restored, the
  bytes are identical to what was measured and both are green — `== COMPOSE GATE: 164 checks,
  0 failures ==` and `== CI GATE: 140 checks, 0 failures ==`.
- `--progress=plain` moved in front of `-f` in both build steps of
  `.github/workflows/godot-ci.yml:473` and `:479`. The runner said so in as many words —
  `--progress is a global compose flag, better use \`docker compose --progress xx build …\`` —
  and discarded the value where it had been written, so the flag after `build` was decoration:
  the plain progress the step asked for, and the log evidence a failed build needs, were never
  there. It is now a global flag on the command, and the comment names the measured warning
  rather than a preference.
- Two prose sites were corrected to say what the file now does. `.dockerignore:9` and
  `scripts/check_compose.sh:774` both described the build context as "the root of the
  repository" while `deploy/docker-compose.yml` was declaring `context: .`, which is `deploy/`;
  the sentence was true of the intent and false of the file, which is the shape every ruler in
  this repository exists to catch.
- The lockout-duration check in `tests/login_hardening_test.gd` was an unsatisfiable wall-clock
  assertion. `RecordFailedLogin` (`sources/sql/SQL.gd:381`) stamps `lockedUntil` from
  `SQLCommons.Timestamp()` at the moment of the write (`sources/sql/SQL.gd:386`) — a
  second-granularity clock — and the check compared `lockedUntil - _now()` after reading the row
  back, so every second that elapsed between the write and the read demanded the full
  `BaseLockoutSec` from a window that had already passed. Red in the full run, green when the
  harness happens to be fast: the shape of a flake, on a runner slower than this machine. The
  duration is now measured against a clock read before the attempts. Proven three ways against
  the same suite: with 1.1 s of sleep between write and read the old form printed 94 checks and 1
  failure, the new form prints 94 and 0 against that same sleep, and with the product capped to
  grant 60 s while `BaseLockoutSec` still declares 300 the new check goes red — so the ruler
  stopped reading the calendar without stopping reading the product.
- The harness that proves #86 had never finished a run, and it took three separate defects to
  get one — each isolated by changing exactly one of them. `_spawnAgent` warmed the farm zone on
  every call, and `CreateInstance` (`sources/world/WorldMap.gd:38`) only writes
  `instances[instanceID]` (`sources/world/WorldMap.gd:40`), so the second warm-up replaced the
  live instance and left the first peer's agent standing in an orphan: the guard "two real
  PlayerAgents spawned" read a
  freed reference, which in GDScript is `== null`, printed no `[spawn bail]` line and no script
  error at all, and aborted the run at 49 checks — 23 of the 72 never executed. Reproduced 2/2
  against the committed state before the fix, green after: the instance is created only when the
  map does not already hold it, and the check names each side (`A=true B=true`) because a joint
  `and` cannot say which half died. Sessions then entered through `Peers.AddPeer`, which is not
  the product's door: `Network.Bulk` routes every peer not marked WebRTC/WebSocket to the ENet
  interface (`sources/network/Network.gd:1075`) and `NetInterface.Bulk` reads `bulks[peerID]`
  (`sources/network/Interface.gd:22`) — a row only `ConnectPeer` writes
  (`sources/network/server/Server.gd:1807`, and the offline boot self-connects at
  `sources/network/server/Server.gd:1890`, so in production the row is always there). That cost
  145 `Out of bounds get index` script errors in a run whose 72 checks were all green: the gate
  does not accept a script error when nothing fails. Third, delivery was never wired —
  `NotifyInstance` reaches only players whose own `peerID` is set, which the product writes on
  world entry (`peerID` at `sources/network/server/Server.gd:527`) — so the ruler for "the cut is
  in the effect, not only in the counter" read 0 deliveries for an assembly reason while the
  contrafactual in the same suite (`Network.ChatPlayer` called directly, peerID as an argument)
  delivered all 200. The suite opens sessions with `ConnectPeer` and releases them with
  `DisconnectPeer`, the pair the product uses, which also runs the product's own
  `RateLimit.Forget` and world removal at exit instead of leaving two agents hung. Measured on
  the fixed suite: 72 checks, 0 failures, zero script errors; R2 accepted 12 of a 200-line flood
  (the bucket quota), cut 188 and delivered exactly 12 to the client probe, while the control
  still delivered 200. Teardown had never been recorded for this harness because it had never
  completed a run — the ceiling of 64 is the lean boot, and a booted world with live agents
  leaks in the family of the other agent-spawning suites (`social_graph_test` measured 1888):
  recorded from the run with `TEARDOWN_RECORD=1`, measured 1874 into a ceiling of 2406, and the
  verifying run measured 1873.
- Every `arquivo:NN` pointer living in the conf prose was lying — three at HEAD, three
  false — and no gate could see it. `data/conf/seasons.json` pinned the
  `not IsScheduled(s1)` leg at
  "tests/season_liveops_test.gd:173" while the leg had moved to `:175`;
  `data/conf/liveops_calendar.json` justified its "no XP or chest window may cover the
  run" rule by "SuiteSettleGolden (IdleTests.gd:238)", a citation with no directory and
  no backticks whose line was neither the golden assertion (`tests/IdleTests.gd:286`) nor
  the function (`:232`); and `data/conf/economy_base_catalog.json` sent the reader to
  "EconomyCatalog.gd:64,67" for the chest price and cap — where the file now holds the
  comment *describing that move* — and to "EconomyService.gd:208-212" for the trade
  friction, four lines of chest-odds delegation. The consts had been cut into
  `sources/economy/EconomyBaseCatalog.gd`, at `:199` and `:201` for the chest and
  `:208`, `:210`, `:212` for the trade trio. The three notes now cite those lines, each in
  the house form (the symbol in backticks immediately before the pointer), which is what
  gives the extended corpus something to bite on: a clause that names nothing is a clause
  the identity ruler cannot judge, and that fresta is why these three survived. A range
  that crosses a blank line is a dead pointer here too, which is why the trade trio is
  three single-line pointers rather than one `:208-212`.
- A season opening that rolled back still handed back an id.
  `SeasonService._CreateSeasonWindow` writes the `season` row and the 064 race marks in
  one `SQL.Transaction`, and read `out["id"]` *after* the `if` rather than inside the
  committed branch. When `_StampRaceBaselines` failed — which is exactly what a database
  where migration 064 has not been applied does — the `ROLLBACK` took the `season` row
  away and the function returned the number of a season that no longer existed.
  `EnsureSeason` printed its "opened from seasons.json" line for that id, and
  `SQLBackups` counted it as `opened 1` in the season-clock log, while `CloseSeason` on
  the same id returns false (`status = 'active'` finds no row) — the operator's own log
  was the only trace of a season that could never be closed. The id is now read only on
  the committed path, so a rolled-back opening answers 0, the same answer `CreateSeason`
  already gives for "there is an active season". Leg S9 of
  `tests/season_race_delta_test.gd` renames `season_score_baseline` out of the way so the
  mark write fails for the real reason, requires `CreateSeason` to answer 0 *and* the
  `season` row census to be unchanged, then restores the table and requires the same
  opening to commit — the point of the control being that "returns 0" is also true of a
  dead facade. Measured red on the pre-fix code (it returned id 10) and green after:
  33 checks, 0 failures.
- The item recipe told the reader to run a script that does not exist.
  `docs/adding-an-item.md` said to generate the `.translation` files with
  `python3 tools/i18n/extract_i18n.py`: the tool is `tools/extract_i18n.py`, it writes a
  coverage report and can append missing keys, and the compiled `.translation` the
  `TranslationServer` actually reads comes from the engine's `csv_translation` importer.
  No ruler could see the dead command, for two reasons stacked: the doc-path ruler judges
  only `.md` tokens in prose (extending that corpus to `.py` and `.sh` had been measured
  as noise), and the four recipe docs under `docs/` were in no doc corpus at all.
  Section 27 of `scripts/check_doc_drift.sh` now reads the command lines inside fenced
  blocks of every doc someone executes — README, `docs/*.md`, `docs/development/*.md`,
  `deploy/*.md` — and requires each path-with-extension to exist in the tree, with the
  container-absolute, `res://` and glob forms filtered and each filter carrying its own
  control. Measured on the run that found it: 76 command paths across 19 docs, 8/8
  controls biting, one accusation, and the recipe now names the importer command plus the
  `i18n_catalog_test` that checks the compiled catalog against the CSV.
- Picking up a drop could delete it. `WorldDrop.PickupDrop` chained
  `PopDrop(dropID, inst)` *before* `inventory.AddItem(cell, count)`, so on a full bag
  the item left the world and never reached the player — a silent loss, not a refusal,
  and the ground was gone so there was nothing to retry. The order is now
  `CanHold(cell, count)` → `PopDrop` → `AddItem`: `CanHold` is the same `PushItem`
  consult the real add performs, so an item only leaves the floor when it enters the
  inventory. Measured by the floor-guard conservation leg of
  `tests/IdleTestsFrontier.gd` (the full-bag case must leave the drop on the ground and
  the room-y case must move it), inside the 3219-check idle gate, green 2026-09-29.
- The live-ops calendar had two measured deserts and the note in the file miscounted
  its own rows. `data/conf/liveops_calendar.json` shipped six events: nothing in the
  air on a normal day, 44 days between the ended weekend campaign and the next window
  (2026-09-21 → 2026-11-04) and 65 between the November cup and the S2 opening. The
  `tournament` axis is what stitches it, because it is the only axis where being always
  on is honest: the gem pool already exists, the modifier only announces a bigger prize
  for the window whose `ends_at` it covers, and it touches no XP, gold, keys or chests.
  Eleven `tournament` windows now cover 2026-09-23 (1790121600) through the S2 end
  (1802563200) with zero uncovered days — the largest gap anywhere in the file is
  2 days — and the last one ends on the same unix the season ends, so the agenda does
  not abandon a season in service. Suite E of `tests/season_liveops_test.gd` (E0–E7;
  the harness closes at 180 checks) measures the instant, the union gap, every day of every scheduled
  season, the neutral-value facades and the negative control that filters the cup axis
  out and gets the desert back. Writing the ruler also caught the prose lying about
  itself: `_estado_atual` swore "NOVE janelas de `tournament`" in a file holding eleven,
  and no ruler measured a single numeral in it. `_FactLiveOpsCalendarCounts` in
  `tests/doc_facts_test.gd` now counts per kind through `LiveOpsCalendar.Entries()` and
  requires every count in the note — spelled as a digit *or* as a word, which is the
  form that escaped — to equal the measurement, with a control that swaps the numeral on
  a copy and must be accused. `doc_facts_test` is 78 checks green.
- Two timing rulers in `tests/multi_instance_tick_test.gd` were read for the first
  time on a quiet host (`== NOISE-DECLARED: 0 ==`, 182 checks) and both came back red
  for different reasons. The overload leg predicted that 40 ms/step of injected spin
  would raise this process's share of the machine by 10 points and measured
  8.4% → 8.3%: the tick loop is a single thread and at the probe rung it already sat
  at 1.00 core, which on 12 cores is exactly 8.33% — a work-bound process buys
  *period* with CPU, not fraction. `ownRisePct()` now returns
  `min(cores asked for, headroom to 1.00)`, the share check moved to the calibration
  burn on the lightest rung (0.04 cores, where the prediction holds and can bite),
  and the saturated rung asserts the period delta instead; four constructed rows in
  leg (e) cover both regimes, including the saturated one, which must return zero.
  The pass-convergence ruler was charging the wrong statistic: `medianMs` is the
  median of 90 samples of engine monitors that are themselves 1-second moving
  averages, so a window holds ~3 real observations and `max − min` over three medians
  bounds nothing — the quiet census was 0.06/0.49/0.25/2.53/1.29/1.55/1.63/10.50 ms
  and 2x20 reddened on `[5.13 7.66 5.52]` while the wall period never left 33.60 ms.
  It is now the three questions the beta actually decides, each in its own ruler: a
  *majority* of passes within ±25% of the median (relational), **even the worst pass**
  inside the 33.33 ms budget (a one-window ceiling — the strongest of the three and
  the only one that survives a noisy neighbour), and total spread below *one frame
  period* (legibility witness). Five constructed rows, including this host's real
  case and the bimodal level that bites.
- The teardown ceiling was keyed on the log filename, not on the harness. The same
  boot has three names depending on who ran it (`all` calls it `rpc`, CI calls it
  `rpc-identity`, `scripts/test.sh one` calls it `run_rpc_identity_test`), so two of
  the three lookups found nothing and fell back to the 64-object ceiling — against a
  world boot that leaks ~1700. The harness name is now passed to
  `scripts/ci_gate_log.sh` by every caller that knows it, and the five aliased rows
  in `data/conf/teardown_baseline.txt` were renamed to the harness identity. This was
  not cosmetic: the `one <harness>` path is exactly what a blind judge runs, and it
  was a guaranteed false red.
- `tests/run_rpc_identity_test.gd` was the only runner that opened `SQLite` and quit
  with the DB's threaded preloads unjoined, which made its own leak count a property
  of machine load instead of a property of the harness: measured 30 inside `all` and
  1747 standalone, three runs in a row. Calling `DrainPendingPreloads` — what the
  other 28 runners do — did not fix it, and the reason is in `sources/db/DB.gd`: the
  drain only joins paths already in `preloadPaths`, and that array is filled by
  `Preload()`, so a path nobody asked for is joined by nobody. What decides the count
  is whether the async boot has *settled* when `quit()` lands. The harness waits for
  the state now: after the last transport step it polls `DB.isInitialized` under a
  wall-clock budget (20 s, not frames — frame pacing is exactly what contention
  changes) and only prints its verdict once the boot closed, the wait itself counted
  as a check. Measured after the change on a host with Steam running (load 8-18 on 12
  cores): ten standalone runs, 1747 leaked seven times and 1748 three times (one
  extra ObjectDB instance), and the run that got twenty extra CPU loops and a 3.4 s
  boot leaked 1747 too. The wait cost 1-19 ms because the boot had already settled
  when the last step landed — it is a floor, not a cost. Recorded ceiling 2247.
- The cheap doc-drift gate and the 20-minute idle gate disagreed, and the cheap one
  was losing: three `ROADMAP_COMERCIAL.md` pointers pinned onto blank lines passed
  `check_doc_drift.sh` while `run_idle_tests` accused them, twice in one pass. The
  identity ruler now also requires both ends of a cited range to have text (the name
  rule reads the range as one string, so a blank border was invisible to it), with
  four planted controls in its self-test biting, and it caught a fourth pointer the
  idle ruler never looked at — `deploy/prometheus.yml` citing an alert-rules span
  that ended on a blank line.
- The storefront could advertise a pass the checkout was going to refuse. The season
  gate (`season_offer_status`) already answered "which season's pass is this?" on the
  three money doors, but `GET /catalog` — the only public read a browser makes that
  touches the game database — answered nothing: with S2 live it still listed
  `pass.s1`, and the shipped landing page said "(S1)" in prose. The player's click
  ended in a `409 season_mismatch`, which in front of money is not a user error, it
  is the shop getting the price wrong. Now `public_catalog()` annotates every
  `pass_premium` with `season_eligible` (plus `season_id` when eligible, or
  `season_reason` and the expected `season_premium_sku` when not), and the route is
  reachable through the web proxy as `location = /catalog` — exact path, GET-only,
  its own `limit_req` zone at 5 r/s (it is a database read, so it cannot borrow the
  webhook's 25), `Cache-Control: public, max-age=60`, CSP `default-src 'none'`.
  Annotation, never filtering: `companion/test_security.py` D5 exists precisely to
  forbid items silently disappearing from the price display. Measured here: `SEASON
  OFFER` 107 → 125 checks, `SECURITY` → 63 (new part F raises a live server on a
  database built by the real 018 migration and asserts page and money return the same
  reason string), `NGINX HARDENING` → 150 checks over 7 suites, with suite G reading
  `companion/server.py` to prove the display calls the SAME gate with the SAME clock.
  The `(S1)` literal is gone from the shipped copy, and the copy ruler derives its
  file list from `deploy/web/Dockerfile` instead of a hand-written one — if someone
  ships `landing_new/` (the draft storefront, still excluded by all four
  `.dockerignore`, still hardcoding `pass.s1`), that check turns red by itself.
- `Conf` could hand the login token back as a user preference. `Type.NONE = -1` is
  the default of every getter and a Godot `Array` accepts negative indices, so
  `confFiles[-1]` is the LAST file in the list — `AUTH_TOKEN`. A `GetString(section,
  key)` that forgot the type read the credential off disk and returned it silently.
  `Usable(type)` now closes the range, and `Ensure()` closes the other hole the same
  storm came from: `Init()` was only ever called from `Launcher._ready`, so on any
  path that skipped it the array was empty and the first access was an out-of-bounds
  spray (20 `SCRIPT ERROR` from `WebPush._Save` alone) that dropped the preference
  write on the floor. `tests/conf_type_guard_test.gd` pins all of it, including a
  source sweep that refuses a future accessor that indexes `confFiles` without both
  guards.
- The config leaf knew the world, and that is why the above was invisible. `Util`
  read `SkillCommons.PerspectiveIncrease` (an isometric projection constant) from
  `UnrollPathLength`; `SkillCommons` pulls `DB`, and `DB` writes `Launcher`. Godot
  resolves the class graph when a class is compiled, and under `godot -s` that
  happens before autoloads are registered — so touching `Util` printed 41
  `Compile Error: Identifier not found`, `Conf` 43, `LauncherCommons` 42, all of them
  before `_init`. The fallout was not cosmetic: the `Launcher` class failed whole,
  `FileSystem.LoadConfig("settings")` returned null, and the process died in SIGABRT
  at teardown. Measured in the same run: `webpush_subscription_test` 134 → 0 (110
  checks), `economy_design_fix_test` 134 → 0 (92 checks). The one edge is gone — the
  function moved to `WorldNavigation`, its only caller, which already lives in the
  world graph — and the coupling rule is now a ruler that walks the graph from the
  four leaf files with the autoload list read from `project.godot`, so an edge to a
  class nobody thought to forbid is caught the same way.
- `multi_instance_tick_test` was checking the wrong row. `_measurePasses` re-measures
  every rung `MeasurePasses` times and keeps the median, but it discarded the
  leftovers with `pop_back()` — and the row it keeps is the LAST one appended, so the
  pops threw away the merged row and left a raw single-shot pass in the published
  ladder, labelled `2x20 p1`, with no `passSpreadMs`. The asserted rungs were being
  judged against one lucky shot instead of the median of three, and the convergence
  check died on a missing key. Rungs are now pruned by label.
- `companion/test_ad_ssv.py` pinned `len(server.py) == 2068`. The gate's own ratchet
  moved to 2222 when the season catalog grew a successor, so this ruler was red on
  unrelated work forever. It now reads the ceiling out of `scripts/check_god_nodes.sh`
  and asserts `<=`, with the slack printed: no number copied into the test.
- Offline drop settlement read `dropRatePPM` as ppm-of-seconds, paying ~0.54 drops/h
  against the ~105/h the live farm of the same zone delivers (a ~194x unit error).
  Drops are now ppm of KILLS — the repo's own unit, the one `BossService.KeyDropPPM`
  already used — and they ride `report.mods`, so a `weekend_drops` campaign finally
  doubles offline drops as well.
- Two rulers that measured an outcome instead of a mechanism and therefore failed on
  order, not on defect: the auto-potion check in `SuiteIdleLootPipeline` (drinking
  depends on how much the neighbour hits, so the mechanism is now driven directly with
  HP forced under the threshold) and the boss-key count in `SuiteBossLadder` (a frontier
  bonus makes any exact count across a win a 30% coin flip, so only the deterministic
  spend is asserted).
- `docs/development/testing.md` claimed the idle gate runs "137 suites"; nothing in the
  repository reproduced 137. The count is now an anchor recomputed by the drift gate.
- Five pointers into `scripts/test.sh` were false after the reaper landed: function
  bodies had moved ~40 lines, and three cites named a range that no longer held the
  function their own sentence promised. The cite of `harnesses_extra()` lived at
  `tests/deploy_ops_test.gd:6` and again at `docs/development/setup.md:80`; the cite
  of `harness_marker()` lived at `tests/deploy_ops_test.gd:7`; the cite of
  `companion_gates()` lived in the companion row, `docs/development/testing.md:115`.
  Two more pointed at unrelated code while saying what the gate does *not* check: the
  secrets comment, which lived at `tests/IdleTests.gd:6061`, cited runner line 431 to
  claim `check_secrets.sh` entered the gate list there, when the entry was then line
  532; and `tests/repo_layout_test.gd:18` cited 421-427 for the written reason a gate
  without a caller is a ruler without effect, which lived at 516-527. All five now
  resolve to the code their sentence promises. A locator is a claim too, so the four
  that name a place in today's tree were re-read on 2026-09-29: the companion row is
  `docs/development/testing.md:115`, the secrets comment is
  `tests/IdleTests.gd:6061`, the gate entry is `scripts/test.sh:589` and the no-caller
  reason is `scripts/test.sh:579-585`.
- The class those two survivors belong to is closed, not just the instances. The
  identity ruler cannot see a bare `check_secrets.sh` (its `IDENT` rejects the dot) and
  the literal ruler refuses any token living more than once in the target, so the
  sentence above sat green on a line of unrelated shell. Section 23 now also judges
  tokens shaped `name.ext` with no path, with two extra allowances — the neighbouring
  line and the blank-delimited chunk, because pointing at the block a file is discussed
  in is honest prose — and it accuses only when the name really does live elsewhere in
  that file. Measured before and after: re-planting the original lie
  (`532`→`431`) returns `[FAIL] arquivo: tests/IdleTests.gd:6018 … o nome mora em
  [522, 532]` and the gate goes red; the restored tree gives 218 pointers judged per cut
  with zero accusations and 34 self-test controls biting (five of them the new class,
  including the two that must NOT accuse).
- Prose that states a **count** of a code-derived registry was lying in four places, and
  no ruler could see it. `structure_gates()` gained the gate-log and boot-sandbox gates
  and the old total stayed written: `README.md` said "sete", `scripts/test.sh` said
  "Três", `.github/workflows/godot-ci.yml` said "Os dois", and `docs/development/setup.md`
  enumerated seven names. Only `deploy/OPS_RUNBOOK.md` was true at nine. The sentence names
  no file, no line and no snippet, so the identity, path and literal rulers had nothing to
  check — it is exactly the method this repo tells a critic to plant ("write an assertion
  no gate reads"), and the gate now reads it (see the section-26 entry under Added). All
  four places say nine, `docs/development/setup.md` stopped enumerating (the list lives in
  `structure_gates()`), and the README states the ruler instead of a count.
- `tests/tick_capacity_test.gd` reddened on a host taken by ten concurrent judges —
  `nível 200: mediana 34.64 ms não caiu contra o nível anterior (50.74 ms)` — and the same
  harness rerun alone came back green (32 checks, 0 failures; 31.82 ms at the 200-rung).
  The accusation was load, but the ruler was wrong anyway: the four rungs live in four
  different zones, so a drop can mean the *previous* rung swelled on a dirty window, and
  the harness printed no `== NOISE-DECLARED: ==` line at all — which the gate reads as
  "this harness has no timing ruler", not as zero. Monotonicity now re-measures the
  previous rung once and accepts the drop only when the re-measure is cheaper than the
  suspect window (preemption can add time, never remove it); the re-measured line is what
  reaches `deploy/SCALING.md` and the slope regression, and the window is declared. The
  harness now prints the hook unconditionally. Its header also claimed the retired
  `process_priority` sandwich had been tested in an isolated probe; what was measured is that all four rungs
  returned `0.00 ms` under the load ladder (observed on this machine in the 2026-09-28
  round; that run's log is not retained), and the reason why is now marked as inference
  from that zero rather than presented as a separation that was never measured.

### Changed
- The forge fee reads the zone the character farms in (finding #107), and the band it has
  to land in is measured at both edges. Both gold sinks of
  `sources/economy/ItemForgeService.gd` charged `base × tier²` with no notion of place: a
  tier-9 corruption at zone 27 cost 40 500 gold against a faucet of 3 771 956 gold/h —
  0.64 minutes of par farming, while the largest guild upgrade step costs 10 000 000 gold
  (`GuildLevelCostGold` at `sources/economy/EconomyCatalog.gd:289`). The fee is now
  `base × tier² × ratio^elasticity`, with `ratio` the zone's `goldPerHour` over zone 1's
  read through `FarmZoneData.GetZone` and `elasticity` the new
  `forge_fee_zone_elasticity_permille` knob, shipped at 886 ‰
  (`ForgeFeeZoneElasticityPermilleRef` at `sources/economy/EconomyBaseCatalog.gd:223`).
  The same tier-9 corruption at zone 27 now costs 3 786 686 gold — 60.23 minutes of par
  farming — and zone 1 still pays the old constants bit for bit, because the curve is
  normalized there, so nothing a fresh character pays moved. 886 is arithmetic, not taste:
  `tests/gold_sink_scale_test.gd` sweeps every reachable (zone, tier) pair of both sinks
  against a band of 60–180 minutes of par farming at tier 9, scaled by `(tier/9)²`, and
  proves the declared band `[886, 1099]` is tight on both edges — 885 breaks the floor at
  59.93 minutes and 1100 breaks the ceiling at 180.24, each in exactly one pair, and it is
  the same pair (zone 27, tier 9) that decides both. Measured 2026-09-29: the harness
  closes at 159 checks with 0 failures, and the sinks' neighbours re-ran green the same day
  — `craft_authority_test` 56, `craft_wiring_test` 316, `faucet_census_test` 62,
  `economy_knob_range_test` 67, `economy_design_fix_test` 92, `scale_test` 95,
  `balance_test` 1919 and `economy_invariant_fuzz` 21 891. An unaffordable fee stays a
  refusal rather than a debt: both paths still test `gp < fee` and answer
  `insufficient_gold`.
- Season races score the window, not the character's life (migration 064). Three of
  the four races were read off a current counter with no history —
  `character.power_score`, `character.bosses_beaten`, `guild.points` — so freezing
  the board at `CloseSeason` froze in everything the player had done *before* the
  season opened, and the prize went to whoever arrived big instead of whoever rose
  during the window. `season_score_baseline` is the zero mark: `CreateSeason`/
  `EnsureSeason` copy the live state of all three tables inside the *same*
  transaction as the `INSERT INTO season` — the two halves have different readers
  (`baselines_at` is only the label the leaderboard shows, the subtraction is the
  `LEFT JOIN`, which never consults the label), so an opening committed outside this
  transaction could promise `delta` with no mark at all — `COALESCE(b.value, 0)`
  hands back the absolute and the prize pays for work done before the window — or
  promise `current` while a partial mark is subtracted), and every
  snapshot subtracts it with `LEFT JOIN` + `MAX(0, cur − COALESCE(b.value, 0))`.
  Ordering is by the delta, which is the other half of the fix: with `limit = 1` the
  old `ORDER BY power_score DESC` cut exactly the player the race exists to find. A
  subject with no mark (born after the open, or a season predating 064) gets the
  current value back, and `season.baselines_at` makes the two regimes observable
  instead of assumed: `CommunityService.GetSeasonBoardsState` reports
  `scoring = "delta" | "current"` and `Leaderboard` says so on screen. Pinned by
  `tests/season_race_delta_test.gd` (34 checks, S1–S9, measured 2026-09-29) —
  including both legs of the confession, because pinning only the legacy `"current"`
  left a facade that always answers `"current"` passing the whole suite. The screen
  is measured too: the idle suite's `ShowSeason` block renders the board with and
  without the mark and requires the word `lifetime` to appear in exactly the
  no-mark case, so deleting the label is caught where the player would see it.
- The map rooms are in git. `presets/maps/*` sat under `# imported files` in
  `.gitignore`, but nothing imports them: `presets/maps/data/**` is what builds
  `MapsDB` (`sources/system/Path.gd:49` → `sources/db/DB.gd:280`) and
  `presets/maps/server/**` is where the boss arena mobs are spawned. A fresh
  `git clone` therefore had zero maps and the rulers that exist to prove content
  is real (`tests/balance_test.gd:648`, `tests/content_hygiene_test.gd:282`) died
  at the source. 160 files / 20 MiB tracked.
- Tracking them exposed the secrets gate: 28 lines of `presets/maps/layers/**.tscn`
  matched the cloud access-key pattern, all of them
  `tile_map_data = PackedByteArray("…")` — base64 arithmetic, not a credential. The
  exemption is structural rather than a path allowlist (`scripts/check_secrets.sh`,
  `blob_body_spared`): it requires the blob constructor before the match on the same
  line, refuses a property name that looks like a credential, and is opt-in per rule
  (only the access-key rule uses it, because the other patterns contain characters a
  base64 literal cannot). Four probes prove the limit of what is spared, and a ruler
  on the script's own text proves the flag did not leak to another rule.
- The test harness is sliced: `tests/IdleTests.gd` (kernel: fixtures, scoreboard,
  helpers) plus `tests/IdleTestsFrontier.gd` (`extends IdleTests`, the frontier
  suites). The runner loads the leaf, because one instance is the scoreboard
  (`checks`/`failures`) and the shared world fixture (`lastCharID`).

### Added
- A pointer into prose now has its *line* judged, not just its file. The identity arm of
  `SuiteEvidencePointers` asks whether the symbol a clause names lives at the cited line,
  and for a `.md` target that question had no teeth: prose declares nothing, so the symbol
  index arrives empty by design and the arm that answers from the whole file
  (`_IdentityVerdict`, `tests/IdleTestsFrontier.gd:454`) returned "the name is in this
  document" and stayed silent about the number. Found while writing the #107 register: a
  sentence locating `companion_gates()` at testing.md line 99 read green while the row that
  names it is `docs/development/testing.md:115`. The sweep gained a fourth arm,
  `_ProseTargetVerdict` (`tests/IdleTestsFrontier.gd:428`), gated by `_IsProseTarget`
  (`tests/IdleTestsFrontier.gd:414`): a prose target that writes the name somewhere but not
  inside the cited window is accused by symbol *and* by line number, and one that writes it
  nowhere returns the same silence the series ruler uses, because a name the document never
  spells is the path and literal rulers' business, not this one's.
  First contact: four accusations, four true — a range in this repo's own judge register
  that no longer held what its sentence promised, one historical cite inside
  `scripts/check_doc_drift.sh` that was written with live-pointer notation, and two in the
  prose being written that minute. All four closed by re-pointing the number or by dropping
  the backticks a stale cite never earned; no leg was exempted to get green.
  Same pass, same kind of rot, different blind spot: nine `IdleTestsFrontier.gd` locators
  (plus one elided bare range) across nine comment lines of
  `tests/drop_band_content_test.gd` and `sources/idle/FarmZoneData.gd` were off by ~1300
  lines, and no ruler could see it because none of those clauses names a declared symbol —
  they name a local, or a file, or nothing. Re-pointed to the code each sentence promises;
  the hole itself is registered, not papered over, because the honest fix for it is a
  declaration index that covers locals, not a prose-rewriting machine.
  Proof the arm bites, run every gate: three injected controls over an in-memory fixture —
  a name at the wrong line accuses, the same name at the right line is silent, a name the
  document never writes is silent — and the arm must have an opinion on exactly two of the
  three, so a "0 accusations" verdict cannot mean "0 looks". Measured with the registers
  above landed: 497 references checked line by line (134 of them prose outside `.md`), 122
  clauses naming a code symbol, 3 prose line-targets judged, 0 accusations. The count moved
  from 2 to 3 because the register describing this axis cites the very line it proves — the
  ruler read the new sentence and judged it, which is the intended behavior, not a surprise.
  The floor is 2, below the measured 3, so a paragraph being rewritten is not a gate failure
  while the axis going mute still is; the number that proves the bite is the control, not
  the floor.
- The season that is actually running declares its own pass track. `s1` in
  `data/conf/seasons.json` carries `pass_tiers` now — `max_level` 40, `bonus_start` 31,
  `bonus_gems` 20, ten `free` levels and eighteen `premium` levels — written as the exact
  mirror of `EconomyCatalog.PASS_FREE` / `PASS_PREMIUM` / `PASS_MAX_LEVEL` /
  `PASS_BONUS_START` / `PASS_BONUS_GEMS`, so nothing a player receives changed: what
  changed is where the track is *read from* (the file, through `PassService`'s existing
  per-season lookup) and that the mirror is measured. `tests/season_liveops_test.gd`
  compares the two level by level through the product's own reader (`PassTiers`, which
  normalizes JSON's string keys to int and normalizes each reward), over the union of the
  levels on either side, in both tracks, plus the three scalars; the harness closes at
  180 checks with 0 failures.
  The ruler bit on a one-field drift (`gems` 10 → 11 at level 3) by naming the level and
  both sides, which is also the first version of the helper failing its own label — the
  count in the message claimed 20 levels for a 10-level track until the level list became
  a deduplicated union. `SeasonConfig._ValidatePassTiers` grew the two refusals that the
  mirror exposed: a `pass_tiers` scalar that is present and not an integer (`_IntOf` hands
  back the catalog default in silence, so `"max_level": "30"` would have been read as 40
  and paid the track you thought you had replaced), and a `premium` level at or above
  `bonus_start`, which `PassService._GrantPassRewardRaw` overwrites with the bonus gem row
  — an award written, validated, and unreachable. Both bite: removing the 22 validator
  lines takes exactly the three new legs red and leaves the control leg (a premium level
  one below `bonus_start` validates clean) green, so the refusal is not always-on.
- The pointer rulers read the prose embedded in data. `data/conf/*.json` describes its own
  rules in `_note`, `_campos`, `_estado_atual` and siblings, and no corpus judged any of
  it: the resolution sweep (`SuiteEvidencePointers`) walked `.md` plus comment lines of
  `.gd/.py/.sh`, and section 23 of `scripts/check_doc_drift.sh` had no `.json` in `EXTS` —
  and would have skipped it anyway, since a JSON line never starts with `#`. The census
  measured on 2026-09-29: three pointers in that prose at HEAD, all three false; the
  rewritten prose carries ten. Both corpora now read
  the conf JSON, and the Godot side's input guard requires `res://data/conf/seasons.json`
  to be in the list, because a `roots` that finds nothing returns "0 broken" for the worst
  possible reason. Proven the way the house asks, in situ: repointing
  `ChestCostGemsRef` at the neighbor row makes section 23 answer
  `nomeia ['ChestCostGemsRef'] e aponta sources/economy/EconomyBaseCatalog.gd:220; o nome
  mora em [199, 219]` — with the whole corpus at 239 named pointers, 478 checked line by
  line, 0 accusations.
- The doc-drift gate grew a third pointer ruler: **literal pinning** (section 25 of
  `scripts/check_doc_drift.sh`). Sections 23 and 24 ask "does the cited line hold the
  named identifier?" and "does the cited file exist?", and both stayed green on anchors
  that pointed at the wrong code: a clause promising the port the image exposes is
  satisfied by any line with text on it, and neither ruler can see the difference. The
  new one takes the literal between backticks in the citing clause and requires it to
  occur exactly once in the target file, at the cited line (±1), inside the same
  blank-line-delimited chunk, or with every one of its words in the span. Exemptions are
  measured, not guessed: globs, tokens under eight characters, self-citations, a literal
  that is the target's own filename, and anything occurring zero or 2+ times — two
  occurrences pin nothing, and choosing one would be the ruler lying. Nineteen self-test
  controls, all of which must bite, police the clause cut (comma, sentence, line-break
  carry, the pointer's own opening and closing backticks), because the earlier drafts of
  this ruler accused honest prose and a gate that cries wolf is a gate that gets turned
  off.
- Wall-clock fences now say when they were not read. Measured on 2026-09-28, on a
  12-core host with the user's game running (load 11.6-15): the same process floor in
  `tests/multi_instance_tick_test.gd` came out 60.66 ms/step against 11.11 ms measured
  two minutes earlier, and per-player cost 370 µs against a 340 µs fence. Those reds
  were somebody else's scheduler inside this measurement, not a regression — and
  re-running until green is how a gate becomes a coin toss. The harness now probes, for
  every measurement window, what fraction of the *machine* went to other processes
  (aggregate `/proc/stat` minus this process's `utime+stime`, over `wall × cores`). The
  declared limit is 25%, and it is a consequence rather than a choice: `cpus: 2` in the
  compose admits 16.7% of neighborhood on a 12-core host, and double that is no longer
  the beta's contract. A dirty window is re-measured inside three bounds — 15 s per
  window, 90 s per run (`SHAMBLETA_NOISE_WAIT_MS`, capped at 600 s), and only for
  windows the probe itself declared dirty. If noise wins, the ruler reports `[RUIDO]`
  instead of a verdict, and the two reading rules are asymmetric on purpose: a
  *relational* claim (does the player show up in the measurement, does the deeper step
  cost less, did pausing return what was predicted) is not read at all under noise,
  because the reference window inflates too and a green becomes manufacturable by the
  neighbor; a *ceiling* that held is still a reading, because preemption can only raise
  a window's time — what fit the budget with the machine taken fit for real. Both
  decisions are pure functions (`readsTiming`, `readsCeiling`) policed by a constructed
  table in the new leg (e), next to the nine probe cases, including the discriminating
  "we occupy eight cores and the machine is ours" (a probe that forgot to subtract
  itself would call that 66.7% noise).
- That census leaves the harness. `== NOISE-DECLARED: N ==` is printed by every harness
  that has the ruler, always, including zero — absence of the line means "no ruler", not
  "no noise". `scripts/ci_gate_log.sh` turns it into a job note (green with a gap, said
  out loud) and `scripts/test.sh` closes a pass with
  `== GATES COM RUÍDO: <harness>:<windows> ==` beside `== GATES VERMELHOS: … ==` and
  `== FLAKES: … ==`. A gate listed there passed the checks it read and did not read the
  others; quoting its capacity numbers as verified requires a pass ending in
  `GATES COM RUÍDO: none`.
- `scripts/check_gate_log.sh` — a self-test of the verdict reader itself, wired into
  `structure_gates()` so `all` and CI call it through the same door. It writes synthetic
  logs (green, green-with-three-declared-windows, green-with-no-line-at-all, a failed
  check, a `SCRIPT ERROR`, a leak above the ceiling), runs the real
  `scripts/ci_gate_log.sh` against them, and executes `_noise_declared()` extracted from
  `scripts/test.sh` on the same fixtures — because two readers of one format is the
  divergence this repo keeps burying. Three mutations measured: deleting the
  notice block from the reader, breaking the extractor's anchor, changing the harness's
  hook text — each one turns the fixture red.
- The same gate then accused itself, and that is now a policed class. A `gate_sh` script's
  stdout *is* the log `scripts/ci_gate_log.sh` scans, so a `afere` label quoting the fatal
  marker text makes the gate find `SCRIPT ERROR` in a green run: `check_gate_log.sh`
  printed `16 checks, 0 failures` and was still declared red by the run. `fatal_labels()`
  reads every printed string in each gate registered in `structure_gates()` and rejects the
  fatal markers in them — the needle stays in the code, out of the prose — with two planted
  controls (a label that merely says `SCRIPT ERROR` must pass the ruler, a fixture whose
  *data* is the marker must still be caught). 27 checks.
- A killed harness used to poison the next pass, and the pass could not say so. Measured
  on 2026-09-28: `run_idle_tests` died with `godot exit=134` twice in one pass, at
  identical engine offsets, with no `SCRIPT ERROR` and no marker — the sandbox
  `.test-home/run_idle_tests/` was left holding the `testing.db` (3.4 MB) and its WAL
  (16 MB) of a run that never finished its teardown, and the next boot opened on top of
  that state. `gate()` now writes `.test-home/<harness>/.booting` before the engine
  starts and removes it only when the verdict is green, and
  `_reap_interrupted_sandbox()` — called *before* the mark, so a normal boot keeps its
  cache and migrations — deletes `data/` and `cache/` and prints
  `sandbox <harness>: último boot não terminou — data/ e cache/ reapados antes deste run`.
  The sentinel also makes the retry meaningful: a red-with-crash keeps the mark on
  purpose, so the flake-retry opens a clean sandbox instead of the same dirty state that
  killed the first attempt. `scripts/check_boot_sandbox.sh` (15 checks, in
  `structure_gates()`) executes the reaper extracted from the runner against planted
  fixtures, and its four behavioural controls are the point: sentinel present must reap,
  sentinel *absent* must touch nothing (the control that refuses "wipe always", which
  would throw away the migration cache that makes the pass cheap), sentinel with no
  `data/` must stay silent without exploding under `set -e`, and a harness booting for
  the first time must be tolerated. On top of that it checks the order in the runner
  itself — reap before the mark, mark before the engine, engine before the verdict,
  verdict before the guarded `rm` — because every one of those four links is a way to
  make the mechanism silently useless.
- The doc-drift gate grew a fourth ruler that is not about pointers: **numeral of
  registry** (section 26 of `scripts/check_doc_drift.sh`). It reads the registry where it
  is true — the `gate_sh` calls inside the body of `structure_gates()` in
  `scripts/test.sh` — and accuses any prose asserting `<numeral> gates de estrutura` whose
  numeral differs, across `.md`, code comments and workflow YAML. Narrow on purpose: prose
  that enumerates without a numeral asserts nothing and is not judged, a word that only
  looks like a numeral ("outros", "Os") is exempt with its own control, and an unreadable
  `scripts/test.sh` is not an empty registry — with nothing read, no count is approved.
  Eleven planted controls, all biting, six of them the lies of this round or the honest
  forms the ruler must not touch. Measured: 4 claims against a registry of nine, zero
  accusations, `REG_MIN=2` as a floor against the ruler going mute. The bite was checked
  on the real tree, not only in the self-test: re-planting "sete" in `README.md:106`
  returns `[FAIL] registro: README.md:106 afirma "sete gates de estrutura" e o registro em
  scripts/test.sh tem 9 chamada(s) de gate_sh em structure_gates()` and one failure in the
  verdict, and the restored tree is green again.
- `tests/repo_layout_test.gd` reads the structure gates by their SHAPE instead of by
  line budget: every non-comment line in the body of `structure_gates()` must be a
  `gate_sh` call, and the declared list of gate scripts must equal the list the body
  actually calls. The old fence (`<= 12` lines) broke the moment the body grew comments,
  and the old scan read those comment lines as calls — it invented `ci_gate_log.sh`, the
  verdict *reader*, as a gate. A declared list that a body comment can edit is how the
  README ended up saying seven while the runner said nine.

### Changed
- 21 anchors corrected, all of them checked by hand against the source before editing.
  Two came from the identity ruler (`deploy/BACKUP_RUNBOOK.md` and `deploy/OPS_RUNBOOK.md`
  naming `ENV HOME=/data` and `EXPOSE` on Dockerfile lines that had moved), seven from the
  new literal ruler, and the rest were the neighbouring citations in the same sentences —
  three compose line numbers and `alertmanager.Dockerfile:11` in `deploy/SCALING.md`, the
  `/metrics` handler in `deploy/prometheus.yml`, the warp citation in `deploy/SCALING.md`,
  two `[autoload]` ranges in `docs/development/`, the cosmetic consumers in
  `sources/economy/Storefront.gd`, the boss-instance const in `sources/world/WorldAgent.gd`
  and the backup-path pair in `deploy/docker-compose.yml`. None of them was visible to the
  gates that existed: a runbook is the file someone reads at 3am, so a line number there
  is an instruction, not a reference.

## [0.0.9] - 2026-09-21

### Added
- Rebirth system (hybrid B+C) with essence economy and attune offline
- Season pass S1 with premium track, missions, auto-claim, deluxe, double XP
- Guilds, auction house, tournament system
- Crafting with item lots, fees, and creator revenue
- 2FA TOTP (S4) with setup/disable for admin/GM accounts
- LGPD compliance: right to erasure (`DeleteAccount`), refund (`RequestRefund`), consent logging
- Device fingerprint (migration 030)
- IP ban table (migration 008)
- Fraud detection (migration 017)
- Backup automation with daily local + offsite + restore probe
- Observability: Sentry opt-in, breadcrumbs, performance tags
- Tests: 1015+ checks, backup restore probe, benchmarks, E2E implementation checks

### Changed
- Idle engine migrated to physics-coupled tick (`_physics_process`, 0.25s interval)
- ZonePolicy for O(1) tick per zone independent of player count
- Multi-transport unified (ENet, WebSocket, WebRTC) via Network.gd RPC layer
- SQLite WAL with busy_timeout=5000 and synchronous=NORMAL
- Web export with PWA, service worker, and COOP/COEP headers

### Fixed
- Settlement idempotency anchor guard
- Boss ladder double-count guard
- Auth hardening anti-bruteforce backoff
- Nested transaction corruption guard in SQL.Transaction()
- Password hash upgrade on login (hash_ver migration)
