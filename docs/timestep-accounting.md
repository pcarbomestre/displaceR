# timestep-accounting: the hourly step as a time budget

Feature patch `tools/patches/timestep-accounting.patch`: reviewed, review
fixes in, acceptance tests A-E passed (see Verification). Written against v1.8.0 **after** the eight
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
  is left. A node within 1e-6 km of what is left of the budget counts as
  reached (rounding of the budget otherwise left the vessel 1e-12 km short of
  it and arriving a step late); at speed 0 the vessel does not move (0 h, no
  0/0).
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
  decisions (as upstream does). That flag is kept on the vessel
  (`Vessel::get_fish_without_deciding`, cleared when used and in
  `reinit_after_a_trip`), so it still holds when the step runs out between
  reaching the ground and fishing. Otherwise: fish.
- **fish**: `do_catch()` and the upstream fishing bookkeeping for one hour.
  A fishing action needs a full hour of budget (upstream's catch is per hour);
  when less than an hour is left on a ground the rest is carried
  (`Vessel::set_time_carry`) to the next step, which then has 1 h + carry. The
  carry is spent by the next move and dropped when the trip ends
  (`reinit_after_a_trip`). Only this break carries: what is left when the
  loop ends any other way (in port, no path home, inactive quarter, action
  limit) is dropped, and the carry is capped below 1 h, so it cannot grow
  from step to step. This is how step 1 "starts fishing within the
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
row with `seg 1, hours 0, km 0`. `read_displace_output(x, "vmslike")` recognises
the 11-column layout by its width and names the extra columns. With the option off the 8-column format is
unchanged. The SQLite vmslike and `vmslike_fpings_only` are not segmented
(off in the westcoast runs). Per-trip sums of `hours` by state equal the
logbook's `cumsteaming` (state 2) and `timeatsea - cumsteaming` (state 1), and
the sum of `km` equals `traveled_dist` (see Verification).

## Step 3: partial-hour fishing (option `partial_fishing`)

A fishing action takes `min(budget, 1 h)` instead of a full hour, so a step
can be 0.4 h steaming + 0.6 h fishing and there is no carry at sea. The
shortest fishing action is 0.05 h: a rest of the step on a ground shorter
than that (e.g. a ground reached 0.01 h before the end of the step) is dropped
(the vessel waits: no catch, no decision, no time charged), because a fishing
action of any length runs the whole `do_catch()` (random draws per implicit
stock, tariffs, metier-used and bycatch bookkeeping). Not carried, so no step
holds more than 1 h. The catch
and its side effects scale with the fraction through `Vessel::m_fishing_fraction`
(1.0 otherwise), used in the 1.8.0 `do_catch()` path only:

- explicit stocks: `catchPotential` (the per-hour catch) times the fraction;
- implicit stocks (incl. out-of-range-implicit): `weight = cpue * fraction`;
- swept area (benthos; trawl and static gear), effort per node/metier/pop
  (`cumeffort_*`, `add_to_cumeffort_per_pop_per_met_this_month`) times the
  fraction;
- fishing fuel, `timeatsea`, `timeatseasincefirstcatch`, node `cumftime` add the
  fraction. `Node::cumftime` is a double (it was an `int`, which truncated
  every fraction: in the first version `popnodes_cumftime` was 2.2% below the
  vmslike fishing hours over 13 years); `popnodes_cumftime` prints whole hours
  as before (byte-identical with the options off) and fractions with the
  file's 8 decimals, and the tariff/effort updates in `fisheriesmanagmt.cpp`
  read the exact value.

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
| segment km - traveled_dist | - | 0.01 [-0.45, 0.45] (loglike prints `traveled_dist` in whole km) |

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

**Upstream overcharge, checked from positions.** Straight-line distance between
consecutive vmslike positions of each trip vs the logged `traveled_dist`
(`vms_track.R` in the work folder; the straight line understates the path and
misses the first hour, so only the ratio between runs means something):
8-patch 3.13 Mkm of track for 4.11 Mkm logged (0.763); timestep_accounting
3.06 Mkm for 3.45 Mkm (0.885); partial_fishing 3.03 / 3.42 (0.887). The
vessels move about as much in all runs; upstream logs ~16% more distance (and
steaming time) than it moves.

**(d) `timestep_accounting` + `partial_fishing`** (step 3), two seeds:

| years 1-3 | 8-patch simu1 | partial simu1 | 8-patch simu2 | partial simu2 |
|---|---|---|---|---|
| trips | 20,402 | 20,433 | 20,608 | 20,581 |
| vmslike rows at sea | 730,593 | 661,238 | 733,575 | 676,097 |
| vmslike fishing / steaming rows | 413,531 / 317,062 | 408,694 / 252,544 | 415,324 / 318,251 | 421,344 / 254,753 |
| segment hours fishing / steaming | - | 398,801 / 252,338 | - | 411,402 / 254,516 |
| logbook timeatsea | 696,343 | 649,785 | 698,104 | 664,973 |
| logbook fishing / cumsteaming | 393,608 / 302,735 | 397,808 / 251,977 | 394,503 / 303,600 | 410,669 / 254,304 |
| distance (km) | 4,105,568 | 3,418,696 | 4,118,690 | 3,437,522 |
| fuel | 23,247,705 | 20,668,001 | 23,216,649 | 20,883,830 |
| catch (t) | 91,192 | 92,156 | 92,877 | 93,556 |
| catch per fishing hour (kg) | 231.7 | 231.7 | 235.4 | 227.8 |
| mean trip (steps) | 34.8 | 31.3 | 34.5 | 31.8 |
| run time | 5:03 | 5:11 | 4:51 | 5:07 |

Per trip (simu1; simu2 the same to 0.01): rows - (arr - dep) 1.00; segment
steaming hours - cumsteaming 0.00 [-0.05, 0.04]; segment fishing hours -
fishing 0.00 [-0.07, 0.07]; segment km - traveled_dist 0.01 [-0.44, 0.45];
rows at sea - timeatsea 0.50 [0.1, 0.9]. No step holds more than 1 h; 20,430
steps hold less (one per trip: the arrival in port, the rest of that hour is
spent in port). 20,642 steps have 2 segments and 158 have 3 (arrive and fish,
fish and head home).

Reading: with partial fishing the carry is gone and the only difference
between counting rows and the logbook is the arrival hour (0.5 h per trip on
average), which is real port time and could be dropped by counting segment
hours instead of rows. Trips per year are unchanged (within seed noise:
-0.1% and +0.2% vs 8-patch, the seeds differ by 1%), fishing hours +1.1% and
+4.1%, catch +1.1% and +0.7%, catch per fishing hour unchanged within noise,
steaming time and distance -17%, fuel -10%, time at sea -5 to -7%, trips 3 h
(9%) shorter in calendar time. Run time +2-5%.

## Fix round (review findings) and 13-year acceptance tests

Fixes (each a minimal change in the patch; see `git log -- tools/patches/timestep-accounting.patch`):

1. `Node::cumftime` is a double (was `int`: every partial-fishing fraction was
   truncated; the first version's `popnodes_cumftime` was 2.19% below the
   vmslike fishing hours over 13 years). Whole hours print as before.
2. The carry is set only by the "less than a full fishing hour left on a
   ground" break and capped below 1 h; any other leftover is dropped (it grew
   without bound for a vessel stuck at sea).
