# Per-trip and total accounting of a DISPLACE run (westcoast 7.47, simu1),
# adapted from calibration/autopilot/loglike_vmslike_reconcile.R. Reads the
# 8-column vmslike (one row per step) or the segmented 11-column one
# (timestep-accounting: one row per segment, + seg, hours, km).
#   Rscript compare.R <label> [<label> ...]   (outputs/<label>/...)
suppressPackageStartupMessages(library(data.table))
W <- "/home/pcarbomestre/displace-timestep-work/outputs"
end3 <- 26305
res <- list()
for (lab in commandArgs(trailingOnly = TRUE)) {
  f <- list.files(file.path(W, lab), "^loglike_simu1.dat$", recursive = TRUE, full.names = TRUE)[1]
  b <- dirname(f)
  l <- fread(f, header = FALSE, fill = TRUE)
  setnames(l, 1:10, c("dep", "arr", "rtbb", "cumstm", "node", "idx", "vid", "tas", "fuel", "dist"))
  l[, catch := V11 + V12 + V13 + V14 + V15]
  l <- l[, .(vid, dep, arr, rtbb, cumstm, tas, dist, fuel, catch)]
  x <- fread(file.path(b, "vmslike_simu1.dat"), header = FALSE)
  seg <- ncol(x) >= 11
  nm <- c("tstep", "vid", "dep", "x", "y", "course", "fuel", "state")
  if (seg) nm <- c(nm, "seg", "hours", "km")
  setnames(x, seq_along(nm), nm)
  x <- x[state %in% 1:2]
  if (!seg) { x[, `:=`(seg = 1L, hours = NA_real_, km = NA_real_)] }
  # a step is "fishing" if any of its segments fishes (as the 1-row format labels it by end state)
  steps <- x[, .(st_last = state[.N], any_fish = any(state == 1),
                 h1 = sum(hours[state == 1]), h2 = sum(hours[state == 2]), km = sum(km)),
             by = .(vid, dep, tstep)]
  pt <- steps[, .(rows = .N, rows_fish = sum(st_last == 1), rows_steam = sum(st_last == 2),
                  h_fish = sum(h1), h_steam = sum(h2), km = sum(km)), by = .(vid, dep)]
  m <- merge(l, pt, by = c("vid", "dep"))
  m <- m[dep > 0]
  cat("\n==========", lab, "(", if (seg) "segmented" else "1 row/step", ") ==========\n")
  cat("trips loglike", nrow(l), "| matched", nrow(m), "\n")
  q <- function(v) sprintf("mean %.3f  [p5 %.2f, p50 %.2f, p95 %.2f]", mean(v), quantile(v, .05), quantile(v, .5), quantile(v, .95))
  cat("per trip: steps rows - (arr-dep)          :", q(m$rows - (m$arr - m$dep)), "\n")
  cat("per trip: steam rows - cumsteaming        :", q(m$rows_steam - m$cumstm), "\n")
  cat("per trip: fish rows - (tas - cumsteaming) :", q(m$rows_fish - (m$tas - m$cumstm)), "\n")
  cat("per trip: rows - tas                      :", q(m$rows - m$tas), "\n")
  if (seg) {
    cat("per trip: seg steam hours - cumsteaming   :", q(m$h_steam - m$cumstm), "\n")
    cat("per trip: seg fish hours - (tas-cumstm)   :", q(m$h_fish - (m$tas - m$cumstm)), "\n")
    cat("per trip: seg km - dist                   :", q(m$km - m$dist), "\n")
  }
  x3 <- steps[tstep < end3]
  l3 <- l[dep < end3 & dep > 0]
  r <- data.table(
    run = lab,
    trips = nrow(l3),
    trips_per_year = nrow(l3) / 3,
    vms_rows_fish = sum(x3$st_last == 1),
    vms_rows_steam = sum(x3$st_last == 2),
    vms_rows_atsea = nrow(x3),
    vms_h_fish = if (seg) round(sum(x3$h1)) else NA,
    vms_h_steam = if (seg) round(sum(x3$h2)) else NA,
    log_tas = round(sum(l3$tas)),
    log_steam = round(sum(l3$cumstm)),
    log_fish = round(sum(l3$tas - l3$cumstm)),
    log_steps = sum(l3$arr - l3$dep),
    dist_km = round(sum(l3$dist)),
    fuel = round(sum(l3$fuel)),
    catch_t = round(sum(l3$catch) / 1000, 1),
    trip_h_mean = round(mean(l3$arr - l3$dep), 2),
    tas_mean = round(mean(l3$tas), 2)
  )
  print(t(r))
  res[[lab]] <- r
}
if (length(res) > 1) { cat("\n"); print(rbindlist(res)) }
