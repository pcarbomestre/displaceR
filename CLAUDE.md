# displaceR — project context

## Goal

An R package that runs the DISPLACE fisheries simulator from R on a Linux
server, installable with `remotes::install_github()` and requiring **no
compiler, no root, and no CMake on the target machine**. The package must keep
working when upstream DISPLACE releases new versions.

Constraint: the user cannot build DISPLACE manually on their server. They run R
via Positron on that server. DISPLACE is the only model of interest — this is
not negotiable, alternatives (e.g. `marlin`) have been considered and rejected.

## Hard constraint — upstream is read-only

**`frabas/DISPLACE_GUI` must never be modified.** No issues, no pull requests,
no branches, no comments — nothing is pushed to, or filed against, that
repository or any other upstream project (`studiofuga/mSqliteCpp`,
`greg7mdp/sparsepp`). Upstream is consumed at a pinned SHA and nothing more.

Every fix, workaround and piece of documentation lives **in this repository**:

- Build-time patches applied to a throwaway checkout by
  `tools/build-displace.sh` — conditional, never committed to any upstream tree,
  and self-disabling if upstream ever changes.
- Compatibility sources under `tools/patches/`.
- Findings recorded in `docs/upstream-issues.md`, which is an **internal
  engineering record of what we work around and why** — not a to-do list of
  reports to send. Read it that way.

This is not a licensing or etiquette question; it is a project rule. If a
problem seems to need an upstream change, the answer is to handle it here or to
document it as a known limitation.

## Upstream

- Repo: https://github.com/frabas/DISPLACE_GUI (GPL-2.0) — **read-only, see above**
- Verified against HEAD `7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de` (2026-08-05)
- Binary self-reports as `version 1.6.6 build 0`

## Architecture (three layers, deliberately separate)

1. **Upstream DISPLACE** — never forked, never vendored into the R package.
   Referenced by tag or commit SHA only.
2. **Build pipeline** — GitHub Actions workflow in the `displaceR` repo. Checks
   out a given upstream ref, builds the headless simulator, publishes a tarball
   as a release asset.
3. **R package** — contains no C++ and no `src/`. Downloads a prebuilt binary,
   writes inputs, runs the simulator, reads outputs.

The separation is the point: a new upstream version means re-running layer 2,
not editing layer 3.

## Rejected approaches — settled, do not reopen

- **Vendoring DISPLACE's C++ into `src/` and compiling via Rcpp.** DISPLACE is a
  CMake application with `main()`, file-based I/O, and shared libraries — not a
  library with a bindable API. Wrapping it would mean rewriting the simulator.
  Rejected.
- **A `configure` script that runs CMake at install time.** Technically legal
  (R runs `configure` before `src/Makevars`), but it needs a compiler, CMake, and
  all system deps present on the target — exactly what the user does not have.
  Rejected on the user's constraint, not on principle.
- **Bundling GDAL (or Boost/CGAL) source into the package.** GDAL drags in PROJ,
  GEOS, libtiff, curl, plus PROJ runtime data. `sf`/`terra` do not compile GDAL
  either — they download prebuilt static libs. Moot anyway: the headless
  simulator does not link GDAL at all (see Phase 0 findings).
- **`marlin` (github.com/DanOvando/marlin) as an architectural model.** Wrong
  analogue — one C++ file, no system deps, designed R-first. Also evaluated and
  rejected as a substitute model; the user needs DISPLACE specifically.

### Correct precedents to follow

- **r4ss / Stock Synthesis** — closest match. Compiles nothing; reads/writes
  SS3's input files, runs the executable, parses outputs. `get_ss3_exe()`
  downloads a prebuilt binary from GitHub releases into a user directory.
- **cmdstanr** — large C++ backend with its own build system; the R package is
  thin and backend installation is a separate `install_cmdstan()` step into a
  user-writable directory.

## Build facts (verified in Phase 0)

### Build environment specifics

- **C++17** (`cmake/compiler.cmake` sets `CMAKE_CXX_STANDARD 17`). CMake >= 3.20.
- **Boost >= 1.55**, components: `date_time filesystem system thread
  program_options log unit_test_framework`. All are `REQUIRED` in
  `cmake/dependencies.cmake` even when `WITH_TESTS=Off`, so
  `unit_test_framework` must be installed — `libboost-all-dev` covers it.
- `commons` and `formats` are built as **SHARED** libraries, which is why the
  `.so` files must ship alongside the executable.
- The build is slow single-core (`commons` is ~100 translation units). Use `-j$(nproc)`.
- Also built headless and possibly useful: `avaifieldshuffler`,
  `avaifieldupdater`, `vmsmerger` (no Qt/GDAL/CGAL deps). Not needed for Phase 1,
  but cheap to include in the tarball if the R package ever needs them.

### RPATH — must be added, not inherited

Upstream sets **no** RPATH (`cmake/platform-linux.cmake` is nearly empty). Without
it, the tarball only works with `LD_LIBRARY_PATH` set. Add at configure time:

```
-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN'
```

