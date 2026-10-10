# timestep-accounting: the hourly step as a time budget

Feature patch `tools/patches/timestep-accounting.patch` (exploration branch
`timestep-accounting`, local only). Written against v1.8.0 **after** the eight
westcoast patches (it shares context lines in `include/options.h`,
`commons/options.cpp`, `commons/Vessel.cpp` and `simulator/outputexporter.*`
with `grounds-by-port`, `out-of-range-implicit` and `shortest-paths`), so it is
applied last:

```bash
tools/build-displace.sh --ref v1.8.0 \
  --patch grounds-by-port --patch headless-ipc-lazy --patch keep-unselected-othland \
  --patch out-of-range-implicit --patch astar-speedup --patch sample-table-cache \
  --patch shortest-paths --patch reproducible-diffusion --patch timestep-accounting ...
```

Two `dyn_alloc` options in the scenario file (`simusspe_<app>/<scenario>.dat`,
line after `# dyn_alloc_sce`):

| Option | Effect |
|---|---|
| `timestep_accounting` | steps 1 and 2 below |
| `partial_fishing` | step 3 below; only read together with `timestep_accounting` |

With neither option the binary runs the upstream code paths unchanged (the new
function is never called; the only edits on the shared path multiply by
`m_fishing_fraction`, which is exactly 1.0, so results are byte-identical; see
Verification).

## What upstream does (v1.8.0, `simulator/thread_vessels.cpp`, `commons/Vessel.cpp`)

One action per vessel per 1 h step (`manage_vessel()`):

