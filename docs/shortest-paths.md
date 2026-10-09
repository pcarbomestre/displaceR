# Exact shortest paths for vessels (`shortest-paths` patch)

Branch `displace-shortest-paths` (from `displace-grounds-by-port` at `f80e104`).
Experimental: this patch **changes model results** when switched on, and whether
to use it is a modelling decision. It is kept on its own branch until that
decision is made.

## The problem

Every vessel movement (port -> ground, ground -> ground, ground -> port) follows
a path from upstream's A* (`commons/shortestpath/AStarShortestPathFinder.cpp`).
`GeoGraph::addNode()` stores `{x, y}` into a struct declared `{y, x}`, so the A*
heuristic passes each node's longitude as its latitude. On the US west coast
every |longitude| > 90, so GeographicLib returns NaN for every heuristic value,
the search order is effectively arbitrary, and the path returned is usually not
the shortest (`docs/speedup.md`, "Why A* is so slow"). The heuristic is also in
metres while edge weights are km, so it would not be admissible even with the
coordinates the right way round.

Upstream's A* compared with exact shortest paths on the calibration 4.0 graph
(18,427 nodes, 107,992 edges), 996 reachable (harbour, node) and (node,
harbour) pairs: the A* path is exactly shortest in 17; length ratio median
1.079, p90 1.288, max 7.33.

## The patch

`tools/patches/shortest-paths.patch`:

- `commons/shortestpath/DijkstraShortestPathFinder.h` (new, header only):
  `boost::dijkstra_shortest_paths` on the same `GeoGraph`, by edge weight (km),
  stopped as soon as the goal is settled, with the same return contract as the
  A* finder (path from `from` to `to` inclusive; empty if unreachable). Results
  are memoised by `(from, to)` (the graph never changes during a run), bounded
  at 512 MB.
- `commons/Vessel.cpp`: the five calls to `aStarPathFinder.findShortestPath()`
  go through `displaceR_findPath()`, which uses the Dijkstra finder when the
  scenario's `dyn_alloc_sce` contains `shortest_paths`, and the unchanged A*
  otherwise.
- `include/options.h`, `commons/options.cpp`: the new option `shortest_paths`.
- `R/grounds_by_port.R`: `shortest_paths` added to `FEATURE_OPTIONS`, so
  `run_displace()` refuses such a scenario on a binary built without the patch
  (an unpatched simulator would silently ignore the option).

Switch it on per scenario, on the first value line of
`simusspe_<name>/<scenario>.dat`:

```
# dyn_alloc_sce
baseline grounds_by_port out_of_range_implicit shortest_paths
```

Applies alone and with all seven other patches, in either order (checked
2026-10-09). Not used for the static-path mode (`-p 1`), which reads precomputed
paths instead of searching.

## Checks (2026-10-09, macOS arm64)

**Offline, calibration 4.0 graph, 1000 pairs:** the finder's path cost equals
the Dijkstra distance in all 996 reachable pairs; the 4 unreachable pairs return
an empty path; no path is malformed. 0.56 ms per uncached search (the compact
A* in `astar-speedup` takes ~5 ms).

**Option off is invisible.** Build with all eight patches vs the same build
without `shortest-paths`, calibrations 4.0 and 2.0, real `baseline`, 2200 steps,
simu1, production output settings: 38/38 output files byte-identical (memstats
excluded). A byte-identical copy of `baseline.dat` under another name also gives
38/38 identical outputs, so renaming the scenario changes nothing by itself.

**Option on**, same runs with `shortest_paths` added (only line 2 of the
scenario file differs), from `loglike` (per-trip means):

| | 4.0 A* | 4.0 shortest | change | 2.0 A* | 2.0 shortest | change |
|---|---|---|---|---|---|---|
| trips | 1,670 | 1,687 | +1% | 1,649 | 1,624 | -2% |
| distance per trip | 245.0 km | 196.7 km | -20% | 235.6 km | 192.3 km | -18% |
| time at sea per trip | 36.8 h | 32.0 h | -13% | 43.7 h | 39.0 h | -11% |
| fuel per trip | 1338.5 | 1164.6 | -13% | 1418.5 | 1211.3 | -15% |
| total landings | 5.30 M | 5.90 M | +11% | 5.73 M | 5.46 M | -5% |
| VMS positions | 65,550 | 57,993 | -12% | 80,680 | 74,565 | -8% |

