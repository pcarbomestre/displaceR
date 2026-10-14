# Changes this branch makes to DISPLACE v1.8.0

Branch `displace-grounds-by-port`. Upstream DISPLACE is never modified (see
`CLAUDE.md`): every change below is a patch file in `tools/patches/`, applied by
`tools/build-displace.sh` to a throwaway checkout of upstream `v1.8.0`
(`96eadecb1980`) at build time. Each one is **opt-in** (`--patch NAME`) and is
recorded as `feature_patches` in the build's `build-info.json`, so
`displace_features()` and `displace_installed()` show what a binary contains.

The compatibility patches the build script always applies (C++17, Boost,
GDAL, `random_shuffle`, ICES file) only make upstream compile and run; they do
not change model behaviour and are not listed here. See `docs/upstream-issues.md`
1-17.

## Feature patches

| Patch | Files | Changes model behaviour? | Why | Details |
|---|---|---|---|---|
| `grounds-by-port` | 8 files, +366/-3 | Only when the scenario sets `grounds_by_port` | Fishing grounds tagged by landing port: a trip draws its port, fishes only that port's grounds and lands there (A -> grounds of B -> B). Adds `trip_port`, `dep_port` to `loglike`. | `docs/grounds-by-port-spec.md`, `-plan`, `-log`, `-handover` |
| `headless-ipc-lazy` | `simulator/outputqueuemanager.{cpp,h}` | No (outputs byte-identical) | Headless runs no longer create the shared-memory `OutQueue`, whose creation race could abort simultaneous starts. | `docs/upstream-issues.md` 18 |
| `keep-unselected-othland` | `commons/Node.cpp`, 1 line | Yes, whenever other landings are used | Other landings set N to 0 for size groups with <= 1 kg available (sizes not selected), every month on every node with other landings. The patch leaves those fish in place. | `docs/upstream-issues.md` 19 |
| `astar-speedup` | `commons/shortestpath/AStarShortestPathFinder.{cpp,h}` | No (outputs byte-identical) | A* heuristic is NaN wherever \|longitude\| > 90 (swapped lat/lon in `GeoGraph`); return that NaN without the geodesic work, and memoise paths. ~4x faster on westcoast. | `docs/speedup.md` |
| `shortest-paths` | `commons/Vessel.cpp`, `commons/options.cpp`, `include/options.h`, new `commons/shortestpath/DijkstraShortestPathFinder.h` | Only when the scenario sets `shortest_paths` | Vessels follow exact shortest paths (Dijkstra, km) instead of upstream's A*, whose heuristic swaps latitude and longitude (median path 8% longer, up to 7x, on the westcoast graph). Changes results when on; off by default. | `docs/shortest-paths.md` |
| `sample-table-cache` | `include/myRutils.h` | No (outputs byte-identical) | `do_sample()` re-sorted the whole probability vector on every draw; the sorted cumulative table is now reused when the inputs are bit-for-bit identical. | `docs/speedup.md` |
| `reproducible-diffusion` | `commons/Population.cpp`, `commons/SimModel.cpp`, `include/Population.h`, +15 | Yes, when `diffusePopN` is on: the diffusion shuffle follows the simulation name instead of `std::random_device`. Results change relative to earlier runs (a different but equally valid draw); after that, the same name always gives the same run. | `diffusePopN` used a generator seeded from the OS, so runs were not reproducible even with the same `-s`. `SimModel::initRandom()` now reseeds it with the name's seed, as it does `rand()`. Every other random draw already followed the name. | below |
| `out-of-range-implicit` | `commons/Vessel.cpp`, `commons/options.cpp`, `include/options.h`, +19/-5 | Only when the scenario sets `out_of_range_implicit` | On nodes with `code_area` 10 every stock is caught as an implicit stock (gamma draw from the vessel's `gshape/gscale_cpue_per_stk_on_nodes` x cpue and metier multipliers; no presence check, no biomass removed, landings in size group 0), and the random change of ground is no longer blocked there. DISPLACE 1.5.0 did this (`do_catch_v150`, "implicit (or outside the range)"); the 1.8.0 rewrite of `do_catch` dropped it. Used by the westcoast analysis for grounds outside the species distribution domain. | below |
| `timestep-accounting` | `simulator/thread_vessels.cpp`, `simulator/outputexporter.{cpp,h}`, `simulator/main.cpp`, `commons/{Vessel,Node}.cpp`, `include/{Vessel,Node}.h`, options, +416/-18 | Only when the scenario sets `timestep_accounting` (and `partial_fishing`) | The 1 h step becomes a time budget spent on several actions (reach the ground and fish, decide to stop and head home, arrive and declare, in the same step), moves charge exactly the time and distance covered, vmslike gets one row per segment with `seg hours km`; `partial_fishing` fishes fractions of an hour with catch/effort scaled. Applied after the eight westcoast patches. Reviewed; passed acceptance tests A-E. | `docs/timestep-accounting.md` |

### Patches for upstream v1.9.2

Upstream v1.9.2 (`c7fe66fb`) includes its own versions of the patches above.
The patches below apply to `--ref c7fe66fb` only, not to v1.8.0.

| Patch | Files | Changes model behaviour? | Why |
|---|---|---|---|
| `out-of-range-implicit-v192` | `commons/Vessel.cpp`, +14/-11 | Only when the scenario sets `out_of_range_implicit` | In v1.9.2, `maybe_close_ground()` sends every stock on `code_area` 10 nodes to `handle_implicit_population()`, but the exception to the "stock listed on this node" check was put in `handle_explicit_population()`, which is never called there. Explicit stocks were therefore never caught outside their range. The patch moves the exception to `handle_implicit_population()`, as in `out-of-range-implicit` for v1.8.0; both functions then match the `1.8.0-96eadecb-westcoast-timestep` build. Also fixes `grounds_by_port` in `choose_a_ground_and_go_fishing()`: in v1.9.2 a moved brace attached the `else { set_metier(metiers[0]) }` fallback to `if (!by_port)`, so every vessel with port-tagged grounds started each trip with metier 0 instead of the metier drawn with its ground. The `else` is put back on the metier check, as in v1.8.0 + `grounds-by-port`. |
| `partial-fishing-effort-v192` | `commons/Vessel.cpp`, +5/-4 | Only with `partial_fishing` and an option that reads the vessel's experienced cpue (`focus_on_high_previous_cpue`, `focus_on_high_profit_grounds`, `shared_harbour_knowledge`, `experiencedCPUEsPerMet`, `experiencedCPUEsPerYearQuarter`) | In v1.9.2 `maybe_close_ground()` scales the catch and the node effort by `m_fishing_fraction`, but adds a full hour (`PING_RATE`) to the vessel's effort per ground (`cumeffort_per_trip_per_fgrounds`, `_per_yearquarter_`, `_per_met`), so the experienced cpue per ground is too low when fishing lasts less than an hour. The patch adds `PING_RATE * m_fishing_fraction`, as v1.8.0 + `timestep-accounting`; `maybe_close_ground()` then matches that build. No effect on the westcoast runs, which use none of those options. |
| `seeded-shuffle-v192` | new `include/seeded_shuffle.h`; `simulator/main.cpp`, `commons/Vessel.cpp`, `commons/diffusion.cpp`, +39/-18 | Yes: runs follow the simulation seed again | v1.9.2 replaced `random_shuffle` (removed in C++17) with `std::shuffle` on a new `std::random_device` generator at six sites: the vessel order every step (`main.cpp`), the change-of-ground draws (`choose_another_ground_and_go_fishing`, `should_i_change_ground`) and the nitrogen and benthos diffusion (`diffusion.cpp`). These draw from the operating system, so the same simulation name gave a different run each time. The patch uses `seeded_shuffle()`, the historical libstdc++ `random_shuffle` drawing from `rand()` (seeded by `SimModel::initRandom()`), portable C++17. Checked on westcoast calibration 10.0 (3 years): two runs with the same name are byte-identical in every output except `memstats` and `popdyn_annual_indic` (not reproducible on v1.8.0 either). |

The patches apply in any combination and order (`out-of-range-implicit` and
`grounds-by-port` both edit `Vessel.cpp` and the options files, in different
places; checked 2026-10-09).

## Building

The binary used by the westcoast analysis:

```bash
tools/build-displace.sh --ref v1.8.0 \
    --patch grounds-by-port --patch headless-ipc-lazy --patch keep-unselected-othland \
    --workdir scratch/build-patched --outdir scratch/dist-gbp
```

then in R:

```r
displaceR::install_displace(from = "scratch/dist-gbp/payload")
displaceR::displace_features()   # lists the three patches
```

The local install is labelled `1.8.0-96eadecb1980-<patches>-local`.

The westcoast calibration 4.x runs (outside_sdm = "implicit") use the same
build plus `--patch out-of-range-implicit` (`--outdir scratch/dist-oori`),
not installed in the cache: they point `DISPLACE_BINARY` at
`scratch/dist-oori/payload/displace`, so `displace_path()` keeps the build
above for the other runs (with several installs it picks the most recent).

### Speed patches

`astar-speedup` and `sample-table-cache` change no result: every output is
byte-identical with and without them (`docs/speedup.md`), and on the westcoast
calibrations a run is ~9-13x faster. They can be added to any build above.
`reproducible-diffusion` does change results once (diffusion draws now follow
the simulation name), so runs with it start a new baseline.

### Linux builds through CI

`.github/workflows/build-displace.yml` takes a `patches` input (space
separated, e.g. `grounds-by-port headless-ipc-lazy keep-unselected-othland
out-of-range-implicit astar-speedup sample-table-cache`). A patched build's
asset name ends in its patch list joined by `+`, so it never replaces the plain
asset. Install on the server with `install_displace(from = "<tarball>")`.

## R-side changes on this branch (no model code)

- `write_displace_fgrounds_harbours()`, `read_displace_fgrounds_harbours()`,
  `check_grounds_by_port()`, `displace_features()`.
- `read_displace_loglike()` and `displace_output_spec("loglike", grounds_by_port = TRUE)`
  know the two extra `loglike` columns.
- `run_displace()` refuses a `grounds_by_port` scenario on a binary built
  without that patch (`check_features = FALSE` overrides).
- `run_displace_campaign(start_lag = 15)`: parallel workers start replicates
  at least `start_lag` seconds apart.
- Local installs of feature-patched builds get their own version label.

## Verification

| Patch | Check | Where |
|---|---|---|
| `grounds-by-port` | Without the option: byte-identical to plain v1.8.0. With it: every trip lands at the port whose grounds it fished. | `docs/grounds-by-port-log.md` |
| `headless-ipc-lazy` | Outputs byte-identical. | `docs/upstream-issues.md` 18 |
| `out-of-range-implicit` | westcoast calibration 2.0 inputs, 1 month, simu1 (2026-10-09). Option off: totals within the run-to-run noise of the unpatched build (trips -1%, fishing pings +0.4%); every change is behind the option or code_area 10, so the model is the same by construction (runs are not byte-reproducible, see below). Option on (code_area 10 on the 2,857 sea nodes outside the SDM domain): fishing on code-10 nodes 38.7% -> 6.0% of the fishing pings, fuel-limited trips 22 -> 16 (mean 106 -> 48 h), trips fishing only there catch (28 of 39 end with a full hold, none before). | westcoast analysis `calibration/PLAN_sdm_domain.md` |
| `keep-unselected-othland` | westcoast test application (60 vessels, 1 year, same seed): other landings removed 98-99% of input; biomass loss 0.86-0.96x the landings (6.8-62x without the patch); vessel catches unchanged. Same with and without `grounds-by-port`. The `tools/build-displace.sh` build gives byte-identical outputs to the tested build. | `docs/upstream-issues.md` 19 |
| `timestep-accounting` | westcoast calibration 7.47, sequoia (2026-10-10). Options off: 38/39 output files byte-identical to the `1.8.0-96eadecb-westcoast-repro` binary (only `memstats` differs). Options on: per-trip sums of vmslike segment `hours`/`km` reproduce the logbook's `cumsteaming`, fishing time and `traveled_dist`; acceptance tests A-E over 13 years x 3 seeds. | `docs/timestep-accounting.md` |
| `reproducible-diffusion` | westcoast calibrations 4.0 and 2.0, real `baseline` (`diffusePopN`, `grounds_by_port`, 4.0 also `out_of_range_implicit`), 2200 steps, production output settings, macOS arm64 (2026-10-09). With the patch, `simu1` twice: 38/38 result files byte-identical on both (only `memstats` differs); `simu2` differs (1,683 vs 1,670 trips). Without it, `simu1` twice: 11 files differ (1,748 vs 1,669 trips). | `docs/speedup.md` |

When comparing runs, give them the same seed: DISPLACE seeds `rand()` with the
first integer in the simulation name (`sim7_a` and `sim7_b` share seed 7;
`sim1` and `sim5` do not).
