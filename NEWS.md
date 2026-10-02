# displaceR 0.1.0.9000

## Port-tagged fishing grounds (`grounds-by-port` feature patch, branch only)

* `tools/build-displace.sh --patch grounds-by-port` builds DISPLACE v1.8.0 with
  `tools/patches/grounds-by-port.patch`: a new `dyn_alloc_sce` option
  `grounds_by_port` under which each vessel reads
  `vesselsspe_<app>/<vid>_fgrounds_harbours_quarter<N>.dat`, draws a trip port,
  fishes only that port's grounds and lands there (A -> grounds of B -> B).
  `loglike` gains `trip_port` and `dep_port` at the end of each line. Without
  the option the build behaves as plain v1.8.0. Opt-in, recorded as
  `feature_patches` in `build-info.json`. Spec: `docs/grounds-by-port-spec.md`.
* New `write_displace_fgrounds_harbours()`, `read_displace_fgrounds_harbours()`,
  `check_grounds_by_port()` and `displace_features()`.
  `read_displace_loglike()` names the two new columns;
  `displace_output_spec("loglike", grounds_by_port = TRUE)` lists them.
* `run_displace()` refuses a scenario using `grounds_by_port` on a binary whose
  build record lacks the patch (`check_features = FALSE` overrides): an
  unpatched simulator ignores the option and would silently run baseline.
* Second opt-in patch, `--patch headless-ipc-lazy`: headless runs no longer
  create the shared-memory object `OutQueue`, which only the desktop GUI uses
  and which could make DISPLACE runs started at the same moment abort with
  "File exists". Outputs are unchanged. See `docs/upstream-issues.md` 18.
* `run_displace_campaign()` gains `start_lag` (default 15 s): parallel
  workers launch replicates at least that far apart, through a small lock in
  `output_dir/.displaceR-launch/`, so their initial reads of the input tree do
  not coincide. A launch more than `start_lag` after the previous one does not
  wait; `start_lag = 0` disables it.
* Local installs of feature-patched builds get their own label
  (`1.8.0-96eadecb1980-grounds-by-port-local`) and record `feature_patches`.

## Building graphs from polygons

* New `build_displace_graph()`: an R port of the editor GUI's "Create Graph"
  (`qtgui/graphbuilder_shp.cpp` upstream), which the headless simulator does
  not include. It lays a hex or square grid over a box, keeps the nodes inside
  the `include` polygons and outside the `exclude` ones, and links neighbours by
  Delaunay triangulation, with WGS84 geodesic km as edge weights. It supports
  two include areas at different resolutions and an optional coarser "outside"
  grid, like the GUI. Needs `sf` (Suggests).
* New `link_displace_harbours()`: the GUI's "Load Harbours" and "Link
  Harbours". Appends ports as harbour nodes and links each one to its nearest
  sea nodes. It also reads the GUI's `name;lon;lat;code` harbour file.
* Checked against the westcoast case study's GUI-built graph. From the same
  shapefiles it gives byte-identical `coord` files and the same edges and
  weights. `write_displace_graph(digits = 6)` writes the GUI's 6-significant-digit
  number format.
* New `add_displace_closure()` and `write_displace_closures()`: the GUI's
  "Add Penalty from File". Each edge crossing a polygon gets `weight` added
  once per polygon it crosses, and nodes inside are written to the monthly
  `metier_`, `vsize_` and `nation_closure_a_graph<N>_month<M>.dat` files. The
  deprecated quarterly files, which the simulator no longer reads, are not
  written. Checked against the westcoast graph 2 (wind lease areas at weight
  500): all 36 closure files are byte-identical and every penalised weight
  matches.
* The output goes straight into `write_displace_graph()`. See
  `docs/graph-builder.md` for how the port differs from the GUI and why it is
  a port rather than a compiled upstream tool.

## DISPLACE 1.8.0

* Verified against upstream `v1.8.0` (`96eadecb`). 16 commits past `7f2656fb`;
  no change to the CLI, the build system or the SQLite schema (`dbVersion` 4).
  Every existing build patch still applies, and the golden-file tests pass
  against a 1.8.0 binary.
* Model behaviour did change: 1.7.0–1.8.0 fix N depletion in `do_catch()`, the
  cpue multiplier's annual update, monthly area closures, times at sea, and TAC
  logic that silently assumed a discard ban. Results are not comparable with
  1.6.6. 1.8.0 is now the manifest default; `install_displace("1.6.6-7f2656fb-beta2")`
  still installs the old version, and existing installs are left alone.
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

## Windows

* `install_displace()` now installs DISPLACE 1.8.0 on Windows x86_64. The
  binary is built with MSVC and vcpkg in CI, bundles Boost, GeographicLib,
  sqlite and the Microsoft C++ runtime, and passes the minitest smoke test and
  the package's own test suite on `windows-2022`.
* New build patch `windows-outdir`: on Windows the simulator ignored `-O` and
  wrote every output to `C:/DISPLACE_outputs`, because a local variable
  shadowed the option. See `docs/upstream-issues.md` 17.
* Each platform's C library has its own `rand()`; keep a set of replicates on
  one platform (runs are not bit-reproducible anyway, `docs/upstream-issues.md`
  11).

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