(escape `$ORIGIN` carefully in YAML/shell), or post-process with
`patchelf --set-rpath '$ORIGIN' displace libcommons.so`. Verify with
`ldd` in a clean shell before publishing the asset.

### Versioning trap

`include/version.h` hardcodes `#define VERSION "1.6.6"` — it is **not** derived
from git tags and changes rarely. Two different upstream commits will usually
report the same `--version`/`--help` banner. **Use the upstream commit SHA as the
authoritative manifest key**; treat the 1.6.6 string as informational only.
`displace_version()` should report both.

## PHASE 0 — COMPLETE. Verified build recipe

Confirmed working on Ubuntu 24.04, glibc 2.39, gcc 13.3, CMake 3.28.
Full source compile + link + `--help` all succeed.

```bash
# System deps — all in the Ubuntu archive
apt-get install -y libboost-all-dev libgeographiclib-dev \
                   libgdal-dev libsqlite3-dev

# Header-only
git clone --depth 1 https://github.com/greg7mdp/sparsepp

# msqlitecpp — NOT packaged anywhere, must build from source (~2 min)
git clone --depth 1 https://github.com/studiofuga/mSqliteCpp
cmake -S mSqliteCpp -B mSqliteCpp/Build -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_TEST=Off -DENABLE_PROFILER=Off \
      -DCMAKE_INSTALL_PREFIX=$PWD/local
cmake --build mSqliteCpp/Build --target install

# DISPLACE, headless
cmake -S DISPLACE_GUI -B DISPLACE_GUI/Build -DCMAKE_BUILD_TYPE=Release \
      -DWITHOUT_GUI=On -DSPARSEPP_ROOT=$PWD/sparsepp \
      -DCMAKE_PREFIX_PATH=$PWD/local
cmake --build DISPLACE_GUI/Build --target displace
# -> DISPLACE_GUI/Build/bin/displace
```

### Hard-won findings — do not relearn these

- **`-DDISABLE_IPC=On` is broken upstream.** It excludes the IPC sources but
  `thread_vessels.cpp` and `biomodule2.cpp` still reference
  `OutputQueueManager::enqueue`, `mOutQueue`, and `guiSendUpdateCommand`, so the
  link fails. **Leave IPC enabled** — it is inert unless `--use-gui` is passed.
  Would be a small fix in `commons/CMakeLists.txt`, but upstream is read-only:
  the build script leaves IPC enabled instead (it is inert without `--use-gui`).
- **`WITHOUT_GUI=On` drops Qt6 and CGAL entirely** — they are gated behind it in
  `cmake/dependencies.cmake`. It skips `QMapControl`, `qtcommons`, `qtgui`, the
  editors, the scheduler, and `tests`.
- **GDAL is a configure-time formality only.** `find_package(GDAL REQUIRED 1.11)`
  sits *outside* the `WITHOUT_GUI` guard, so `libgdal-dev` must be present to
  configure — but GDAL does **not** appear in the binary's `ldd` output and is
  not needed at runtime. Handled here instead: the build script makes the GDAL
  lookup optional at configure time, so `libgdal-dev` is not a dependency.
- **vcpkg is unnecessary on Linux.** The repo ships `vcpkg.json` and a
  `vcpkg-overlays/msqlitecpp` port, but apt + a source build of msqlitecpp is far
  faster and less fragile. Keep vcpkg in mind only if targeting Windows/macOS.
- **GeographicLib version string prints empty** during configure. Harmless; it
  still links (`libGeographicLib.so.26`).

### Runtime payload

DISPLACE's own files:

```
displace             (817 KB)
libcommons.so        (4.8 MB)
libformats.so        (233 KB)
libmsqlitecpp.so.1
```

**Plus every third-party dependency except the platform ABI floor** — on Ubuntu
24.04 that is Boost (`program_options`, `filesystem`), GeographicLib and
sqlite3, roughly 10 MB more.

Treating those as "stock system libs" was wrong and shipped a broken tarball:
they reach the build machine via `libboost-all-dev` / `libgeographiclib-dev`,
which are **build** dependencies, so a bare compute server does not have them.
The binary then dies at startup with `error while loading shared libraries:
libboost_program_options.so.1.83.0` even when the OS and glibc match the builder
exactly. Bundling is what keeps the "no root on the target" constraint true.

The ABI floor — `libc`, `libstdc++`, `libgcc_s`, `libm`, the loader — is
deliberately **never** bundled. Those are shared by every library in the
process (R has already loaded `libstdc++` before `displace` runs), and symbol
versioning is one-directional, so a bundled copy older than the host's breaks in
ways a missing library does not. The glibc rule below is what handles them.

`tools/build-displace.sh` derives the list from `ldd` rather than hardcoding it,
so a new upstream dependency is bundled automatically, and asserts that nothing
outside the floor is left unbundled. That assertion is the check that matters:
plain `ldd` cannot fail on the machine that built the binary, because the build
deps are installed there.

