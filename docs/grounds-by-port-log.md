# Progress log: `grounds_by_port` patch

Plan: [grounds-by-port-plan.md](grounds-by-port-plan.md). Newest entries at the
bottom. All paths under `scratch/` are gitignored (`.gitignore: scratch/`).

## 2026-10-01

### Setup

- Branch `displace-grounds-by-port` created from `main` (`be83281`).
- DISPLACE source: `git clone https://github.com/frabas/DISPLACE_GUI.git
  scratch/DISPLACE_GUI-v1.8.0`, `git checkout --detach v1.8.0` ->
  `96eadecb1980d6f9ad22571cd6f963cc05379815` ("v1.8.0 - Major fix of TAC logic
  ...", 2026-09-17). This checkout is the development tree; the patch is
  `git diff` of it, saved as `tools/patches/grounds-by-port.patch`.
- Toolchain already present (nothing installed): Apple clang 17.0.0 (arm64),
  CMake 4.4.0, Homebrew boost 1.90.0_1, geographiclib 2.7, sqlite 3.53.3.
  R 4.6 with testthat, RSQLite, DBI, jsonlite, sf, devtools in the system
  library.
- Public test data: `git clone --depth 1
  https://github.com/frabas/DISPLACE_input_minitest.git scratch/minitest`
  (`22d98622`). Not confidential; used only as the base of the synthetic test
  application.
- Reference build, unpatched v1.8.0, same script and options as the released
  binary:

  ```
  tools/build-displace.sh --ref v1.8.0 --workdir scratch/build-unpatched \
      --outdir scratch/dist-unpatched     # log: scratch/logs/build-unpatched.log
  ```

  Result: OK in ~4 min, `build_patches: cxx17 boost-components gdal-optional
  random-shuffle ices-optional msqlitecpp-includes`, payload
  `scratch/dist-unpatched/payload/displace` reports 1.8.0 build 0.

### Source reading (v1.8.0) -- where the trip decisions are

| Step | Where | Upstream behaviour |
|---|---|---|
| metier for GoFishing | `Vessel::which_metier_should_i_go_for` (called every hour in port, `simulator/thread_vessels.cpp:254`) | ground drawn from all `freq_fgrounds`, metier drawn from `possible_metiers` on it |
| ground | `Vessel::choose_a_ground_and_go_fishing` | ChooseGround dtree, or freq-reshaping options, monthly closures, `metier_mask`, draw; metier re-drawn on the ground |
| change of ground | `Vessel::choose_another_ground_and_go_fishing` | closest / 2nd closest among all `fgrounds` |
| landing port | `Vessel::choose_a_port_and_then_return` | `closer_port` or draw from `freq_harbours` |
| logbook | `OutputExporter::exportLogLikePlaintext` (`simulator/outputexporter.cpp`), called from `main.cpp:3258` at the end of the arrival step, then `reinit_after_a_trip` | landing node = `get_loc()` |
| loader | `commons/TextImpl/LoadVesselsImpl.cpp` `loadLocalData` / `loadVessels` / `reloadVessels` (each quarter) | |
| DB loader | `commons/DatabaseInputImpl/LoadShipsAndVesselsImpl.cpp` | unfinished upstream (`nbmets = 300` TODO, start harbour FIXME); not extended |

Other facts that shaped the design:

- `types::NodeId` is `uint16_t`; the invalid id is 65535 (printed as -1 in the
  new column).
- `do_catch` finds the current node's per-vessel catch parameters by its index
  in `fgrounds` (`Vessel.cpp:5508`), so port-tagged grounds must be a subset of
  the vessel's `vesselsspe_fgrounds_quarterN.dat` grounds.
- The scenario parser silently ignores unknown option names
  (`Option::setOption(string)`), so the same `baseline.dat` with
  `grounds_by_port` runs (as baseline) on an unpatched binary.
- The validation runs were made on Windows with `--num_threads 3`; vessel
  threads share the global `rand()`, so those runs are not reproducible
  bit-for-bit. Check 2 compares unpatched vs patched builds made here, with
  `--num_threads 1`.

### C++ patch

Files changed (final patch, `git -C scratch/DISPLACE_GUI-v1.8.0 diff --stat`):

```
 commons/TextImpl/LoadVesselsImpl.cpp | 125 ++++++++++++++++++++++
 commons/Vessel.cpp                   | 194 ++++++++++++++++++++++++++++++++++-
 commons/options.cpp                  |   1 +
 include/Vessel.h                     |  30 ++++++
 include/options.h                    |   1 +
 simulator/main.cpp                   |   1 +
 simulator/outputexporter.cpp         |  12 +++
 simulator/outputexporter.h           |   5 +
 8 files changed, 366 insertions(+), 3 deletions(-)
```

Every new code path is behind `dyn_alloc_sce.option(Options::grounds_by_port)`;
with the option off the only differences are one unused enum value, one unused
map entry, three idle members per Vessel (one of them written at departure,
never read) and a `false` flag in the exporter.

`tools/build-displace.sh` gained `--patch NAME` (opt-in, applied with
`git apply` to a restored tree before the compatibility patches, recorded as
`feature_patches` in `build-info.json`, fails if the patch does not apply).

Later additions to the patch, found while testing (all in the final patch):

- `dep_port` logbook column after `trip_port`: vessels are not pinged in port,
  so the departure port cannot be read from `vmslike`; it is needed to verify
  "next departure == previous landing".
- `dep_port` comes from a new member `trip_dep_port` set at departure. A first
  version used upstream's `previous_harbour_idx`, but the quarterly reload sets
  that to node 0 (`LoadVesselsImpl.cpp:1194`), so 6 of 2,367 trips (those at
  sea across a quarter change) reported `dep_port = 0`.
- Closure leak in `choose_another_ground_and_go_fishing`: upstream's checks use
  the current metier, while the patch draws the metier on the new ground among
  the port's entries there. Under `grounds_by_port`, entries closed to their
  own metier (open days used) are now excluded from the candidates and from
  that draw.

### Check 1 -- build on macOS arm64 (PASS)

```
tools/build-displace.sh --ref v1.8.0 --patch grounds-by-port \
    --workdir scratch/build-patched --outdir scratch/dist-gbp
# log: scratch/logs/build-gbp.log
```

Same script, options and compatibility patches as the released binary
(`cxx17 boost-components gdal-optional random-shuffle ices-optional
msqlitecpp-includes`) plus `feature_patches: grounds-by-port`. Compiler
warnings: 8, the same 8 as the unpatched build. Payload relocatable (bundled
dylibs, `otool` check, `--help` smoke test in the script). Build ~4 min.

### Check 2 -- baseline equivalence on validation_1.0 (PASS, with one upstream caveat)

Copy of `DISPLACE_input_westcoast_validation_1.0` in `scratch/check2/`
(read-only source untouched). Runs: `scratch/check2/run.sh` =
`displace -f westcoast_validation_1.0 -F <scenario> -s simu1 -i <steps> -p 0 -e 1
--huge=1 -v0 -V 1 --num_threads 1 --disable-crash-handler`, sqlite on,
comparison script `scratch/check2/compare.R` (md5 per file, first diverging
tstep).

1. **Upstream v1.8.0 is not reproducible with the validation scenario.** Two
   runs of the *same unpatched binary*, same seed, one thread, run one after
   the other, differ (744 steps: loglike, vmslike differ from the trip arriving
   at tstep 153; 36 of 39 files identical). Cause found:
   `Population::diffuse_N_from_field()` (the `diffusePopN` option in
   validation_1.0's `dyn_pop_sce`) shuffles nodes with a `std::mt19937`
   seeded from `std::random_device` (`commons/Population.cpp:30-31`), i.e. a new
   seed every run, independent of `-s`. Ruled out on the way: threads (one
   worker, FIFO jobs), missing multiplier files (default to 1), uninitialised
   heap (`MallocPreScribble=1 MallocScribble=1` runs still differ).
   The patched binary diverges from unpatched at the same place and in the same
   way as unpatched from unpatched (first loglike difference at arrival tstep
   153 in all pairs).
2. **Exact test**: scenario `baseline_nodiff` = validation `baseline.dat` with
   `dyn_pop_sce` `baseline` instead of `baseline diffusePopN` (only line 4
   changed; written in the scratch copy only). 744 steps:

   ```
   nd-unpatched-1 vs nd-unpatched-2: 38 of 39 .dat files identical   differ: memstats_simu1.dat
   nd-unpatched-1 vs nd-gbp-1:       38 of 39 .dat files identical   differ: memstats_simu1.dat
   ```

   `memstats` is the process's RSS report. All 18 SQLite output tables
   (`VesselLogLike` 582 rows, `VesselVmsLike` 24,685, `PopValues` 92,195,
   `PopDyn`, ...) identical between unpatched and patched.

So: without the option the patched build is bit-identical to unpatched v1.8.0
wherever v1.8.0 is itself reproducible. Earlier 1,488-step runs with
`diffusePopN` (`out-*`) show the same pattern as the 744-step ones.

Side findings (upstream, not caused by the patch; recorded for the user):

- Every DISPLACE process creates the boost::interprocess shared memory
  `"OutQueue"` from a global constructor, even headless; two processes
  starting at the same moment race and one aborts with
  `interprocess_exception: File exists` (seen once here with 3 simultaneous
  starts). Stagger parallel starts (`run_displace_replicates()` /
  `campaign` should be checked for this).
- With SQLite output on, the simulator segfaults in teardown (known, handled by
  `run_displace()`), and it does so **before flushing text streams**: on the
  small synthetic application `vmslike` lost everything after tstep 0. Large
  files only lose their last buffer. Use `sqlite = FALSE` when the text
  outputs matter.
- `vmslike` is only written with `--huge=1`; `-e 1` limits it to the first
  year (`-e 10` = all years).
- A stray copy of one check-2 output database
  (`westcoast_validation_1.0_simu1_out.db`, 6 MB) was written to `/tmp` by a
  `cp` in a comparison command, against the "nothing outside the repo" rule;
  it was deleted immediately after (2026-10-01 ~15:00).

### Check 3 -- option on, synthetic application (PASS)

Synthetic application: `make_grounds_by_port_app()` in
`tests/testthat/helper-grounds-by-port.R`, built on the public minitest (41
nodes): 3 ports (36, 40, 4), 9 port-tagged entries (node 26 tagged by two
ports with different metiers), 6 vessels with different port shares (quarter 3
swaps two ports' shares), DNK005 tagged in quarter 1 only, DNK006 without any
file. Script: `scratch/check3.R`, output `scratch/logs/check3.txt`. 2 years
(17,524 steps), `sqlite = FALSE`, `huge = TRUE`, `export_vmslike = 10`.

| check | gbp | gbpnochange | gbpclosure |
|---|---|---|---|
| trips (tagged) | 2,373 (1,762) | 2,409 (1,775) | 2,323 (1,775) |
| tagged = trips of vessels with entries | 0 fail | 0 | 0 |
| landing node == trip_port | 0 fail | 0 | 0 |
| dep_port == previous landing | 0 / 2,367 fail | 0 / 2,403 | 0 / 2,317 |
| every fished node in trip port's entries | 0 fail | 0 | 0 |
| every metier used in trip port's entries | 0 fail | 0 | 0 |
| port shares vs weights, chi2 p per vessel | 0.71 - 0.91 | 0.16 - 0.84 | see below |
| metier shares vs weights | (changes of ground on, n/a) | 0.30 - 0.71 | - |

- 503 tagged trips in `gbp` fished more than one node (changes of ground), all
  within the trip port.
- Untagged trips: DNK006 all `trip_port = -1`; DNK005 tagged only in quarter 1.
- Example (DNK001): `dep 4 -> port 36 -> land 36`, `36 -> 36`, `36 -> 40 -> 40`,
  `40 -> 36 -> 36` ...
- Closures (`gbpclosure`, node 30 closed to metier 0 = port 36's only entry
  there; node 26 closed to metier 0 = port 40's entry): node 30 fished on 0
  trips; node 26 fished on 163 trips, all with trip port 36 (its open metier
  1). Port shares shift as the closures imply: against the shares recomputed
  without the closed entries, chi2 p = 0.06 - 0.60 per vessel.
- `gbpnochange` (ChangeGround dtree with probability 0): every tagged trip used
  one metier; metier shares match the weights.
- Patched binary, `baseline` scenario (option off): loglike 36 columns, no
  `trip_port`; 1,092 trips.
- No change to metiers, GoFishing, catch: the patch touches only
  `which_metier_should_i_go_for`, `choose_a_ground_and_go_fishing`,
  `choose_another_ground_and_go_fishing`, `choose_a_port_and_then_return`, the
  vessel loader, options and the loglike writer -- not `do_catch`,
  `should_i_go_fishing`, `Metier`, selectivity or the dtree code (`grep` on
  the patch). nbmets is read from `config.dat` as before.

### Check 4 -- displaceR (PASS)

```
DISPLACE_MINITEST_DIR=$PWD/scratch/minitest \
DISPLACE_GBP_BINARY=$PWD/scratch/dist-gbp/payload/displace \
  Rscript -e 'devtools::test()'      # scratch/logs/r-tests.txt
```

All files pass; `grounds-by-port`: 46 expectations incl. the four
simulator-backed tests (A -> B -> B, metier shares, closures, option off).
Skipped: 1 doctor test (no `ldd` on macOS) and the golden tests (no
`DISPLACE_BINARY`); with `DISPLACE_BINARY` set to the patched binary the
golden tests pass too. `R CMD check` (`devtools::check()`, no manual):
0 errors, 0 warnings, 0 notes.

## 2026-10-02

### `headless-ipc-lazy`: no shared memory in headless runs

Problem (upstream, every build): the global `OutputQueueManager mOutQueue`
(`simulator/ipc.cpp`) holds an `IpcQueue` by value, and constructing one opens
or creates the machine-wide boost::interprocess shared memory `"OutQueue"`
(`commons/ipcqueue.cpp`: try `open_only`, else `create_only`). This happens at
static initialisation, before `--use-gui` is even parsed, so every headless
run touches it. Two processes starting together can both fail the open and
then race on the create; the loser aborts with
`interprocess_exception: File exists` (exit 134, 0 steps). On macOS boost
backs the object with files under `/tmp/boost_interprocess/`; on Linux with
`/dev/shm/OutQueue`.

Fix: `tools/patches/headless-ipc-lazy.patch` (simulator/outputqueuemanager.h/.cpp,
+8/-2): the member becomes `std::unique_ptr<IpcQueue>`, created in `start()`
only when the protocol is Binary, i.e. when `--use-gui` was given. GUI runs
create it as before (just before the output thread starts); headless runs
never do. Opt-in like `grounds-by-port`:

```
tools/build-displace.sh --ref v1.8.0 --patch grounds-by-port --patch headless-ipc-lazy \
    --workdir scratch/build-patched --outdir scratch/dist-gbp     # scratch/logs/build-gbp-ipc.log
```

Build: OK, same 8 compiler warnings; `feature_patches: grounds-by-port
headless-ipc-lazy`. This build replaced `scratch/dist-gbp`.

Tests (`scratch/race.sh`: N minitest runs of 50 steps started at once, sqlite off):

- Old binary (grounds-by-port only), first round of the day, 8 at once: **7 of 8
  aborted** (exit 134). The race is intermittent: the old binary's later
  rounds, 224 starts in all (incl. 10 rounds x 16 with
  `/tmp/boost_interprocess/` removed before each), aborted 0. It seems to hit
  mostly the first creation after a reboot, when that directory does not exist
  yet.
- New binary: 0 of 232 starts aborted, and in the 3 rounds checked from a clean
  state (directory removed first) it never created `/tmp/boost_interprocess/`,
  i.e. the object the race is about is no longer used at all.
- Results unchanged: old vs new binary, same seed, one thread, sqlite off --
  minitest `baseline` 4,000 steps and the synthetic app's `gbp` 8,762 steps:
  all 39 text output files byte-identical in both.

Cleanup outside the repo: the empty `/tmp/boost_interprocess/` directory
created by these test runs was removed with `rmdir` between rounds; it is
recreated by any plain DISPLACE run, and is harmless.