One seed and 3 months: once paths change, every later random draw differs, so
trip-level means are meaningful but totals such as landings need several
replicates before reading anything into them. Run time also drops (40 s -> 22 s
for these runs) because the Dijkstra search is cheaper than the A* it replaces.

## Closures and the lease-area penalty

Closures (`metier_`, `nation_`, `vsize_closure_a_graph<N>_month*.dat`, active
with `area_monthly_closure`) are only checked when a vessel chooses where to
fish (`choose_a_ground_and_go_fishing`, `choose_another_ground_and_go_fishing`,
`should_i_choose_this_ground`, `maybe_close_ground`,
`which_metier_should_i_go_for`). The navigation graph is fixed after loading,
so neither path finder routes around closed nodes; that is unchanged here.

What does steer routes is the edge-weight penalty that `add_displace_closure()`
writes into `graph<N>.dat` (graph 2: 758 lease-area edges at +500 km, 102 at
+1000). Travelled distance, steaming time and fuel are computed from node
coordinates (`dist()` in `Vessel.cpp`), not edge weights, so the penalty only
affects route choice. 1,500 random harbour <-> node paths on the calibration
4.0 graph:

| | paths crossing a penalised edge | crossings |
|---|---|---|
| upstream A* | 27 (1.8%) | 111 |
| `shortest_paths` | 15 (1.0%) | 24 |

All 15 Dijkstra cases start or end at a node inside a lease area (every edge
at that node penalised), where crossing is unavoidable; no Dijkstra path crosses
an area in transit. Upstream A* does, because its search order ignores weights
in practice. So with `shortest_paths` the penalty works as intended. Fishing
inside the areas is still possible unless `area_monthly_closure` is on.

### Test: closures on, A* vs shortest paths (2026-10-09)

Calibration 4.0, 2200 steps, simu1, all eight patches; `area_monthly_closure`
added to the scenario. Every `vmslike` position tested against the five
lease-area polygons (`DISPLACE-westcoast-analysis/data/lease_areas/ca_lease_areas_2024`);
all 117 closed nodes lie inside them. State 1 = fishing, 2 = steaming.

| scenario | positions inside lease areas | fishing | steaming | trips |
|---|---|---|---|---|
| A*, no closures | 153 | 129 | 24 | 11 |
| shortest paths, no closures | 140 | 128 | 12 | 8 |
| A*, closures on | 8 | 0 | 8 | 7 |
| shortest paths, closures on | **0** | 0 | 0 | 0 |

Closures stop fishing inside; only `shortest_paths` also stops transit through.
Positions are hourly, so a crossing shorter than an hour could fall between two
records; the offline path check above covers that case (no Dijkstra path
crosses a lease area unless it starts or ends inside one).

**Gap in the closure files:** `vsize_closure_a_graph2_month*.dat` close sizes
0, 1, 2 and 4 but not 3 (24-40 m), and DISPLACE treats a ground as closed only
when metier, size and nation are all banned. Calibration 4.0 has 3 vessels of
24-40 m, so those can still choose grounds inside the lease areas with closures
on (none did in this run). Regenerate with `vessel_sizes = 0:4` if all vessels
should be excluded.

## Before adopting it

- The calibrations so far (effort, CPUE, fuel and trip-duration targets) were
  fitted with upstream's longer paths. Shorter paths lower distance, time at sea
  and fuel per trip by roughly 10-20%, so the calibration should be re-checked
  with the option on.
- Suggested evaluation: a few replicates per scenario, a year or more, comparing
  trip duration, distance, fuel and the spatial distribution of effort against
  the observed VMS/logbook data, with and without the option.
- If adopted, merge this branch into `displace-grounds-by-port` and add
  `shortest-paths` to the build's patch list; the option still has to be set per
  scenario.