Build with `RPATH=$ORIGIN` so the tarball is relocatable and needs no
`LD_LIBRARY_PATH`. `$ORIGIN` also means the bundled copies win for `displace`
only — nothing is installed system-wide and no other program's view of Boost
changes.

**macOS is not bundled.** Mach-O records an absolute install name in each
dependent, so it needs `install_name_tool -change` rather than a copy. The macOS
payload still relies on Homebrew.

### glibc / portability rule

Build on a runner whose glibc is **no newer** than the target server's. Verified
on 2.39 (Ubuntu 24.04). If the server is 22.04 (2.35) or 20.04 (2.31), rebuild on
the matching runner; older Boost/GeographicLib is the main risk.

## The simulator CLI — this is the whole R API surface

```
-f  <name>    input folder name (e.g. DISPLACE_input_minitest)
-F  <name>    output folder name  (--f2)
-a  <path>    path to the input folder
-O  <dir>     output directory    (--outdir)
-s  <name>    simulation name
-i  <n>       number of steps (hours). 8762 ~= 1 year. NO maximum: nbsteps is
              a plain int, unvalidated. The 52586 in upstream's README is a
              GUI slider limit, not a simulator one. 10 years = 87673.
-V  <n>       verbosity level
-p  [=0]      use static paths
-e  [=1]      export VMSLike data
-v  [=0]      selected vessels only
-d  <val>     dparam
--huge [=0]           export huge files
--indb <db>           read inputs from a SQLite db instead of text files
--commit-rate <n>     loops before committing to sqlite
--num_threads <n>     threads for moving vessels
--rate <n>            displayed moves out of 20
--disable-sqlite      turn off SQLite output
--disable-crash-handler
--debug
--use-gui             DO NOT USE — IPC channel to the GUI
--without-gnuplot     no-op, compatibility only
```

Notes: default `--disable-crash-handler` from R (the handler is unhelpful
headless). Investigate `--indb` — feeding inputs as SQLite is likely a far better
R interface than generating the text-file zoo.

## Input formats — two paths

DISPLACE can load a model **either** from text files (`TextfileModelLoader`,
`commons/TextImpl/`) **or** from a SQLite database (`DatabaseModelLoader`,
`commons/DatabaseInputImpl/`, selected with `--indb`). Investigate the DB path
early — generating one SQLite file from R is far more tractable than emitting the
text-file zoo, and it is likely the more stable interface.

### Text input folder structure

Given `-a <inputfolder> -f <name>`, the loader reads subfolders whose names are
suffixed with the parameterisation name, e.g.:

```
graphsspe_<name>/        simusspe_<name>/       vesselsspe_<name>/
metiersspe_<name>/       harboursspe_<name>/    firmsspe_<name>/
shortPaths_<name>/       min_distance_<name>/   previous_<name>/
```

Within `vesselsspe_`, files are keyed by type and quarter, e.g.
`vesselsspe_fgrounds_quarter1.dat`, `vesselsspe_harbours_quarter3.dat`.
Metier files are semester-based: `metierspe_betas_semester*`,
`metierspe_mls_cat_semester*`, `metierspe_discardratio_limits_semester*`,
`metierspe_is_avoided_stocks_semester*`.

Scenario `.dat` files live in `simusspe_<name>/`. Canonical reference:
`InputFileFormats.txt` in the repo root, plus the `DISPLACE_input_minitest`
repository. Defaults if unset: `-f fake`, `-F baseline`, `-a .`.

## Output formats

### SQLite (preferred for R readers)

`commons/storage/sqliteoutputstorage.cpp` defines
`CURRENT_DB_SCHEMA_VERSION = 4`, written into the `Metadata` table under the key
`dbVersion`. **This is the correct dispatch key for version-aware readers** —
more reliable than the DISPLACE version string.

Tables: `Metadata`, `VesselDef`, `VesselLogLike`, `VesselLogLikeCatches`,
`VesselVmsLike`, `VesselVmsFPingsOnlyLike`, `Ships`, `NodesDef`, `NodesEnvt`,
`NodesStat`, `NodesTariffStat`, `PopDyn`, `PopQuotas`, `PopValues`, `FuncGroups`,
`FishFarmsDef`, `Fishfarms`, `Windmills`. Aggregation helpers exist for `months`,
`quarters`, `semesters`, `years`.

Disable with `--disable-sqlite`; tune write batching with `--commit-rate`.

### Text files

Documented with column layouts in `docs/output_fileformats.md`, written to
`DISPLACE_outputs/<basepath>/<basename>/`. Includes `vmslike_*.dat`,
`vmslikefpingsonly_*.dat`, `popstats_*.dat`, `popdyn_annual_indic_*.dat`,
`benthosnodes_tot_biomasses_*.dat`, `popnodes_start_*.dat`, and others.
`--huge` and `-e` control which of the large exports are produced.

## Related upstream R work — reuse, don't reinvent

- `https://github.com/frabas/DISPLACE_R_inputs` — R routines to build a case
  study from scratch. Data-hungry and case-specific; the upstream README says
  these should ideally become a package. Basis for Phase 3 writers.
