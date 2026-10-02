# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-10-01

### Added
- The prose of a dated register is now read by a ruler, because a commit of this project ate a
  sentence and nothing noticed (#148). The damage is in this file and it is mine: while fixing
  an anchor clause for #136, the commit deleted the OPENING line of the #107 entry, and the
  entry began with its own continuation — `to land in is measured at both edges`, with no
  subject and no bullet. It survived two commits — the one that broke it and the one that did
  not look — and three human reads, because `SKIP_NAMES` exempts the four registers from
  positional pointers and that exemption was being read as an exemption from everything. The
  new ruler charges a shape, not a level: in a dated register, a
  block that opens indented after a blank line has no parent, because every entry there opens
  with a bullet at column 0. The scope is by NAME, mirroring the exemption that created the
  hole — outside those four files an indented block is the syntax of an ordered list, so the
  census taken before writing says eight blocks open indented in the tree, seven of them
  legitimate under a numbered step in `deploy/` or `docs/` (three of those seven are exactly
  the edge the controls plant: prose continuing a code fence that just closed), and exactly one
  is the orphan. The
  first block of a file is not judged: with no blank line before it there was no mother to
  lose, and that is also the edge that makes the two implementations comparable. Eight planted
  controls, and the ones that do NOT bite carry the weight — indentation glued to its own
  bullet is not the crime, fence interiors are not read, a fence closed without a blank line
  does not open a block (the regex census would never see it, so a ruler that did would stop
  being the same census), and a file that begins indented is not an orphan. Coverage fence:
  `orfacensus` splits the text on fence markers and finds `blank line + indented line` with one
  regex, never calling `orfajudge`, and the bash section asserts both walks agree — a number
  born inside the arm dies with the arm, and that is how this class hid. The bite is proven in
  the tree, not only in the table: checking out the committed (damaged) register makes the
  ruler print an `entrada órfã` accusation naming `CHANGELOG.md` and the line that
  `abre bloco indentado depois de linha em branco`, carrying the orphan's own text as a quoted
  value, and the gate exits 1 with `1 no censo por recorte` beside its own accusation; the
  restored entry makes both zero. Restored here, same commit. Gate:
  `== DOC DRIFT: 2173 checks, 0 failures ==` with `4 registros datados lidos, 0 bloco(s)
  abrindo indentado (0 órfão(ãos))` and the eight controls biting.
- A pointer of evidence can now be an ANCHOR: `arquivo:@símbolo`, judged by the block of the
  declaration instead of by a line number (#124). The motive is price, not taste — a `path:NN`
  pointer is re-paid with a hammer on every commit that shifts the cited file, and while
  `tests/benchmarks.gd` grew from 400 to 690 lines this round it dirtied eleven of them, which
  is the only kind of work in this house that is work without being measurement. The anchor
  ruler demands three things and accuses in a fixed order: the symbol must exist exactly once in
  the target (`inexistente`, `duplo`), the clause carrying the pointer must name it (`prosa`),
  and a literal pinned in that clause must live inside the declaration's block, not merely
  somewhere in the file (`bloco`). A target with no declaration model — `.md`, `.json`, `.conf`,
  `.tscn` — is accused as `arquivo` rather than passed in silence, because an anchor is not free
  there and treating it as free would make the cheap form the trap. The form is cut-invariant,
  which is the entire point: `anchor_cut_drift` asserts that the narrow and wide cuts agree on
  anchors, on accused anchors and on judged lines, so growing a file cannot move a verdict. Two
  one-way ratchets keep the migration honest — `ANCHOR_MIN` is a floor that only rises,
  `LINE_MAX` is a ceiling that only falls — and the ruler carries eight self-test controls (one
  honest, seven planted) that must all bite, because a census read off a blind ruler is a number
  invented. Judging anchors in the dated records required fixing the walk: those file names were
  skipped before the anchor pass, so the first census reported one anchor where the tree had
  eleven. Line citations in them stay exempt — they are dated history — but anchors do not rot
  when lines are inserted above them, so they are judged. The bite was proven in the real tree,
  not in a fixture: a planted anchor to a nonexistent symbol, a prose anchor in a live doc, a
  prose anchor inside this file, and a literal pinned outside the block each came back with its
  own accusation, and both ratchet directions fired. Eleven pointers migrated in this commit,
  including the ones in `BLIND_JUDGE_PROTOCOL.md` that the growth had just broken.
- The anchor is judged in GDScript as well, and the two judges counted the same tree (#124
  slice 2). The half that lives in `tests/IdleTestsFrontier.gd` is `_AnchorStruct`
  (`tests/IdleTestsFrontier.gd:@_AnchorStruct`), which needs no model of a clause: the name no
  line declares, the name declared twice, and an anchor landing where no declaration is legible.
  `SuiteEvidencePointers` (`tests/IdleTestsFrontier.gd:@SuiteEvidencePointers`) walks it over the
  same sweep the line pointers use, and prints how many anchors the sweep saw — a census under
  eight is the ruler green by not looking, so the floor is charged. The two clause-shaped
  verdicts stay in §28 on purpose: a second model of what a clause says, in a second language,
  is the disagreement #116 and #123 register rather than double coverage, and the arm says out
  loud which verdicts it does not judge. Two judges is not redundancy either — the harness runs
  where the bash ruler cannot, because the runner image has no `python3` (#119), so an anchor
  that only rots in bash is an anchor the CI never checks. The bite was proven in the live tree,
  not in a fixture: with two anchors planted in `docs/development/testing.md` — one to a symbol
  declared nowhere, one to a `README.md` — the idle gate returned 3243 checks and ONE failure,
  and that single failure named all four accusations (two `inexistente`, two `arquivo`), while
  `scripts/check_doc_drift.sh` returned the same four across both cuts. Census with the plant in:
  21 anchors seen by each judge; with it out: 17, and 19 once this entry cites the arm by name
  instead of by line — the number the floor now holds.
- The anchor paid for itself and then billed its own pass (#124 slice 3). 103 `arquivo:NN` pointers
  became `arquivo:@símbolo` across 50 files, and the migration was computed with the ruler's own
  `anchorverdict` (`scripts/check_doc_drift.sh`): a pointer moved only when the anchor already
  returns true for the clause exactly as written — the cited interval sits inside ONE declared
  symbol of the target, that symbol's name is already in the clause, and every literal the clause
  pins already lives inside the block. None of those three is a `sed` decision, and the proof that
  no sentence moved is the diff: for those 103 only the token changed. Then the marreta sent the
  invoice for this very commit — `SuiteEvidencePointers` grew by 62 lines to host the anchor
  controls, and that displaced nine pointers the tree makes to `tests/IdleTestsFrontier.gd`. Six
  became anchors, and those six did NOT keep the sentence intact: this ruler's clause is the
  ORAÇÃO, cut at the last `,`, `;` or `. ` outside backticks before the pointer, so
  `SuiteIdleLootPipeline` sat on the far side of the decimal comma of `0,70` and the anchor was
  refused as `prosa` until the sentence was re-worded. The comma-as-boundary slices every numeric
  Portuguese sentence in the repo and is registered, not fixed in passing. Three pointers went to
  prose instead, because the claim they carried ("== instância da zona 1") is not what an anchor
  says — and one of the three was already lying at HEAD: the line it spelled is the
  `InventorySize` comment, not the instance, with a full line and no name in the clause, which no
  ruler accuses. Two more refused the automatic pass over a surviving bare digit (`SCALING.md §7`,
  `= 5 s`); the guard was right to be nervous, and both were section numbers and durations, so
  they went in by hand. What is left does not fit a script: re-measured after the pass, ZERO
  pointers migrate automatically and 165 need a sentence rewritten (163 `prosa`, 2 `bloco`).
- Growing a file that is cited by name is how this round nearly shipped a new lie. Six bare
  `FarmZoneData.gd:NN` pointers (three live files) point into `sources/idle/FarmZoneData.gd`, and
  bash does not resolve a bare filename while the GDScript arm resolves it by unique suffix — so
  every line I add there silently falsifies a citation that one judge cannot see and the other
  would blame on the wrong thing. The file was re-flowed to stay line-neutral against HEAD (13 in,
  13 out) instead of touching three other files: `git diff --numstat` is the receipt. Census of
  the pass: `ANCHOR_MIN` 19 → 128 (19 + 103 automatic + 6 paid by the tax), `LINE_MAX` 608 → 496,
  `== DOC DRIFT: 2107 checks, 0 failures ==` and `== RESULT: 3246 checks, 0 failures ==` on the
  idle gate, the eight anchor controls biting, and the harness anchor floor raised 8 → 90 on 101
  measured. The seam the migration exposed is in the GDScript
  arm, not in the docs: its name→pointer index did not know anchors, so a name glued to an anchor
  got attributed to a neighbouring `arquivo:NN` and two clauses were accused for saying the truth.
  Anchors are now indexed in the production sweep and in the fixture corpus alike, and the fix is
  proven by a two-sided control — the same claim anchored is silent, the same claim unanchored
  accuses — rather than by quieting the arm.
- What one commit pays in pointer tax, counted in this tree rather than argued: growing two
  files cost fifteen re-citations — two in `docs/development/testing.md`, ten in code comments,
  three in this file. Nine of the ten in code named a file and a number, and the number was
  wrong while every ruler stayed green: the line arm judges the file, the blank edge, the sealed
  chain and the named symbol — all four of which survive an insertion above the cited lines —
  not whether the interval still holds the construct the sentence describes. That was tested
  rather than asserted: putting one stale number back into `sources/idle/FarmZoneData.gd` left
  the ruler at 2291 checks and 0 failures, which is the difference between an invisible class and
  an unfixed one. The tenth named no
  file at all (a bare interval citation), which is invisible to a regex that requires a path
  before the colon; measuring that class gives 105 bare citations repo-wide, 20 of them outside
  the four dated registers the walk exempts, and that is #124 slice 3's first target. The ratchet
  moved with the migration it is meant to hold: `ANCHOR_MIN` 11 → 19 and `LINE_MAX` 610 → 608.
- The settle's drain of the write-ahead log is now attributed rather than argued, and the
  counterfactual is printed (#125 scope). Each settle above the ceiling is printed with its
  distance to the nearest drain, and `DrainAftermathSettles` in `tests/benchmarks.gd` is the
  window the measured series showed (5 settles), not a window chosen to buy green. The
  diagnostic answers the question the next round would otherwise guess at: if everything inside
  that window were absolved, would the red survive? Across the three runs on this disk, 46, 51
  and 65 samples sat above the ceiling and 2, 4 and 10 of them fell outside the window, against
  8, 7 and 7 that the p99 of the survivors would tolerate. Two of the three would go green, the
  third would not. The verdict itself still absolves only the hitches the ruler attributes, and
  the p99 gate remains red at 4.98× the baseline against a 4× headroom.
- YAML keys became anchors in both judges, and the migration was priced, not granted (#124
  slice 6). A compose file has no identifiers, so the symbol of an anchor into one is the
  dotted KEY PATH: `yaml_spans` (`scripts/check_doc_drift.sh`) and `_YamlSpans`
  (`tests/IdleTestsFrontier.gd`) index a map by path, and the level is the COLUMN OF THE KEY —
  so `- name: build` and its sibling `run: make` are siblings, because counting the space
  before the dash would invent a nesting the file does not have. One-segment roots (`services`,
  `jobs`, `on`) stay out of the index: they are sections, not declarations, and approving one
  would hand the prose an anchor that judges an entire file with a single word. A block scalar
  (`run: |`) is opaque — what lives inside is a script, not a pair, and indexing it would give
  an anchor to text that YAML itself does not read as a key. The dotted form is the only
  judgable one: `mem_limit` sits in three services of the same compose, so an anchor that does
  not say whose key it is has no verdict to return. Sixteen `.yml` pointers moved — the engine
  pin in `README.md`, the five images plus the two `depends_on` and the two healthchecks of
  `deploy/ROLLBACK.md` plus its `game` service, four in `deploy/SCALING.md`, and the budget
  anchor in `sources/network/server/Admission.gd` — and not one was free: `prosa` refused each
  sentence until it said the path inside the same comma-cut clause, and a bare key alone came
  back `duplo`. Nine stayed lines because they are position for real: comment lines, a repeated
  `- alert:` list item, argv flags, and `- service_started`, a value with no key that no path
  can reach. `ANCHOR_MIN` 166 → 182 and `LINE_MAX` 468 → 452; the twin's anchor floor 90 → 120
  over 155 measured (139 before), and its named-citation sum 187 → 203 = 48 identities + 155
  anchors with identities UNCHANGED, because those sixteen were positional pointers that never
  entered the identity ruler — the one conversion that adds coverage instead of moving it, and
  the reason the sum floor stayed at 180: the arm that skips history inside the anchor loop
  returns 188, and a floor above that would accuse it by census arithmetic rather than by the
  control that exists for it. The bite, in both directions: one `#Shift` line inserted at the
  top of the compose, which is exactly the event an anchor exists to absorb. On HEAD that
  mutation accused ten lines across six distinct pointers (two `branco`, three identity, one
  `service_started`); on this tree the same mutation accuses two lines, both the surviving
  runbook pointer, one per cut — and the 182-anchor census passes with zero accusations. Five
  silences and one bite from a single mutation is the claim of this slice: exemption from
  charge is not silence of the ruler. Parity was proven three ways — seven planted controls in
  bash (including `bloco` over a YAML block, via a terrain the twin does not carry because
  clause judging has exactly one owner) against six mirrored mesa controls in the twin, and the
  two judges reading the same recorte on the real tree: 222 line pointers spared and 15 anchors
  charged in both. Gates: `== DOC DRIFT: 2236 checks, 0 failures ==` and the idle twin green.
  The ruler then bit its own documentation: the first draft of the note inside
  `scripts/check_doc_drift.sh` cited those line numbers in pointer form and cost four orphan
  continuations, one identity lie about `service_started` and a two-pointer breach of
  `LINE_MAX` — recorded here because that is the thesis, and rewritten without numbers glued
  to filenames.
- INI keys became anchors in both judges, and that was the last grammar in the tree (#124
  slice 7). `project.godot` and `export_presets.cfg` have no identifiers either, so the symbol is
  again the dotted path — `application.run/main_scene`, `preset.5.options.html/head_include` —
  with one twist the YAML slice did not have: in the Godot dialect the slash is part of the
  KEY'S NAME, not a level of hierarchy, so the anchor regex had to widen its segment charset
  before a path with a slash in it could be read at all. The widening was proven harmless before
  it was used: the census stayed at 239 anchors with zero accusations, so no existing anchor was
  re-shaped by the new characters. Level 0 is `[section]`, level 1 is a column-zero `key=value`;
  a section's block ends at the NEXT section, which is why `@autoload` covers the six keys under
  it, and a key's block ends at the next declaration of level ≤ 1. A key before any section keeps
  its bare name (`config_version`) — deliberately the opposite of what the YAML slice does with a
  one-segment root, because an INI section has a real right border (`[`…`]` to the next `[`) and
  a YAML root is the whole document. `;` and `#` do not declare, and neither does anything inside
  a value that crosses lines or inside a `{…}` object: the walk carries one pair,
  (string-open, brace-depth), line to line. That parity is load-bearing and was designed to bite:
  a line holding an ODD number of quote characters, all of them escaped — `<script src=\"…` —
  keeps the string open for the machine that reads escapes and closes it for the one that does
  not, and the escape-blind judge then indexes `crossorigin=` as a key and swallows the real key
  that comes after the closing quote. Thirteen pointers moved: nine charged by bash (five in
  `deploy/WEB_SLIM.md`, two in `docs/development/setup.md`, two in `docs/development/debugging.md`)
  and four read only by the twin (`sources/gui/GuiUiScale.gd`, twice in `tests/panel_fit_test.gd`,
  once in `scripts/export_web.sh`) — those four are the reason the model is in both judges, and
  they are #132 in one sentence: a range of config lines cited from a harness comment is the
  class that rots loudest and was invisible to the cheap gate. None was free. `prosa` refused the
  sentences until they said the path inside the same comma-cut clause, two of the twelve new
  controls were blind on the first run — one expected to pass and came back `prosa` because a
  comma had cut the clause between the literals and the symbol, and one expected `prosa` and came
  back `duplo`, because accusation is a fixed pipeline and a planted expectation has to know the
  order. `ANCHOR_MIN` 239 → 253 and `LINE_MAX` 406 → 393, thirteen each way, and for the first
  time the two judges agree class-by-class on the recorte: 222 line pointers spared and 22 anchors
  charged, in both. The twin carries ten of the twelve controls as its own mesa — the two it does
  not are `prosa` and `bloco`, clause, and clause has exactly one owner. Gates:
  `== DOC DRIFT: 2146 checks, 0 failures ==` and the idle twin green at 3313 checks, its anchor
  census now 225 with zero accusations. The ruler bit its own documentation twice in one slice
  and both are recorded here because that is the thesis: the harvest note inside
  `scripts/check_doc_drift.sh` cited a range of `project.godot` lines in pointer form and became
  the one pointer the slice was supposed to delete, and the comment in the twin that explains why
  the slash entered the regex cited an anchor without naming the path in its own clause, which
  came back accused twice — an explanation of a rule is a citation, and is charged as one.

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
- A chest-cap comment cited a 60 s footprint gate three hundred lines away from the gate it meant, and
  only the naming requirement could find where it actually lived (`#156`). `sources/idle/OfflineSettle.gd`
  asserted "gate de pegada de 60 s em `Server.gd:490`", but line 490 is `DeleteCharacter` — a login/peer
  check with no footprint logic in it. The gate the sentence meant is real, just elsewhere:
  `Peers.Footprint(peerID, "open_chest", NetworkCommons.FootprintGateMs)` at line 1087, inside `OpenChest`
  (`sources/network/server/Server.gd:@OpenChest`), and the 60 s ceiling is `FootprintGateMs` = 60000
  (`sources/network/NetworkCommons.gd:@FootprintGateMs`). The pointer had rotted onto a completely
  different function, and it escaped the identity ruler for the campaign's standing reason — the clause
  named only a bare `Server.gd:490`, not a column-zero declaration, so there was nothing to check the line
  against and a citation sitting in the wrong function stayed invisible by construction. Forcing the
  symbol `OpenChest` is what made the sentence open its target and led the search to the real gate. This
  one behaves differently from the previous slice on the aggregate: that pointer had never been read
  line-by-line (it named no declaration), so retiring it trades one walk-read for one anchor-read — the
  census moves to 321 anchors against 359 line pointers while `== DOC DRIFT: 2114 checks, 0 failures ==`
  holds unmoved, the total only falling when a dead pointer was ALSO costing the identity or literal
  sections a read. The entry's two `arquivo:@símbolo` citations are charged inside the register, lifting the
  committed tree to 323 anchors against 359 pointers and `== DOC DRIFT: 2116 checks, 0 failures ==` (clean
  clone −1, the #157 build-artifact pointer).
- Three more harness comment pointers had rotted at the line level while remaining true at the function
  level, and a fourth class was confirmed not to be swappable at all (`#156`). Each of these clauses had
  escaped the identity ruler for the standing reason — it names a method call or a bare file, not a
  column-zero declaration, so there was nothing to check the line against — and adopting the anchor forced
  the name, opening each target: `BossProgressionService.gd:283` sits in `SettleBossResult`
  (`BossProgressionService.gd:@SettleBossResult`) on the exact `randf() < FRONTIER_KEY_CHANCE` →
  `GrantBossKey(…, "frontier_bonus")` roll the comment describes; `IdleTests.gd:4661` was NOT the trade it
  claims — that line is `SuiteMoneyFunnel`'s `DELETE FROM telemetry_event` cleanup, and the trade that
  consumed the daily slot lives earlier in the same `SuiteMoneyFunnel`
  (`IdleTests.gd:@SuiteMoneyFunnel`), which the function-level anchor reaches honestly where the bare line
  number pointed at the wrong statement; and `scripts/test.sh:721` is precisely the
  `gate_sh … check_secrets.sh` call the prose credits for "measuring 4", inside `structure_gates`
  (`scripts/test.sh:@structure_gates`). Measured on this working tree, the three conversions alone are 317
  anchors against 360 line pointers and `== DOC DRIFT: 2111 checks, 0 failures ==`, identity `0 acusacoes`
  and literal `0 acusações` — the naming checked each real span, and the literals it could pin
  (`frontier_bonus`, `check_secrets.sh`) are present in the target, not evaded. What this slice does NOT
  convert is a different problem, listed to stop pretending it is mechanical: `Formula.gd:229` is the key
  drop *event* inside `ApplyXp`, but the "0,2%/kill" rate the same sentence cites is defined in
  `RollsKeyDrop`, so anchoring to `ApplyXp` would move a claim about a rate onto a symbol that only rolls
  it — a truth call, not a swap; `Shop.gd:265` straddles `ShowDailyShop` and a checkout branch with no
  single owning declaration; `Server.gd:490` names a "gate de pegada de 60 s" but line 490 is inside
  `DeleteCharacter`, a login/peer check — the pointer is rotted onto the wrong function and the real gate
  is elsewhere. And two are simply not anchorable: `nginx.conf:174/205` (no declaration model for `.conf`)
  and `ci_gate_log.sh:42` (the file declares no column-zero function, so `@` resolves to nothing) — both
  stay honest line pointers, the disposition the campaign has been reserving for exactly these. With this
  the mechanically-anchorable comment pointers in `#156`'s three files are exhausted; this entry eats three
  charged `arquivo:@símbolo` citations inside the register — its positional line references are spared from
  the census, which is why the pointer count holds at 360 while the anchors climb to 320 — lifting the
  committed tree to `== DOC DRIFT: 2114 checks, 0 failures ==` (a clean clone prints one less, the #157
  build-artifact pointer).
- The last anchorable comment pointer in `#156`'s test.sh was rotted and its sentence named the wrong
  file — and anchoring it is what exposed the second lie (`#156`). `scripts/test.sh` justified its parse
  pre-check with "`run_idle_tests.gd:76` faz `load()` de `IdleTests.gd` e chama `.new()`", but line 76 is
  a comment (`# A FOLHA da hierarquia de suítes`); the load and the instantiation are `load("res://tests/
  IdleTestsFrontier.gd")` and `suitesScript.new()` at lines 81-82, inside `_run_tests`
  (`run_idle_tests.gd:@_run_tests`). The identity ruler had never bitten the old pointer for the
  standing reason — the clause named `.new()` and `load()`, method calls that are not column-zero
  declarations, so there was no symbol to test the line against. Naming `_run_tests` to make it anchorable
  then forced the file question: the pre-check does not load the kernel `IdleTests.gd`, it loads the
  frontier `IdleTestsFrontier.gd`, and the kernel is parsed only transitively as that class's parent. The
  anchor carries the correction the pointer had hidden. Measured on this working tree: the conversion
  alone is 313 anchors against 363 line pointers, `== DOC DRIFT: 2116 checks, 0 failures ==`, with the
  literal ruler still `0 acusações` because `load()` (three times in the span) and `IdleTestsFrontier.gd`
  (code plus comment) are both non-unique and so exempt — the naming requirement checks the real target
  without pinning a literal that would force a false match. This entry eats one `arquivo:@símbolo` citation
  charged inside the register, lifting the committed tree to 314 anchors against 363 line pointers and
  `== DOC DRIFT: 2117 checks, 0 failures ==` (a clean clone prints one less, the #157 build-artifact
  pointer). The sibling pointer the same
  file cites, `ci_gate_log.sh:42`, is NOT converted: `ci_gate_log.sh` declares no column-zero shell
  function, so there is no symbol to name and a `@` would resolve to nothing — it stays an honest line
  pointer, the same disposition as the `.conf` and header-comment pointers the campaign has been leaving.
  With this, the three files `#156` names are done: IdleTests.gd and OfflineSettle.gd in the two prior
  slices, and the one anchorable comment in test.sh here.
- The two pointers the previous slice deliberately left as "a truth call, not a pointer swap", and this
  slice makes that call on both (`#156`). They had been framed as false-about-their-symbol, and the fix
  was to find the sentence's actual witness rather than mint a lie with a name on it. The i18n pair swore
  the two sole call sites of `"Attack"` were "`sources/actor/ActorCommons.gd:171`,
  `sources/cell/CellCommons.gd:95`"; the first was honest (line 171 is inside `STATE_NAMES`
  (`sources/actor/ActorCommons.gd:@STATE_NAMES`), which does hold `"Attack"`), but the second was the lie
  the last commit named — line 95 of CellCommons does not touch the string, while the cell's real use is
  the `Modifier.Attack: return "Attack"` at line 110, inside `GetModifierDisplayName`
  (`sources/cell/CellCommons.gd:@GetModifierDisplayName`). Anchoring to that function moves the citation
  onto the return that actually emits the label, so the sentence now names where CellCommons uses
  `"Attack"` instead of pointing at a line that does not. The FarmZoneData case was the same shape read
  the other way: the comment "comentário de GetDropForRoll, `FarmZoneData.gd:401`" names `GetDropForRoll`
  but line 401 lies inside `GetDropPool`, and the "com os 200 rolls … 28 dos 57 itens ficavam
  inalçáveis" remark is at lines 527-529, inside `GetDropForRoll`
  (`sources/idle/FarmZoneData.gd:@GetDropForRoll`) — so the named symbol and its own pointer disagreed,
  and re-anchoring to the named symbol is what made them agree. Measured on this working tree, which has
  `build/`: the three conversions alone print 309 anchors against 364 line pointers and `== DOC DRIFT:
  2115 checks, 0 failures ==` — three line pointers died (the pair plus FarmZoneData), each worth one
  read, while the literal ruler stays `0 acusações` because `"Attack"` is unique inside both spans and so
  the naming requirement that now forces the check is satisfied by the real target, not evaded. This
  entry then carries three of its own `arquivo:@símbolo` citations, charged inside the dated register
  exactly as #148 requires, which lifts the committed tree to 312 anchors against 364 line pointers and
  `== DOC DRIFT: 2118 checks, 0 failures ==` — the three reads this slice paid off are re-added by the
  three anchors its own entry eats; a clean clone prints one less, 2117, the #157 build-artifact pointer
  neither added nor removed here. The full idle suite is left to CI under "run locally only the gate a
  change touches" — a comment-only anchor edit cannot move any of its 3313 checks, and both census
  ratchets (ANCHOR_MIN 253, LINE_MAX 393) sit far from 312/364.
- Two harness pointers had drifted off their own sentences, and the naming requirement this slice
  obeys is what moved them back (`#156`). A comment in the kernel `tests/IdleTests.gd` swore that when
  `Monitoring` lost `SetPlayer`, "`Map.gd:125` continuou chamando na chegada do jogador local ao
  mapa" — but line 125 is `entity.stat.race = entry.race`, and the call that kept firing,
  `Monitoring.SetPlayer(entry.nick)`, is eight lines later inside `SpawnEntity`
  (`sources/map/Map.gd:@SpawnEntity`). A sibling comment said "`GuildPanel.gd:74` faz
  `GuildWithdrawGate.new()`" while line 74 is `var _overrideAccount : int = 0`; the construction is on
  line 79 — `var _withdrawGate : GuildWithdrawGate = GuildWithdrawGate.new()` — so it is the field
  `_withdrawGate` (`sources/gui/GuildPanel.gd:@_withdrawGate`), not line 74, that does the thing.
  Neither had been accused by any ruler, for the reason this slice keeps re-meeting: a line pointer is
  read against the declaration its clause names, and a clause naming only a `.new()` call and a bare
  `Map.gd` names no declaration, so the identity and literal sections had nothing to test and a body
  that relocated under a later edit left its line number stranded in silence. Adopting the anchor is
  what forces the sentence to say the symbol, and saying the symbol is what made these two open their
  target. Two honest conversions ride with them — the newbie-boost rule `Formula.gd:212` is `ApplyXp`
  (`sources/actor/stat/Formula.gd:@ApplyXp`), and "um item por roll, nunca quantidade"
  `FarmZoneData.gd:513` sits inside `GetDropForRoll` (`sources/idle/FarmZoneData.gd:@GetDropForRoll`) —
  and the slice stops at four because the pointers it left are a different problem than the ones it
  killed: `FarmZoneData.gd:401` names `GetDropForRoll` while line 401 lies in `GetDropPool`, and the
  i18n pair calls `sources/cell/CellCommons.gd:95` a use of the `"Attack"` string that CellCommons does
  not contain — those sentences are false about their own symbol, so re-anchoring them would mint a lie
  with a name on it; they need a truth call, not a pointer swap, and stay line pointers for a
  follow-up. Measured on this working tree, which has `build/`: the four conversions alone print 302
  anchors against 367 line pointers and `== DOC DRIFT: 2115 checks, 0 failures ==` — four line pointers
  died, each worth one read, so the total drops 2119 → 2115 while the anchors rise 298 → 302. This entry
  then carries four of its own `arquivo:@símbolo` citations, charged inside the dated register exactly as
  #148 requires, which lifts the committed tree back to 306 anchors against 367 line pointers and
  `== DOC DRIFT: 2119 checks, 0 failures ==`: the four reads the slice paid off are re-added by the four
  anchors this entry eats, so a dated register that documents a measurement also pays for it. A clean
  clone prints one less, 2118 — the #157 build-artifact pointer, neither added nor removed here. The run
  carries `0 acusações` and self-test 29/29. The GDScript twin read the same committed tree: 278 âncoras
  vistas pela varredura, four above the 274 the code slice printed before this entry existed and eight
  above the 270 of the debugging.md slice, `0 acusadas`; its recorte charges 45 âncoras de história
  inside the register — the 41 the code slice left plus these four — against 241 spared line pointers,
  and closes the same `== RESULT: 3313 checks, 0 failures ==`, the census up four and the aggregate
  unmoved (#152 standing), no red gates, no flakes and teardown 1869 of a 2401 ceiling.
- A line pointer that names no declaration had rotted onto the wrong function, and no ruler could see it
  because the range only ever had to be non-blank (`#156`). `docs/development/debugging.md` swore that
  `DrainPendingPreloads` "é chamado no último hook de árvore ainda viva do autoload —
  `sources/launcher/Launcher.gd:254-258`". Those five lines are `Reset()` freeing `Debug` and renaming
  `Action`; there is no drain call in them. The call is `DB.DrainPendingPreloads()`, one function later,
  inside `_exit_tree` (`sources/launcher/Launcher.gd:@_exit_tree`), a hook whose own comment says "Last
  hook that still runs on a live tree" — the sentence described `_exit_tree` while its pointer sat in
  `Reset`. The identity and literal rulers bite a pointer only through the declaration its clause names;
  a clause that names nothing hands them nothing to check, so the fifty-line drift between the code that
  moved and the numbers that did not was invisible by construction. That is the argument for #124 killing
  the pointer class rather than re-auditing it: a symbol name survives a reflow that relocates a body, a
  line number does not. The two remaining pointers in the same file were honest and converted without
  finding a lie — `FSM.gd:41-47` is exactly `EnterState` (`sources/launcher/FSM.gd:@EnterState`) and
  `Network.gd:1190-1194` is exactly `_init` (`sources/network/Network.gd:@_init`) — and one was kept a line
  pointer on purpose: `sources/web/WebPush.gd:11-20` cites a module-header comment, not a declaration, so
  the anchor format has no symbol to name it and converting would trade a precise text reference for a
  whole-file span, the same declared cost #153 paid for `alerts.rules.yml`. Measured on this working tree,
  which has `build/`: 298 anchors against 371 line pointers, `0 acusações`, self-test 29/29 — three of the
  six anchors this slice added over the runbook slice are the entry's own three citations and the other
  three are the converted pointers, which also took three `arquivo:linha` off the ledger (374 → 371). The
  three killed pointers had each been read line by line by the identity section, so paying them off lowers
  the bill: the run prints `== DOC DRIFT: 2119 checks, 0 failures ==` here and `2118` in a clean clone of
  the same content, the one apart that #157 records for the build-artifact pointer. The GDScript twin read
  the same tree and charged the three converted symbols plus the three this entry cites: 270 âncoras vistas
  pela varredura, 0 acusadas, and the same `== RESULT: 3313 checks, 0 failures ==` — the census moved +6
  while the aggregate did not budge, which is #152's finding standing: the census is a line the walk prints,
  not a check per anchor.
- Eight positional pointers in `deploy/OPS_RUNBOOK.md` became ten anchors, and the clause that now has
  to name its declaration turned up a range that had been billing three functions as one (`#153`). The
  canary paragraph says what happens after the `touch` and cited `sources/world/ShutdownCanary.gd:28-59`
  as a single thing. That range is three declarations: `CheckCanary()`
  (`sources/world/ShutdownCanary.gd:@CheckCanary`) refuses new connections, `ShutdownStep()`
  (`sources/world/ShutdownCanary.gd:@ShutdownStep`) broadcasts the warning, `OnShutdownStep()`
  (`sources/world/ShutdownCanary.gd:@OnShutdownStep`) drops the peers that remain — and the two messages
  the same sentence promises, "a 30 s e 15 s", are not inside the cited range at all: they are the const
  `shutdownMessages` (`sources/world/ShutdownCanary.gd:@shutdownMessages`), which the range never covered.
  Nothing had noticed, because an unnamed pointer has exactly one duty, which is not to be blank. Each of
  the ten citations was opened before being written: the 404 row lands on the `Handler`
  (`companion/server.py:@Handler`) whose GET fallthrough answers `{"error": "not_found"}`, the compose row
  on `services.web.depends_on.companion` (`deploy/docker-compose.yml:@services.web.depends_on.companion`)
  which does ask `condition: service_started`, the cadence row on `Run()` (`sources/sql/SQLBackups.gd:@Run`)
  where `lastDailyBackupTimestamp` is still born from `SQLCommons.Timestamp()` while its neighbour
  `lastMetaJobTimestamp` is born in `0`, and the CI row on `jobs.code-health`
  (`.github/workflows/godot-ci.yml:@jobs.code-health`), which runs `bash scripts/test.sh structure`. What
  the conversion gives up is stated rather than buried, and in two places it is a hole in the ruler and not
  a shortage of will: `deploy/alerts.rules.yml:102` stays a line pointer because the YAML model addresses a
  target by KEY PATH while a Prometheus rule is addressed by the VALUE of its `alert:` inside
  `groups[].rules[]`, so no key path can name it (filed as #155); and the `Handler` above, with the `Store`
  (`companion/server.py:@Store`) of the stateless row, anchors a whole CLASS because `DECL_PY` is
  column-zero — `do_GET` at `companion/server.py:1412` and `connect` are not declarations to this ruler, so
  a sentence about one branch of one method is now judged against a two-thousand-line block (filed as #154).
  Measured in a clean worktree at `43e9624` — no `build/`, so no tree the CI does not also have — the
  untouched base prints 273 anchors against 382 line pointers and `== DOC DRIFT: 2127 checks, 0
  failures ==`, and that same tree with only this runbook replaced prints 283 against 374 and `2112
  checks`, `0 acusações`, self-test 29/29. Applying the six edits one at a time to it moves the total by
  -5, +4, -2, -3, -7 and -2, and in one tree those marginals are additive: they sum to the joint -15
  (2127 → 2112) to the check, and one of them is positive. Each hunk is measured on its own rather than
  collapsed into a formula because a pointer `arquivo:linha` is also read line by line by the identity
  and literal sections whenever the sentence names a declaration — the mechanism #152 wrote down — while
  an anchor is billed once, so paying the ratchet down lowers the bill; the run that proves they add is
  this one. The entry above quoted `2128`, and it did not lie: `deploy/WEB_SLIM.md:78` cites
  `build/Web/index.html` at line 149, a generated file no fresh clone has, and planting that one ignored
  file into the clean worktree moves the same commit from 2127 to 2128 and this conversion from 2112 to
  2113; reverting only `CHANGELOG.md` to `91fa546` prints 268 / 382 / 2122 in the clean tree and 2123
  planted, so #152's real marginal is five anchors and five checks in either tree, and its closing `2128`
  is the number its own built desk printed. #152 was reading a desk that had built; the CI reads a tree
  that has not, and the two totals differ by exactly the one pointer whose target is a build artifact.
  So this entry's numbers name their tree: this working tree, which has `build/`, prints
  `== DOC DRIFT: 2122 checks, 0 failures ==` and a clean clone of the same content prints `2121`, and
  that gap is filed as #157 rather than smoothed over, because a dated register that quotes a check
  total is quoting a measurement of one machine. The census is not affected — 292 anchors against 374
  line pointers in both trees — only the literal section, which judges a pointer when the target exists
  and says nothing when it does not. The GDScript twin could not be run narrower than the whole
  idle gate: `bash scripts/test.sh one IdleTestsFrontier` dies at compile with
  `Identifier not found: Launcher` before printing a single check, which is #130 standing and is why a doc
  change pays for a full gate. Its pass on the runbook-only tree printed 255 anchors, ten above the
  245 that `43e9624` printed — the runbook's ten, the same delta the bash census shows — with 0 acusadas,
  and closed `== RESULT: 3313 checks, 0 failures ==`, `== GATES VERMELHOS: none ==`, `== FLAKES: none ==`,
  teardown 1869 of a 2401 ceiling. The 3313 did not move with ten more anchors, which is the #152 finding
  standing: the census is a line the walk prints, not a check per anchor. This entry is then nine more
  anchors and no charged pointer, so the pass that closes the gate reprints 264 with 0 acusadas and the
  same `== RESULT: 3313 checks, 0 failures ==`, and the bash ruler on this tree prints 292 anchors against
  374 line pointers with `== DOC DRIFT: 2122 checks, 0 failures ==`.
- Eleven line pointers in `deploy/BACKUP_RUNBOOK.md` died, and the clause that now has to name its
  symbol turned up three that had never pointed where the sentence said (`#152`). The mechanism that
  hid them is narrow and worth writing down: a line pointer IS read line by line, but only when the
  sentence around it already names a declaration — 354 of them were charged that way before this
  edit, 332 after. An unnamed pointer has one duty, which is not to be blank. The anchor format has
  no unnamed form, because `prosa` accuses a pointer whose clause does not name the symbol it cites,
  so adopting it forces the sentence to declare the declaration it means — and then three of these
  declarations turned out to be about a different job than the sentence. Retention: §2 said 7 daily /
  4 weekly / 12 monthly was declared at `sources/sql/SQLCommons.gd:34-38`; those five lines are the
  tail of the LEDGER-retention comment and its two constants, so the range ends on
  `LedgerRetentionIntervalSec` (`sources/sql/SQLCommons.gd:@LedgerRetentionIntervalSec`) and
  `LedgerRetentionEnv` — a different retention of a different store, and the reason an operator
  reading for "retention" stops there is that the very next line does cite the pruner. The backup
  limits are `BackupLimits` (`sources/sql/SQLCommons.gd:@BackupLimits`). Cadence: §2 cited the trigger as
  `sources/sql/SQLBackups.gd:149-162`, which is the tail of the season clock and the ledger-retention
  job, while the daily/weekly/monthly firing is at 164-180 inside `Run()`
  (`sources/sql/SQLBackups.gd:@Run`). Snapshot: `sources/sql/SQLBackups.gd:167-170` is the daily's
  offsite push and the opening of the weekly copy, and the player snapshot fires at 182-185, also
  inside `Run()` (`sources/sql/SQLBackups.gd:@Run`), on the cadence `BackupPlayersSec`
  (`sources/sql/SQLCommons.gd:@BackupPlayersSec`). None of it is drift, and that is checked rather
  than asserted: `sources/sql/SQLBackups.gd` has not been touched since `2fad68b` (2026-09-27) and
  `sources/sql/SQLCommons.gd` since `855b0a7` (2026-09-28), `git blame` puts the three sentences at
  `2fad68b`, `855b0a7` and `689c9e7` (2026-09-30), and `git show` of each of those commits' own trees
  holds `BackupLimits` at 45-49 and the cadence at 164-180 — false at birth, and false for four days
  because the format could not be wrong. The third one is the finding inside the finding: `689c9e7`
  is the commit that called itself "A âncora liquida 103 ponteiros numa passada", and in this very
  file it converted three pointers to anchors — including the `PruneBackups()` citation on the very
  next line below the lying retention range — while the range itself stayed. What the conversion
  gives up is stated rather than buried: `Run()` is a 104-line block, so a cadence sentence anchored
  to it is now judged as "does this fire inside the worker's own loop" and no longer claims a line,
  and one true pointer that pinned three constants by range (`:13-15`) became three named anchors
  because a range cannot be charged a name. Two pointers stay lines:
  `deploy/server/Dockerfile:37` for `ENV HOME=/data`, because a file with no extension has no
  identity model in either judge, and `tests/test_backup_restore.gd:86-113`, a slice of a body inside
  a fenced recipe block where an anchor would be strictly coarser than the claim — opened and true
  today. The runbook slice alone moves the repo census 255 → 268 anchors against 393 → 382 line
  pointers and 2147 → 2122 checks, the first pair measured on the untouched tree in a clean worktree
  at `91fa546` and the 2122 re-measured on the same tree with only this runbook replaced; this entry
  is then five more anchors and six more checks, so
  the run that closed the gate prints 273 anchors against 382 line pointers, `0 acusações` and
  `== DOC DRIFT: 2128 checks, 0 failures ==`. The GDScript twin read 240 anchors on the runbook slice
  and 245 with this entry in the corpus, 0 acusadas nas duas passadas, e fechou
  `== RESULT: 3313 checks, 0 failures ==` em ambas: o censo de âncora é uma linha impressa pelo walk,
  não um check por âncora, então o que se move de uma passada para a outra é só o número daquela linha.
- The attribution return leg accused the runner and passed here, and neither verdict was about
  the game (`#151`). `tests/multi_instance_tick_test.gd` demanded that the work come back to
  within 15% ABSOLUTE of the full rung. That sentence compared a single window — both the pause
  and the return legs call `_measure`, one pass — against the three-pass median the level was
  recorded with (`_measurePasses`, `MeasurePasses = 3`), in a file whose own `PassAgreeTolPct`
  confesses ±25% between three passes taken back to back, with two other windows lying between
  the two readings it was comparing, on a rung where the runner delivers a 66.49 ms step period
  with the loop pinned at 1.00 core while the work it measures is 123.91 ms: past the knee,
  where `medianMs` is not a per-step quantity any more. Run 36925101247 printed
  `[FAIL] e o trabalho volta quando as instâncias voltam (1.40 -> 98.64 ms, tolerância de 15%
  do degrau cheio 123.91 ms)` — 97,24 ms of a 119,40 ms marginal cost had come back, 81% of it,
  and the ruler called that "the work did not return". The predicate the leg now bills is
  `resumeRecovers` declared at `tests/multi_instance_tick_test.gd:@resumeRecovers`: it charges
  the SAME marginal cost as a fraction returned, over the floor `ResumeRecoverFloorPct = 0.70`
  declared at `tests/multi_instance_tick_test.gd:@ResumeRecoverFloorPct` — and 0,70 is not a
  new number: it is the identical machine-noise allowance `MonotonicFloorPct` already grants a
  rung, and the pause leg has always billed in marginal cost (`AttributionFloorPct`). A dead
  denominator — full rung equal to level 1 — reads FALSE, never vacuous, because a ruler that
  greens with nothing predicted greens by construction. The constant this leg was supposed to
  carry, `ResumeFloorPct = 0.15`, was declared and never read: the check hardcoded its own 15%.
  Five controls planted on the mesa, as every pure predicate in this file is bitten — the exact
  CI triple green at 81%, nothing returned (destroyed rather than paused) RED, half the marginal
  RED because the return floor sits above the pause floor, exactly 70% green because the floor
  is inclusive, dead denominator RED. Re-run here: 97,46 -> 1,13 -> 95,01 ms, 99% of the
  marginal returned and `== RESULT: 249 checks, 0 failures ==`, `== NOISE-DECLARED: 0 ==`,
  `== GATES VERMELHOS: none ==`, `== FLAKES: none ==`, teardown 1747 inside the measured
  ceiling 2247. The old form also passed on this machine — by 2,45 ms of deviation sitting
  inside 14,62 ms of tolerance, which is margin, not measurement. Nothing here moves a
  ratchet or re-baselines a level: what changed is WHAT is compared.
- The anchor ruler accused with a stutter, and the fix was caught by the ruler itself. The
  `arquivo` motive returned the extension already carrying its dot while the sentence added
  another, so every accusation of an anchor in prose printed a doubled dot — a cosmetic defect
  in the one part of the verdict a human reads to decide whether the ruler is right. Rewriting
  the comment that records it, in backticks, put that doubled name into the script's own prose,
  and the path ruler charged it as a citation to a file that exists nowhere: the self-referential
  tax #124 exists to kill, collected here on the sentence describing the kill.
- The offline settle paid four statements per dropped item identity, in a loop. `_Apply` called
  `AddItemToCharacter` once per hash and each call was a SELECT of the stack, an UPDATE or INSERT
  of it, an INSERT of the `item_instance` lot, and a `SELECT last_insert_rowid()` to fetch the uid
  the settle then threw away. `AddItemsBatchToCharacter` writes the same rows as two multi-row
  statements per slice of up to `GrantBatchSlice` identities — 512, because nine bindings per lot
  against SQLite's 32766 host-parameter ceiling — so a collection of many days passes through here
  more than once instead of blowing up the connection. It keeps the two rules the per-item path
  existed to enforce: one lot per identity, never merged, because the ledger and the escrow (#94)
  need the lineage, and `bound` read from the cell, never from the name (#88). It also closes a
  window the old path carried: the stack used to be read, summed in GDScript and written back
  absolutely, while the batch writes `count = item.count + excluded.count` and lets the engine do
  the addition in the statement. The probe's census now reads 12.00 counted round trips per
  settle inside the 8–16 budget this ruler has always demanded.
- The web image could not be built, and the reason was a directive in the wrong context.
  The CI's `Build Deploy Images` job refused the tree at `RUN nginx -t` with
  `"client_header_timeout" directive is not allowed here in
  /etc/nginx/conf.d/default.conf:178` and stopped before the game export finished:
  `client_header_timeout` exists in the `http` and `server` contexts only, and
  `deploy/web/nginx.conf` carried it in four `location` blocks (the webhook, the
  checkout, `GET /push/vapid` and `GET /catalog`), so the proxy in front of the money
  path was a config nginx refuses to load — production web was undeployable, and no gate
  said so. It is the same defect #89 named from the other side: the file was only ever
  validated by `nginx -t`, and `nginx -t` does not exist on this machine (`which nginx`
  is empty, and the harness prints `[SKIP] nginx -t neste host (binário ausente)` rather
  than pretend). Fixed by moving the timeout to the `server` block, where it covers every
  route including the static ones, and leaving `client_body_timeout` per-route — that one
  does have a `location` context, and the right ceiling depends on the body each route
  accepts. Three of the harness's own assertions were the cause: suite C, suite F and
  suite G each demanded `client_header_timeout` *inside* the location, so the conf was
  written to satisfy a ruler that was wrong about nginx. They now ask the body guard of
  the route and the header guard of the `server`. While there: `text/html` left
  `gzip_types`, because nginx compresses `text/html` always and listing it produced the
  `[warn] duplicate MIME type "text/html"` the same build printed.
  The ruler added is suite B's context arm (`_Misplaced()`, in
  `tests/nginx_hardening_test.gd`, over a closed list of five directives whose context is
  `http|server` and can be stated without a lookup — `client_header_timeout`,
  `client_header_buffer_size`, `large_client_header_buffers`, `server_tokens`,
  `limit_req_status`), and it walks children too, because `limit_except` is a route
  context. A census of the blocks it judged is printed
  (`a varredura de contexto julga 11 blocos de rota`), so a sweep that looked at nothing
  cannot read as innocence. Its limits are stated rather than papered over: the list is
  closed, so a directive outside it placed in the wrong context is still only caught by
  `nginx -t` in the image build, which is the half that bit here.
  Bite measured on real files, through the harness's own conf override: the planted route
  with a header timeout gave `== NGINX HARDENING: 157 checks, 1 failures ==` accusing
  `location ^~ /webhooks/: client_header_timeout (contexto http|server apenas)`; putting
  `text/html` back on the *second* line of `gzip_types` gave the same `1 failures`, which
  is what the new `_stmt()` exists for — `_parse()` ends a directive at the first
  newline, so reading `gzip_types` through `_dir()` sees the top half only, and an
  assertion written that way would have called the planted warn clean. Green: the same
  157 checks with `0 failures`, `== GATES VERMELHOS: none ==`, `== FLAKES: none ==`,
  `== GATES COM RUÍDO: none ==` and teardown inside the measured ceiling (30/101). Eight
  live `deploy/web/nginx.conf:NN` pointers moved with the file (300 → 308 lines) —
  `sources/web/WebPush.gd:288`, the two in `tests/IdleTests.gd:6599`, the two in
  `deploy/OPS_RUNBOOK.md:14`, `deploy/OPS_RUNBOOK.md:176` and `:187`, and
  `deploy/docker-compose.yml:72`. A ninth pointer, in `scripts/check_ci.sh`, named a line
  of the harness that no longer holds what its sentence described: the comment reciting
  finding #89 pointed at `tests/nginx_hardening_test.gd:570-574` for code that had since
  been replaced, and the anachronism now reads as history without a line number, with the
  live pointer moved to `_skip()` (`tests/nginx_hardening_test.gd:681-687`) — the code
  that is there and does what the sentence says. The three citations landing above the
  insertions (`deploy/WEB_SLIM.md:213` on `:46`, `deploy/OPS_RUNBOOK.md:14` and
  `deploy/docker-compose.yml:80` on `:43`) were re-read against the file rather than
  assumed untouched: `:43` is `listen 80;` and `:46` is `index index.html;`.
- An interrupted gate used to poison the next one, and the poisoning was not a crash: it
  was a *verdict read from a log two processes were writing*. `flock` belongs to the
  process that took it, so when the shell holding the gate lock is SIGTERMed — the tool
  wrapper, a Ctrl-C — the lock dies with the shell while the `godot` child keeps running,
  desanexado, still holding the `> /tmp/shambleta-<harness>.log` descriptor and the shared
  sandbox `.test-home/<script>/`. The next run acquires a free lock, truncates the same
  file and reads the mixture of two runs. Measured 2026-09-30 between 00:05 and 00:22: the
  orphan survived twenty-odd minutes with an engine clock of `[4254.165]` (the boot
  restarted on its own clock, not on the wall), two signal-11 blocks and nine
  `SCRIPT ERROR` lines naming files that exist nowhere —
  `res://database/Database.tscn:0` and `res://presets/entities/codex/codex_00112.tres:50`,
  both disproved by `ls`, `git ls-files`, a tree-wide `grep -rl` and the same grep over
  `.godot/`. A judge reading that stack decode is reading an artifact of my own tooling.
  The fix is an owner stamp, and it is two checks, because the lock says only who has the
  *right* to write: `_log_holders()` resolves the log with `realpath`, walks
  `/proc/[0-9]*/fd` for descriptors pointing at it and reads `/proc/<pid>/fdinfo/<fd>`
  `flags:` — writable iff `mode != 0` — so a `tail` watching the file is not accused of
  writing it; `_guard_log_owner()` refuses the boot while a writer holds the descriptor,
  prints the pid and its `cmdline`, and names `SHAMBLETA_ORPHAN_WAIT` (default 120 s) as
  the wait; `gate()` calls it before the boot — before `_reap_interrupted_sandbox()`, so
  the foreign content is never truncated — and again before the verdict, copying the
  contaminated file to `$log.mixed` and recording
  `(log concorrente no veredito)` instead of judging it. `gate_sh()` carries both guards
  and `gate_py()` the post one. The boot itself is now backgrounded with
  `trap '_stop_boot "$bootPid"; exit 143' TERM INT HUP` around `wait`, and `_stop_boot()`
  forwards TERM, waits ten seconds for the child to leave, and escalates to KILL — an
  interrupted gate dies together with its engine instead of leaving it behind.
  The ruler is `scripts/check_boot_sandbox.sh`, 20 → 33 checks, and it exercises real file
  descriptors: it extracts `_log_holders`, `_guard_log_owner` and `_stop_boot` out of the
  runner with `awk` and runs them against a fixture holding a live writer
  (`sleep 120 >> log &`) and a read-only holder (`sleep 120 < log &`) that must *not* be
  accused, it asserts the refusal text, the clearance after `kill -TERM`, that
  `_stop_boot` kills a live sleep, that the machinery degrades to stderr (stdout is the
  pid stream), that the wait is a default and not a literal, and the ligaments as line
  numbers — pre-guard before the reap, post-guard before the verdict, backgrounded boot
  before the trap before the `wait` before `trap -`. Bite measured where it happened: with
  a `sleep 120` holding the log, the runner printed
  `LOG CONCORRENTE (gm_gate_fix_test antes do boot)` naming pid 2732541, then
  `GATE VERMELHO: gm_gate_fix_test (log concorrente no boot)` — with **no godot booted**
  and the foreign bytes intact; interrupting a real `content_hygiene_test` at boot printed
  `MORREU JUNTO: godot pid 2733760 não existe mais` with zero fd holders and the `.booting`
  sentinel left for the reaper. The green half is the ordinary
  `godot exit=0` / `Gate §24-8 OK … (30/101)` / `== GATES VERMELHOS: none ==` /
  `== FLAKES: none ==`.
  The new ruler wrote one false accusation of its own before it was trusted:
  `[FAIL] ensure_class_cache() roda --import fora do lock de boot — lock=12 import=9`,
  because it anchored on the bare word `--import`, whose first occurrence in that body is
  a comment line. Re-anchored on the executable command (`--editor --import --quit`) and
  tightened to `lock < import < _release`, with the incident kept in the ruler's comment —
  prose is not evidence of execution. And the +132 lines the fix added to `scripts/test.sh`
  moved every inbound `path:NN` pointer, so the doc-drift suite came back with 21 failures,
  all of them mine: seven citations repaired to the verified current lines
  (`tests/IdleTests.gd`, `tests/repo_layout_test.gd`, `tests/deploy_ops_test.gd`,
  `tests/hud_wiring_test.gd`, `deploy/OPS_RUNBOOK.md`, `docs/development/setup.md`,
  `docs/development/testing.md`) and one historical claim in `docs/development/testing.md`
  rewritten out of the present tense, since "quando a entrada é a linha 532" was true of a
  state that no longer exists. Nothing was exempted and no ceiling was retuned to reach
  green; the ruler ended at `== DOC DRIFT: 1660 checks, 0 failures ==`.
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
  eleventh was a name this repo never had, and the entry that recorded it got the story
  backwards. What git says, and it is checkable: `git log --all --diff-filter=A --
  '*zone_policy_test*'` is empty — no commit ever added the file — and the name lived in the
  `DIRT` list of the Python sweep inside `scripts/check_compose.sh` (planted by `7079661`,
  dropped by `b5691ef`), a list of paths to ignore as untracked dirt, not a promise that a
  harness measures anything. The harness-citation arm sweeps `scripts/*.sh` for the
  `tests/<nome>.gd` form, so a dead path parked in a skip list is read as a citation and
  accused; and the entry above then repeated that path twice while claiming the round had
  deleted the harness and that the prose had cited it as the measurement — three assertions,
  none of them true, and the CI's `== RESULT: 3236 checks, 1 failures ==` counted the two
  repeats in `CHANGELOG.md` as its ghosts. The record is fixed to the measured story, and it
  names the commits rather than the dead path: writing the path in the pointer form is
  exactly the promise the arm reads, and a sentence that promises proof it cannot deliver is
  the lie this suite exists to hunt. Two more moved to the lines that
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
- The series ruler's floor was a level, and it charged the #124 migration for migrating (#150).
  The number moved in the very commit that did the work: CI run 36904965051, the push of #147,
  came back with two failures and one of them was
  `ponteiros: 1 pares (série, intervalo) julgados pela régua de série — abaixo disso ela está
  muda e o "0 fora" não é prova`. The push before it (36903072011) printed no series failure at
  all, and the run before that finished green. The cause is not rot — it is success. #147 replaced
  seven line ranges in the `/metrics` family list of `deploy/ROLLBACK.md` with one anchor, and
  those seven lines were the class: replicating the census this slice introduces over the tree at
  `72bdf95^` gives 21 (pointer × series) pairs in the two deploy docs, against 2 in the twin's
  whole scope today. A floor that falls when the corpus gets cheaper is the same defect #137
  registered for the continuation class, and the remedy is the same one — coverage, not level. Two
  numbers now bound the arm instead of one being wished for: `metricosDitos`, incremented when
  `_OwnerPtr` says a named series belongs to the pointer being judged — before the verdict opines,
  so a verdict gone mad cannot starve it — and `serieCenso`, an independent pass over the same
  sweep with the same scope filter that multiplies pointers by series per line and never opens a
  target. They are not asserted equal, and the reason is in the tree: today's spared pair is
  `shambleta_grant_queue_pending`, 148 characters from the only pointer on its line against the
  house's 140-character clause window, and three `continue`s upstream — target that does not
  resolve, edge past the file, edge in blank — take pairs off the walk without taking them off the
  corpus. So the census is a ceiling by construction, not a twin: `serieCenso >= metricosDitos`
  accuses a walk that counts a pair the line does not present, and `serieCenso == 0 or
  metricosDitos >= 1` is what "not mute" actually means now — while the tree has a pair, the arm
  has to recognize one. Both bites are proven by mutating the ruler and running the full idle gate
  on each mutation, one failure per run and no other check moving: forcing the ownership test to
  skip prints `a régua de série não está muda: 2 pares no escopo e nenhum reconhecido pelo walk`,
  and telling the census to ignore prose (`stProse = false`) prints `cobertura da régua de série:
  o censo acha 0 pares no mesmo escopo e o walk disse ter reconhecido 1`. The harness reads the
  file it judges, so each mutated tree was restored byte-exact by checksum before the next run.
  The three controls that derive the verdict from `sources/system/MetricsServer.gd` itself stay as
  they were: they are what proves `dentro` is an opinion rather than a default, by innocently
  ruling the interval containing the emission and accusing the one that stops a line short.
  Gates: `== RESULT: 3303 checks, 0 failures ==` for the twin (3302 with the floor: one check out,
  two in), and the bash ruler does not move — `== DOC DRIFT: 2175 checks, 0 failures ==`, 239
  anchors over 406 line pointers. The idle job of #149's push (36911478669) had this floor as its
  only accusation, so with it gone nothing is left standing between the last three pushes and a
  green runner.
- The one pointer CI's twin judge accused became an anchor, and the ceiling fell with it (#124
  slice #149). The idle job came back with a single failure, quoted verbatim from the runner:
  ``tests/map_load_test.gd:108: Launcher.gd → 205-205 não declara nem usa `Action``, declarado em
  8-8: 1 vs 0. The comment was honest the day it was written and rotted in the next commit that
  touched the file — this project's own #136 grew `sources/launcher/Launcher.gd` by forty-six
  lines and moved `func Client()` from 172 to 218, so line 205 became `return false`, and the
  harness comment went on citing it. Nothing in bash said a word, and that is not a bug in the
  bash ruler but the corpus split #132 registered: `.gd` comments are read by the GDScript twin
  only, and the twin runs in CI, so a rotted pointer in a harness is a failure that arrives after
  the push. The citation now names the declaration instead of a coordinate: the clause points at
  `Client` (`sources/launcher/Launcher.gd:@Client`), and what makes the claim true is in that
  block — `add_child.call_deferred(Action)` — which is better evidence than the old target ever
  was, because the line it pinned was a comment inside `Reset()` repeating the fact rather than
  the code stating it. One line pointer died: `LINE_MAX` 407 → 406, and `ANCHOR_MIN` rose to the
  census the gate measures with this text in it. `check_doc_drift.sh` is green with zero failures
  at that census. The GDScript twin is NOT green, and the reason is not this pointer: its series
  arm floors the number of (named series, cited interval) pairs it judges at three, and the #147
  migration took that corpus in the same stroke — the ROLLBACK rows that named `shambleta_up` and
  friends next to a range now name them next to an anchor, which the twin does not judge by
  literal (#128 kept the clause model in bash on purpose). The run of this commit prints
  `1 pares (série, intervalo) julgados` against the floor of 3. That is a level floor accusing
  progress, the same defect #137 registered for the continuation class, and it is filed as #150
  rather than lowered here — a floor moved to make a gate pass is the one edit this house does
  not get to make on the way to something else.
- Seven line ranges that lived inside one function became one anchor (#124 slice #147). The
  alta-latência step of `deploy/ROLLBACK.md` enumerated the seven families the `/metrics` body
  publishes and pinned each with its own range, and all seven ranges sat inside
  `MetricsBody()` (`sources/system/MetricsServer.gd:@MetricsBody`) — the very body #136 had just
  edited, so one `# HELP` inserted near the top would have moved all seven citations at once and
  made seven of them wrong. They now point at that single anchor (repeated eight times, once per
  row plus the intro clause that says the rows share it), which is what the conversion is for:
  the sentence carries no positional claim, so the block can grow. Same harvest, three more
  pointers: the mutex paragraph in `deploy/OPS_RUNBOOK.md` carried a range *and* the anchor for
  the same thing and keeps only the anchor; `deploy/STAGING.md` migrated its `BindAddress`
  citation to `sources/system/MetricsServer.gd:@BindAddress`; and `deploy/prometheus.yml` now
  reads its security claim off `MetricsServer` (`sources/system/MetricsServer.gd:@MetricsServer`),
  whose own header pins the loopback-only bind and says no TLS and no auth. Measured census of
  the conversion itself: ten line pointers died and ten anchors were born, 417 → 407 positional
  against 224 → 234 anchored, both ratchets moved (`ANCHOR_MIN=234`, `LINE_MAX=407` in
  `scripts/check_doc_drift.sh`), and the gate that judges them closed green with this entry in
  the tree: `== DOC DRIFT: 2172 checks, 0 failures ==`, with 237 anchors judged by the
  declaration's block over 407 line pointers against a ceiling of 407, and the 17 self-test
  controls biting.
  The ruler charged a price for converting in a hurry, and the price is the evidence it works:
  `deploy/STAGING.md` came back accused of `bloco` because its sentence pinned the token
  `MetricsServer`, which resolves in the class header and therefore *outside* the block of the
  constant the same clause pointed at. The fix narrowed the sentence — a full stop where the
  em-dash had been, so the clause names only what the anchor's block declares — which is a
  scope correction in the doc, not a loosening in the ruler: the accusation judges the promise
  a pointer makes, not the path taken to satisfy it.

- The step-budget page now reads the DISPATCH, not the wall period (finding #136). The
  exported predicate was `periodUs > budget + tolerance`, and the period is the wall time
  between two physics frontiers of the same process — so it is budget PLUS the sleep of the
  `max_fps` pacer, which the engine takes at the end of every iteration. Measured: an idle
  server delivers 33.3–33.6 ms of period against a 33.33 ms budget, which no 1 ms slack can
  cover, because what it was covering is kernel wake latency. So the alert paged for the
  scheduler. CI run 36841440840 said it in two lines on `nível 5x20` — 100 players, a rung
  inside the ladder that `deploy/SCALING.md` publishes, not the claimed ceiling:
  `8.3% dos passos da pior passada acima de orçamento+folga, contra o
  corte de 5.0% que pagina (10 de 120 passos; período p95 34.37 ms, max 34.46 ms)` — a rung
  the same log reports at `trabalho 9.13 ms/passo`, where no player lost a step — and
  `o contador que o produto exporta viu 16 passos acima de orçamento+folga, esta janela viu 8
  (diff 8, banda 6)`. `workUs` is now the dispatch window: opened at `_physics_process`
  (`sources/launcher/Launcher.gd:@_physics_process`) and closed by the same node at its next
  `_process` (`sources/launcher/Launcher.gd:@_process`), which the engine reaches only after
  every `_physics_process` of the iteration; the predicate is `StepBudgetRecord`
  (`sources/launcher/Launcher.gd:@StepBudgetRecord`) and the
  slack stayed at 1000 µs because what it buys changed name, not size — scheduler preemption
  and GC inside the window. The period is still measured and still exported, because it is
  what answers "the 30 Hz tick was met"; it only stopped being the numerator, and
  `deploy/alerts.rules.yml` kept its `expr:` byte for byte, so the page is still the same
  fraction of the same two counters.
  The change rests on a probe, not on a reading of the manual. The retired
  `process_priority` sandwich had left four rungs at `0.00 ms` and the reason was declared
  inference; the isolated probe (this machine, 2026-10-01) separated the two hypotheses: a
  window opened in a node's `_physics_process` and closed in that node's `_process`, with the
  throttle at 30 Hz, returns 1.4–1.8 ms idle and 20.16 ms with 20 ms burned in a node child
  of a `SubViewport` — contained in 59 of 59 pairs — while the period stays at 33.3 ms. So
  the window is blind to the pacer's sleep and NOT blind to the `SubViewport` step, which is
  where the `WorldInstance`s live; the historical zero came from the phase hypothesis (a
  `_process`→`_process` sandwich measures the gap between two idle phases, which the pacing
  fills). Node position is instrument, not aesthetics, for the same reason: one iteration
  runs every `_physics_process` in tree order, then every `_process`, so the harness's
  `Cadence` is now the Launcher's immediate sibling, and a check reads that adjacency rather
  than presuming it.
  Blind spot, declared rather than buried: when the engine recovers delay by running two
  physics flushes in one iteration, the closer never runs for the swallowed step and it
  records 0 µs — work NOT measured, not zero work — so `shambleta_step_over_budget_total`
  understates the catch-up fraction by at most the catch-up ratio, and the deficit itself is
  confessed by `shambleta_step_lost_total`.
  Three rulers came with the change, each with planted controls because a ruler that only
  accuses is not proven to bite. `tests/step_budget_metric_test.gd` carries the control that
  discriminates the QUANTITY: five steps with a 34 500 µs period and a 9 000 µs dispatch
  return `overBudget == 0`, while their period buckets still fill — a fix that moved the
  predicate without changing the quantity would pass every other leg and die there.
  `tests/multi_instance_tick_test.gd` charges the tail off the dispatch against the cut read
  from `deploy/alerts.rules.yml`, and adds containment (the 40 ms/passo burn has to show in
  this harness's own bracket AND in the product's `shambleta_step_work_seconds` max, so the
  rate cannot be paid by some other counter) plus alignment: the bracket must be a
  sub-interval of the same index's period, and the census of the two series may differ by at
  most the one legitimate case — the last bracket with no successor frontier yet — with four
  planted controls deciding which of the two readings is the defect. The alignment ruler was
  itself wrong before it was right: it charged that legitimate surplus twice, and read
  `drift 2` in a healthy process at every rung measured 2026-10-01. The fix split containment
  from census — a scope correction, not a raised tolerance.
  Gates the change touches: `multi_instance_tick_test` 213 checks / 0 failures and
  `step_budget_metric_test` 56 / 0 on this machine, `check_doc_drift.sh` 2193 / 0. Two claims
  the local run does NOT settle: with a neighbour holding ~85% of the CPU, 28 timing readings
  were demoted to `[RUIDO]`, so the ladder's per-rung ceilings and the marginal-cost ramp are
  CI's to confirm, and the two quotes above are CI's evidence, not this machine's.
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
  (`_IdentityVerdict`, `tests/IdleTestsFrontier.gd:@_IdentityVerdict`) returned "the name is in this
  document" and stayed silent about the number. Found while writing the #107 register: a
  sentence locating `companion_gates()` at testing.md line 99 read green while the row that
  names it is `docs/development/testing.md:115`. The sweep gained a fourth arm,
  `_ProseTargetVerdict` (`tests/IdleTestsFrontier.gd:@_ProseTargetVerdict`), gated by `_IsProseTarget`
  (`tests/IdleTestsFrontier.gd:@_IsProseTarget`): a prose target that writes the name somewhere but not
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
