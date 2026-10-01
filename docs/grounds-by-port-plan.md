# Plan: port-tagged fishing grounds and A -> B -> B trips (`grounds_by_port`)

Branch `displace-grounds-by-port`, created 2026-10-01 from `main` at `be83281`.
Progress, commands and results: [grounds-by-port-log.md](grounds-by-port-log.md).

## Goal

The West Coast effort layers are per vessel x metier x landing port, but
DISPLACE 1.8.0 keeps one list of grounds per vessel (labelled by metier only)
and a separate list of ports. A trip therefore runs A (current port) -> any
ground of the vessel -> a port drawn from `freq_harbours`. The goal is a new
scenario option under which each ground entry carries its port, and a trip runs
A -> grounds of trip port B -> B. Without the option the simulator must behave
exactly as unpatched v1.8.0.

## Where the patch lives (decision)

- Upstream is read-only (CLAUDE.md), and the R package carries no C++, so the
  DISPLACE source is **not vendored** into the branch. The change is one
  unified diff, `tools/patches/grounds-by-port.patch`, against tag `v1.8.0`
  (`96eadecb1980d6f9ad22571cd6f963cc05379815`).
- `tools/build-displace.sh` gains `--patch grounds-by-port`, which applies it
  to the throwaway checkout before the existing build-time patches and records
  it in `build-info.json` (`feature_patches`). Without `--patch` the script is
  unchanged, so released builds stay pure upstream.
- The patch is opt-in and **fails loudly** if it does not apply (unlike the
  self-disabling compatibility patches): someone who asked for it must not
  silently get an unpatched binary.
- Source copy, build trees, payloads, test applications and run outputs all go
  in `scratch/` (already in `.gitignore`).

## C++ design (against v1.8.0)

New `dyn_alloc_sce` option **`grounds_by_port`** (`include/options.h`,
`commons/options.cpp`; appended before `Dyn_Alloc_last` so no existing enum
value moves). Unknown option names are ignored by DISPLACE's parser, so an
unpatched binary reads the same scenario file and runs baseline.

1. **Input** `vesselsspe_<app>/<vid>_fgrounds_harbours_quarter<N>.dat`,
   header + rows `pt_graph metier harbour weight` (spec in
   [grounds-by-port-spec.md](grounds-by-port-spec.md)). Read in
   `commons/TextImpl/LoadVesselsImpl.cpp` (`loadLocalData`, only when the
   option is on) and attached to the Vessel in `loadVessels` and
   `reloadVessels` (every quarter). Entries are validated against the vessel's
   `fgrounds` of that quarter, the metier count and the graph's harbour flags;
   invalid rows are dropped with a message. A missing or empty file means that
   vessel keeps baseline behaviour for that quarter.
2. **Vessel** (`include/Vessel.h`, `commons/Vessel.cpp`): stores the entries
   (node, metier, harbour, weight normalised within port) and the port shares,
   plus `trip_port` (initially -1).
3. **Trip port and metier** — `which_metier_should_i_go_for`: draw one entry
   from all of the vessel's entries with probability proportional to its share
   of the vessel's total weight (closed entries x 1e-8, as upstream does for
   grounds); `trip_port` = its port, metier = its metier. This equals "draw P by
   port share, then an entry within P".
4. **Ground** — `choose_a_ground_and_go_fishing`: draw among P's entries only,
   weights = normalised weight, x 1e-8 for entries closed under
   `area_monthly_closure` once the month's open days for the entry's metier are
   used (same days rule as upstream), restricted to the current metier under
   `aSingleMetierPerTrip`; `PickUpTheMostFrequentGroundEachTime` takes the
   heaviest entry. The trip metier is the drawn entry's metier (the upstream
   re-draw from `possible_metiers` is skipped, since it could pick a metier
   from another port's layer). All open probabilities < 1e-5 -> stay in port,
   as upstream.
5. **Change of ground** — `choose_another_ground_and_go_fishing`: candidate
   grounds are P's entry nodes; the upstream distance/closure logic is kept; the
   metier on the new ground is drawn among P's entries at that node.
6. **Return** — `choose_a_port_and_then_return`: destination = `trip_port`
   (overrides `freq_harbours` and `closer_port`). The vessel lands at P and its
   next trip starts there.
7. **Logbook** — `loglike_*.dat` gets one extra last column `trip_port`
   (node index; -1 if the vessel used the baseline draw) only when the option is
   on, so baseline outputs stay byte-identical. SQLite `VesselLogLike` is not
   changed (its landing node column already equals P under the option).
8. Not combined (documented, warned once at load): ChooseGround / ChoosePort
   dtrees and the frequency-reshaping options `focus_on_high_previous_cpue`,
   `focus_on_high_profit_grounds`, `fuelprice_plus20percent`, `closer_grounds`,
   `closer_port` are bypassed for vessels with port-tagged entries.
   Untouched: GoFishing dtree, metiers, selectivity, catch equation, economics.
   The `--indb` SQLite input loader is unfinished upstream and does not load the
   new file; vessels loaded that way keep baseline behaviour.

## R side

- `read_displace_loglike()` recognises the extra `trip_port` column.
- `read_displace_fgrounds_harbours()` / `write_displace_fgrounds_harbours()`:
  reference reader/writer of the new input file.
- `check_grounds_by_port()`: the check-3 assertions on a run (ground in trip
  port's entries, landing == trip port, next departure == previous landing,
  shares vs weights).
- `displace_features()`: reports the build's feature patches from
  `build-info.json`, so code can require `grounds_by_port`.
- Test-only builder `make_grounds_by_port_app()` (tests helper) that turns the
  public `DISPLACE_input_minitest` into a small multi-port synthetic
  application; the integration tests skip when the patched binary or the
  minitest dataset is not available. No confidential data in tracked files.

## Checks

1. Build on macOS arm64 with the release options (`tools/build-displace.sh`).
2. Baseline equivalence: copy of `westcoast_validation_1.0` in `scratch/`,
   short horizon, same seed, unpatched vs patched binary, diff loglike / popdyn
   and the other text outputs.
3. Option on, synthetic multi-port application: the five properties in the
   task, including a closure scenario.
4. R tests (`devtools::test()`), synthetic only.

## Steps

1. Plan + log files; unpatched v1.8.0 reference build (done first, in the
   background).
2. C++ patch in `scratch/DISPLACE_GUI-v1.8.0`, export to
   `tools/patches/grounds-by-port.patch`; `--patch` in the build script.
3. Patched build (check 1).
4. Check 2 on validation_1.0 copy.
5. Spec document; R functions; synthetic builder; check 3; R tests (check 4).
6. Handover document + summary.