- `https://github.com/frabas/displaceplot` — existing R package for reading the
  text outputs and plotting. Check before writing readers; may be reusable or
  worth depending on.
- Example datasets: `https://displace-project.org/blog/download/`. Unzip into a
  folder named `DISPLACE_input_xx`; `DISPLACE_input_minitest` is the minimal one
  used for demos and is the right smoke-test fixture.

## Remaining phases

### Phase 1 — Build pipeline
GitHub Actions workflow, `workflow_dispatch` input for the upstream ref. Runs the
recipe above, smoke-tests on the minitest dataset, `ldd`s the binary, bundles the
runtime payload (see above), publishes `displace-<ref>-linux-x86_64.tar.gz` +
sha256.
Get it green once against a pinned SHA before automating.

### Phase 2 — Binary distribution
`inst/manifest.json` mapping version -> {url, sha256, upstream_sha}. R functions:
- `install_displace(version = NULL)` — download to
  `tools::R_user_dir("displaceR", "cache")`, verify checksum, unpack, chmod +x
- `displace_versions()`, `displace_path()`, `displace_version()`
- `displace_path()` respects a `DISPLACE_BINARY` env var override
- Default version pinned in the package for reproducibility

### Phase 3 — R I/O layer (the real work)
- Writers: build a valid `DISPLACE_input_xx` folder from R objects. Reuse logic
  from https://github.com/frabas/DISPLACE_R_inputs (the upstream README says
  these should ideally become a package).
- Runner: `run_displace()` wrapping `system2()`, temp working dir, captured
  stdout for progress, non-zero exit handling.
- Readers: text outputs per `docs/output_fileformats.md`; SQLite output via
  `RSQLite` (prefer this — structured and more stable than text parsing).
- Parallel replicates via `future`/`furrr` over independent working dirs.

**Runtime defaults worth baking into `run_displace()`:**
- Always pass `--disable-crash-handler` (the handler is useless headless).
- Never pass `--use-gui`.
- Expose `--num_threads`; note DISPLACE threads vessel movement internally, so
  do not naively multiply it by `future` workers on a shared server.
- Step-count sanity: 8762 steps ~= 1 year (hourly). There is **no** maximum —
  `nbsteps` is a plain int parsed from `-i` and never validated. The 52586
  figure in upstream's README describes a slider in the *GUI's* Setup menu and
  does not constrain the headless simulator; real case studies exceed it
  routinely (a 10-year run is `-i 87673`). Multi-year, multi-replicate runs are
  slow — that is why upstream recommends HPC.
- Sanity-check that `-O`/`-F` output directories exist before launching; the
  simulator is not consistently defensive about missing paths.

### Phase 4 — Tracking upstream
The fragile surface is exactly four things: **CLI arguments, input formats,
output formats, SQLite schema.** Design for these changing.
- Scheduled workflow polls upstream for new tags, opens an issue / triggers build
- **Golden-file regression tests**: run minitest, snapshot outputs, diff on every
  new upstream build. This is what catches interface drift early.
- Version-aware readers in `R/formats/`, dispatched on installed DISPLACE version
- `install_displace()` becomes the only thing users update on a new release

## Licensing

DISPLACE is GPL-2.0. Distributing its binaries means `displaceR` must be
GPL-2-compatible and must offer corresponding source — in practice, the exact
upstream SHA plus the build workflow. Document in release notes.

## Open items

- [ ] Clarify whether `shortPaths_*` / `min_distance_*` caches must be
      pre-generated per case study, and how `-p` (use static paths) interacts
      with them — blocks Phase 3 writers

- [ ] Server's `cat /etc/os-release; ldd --version; uname -m` — sets runner target
- [ ] Does `R CMD config CXX` work on the server? Does
      `devtools::install_github("DanOvando/marlin")` succeed? (toolchain canary)
- [x] Run the minitest dataset and verify output correctness — done; the golden
      test passes and CI smoke-tests every build against it
- [x] ~~File upstream issue: `DISABLE_IPC` link failure~~ — upstream is
      read-only. Handled here: IPC stays enabled, inert without `--use-gui`.
- [x] ~~Upstream PR: move `find_package(GDAL)` inside the `WITHOUT_GUI` guard~~
      — upstream is read-only. Handled here: the build script makes GDAL
      optional at configure time.
- [x] ~~Ask maintainer whether he'd publish headless binaries~~ — not available
      to us. The build pipeline is permanent infrastructure, not a stopgap.

---

# Appendix A — Output text file column layouts

Transcribed from `docs/output_fileformats.md` at upstream `7f2656fb`. **Verify
against the repo before relying on these** — they drift. Fields are
space/whitespace separated, no headers. Written to
`DISPLACE_outputs/<basepath>/<basename>/`.

