# Making a single DISPLACE run faster without changing its results

Branch `displace-speedup` (from `displace-grounds-by-port` at `9b14ee0`).

Summary: `astar-speedup` + `sample-table-cache` make a single westcoast run
~9-13x faster on macOS arm64 with byte-identical outputs (details below).

Ground rules for this work:

- **One replicate, one thread.** More `--num_threads` is out of scope.
- **Outputs must be byte-identical** to the unpatched build for the same inputs
  and seed. A speedup that changes any output is a model change and does not
  belong here.
- Upstream stays read-only: changes are opt-in patches in `tools/patches/`.

## Where the time goes (v1.8.0, westcoast validation_1.0, macOS arm64)

`sample` profile of one month (744 steps, `baseline_nodiff`, 484 vessels,
18,439 nodes, 108,064 edges), reference build
(`grounds-by-port + headless-ipc-lazy + keep-unselected-othland`):

| | seconds | share of stepping |
|---|---|---|
| Loading inputs | ~8 | – |
| Stepping | ~122 | 100% |
| of which A* (`AStarShortestPathFinder::findShortestPath`) | ~96 | 78% |
| of which GeographicLib `Geodesic::Inverse` inside A* | ~95 | 77% |
| `do_sample` (sort in `which_metier_should_i_go_for`) | ~5 | 4% |

All A* calls are already serialised behind `aStarMutex` in `Vessel.cpp`, so
extra threads would not have helped this part anyway.

## Why A* is so slow: the heuristic is always NaN

`GeoGraph::location` is declared `{ float y, x; }` (lat, long), but
`GeoGraph::addNode()` fills it with `{x, y}`. Each location's `.y` therefore
holds the **longitude**, and the A* heuristic

```cpp
geod.Inverse(m_location[m_goal].y, m_location[m_goal].x, m_location[u].y, m_location[u].x, d);
```

passes longitude as latitude. GeographicLib returns NaN for any latitude
outside [-90, 90] — after doing the full geodesic iteration. On the US west
coast every longitude is in [-125.9, -117.2], so **every heuristic call returns
NaN** (checked on all 3.5 million (goal, node) pairs for 191 goals: 100% NaN,
and exactly when one of the two "latitudes" is outside ±90).

With NaN priorities the A* queue is effectively unordered: the search explores
most of the graph (~60 ms per call) and returns *a* path, not the shortest one.

### Consequence for results (not changed here)

Upstream's A* compared with Dijkstra on the same graph, 298 random
(harbour, node) pairs: the A* path is the true shortest in **4 of 298**; path
length ratio median **1.07**, p90 1.21, max 2.14. Steaming distance, fuel and
trip duration in the simulation are computed along these paths. This is upstream
behaviour and is preserved exactly by everything on this branch; fixing it would
be a separate, result-changing patch and a modelling decision. Reproduce with
the throwaway program described in "How it was checked".

In a European case study (|longitude| < 90) the heuristic is finite but still
built from swapped coordinates, and it is in metres while edge weights are in
km, so it is not admissible there either.

## Patch `astar-speedup` (opt-in, results unchanged)

`commons/shortestpath/AStarShortestPathFinder.{cpp,h}`. Three independent parts:

1. **NaN shortcut.** When either coordinate passed as latitude is outside ±90,
   the heuristic returns GeographicLib's NaN directly instead of computing it.
   Same test as GeographicLib's `Math::LatFix`, on the same values, so the
   search sees exactly the same numbers. The NaN is probed from the library at
   startup (`Inverse(91, 0, 0, 0)`); if it ever stops being NaN the shortcut
   disables itself. `DISPLACE_ASTAR_NAN_SHORTCUT=0` turns it off.
2. **Path cache.** The graph is loaded once and only reachable as `const`, and
   the search draws no random numbers, so `findShortestPath(from, to)` is a pure
   function. Results are memoised by `(from, to)`, bounded by
   `DISPLACE_ASTAR_CACHE_MB` (default 1024; `0` disables; when full it is
   emptied and refilled). `DISPLACE_ASTAR_CACHE_STATS=1` prints the hit rate to
   stderr every 1000 lookups.
