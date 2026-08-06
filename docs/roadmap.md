# Roadmap and known gaps

Status of the plan in `CLAUDE.md`, as built.

| Phase | Status |
|---|---|
| 0 — Verified build recipe | Complete, and corrected: upstream does not build unpatched. See `docs/upstream-issues.md` 1 and 2. |
| 1 — Build pipeline | Implemented and **executed end to end**: `tools/build-displace.sh` produces a working, relocatable `displace 1.6.6`. Not yet run in GitHub Actions. |
| 2 — Binary distribution | Implemented. Manifest is empty until a release is published. |
| 3 — R I/O layer | Runner and readers complete and **verified against a real run**. Writers cover 4 of ~150 input formats. |
| 4 — Tracking upstream | Watcher plus a golden-file harness that now passes against the real minitest dataset. |

## Blocking, in order

### 1. Run the build workflow once — **needs you**

`tools/build-displace.sh` has been run end to end on Ubuntu 24.04 and produces a
working binary, so the recipe is proven. What has *not* run is the same script
inside GitHub Actions, which is the only way to get a published release asset.

Run **Build DISPLACE binary** with
`upstream_ref: 7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de` and no `release_tag`,
and read the step summary. When it is green, re-run with a `release_tag` and
paste the manifest entry into `inst/manifest.json`. This needs repository write
access, so it is yours to trigger.

Until then, users can build locally and set `DISPLACE_BINARY` — that path is
tested and works.

### 2. The minitest dataset — **done**

`frabas/DISPLACE_input_minitest` is a public repository, cloned and used. Note
its parameterisation name is **`fake`**, not `minitest`: the folders are
`simusspe_fake/`, `vesselsspe_fake/` and so on.

```r
Sys.setenv(DISPLACE_MINITEST_DIR = "/data/DISPLACE_input_minitest")
Sys.setenv(DISPLACE_BINARY = "/path/to/displace")
testthat::test_local(".")     # test-golden.R stops skipping
```

The golden test passes: `validate_displace_input()` accepts the real case study,
the config/scenario/graph readers round-trip it, and every recognised text
output of a real 50-step run reads back with the right column count.

### 3. Confirm the target server

From `CLAUDE.md`'s open items, still unanswered:

```bash
cat /etc/os-release; ldd --version; uname -m
```

This picks the runner. The build workflow currently produces both a glibc 2.35
(Ubuntu 22.04) and a glibc 2.39 (24.04) build, and `install_displace()` selects
between them, so a wrong guess is recoverable — but building only what is needed
halves the CI time.

## Deliberately not implemented

### A full case-study writer -- partly started, and instructive

**What was added:** `read_displace_table()` / `write_displace_table()` for the
header-plus-records format that most `*spe_` input files use, and
`read_displace_vessel_features()` / `write_displace_vessel_features()` for the
`|`-separated vessel file. Together these read all 575 `.dat` files in
`DISPLACE_input_minitest` and value-round-trip every one.

**And the important part: reading them all back in R proved nothing.** A writer
and its matching reader share their assumptions, so a wrong pair round-trips
perfectly. The test that actually settles it is to rewrite the inputs, run the
simulator on both trees, and compare -- and doing that revealed real corruption:

| Family rewritten | Simulator outputs changed? |
|---|---|
| `harboursspe_`, `benthosspe_`, `fishfarmsspe_`, `windmillsspe_` | no |
| `metiersspe_`, `popsspe_` | no, **once headerless files are refused** |
| `vesselsspe_`, `shipsspe_` | **yes -- not yet safe to write** |

Two causes, both now guarded against at read time rather than silently
propagated:

* **Not every file has a header.** `popsspe_*/0spe_initial_tac.dat` is a bare
  `10000`. Read with `header = TRUE` its only record became a column name and
  the round trip wrote the corruption back. Any all-numeric first line is now
  refused with a message naming `header = FALSE`.
* **Not every file is whitespace separated.** `shipsspe_features.dat` and
  `firms_specs.dat` use `|`; read as whitespace they gave one mangled column
  and no error. Now refused.

A third, subtler one: formatting numbers with a fixed digit count rewrote
`54.3473507` as `54.34735070`. Values equal, bytes different. Now fixed by
using R's shortest round-tripping representation.

**Still to do:** `vesselsspe_` and `shipsspe_` need per-file work before their
writers can be trusted. Use `check_displace_roundtrip()` to verify any writer
against your own case study before relying on it.

### A full case-study writer -- the remaining bulk