| File | Columns (in order) |
|---|---|
| `vmslike_*.dat` | tstep, name, tstep_dep, x, y, course, cum_fuel, state |
| `vmslikefpingsonly_*.dat` | tstep, vessel name, start-trip tstep, lon, lat, nodeid, course, cumfuelcons, pop, then catches (landings+discards, weight) for szgroup 0..13 |
| `popstats_*.dat` | tstep, stock, N at szgroup (14 szgrps, thousands of individuals), W at szgroup (kg), SSB at szgroup (kg) |
| `popdyn_annual_indic_*.dat` | tstep, stock, oth mult, cpue mult, fbar, tot landings, tot discards, SSB, N at age, F at age, W at age, M at age |
| `benthosnodes_tot_biomasses_*.dat` / `benthosnodes_tot_numbers_*.dat` | func gr id, tstep, node, long, lat, number this funcgroup, biomass this funcgroup, mean weight this funcgroup, benthosbiomassoverK, benthosnumberoverK, benthos_tot_biomass_K this funcgr |
| `popnodes_start_*.dat` | tstep, node, long, lat, then tot N sp0, tot W sp0, tot N sp1, tot W sp1, ... |
| `popnodes_inc_*.dat` | same layout as `popnodes_start_*.dat` |
| `popnodes_impact_*.dat` | pop, tstep, node_idx, long, lat, impact_on_pop |
| `popnodes_cumulcatches_per_pop_*.dat` | pop, tstep, node_idx, long, lat, cumcatches (actually landings) |
| `popnodes_cumftime_*.dat` | tstep, node, long, lat, cumftime |
| `popnodes_cumsweptarea_*.dat` | tstep, node, long, lat, cumsweptarea, subsurfacecumsweptarea |
| `popnodes_cumcatches_*.dat` | tstep, node_idx, long, lat, cumcatches (landings only, unless discard ban) |
| `popnodes_cumdiscards_*.dat` | tstep, node_idx, long, lat, cumdiscards |
| `popnodes_cumcatches_with_threshold_*.dat` | tstep, node_idx, long, lat, cumcatches, threshold (percent) |
| `popnodes_tariffs_*.dat` | tstep, node, long, lat, tariffs |
| `tripcatchesperszgroup_*.dat` | tstep, vessel name, departure tstep, popid, catches (landings only, unless discard ban) szgroup 0..13 |
| `export_individual_tac_*.dat` | tstep, vesselid, pop, remaining quota this pop, amount discarded if remaining is 0 |
| `fishfarmlogs_*.dat` | tstep, node, long, lat, farmtype, farmid, meanw_kg, fish_harvested_kg, eggs_harvested_kg, fishfarm_annualprofit |
| `shipslogs_*.dat` | tstep, node, long, lat, shiptype, shipid, nb_units, fuel_use_h, NOx_emission_gperkW, SOx_emission_percentpertotalfuelmass, GHG_emission_gperkW, PME_emission_gperkW, fuel_use_litre, NOx_emission, SOx_emission, GHG_emissions, PME_emission |
| `windmillslogs_*.dat` | tstep, node, long, lat, windfarmtype, windfarmid, kWh, kW_production |
| `<app>_simu1_out.db` | SQLite database duplicating most of the above (see Output formats section) |

## `loglike_*.dat` — the economics file, variable width

Column count depends on the number of populations, so it must be constructed
dynamically. Fixed leading fields (0-indexed):

```
0  tstep_dep
1  tstep                  (arrival / current tstep)
2  reason_to_go_back
3  cum_steam
4  loc->nodeidx           (harbour node)
5  idx                    (vessel index)
6  name                   (VE_REF)
7  timeatsea
8  cumfuelcons
9  travel_dist_this_trip
10..10+N  cumul sz per pop 1..N   (landings only)
```

Then, in order: `freq_metiers`, `revenue`, `revenue_from_av_prices`,
`revenue_explicit_from_av_prices`, `fuelcost`, `gav`, `gav2` (gav handling energy
cost only), `sweptarea` (EU FP7 BENTHIS parameterisation), `revenuepersweptarea`,
`GVA` (handles all costs, needs deeper parameterisation), `GVAPerRevenue`,
`LabourSurplus`, `GrossProfit`, `NetProfit`, `NetProfitMargin`, `GVAPerFTE`,
`RoFTA`, `BER`, `CRBER`, `NetPresentValue`, `numTrips`.

Upstream supplies this R idiom for naming the columns — note it inserts a
`disc.*` block for explicit pops that the plain field list above omits, so
**trust this construction over the flat list**:

```r
colnames(loglike) <- c('tstep_dep', 'tstep_arr', 'reason_back', 'cumsteaming',
  'idx_node', 'idx_vessel', 'VE_REF', 'timeatsea', 'fuelcons', 'traveled_dist',
  paste('pop.', 0:(general$nbpops-1), sep=''),
  "freq_metiers", "revenue", "rev_from_av_prices",
  "rev_explicit_from_av_prices", "fuelcost", "vpuf", "gav", "gradva",
  "sweptr", "revpersweptarea",
  paste('disc.', explicit_pops, sep=''),
  "GVA", "GVAPerRevenue", "LabourSurplus", "GrossProfit", "NetProfit",
  "NetProfitMargin", "GVAPerFTE", "RoFTA", "BER", "CRBER", "NetPresentValue",
  "numTrips")
```

