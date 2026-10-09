# Handover: `grounds_by_port` DISPLACE patch, for the West Coast analysis repo

State on 2026-10-01. Details: [plan](grounds-by-port-plan.md),
[file spec](grounds-by-port-spec.md), [progress log with all check outputs](grounds-by-port-log.md).

## What exists

| Item | Value |
|---|---|
| displaceR branch | `displace-grounds-by-port` (local only, not pushed) |
| DISPLACE base | tag `v1.8.0` = `96eadecb1980d6f9ad22571cd6f963cc05379815` (frabas/DISPLACE_GUI, read-only) |
| Patch | `tools/patches/grounds-by-port.patch` (8 files, +366/-3), applied at build time; DISPLACE source is not vendored |
| Scenario option | `grounds_by_port` in `dyn_alloc_sce` |
| New input | `vesselsspe_<app>/<vid>_fgrounds_harbours_quarter<N>.dat`: header + `pt_graph metier harbour weight`, 0-based nodes and metiers, one file per vessel and quarter ([spec](grounds-by-port-spec.md#2-input-file-vid_fgrounds_harbours_quarterndat)) |
| New loglike columns | appended after `numTrips`, only with the option: `trip_port` (node of the port whose grounds the trip fished, `-1` = baseline draws) and `dep_port` (node the trip left from) |

## Build and run from displaceR

```sh
# in the displaceR checkout, branch displace-grounds-by-port (macOS or Linux,
# same build deps as the released binary)
tools/build-displace.sh --ref v1.8.0 --patch grounds-by-port --patch headless-ipc-lazy \
    --workdir scratch/build-patched --outdir scratch/dist-gbp
```

```r
# install the payload into displaceR's cache (label 1.8.0-96eadecb1980-grounds-by-port-local)
displaceR::install_displace(from = "scratch/dist-gbp/payload")   # or point at it directly:
bin <- "scratch/dist-gbp/payload/displace"
displaceR::displace_features(bin)          # "grounds-by-port" "headless-ipc-lazy"

res <- displaceR::run_displace(input_dir, "westcoast_xxx", scenario = "baseline_gbp",
                               binary = bin, steps = 8762, sqlite = FALSE,
                               huge = TRUE, export_vmslike = 10)
cfg <- displaceR::read_displace_config(input_dir, "westcoast_xxx")
ll  <- displaceR::read_displace_loglike(res, cfg)      # has trip_port, dep_port
chk <- displaceR::check_grounds_by_port(res)           # the check-3 assertions on a real run
```

`install_displace(from = ...)` is the existing local-install path; it was not
exercised here because it writes to the user cache, outside the repository
(the label logic is unit-tested). `run_displace()` refuses a
`grounds_by_port` scenario on a binary without the patch (an unpatched
simulator would silently run baseline). Reference writer for the new file:
`write_displace_fgrounds_harbours()`; reader with derived probabilities:
`read_displace_fgrounds_harbours()`.

`headless-ipc-lazy` is a second, independent patch: headless runs no longer
create the shared-memory object `OutQueue` (used only to talk to the desktop
GUI), which could make simultaneous starts abort with "File exists". It does
not change results (byte-identical outputs, see the log). Both are opt-in;
without `--patch` the script builds plain upstream.

For a Linux server build, run the same script on the Linux builder with both
`--patch` flags, or run the CI workflow with its `patches` input.

## Check results (all on macOS arm64)

1. Build with the release options: **pass** (same 8 compiler warnings as unpatched).
2. Option off vs unpatched v1.8.0 on a copy of validation_1.0: **pass where
   v1.8.0 is reproducible**. With validation's `diffusePopN`, upstream itself
   differs run to run (seed from `std::random_device`, `commons/Population.cpp:30`);
   without it, all text outputs except `memstats` and all 18 SQLite tables are
   byte-identical (744 steps).
3. Option on, synthetic 3-port application (public minitest base, 2 years,
   ~2,350 trips per scenario): 0 failures for landing == trip port, next
   departure == previous landing, grounds and metiers within the trip port's
   entries; port shares match weights (chi2 p 0.16-0.91), metier shares match
   with ground changes off (p 0.30-0.71); closures: closed entries never
   fished, per metier.
4. displaceR tests (incl. 4 simulator-backed) and `R CMD check`: **pass**.

## Needs your decision / attention

1. **Reproducibility of the validation runs.** `diffusePopN` makes DISPLACE
   1.8.0 runs non-reproducible regardless of `-s`. For seed-to-seed comparisons
   between builds or scenarios this matters; fixing it would mean a second
   (one-line) build-time patch seeding that generator from the simulation seed
   -- which changes model results relative to released binaries. Not done.
2. **Port shares definition for routine 06/07.** DISPLACE uses the row sums of
   `weight` per port as port shares. If they should equal `RelativeEffort` per
   port instead of the layers' hour totals, scale rows as in the spec
   (`w = share_P * fe / sum(fe over P)`).
3. **Per-port catch rates** cannot live in the new file: gshape/gscale per node
   are shared by all ports' entries on a node (spec, "Consistency").
4. **Realised shares vs GoFishing.** Departures happen when GoFishing says yes
   for the drawn metier, so classes with higher GoFishing probability are
   over-represented relative to the weights -- as in baseline DISPLACE. Relevant
   when comparing simulated port/metier shares to observed ones.
5. **Not supported with the option** (warning at load): `closer_grounds`,
   `closer_port`, `focus_on_high_previous_cpue`, `focus_on_high_profit_grounds`,
   `fuelprice_plus20percent`, `shared_harbour_knowledge`, ChooseGround dtree;
   `--indb` input. None is used by validation_1.0.
6. **Parallel runs.** Plain DISPLACE builds can abort when several start at
   the same moment (shared object `OutQueue`, "File exists"); builds with
   `headless-ipc-lazy` cannot. With SQLite on, text outputs can lose their
   last buffer at the teardown crash; use `sqlite = FALSE` when text files are
   the product.
7. Nothing was pushed, no PR, nothing filed upstream. The branch has local
   commits only.
