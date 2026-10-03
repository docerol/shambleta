# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-10-01

### Added
- An indented `def` in Python is a declaration for the anchor ruler (#154). The model read
  column zero in all three indexed dialects, and in python column zero is the module, not the
  file. Measured before writing: 47 declarations in the tree's python were invisible to the
  ruler, 28 of them methods of `Handler`
  (`companion/server.py:@Handler`) — so a sentence anchored on the class was satisfied by any
  line of any of its methods, which is the pointer-with-no-evidence the ruler exists to kill.
  Methods index by path (`Classe.método`) for the same reason the YAML slice does: the bare
  method name repeats inside one file, and an anchor that does not say whose method it is
  picks no block at all. A module-level function keeps its bare name, because it has no owner
  to name. Uppercase assignment did not gain indentation in any dialect: inside a method that
  is a local, and indexing it would shorten the block of the function that holds it. GDScript
  and shell stayed at column zero — their indented census in `sources/`, `tests/` and
  `scripts/` is zero, so the two already read those files whole and changing them would have
  been inventing geography, not measuring it. The harness half is `_SymbolSpans`
  (`tests/IdleTestsFrontier.gd:@_SymbolSpans`); the bash half lives in the python heredoc of
  `scripts/check_doc_drift.sh` and gets no anchor, because the model that reads a `.sh` is the
  shell model and python inside a heredoc declares nothing to it — the sentence tried the
  `@anchor_spans` of `scripts/check_doc_drift.sh` and the ruler answered `inexistente`, which is
  the honest answer (and the proof of the bite, on live prose, on the first try): an anchor the
  model cannot see is a line in disguise, so the claim stays with the file. Same stack, same
  level rule, one geography (#116) — and the first twin run caught the two judges failing to
  have it: the harness assembled the path backwards (`do_GET.Handler`), and the seven new
  controls plus the anchor census then accused the two doc anchors this very change had just
  written. Nothing was committed green on that reading. Bite is proved on both sides — eight
  controls in the
  ruler's self-test and seven in the harness mesa, planted on a python file whose lines each
  exist for one decision of the
  machine (method resolves by path, bare name does not, same name twice in one class is
  `duplo`, the same name in two classes is two keys, the class keeps its block, an indented
  `X = 1` declares nothing). What it bought, in pointers: the last two python line citations
  the worklist still charged converted. The checkout 401 that `deploy/COOLIFY.md` describes now
  names `Handler._resolve_checkout_account` (`companion/server.py:@Handler._resolve_checkout_account`),
  anchorable only after this change, and the boot-time refusal in `deploy/docker-compose.yml`
  now names `main` (`companion/server.py:@main`), whose `def` was already at column zero and had
  simply never been asked. 416 anchors against 301 line pointers, zero accusations.
- Deleting an auction listing now takes the escrow portrait with it (#168). `ah_escrow_lot`
  (migration 063) writes one row per `(listing, uid)` describing exactly what left the
  seller's inventory, and only the service knew that row existed: its own
  `_ClearEscrowSnapshotLocked`
  (`sources/economy/AuctionHouseService.gd:@_ClearEscrowSnapshotLocked`) deletes the row on
  settle, on refund and in the reaper, and nothing in the schema owned the listing. Every
  route that removes an `auction_listing` row outside the service therefore left the portrait
  pointing at a market that no longer exists. Measured on the `.test-home/run_idle_tests/`
  sandbox after its own run: 8 rows in `ah_escrow_lot`, ZERO rows in `auction_listing`, and 0
  of the 8 `uid`s still present in `item_instance`. The same sweep of
  `.test-home/faucet_census_test/` found 6 lots against 6 live listings — the litter is the
  trail of deleting an owner, not a cost of the harness. Litter by reading, not by taste:
  every consumer of the table asks BY LISTING — `_WriteEscrowSnapshotLocked`
  (`sources/economy/AuctionHouseService.gd:@_WriteEscrowSnapshotLocked`) writes it,
  `_RestoreEscrowLocked` (`sources/economy/AuctionHouseService.gd:@_RestoreEscrowLocked`)
  reads it back, `_ClearEscrowSnapshotLocked` deletes it, all three keyed on `listing_id` — so
  with the listing row gone nobody ever asks for that lot again, neither to return the item
  nor to audit it, and `listing_id` is a non-reused rowid, so the row cannot match a future
  listing either. `ah_price_history` stays out on purpose: 5 of its 5 rows in that same copy
  were orphans by listing, and none of its readers asks by listing — `RecentSoldPrices`
  (`sources/economy/AuctionHouseService.gd:@RecentSoldPrices`) orders by `item_id`/`sold_at`,
  `AHPriceAnchor` (`sources/economy/AuctionHousePricing.gd:@AHPriceAnchor`) asks the band by
  `item_id`, `_CollectAHWashPairs` (`sources/economy/FraudeReview.gd:@_CollectAHWashPairs`)
  scans the wash window by `sold_at`.
  A paid price is a record, the same class as the `ledger_transaction` of 066. Migration
  `067_listing_delete_escrow.sql` puts the DELETE in the schema and sweeps the dead portraits
  already sitting in every live database, wrapped in the transaction that `ApplyMigration`
  (`sources/sql/SQL.gd:@ApplyMigration`) opens around a patch that opens none itself. The
  nesting is what makes one trigger enough, and it was measured
  instead of assumed: with `recursive_triggers` OFF — the value the product never changes — a
  DELETE issued inside a trigger body on a DIFFERENT table does fire that table's trigger;
  the setting only gates a trigger firing itself. Probed on a copy of that same sandbox
  (engine 3.53.4): `DELETE FROM account` removed the `character` row and
  `trg_character_delete` ran from inside `trg_account_delete` — stat, trait, attribute and
  equipment went with it, and `item_instance` survived only because that database predates
  066. So the listing trigger covers the service's refund, 066's character cascade and the
  account erasure without any of the three naming the table. Applied verbatim to a copy of
  the littered idle database, the patch's sweep DELETE takes those 8 dead portraits to 0
  without touching a live row, because no live row exists.
- The orphan census now has a second axis, and prints one verdict per axis (#168). An orphan
  of a listing and an orphan of a character are closed by different cascades (067 and 066),
  and a
  count growing inside the other axis's total is exactly how a new defect passes green, so
  the single summed number is gone: `tests/benchmarks.gd` censuses `listing_id` orphans on
  both sides of the run, charged by DELTA like `char_id`, and prints the register that
  survives by design — `ledger_transaction`, `telemetry_event`, `ah_price_history` — as
  information that is never charged. The planted control gained the three escrow legs: a
  portrait under a LIVE listing (must not be counted), the live character deleted (the
  listing leaves by 066 and the lot has to leave with it — this migration's chain, exercised
  inside the gate), and a lot under a `listing_id` that never existed (must be counted). An
  `EXPLAIN` leg reads the purge plan against `idx_ah_escrow_lot_listing` with the planted
  rows on the table, because a plan read over an empty table proves nothing. Counterfactual,
  same day, this file out of the migrations directory and the sandbox database rebuilt: 4
  failures instead of 2, and the two extra are the nesting legs — `sobraram item=0,
  auction_listing=0, ah_escrow_lot=1 depois do DELETE, antes era 0/0/0` and `o órfão
  arrancado não saiu da contagem (item 0→0, auction_listing 0→0, ah_escrow_lot 0→2)`. Both
  census verdicts printed `0 na largada, 0 na chegada` on either side of the experiment, and
  that is information, not mitigation: the auction path this gate walks is the service's,
  which clears the snapshot in the same transaction, so the axis is guarded by the planted
  control rather than by the run's own count.
- Deleting a character now takes what hangs off it (#167). `trg_character_delete` was born in
  the bootstrap template with four DELETEs — stat, trait, attribute, equipment — which are
  exactly the four rows `trg_character_new` mints, and every schema object created after that
  hung rows on a `char_id` nobody ever added to the cascade: `item_instance` (migration 012),
  `chest_instance` (009), listings by `seller_char` (018). Measured on a clean database with this
  migration kept out of the directory: one run of `tests/benchmarks.gd` left 34.409 orphan rows —
  33.922 `item_instance`, 200 `auction_listing`, 129 `item`, 80 `bestiary`, 40 `skill`, 30 `quest`
  and 8 `chest_instance` — with zero characters living. Not a harness quirk — `SQL.RemoveCharacter` is
  the player's own delete route (`Server.DeleteCharacter`), while `SQL.EraseAccount` was the
  only path that knew the full list, so the two disagreed about what a character owns and the
  settle probe measured latency on top of a dead inventory. Migration
  `066_character_delete_cascade.sql` puts the cascade in the list, so `RemoveCharacter`,
  `EraseAccount` and the account cascade clean the same way by construction instead of by
  whoever wrote the DELETE; sweeps the garbage that is already in every live database once,
  inside the same `BEGIN TRANSACTION`/`COMMIT` that `SQL.ApplyMigration` wraps around the
  patch; and adds `idx_auction_listing_seller_char`, without which the cascade would scan
  every listing in the shop for every character deleted. `ledger_transaction` and
  `telemetry_event` stay orphan-tolerant on purpose: those are records, not litter. The gate
  now censuses `char_id` orphans on both sides of the run and charges the DELTA (pre-existing
  litter is not this run's fault), asserts the purge plan walks the new index rather than
  scanning, and plants a control in both directions — a row under a live character (must not
  be counted), a row under a `char_id` that never existed (must be counted), and the living
  character itself deleted (its child has to leave with it). Counterfactual, same file with
  066 out of the migrations directory and a clean database: `Censo de órfãos do char_id: 0 na
  largada, 34409 na chegada`, `Plano do purge de anúncio por seller_char: SCAN auction_listing`
  and both control legs — `sobraram item=130, auction_listing=201 depois do DELETE, antes era
  129/200` and `o órfão arrancado não saiu da contagem (item 129→130, auction_listing 200→201)`
  — 6 failures instead of 2. The
  gate's own teardowns went from `delete_rows` on `character` to the production APIs, which is
  the point of the whole thing: the harness and the server now agree by construction, not by
  remembering.
- The telemetry buffer now confesses what it throws away (#165). `TelemetryService.Record` has always
  dropped the oldest event once `BufferCap` fills, and the file's own header called that drop-oldest:
  under load the funnel under-reported and nothing in the process said how many events died in the
  cut, so "fewer purchases" and "no traffic" were the same sentence on the dashboard. `_dropped` counts
  every cut since boot, `BufferGaugeLines()` serves it as `shambleta_telemetry_buffer_dropped_total`
  (monotonic, so the difference between scrapes is the drop) next to `shambleta_telemetry_buffer_events`,
  and `MetricsServer` attaches the section to `/metrics` — with no SQL guard, because the scrape that
  matters is the one from a server whose database is not ready yet. `tests/telemetry_census_test.gd`
  pushes three events past the cap read from the fonte and asserts the DELTA (never the absolute, since
  other blocks touch the same buffer), that the buffer stops exactly at the declared ceiling, that the
  gauge publishes the counter's total, and that `Flush()` hands the database exactly the `BufferCap`
  survivors: the three that died were eaten, not stored.
- `telemetry_event` got a horizon, because the census written to count kinds found a table nobody was
  ever going to delete (#164). Migration `016_telemetry` created it and the only `DELETE` that ever
  touched it is the LGPD erasure by account: the analytical body grows with no ceiling and no owner,
  read back whole inside the process that holds the writer. `SQLRetention.PruneTelemetry` is the
  second pruning this module owns — same 6 h trigger as the ledger (`SQLCommons.LedgerRetentionIntervalSec`)
  and the same `RetentionEnabled()` button, so the one environment variable that already stops
  ledger compaction stops both, and neither can be re-enabled behind the other's back. The sweep is
  by `created_at` and NOT by id, and that is
  the deliberate opposite of migration 056: the ledger walks from a durable frontier
  (`ledger_compaction_cover`) so id order is proportional work, while telemetry has no frontier — one
  live row below a dead one (a clock that ran fast and was NTP-corrected) would starve an id-ordered
  window forever, deleting zero with the job green. `idx_telemetry_created_at` (migration
  065) pays one index entry per event, and the plan is certified from the production TEXT:
  `_pruneStatements` reads the two literals out of `SQLRetention.gd` and `EXPLAIN`s them, so trading
  the index for a `SCAN` in the product turns this red instead of proceeding quietly. Before anything
  dies, `BackfillCohortDay` freezes the cohort day of accounts whose ONLY evidence of birth is a
  login about to be pruned, because `TelemetryService.IsD1Return` and the `cohort_retention` view
  fall back to that row and would otherwise start measuring "first login inside the window" — another
  metric, and one that does not confess. The same fallthrough was a live money bug:
  `CheckoutService.GetStarterOfferState` reads `created <= 0` as "account created now", so every
  legacy account without a stamp was permanently eligible for the starter offer; with the true day
  frozen in, it expires like everyone else's. The horizon is not a transcription of someone else's
  window: the ruler derives each reader's bound positionally, from the CALL that carries it —
  `MaskRanges` blanks comments and string interiors, so a `created_at < ?` quoted in prose is not a
  reader and an `IN (` inside a SQL literal is not a call — and it resolves the bindings array
  through variable initializers and same-file SQL builders, demanding 2× slack over the largest
  window it can resolve in seconds (today 7 days, so 90 is 12×). Eight planted corpora keep the
  ruler's bite, and the pruning is measured on the booted database rather than argued: a 400-day
  window hoisted into `var cutoffs` is still resolved AND
  still accused, a bindings variable that confesses no time is accused, prose next to a real orphan
  reader accuses exactly one (not two, not zero), a bound with neither a call nor a table on its own
  line is accused, and on the live bank horizon 0, the ops button, the batch cap and the row hiding
  behind a live blocker each say what they did — `no_horizon` and `disabled` included, over the same
  fixture the pruning otherwise clears. What this does NOT do: `VACUUM`. The `DELETE` returns
  pages to the freelist and the file keeps its size — the pruning stops the growth, it does not
  shrink what `016` through `064` already wrote.

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
- The hand-written copy of the per-character purge list inside `SQL.EraseAccount`
  (`sources/sql/SQL.gd:@EraseAccount`) (#169). The LGPD route ran ten `DELETE`s over
  `item`, `item_instance`, `stat`, `attribute`, `skill`, `quest`, `equipment`,
  `bestiary`, `chest_instance` and `auction_listing` before dropping the `character`
  rows, and since migration 066 every one of those ten is already the job of
  `trg_character_delete` — the list lived in a method and in the schema, which is the
  same split #167 closed from the other side. The copy was not even faithful: it never
  had `trait`, a table the trigger has deleted since the bootstrap template. Measured
  on a copy of the gate's own database (24 characters, 1200 `item`, 600 `item_instance`,
  48 listings with 48 escrow lots, `recursive_triggers` 0, engine 3.53.4): the ten
  `DELETE`s and the trigger alone return the same zero residue across the eleven tables,
  and the wall clock (9/11/9 ms with the list, 9/7/7 ms without, three alternating
  rounds) decides nothing — the reason to cut it is that it is a second copy of the
  truth, not that it is slow. What stayed is `DELETE FROM auction_listing WHERE
  seller_account = ?`: counted over the databases in this tree that still hold
  listings, 20 of 2205 rows have a `seller_char` that is no live character (7 in
  `.test-home/fraud_test/`, 13 in `.test-home/marketplace_depth_test/`, with 066
  applied) and ZERO have a live character of another account, so no cascade-by-sheet
  reaches them and the account is the only owner left that can answer for them. After
  the cut no method in `sources/` carries a copy of the char-keyed list: `RemoveCharacter`
  was already a single `DELETE FROM character`, and the census now charges both.
  The right-to-erasure ruler was the precondition, not the cleanup: `SuiteLGPD` plants
  one row in each of the seven tables `trg_character_new` does not mint and demands
  exactly one across all eleven before the erase and zero after, plus the escrow
  portrait of the planted listing — 26 checks, because a `0` read from an empty table
  proves nothing. `== RESULT: 3339 checks, 0 failures ==`. Counterfactual measured the
  same day with the migration out of the directory and the sandbox rebuilt from the
  template: exactly the six legs predicted go red (item, item_instance, skill, quest,
  bestiary, chest_instance), while the four the template already carries stay green and
  so do the listing and its lot, reached by the route's own account-side `DELETE`
  (7 failures in total — the seventh is the boot's patch-contiguity ruler noticing
  index 65 is not 066, which is the same experiment confessing it is not
  single-variable). That run also stamps the sandbox by index, so the skipped patch is
  never re-applied: the idle database was deleted afterwards rather than trusted.
  Cutting the list moved two lines out of `SQL.gd`, and two `arquivo:linha` pointers
  that were pointing *at* those lines went stale on the spot — `sources/world/World.gd`
  promising `SQLBackups.new()` and `deploy/docker-compose.yml` promising
  `db.close_db()`. Both are anchors now (`:@_post_launch`, `:@Destroy`), which is the
  house answer when a cut breaks a pointer: the sentence names the symbol, so the next
  cut cannot orphan it. `== DOC DRIFT: 2027 checks, 0 failures ==`.
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
- The gate's clock was written by hand in five places, and the fifth one lied. `gate` carried a
  default of 900 s that nobody had measured, `one` inherited it, and the named paths each typed
  their own number again (`run_idle_tests` 1200, `run_rpc_identity_test` 180, the three others
  120), while the workflow typed 1200 a sixth time. Measured on this tree on 2026-10-03, with the
  1,2 MB `testing.db` the previous run left in the same sandbox (only an interrupted boot is
  reaped, so a harness does inherit itself): `bash scripts/test.sh one run_idle_tests` died at
  exactly 900 s of wall clock — `godot exit=124`, last engine stamp `[745.176]`, no `== RESULT:`
  line in the log, `GATE VERMELHO: run_idle_tests`. The same harness measured end to end on this
  tree finished in 947 s of wall (05:54:30 → 06:10:17) and printed its verdict at engine stamp
  `946.686` inside the budget: `== RESULT: 3389 checks, … ==`, the same count the 04:58 control
  had answered. So the hand-typed 900 was about 47 s short of a run that was always going to
  finish, and the 1200 the workflow had been typing all along is the number that fits, with ~250 s
  of margin.
  A timeout is not a check: the gate reported a red product for a green one, and the retry logic
  deliberately does not re-run a timeout, so nothing softened the lie. Now `harness_timeout`
  (`scripts/test.sh:@harness_timeout`) is the only source, `gate`
  (`scripts/test.sh:@gate`) reads it by harness name, every call site dropped its literal, and
  `one` keeps the optional override it already advertised. The default for a name the table does
  not know is 300 — the ceiling CI already enforces on every discovered harness through
  `gates_extra` (`scripts/test.sh:@gates_extra`), where the job is green — so nothing was
  loosened; `one` on an unlisted harness got *stricter* (900 → 300), which is why the override
  stayed documented in `docs/development/testing.md`. Durability is R7, whose verdict the ruler
  computes in `verdict_r7` (`scripts/check_gate_markers.sh:@verdict_r7`): zero numeric timeout may
  reappear in a `gate` call, and the `timeout NNNN` the workflow writes for the same harness must
  equal the table. Its
  three canaries plant the relapse in copies (`gate … run_idle_tests 900`, CI at 9999 s against a
  1200 s table, and the untouched pair) and each failure has to name the harness, because a ruler
  that reads zero timeouts from the workflow would also read zero disagreements.
- The fix itself then killed every harness for a different reason, and only the gate that reads
  the change caught it: the first version of `gate` asked for the table in the same `local` that
  defined `script` — `local script="$3" timeout="${4:-$(harness_timeout "$script")}"` — and under
  `set -u` the command substitution reads `script` before it has a value, dies inside `$( )` and
  leaves `timeout` empty. `bash scripts/test.sh one repo_layout_test` answered
  `variável não associada`, `timeout: intervalo inválido de tempo ""`, `godot exit=125` and no
  verdict line: a budget table that resolves to nothing is worse than no table, and no grep for a
  literal would have seen it. The assignment is now two sentences, and R8 is the function
  `verdict_r8` (`scripts/check_gate_markers.sh:@verdict_r8`), which reproduces the two extracted
  lines as a probe
  function — the same extraction-not-copying idiom as `harness_marker` — requiring that with the
  4th argument absent `gate` computes the table's number for `run_idle_tests` and that the
  override still wins when one is asked for. Its three canaries plant the one-sentence form
  (denounced: empty default), a `timeout=""` that swallows the override (denounced) and the clean
  copy (spared).
- The weakest cure in the game was the second most expensive one, and it bought less health than
  the cheapest. Crossing the two declared tables — unit `cost` of `VENDOR_CATALOG`
  (`sources/economy/EconomyCatalog.gd:@VENDOR_CATALOG`) against each cell's `Modifier.Health` —
  the ladder answered `apple` 50 gp/20 hp, `water` 80/20, `candy` 150/20, `drink` 200/75,
  `pitaya` 350/15, `potion` 500/100. Pitaya is the only rung that heals less than the rung below
  it while costing seven times as much: 23.3 gp per hit point against the entry step's 2.5. This
  is not a taste question, because the vendor is the game's only source of cure price and
  `AHVendorUnitPrice` (`sources/economy/AuctionHousePricing.gd:@AHVendorUnitPrice`) reads this same
  table to anchor the ask of an item with no history — a wrong shop number becomes an auction
  band. `croissant` is excluded by the ruler, not by hand: its modifiers are mana and stamina, so
  its health cure is 0. The ruler is `_suiteVendorCureLadder`
  (`tests/content_hygiene_test.gd:@_suiteVendorCureLadder`), class (6) of the content-hygiene
  harness: it sorts the cure offers by unit price and requires non-decreasing health, with a
  declared denominator (at least 4 measured offers) so an empty sweep cannot read green. It
  encodes the property "paying more never buys less cure", not a preferred number, so any
  re-price that respects the order survives it. The fix is the smallest number the ladder itself
  asks for: the best rate after Apple is the drink's 2.67 gp/hp, and 15 × 2.67 → `cost` 40, which
  puts price order (40, 50, 80, 150, 200, 500) and cure order (15, 20, 20, 20, 75, 100) on the same
  side. Checked before touching it: nothing else in the repo assumes 350 — Pitaya appears in three
  NPC scripts and two quests, always as an item and never as a price, and no quest carries a
  `repeatable` field, so the cheaper cure does not open a buy-and-resell loop. Bite measured on
  the real gate: with the old data the harness prints `== RESULT: 7264 checks, 1 failures ==`
  naming `pitaya (350 gp/un, cura 15) paga MENOS cura que drink (200 gp/un, cura 75)`; with the
  data fixed, `7264 checks, 0 failures`. Gates of this tree: `content_hygiene_test`,
  `balance_test` (`1919 checks, 0 failures`), `core_loop_cycle_test` (`71`),
  `faucet_census_test` (`63`), `spend_confirm_test` (`227`), `marketplace_depth_test` (`249`),
  `bash scripts/test.sh one run_idle_tests 1200` → `3389 checks, 0 failures`, and
  `scripts/check_doc_drift.sh` → `2044 checks, 0 failures`.
- Four of seven shop offers and four of six auction-bot seeds sold nothing. `ParseCellDB`
  (`sources/db/DB.gd:@ParseCellDB`) keys `ItemsDB` by `SetCellHash(cell.name)` — the display
  name declared inside the `.tres`, not the file it lives in: `WaterBottle.tres` says
  `name = "Water Bottle"`. Both market tables of `EconomyCatalog` had stored the basename, and
  all three readers of the field hash it as written — `BuyVendorOffer`
  (`sources/economy/ShopService.gd:@BuyVendorOffer`) for the gold debit, `EnsureAuctionBots`
  (`sources/economy/AuctionHouseService.gd:@EnsureAuctionBots`) for the launch storefront and
  `AHVendorUnitPrice` (`sources/economy/AuctionHousePricing.gd:@AHVendorUnitPrice`) for the ask
  anchor of an item with no history. The four names containing a space hash to a key that is
  nothing. This is not a render defect: `_GrantStackRaw`
  (`sources/economy/EconomyKernel.gd:@_GrantStackRaw`) deliberately does not validate against the
  catalog — a craft-template hash has to be grantable inside a transaction without
  `push_error` — so the paying player received a row naming an id `GetItem` cannot resolve, with
  no name, no sprite and no use, and four consumibles with a vendor price carried no auction
  band at all. The fix is data, not code: the two tables now write the display name, and no
  caller changes. The ruler is `_suiteMarketItemNames` (`tests/content_hygiene_test.gd:@_suiteMarketItemNames`),
  class (5) of the content-hygiene harness: it replays the three consumers' comparison over both
  tables, declares its denominators (7 vendor offers, 6 bot listings) so an empty sweep cannot
  read green, and its second leg requires every resolving offer to hand back a price > 0 through
  the ask anchor. Bite measured on the final tree: with the old data the harness prints
  `== RESULT: 7262 checks, 1 failures ==` and names all eight strings
  (`VENDOR_CATALOG[1] 'WaterBottle'` through `AH_BOT_LISTINGS[5] 'CactusPotion'`); with the data
  fixed it prints `7262 checks, 0 failures`. Gates of this tree: `content_hygiene_test`, the
  neighbours that read the catalog (`core_loop_cycle_test`, `faucet_census_test`,
  `spend_confirm_test`, `marketplace_depth_test`), `bash scripts/test.sh one run_idle_tests 1200`
  → `3389 checks, 0 failures`, and `scripts/check_doc_drift.sh` → `2034 checks, 0 failures`.
  Pitaya's price (350 gp for 15 hp where Apple gives 20 hp for 50) is deliberately not here: the
  cure ladder can only rank offers that resolve, and it ships as its own discovery with its own
  ruler.
- The auto-potion leg drank one item, and that item was an Apple. `_usePotion`
  (`sources/idle/IdlePolicy.gd:@_usePotion`) resolved a hash written once in the declaration
  (`autoPotionItemHash = 215387671`), and no persisted path ever fed it: `SaveFormation`
  (`sources/sql/SQL.gd:@SaveFormation`) carries the player's percentage and nothing else, and the
  field's only other readers in `HEAD` were the policy's own lookup, one comment and the fixture
  that asked the policy which item it knows about — so every character in the game shared one
  tier-1 fruit as its cure, and the harness proved the loop against the answer it was handed. The
  task that opened this claimed the opposite ("auto-poção nunca dispara, `potions_used` = 0 com hp
  a 6/112"), and measuring first killed that premise too: the same 300 s probe reports
  `potions_used: 18`. What the measurement exposed instead is the single hash. The catalog answers
  eight `usable` cells carrying a health modifier — 15, 20, 20, 20, 75, 100, 160, 210 — and seven
  of them were content no policy could drink, at exactly the tiers where 20 hp stops covering a
  hit. `_usePotion` now scans the bag and drinks the SMALLEST cure that closes the hole, falling
  back to the biggest it carries; `_tickPotion` kept the same decision boundary it always had
  (`health < x` and `health < ceili(x)` are the same set of integers), so nothing about WHEN the
  policy drinks changed, only WHAT. The other half is a number the game never had:
  `metricPotionShortfalls` counts the ticks that sank below the threshold with nothing drinkable in
  the bag, and the probe answers 86 against those 18 drinks — which turns `potions_used = 0` from a
  verdict into a question and opens the supply leg as a work order (two of twelve mobs carrying
  `_drops` hand out a cure, both tier 1, and the tier-7 band has no usable cell at all). Bite
  proven with three mutants through the real gate, one per run: putting the single hash back prints
  `== RESULT: 3388 checks, 21 failures ==` and the census names all seven (`Ambrosia Flask`,
  `Cactus Drink`, `Cactus Elixir`, `Cactus Potion`, `Cactus Sour Candy`, `Pitaya`, `Water Bottle`);
  reversing the choice to biggest-first prints 2 failures on the economics pair — the expensive
  cure is gone and the cheap one is intact — while "it drinks exactly once" stays green; dropping
  the health-effect filter prints 2 failures on the planted control, the `Croissant` is drunk and
  the shortfall stays at zero. The census runs `DB.ItemsDB` rather than a list of mine, so
  re-hardcoding one hash now accuses the cells that leave the table. Gates:
  `bash scripts/test.sh one run_idle_tests 1200` → `3388 checks, 0 failures` (1200 is the number
  the `all` path already declares for this harness; `one` falls back to a 900 s default the harness
  outlives, which is its own open task), and `scripts/check_doc_drift.sh` →
  `2033 checks, 0 failures`. Left alone on purpose: `BLIND_JUDGE_PROTOCOL.md` still names
  `autoPotionItemHash` in the round-3 and round-4 rows — that is a dated judge record, so the words
  stay and this line is what a reader gets instead of a rewritten verdict.
- `docs/development/testing.md` was selling `telemetry_census_test` as proof that "the table is
  pruned by a declared window", and no ruler reads a row's prose — only its name. The harness has no
  `DELETE` in it, and the census of deletes across `sources/` before writing this line found exactly
  one statement touching `telemetry_event`: the account-erasure path. Nearly every reader is
  `created_at >= <window>`, so the rows below those windows are dead weight no query answers from and
  the table grows forever while the doc said it was bounded — with one real dependency a horizon has
  to settle first, the legacy fallback in `IsD1Return` that takes `MIN(created_at)` for accounts with
  no `created_timestamp`. The claim is gone and the row now says what the harness actually derives —
  written
  kinds have readers, kinds handed to a validating emitter are accepted by it, the `/metrics` summary
  reads the live table, orphans are measured from the directory — plus an explicit "what this ruler
  does NOT prove: pruning", which is left as a named work order rather than quietly deleted from the
  sentence. A false claim removed without naming the hole it covered is how the next reader re-buys it.
- The daily login streak paid its gold twice for anybody who was online when it granted. The
  server-side funnel writes the wallet into `stat.gp` absolutely inside the transaction and then
  mirrors the same amount into the loaded agent with `AddGP` — and a memory mirror whose lastro
  does not move with it is a second credit waiting to happen: `FlushGoldDelta` writes the bank as
  `gp - gpFlushed`, so the 600 s backup re-applied the reward that was already in the row, and
  unlike the first write this one has no ledger line at all (§7.3 attests the grant, not the
  re-credit). `ApplyGoldMoves` had been doing this correctly all along, which is how the branch
  stayed invisible: the streak is the only other kernel writer that also touches the agent, and it
  did not. It now advances the lastro by the delta memory ACTUALLY moved rather than by the nominal
  reward, because `AddGP` returns without doing anything on a dead actor and a lastro ahead of
  memory would debit gold on the flush. No harness had ever exercised the online branch — every
  `RecordLogin` call in `balance_test` omits `stat`, so the mirror never ran and the double credit
  had no witness. Suite E of the core-loop harness spawns a real agent, records the login, and
  asserts bank == memory == lastro == one rung with the ledger agreeing and the flush moving
  nothing; then it plants the exact stale-lastro state the bug left and shows the flush re-crediting
  that same rung (100 → 200) and breaking the gp↔ledger invariant, so the ruler above it is pinned
  to the lastro and not to luck. The bite is proven in the tree: with the lastro advance deleted the
  harness prints `== CORE LOOP CYCLE: 71 checks, 4 failures ==`, exits 1, and names the two
  accusations it lost — `o lastro avancou junto com a memoria` (got 0, want 100) and
  `e nao re-credita: a carteira continua num degrau` (got 200, want 100). Gates:
  `== CORE LOOP CYCLE: 71 checks, 0 failures ==`, `== RESULT: 1919 checks, 0 failures ==` and
  `== WRITE FUNNEL GATE: 9 checks, 0 failures ==`.
- The craft-wiring harness said its comment-stripper was "the same helper as" a line in the webpush
  subscription test — `webpush_subscription_test.gd:169` — and reading the target showed line 169 is
  exactly `func _codeOnly`, so the number named the helper and the line became the symbol anchor (`#124`).
  Bare-to-full stays bare-to-full, so the name-resolution census fell one more on BOTH arms (95 each) and
  the floor held at 87. This one earned its keep differently from the last two: the sentence never said
  the word it meant — it said "mesmo helper", a noun, and a line pointer lets that slide. An anchor does
  not. To convert it I had to spell out `_codeOnly` right beside the citation, so the sentence now names
  the function it claims is shared instead of pointing a reader at a number and hoping they look. The
  naming rule did not move words around here; it made the claim say what it was actually claiming.
- A fraud-harness comment cited `EconomyKernel.gd:156` for the claim that the kernel's gold mover is the
  one path writing `stat.gp` with the ledger line that attests it, and reading the target showed line 156
  is exactly `func MoveGold` — the declaration, so the number already named the function and the fragile
  line became the stable symbol anchor (`#124`). Bare name to bare name: the name-resolution census fell
  one more on BOTH arms at once (96 on each) and the floor held at 87. This one is the case the naming rule
  bit, and honestly so: the symbol's own name sat two comment lines above the citation, and the judge would
  not count that as naming — the first pass failed with "nada na cláusula nomeia `MoveGold`" even though the
  anchor on the sentence above (`@BuyListing`) passed with its name one line up. The difference is what the
  clause-cut reached. The fix was to move the citation next to its name — "`MoveGold` (`EconomyKernel.gd:@...`)"
  on one line — the same reorder that makes the sentence read as a claim, not a guess. The anchor now sits
  where the word it stands for sits.
- A cross-file caller table in the testing doc cited `Gui.gd:286` as the location of the character-menu
  opener, and reading the target showed line 286 is exactly `func _show_char_menu` — the declaration
  itself, so the number already meant "this function" and the fragile line became the stable symbol
  anchor (`#124`). Bare name to bare name, so the name-resolution census moved 98→97 on BOTH arms at
  once (the line left the `arquivo:NN` count and joined the `arquivo:@simbolo` one, anchors 382→383) and
  the floor held at 87. `docs/` is not one of the four dated registers, so the judge charges this anchor:
  the clause had to NAME the symbol, and the reorder that reads better — "`_show_char_menu` (`Gui.gd:@...`)"
  instead of "`Gui.gd:286` (`_show_char_menu`)" — is what put the naming on the anchor's own line. The rest of
  this pass was spent NOT converting: six worklist candidates were read against source and kept as line
  pointers because the symbol would be vaguer than the line — a class name (`WebPushService`, not indexed), a
  local `var drops` inside a big function, a bare-name continuation the prose itself flags as wrong-directory,
  a `:40-59` range spanning the buffer field and its flusher, and three precise statements (`return
  ExecuteBindings`, `TradeLine(result)`, `Telemetry.Record("flag_change"...)`) each sitting mid-function where
  only the line says which call. Anchoring those would have traded a stable symbol for a lost claim.
- The COOLIFY backup row cited the line that opens a function, so the pointer became that function's
  anchor, and the naming rule made the sentence say which symbol it meant (`#124`). The deploy doc
  explained that the local backup directory name is UPPERCASE because it is the enum key
  `BackupFrequency`, and cited `SQLBackups.gd:12` as where that name gets built. Read the target: line 12
  is exactly `func CreateDailyBackup`, the declaration, so the pointer already meant "this function" and
  the number was just the brittle spelling of it. Anchoring the function keeps the claim — this is what
  reads the enum key and forms the path — and survives a line shift the number cannot. The clause named
  `BackupFrequency` (the enum it reads) but not `CreateDailyBackup` (the function that builds), so the
  sentence had to say the builder's name next to its own anchor; two different symbols, and an anchor does
  not name itself. The sibling in the next row of the same table, the reconcile timer pointing at the
  importer's `Run`, was already an anchor. A full-path citation becoming a full-path anchor is
  RESOL-neutral. Measured on this tree: anchors 381 to 382, line pointers 309 to 308, name-resolution
  coverage held at its floor of 87, `0 acusações`. Gate: `== DOC DRIFT: 2011 checks, 0 failures ==`.
- Two pointers in the entrypoint's problem statement became anchors, and each taught the anchor form a
  different limit (`#124`). `deploy/server/entrypoint.sh` said the SIGTERM drain is really the canary —
  cited as `ShutdownCanary.gd:28-42` — and that the window-close notification is handled only client-side,
  cited as `Gui.gd:409`. Read both targets. Line 409 is exactly `func _notification`, the declaration, and
  the constant it names sits inside the function one line later, so the symbol is what the sentence means
  better than the bare line was. The 28-42 citation was a range — the anchor form has no range — but the
  span opens `func CheckCanary` at 28 and closes exactly that function, the next declaration starting at
  43; a range that was one whole function is the one case where collapsing it into the function loses
  nothing, and says the same thing stably. A range straddling two functions would not qualify and stays a
  line pointer. Each anchor still had to name its symbol on its own line — `CheckCanary`, `_notification`
  — because an anchor does not name itself. Both were full-path citations, so the conversion is
  RESOL-neutral. Measured on this tree: anchors 379 to 381, line pointers 311 to 309, name-resolution
  coverage held at its floor of 87, `0 acusações`. Gate: `== DOC DRIFT: 2014 checks, 0 failures ==`.
- A code comment cited the exact line that declares a function, so the anchor points at the declaration —
  but two functions share the bare name, and the naming rule forced the sentence to say which one
  (`#124`). `sources/skill/SkillTrainer.gd` said the skill delivery is `NpcCommons.TeachSkill`, the same
  function the NPC's own action step used to invoke, citing `NpcScript.gd:353`. Read the target: line 353
  is exactly `func TeachSkill`, the declaration itself. Anchoring the NpcScript symbol says the same thing
  at the declaration and survives a line shift the number cannot — but the clause already carried
  `NpcCommons.TeachSkill`, a different function with the same bare name in a different file, and an anchor
  does not name itself, so the sentence had to name the NpcScript `TeachSkill` on the very line it cites.
  That is the naming rule earning its keep: it refuses a pointer whose symbol the reader cannot pin, which
  is exactly the two-`TeachSkill` trap the sentence was about to walk into. A full-path line pointer
  becoming a full-path anchor is RESOL-neutral. Measured on this tree: anchors 378 to 379, line pointers
  312 to 311, name-resolution coverage held at its floor of 87, `0 acusações`. Gate:
  `== DOC DRIFT: 2019 checks, 0 failures ==`.
- The rollback doc named a value and cited the line that declares it, so the pointer became the anchor
  of its own declaration (`#124`). `deploy/ROLLBACK.md` said the migration flag delivers
  `schema_blocked` and cited `sources/network/server/Admission.gd:55`; read the target — line 55 is
  exactly `const ReasonSchema : String = "schema_blocked"`, the declaration itself. Two of the three
  pointers in that sentence were already anchors — `_ValidateAuth` (`Server.gd:@_ValidateAuth`)
  and `MigrationBlocked` (`SQL.gd:@MigrationBlocked`);
  the third pointed at a const's own line, so it now anchors that const — the anchor names what the
  line pointed at, at the declaration, and survives a line shift the number cannot. The sentence's
  fourth citation is a test range, `admission_gate_test.gd:691-796`, and stays a line pointer: the
  anchor form has no range, and collapsing it into the enclosing suite would drop the exact lines the
  note stakes its claim on. A clause had to name `ReasonSchema` for the judge, not just the value it
  prints. Measured on this tree: anchors 375 to 376, line pointers 313 to 312, name-resolution
  coverage held at its floor of 87 (a full-path line pointer becoming a full-path anchor is
  RESOL-neutral), the independent census and the walk agree at 102, `0 acusações`. Gate:
  `== DOC DRIFT: 2019 checks, 0 failures ==`.
- The web-push evidence block was audited end to end; one pointer converted to an anchor, two stayed
  line pointers, and the reason they stayed is a real boundary of the anchor form rather than an
  unconverted case (`#124`). The note explains that `CanOfferToPlayer` is, and stays, the equality
  with `CanDeliver` — and the source proves it: the function's whole body is one line returning
  `CanDeliver`, so the pointer that cited that line now anchors the function that IS that equality,
  declared once with a block that covers the line. Its sibling in the same sentence cited a single
  assertion inside the test suite's catch-all runner. Anchoring it would name the whole runner — a
  strictly coarser claim than the one line a reader can go read — so the line pointer is the honest
  choice there. The third, in the block below, is a line range; the anchor form has no range, and
  collapsing it into the enclosing suite would drop the exact lines the note stakes its claim on.
  #124 trades brittle line numbers for stable symbols only where the symbol says the same thing the
  line did; where the symbol is vaguer than the line, the line wins, and that is a scope call, not a
  floor to lift. Measured on this tree: anchors 374 to 375, line pointers 314 to 313,
  name-resolution coverage held at its floor of 87, `0 acusações`. Gate:
  `== DOC DRIFT: 2022 checks, 0 failures ==`.
- The push-RPC pointers in the web-push module were resolving but lying, and the anchor form is what
  finally caught it (`#124`). The client module documented that "peça 6" had landed the two push
  RPCs, citing `Network.gd:543,549` for the client wrappers and `Server.gd:1111,1118` for the server
  handlers. All four are valid lines in the right files, so no cheap ruler flagged them — but none is
  a push RPC: line 543 is the referral-code setter and 549 sits in the same block; both server lines
  sit inside the VIP purchase. The real register and unregister handlers had moved out from under the
  dated note. The description was honest, the numbers were not. Each side became an anchor naming its
  real handler — the CONNECT-channel wrappers on the client, the handlers that read the account from
  the peer table on the server — and the landed-date sentence in the submit method anchored the same
  handler by its now-correct name. This is the class the line-number form hides: a pointer that
  resolves to a real but wrong line passes every gate that only checks that the line exists. Measured
  on this tree: anchors 369 to 374, line pointers 317 to 314, comma-lists 8 to 6 (the two stale pairs
  gone), name-resolution coverage held at its floor of 87. Gate:
  `== DOC DRIFT: 2024 checks, 0 failures ==`.
- The offline-drops pointers in the same launch note were audited next, and the audit split them
  rather than converting all three (`#158`, `#124`). The note about the malformed network report
  cited three lines: the offline-cap rule, the panel method that reads the drops field, and the idle
  module that declares it. The cap and the panel became anchors — the cap is a module-level constant
  the ruler indexes by name, the panel method is declared once with its block covering the cited
  read. The declarant did not, for two reasons the ruler states out loud. Its field is a member of a
  class, and the anchor ruler indexes function and constant names but not class names: the class
  anchor came back "a name nobody declares", and the worklist's fallback named a module constant
  fifteen lines above the class body, so taking it would have minted a false anchor. And the belief
  this pass carried in — that the cited line had drifted off the drops field — was itself wrong: the
  field sits exactly on the cited line, so the pointer was never stale and stayed an honest line
  pointer. Both citations were kept addressing their file by bare name, because the name-resolution
  walk fires precisely on a pointer that cites a file without a path, and full-pathing them would
  have dropped that coverage below its floor of 87 — lowering a floor to turn the ruler green is not
  what a conversion is for. Measured on this tree: anchors 366 to 369, line pointers 320 to 317,
  `0 acusações`. Gate: `== DOC DRIFT: 2028 checks, 0 failures ==`.
- The three 2FA/buy pointers in `deploy/LAUNCH_HANDOFF.md` are now anchors, after an audit of every
  cited line in the source (`#158`, `#124`). The launch note described the member-of-nonexistent bug
  it had fixed: three 2FA calls in `Settings.gd` and two buy screens in `Shop.gd` and `Checkout.gd`
  reading `Launcher` members that do not exist. Each citation was a bare line number, and a launch
  note that rots is worse than none. Checked line-by-line before converting — the cited 2FA line sits
  inside the two-factor state handler, the cited shop line inside the catalog-rebuild routine, the
  cited checkout line inside the username resolver, each declared once with its block covering the
  line — so each became an anchor naming its real handler, clause rewritten to name the symbol so the
  ruler judges it against the declaration rather than trusting a number. Measured on this tree:
  anchors 363 to 366, line pointers 323 to 320, `0 acusações`. Gate:
  `== DOC DRIFT: 2035 checks, 0 failures ==`.
- A pointer pair was lying, and the anchor form is what caught it (`#124`). The push-delivery
  fission note in `sources/web/WebPushDelivery.gd` said the client-to-server subscription RPC
  "landed on 2026-09-27" and cited `Network.gd:543` and `Server.gd:1111` as the two sides. Auditing
  the cited lines in the source: line 543 is now `SetReferralCode` and line 1111 sits inside
  `PurchaseVIP` — neither has anything to do with push. The `RegisterPushSubscription` handler the
  note actually means lives at a different line in each file (the code moved under the dated note).
  So the line pointers resolved cleanly but named the wrong function: exactly the class of drift the
  campaign kills. Both were re-pointed to the real handler — each `RegisterPushSubscription` is
  declared once and its block is the RPC itself — and the clause rewritten to name the symbol on
  each side. Because an anchor token cuts its own clause, one naming backtick covering a joined pair
  is not enough: each anchor needs its own, so the second side stayed a `prosa` rejection until
  named in place. Measured on this tree: anchors 361 to 363, line pointers 325 to 323, `0 acusações`.
  Gate: `== DOC DRIFT: 2041 checks, 0 failures ==`.
- One sentence, written twice, cited two line numbers; both became anchors, and the second was a
  mis-citation the anchor forced into the open (`#124`). The comment explaining why `currentMapID`
  tracks only a standing map lives in both `sources/map/Map.gd` and `tests/map_load_test.gd`. It
  pointed at the minimap line that reads `DB.UnknownHash` as "no map", then at "the `not force`
  early-return of `EmplaceMapNode`, line 35". The first pointer was anchorable: `Warped` is declared
  once and its block covers the cited line, so it became an anchor naming `Warped`. The second was
  the finding. A bare `:35` with no file of its own resolves by inheriting the file of the last real
  pointer on the run — which here was `Minimap.gd`, so `:35` silently meant `Minimap.gd:35`, a
  `return` inside `Moved`, not the `not force` guard of `EmplaceMapNode` that lives in `Map.gd`.
  Worse, the number sat far enough from its witness that the continuation ruler never linked it as a
  continuation at all (the census stayed 3 before and after), so no judge was ever going to accuse
  it. Giving it a real anchor — `EmplaceMapNode` in `Map.gd`, declared once, block covering the
  early-return — both fixes the target and makes it judged. Measured on this tree: anchors 357 to
  361, line pointers 327 to 325, continuation 3 == census 3, `0 acusações`. Gate:
  `== DOC DRIFT: 2045 checks, 0 failures ==`.
- The heartbeat TTL comment in `sources/network/server/Presence.gd` cited the checkpoint-stall
  source by line (`#124`). It warned that one late heartbeat must not drop a player, and pointed at
  the `wal_autocheckpoint` value to say where the stall could come from. The line number was the
  fragile part: that `PRAGMA` lives in one function, and the number drifts the moment anything above
  it is edited. Confirmed in the source before converting — the cited line is the
  `wal_autocheckpoint=4000` query, which sits inside the post-launch setup function (declared once,
  its block covering the line) — and the clause was rewritten to name that function so the anchor is
  judged against its declaration, not assumed. Measured on this tree: anchors 356 to 357, line
  pointers 328 to 327, `0 acusações`. Gate: `== DOC DRIFT: 2048 checks, 0 failures ==`.
- Three line pointers in `sources/economy/TelemetryService.gd` became anchors, and the fourth
  confessed it is not anchorable (`#124`). The D1-return comment cited the login emitter by line
  twice, and the censo comment cited the `flag_change` writer by line. Each target was checked in
  the source, not assumed: the login emitter (`FinalizeLogin`) is declared once and its block
  covers the cited lines, and `flag_change` is emitted inside `CommandFlags`, whose block runs to
  the end of that file, so the cited line is honestly inside it. The clause was rewritten to name
  each symbol (the ruler rejects an anchor whose own clause does not name it), so the conversion is
  evidence, not decoration. The fourth pointer is left as a live line pointer on purpose: it cited
  `SQLSecurity.gd` 67 through 72 for "the six `sec_*` events", and the ruler's model offered
  `WindowRetentionSec` — but that constant sits at line 65 and is about table retention, not the
  events, and the six events are six separate module-level constants with no single enclosing
  symbol. Minting that anchor would have named the wrong thing, so it stays a line pointer.
  Measured on this tree: anchors 353 to 356, line pointers 331 to 328, identity judged 119 to 116
  with the independent census at 116, `0 acusações`. Gate: `== DOC DRIFT: 2051 checks, 0 failures ==`.
- The conversion the identity floor had blocked is now landed (`#124`). The header of
  `sources/social/SocialGraph.gd` cited a line in `sources/gui/Chat.gd` by number to show how the
  social verbs reach the command route. That line moves whenever anything above it in the chat
  handler changes, so the citation was the exact marra-cost the campaign kills. The pointer is now
  an anchor: the clause names the chat handler that owns the cited statement, and the ruler judges
  it against the block of that declaration. Verified honest here — the handler is declared exactly
  once and its block truly covers the cited statement — and the naming backtick was added so the
  clause names its own symbol rather than relying on the anchor token. Measured on this tree:
  anchors 352 to 353, line pointers 332 to 331, identity judged 120 to 119 with the independent
  census at 119, `0 acusações`. Gate: `== DOC DRIFT: 2059 checks, 0 failures ==`.
- The identity ruler's floor was a hand-written number, and it accused the very conversion the
  campaign drives (`#160`). `scripts/check_doc_drift.sh` judged `arquivo:NN` line pointers with the
  `verdict` of section 23, then required the walk to have judged at least a written `IDENT_MIN` of
  them. Converting one line pointer into an anchor — the whole point of #124 — removes it from the
  population the walk judges, so the count legitimately falls and the floor read a shrinking byproduct
  as blindness. This is the same lesson for the fourth time: #137 retired the continuation level, #149
  the series level, #159 the literal count, and this retires the identity population level. The guard
  is now coverage. `identcoverage` re-walks the same scope as the scan — the directory filters, the
  archive skip, the extension set, the dated-register skip and the code-comment gate — and counts the
  line pointers whose target resolves, WITHOUT calling `verdict`. The bound is the equality between
  what the walk judged and what the census found: a converted pointer drops both together (progress
  survives) and a walk that stopped looking drops only the walk (caught at the exact size of what
  vanished). Proven both ways here: with the walk intact the census and the walk agree at 120; with the
  walk's judged-increment temporarily forced to zero the gate prints `sumiram 120 do walk` and fails,
  then the edit is reverted. No floor was lowered to go green and no anchor was minted. The name
  resolution floor is untouched. Measured on this tree: identity 120 judged against 120 in the census,
  resolution floor 87, `0 acusações`. Gate: `== DOC DRIFT: 2062 checks, 0 failures ==`. The pointer
  body is still read by the GDScript twin in CI.
- The comment that says where a farm zone's drop count comes from was still pointing at a line
  (`#124`). `sources/idle/FarmZoneData.gd` reads its drops-per-kill figure from `dropRatePPM` at a
  numbered line inside `OfflineSettle.gd` — that line is the `var dropExpected` ppm-of-kills formula,
  inside `_ApplyFormula` (declared once at column zero, block encloses the formula). This pointer was
  lit-bearing: its clause promised the literal `dropRatePPM`, and the old raw literal floor accused the
  conversion because a line-pointer to anchor step drops the walk count, which the floor read as
  regression. #159 replaced that floor with the independent coverage census, so the step is now honest
  progress. Naming `_ApplyFormula` on the anchor's own line, the naming backtick suppresses the backward
  continuation that used to pull `dropRatePPM` into the clause, and the anchor block still covers the
  formula. Measured here: anchors 351 to 352, line pointers 333 to 332, literal 40 to 39 with the census
  at 39 (walk and census drop together, exactly what #159 authorizes), floor 87, `0 acusações`.
  Gate: `== DOC DRIFT: 2062 checks, 0 failures ==`.
- A comment declaring a farm zone's PPM unit justified the unit by borrowing a live boss constant, pointing
  at a bare filename and a line number the tree can move without warning (`#124`). `sources/idle/FarmZoneData.gd`
  says its "drops per million kills" uses the same unit as the boss key-drop, and the cited line is the
  comparison `return rng < float(KeyDropPPM)/1000000.0` inside `RollsKeyDrop` (declared once at column zero,
  block encloses the roll). This is the mirror of the SocialGraph collision that taught the lit rule: the clause
  opens with the dotted token `BossService.KeyDropPPM`, and the literal walk does reach a dotted token's trailing
  identifier — but `KeyDropPPM` appears TWICE in `BossService.gd` (the const and the use), so it is not unique,
  pins nothing, and the pointer is lit-neutral. Naming `RollsKeyDrop` on the anchor's own line makes it a
  bare-name anchor with no literal duty. Measured here: anchors 350 → 351, line pointers 334 → 333, literal held
  flat at 40, floor 87, `0 acusações`. Gate: `== DOC DRIFT: 2065 checks, 0 failures ==`. The target body is read
  by the GDScript twin in CI.
- A comment on the client's mode-restore explained that the browser boots client-only by pointing at a bare
  filename and a line number the tree can move without warning (`#124`). `sources/network/client/Client.gd`
  reaches for the launcher's mode switch, and the cited line is the `Launcher.Reset(false, false)` call inside
  `Mode` (declared once at column zero, block encloses the reset). The citation sat on a comment line with no
  backtick before it and a plain-text previous line, so the backward continuation pulled nothing shaped —
  note the shape-bearing token in that paragraph lives on the line BELOW the citation, which is out of reach of
  a clause that only ever walks upward. Naming `Mode` on the anchor's own line is safe because `Mode` is far
  too short to be a candidate. Bare-to-bare keeps the target open for name resolution: literal held flat at 40,
  floor 87, identity counts one fewer named pointer (123 → 122). Measured here: anchors 349 → 350, line
  pointers 335 → 334, `0 acusações`. Gate: `== DOC DRIFT: 2067 checks, 0 failures ==`. The target body is read
  by the GDScript twin in CI.
- A comment on the map-emplace regression explained that the only caller kept asking for an insertion that
  never happened by pointing at a bare filename and a line number the tree can move without warning (`#124`).
  `sources/map/Map.gd` names that caller, and it is `AddCharacter` in `Character.gd` (declared once at
  column zero, block encloses the line that hangs the entity on the map). The citation sat on a comment line
  already opening with a `return` backtick, so continuation never reached the previous line — and `return` is
  too short to be a candidate — which meant the clause pinned no unique literal. Naming `AddCharacter` on the
  anchor's own line turns it into a bare-name anchor with no literal duty; the name is a candidate but it is
  the anchored function, so it lives in its own block. Bare-to-bare keeps the target open for name resolution:
  literal held flat at 40, floor 87, identity counts one fewer named pointer (124 → 123). Measured here:
  anchors 348 → 349, line pointers 336 → 335, `0 acusações`. Gate: `== DOC DRIFT: 2069 checks, 0 failures ==`.
  The target body is read by the GDScript twin in CI.
- A comment explaining why an idle-mode shortcut was rewired off the engine action list justified the new
  key by pointing at a bare filename and a line number the tree can move without warning (`#124`).
  `sources/gui/Gui.gd` says the bindings panel lists its own categories, not the engine's action list, "the
  way the ESC case already does it" — and that ESC case is the `KEY_ESCAPE` handler inside `InputBindings`'s
  `_input` (declared once at column zero, block encloses the escape branch). The pointer sat on a comment
  line with no backtick before it and a plain-text previous line, so the backward continuation pulled no
  shaped token: a naming backtick on `_input` — short enough to stay under the candidate length — turns it
  into a bare-name anchor that adds no literal duty, so the literal walk stayed flat at 40 and the name
  floor held at 87; the identity walk counts one fewer named pointer (125 → 124) because the citation is now
  an anchor. Measured on this tree: anchors 347 → 348, line pointers 337 → 336, `0 acusações`. Gate:
  `== DOC DRIFT: 2071 checks, 0 failures ==`. The target body is read by the GDScript twin in CI.
- The same symbol was cited by line number in two files, and only one of the two was free to convert — the
  asymmetry is the point (`#124`). `sources/world/WorldCommands.gd` and `sources/social/SocialGraph.gd`
  both reach for the chat-input handler by writing a bare `Chat.gd` name plus a moving line number, pointing
  at `OnNewTextSubmitted` (declared once at column zero, block encloses the cited line). The WorldCommands
  clause ("no funil que ... já usa") carries no backtick before the citation, so its backward continuation
  pulls nothing shaped — a naming backtick on `OnNewTextSubmitted` makes it a bare-name anchor with no new
  literal duty, so the literal walk stays flat. The SocialGraph clause is the mirror image: it sits one line
  under "disparados por `Network.TriggerCommand`", and the continuation walks the literal walk through the
  dotted token to `TriggerCommand`, which appears exactly once in `Chat.gd` — so that pointer is one of the
  forty the floor protects, and converting it dropped the walk to 39 and tripped `literal julgou pouco`.
  Measured here: WorldCommands converts (anchors 346 → 347, line pointers 338 → 337, literal held at 40,
  floor 87, `0 acusações`); the SocialGraph sibling is left as an honest line pointer, and the empirical
  per-conversion ruler run is what caught it. Gate: `== DOC DRIFT: 2073 checks, 0 failures ==`. The target
  body is read by the GDScript twin in CI.
- A comment on the offline drop roll justified moving the roll from spawn-time to death-time by pointing at
  a bare filename and a line number the tree can move without warning (`#124`).
  `sources/actor/agent/variants/MonsterAgent.gd` cites the live key-drop as the model for the per-cell roll;
  the cited line is `BossService.RollsKeyDrop` inside `ApplyXp`, declared once at column zero with a block
  that encloses that call. The clause carried no unique pinned literal (the only other token, `randf()`,
  is parenthesised so it is never a candidate), so a naming backtick on `ApplyXp` both satisfies the anchor
  and suppresses the continuation pull that had been reading the previous line — `ApplyXp` is short enough
  to stay below the candidate length, so it adds no new literal duty. Bare-to-bare keeps the target open for
  name resolution, so the floor held at 87 and the literal walk stayed flat at 40; the identity walk counts
  one fewer named pointer (127 → 126) because this citation is now an anchor. Measured on this tree: anchors
  345 → 346, line pointers 339 → 338, `0 acusações`. Gate: `== DOC DRIFT: 2075 checks, 0 failures ==`. The
  target body is read by the GDScript twin in CI.
- A comment on the manual-click path explained that two other code paths kept checking the same cell by
  pointing at a bare filename and two line numbers the tree can move without warning (`#124`).
  `sources/actor/entity/Entity.gd` names the idle tick and the inventory-space gate as the two halves that
  stayed honest while the click path dropped its `usable` guard. Both clauses carried no unique pinned
  literal, so each pointer became a bare-name anchor on the function that owns that line — `_tickPotion`
  (declared once, its block encloses the `usable` check) and `HasSpace` (declared once, block covers the
  line the prose names) — with a naming backtick on each anchor so the clause does not pull `usable` from
  the previous line. Bare-to-bare keeps them in the name-resolution walk, so the floor held at 87 and the
  literal walk stayed flat at 40. Measured on this tree: anchors 343 → 345, line pointers 341 → 339,
  `0 acusações`. Gate: `== DOC DRIFT: 2077 checks, 0 failures ==`. Both target bodies are read by the
  GDScript twin in CI.
- Two harness headers explained a dependency by pointing at a bare filename and a line number the tree
  can move without warning (`#124`). `tests/test_e2e_implementation.gd` justifies draining preloads
  before `quit` by the same reason `balance_test.gd` runs `_initialize` with half-loaded autoloads;
  `tests/marketplace_depth_test.gd` names the UPDATE branch of `ConsumeItemLotsRaw` as the reason a
  source row survives a partial consume with `count = 1`. Both cited a bare `file.gd:NN` whose clause
  carried no unique pinned literal, so each became a bare-name anchor on the function that owns that
  line — `_initialize` (declared once, block covers the cited range) and `ConsumeItemLotsRaw` (block
  encloses the UPDATE branch the prose names). Bare-to-bare keeps them in the name-resolution walk, so
  the floor held at 87 and the literal walk stayed flat at 40. Measured on this tree: anchors 341 → 343,
  line pointers 343 → 341, `0 acusações`. Gate: `== DOC DRIFT: 2081 checks, 0 failures ==`. Both target
  bodies are read by the GDScript twin in CI.
- One duplicated citation was paying the pointer cost twice, and both copies were bare names the
  name-resolution walk already owned (`#124`). `sources/economy/AuctionHouseService.gd` and
  `sources/economy/EconomyKernel.gd` each explain that the daily reconcile — `ReconcileDaily`, declared
  once at column zero and spanning the block that checks `item.count == SUM(item_instance.count)` — is
  what turns a stack the caller decremented without touching the aggregate into a permanent divergence.
  Both wrote it as `TournamentArenaService.gd` at line 398. That line sits inside the `ReconcileDaily`
  block, and neither clause carried a unique pinned literal, so anchoring both moved them out of the
  line-pointer pool and into the anchor walk without touching the literal walk's count or the 87
  name-resolution floor. Measured on this tree: anchors 339 → 341, line pointers 345 → 343, literal walk
  flat at 40, `0 acusações`. Gate: `== DOC DRIFT: ... 0 failures ==`. The `ReconcileDaily` body is read
  by the GDScript twin in CI.
- One comment described the login emitter three times over, and the bare-name copy was the only one
  that could be anchored today (`#124`). `sources/economy/TelemetryService.gd` argues that `d1_return`
  used to have two disagreeing predicates: the view's, and the emitter's `COUNT(DISTINCT
  date(created_at,'unixepoch')) == 1` heuristic that lived inside `FinalizeLogin` in
  `sources/network/server/Peers.gd`. The prose named that block by its line range in four places — one
  bare `Peers.gd` citation and three full-path ones. The bare one is a name already resolved once, so it
  became a bare-name anchor on `FinalizeLogin` (declared once, spanning 269–331, with the cited range
  291–297 and the `created_at` literal sealed inside that block) and the name-resolution floor held at
  87. The three full-path citations stayed honest line pointers on purpose: each one currently feeds
  the literal-resolution walk, whose raw-count floor now sits exactly at that walk's population, so
  converting a fourth would trip a guard that is measuring a shrinking byproduct rather than blindness.
  Turning that floor into a coverage check is its own discovery (#159), mirroring how #137 and #149
  retired the continuation and series level-floors. Measured on this tree: anchors 338 → 339, line
  pointers 346 → 345, literal walk 40 (piso 40), `0 acusações`. Gate: `== DOC DRIFT: 2089 checks, 0
  failures ==`. The `FinalizeLogin` body is read by the GDScript twin in CI, so that axis is verified
  there rather than paid for twice locally.
- One comment listed seven dialogs by line number, and seven line numbers is seven things the tree
  can slide out from under the sentence that trusts them (`#124`). `sources/actor/agent/NpcCommons.gd`
  explains that quest gold and EXP now live in the `.tres` data and the dialog scripts keep only a
  comment saying where the number went, then cited `Nina.gd:144`, `Frost.gd:54`, `Mauro.gd:47`,
  `Nathan.gd:89`, `ThiefsChest.gd:30`, `Eridu.gd:85` and `Riskim.gd:123`. Every one of those lines is
  the migration comment sitting inside a named reward handler — `OnCroissantTurnIn`, `QuestRewards`,
  `OnDeliverWater` (in two different scripts, which is why the file still has to be said),
  `OnTryOpen`, `OnGathering`, `OnReward` — each declared once at column zero. So each pointer became an
  anchor on its own handler, the clause now forced to spell the symbol so the ruler opens the target and
  checks the block rather than trusting an integer. All seven resolve by bare name exactly as the seven
  pointers did, so the name-resolution floor held at 87 while the positional citations fell. Measured on
  this tree: anchors 331 → 338, line pointers 353 → 346, identity-named pointers 141 → 134,
  `0 acusações`. Gate: `== DOC DRIFT: 2091 checks, 0 failures ==`. The seven handler bodies are read by
  the GDScript twin in CI, so that axis is verified there rather than paid for twice locally.
- Two runbooks cited the same log line, the line had moved out from under them, and only the
  block-naming anchor keeps a moving target honest while the claim stays true (`#124`).
  `deploy/COOLIFY.md` and `deploy/TLS.md` both explain that a proxy-TLS bind logs under the group
  `Server`, not `TLS`, so a `grep '[TLS]'` on the log reads as "proxy mode did not engage" when it
  did. Each pointed at `sources/network/server/Server.gd:1764` for the `Util.PrintLog("Server", ...)`
  call and at `sources/util/Util.gd:5-6` for the `[msec][Grupo]` prefix. The second was one step from
  an anchor: line 5 is `static func PrintLog` — a single column-zero declaration — and its body holds
  the `[%d.%03d][%s]` format, so naming `PrintLog` in `Util.gd` pins a fact true of that block. The
  first was a lie of position, not of substance: line 1764 is `func UnequipItem`, and the TLS line now
  lives at 1929, inside `func _enter_tree()` — the call really is `Util.PrintLog("Server", ...)`, the
  address was just stale, which is exactly the drift the anchor grammar exists to survive. So neither
  sentence swapped into a false anchor: both now name the block that contains the fact — the call site
  on `Server.gd`'s `_enter_tree`, the format on `Util.gd`'s `PrintLog` — with each clause forced to
  spell its own symbol so the ruler checks it against the target rather than trusting a number.
  Measured on this tree: anchors 327 → 331, line pointers 357 → 353, identity-named pointers
  145 → 141, and the name-resolution floor unchanged at 87, because a full-path anchor resolves by
  literal and never enters that count. Gate: `== DOC DRIFT: 2105 checks, 0 failures ==` with
  `331 âncoras ... sobre 353 ponteiros de linha (teto 393), 0 acusações`.
- The DOC DRIFT gate reported a different total depending on whether the machine had ever run an export, and the
  leak was one branch trusting `os.path.isfile` over the index (`#157`). `resolve_path` resolves a cited path three
  ways — literal path, unique suffix, unique bare name — and the literal way was the offender: the resolution index
  already keeps `build/` and `dist/` out (a generated copy is not evidence, and indexing it would flip a true
  citation into "ambiguous" the moment anyone ran `scripts/export_web.sh`), but `os.path.isfile` on the committed
  tree happily returns true for `build/Web/index.html`. So the citation in `deploy/WEB_SLIM.md:78` of
  `build/Web/index.html:149` — a splash-image byte count the doc really measured, that line does hold the
  `<img id="status-splash">` — had its target read here and skipped in a clean clone, the single check the
  aggregate carried only locally. Measured by hiding `build/` and re-running: the total fell 2114 → 2113 while no
  census number moved (327 anchors, 357 line pointers, identity 145, the 87 name-resolution floor). The fix is
  scope, not metric: the literal branch now refuses any path that traverses an artifact segment, exactly as the
  index already does, so the citation resolves to nothing on both trees and the total reads 2113 exported or not.
  Godot's twin never carried the bug — `DirAccess` honors the tracked `build/.gdignore`, so the harness already
  treated the artifact as absent; it was the raw-`os.walk` bash ruler that had quietly diverged from its own twin.
- The "0,2%/kill" the last deferred truth-call chased was never in Formula at all, and naming the symbol that
  actually defines it is what moved the citation onto the right line (`#156`). The mechanical-trio slice had
  listed `Formula.gd:229` under what it would NOT swap, reasoning that anchoring the rate onto `ApplyXp` would
  drop a claim about a number onto a function that only rolls it — and it was right: line 229 is where the
  online farm grants the key, and no such percentage lives in Formula.gd. What that slice deferred was the
  other half, and it has a clean home: the rate is `KeyDropPPM` (`BossService.gd:@KeyDropPPM`), the 2000-ppm
  constant whose own comment spells out the percentage, the same number the online roll consumes. So the
  sentence at `tests/IdleTests.gd:2368` now names where the value is defined instead of pointing at a grant in
  another file. This is the last of the three pointers that slice left as truth calls rather than swaps:
  `Server.gd:490` became the real footprint gate two slices back, `Shop.gd:265` became the checkout-window
  creator in the prior one, and Formula's rate resolves here — leaving on `#156`'s files only the genuinely
  non-anchorable pair, `nginx.conf:174/205` (no declaration model for `.conf`) and `ci_gate_log.sh:42` (no
  column-zero function for a `@` to resolve to). Measured on this tree the conversion alone prints 326 anchors
  against 357 line pointers and `== DOC DRIFT: 2114 checks, 0 failures ==`, identity dropping 146 → 145 named
  while name-resolution holds at the 87 floor (the bare `BossService.gd` anchor resolves by name exactly as the
  bare `Formula.gd` pointer it retired did). This entry's one `arquivo:@símbolo` citation is charged inside the
  register: it lifts the census to 327 anchors against 357 line pointers, yet the aggregate holds at the same
  2114 the code conversion reached — the citation is counted as an anchor but added no new check on this tree
  (a clean clone prints one less, the #157 build-artifact pointer).
- A pointer the mechanical-trio slice filed as having "no single owning declaration" did have one, and only
  reading the sentence instead of arguing from its rotted line could surface it (`#156`). That slice had put
  `Shop.gd:265` under what it deliberately would NOT convert — "straddles `ShowDailyShop` and a checkout
  branch with no single owning declaration" — because line 265 is a daily-offer button built inside
  `ShowDailyShop`, while the checkout window the harness builds is created elsewhere. But the verdict was
  argued from the line, not the claim. The sentence says the Shop creates the window at runtime with `new()`
  + `add_child` in the GUI, and that claim has exactly one owner: `_show_web_checkout` (`Shop.gd:@_show_web_checkout`),
  which sets the GUI's checkout window to a freshly constructed dialog and then adds it as a child. Naming it
  dissolves the "straddles" — the two things that looked straddled were
  the rotted line's own function and a checkout branch the sentence never pointed at. This one falls on the
  aggregate where the OpenChest slice held flat: `Shop.gd:265` was an identity-named target, so the identity
  section was opening it line by line, and retiring it costs both that read and the walk read while the
  anchor adds back only one — measured here the conversion alone is 324 anchors against 358 line pointers and
  `== DOC DRIFT: 2114 checks, 0 failures ==`, identity dropping 147 → 146 named while name-resolution holds at
  the 87 floor (a full-path `sources/gui/Shop.gd` anchor would have moved that counter to 86 and the #116 walk
  guard would have bitten, so the bare filename anchor is kept resolving by name). This entry
  eats one charged `arquivo:@símbolo` citation inside the register, lifting the committed tree to 325 anchors
  against 358 line pointers and `== DOC DRIFT: 2115 checks, 0 failures ==` (a clean clone prints one less, the
  #157 build-artifact pointer). With it the two `#156` pointers the mechanical-trio slice left precisely
  because it had not followed the sentence to its witness are both resolved — `Server.gd:490` in the prior
  slice, `Shop.gd:265` here — and what genuinely remains on those three files are the ones it named as not
  mechanically swappable: the Formula key-drop line, where the "0,2%/kill" rate lives in `RollsKeyDrop` and not
  `ApplyXp`, so a claim about a rate must not ride onto the symbol that only rolls it, and the two
  non-anchorable `nginx.conf:174/205` (no declaration model for `.conf`) and `ci_gate_log.sh:42` (no
  column-zero function for a `@` to resolve to).
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