Post-processing artefacts (produced by upstream R routines, not the simulator):
`lst_loglike_weight_agg_sce*.RData`, `average_cumftime_layer.txt`.

---

# Appendix B — Input file index

`InputFileFormats.txt` (repo root, 693 lines) documents each input file as
purpose / fields / separators / headings. It is stated to be for DISPLACE v0.9.0
and generated from the `testexample` dataset via the Objects Editor R routines
(except `graphsspe`, from the Graph editor) — so **treat it as indicative and
validate against `DISPLACE_input_minitest`**. Below is the complete file index;
read the full spec from the repo for per-file field detail.

### `/graphsspe/`
`coord*.dat`, `graph*.dat`, `code_area_for_graph*_points.dat`,
`coord*_with_landscape.dat`, `metier_closure_a_graph*_quarter*.dat`

**Critical structural quirk:** `coord*.dat` and `graph*.dat` are *column-stacked,
not row-wise*. There are no delimiters or headers — one value per line. For
`coord*.dat` with `nrow` nodes, node *i*'s longitude is at line *i*, latitude at
*i+nrow*, harbour flag at *i+2·nrow*. For `graph*.dat` with `nrow` edges: source
node at *i*, destination at *i+nrow*, weight/cost at *i+2·nrow* (read as a
rounded integer). `code_area_for_graph*_points.dat` follows the same stacking,
with the first two blocks ignored by the simulator and the third holding the area
code. Dataset sizes come from `config.dat`. Any R writer must reproduce this
layout exactly.

### `/popsspe_*/`
`*ctrysspe_relative_stability_semester*.dat`,
`*spe_fbar_amin_amax_ftarget_Fpercent_TACpercent.dat`,
`*overall_migration_fluxes_semester*_biolsce*.dat`, `*spe_initial_tac.dat`,
`*spe_percent_age_per_szgroup_biolsce*.dat`,
`*spe_percent_szgroup_per_age_biolsce*.dat`,
`*spe_size_transition_matrix_biolsce*.dat`, `*spe_SSB_R_parameters_biolsce*.dat`,
`*spe_stecf_oth_land_per_month_per_node_semester*.dat`,
`comcat_per_szgroup_done_by_hand.dat`, `hyperstability_param.dat`,
`init_fecundity_per_szgroup_biolsce*.dat`, `init_M_per_szgroup_biolsce*.dat`,
`init_maturity_per_szgroup_biolsce*.dat`, `init_pops_per_szgroup_biolsce*.dat`,
`init_prop_migrants_pops_per_szgroup_biolsce*.dat`,
`init_proprecru_per_szgroup_biolsce*.dat`, `init_weight_per_szgroup_biolsce*.dat`,
`percent_landings_from_simulated_vessels.dat`,
`species_interactions_mortality_proportion_matrix_biolsce*.dat`,
`the_selected_szgroups.dat`, `avai_betas_semester*.dat`

Note the `biolsce*` suffix — biological scenario variants are encoded in
filenames, as are `semester*` / `quarter*`. Size-group matrices are 14 szgroups;
age conversion matrices are 11 ages × 14 szgroups, rows summing to 1.

### `/vesselsspe_*/`
`*_cpue_per_stk_on_nodes_quarter*.dat`, `*_possible_metiers_quarter*.dat`,
`*_freq_possible_metiers_quarter*.dat`,
`*_gscale_cpue_per_stk_on_nodes_quarter*.dat`,
`*_gshape_cpue_per_stk_on_nodes_quarter*.dat`,
`fuel_price_per_vessel_size.dat`, `initial_fishing_credits_per_vid.dat`,
`vesselsspe_betas_semester*.dat`, `vesselsspe_features_quarter*.dat`,
`vesselsspe_fgrounds_quarter*.dat`, `vesselsspe_freq_fgrounds_quarter*.dat`,
`vesselsspe_harbours_quarter*.dat`, `vesselsspe_freq_harbours_quarter*.dat`,
`vesselsspe_percent_tacs_per_pop_semester*.dat`

`main.cpp` confirms the simulator loads `fgrounds` and `harbours` for all four
quarters at startup — all four must exist or loading fails.

### `/metiersspe_*/`
`*loss_after_one_passage_per_landscape_per_func_group.dat`,
`*metier_selectivity_per_stock_ogives.dat`, `combined_met_types.dat`,
`met_target_names.dat`, `metier_fspeed.dat`,
`metier_gear_widths_model_type.dat`, `metier_gear_widths_param_a.dat`,
`metier_gear_widths_param_b.dat`, `metier_names.dat`,
`metierspe_betas_semester*.dat`, `metierspe_mls_cat_semester*.dat`,
`percent_revenue_completenesses.dat`

Additional metier files referenced from the loader but not in the v0.9.0 doc:
`metierspe_discardratio_limits_semester*`,
`metierspe_is_avoided_stocks_semester*`,
`metier_fuel_reduction_multiplier_fleetsce*`.