- **Moving** (`find_next_point_on_the_graph_unlocked()`): the vessel travels
  `speed * 1 h` along its roadmap. On a step that ends the roadmap the vessel
  stops at the destination node and waits out the rest of the step. The time
  charged to `cumsteaming`/`timeatsea` is **not** what was covered: a roadmap of
  one node charges exactly 1 h (and the full hour's distance) however close the
  node is; a multi-node step that reaches the destination charges
  `(speed * 1 h + d_last) / speed`, more than an hour (`actual_distance_traveled`
  adds the last leg twice). A step that runs out mid-route because the next leg
  is longer than what is left (the `while` test compares against the previous
  leg) stops the vessel at the last node passed and still charges 1 h.
- **Deciding to stop fishing** (`choose_a_port_and_then_return()`): sets the
  roadmap but does not move, so that step neither fishes nor moves; the vmslike
  row keeps the previous state (1, fishing) with no catch and no time charged.
- **Changing ground** (`choose_another_ground_and_go_fishing()`): moves in the
  same step; if the new ground is reached within it the vessel also fishes a
  full hour in that step (a step that charges more than 1 h + 1 h).
- **Arriving in port**: the step that reaches port is a state-2 row; the trip
  is declared (logbook written, `reinit_after_a_trip()`) in the **next** step,
  which is another state-2 row at the port with no time charged. The logbook's
  `tstep` (arrival) is that declaring step.

So vmslike rows per trip = `arr - dep + 1` while `timeatsea` sums the charged
hours; the two disagree in both directions.

## Step 1: carry the leftover part of the step (option `timestep_accounting`)

`manage_vessel_timebudget()` (new, `thread_vessels.cpp`) replaces the action
part of `manage_vessel()` when the option is on; the export part is shared.
Each step starts with a budget of 1 h (+ the vessel's carry, below). Actions
are taken in a loop until the budget is spent:

- **move** (`Vessel::move_within()`, new): along the roadmap for at most the
  budget; passes nodes while the budget allows, then approaches the next node
  along the bearing to it. Charges exactly the distance covered and
  `covered / speed` hours to `cumsteaming`, `timeatsea`,
  `timeatseasincefirstcatch` (after the first catch), `traveled_dist_this_trip`,
  fuel (`fuelcons * hours * mult_when_steaming|returning * fuel_reduction`,
  i.e. upstream's multi-node formula; upstream's one-node branch applies the
  metier fuel multiplier twice, which this does not copy) and
  `consotogetthere`. If the roadmap is completed the loop continues with what
  is left.
- **in port, trip not declared** (just arrived): declare in this step (same
  calls as upstream), and the rest of the step is spent in port. The logbook's
  arrival tstep is the arrival step (one earlier than upstream), and port time
  starts one step earlier.
- **in port, declared**: the upstream departure decision (metier, go fishing,
  ground); `choose_a_ground_and_go_fishing()` sets the roadmap without moving
  (`Vessel::set_defer_move`) and the loop moves with the full hour.
- **on a ground**: the upstream decisions in the upstream order (stop fishing,
  mailbox, change ground). Stop: `choose_a_port_and_then_return()` and the loop
  moves home with what is left of the step (the stop decision no longer takes
  a step). Change: the roadmap is set without moving and the loop moves; if the
  new ground is reached within the step the vessel fishes there without new
  decisions (as upstream does). Otherwise: fish.
- **fish**: `do_catch()` and the upstream fishing bookkeeping for one hour.
  A fishing action needs a full hour of budget (upstream's catch is per hour);
  when less than an hour is left on a ground the rest is carried
  (`Vessel::set_time_carry`) to the next step, which then has 1 h + carry. The
  carry is spent by the next move and dropped when the trip ends
  (`reinit_after_a_trip`). This is how step 1 "starts fishing within the
  step": the vessel's work catches up with the calendar over the trip, so
  calendar hours at sea = work hours + the last carry (< 1 h).

Decisions use the same random draws as upstream but at different times, so
results differ from upstream once the option is on (as any behaviour change
does); the run is still reproducible for a given seed.

Safety: at most 50 actions per vessel and step.

## Step 2: segmented vmslike (same option)

Every action that takes time adds a segment (`Vessel::add_segment`: state,
hours, km, end x/y/course/cumulative fuel). With the option on, vmslike has one
row per segment, keeping the integer tstep, with 3 more columns:

`tstep vid tstep_dep x y course cumfuel state seg hours km`

A step at sea with no segment (vessel stuck without a path, or tstep 0) is one
row with `seg 1, hours 0, km 0`. With the option off the 8-column format is
unchanged. The SQLite vmslike and `vmslike_fpings_only` are not segmented
(off in the westcoast runs). Per-trip sums of `hours` by state equal the
logbook's `cumsteaming` (state 2) and `timeatsea - cumsteaming` (state 1), and
the sum of `km` equals `traveled_dist` (see Verification).

## Step 3: partial-hour fishing (option `partial_fishing`)

A fishing action takes `min(budget, 1 h)` instead of a full hour, so a step
can be 0.4 h steaming + 0.6 h fishing and there is no carry at sea. The catch
and its side effects scale with the fraction through `Vessel::m_fishing_fraction`
(1.0 otherwise), used in the 1.8.0 `do_catch()` path only:

- explicit stocks: `catchPotential` (the per-hour catch) times the fraction;
- implicit stocks (incl. out-of-range-implicit): `weight = cpue * fraction`;
- swept area (benthos), effort per node/metier/pop (`cumeffort_*`,
  `add_to_cumeffort_per_pop_per_met_this_month`) times the fraction;
- fishing fuel, `timeatsea`, `timeatseasincefirstcatch`, node `cumftime` add the
  fraction.

Not scaled: `do_catch_v150` (not used), the stop/change decisions (still taken
before each fishing action, so a short leftover is one more decision, as an
extra hour would be), and per-event outputs that count events rather than hours.

## Verification

westcoast calibration 7.47 inputs (copy), `baseline` scenario (`grounds_by_port
out_of_range_implicit shortest_paths`, `diffusePopN`), simu1, 26,305 steps (3
years), `-e13 --huge=1 --disable-sqlite`, 1 thread, sequoia (GRIT), builds with
conda-forge Boost 1.92 / GeographicLib (2026-10-10). Accounting with
`compare.R` (per trip, loglike matched to vmslike on vessel and tstep_dep;
totals for trips departing in years 1-3).

**Builds.** `8-patch` = this script with the eight westcoast patches;
`8-patch + timestep-accounting` = the same plus this patch.

**(a) 8-patch rebuild vs the calibration binary** (CI release
1.8.0-96eadecb-westcoast-repro): 37 of the 39 output files byte-identical,
including vmslike, loglike, popstats; `memstats` differs (expected) and
`popdyn_annual_indic` differs in one printed value (year 2 F of one stock,
0.0004 vs 0.0003, a 4th-decimal rounding flip).

**(b) patched build, options off vs the calibration binary**: 38 of 39 files
byte-identical (all but `memstats`), so the patch with the options off is the
8-patch model. (The rebuild in (a) and this run differ in that same single
`popdyn_annual_indic` value, so that flip is not caused by the patch.)

**(c) `timestep_accounting` on** (steps 1-2):

| years 1-3 | 8-patch | timestep_accounting | change |
|---|---|---|---|
| trips | 20,402 | 20,673 | +1.3% |
| vmslike rows at sea (state 1/2 steps) | 730,593 | 672,526 | -7.9% |
| vmslike fishing rows | 413,531 | 406,602 | -1.7% |
| vmslike steaming rows | 317,062 | 265,924 | -16.1% |
| segment hours fishing / steaming | - | 406,602 / 255,328 | |
| logbook timeatsea (h) | 696,343 | 661,312 | -5.0% |
| logbook fishing (timeatsea - cumsteaming) | 393,608 | 406,218 | +3.2% |
| logbook cumsteaming | 302,735 | 255,094 | -15.7% |
| logbook arr - dep (steps) | 709,231 | 651,229 | -8.2% |
| distance (traveled_dist, km) | 4,105,568 | 3,451,454 | -15.9% |
| fuel | 23,247,705 | 21,103,543 | -9.2% |
| catch (t, loglike pops 1-5) | 91,192 | 94,173 | +3.3% |
| mean trip (steps) | 34.8 | 31.5 | |
| run time | 5:03 | 5:05 | |

Per trip (mean [p5, p95]):

| | 8-patch | timestep_accounting |
|---|---|---|
| vmslike rows - (arr - dep) | 1.00 | 1.00 |
| steaming rows - cumsteaming | 0.69 [0.2, 1.4] | 0.51 [0.1, 1.0] |
| fishing rows - (timeatsea - cumsteaming) | 0.94 [0, 1] | 0.00 [0, 0] |
| rows at sea - timeatsea | 1.63 [1.2, 2.0] | 0.51 [0.1, 1.0] |
| segment steaming hours - cumsteaming | - | 0.00 [-0.04, 0.04] (loglike rounds to 0.1 h) |
| segment fishing hours - fishing | - | 0.00 |
| segment km - traveled_dist | - | 0.01 [-0.45, 0.45] (loglike rounds to 0.1 km) |

Reading: the stop step and the declaring step are gone (fishing rows = fishing
hours exactly; a trip has arr - dep + 1 rows where the last is the arrival
step). Summing segment hours reproduces the logbook exactly. Counting rows still
overstates time at sea by ~0.5 h per trip: the arrival step in port is a
partial hour, and the carry (vessel waiting less than a full fishing hour on a
ground, 0.5 h on average) is time the calendar spends that the logbook does
not. 19,001 of 672,526 steps hold more than 1 h of work (carry spent), 39,561
less (arrival steps); multi-segment steps are rare (232) because without
partial fishing a fishing action needs the whole hour.

The biggest effect is not the leftover itself but upstream's charging: it
charges a full hour (or more) on every step that reaches a destination, and
the same for distance, so upstream steaming time and distance are ~16% higher
than the movement the vessels actually make. Fuel follows (-9%). With less
time lost per trip, vessels fish ~3% more hours and catch ~3% more.
