# displaceR

Run the [DISPLACE](https://displace-project.org/) individual-based fisheries
simulator from R, on a Linux server, **without a compiler, CMake, or root
access on that server**.

```r
remotes::install_github("pcarbomestre/displaceR")
```

## Why this exists

DISPLACE is a CMake application: a `main()`, file-based I/O, shared libraries,
and a Qt GUI bolted alongside a headless simulator. It is not a library with a
bindable API, so there is nothing to wrap with Rcpp — doing so would mean
rewriting the simulator. And building it on the target machine needs Boost,
GeographicLib, sqlite3, and a source build of msqlitecpp, which is exactly what
a locked-down analysis server does not have.

The way out is the one `r4ss` and `cmdstanr` already take: keep the R package
free of compiled code, build the backend somewhere else, and install it into a
user directory at runtime.

## Architecture

Three layers, deliberately separate:

| Layer | Where | What it does |
|---|---|---|
| **1. Upstream DISPLACE** | `frabas/DISPLACE_GUI` | Never forked, never vendored. Referenced by commit SHA. |
| **2. Build pipeline** | `.github/workflows/build-displace.yml` | Builds the headless simulator from a pinned ref, publishes a relocatable tarball as a release asset. |
| **3. R package** | `R/` | No C++, no `src/`. Downloads the binary, writes inputs, runs it, reads outputs. |

A new upstream version means re-running layer 2 and adding a manifest entry —
not editing layer 3. That separation is the whole design.

## Usage

### Check the machine first

```r
library(displaceR)
displace_doctor()
```

```
displaceR environment check

  [OK  ] platform          Linux x86_64
  [    ] glibc             2.39. A binary must be built against this version or older.
  [OK  ] cache directory   /home/you/.cache/R/displaceR
  [OK  ] simulator         /home/you/.cache/R/displaceR/1.6.6-7f2656fb7cd4-local/displace
  [OK  ] shared libraries  all resolved
  [OK  ] simulator runs    This is displace, version 1.6.6 build 0
  [OK  ] package RSQLite   installed

Ready to run.
```

This is the first thing to run on a new server, and the first thing to run when
something fails for an unclear reason. It never installs or changes anything.

### Install the simulator

Once per machine, or once per shared cache directory:

```r
install_displace()      # downloads, verifies sha256, unpacks, chmod +x
displace_version()      # reports the binary AND the upstream commit it came from
```

`install_displace()` writes to `tools::R_user_dir("displaceR", "cache")`. Point
`DISPLACER_CACHE` somewhere shared if several users on a server should share one
copy.

**No release published yet?** Until the build workflow has run, there is nothing
to download. Two routes work today:

```r
# 1. Build once anywhere with a compiler, copy the tarball to the server:
#      ./tools/build-displace.sh --ref 7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de
install_displace(from = "displace-7f2656fb7cd4-linux-x86_64.tar.gz")

# 2. Or point straight at a build you already have:
Sys.setenv(DISPLACE_BINARY = "/opt/displace/displace")
```

Route 1 is also the answer for a server with no outbound network access. The
tarball carries a `build-info.json`, so `displace_version()` can still report
which upstream commit the binary came from.

### Run a simulation

```r
res <- run_displace(
  input_dir  = "/data/DISPLACE_input_minitest",
  input_name = "fake",          # the suffix on the *spe_<name> folders
  scenario   = "baseline",      # simusspe_fake/baseline.dat
  sim_name   = "sim1",
  steps      = 8762             # ~1 year of hourly steps; max 52586 (~6 years)
)

res
#> <displace_run>
#>   input:    /data/DISPLACE_input_minitest (-f fake)
#>   scenario: baseline   simulation: sim1
#>   steps:    8762 (~1.00 years)
#>   outputs:  /tmp/.../DISPLACE_outputs/fake/baseline
#>   status:   139 (completed; crashed in teardown)   elapsed: 142.3s
```

Watch the `input_name`: it is the suffix on the `*spe_<name>` folders, **not**
the folder name. In the demo dataset those folders are `simusspe_fake/`,
`vesselsspe_fake/` and so on, so the name is `fake` even though the directory is
called `DISPLACE_input_minitest`.

`run_displace()` validates the input folder first, creates the output tree
(the simulator is not consistently defensive about missing paths), always passes
`--disable-crash-handler`, and refuses `--use-gui`.

### Read the outputs

Prefer the SQLite database. It is typed, indexed, and carries a schema version
that a version-aware reader can dispatch on — none of which the text files do.

```r
displace_db_version(res)          # 4
displace_db_tables(res)

catches <- read_displace_db(res, "VesselLogLikeCatches", where = "tstep < 5000")

# Aggregating in SQL beats pulling a table into R:
displace_db_query(res, "
  SELECT tstep, SUM(catches) AS total
  FROM VesselLogLikeCatches GROUP BY tstep ORDER BY tstep
")
```

The text outputs work too, but several layouts widen with the number of
populations, so they need the case study's `config.dat`:

```r
cfg <- read_displace_config("/data/DISPLACE_input_minitest", "fake")

displace_output_files(res)                      # what got written
popstats <- read_displace_output(res, "popstats")
loglike  <- read_displace_loglike(res, cfg)     # the economics file
```

### Replicates

```r
runs <- run_displace_replicates(
  n = 8,
  input_dir = "/data/DISPLACE_input_minitest",
  input_name = "fake",
  steps = 8762
)
```

DISPLACE seeds its RNG from the simulation name, so distinct `sim_name`s are
what makes replicates distinct. Note that DISPLACE already threads vessel
movement internally: if you parallelise replicates with `future`, the load is
the *product* of the two. `run_displace()` defaults `num_threads` to 1 for that
reason.

### Inputs

```r
create_displace_input("/data/mycase", "mycase")   # folder skeleton

write_displace_config(new_displace_config(nbpops = 3, nbmets = 12),
                      "/data/mycase", "mycase")
write_displace_scenario(new_displace_scenario(nrow_coord = 1000, nrow_graph = 4000),
                        "/data/mycase", "mycase")
write_displace_graph(g, "/data/mycase", a_graph = 1)

validate_displace_input("/data/mycase", "mycase")
```

**This is not a full case-study generator.** A complete `DISPLACE_input_xx` tree
is roughly 150 files. What is implemented here is the folder skeleton, the four
formats whose parsers have been read line by line (`config.dat`, the scenario
`.dat`, and the stacked graph triple), and a validator that catches the failures
the loader actually throws on. See [`docs/roadmap.md`](docs/roadmap.md) for what
is missing and why.

## Three things about DISPLACE that will bite you

**Every run "fails".** With SQLite output enabled — the default, and the format
you want — DISPLACE segfaults during static destruction *after* the simulation
has finished and every file is written, so the process exits 139. `run_displace()`
verifies from the output database that the run actually reached its step horizon
before forgiving that, and errors normally on a real mid-run crash. You will see
a warning; the results are fine. Details in
[`docs/upstream-issues.md`](docs/upstream-issues.md).

**The `simusspe_` files are positional, not keyed.** `config.dat` and the
scenario `.dat` are read by a parser that keys on *line number* and ignores
everything else. The `#` lines look like comments but are not — inserting or
deleting a single line silently shifts every field after it, and the simulator
loads the shifted values without complaint. Use this package's readers and
writers rather than editing by hand.

**`--huge` defaults to on.** Upstream initialises `export_hugefiles` to `1`
while the flag's implicit value is `0`, so omitting `--huge` leaves the very
large exports enabled and a bare `--huge` disables them. `run_displace()` always
passes the flag explicitly so that `huge = FALSE` means what it says.

More of these are catalogued in Appendix C of [`CLAUDE.md`](CLAUDE.md).

## Building the simulator yourself

```bash
sudo apt-get install -y build-essential cmake git patchelf \
                        libboost-all-dev libgeographiclib-dev \
                        libgdal-dev libsqlite3-dev

./tools/build-displace.sh --ref 7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de
export DISPLACE_BINARY="$PWD/dist/payload/displace"
```

CI runs the same script, so the two cannot drift. Build on a host whose glibc is
**no newer** than the target server's: a binary built on Ubuntu 24.04 (glibc
2.39) will not start on 22.04 (2.35), though the reverse is fine.

Note that upstream does **not** compile unpatched at this commit — the CMake
files pin C++14 while the sources need C++17, and msqlitecpp's exported CMake
target omits its own include directory. `build-displace.sh` fixes both at build
time, conditionally, so each becomes a no-op once upstream fixes it. Neither is
a fork: the patches are applied to a checkout of the pinned ref and never
committed. See [`docs/upstream-issues.md`](docs/upstream-issues.md).

## Status

The R package is complete and tested; the simulator binary is not yet published
as a release, so `install_displace()` needs `from =` or `DISPLACE_BINARY` for
now. See [`docs/needs-you.md`](docs/needs-you.md) for what is outstanding and
[`docs/roadmap.md`](docs/roadmap.md) for the known gaps.

## Licensing

GPL-2, matching upstream. Distributing DISPLACE binaries means shipping the
corresponding source, which here is the upstream commit SHA in
`inst/manifest.json` plus `tools/build-displace.sh` at the commit that built it.
Both go into every release's notes. See [`LICENSE.note`](LICENSE.note).

DISPLACE is developed by Francois Bastardie (DTU Aqua) and contributors. Cite
the upstream publications when publishing results.