Appendix B of `CLAUDE.md` catalogues roughly 150 input files across
`popsspe_`, `vesselsspe_`, `metiersspe_`, `harboursspe_`, `benthosspe_`,
`shipsspe_` and `fishfarmsspe_`. Writing all of them is Phase 3's real bulk, and
it needs real data to validate against — an incorrect writer that produces
syntactically valid files is worse than no writer, because the simulator will
run and give wrong answers.

What exists instead:

- `create_displace_input()` — the folder skeleton, with the suffixing rule right
  (`graphsspe` is flat; everything else takes `_<name>`);
- `read/write_displace_config()` — `config.dat`;
- `read/write_displace_scenario()` — the scenario `.dat`;
- `read/write_displace_graph()`, `read_displace_code_area()` — the stacked
  triple;
- `validate_displace_input()` — the structural checks that abort loading.

The natural next step is to port the writers from
<https://github.com/frabas/DISPLACE_R_inputs>, whose README says they should
ideally become a package. Do that against the minitest dataset, one file family
at a time, each with a round-trip test.

### The `--indb` path — investigated, not yet trustworthy

This was the roadmap's biggest open question and it now has a partial answer.

`minitest` ships `baseline.db` and `areaclosure.db`: the whole case study in
**30 normalized SQLite tables**, replacing the ~150 text files. `Nodes` alone
subsumes `coord0.dat` and all fifteen `coord0_with_*.dat` files as ordinary
columns. As an R target this is dramatically better than the text zoo — one
`RSQLite` writer instead of 150 formatters.

The path runs: `--indb baseline.db` completes and produces the full output set.

**But it does not reproduce the text-input results.** Same dataset, scenario and
step count:

| Output table | `--indb` | text |
|---|---|---|
| `VesselVmsLike` | 27 | 73 |
| `VesselLogLike` | 1 | 2 |
| `PopValues` | 0 | 123 |
| `NodesEnvt` | 41 | 41 |

`PopValues` empty means population dynamics are not being recorded on the
database path at all. Until it is known whether the shipped `.db` is simply
stale relative to the text files, or `DatabaseModelLoader` is incomplete, this
cannot be recommended — and building a writer against it would be premature.

**Next step:** ask upstream how `baseline.db` is generated, and regenerate one
from the current text inputs to see whether the two paths then agree. If they
do, the database writer becomes the main input story and the 150 text writers
are never needed.

`run_displace(indb = ...)` passes the flag through and skips text-tree
validation when it is set, so the path is usable for experimentation today.

### Version-dispatched readers

The seam exists — `displace_output_spec()` takes a `db_version` — but there is
exactly one output schema version (4) in the wild, so there is nothing to
dispatch on. Adding a second layout should be a data change in `R/formats.R`,
not a rewrite.

### `displaceplot`

<https://github.com/frabas/displaceplot> already reads the text outputs and
plots them. This package does not depend on it or duplicate its plotting.
Whether the two should be joined up is worth a conversation with the maintainer
rather than a unilateral decision here.

## DISPLACE is not reproducible

Worth knowing before designing any regression test or publishing any result.
Given **identical inputs, an identical `sim_name` and an identical step count**,
about a third of DISPLACE's text outputs differ between two runs -- 13 of 39 on
a 2000-step minitest run. `SimModel::initRandom(namesimu)` does not fully
determinise it.

Consequences:

* Golden-file comparison has to establish which outputs are stable first, by
  running the reference twice, and compare only those.
  `check_displace_roundtrip()` does this.
* Replicates are genuinely stochastic even with a fixed name, so
  `run_displace_replicates()` gives variation whether or not you want it.
* A result cannot be reproduced exactly from the inputs alone. Cite the
  upstream commit and archive the output database.

Whether this is intentional (threaded vessel movement) or a seeding bug is
worth asking upstream.

## Open questions inherited from CLAUDE.md

- **`shortPaths_*` / `min_distance_*` caches.** Whether these must be
  pre-generated per case study, and how `-p` (use static paths) interacts with
  them. `create_displace_input()` makes the directories but leaves them empty.
  This blocks any complete writer.
- **`DISABLE_IPC` link failure.** Worth filing upstream; the build script works
  around it by leaving IPC enabled (it is inert without `--use-gui`).
- **`find_package(GDAL)` outside the `WITHOUT_GUI` guard.** A one-line upstream
  PR would drop `libgdal-dev` from the build dependencies entirely.
- **Ask the maintainer (frabas) whether he would publish headless Linux
  binaries in official releases.** That would delete Phase 1 outright and is by
  far the highest-leverage item on this list.
