# Roadmap and known gaps

Status of the plan in `CLAUDE.md`, as built.

| Phase | Status |
|---|---|
| 0 — Verified build recipe | Complete (upstream). Captured in `tools/build-displace.sh`. |
| 1 — Build pipeline | Implemented, **never executed**. Needs one green manual run. |
| 2 — Binary distribution | Implemented. Manifest is empty until Phase 1 runs. |
| 3 — R I/O layer | Runner and readers complete. Writers cover 4 of ~150 input formats. |
| 4 — Tracking upstream | Watcher and golden-file harness implemented; the harness has never had a real dataset to run against. |

## Blocking, in order

### 1. Run the build workflow once

Nothing downstream is real until this happens. Run **Build DISPLACE binary**
with `upstream_ref: 7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de` and no
`release_tag`, and read the step summary. When it is green, re-run with a
`release_tag` and paste the manifest entry into `inst/manifest.json`.

Everything in the workflow is transcribed from a recipe that has been verified
by hand (see CLAUDE.md Phase 0), but the workflow itself has not run. Expect to
iterate on it once.

### 2. Get the minitest dataset

`DISPLACE_input_minitest` is the fixture the golden-file test needs, and it was
not available offline while this package was written. That means:

- `validate_displace_input()` has never been run against a real case study;
- the text output layouts in `R/formats.R` are transcribed from
  `docs/output_fileformats.md`, not verified against real files;
- the stacked-column graph readers are verified against the *parsers* but not
  against real data.

Download from <https://displace-project.org/blog/download/>, unpack, and:

```r
Sys.setenv(DISPLACE_MINITEST_DIR = "/data/DISPLACE_input_minitest")
testthat::test_local(".")     # test-golden.R stops skipping
```

The golden test does the round trip that matters: read a real case study with
our readers, write it back with our writers, re-read, and compare. A one-line
offset shared by a reader and its writer survives a synthetic round trip but not
that one.

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

### A full case-study writer

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

### The `--indb` path

`CLAUDE.md` flags SQLite input (`DatabaseModelLoader`, `commons/DatabaseInputImpl/`)
as likely a better R interface than emitting the text-file zoo, and it probably
is. `run_displace(indb = ...)` passes the flag through, but nothing in this
package *builds* such a database. Worth investigating before writing 150 text
writers: if the schema is stable, one `RSQLite` writer replaces all of them.

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
