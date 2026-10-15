# Feature patch `row-catch-rates` (DISPLACE 1.9.3)

Status: experimental (2026-10-15), branch `row-catch-rates`. Not in the
manifest; built locally only (`~/displace-rowcr/payload` on sequoia).

## What it does

New `dyn_alloc_sce` option **`catch_rate_by_row`**. With it, each vessel reads
`vesselsspe_<app>/<vid>_catchrates_per_metier_harbour.dat` once at creation:

```
metier harbour pop kg_h
3 24124 0 59.0
3 24124 4 196.0
...
```

`metier` = metier index, `harbour` = harbour node index (as in
`<vid>_fgrounds_harbours_quarter*.dat`), `pop` = population index, `kg_h` = catch
per fishing hour. On each fishing step, the rate of the trip's metier and trip
port (`get_trip_port()`, set by `grounds_by_port`) replaces:

- implicit stocks (and every stock on an out-of-range node,
  `out_of_range_implicit`): the per-node gamma scale (shape 1, scale = rate);
- explicit stocks: `exp(vessel beta + metier beta)` in the catch potential
  (habitat and availability effects, the pop / metier multipliers, technology
  creep and partial fishing kept; the catch stays capped by the node biomass).

No row for the (metier, port, pop), no file, or the option off: the vessel's
usual rates. The lookup draws no random numbers, so with the option off (or no
files) runs are byte-identical to plain 1.9.3.

Why: the westcoast analysis computes catch rates per vessel-metier-port but
DISPLACE only takes one rate per vessel and stock (implicit) or vessel x
fleet-wide metier factor (explicit); see the analysis repo, branch
`row_catch_rates`, `calibration/ROW_CATCH_RATES.md`.

## Files touched

`include/options.h`, `commons/options.cpp` (option), `include/Vessel.h`,
`commons/Vessel.cpp` (storage, `get_row_catch_rate()`, the two catch
equations), `commons/TextImpl/LoadVesselsImpl.cpp` (reader, load at creation,
log line `catch_rate_by_row: N of M vessels read ...`).

## Build

```bash
E=<micromamba env with libboost-devel geographiclib-cpp patchelf>
export PATH=$E/bin:$PATH CMAKE_PREFIX_PATH=$E LD_LIBRARY_PATH=$E/lib
tools/build-displace.sh --ref 7cf6378e642a617cd0c3fba4b1580eb9f78ccd6c \
  --patch row-catch-rates --workdir /tmp/<w> --outdir /tmp/<o> --jobs 8
```

Use it with `binary = "<o>/payload/displace"` (not installed, so
`displace_path()` keeps its default). `run_displace()`'s feature check does not
know this option (it does not refuse scenarios with it).

## Open

- Off-check PASSED 2026-10-15: option off, westcoast validation_1.0 simu1,
  13 y: 36 of 38 outputs byte-identical to plain 1.9.3 (memstats and
  popdyn_annual_indic excepted, as between any two runs).
- First test: westcoast validation_1.0rcr, 5 replicates x 13 y: shelf excess
  reduced but effort overshoots onto the slope, fishing time +14.5%
  (uncalibrated); see the analysis repo's calibration/ROW_CATCH_RATES.md.
