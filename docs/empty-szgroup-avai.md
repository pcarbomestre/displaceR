# Feature patch `empty-szgroup-avai` (DISPLACE 1.9.3, on `trip-time-cap`)

Status: experimental (2026-10-20), branch `empty-szgroup-avai`. Not in the
manifest; built locally only (`~/displace-esa/payload` on sequoia). Apply after
`row-catch-rates` and `trip-time-cap` (the diff is against 1.9.3 + both).

## What it fixes

At each growth step (`simulator/biomodule2.cpp`, redispatch after do_growth),
DISPLACE rewrites each size group's availability on a node as the node's share
of that group's numbers before growth, then `distribute_N()` puts the grown
totals back on the nodes with it. A size group with no fish on any node gets
availability 0 on every node, so everything that grows or is recruited into it
is deleted. With redispatch frequency 5 (diffusion; the input layers are never
re-read) a group empty in `init_pops_per_szgroup` therefore stays empty all run
and is a sink. Westcoast: sablefish group 2 (fish growing out of group 1 and 27%
of recruits deleted; 61% of recruits never reach adult sizes) and longspine
groups 0-1 (44% of recruits deleted).

## What it does

New `dyn_pop_sce` option **`keepEmptySzgroupAvai`**: a size group with no fish
on any node keeps its current availability instead of 0. A group empty from the
start keeps the input map (`static_avai`) until it first holds fish, then
follows its fish as every other group; a group that empties later keeps its
last map. Fish growing or recruited into it are kept. Groups with fish are
unchanged. Option off: DISPLACE as before.

## Files touched

`include/options.h`, `commons/options.cpp` (option),
`simulator/biomodule2.cpp` (redispatch).

## Build

```bash
E=<micromamba env with libboost-devel geographiclib-cpp patchelf>
export PATH=$E/bin:$PATH CMAKE_PREFIX_PATH=$E LD_LIBRARY_PATH=$E/lib
tools/build-displace.sh --ref 7cf6378e642a617cd0c3fba4b1580eb9f78ccd6c \
  --patch row-catch-rates --patch trip-time-cap --patch empty-szgroup-avai \
  --workdir /tmp/<w> --outdir <o> --jobs 8
```

## Tests

- Off-check PASSED 2026-10-20: option off, westcoast
  `validation_1.0cap_q90_s0695` inputs, simu1, 13 y: 36 of 38 outputs
  byte-identical to the trip-time-cap build (memstats and popdyn_annual_indic
  excepted, as between any two runs).
- On (westcoast `validation_1.0cap_q90_s0695_esa` vs `_sr`, 5 replicates x
  13 y; analysis repo branch `ground_time_cap`, setup option
  `keep_empty_szgroups`): sablefish group 2 holds fish (mean 2.7 million, was
  0), longspine groups 0-1 69 million (was 0); sablefish total numbers
  2023/2011 0.59 -> 1.72, landings ratio 0.80 -> 0.92 with no cpue change;
  Dover and shortspine unchanged (no empty groups); fits hold (block R2 0.906).

## Upstream

Worth reporting to DISPLACE: any application with a size group empty at the
start (or one that empties) loses the fish entering it when the population is
not re-read from the input layers.