3. `partial_fishing`: shortest fishing action 0.05 h; a shorter rest on a
   ground is dropped (the first version had 4,191 fishing segments < 0.05 h in
   13 years of seed 1, down to 0.0001 h, each a full `do_catch()`). Static-gear
   swept area scaled by the fraction.
4. `move_within()` reaches a node within 1e-6 km of the budget.
5. `fish_without_deciding` is a vessel member (kept across steps, cleared in
   `reinit_after_a_trip`).
6. `move_within()` returns 0 h at speed <= 0.

Binary `dist-fix` (the 8 patches + this one), westcoast 7.47 inputs copy,
`baseline` scenario, 13 years = 113,952 steps (3 years = 26,305), seeds 1-3,
`-e13 --huge=1 --disable-sqlite`, 1 thread, sequoia. Scripts in the work
folder (`cmp_fix.sh`, `accounting_check.R`, `edge_cases.R`,
`closure_check.R`, `long_compare.R`, `catch_explain.R`, `stop_rows.R`).

| Test | Result | Numbers |
|---|---|---|
| A options off vs calibration binary (7.47L 13 y, 7.47 3 y; seeds 1-3) | PASS | each of the 6 runs: 37 of 39 files byte-identical; `memstats` differs; `popdyn_annual_indic` identical once its Fbar columns (5-6) are dropped. The Fbar columns differ in 33-48 rows (13 y) and 2-6 rows (3 y) and also differ between two runs of the same options-off binary (33/45/31 rows in the earlier run), i.e. Fbar is not reproducible run to run, unrelated to the patch |
| B accounting, both options, 13 y, seeds 1-3 | PASS | 88,990 / 88,790 / 89,490 trips, all matched, 0 trips beyond the logbook rounding; max per-trip difference steaming 0.050 h, fishing 0.099 h, timeatsea 0.050 h, distance 0.551 km; totals within 0.007% (h) and 0.002% (km); `popnodes_cumftime` summed over nodes = vmslike fishing hours to 0.0000% (8,723-8,744 of ~8,850 nodes hold fractional hours) |
| C sanity | PASS | 0 NaN / negative hours or km; max step 1.0001 h (4-decimal printing), 0 steps above 1 h + 5e-4; minimum fishing segment 0.0500 h, 0 below 0.05 h (4.1% of fishing segments are partial); 19-22 at-sea steps with 0 h per 13-year run, never two in a row (no stuck vessel); trips longer than 720 steps 27-34 (options off: 33). `timestep_accounting` alone (13 y, seed 1): carry < 1 h (max step prints 2.0000 in 2 of 3.1 M steps: 1 h + a carry just below the 1 h cap) |
| D edge cases and closure | PASS | per trip end reason (seed 1, both options): day trips 37,153, fuel-limited 1,782, hold-full 50,055, trips fishing a code_area 10 node 5,849: all within rounding (max 0.05 h steaming, 0.10 h fishing, 0.54 km). Same for `timestep_accounting` alone (3 y; identical to the run before the fixes) and the closure run. Closure (`area_monthly_closure`, 117 closed nodes, 3 y): 0 fishing hours and 0 steaming rows on closed nodes, options off and on |
| E on vs off, 13 y x 3 seeds | differences listed below | |