3. **Compact graph** (added after the first tests below). `GeoGraph::Graph` is an
   `adjacency_list<listS, vecS, undirectedS>`, so every out-edge is a linked-list
   node pointing at a separately allocated edge record. At the first search the
   out-edges are copied into flat arrays in exactly the order Boost's
   `out_edges()` yields them, and the search runs on those. The search is a
   line-by-line transcription of what Boost runs: `astar_search_tree()`
   initialisation, `astar_search_no_init_tree()` with the same 4-ary
   `d_ary_heap_indirect` of `(rank, vertex)` pairs (duplicates pushed, no
   decrease-key), `boost::relax()` for an undirected graph **including its
   reverse branch** (an edge can lower the distance of the vertex being
   expanded, and the edge's far end is then still pushed), `closed_plus`
   combine and `std::less` compare, all on the same float values. Not used if
   any edge weight is negative (Boost would throw `negative_edge`) or with
   `DISPLACE_ASTAR_COMPACT=0`.

## Patch `sample-table-cache` (opt-in, results unchanged)

`include/myRutils.h`, `do_sample()`. Every call normalised, sorted and
accumulated the whole probability vector before drawing; with `grounds_by_port`
that vector is the vessel's full port x ground x metier entry list, sorted on
every trip decision. The table is now built by an unchanged copy of that code
(`do_sample_table()`) and kept, keyed by the exact bytes of `(val, proba)`: a
lookup hashes them to find a candidate and then confirms with `memcmp` on both
vectors, so a table is only reused for bit-for-bit identical inputs. For
identical inputs `std::sort` produces the identical order (ties included) and
the sums run in the same order, so the table is the same. The draws themselves
(`unif_rand()`, linear scan) are unchanged. Per thread, bounded by
`DISPLACE_SAMPLE_CACHE_MB` (default 256; `0` disables), emptied when full. Only
for element types that are trivially copyable (`int`, `NodeId`); others use the
original path.

Build:

```bash
tools/build-displace.sh --ref v1.8.0 \
    --patch grounds-by-port --patch headless-ipc-lazy --patch keep-unselected-othland \
    --patch astar-speedup --workdir <dir> --outdir <dist>
```

### Results (2026-10-09, macOS arm64, westcoast validation_1.0, 744 steps, simu1)

| Build / switches | wall time | outputs vs reference |
|---|---|---|
| reference (run 1) | 130.2 s | – |
| reference (run 2) | 130.6 s | identical |
| `astar-speedup`, both parts off | 132.1 s | identical |
| `astar-speedup`, cache only (earlier build) | 118.0 s | identical |
| `astar-speedup`, NaN shortcut only | 34.6 s | identical |
| `astar-speedup`, both | **32.7 s** | identical |

"Identical" = all 38 text outputs byte-identical (except `memstats_*.dat`, which
also differs between the two reference runs) and all 18 SQLite tables identical
row for row.

Path-cache hit rate in month 1 is only 7%, because most (from, to) pairs are new.
It should rise over a multi-year run as vessels repeat port -> ground trips; not
yet measured.

### Real calibration applications (2026-10-09)

Inputs: `westcoast_calibration_2.0`, `3.1`, `4.0` (copies of
`.../DISPLACE_owf_westcoast/displace_inputs/DISPLACE_processed_inputs/`, checked
identical with `diff -rq`). Their real `baseline` scenario, including
`grounds_by_port`, `diffusePopN` and (4.0) `out_of_range_implicit`. Run settings
from their `displace_run_settings.json`: `--huge=1 -e13 --disable-sqlite
--num_threads 1`; `-s simu1`, 2200 steps (~3 months, crosses the first quarter
change at 2160). macOS arm64.

Builds: `grounds-by-port headless-ipc-lazy keep-unselected-othland
out-of-range-implicit test-fixed-diffusion-seed`, with and without
`astar-speedup`. `test-fixed-diffusion-seed` was a **testing-only** patch (since
removed; `reproducible-diffusion` replaces it for testing): with
`DISPLACE_TEST_DIFFUSION_SEED` set it seeds `diffusePopN`'s generator
(`commons/Population.cpp`, otherwise `std::random_device`) so these runs are
reproducible; without the variable it behaves exactly like upstream. Both builds
carry it, and every run here set it to 12345.

| Calibration | reference run 1 | reference run 2 | `astar-speedup` | speedup | outputs |
|---|---|---|---|---|---|
| 2.0 | 610 s | 609 s | 134 s | 4.5x | 38/38 identical |
| 3.1 | 621 s | 621 s | 138 s | 4.5x | 38/38 identical |
| 4.0 | 611 s | 623 s | 139 s | 4.4x | 38/38 identical |

39 text files per run (~1,650 trips, 62-81k VMS rows, 18 diffusion events);
`memstats_simu1.dat` differs between the two reference runs and is excluded, all
other 38 are byte-identical across reference, reference and fast. The nine runs
ran concurrently, so absolute times are inflated; the ratio is the useful figure.
Path-cache hit rate after 3000 lookups: 19.5-20.3%.

### All speedups vs none, with `reproducible-diffusion` (2026-10-09)

`reproducible-diffusion` makes same-name runs reproducible, so from here the
comparison is against a plain build and no test patch is needed. Both builds:
`grounds-by-port headless-ipc-lazy keep-unselected-othland out-of-range-implicit
reproducible-diffusion`; the fast one adds `astar-speedup` (all three parts) and
`sample-table-cache`. Real `baseline` scenarios, production output settings as
above, macOS arm64.

| Run | no speedups | all speedups | ratio | outputs |
|---|---|---|---|---|
| 2.0, simu1, 2200 steps | 510 s | 59 s | 8.6x | 38/38 identical |
| 3.1, simu1, 2200 steps | 522 s | 58 s | 8.9x | 38/38 identical |
| 4.0, simu1, 2200 steps | 505 s | 58 s | 8.7x | 38/38 identical |
| 4.0, simu3, 2200 steps | 559 s | 62 s | 9.0x | 38/38 identical |
| 4.0, simu1, 4380 steps (6 months) | 880 s | 69 s | 12.8x | 38/38 identical |

(`memstats` excluded, as before.) The 2200-step runs ran eight at a time and the
6-month pair ran next to four unrelated 3-year runs, so absolute times are
inflated. Alone, the fast build does 4.0 / 2200 steps in 40.5 s. The 6-month run
covers 3,304 trips, 128,860 VMS rows, two quarter changes and a semester change.

Path-cache hit rate (cumulative) over the 6 months: 13.9% at 2000 lookups,
22.4% at 4000, 28.1% at 6000 -- still rising, which is why the ratio grows with
run length.

Offline check of the compact graph alone (`geotest/compact.cpp`: upstream's
loader and finder, compact switch on/off, cache off), calibration 4.0 graph,
3000 searches (harbour -> node, node -> harbour, node -> node): 0 mismatching
paths; 11.1 ms vs 5.2 ms per search.

### Expected saving on a 13-year run (113,952 steps)

Unpatched rate measured from the user's own 3-year calibration runs on the same
Mac: ~0.22 s/step, i.e. ~6.8 h per 13-year run. With all speedups: ~0.015
s/step at 6 months (falling as the cache warms), i.e. ~25-35 min. Not yet
measured on sequoia (different CPU and compiler); the ratio should carry over
because the gains come from skipped work, but confirm with one timed run there.

## Profile after all speedups (4.0, 2200 steps, alone, 40.5 s)

| | share |
|---|---|
| Loading at start + vessel reload each quarter (~3 s each, iostream parsing of `gshape/gscale_cpue_per_stk_on_nodes`) | ~25% of this short run; ~2.5-3 min of a 13-year run |
| A* (compact search) | ~80% of stepping |
| `do_sample` (now cached) | ~10% of stepping, was ~34% |

## Candidates not done yet

All must be verified byte-identical before use.

- **A* with all-NaN keys.** When the goal's "latitude" is out of range every
  rank is NaN, and Boost's 4-ary heap then degenerates to: push appends, pop
  takes the front and moves the last element there. A queue written that way
  would skip the comparisons. Small gain; the number of vertices examined per
  search, not the heap, dominates now, and that cannot change without changing
  paths.
- **Faster quarterly reload.** `fill_multimap_from_specifications_i_d` parses
  numbers through iostreams. A `strtod`-based parser gives the same doubles
  (both are correctly rounded) and would cut most of the ~3 s per quarter.
- **Compiler flags (Linux only).** Release already uses `-O3`. LTO and
  `-march=x86-64-v3` remain; `-march` must come with `-ffp-contract=off`, since
  GCC on x86-64 fuses multiply-adds (FMA) once `-march` enables them, which
  changes floating-point results. Needs a Linux machine to verify; Docker is not
  available on this Mac. (On macOS arm64 clang already contracts within
  expressions by default, one reason Mac and Linux builds can differ.)

## How it was checked

- Profiles: `sample <pid> <secs> 1` on the running `displace`.
- Determinism baseline: `baseline_nodiff` (= `baseline` without `diffusePopN`,
  whose generator is seeded from `std::random_device`, so runs with it are not
  reproducible — `docs/grounds-by-port-handover.md`).
- Comparison: `cmp` on every `.dat` in `DISPLACE_outputs/<f>/<F>/`, and a
  `shasum` of `select * from <table>` for each SQLite table.
- NaN claim: a small program reproducing `GeoGraph`'s storage and calling
  `Geodesic::WGS84().Inverse` on every 97th goal x every node of `coord2.dat`.
- Path-length claim: a small program linking upstream's `GeoGraph.cpp`,
  `GeoGraphLoader.cpp` and `AStarShortestPathFinder.cpp` unmodified, comparing
  path cost with `boost::dijkstra_shortest_paths` on `coord2.dat`/`graph2.dat`.
