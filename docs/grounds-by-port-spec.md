# `grounds_by_port`: input file, scenario option and logbook columns

Specification of the `grounds-by-port` feature patch to DISPLACE v1.8.0
(`tools/patches/grounds-by-port.patch`, branch `displace-grounds-by-port`). It
is written for whoever implements the writer in the West Coast analysis repo
(`routines/06_GenerateVesselsConfigFiles.r`, `routines/07_RunVesselsConfigFiles.R`)
and for anyone reading the outputs. A reference writer exists in displaceR:
`write_displace_fgrounds_harbours()`; `read_displace_fgrounds_harbours()` reads
the files back with the derived probabilities.

## 1. Scenario option

Add `grounds_by_port` to the `dyn_alloc_sce` line of the scenario file
(`simusspe_<app>/<scenario>.dat`, 0-indexed line 1), e.g.

```
# dyn_alloc_sce
baseline grounds_by_port
```

It combines with other options (e.g. `baseline grounds_by_port area_monthly_closure`).

- Without the option the patched binary behaves as unpatched v1.8.0 (check 2 in
  the [log](grounds-by-port-log.md)), reads none of the new files and writes the
  usual loglike.
- An **unpatched** binary silently ignores the unknown option name and runs
  plain baseline. displaceR's `run_displace()` refuses to start such a run
  unless the binary's build record lists the `grounds-by-port` patch
  (`check_features = FALSE` overrides).

## 2. Input file `<vid>_fgrounds_harbours_quarter<N>.dat`

### Location and naming

```
<input folder>/vesselsspe_<app>/<vid>_fgrounds_harbours_quarter<N>.dat
```

- `<vid>`: the vessel id exactly as in `vesselsspe_features_quarter<N>.dat`
  (e.g. `USA0001`), as for `<vid>_possible_metiers_quarter<N>.dat`.
- `<N>`: 1, 2, 3, 4. One file per vessel per quarter. Read at the start of the
  simulation (quarter 1) and at every quarter change, together with the other
  quarterly vessel files.

### Content

- First line: a header. It is skipped without being parsed; write
  `pt_graph metier harbour weight`.
- Then one row per (ground node, metier, port) combination, four fields
  separated by spaces (any run of spaces or tabs):

| # | Field | Type | Meaning |
|---|---|---|---|
| 1 | `pt_graph` | integer >= 0 | ground node index, **0-based**, i.e. the row in `graphsspe/coord<a_graph>.dat` minus 1 -- the same indexing as `vesselsspe_fgrounds_quarter<N>.dat` and `<vid>_possible_metiers_quarter<N>.dat` |
| 2 | `metier` | integer >= 0 | metier index, 0-based, as in `<vid>_possible_metiers_quarter<N>.dat` / `metiersspe_<app>/metier_names.dat` (0..24 for the 25 Gear classes) |
| 3 | `harbour` | integer >= 0 | node index (0-based) of the port the layer belongs to (the landing port of the effort layer) |
| 4 | `weight` | real > 0 | effort weight of this combination, e.g. hours of the vessel x metier x port layer on that node in that quarter |

- The same node may appear on several rows (several ports and/or metiers);
  each row is a separate entry.
- Blank lines are ignored. Node indices must be <= 65534 (DISPLACE node ids
  are 16-bit).
- Write weights in plain decimal or scientific notation (`1.5e-3` is fine).

### How the weights are used (normalisation)

DISPLACE normalises the weights itself; any positive scale works **as long as
all rows of one vessel and quarter share it** (e.g. hours throughout).

With `w_e` the weight of entry *e* of a vessel in the current quarter,
`W_P` the sum of the vessel's weights at port *P* and `W` the vessel total:

- **Trip port**: at departure the vessel draws one entry with probability
  `w_e / W` (closed entries count as `1e-8`, see section 4). Its port is the
  trip port *P*, so `Pr(P) = W_P / W`, the vessel's share of weight at *P*.
- **First ground and metier**: drawn among *P*'s entries with probability
  `w_e / W_P` (`p_within_port` in `read_displace_fgrounds_harbours()`).