**E. Differences beyond seed noise** (per-year means, both options vs off,
z = difference / pooled seed s.e.):

| | off | on | change | z | explanation |
|---|---|---|---|---|---|
| logbook steaming h | 101,140 | 84,531 | -16.4% | -41 | upstream charges a full hour (or more) on every step that reaches a destination |
| distance km | 1,373,300 | 1,146,100 | -16.5% | -43 | same, for distance |
| fuel | 8.227 M | 7.487 M | -9.0% | -15 | follows steaming |
| timeatsea | 244,180 | 233,860 | -4.2% | -3.4 | less steaming, more fishing |
| fishing h (logbook, hours that ran `do_catch`) | 143,030 | 149,330 | +4.4% | 2.2 | see catch below |
| vmslike fishing rows/h | 149,610 | 149,450 | -0.1% | -0.1 | upstream vmslike counts the stop-decision step as a fishing row: exactly 1.000 extra row per trip in all 3 seeds (`stop_rows.R`); the "unchanged" vmslike fishing time hides +4.4% real fishing |
| vmslike steaming rows/h | 105,830 | 84,555 | -20.1% | -51 | overcharge + the declaring step |
| trips | 6,812 | 6,853 | +0.6% | 2.4 | trips 3 h shorter in calendar time |
| fuel-limited trips (share) | 2.25% | 2.01% | -10.6% | -2.9 | with the fuel overcharge gone fewer trips hit the half-tank rule |
| SJU catch | 558.8 t | 595.7 t | +6.6% | 4.4 | more fishing hours (+4.4%) and +2.1% catch/h; 55% from metier 14 |
| OTH catch | 21,283 t | 21,955 t | +3.2% | 4.5 | more fishing hours, catch/h -1.2% |
| SJZ catch | 417.5 t | 436.3 t | +4.5% | 1.3 | (was z 2.3 with the first version; now within noise) |
| total catch | 30,128 t | 30,600 t | +1.6% | 1.9 | borderline |