### `/harboursspe_*/`
`*_quarter*_each_species_per_cat.dat`, `names_harbours.dat`

### `/benthosspe_*/`
`estimates_biomass_per_cell_per_funcgr_per_landscape.dat`

### `/shipsspe_*/`
`shipsspe_features.dat`, `shipsspe_lanes_lat.dat`, `shipsspe_lanes_lon.dat`

### `/fishfarmsspe_*/`
`size_per_farm.dat`

### `/simusspe_*/`
`baseline.dat`, `config.dat`, `tstep_days_2009_2015.dat`,
`tstep_months_2009_2015.dat`, `tstep_quarters_2009_2015.dat`,
`tstep_semesters_2009_2015.dat`, `tstep_years_2009_2015.dat`

`config.dat` is the central file: it sets node and edge counts (which the
`graphsspe` stacked-column files depend on) and enables/disables implicit
populations and calibration features. It is `#`-comment aware. Scenario files
loaded via the GUI's "Load a Scenario Model" are the `.dat` files here —
`baseline.dat` is the default (`-F baseline`).

### Other
`/timeseries/ts.txt`, `/externalforcing_*/`, `/dtrees/`,
`/shortPaths_*_a_graph*/`, `/firmsspe_*/`, `/min_distance_*/`, `/previous_*/`

`shortPaths_*` and `min_distance_*` are precomputed path caches — check whether
they must be generated ahead of a run or whether `-p` (use static paths) governs
this. This is an open question for Phase 3.

---

# Appendix C — Implementation log (Phases 1–4)

Written while implementing the plan. Everything below was checked against a
fresh clone of upstream `7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de` by reading
the parsers themselves, not the docs.

## Corrections to the sections above

These override the earlier text where they conflict.

1. **`graphsspe/` is NOT suffixed with the parameterisation name.**
   `TextfileModelLoader.cpp:96` builds `<inputfolder>/graphsspe/coord<a_graph>.dat`
   — a flat, shared folder. Only `simusspe_`, `vesselsspe_`, `metiersspe_`,
   `popsspe_`, `harboursspe_`, `benthosspe_`, `shipsspe_`, `fishfarmsspe_`,
   `firmsspe_`, `externalforcing_` take the `_<name>` suffix. The graph files are
   keyed by the *graph number* (`a_graph`) instead.

2. **`nrow_coord` / `nrow_graph` come from the scenario file, not `config.dat`.**
   `read_scenario_config_file()` (`commons/readdata.cpp:292`) reads them from
   `simusspe_<name>/<namefolderoutput>.dat` (e.g. `baseline.dat`). `config.dat`
   only carries `nbpops`, `nbmets`, `nbbenthospops` and the calibration vectors.
   This matters: the stacked-column `coord*.dat` / `graph*.dat` files are parsed
   using the *scenario's* row counts, so scenario and graph files must agree.

3. **`config.dat` and the scenario `.dat` are strictly positional, not
   `#`-comment aware.** Both are read by `LineNumberReader`
   (`formats/utils/LineNumberReader.cpp`), which keys on the **0-indexed line
   number** and ignores everything else. Values live on odd 0-indexed lines
   (1, 3, 5, …); the even lines happen to be comments by convention but are never
   parsed. Inserting or deleting a single line silently shifts every field.
   Blank lines still count. This is the single most fragile input format.

4. **Graph edge weights are truncated, not rounded.** `fill_from_graph()`
   (`commons/myutils.cpp:369`) `lexical_cast<double>`s each line and pushes it
   into a `vector<int>` — an implicit narrowing conversion, i.e. truncation
   toward zero.

5. **Blank lines are skipped without incrementing the row counter** in
   `fill_from_coord` / `fill_from_graph` / `fill_from_code_area`
   (`continue` precedes `++linenum`). Writers must not rely on padding.

6. **SQLite output path** is
   `<outdir>/DISPLACE_outputs/<f>/<F>/<f>_<s>_out.db` — built at
   `simulator/main.cpp:740` from `-O`, `-f`, `-F`, `-s`. Text outputs land in
   `<outdir>/DISPLACE_outputs/<f>/<F>/`.

7. **`tstep_*.dat` calendar files have a fallback name.** The loader tries
   `tstep_quarters.dat` first and falls back to `tstep_quarters_2009_2015.dat`
   (same for months/semesters/years). Files are `-1`-terminated integer lists.

## Authoritative field specs (transcribed from the parsers)

### `simusspe_<name>/config.dat` — `read_config_file()`, `commons/readdata.cpp:114`

0-indexed line -> field. Value lines only; all other lines ignored.

| Line | Field | Type |
|---|---|---|
| 1 | `nbpops` | int |
| 3 | `nbmets` | int |
| 5 | `nbbenthospops` | int |
| 7 | `implicit_pops` | int vector, space separated |
| 9 | `calib_oth_landings` | double vector, length must equal `nbpops` |
| 11 | `calib_weight_at_szgroup` | double vector, length must equal `nbpops` |
| 13 | `calib_cpue_multiplier` | double vector, length must equal `nbpops` |
| 15 | `int_harbours` | int vector (node ids) |
| 17 | `implicit_pops_level2` | int vector |
| 19 | `grouped_tacs` | int vector; defaults to `0..nbpops-1` if empty |
| 21 | `nbcp_coupling_pops` | int vector |

