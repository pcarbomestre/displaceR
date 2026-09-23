# displaceR 0.1.0.9000

## DISPLACE 1.8.0

* Verified against upstream `v1.8.0` (`96eadecb`). 16 commits past `7f2656fb`;
  no change to the CLI, the build system or the SQLite schema (`dbVersion` 4).
  Every existing build patch still applies, and the golden-file tests pass
  against a 1.8.0 binary.
* Model behaviour did change: 1.7.0–1.8.0 fix N depletion in `do_catch()`, the
  cpue multiplier's annual update, monthly area closures, times at sea, and TAC
  logic that silently assumed a discard ban. Results are not comparable with
  1.6.6, so the manifest default stays on 1.6.6 until switched deliberately.
* The macOS payload now bundles Boost, GeographicLib and sqlite like Linux
  does. The first 1.8.0 macOS build, linked against CI's Homebrew Boost 1.92,
  aborted at startup on a Mac with Boost 1.90.
* New build patch `ices-optional`: 1.8.0 aborts at load when
  `graphsspe/coord<N>_with_icesrectanglecode.dat` is missing, although upstream
  treats the file as optional. The patch restores the zeros upstream already
  prepares. It fires only on trees that have the new size check, so 1.6.6
  builds are unchanged. See `docs/upstream-issues.md` 16.
* `validate_displace_input()` now checks every per-node layer
  (`coord<N>_with_<layer>.dat`): it must exist and hold at least `nrow_coord`
  values, which 1.8.0 enforces at load time. A missing ICES-rectangle layer is a
  warning, not an error.
* 1.8.0 reads an optional `metiersspe_<name>/metier_catchrate_multiplier_fleetsce<N>.dat`
  (defaults to 1.0 per metier when absent) and writes `cumsteaming` and
  `timeatsea` in `loglike_*.dat` to one decimal. The `loglike` reader already
  types those columns by inference, so no reader change was needed.

## R 4.6

* `R CMD check --as-cran` is clean on R 4.6.1 (0 errors, 0 warnings), and the
  full test suite, golden tests included, passes against both simulator
  versions.

# displaceR 0.1.0

First release. Implements Phases 1–4 of the plan in `CLAUDE.md`.

## Build pipeline (Phase 1)

* `tools/build-displace.sh` builds the headless DISPLACE simulator from a
  pinned upstream ref. CI and a laptop run the same script.
* `.github/workflows/build-displace.yml` runs it on Ubuntu 22.04 and 24.04,
  verifies the payload is relocatable with `LD_LIBRARY_PATH` unset, and
  publishes `displace-<sha>-linux-x86_64-glibc<v>.tar.gz` plus a sha256.
* The payload is built with `RPATH=$ORIGIN`, which upstream does not set.
  Without it the tarball only works with `LD_LIBRARY_PATH`.

## Binary distribution (Phase 2)

* `install_displace()`, `displace_path()`, `displace_versions()`,
  `displace_version()`, `displace_installed()`, `uninstall_displace()`.
* Checksums are verified before installation; a mismatch refuses to install.
* Installation is staged and moved into place, so an interrupted download
  cannot leave a half-populated version directory.
* Builds are keyed by glibc target and `install_displace()` picks the newest
  one the host can actually run.
* `DISPLACE_BINARY` overrides everything; `DISPLACER_CACHE` relocates the cache.
* `displace_version()` reports both the DISPLACE version string and the upstream
  commit. Only the second is unique — `include/version.h` hardcodes the first.

## Running and reading (Phase 3)

* `run_displace()` and `displace_args()`. Always passes
  `--disable-crash-handler`, never `--use-gui`, and creates the output tree
  before launching.
* `run_displace_replicates()`, with a `map` hook for `future`/`furrr`.
* SQLite readers: `read_displace_db()`, `displace_db_tables()`,
  `displace_db_query()`, `displace_db_version()`, `displace_db_metadata()`.
* Text readers: `read_displace_output()`, `read_displace_loglike()`,
  `displace_output_files()`, `displace_output_spec()`.
* Input formats: `read`/`write_displace_config()`,
  `read`/`write_displace_scenario()`, `read`/`write_displace_graph()`,
  `read_displace_code_area()`, `create_displace_input()`,
  `validate_displace_input()`.

## Tracking upstream (Phase 4)

* `.github/workflows/upstream-watch.yml` polls upstream weekly and opens a
  single tracking issue, listing which of the four fragile surfaces changed.
* `tests/testthat/test-golden.R` runs the minitest dataset and reads every
  output back through the package's readers. This is the drift detector; it
  skips unless `DISPLACE_MINITEST_DIR` and a binary are available.
* `.github/workflows/R-CMD-check.yaml` on every push.

## Upstream behaviours worth knowing

Found while reading the parsers; the full list is in `CLAUDE.md` Appendix C.

* `config.dat` and the scenario `.dat` are **positional**, keyed on line number.
  `#` is not a comment character. One inserted line silently shifts every field.
* `nrow_coord` / `nrow_graph` come from the **scenario** file, not `config.dat`,
  and are what the stacked graph files are parsed with.
* `graphsspe/` is **flat** — it takes no parameterisation suffix, unlike
  `simusspe_`, `vesselsspe_` and the rest.
* `--huge` defaults to **on** upstream, and a bare `--huge` turns it **off**
  (its implicit value is 0). `run_displace()` always passes it explicitly.
* Options with boost implicit values (`-p`, `-e`, `-v`, `--huge`) need their
  value adjacent to the flag; `-p 1` would be misparsed.
* Graph edge weights are **truncated**, not rounded, when the simulator reads
  them into a `vector<int>`. `read_displace_graph()` reports both values.

## Offline and diagnostic support

* `install_displace(from = ...)` installs from a locally built tarball or
  payload directory. This is the route for a server with no outbound network
  access, and the route that works before any release has been published: build
  once on any machine with a compiler, copy the tarball over, install it here.
  Payloads carry a `build-info.json`, so provenance survives the trip.
* `displace_doctor()` checks platform, glibc, cache writability, the binary,
  its shared libraries, whether it actually runs, and the optional packages --
  and says what to do about each failure. Run it first on a new machine.

## Verified against a real build and a real run

The build script was executed end to end and the binary run against
`frabas/DISPLACE_input_minitest`. That turned up several things the plan and
upstream documentation had wrong; all are recorded in `docs/upstream-issues.md`.

* **Upstream does not compile unpatched at 7f2656fb.** `cmake/compiler.cmake`
  pins C++14 while `Population.{h,cpp}` need C++17, and msqlitecpp's exported
  CMake target omits its include directory. `tools/build-displace.sh` patches
  both at build time, conditionally.
* **Every SQLite run exits 139.** DISPLACE segfaults in static destruction after
  `main()` returns 0, with all outputs written and intact. `run_displace()`
  verifies completion from the output database before forgiving it.
* Output layouts corrected against real files: `fishfarmslogs` (misnamed in the
  docs, and 14 columns not 10), `shipslogs` types, `popnodes_impact_per_szgroup`
  colliding with `popnodes_impact`. Added `vmslikefpingsonly`, `popdyn`,
  `popdyn_F`, `popdyn_SSB`, `nodes_envt`, `quotasuptake` and two more.
* The demo dataset's parameterisation name is `fake`, not `minitest`.

## Not yet done

`inst/manifest.json` is empty: the build workflow has not been run in GitHub
Actions, so no binaries are published yet. The script it runs has been executed
successfully by hand, so this is a matter of triggering the workflow rather than
of unproven code. Until then use `install_displace(from = ...)` or
`DISPLACE_BINARY`. See `docs/roadmap.md`.
