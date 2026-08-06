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

## Not yet done

`inst/manifest.json` is empty: the build workflow has not been run, so no
binaries are published yet. Until then, build locally with
`tools/build-displace.sh` and set `DISPLACE_BINARY`. See `docs/roadmap.md` for
this and the rest of the known gaps.
