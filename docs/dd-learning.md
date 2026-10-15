# Feature patch `dd-learning` (DISPLACE 1.9.3, on `row-catch-rates`)

Status: experimental (2026-10-15), branch `dd-learning`. Not in the manifest;
built locally only (`~/displace-ddl/payload` on sequoia). Apply after
`row-catch-rates` (the diff is against 1.9.3 + row-catch-rates).

## What it does

Two new `dyn_alloc_sce` options, independent of each other:

- **`density_dependent_catch`**: the catch potential of explicit stocks is
  multiplied by `(available biomass on the node / reference)^dd_beta`, where the
  reference is the node's available biomass at the start of the simulation
  (numbers at szgroup stored before the time loop; current weights and the
  metier's selectivity). The ratio is capped at `dd_max_ratio`; the catch stays
  capped by the available biomass. Nodes without a reference: unchanged.
  Implicit stocks (and stocks on out-of-range nodes) are not affected.
- **`ground_learning`**: after each trip the vessel updates, for each node it
  fished, its remembered catch (landings) per fishing hour,
  `L = (1 - learn_alpha) L + learn_alpha x trip rate` (first visit: the trip
  rate), and its overall remembered rate the same way. In the `grounds_by_port`
  ground draw (choose_a_ground_and_go_fishing), each entry's weight is
  multiplied by `(L_node / L_vessel)^learn_lambda`, bounded to
  [`learn_min_factor`, `learn_max_factor`]; a node never fished keeps factor 1.
  The draw of the trip port and metier is not changed.

Parameters: `vesselsspe_<app>/dd_learning_params.dat`, "key value" lines (keys
`dd_beta` 1, `dd_max_ratio` 10, `learn_lambda` 1, `learn_alpha` 0.3,
`learn_min_factor` 0.1, `learn_max_factor` 10 = defaults when the file or a key
is missing). Log lines: `dd-learning: ...` (parameters) and
`density_dependent_catch: reference numbers stored (...)`.

Options off: no change and no extra random draws (off-check below).

## Files touched

`include/options.h`, `commons/options.cpp` (options), `include/Node.h`
(reference numbers), `include/Vessel.h`, `commons/Vessel.cpp` (parameters,
density factor, learning update and factor), `commons/TextImpl/LoadVesselsImpl.cpp`
(parameter file), `simulator/main.cpp` (reference snapshot).

## Build

```bash
E=<micromamba env with libboost-devel geographiclib-cpp patchelf>
export PATH=$E/bin:$PATH CMAKE_PREFIX_PATH=$E LD_LIBRARY_PATH=$E/lib
tools/build-displace.sh --ref 7cf6378e642a617cd0c3fba4b1580eb9f78ccd6c \
  --patch row-catch-rates --patch dd-learning --workdir /tmp/<w> --outdir <o> --jobs 8
```

## Open

- Off-check PASSED 2026-10-15: options off, westcoast validation_1.0rcr inputs,
  simu1, 13 y: 36 of 38 outputs byte-identical to the row-catch-rates build
  (memstats and popdyn_annual_indic excepted, as between any two runs).
- Tests: westcoast `validation_1.0ddl_{l,d,dl,dl05}` (analysis repo branch
  `dd_learning`).
