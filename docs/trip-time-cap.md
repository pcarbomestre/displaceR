# Feature patch `trip-time-cap` (DISPLACE 1.9.3, on `row-catch-rates`)

Status: experimental (2026-10-15), branch `ground-time-cap`. Not in the
manifest; built locally only (`~/displace-cap/payload` on sequoia). Apply after
`row-catch-rates` (the diff is against 1.9.3 + row-catch-rates).

## What it does

New `dyn_alloc_sce` option **`trip_time_cap`**. Each vessel reads its cap from
`vesselsspe_<app>/vessels_max_trip_hours.dat` (heading line, then
`VE_REF hours`) at load. In the default StopFishing rules
(`Vessel::should_i_stop_fishing`, no StopFishing tree) a fourth condition joins
the day-trip, fuel and hold checks: the vessel stops fishing and returns when
its time at sea plus the steaming to its nearest port (straight-line distance /
speed) reaches the cap; `reason_to_go_back` = 5 (loglike column 3).

Why: in the westcoast validation (one ground per trip, nb_pings_per_trip 1) a
trip ends only on a full hold, fuel or the day-trip rule; trips on nodes where
the hold fills slowly ran for up to 3,000 h, 23% of simulated fishing hours in
trips beyond the vessel x gear's observed maximum.

No file, a vessel without a line, or the option off: no cap (no extra random
draws). Log line: `trip_time_cap: N of M vessels have a cap ...`.

## Files touched

`include/options.h`, `commons/options.cpp` (option), `include/Vessel.h` (cap),
`commons/Vessel.cpp` (stop rule), `commons/TextImpl/LoadVesselsImpl.cpp` (reader).

## Build

```bash
E=<micromamba env with libboost-devel geographiclib-cpp patchelf>
export PATH=$E/bin:$PATH CMAKE_PREFIX_PATH=$E LD_LIBRARY_PATH=$E/lib
tools/build-displace.sh --ref 7cf6378e642a617cd0c3fba4b1580eb9f78ccd6c \
  --patch row-catch-rates --patch trip-time-cap --workdir /tmp/<w> --outdir <o> --jobs 8
```

## Open

- Off-check PASSED 2026-10-15: option off, westcoast validation_1.0rcr inputs,
  simu1, 13 y: 37 of 38 outputs byte-identical to the row-catch-rates build
  (popdyn_annual_indic excepted, as between any two runs).
- Tests: westcoast `validation_1.0cap_{q95,max}` (analysis repo branch
  `ground_time_cap`), one cap per vessel (its observed trip-duration q95 / max).
  A per vessel x metier cap is a possible follow-up.