- **Changes of ground** during the trip pick among *P*'s ground nodes by
  distance (upstream's closest / second-closest rule); the metier on the new
  ground is drawn among *P*'s entries at that node, by weight.

So the port shares are the *row sums by port*. If the writer wants the port
shares to equal a separate quantity (e.g. `RelativeEffort` per port) rather
than the layers' hour totals, scale each port's rows so that they sum to that
share: `w_e = share_P * fe_e / sum(fe over P's rows)`.

Note that the trip-level shares realised in a run also depend on everything
upstream that acts after the draw: the GoFishing dtree decides whether to
leave with the drawn metier (`vesselMetierIs`), so a metier with a higher
GoFishing probability departs more often than its weight alone implies -- the
same as in baseline DISPLACE, where the metier is drawn from the grounds.

### Consistency with the other vessel files (required)

An entry is **dropped**, with a summary line on stdout
(`grounds_by_port: <vid> quarter <N>: dropped ...`), when

1. its `pt_graph` is not among the vessel's grounds in
   `vesselsspe_fgrounds_quarter<N>.dat` for that quarter -- DISPLACE's per-node
   catch parameters and per-ground bookkeeping are indexed on that list, so a
   port-tagged ground must be one of them;
2. its `metier` is not in `0 .. nbmets-1` (`config.dat`);
3. its `harbour` is not a harbour node (third block of `coord<a_graph>.dat`
   equal to 1);
4. its `weight` is not a positive finite number.

A row with fewer than four numeric fields, or a node index above 65534, stops
the simulation with an error naming the file and line.

Keep writing all existing vessel files as now; the new file is an addition:

- `vesselsspe_fgrounds_quarter<N>.dat` / `vesselsspe_freq_fgrounds_quarter<N>.dat`
  must list (at least) every node used in the new file. Their frequencies are
  not used for vessels with port-tagged entries, but they are for the fallback
  below.
- `vesselsspe_harbours_quarter<N>.dat` / `vesselsspe_freq_harbours_quarter<N>.dat`
  are still used to place the vessel at the start of the simulation and for
  the fallback; listing the entries' ports there (with the port shares) keeps
  the start position consistent.
- `<vid>_possible_metiers_quarter<N>.dat` must still have at least two rows:
  DISPLACE treats a vessel as inactive in a quarter otherwise
  (`simulator/thread_vessels.cpp:203`). Listing every (node, metier) pair of
  the new file there is recommended.
- `<vid>_gshape/gscale_cpue_per_stk_on_nodes_quarter<N>.dat` stay per node:
  catch rates cannot differ between two ports' entries on the same node. If
  per-port rates are wanted, the writer has to combine them per node (e.g. an
  hours-weighted mean).
- Ports need their `harboursspe_<app>/<node>_quarter<N>_each_species_per_cat.dat`
  prices as now (missing ones fall back to `a_port`'s, as upstream).

### Missing or empty files

- **Missing file** for a vessel and quarter: that vessel uses the upstream
  ground and port draws (`freq_fgrounds`, `possible_metiers`, `freq_harbours`)
  for that quarter; its trips get `trip_port = -1`. The load prints how many
  of the files were found (`grounds_by_port: read X of Y ... files`).
- **Header only**, or every row dropped: same as missing.
- A vessel at sea when the quarter changes keeps its trip port and lands
  there, even if the new quarter's file has no entries for that port; changes
  of ground then fall back to the vessel's full ground list for the rest of
  that trip.

## 3. Trip sequence (what the simulator does)

1. In port (every hour until it leaves): draw the trip port *P* and the
   metier, as in section 2. The GoFishing dtree sees that metier.
2. Departure: ground and metier among *P*'s entries; the vessel sails from
   where it is (port *A*).
3. Fishing as upstream (selectivity, catch equation, `do_catch`, stop-fishing
   rules unchanged). Changes of ground stay within *P*'s entries.
4. Return: always to *P* (overrides `freq_harbours` and `closer_port`).
   Catches are landed and valued at *P*.
5. The next trip starts from *P*: A -> grounds of B -> B.

Options that reshape or replace the vessel-wide ground or port frequencies have
**no effect on vessels with port-tagged entries** (a warning is printed at
load): `closer_grounds`, `closer_port`, `focus_on_high_previous_cpue`,
`focus_on_high_profit_grounds`, `fuelprice_plus20percent`,
`shared_harbour_knowledge`, and the **ChooseGround** dtree. Supported:
`area_monthly_closure` (section 4), `aSingleMetierPerTrip` (keeps the metier
drawn in port), `PickUpTheMostFrequentGroundEachTime` (heaviest entry of *P*),
all GoFishing / StartFishing / ChangeGround / StopFishing dtrees. The
`--indb` (SQLite input) loader does not read the new file.

## 4. Closures (`area_monthly_closure`)

Applied per entry, with **the entry's own metier**: an entry is closed when
its node is closed to that metier and to the vessel's size class and nation,
exactly the rule upstream applies per ground.

- At the port draw, closed entries weigh `1e-8` (upstream's penalty).
- At the ground draw, a closed entry weighs `1e-8` once the vessel has used the
  month's open days for that metier (`31 - days closed`), as upstream.
- On a change of ground, such entries are not candidates.
- If every entry of *P* is closed (total < 1e-5), the vessel stays in port that
  hour, as upstream does when all grounds are closed.

Closure files are unchanged (`graphsspe/{metier,vsize,nation}_closure_a_graph<N>_month<M>.dat`).

## 5. Logbook columns

With the option on, `loglike_<sim>.dat` gets **two extra columns at the end of
every line**, after `numTrips`; all existing columns keep their order:

| Position | Name | Meaning |
|---|---|---|
| last - 1 | `trip_port` | node index (0-based) of the trip port *P*, whose grounds the trip fished; `-1` if the vessel had no port-tagged entries when it left (baseline draws) |
| last | `dep_port` | node index of the node the trip departed from (the previous landing port) |

So with `nbpops` populations and `n_explicit` explicit populations the line
has `10 + nbpops + 10 + n_explicit + 12 + 2` fields (discards block present
unless `doNotExportDiscardsInLogbooks`). In the West Coast loglike layout read
by `_targets/fisheries_work/review/read_loglike.R`, append
`"trip_port", "dep_port"` to the column names. Under the option the landing
node column (`idx_node`, 0-indexed field 4) equals `trip_port` for tagged
trips. Without the option nothing is appended.

The SQLite output (`VesselLogLike`) is unchanged; its landing node already
equals the trip port for tagged trips.

displaceR: `read_displace_loglike()` detects the two columns by width and
names them; `check_grounds_by_port()` verifies a run against the input file.