Not beyond noise: SAB (-11%, z -0.8; one options-off seed has an SAB boom
after year 9, off s.d. of year-13 SSB 104 kt), MIP (+1.9%, z 0.6), SSB of all
stocks (|z| <= 1.8 after year 3; SAB z -2.7 and -3.3 in years 2-3 for differences below 0.5%),
end-reason shares of day trips and hold-full trips, and the spatial effort
pattern (total-variation distance of effort shares per 0.1 deg cell off vs on
0.073, between two off seeds 0.116; correlation of 3-seed means 0.985).

**Where the extra catch comes from** (`catch_explain.R`, decomposition
catch = fishing hours x catch per hour, per trip end reason and metier):

- Not partial fishing. `timestep_accounting` alone (13 y, 3 seeds) gives the
  same catch: +1.58% vs off (both options +1.57%); adding `partial_fishing`
  changes catch by -0.01% (z 0.0) and fishing hours by -1.2% (z -1.7).
- Not depletion: no SSB differs beyond noise; SJU SSB -0.5% (z -1).
- It is the time accounting, through the trip-ending rules, which read
  `timeatsea` and fuel that upstream overcharges:
  - **Day trips** (stop when timeatsea >= 12 h within 3 h of port; 42% of
    trips): steaming per trip 10.14 -> 8.30 h, fishing 6.80 -> 7.55 h (+11%),
    catch per trip +8.6%: +79 t/yr (z 7.1), +2,085 fishing h/yr.
  - **Fuel-limited trips** (stop at half the tank): 10% fewer (z -2.7), each
    fishes 28.9 -> 36.5 h and lands 1.56 -> 1.98 t: +34 t/yr (z 4.3).
  - **Hold-full trips** (56%): catch per trip fixed by the hold (-0.5%), but
    1.7% more of them (calendar time per trip -3 h: no stop-decision step, no
    declaring step, no steaming overcharge): +359 t/yr (z 1.4), +3,600 h/yr.
  - Stock mix: the extra hours fall on metiers 14, 19, 24, 23 (14 and 19
    alone +670 t/yr of hours effect); metier 14 carries most SJU and SJZ, so
    those stocks rise more than the total. Catch per fishing hour falls 2.7%
    overall because the extra hold-full hours cannot raise the capped catch
    per trip.
  - Decision timing (decisions before each fishing action, stop decision no
    longer costing a step) is part of the trip-length effect above; the
    partial-fishing comparison bounds its catch effect at ~0.

**CI release** `displace-96eadecb-westcoast-timestep` (manifest
`1.8.0-96eadecb-westcoast-timestep`), smoke test on sequoia (2026-10-12), 3 years,
simu1, same inputs and flags as above: options off vs the
`1.8.0-96eadecb-westcoast-repro` binary 38/39 files byte-identical (only
`memstats`); both options on vs `dist-fix` 37/39 (`memstats`, and
`popdyn_annual_indic` only in its run-to-run Fbar columns 5-6); vmslike reads
in R with 11 columns (on) and 8 (off).

## What is not done / caveats

- Decisions (`should_i_stop_fishing`, `should_i_change_ground`) are evaluated
  before every fishing action; with partial fishing a step can hold two
  fishing actions on different grounds (rare); a rest of a step shorter than
  0.05 h on a ground is dropped (neither fished nor charged).
- The upstream one-node move branch applies the metier fuel multiplier twice;
  `move_within()` applies it once (no effect when it is 1).
- `vmslikefpingsonly` and the SQLite vmslike are not segmented; the GUI
  movement messages are unchanged.
- `fishing_credits` tariffs are paid per move action rather than per step
  (not used by the westcoast scenarios).
- The patch is not independent of the other eight (shared context lines); it
  must be applied last.
- Only checked on westcoast 7.47 (13 years, seeds 1-3; closure scenario 3 years, seed 1).