The three `calib_*` length checks throw at load time — they are the cheapest
pre-flight validation available and are implemented in `validate_displace_input()`.

### `simusspe_<name>/<scenario>.dat` — `read_scenario_config_file()`, `commons/readdata.cpp:292`

| Line | Field | Type |
|---|---|---|
| 1 | `dyn_alloc_sce` | space-separated option names |
| 3 | `dyn_pop_sce` | space-separated option names |
| 5 | `biolsce` | string (used as a filename suffix) |
| 7 | `fleetsce` | string (used as a filename suffix) |
| 9 | `freq_do_growth` | int |
| 11 | `freq_redispatch_the_pop` | int |
| 13 | `a_graph` | int -> `a_graph<N>` |
| 15 | `nrow_coord` | int (rows of `coord<N>.dat` per block) |
| 17 | `nrow_graph` | int (rows of `graph<N>.dat` per block) |
| 19 | `a_port` | int (node id) |
| 21 | `graph_res` | double vector; length 1 is duplicated to (x, y) |
| 23 | `is_individual_vessel_quotas` | int, 0/1 |
| 25 | `check_all_stocks_before_going_fishing` | int, 0/1 |
| 27 | `dt_go_fishing` | string |
| 29 | `dt_choose_ground` | string |
| 31 | `dt_start_fishing` | string |
| 33 | `dt_change_ground` | string |
| 35 | `dt_stop_fishing` | string |
| 37 | `dt_change_port` | string |
| 39 | `use_dtrees` | int, 0/1 |
| 41 | `tariff_pop` | int vector |
| 43 | `freq_update_tariff_code` | int |
| 45 | `arbitary_breaks_for_tariff` | double vector (upstream spelling) |
| 47 | `met_multiplier_on_arbitary_breaks_for_tariff` | double vector |
| 49 | `total_amount_credited` | int, default 0 |
| 51 | `tariff_annual_hcr_percent_change` | double, default 0 |
| 53 | `update_tariffs_based_on_lpue_or_dpue_code` | int, default 0 |
| 55 | `metier_closures` | int vector, may be empty |

Note `commons/commons_tests/inputfiles_simusspe.cpp` still carries a fixture
that predates line 47 (`met_multiplier_...`) and is therefore off by one from
line 47 onward. **Trust `readdata.cpp`, not that test.**

### `graphsspe/coord<N>.dat` — `fill_from_coord()`, `commons/myutils.cpp:324`

One value per line, no header, no delimiter. With `nrow = nrow_coord`:
lines `[0, nrow)` = x (longitude), `[nrow, 2*nrow)` = y (latitude),
`[2*nrow, 3*nrow)` = harbour flag (int). Reading stops at `3*nrow`.

### `graphsspe/graph<N>.dat` — `fill_from_graph()`, `commons/myutils.cpp:369`

Same stacking with `nrow = nrow_graph`: `from` node idx, `to` node idx,
`dist_km` (truncated to int).

### `graphsspe/code_area_for_graph<N>_points.dat` — `fill_from_code_area()`

Same stacking with `nrow = nrow_coord`. **The first two blocks are read and
discarded**; only the third block (the area code) is used. Writers must still
emit all three blocks.

## What this repository now contains

- `tools/build-displace.sh` — the Phase 0 recipe as an idempotent script.
  CI and a human on a laptop run the same code path.
- `.github/workflows/build-displace.yml` — Phase 1. `workflow_dispatch` with an
  upstream ref, matrix over Ubuntu 22.04/24.04 for glibc targeting, `ldd`
  verification in a clean environment, tarball + `.sha256` published as a
  release asset.
- `.github/workflows/upstream-watch.yml` — Phase 4. Daily poll of upstream HEAD;
  opens an issue when the SHA moves past what `inst/manifest.json` pins.
- `.github/workflows/R-CMD-check.yaml` — package check on every push.
- `inst/manifest.json` — Phase 2 version -> asset map.
- `R/` — Phases 2 and 3. No `src/`, no compiled code.

## Deliberately not implemented

- **A full case-study writer.** Building a complete `DISPLACE_input_xx` tree
  from R objects needs the ~150 files in Appendix B and, more importantly, real
  data to validate against. `DISPLACE_input_minitest` was not available offline
  during this work. What is implemented instead: the folder scaffolder, the four
  formats whose parsers were read line by line (`config.dat`, the scenario
  `.dat`, the stacked graph triple), and a validator that catches the failures
  the loader throws on. Everything else is an explicit gap, tracked in
  `docs/roadmap.md`.
- **Version-dispatched readers.** The dispatch seam exists
  (`displace_output_spec()` takes a `db_version`), but there is only one schema
  version (4) in the wild, so there is nothing to dispatch on yet.
