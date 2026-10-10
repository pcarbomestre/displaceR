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

See the end of this file (filled in from the westcoast 7.47 test runs).
