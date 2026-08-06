# displaceR

> ### This is not the DISPLACE model
>
> **DISPLACE** is developed by **[Francois Bastardie](https://orbit.dtu.dk/en/persons/fran%C3%A7ois-bastardie)
> and colleagues at DTU Aqua** — the model, the science, and the decades of
> work behind it are entirely theirs:
> **<https://github.com/frabas/DISPLACE_GUI>** · **<https://displace-project.org/>**
>
> `displaceR` is a **third-party R wrapper**, not affiliated with or endorsed by
> the DISPLACE project. It contains **no model code** and implements **no model
> behaviour**. It installs the simulator, writes its input files, runs it, and
> reads its outputs — nothing more. Every number it produces comes from
> DISPLACE.
>
> **If you publish results, cite the DISPLACE papers, not this package**
> (see [Citing](#citing)). Questions about the *model* belong with the DISPLACE
> project; only problems with *this R interface* belong in this repository's
> issues.

Run the [DISPLACE](https://displace-project.org/) individual-based fisheries
simulator from R — on **Linux, macOS or Windows** — **without a compiler,
CMake, or root access on the machine you run it from**.

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

This is the first thing to run on a new machine, and the first thing to run when
something fails for an unclear reason. It never installs or changes anything.

Off Linux the platform line is a note rather than a failure: DISPLACE runs on
macOS and Windows perfectly well, it is only `install_displace()`'s download
that is Linux-only.

```
  [    ] platform          Windows (x86-64). DISPLACE runs here, but
                           install_displace() only publishes Linux builds --
                           install upstream's Windows installer and point
                           DISPLACE_BINARY at the simulator.
```

### Install the simulator

On **Linux (x86_64)** and **macOS (Apple Silicon)**, once per machine or per
shared cache directory:

```r
install_displace()      # downloads, verifies sha256, unpacks, chmod +x
displace_version()      # reports the binary AND the upstream commit it came from
```

`install_displace()` picks the right build for your platform: Linux builds are
selected by glibc version, macOS and Windows by architecture.

**Other platforms** — Windows, Intel Macs, non-x86_64 Linux — have no prebuilt
binary yet. Two routes work:

```r
# 1. Use a DISPLACE you already have (e.g. upstream's Windows installer).
#    Point at the headless `displace` executable, not the GUI application:
Sys.setenv(DISPLACE_BINARY = "C:/Program Files/DISPLACE/displace.exe")

# 2. Or build one:  ./tools/build-displace.sh --ref <upstream-sha>
install_displace(from = "displace-<sha>-<platform>.tar.gz")
```

`displace_doctor()` reports which of these applies on your machine.

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
you want — DISPLACE crashes during static destruction *after* the simulation has
finished and every file is written, exiting 139 or 134 (the signal varies
between otherwise identical runs). `run_displace()`
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

The R package is complete and tested. No Linux binary is published as a release
yet, so on Linux `install_displace()` needs `from =` or `DISPLACE_BINARY`; on
Windows and macOS, install upstream's package and set `DISPLACE_BINARY`.

**Verified where:** the R layer's readers, writers and runner were exercised
against a real DISPLACE run on Linux. The platform handling described above is
tested, but no DISPLACE run has yet been driven from R on Windows or macOS —
if you do that, `displace_doctor()` is the place to start and a surprise there
is worth reporting.

See [`docs/needs-you.md`](docs/needs-you.md) for what is outstanding and
[`docs/roadmap.md`](docs/roadmap.md) for the known gaps.

## Citing

**Cite DISPLACE, not `displaceR`.** The model did the work; this package only
started the process and parsed the output. In R:

```r
citation("displaceR")     # returns the DISPLACE papers
```

The primary reference:

> Bastardie F, Nielsen JR, Miethe T (2014). DISPLACE: a dynamic,
> individual-based model for spatial fishing planning and effort displacement —
> integrating underlying fish population models. *Canadian Journal of Fisheries
> and Aquatic Sciences* 71(3):366–386.
> [doi:10.1139/cjfas-2013-0126](https://doi.org/10.1139/cjfas-2013-0126)

Further DISPLACE publications:

> Bastardie F, Nielsen JR, Eigaard OR, Fock HO, Jonsson P, Bartolino V (2015).
> Competition for marine space: modelling the Baltic Sea fisheries and effort
> displacement under spatial restrictions. *ICES Journal of Marine Science*
> 72(3):824–840. [doi:10.1093/icesjms/fsu215](https://doi.org/10.1093/icesjms/fsu215)

> Bastardie F, Nielsen JR, Eero M, Fuga F, Rindorf A (2017). Effects of changes
> in stock productivity and mixing on sustainable fishing and economic
> viability. *ICES Journal of Marine Science* 74(2):535–551.
> [doi:10.1093/icesjms/fsw083](https://doi.org/10.1093/icesjms/fsw083)

> Bastardie F, Angelini S, Bolognini L, Fuga F, Manfredi C, Martinelli M,
> Nielsen JR, Santojanni A, Scarcella G, Grati F (2017). Spatial planning for
> fisheries in the Northern Adriatic: working toward viable and sustainable
> fishing. *Ecosphere* 8(2):e01696.
> [doi:10.1002/ecs2.1696](https://doi.org/10.1002/ecs2.1696)

If it helps reproducibility to record how you ran the model, name the interface
in your methods text — along with the exact upstream commit, which
`displace_version()` reports — rather than adding this package to your
reference list.

## Credit and scope

| | |
|---|---|
| **The DISPLACE model** | Francois Bastardie and colleagues, DTU Aqua. Copyright © 2012–2026 Francois Bastardie. All model code, science and validation. |
| **This package** | An unaffiliated R interface. No model code, no model behaviour, no scientific contribution. |

Related work by the DISPLACE authors, which this package deliberately does not
duplicate:

- [`frabas/DISPLACE_GUI`](https://github.com/frabas/DISPLACE_GUI) — the model itself
- [`frabas/DISPLACE_R_inputs`](https://github.com/frabas/DISPLACE_R_inputs) — R routines for building case studies
- [`frabas/displaceplot`](https://github.com/frabas/displaceplot) — R package for reading and plotting outputs
- [`frabas/DISPLACE_input_minitest`](https://github.com/frabas/DISPLACE_input_minitest) — the minimal demo dataset

Upstream is treated as strictly read-only: this project never modifies it and
never files against it. Where the build needs a fix, it is applied to a
throwaway checkout at build time and never committed anywhere.

## Licensing

GPL-2, matching upstream. Distributing DISPLACE binaries means shipping the
corresponding source, which here is the upstream commit SHA in
`inst/manifest.json` plus `tools/build-displace.sh` at the commit that built it.
Both go into every release's notes. See [`LICENSE.note`](LICENSE.note).
