# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-09-28

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
- Five pointers into `scripts/test.sh` were false after the reaper landed (function
  bodies had moved ~40 lines): three cited ranges that no longer contain what their own
  sentence names — `harnesses_extra()` in `tests/deploy_ops_test.gd:6` and
  `docs/development/setup.md:80`, `harness_marker()` in `tests/deploy_ops_test.gd:7`,
  `companion_gates()` in `docs/development/testing.md:99` — and two pointed at a line of
  unrelated code while saying what the gate does *not* check: `tests/IdleTests.gd:6018`
  cited `scripts/test.sh:431` (`echo "$n"`) to claim `check_secrets.sh` entered the
  runner there, when the entry is line 532, and `tests/repo_layout_test.gd:18` cited
  421-427 for the written reason a gate without a caller is a ruler without effect,
  which lives at 516-527. All five now resolve to the code their sentence promises.
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
