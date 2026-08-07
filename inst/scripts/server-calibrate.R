# Run this ON THE SERVER before committing to a long allocation.
# Times one short replicate and extrapolates, so the duration you request is
# based on that machine's cores rather than on a laptop's.
library(displaceR)

IN  <- "/PATH/TO/DISPLACE_input_westcoast_pscenario_1.0"   # <- edit
OUT <- file.path(tempdir(), "calib")

t0 <- proc.time()[["elapsed"]]
res <- run_displace(
  input_dir = IN, input_name = "westcoast_pscenario_1.0",
  scenario = "baseline", sim_name = "calib", steps = 4000,
  output_dir = OUT, num_threads = 1,
  sqlite = FALSE, export_vmslike = 10, huge = TRUE,
  static_paths = FALSE, selected_vessels_only = 0, verbosity = 1,
  echo = FALSE
)
elapsed <- proc.time()[["elapsed"]] - t0

# Startup measured at ~3s, so this is essentially the marginal per-step rate.
rate <- (elapsed - 3) / 4000
one  <- (3 + rate * 87673) / 3600
waves <- ceiling(30 / 15)

cat(sprintf("\n4000 steps took %.0fs  ->  %.3f s/step\n", elapsed, rate))
cat(sprintf("one 10-year replicate : %.1f h\n", one))
cat(sprintf("30 replicates, 15 workers (%d waves): %.1f h\n", waves, waves * one))
cat(sprintf("REQUEST AT LEAST      : %.0f h\n", ceiling(waves * one * 1.5)))
cat(sprintf("\n(this Mac: 0.139 s/step, 3.4 h per replicate, 6.8 h total)\n"))

cat("\npeak memory this replicate:\n")
ms <- file.path(res$output_path, "memstats_calib.dat")
if (file.exists(ms)) cat(readLines(ms), sep = "\n")
