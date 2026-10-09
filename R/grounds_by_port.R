## Port-tagged fishing grounds: the `grounds_by_port` feature patch.
##
## A DISPLACE build made with `tools/build-displace.sh --patch grounds-by-port`
## understands one more dyn_alloc_sce option, `grounds_by_port`. With it, each
## vessel reads vesselsspe_<name>/<vid>_fgrounds_harbours_quarter<N>.dat, draws a
## trip port P at departure, fishes only P's entries and lands at P, so trips
## run A -> grounds of B -> B. Two columns, trip_port and dep_port, are appended
## to loglike. The file format and the behaviour are specified in
## docs/grounds-by-port-spec.md; the C++ is tools/patches/grounds-by-port.patch.
##
## An unpatched binary silently ignores unknown dyn_alloc_sce names, so running a
## grounds_by_port scenario on it gives a plain baseline run with nothing to say
## so. run_displace() refuses that combination (see check_binary_features()).

FGROUNDS_HARBOURS_HEADER <- "pt_graph metier harbour weight"

fgrounds_harbours_path <- function(input_dir, input_name, vessel, quarter) {
  file.path(input_dir, paste0("vesselsspe_", input_name),
            sprintf("%s_fgrounds_harbours_quarter%d.dat", vessel, as.integer(quarter)))
}

#' Write port-tagged fishing grounds
#'
#' Writes `vesselsspe_<input_name>/<vessel>_fgrounds_harbours_quarter<N>.dat`,
#' the input of the `grounds_by_port` option of a DISPLACE build made with the
#' `grounds-by-port` feature patch. One file is written per vessel and quarter
#' present in `x`. This is a reference implementation of the format in
#' `docs/grounds-by-port-spec.md`; it checks the row-level rules but cannot check
#' the rules that need the rest of the case study (each ground among the
#' vessel's `vesselsspe_fgrounds_quarter<N>.dat` grounds, each harbour a harbour
#' node). DISPLACE drops rows that break those, with a message on stdout.
#'
#' @param x A data frame with columns `vessel`, `quarter` (1-4), `pt_graph`
#'   (ground node, 0-based), `metier` (0-based metier index), `harbour`
#'   (harbour node, 0-based) and `weight` (positive, e.g. hours; DISPLACE
#'   normalises it).
#' @param input_dir Folder holding `vesselsspe_<input_name>/`.
#' @param input_name Parameterisation name (DISPLACE's `-f`).
#'
#' @return The paths written, invisibly.
#' @export
#' @examples
#' d <- tempfile()
#' dir.create(file.path(d, "vesselsspe_demo"), recursive = TRUE)
#' write_displace_fgrounds_harbours(
#'   data.frame(vessel = "V1", quarter = 1, pt_graph = c(10, 11), metier = 0,
#'              harbour = c(3, 4), weight = c(120, 30)),
#'   d, "demo")
write_displace_fgrounds_harbours <- function(x, input_dir, input_name) {
  need <- c("vessel", "quarter", "pt_graph", "metier", "harbour", "weight")
  miss <- setdiff(need, names(x))
  if (length(miss)) {
    stopf("x is missing column(s): %s", paste(miss, collapse = ", "))
  }
  x <- as.data.frame(x)[need]
  for (col in c("quarter", "pt_graph", "metier", "harbour")) {
    v <- x[[col]]
    if (anyNA(v) || any(v != round(v)) || any(v < 0)) {
      stopf("%s must be non-negative whole numbers.", col)
    }
    x[[col]] <- as.integer(v)
  }
  if (any(!x$quarter %in% 1:4)) {
    stopf("quarter must be 1, 2, 3 or 4.")
  }
  if (any(x$pt_graph > 65534L) || any(x$harbour > 65534L)) {
    stopf("node indices above 65534 do not fit DISPLACE's 16-bit node ids.")
  }
  if (anyNA(x$weight) || any(!is.finite(x$weight)) || any(x$weight <= 0)) {
    stopf("weight must be positive and finite; drop zero-weight rows instead.")
  }
  key <- paste(x$vessel, x$quarter, x$pt_graph, x$metier, x$harbour)
  if (anyDuplicated(key)) {
    stopf(paste0("x has %d duplicated vessel x quarter x pt_graph x metier x harbour ",
                 "rows; aggregate them (sum the weights) first."), sum(duplicated(key)))
  }
  dir <- file.path(input_dir, paste0("vesselsspe_", input_name))
  if (!dir.exists(dir)) {
    stopf("no such folder: %s", dir)
  }

  paths <- character()
  for (grp in split(x, list(x$vessel, x$quarter), drop = TRUE)) {
    p <- fgrounds_harbours_path(input_dir, input_name, grp$vessel[1], grp$quarter[1])
    body <- paste(grp$pt_graph, grp$metier, grp$harbour, fmt_num(grp$weight))
    writeLines(c(FGROUNDS_HARBOURS_HEADER, body), p)
    paths <- c(paths, p)
  }
  invisible(paths)
}

#' Read port-tagged fishing grounds
#'
#' Reads the `<vessel>_fgrounds_harbours_quarter<N>.dat` files of a case study
#' (see [write_displace_fgrounds_harbours()]) and adds the shares DISPLACE
#' derives from the weights.
#'
#' @param input_dir,input_name As for [run_displace()].
#' @param vessels Vessel ids to read. `NULL` reads every file present.
#' @param quarters Quarters to read.
#'
#' @return A data frame with `vessel`, `quarter`, `pt_graph`, `metier`,
#'   `harbour`, `weight`, plus `p_within_port` (the entry's probability once
#'   its harbour is the trip port) and `p_vessel` (its probability at
#'   departure, i.e. port share times `p_within_port`). Zero rows if no file
#'   exists.
#' @export
read_displace_fgrounds_harbours <- function(input_dir, input_name, vessels = NULL,
                                            quarters = 1:4) {
  dir <- file.path(input_dir, paste0("vesselsspe_", input_name))
  files <- list.files(dir, pattern = "_fgrounds_harbours_quarter[1-4]\\.dat$")
  vess <- sub("_fgrounds_harbours_quarter[1-4]\\.dat$", "", files)
  qs <- as.integer(sub(".*_quarter([1-4])\\.dat$", "\\1", files))
  keep <- qs %in% quarters & (is.null(vessels) | vess %in% vessels)
  out <- lapply(which(keep), function(i) {
    lines <- readLines(file.path(dir, files[i]), warn = FALSE)[-1]
    lines <- lines[nzchar(trim(lines))]
    if (!length(lines)) return(NULL)
    f <- strsplit(trim(lines), "[[:space:]]+")
    bad <- lengths(f) < 4L
    if (any(bad)) {
      stopf("%s: line %d does not have 4 fields", files[i], which(bad)[1] + 1L)
    }
    m <- do.call(rbind, lapply(f, `[`, 1:4))
    data.frame(vessel = vess[i], quarter = qs[i],
               pt_graph = as.integer(m[, 1]), metier = as.integer(m[, 2]),
               harbour = as.integer(m[, 3]), weight = as.numeric(m[, 4]),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, out)
  if (is.null(out)) {
    out <- data.frame(vessel = character(), quarter = integer(), pt_graph = integer(),
                      metier = integer(), harbour = integer(), weight = numeric(),
                      stringsAsFactors = FALSE)
  }
  vq <- paste(out$vessel, out$quarter)
  vqh <- paste(vq, out$harbour)
  out$p_within_port <- out$weight / stats::ave(out$weight, vqh, FUN = sum)
  out$p_vessel <- out$weight / stats::ave(out$weight, vq, FUN = sum)
  out <- out[order(out$vessel, out$quarter, out$harbour, out$pt_graph, out$metier), , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Check a grounds_by_port run
#'
#' Verifies, from a run's outputs, the properties the `grounds_by_port` option
#' promises:
#'
#' * `tagged`: trips of vessels with port-tagged entries carry a `trip_port`;
#' * `lands_at_trip_port`: the landing node (`idx_node`) is the trip port;
#' * `departs_from_last_landing`: each trip leaves from the port the vessel's
#'   previous trip landed at;
#' * `grounds_in_trip_port`: every node fished during the trip is a ground of
#'   the trip port's entries (in the quarter of departure or arrival);
#' * `metiers_in_trip_port`: every metier used during the trip is a metier of
#'   the trip port's entries;
#' * `port_shares` / `metier_shares`: per vessel, a chi-squared test of the
#'   trips per port and per trip metier against the input weights (expected
#'   counts follow each trip's departure quarter). Reported, not pass/fail
#'   decided: a small p-value flags a mismatch, but GoFishing decisions that
#'   depend on the metier, closures, and changes of ground during a trip (which
#'   can change the metier) all shift realised metier shares legitimately.
#'
#' Fished nodes come from the fishing pings (`state == 1`) of `vmslike`, matched
#' to the nearest graph node, so the run needs `huge = TRUE` (DISPLACE writes
#' `vmslike` only with `--huge=1`) and `export_vmslike = 10` (all years; `1`
#' exports the first year only). Run with `sqlite = FALSE`: with SQLite output on,
#' the simulator crashes during teardown before flushing the text files, which
#' truncates `vmslike`. Without fishing pings the two ground/metier checks have
#' nothing to check, and are reported as failed (`n_fail = NA`).
#'
#' @param x A `displace_run`, or an output directory.
#' @param input_dir,input_name,scenario The case study, as for [run_displace()].
#' @param sim_name Simulation name, when `x` is a directory.
#'
#' @return An object of class `displace_gbp_check`: a list with `summary` (one
#'   row per check: `check`, `n`, `n_fail`, `ok`), `trips` (one row per trip),
#'   `port_shares`, `metier_shares` and `entries`.
#' @export
check_grounds_by_port <- function(x, input_dir = NULL, input_name = NULL,
                                  scenario = NULL, sim_name = NULL) {
  if (inherits(x, "displace_run")) {
    input_dir <- input_dir %||% x$input_dir
    input_name <- input_name %||% x$input_name
    scenario <- scenario %||% x$scenario
    sim_name <- sim_name %||% x$sim_name
  }
  if (is.null(input_dir) || is.null(input_name)) {
    stopf("input_dir and input_name are required when x is not a displace_run.")
  }
  scenario <- scenario %||% "baseline"

  cfg <- read_displace_config(input_dir, input_name)
  sc <- read_displace_scenario(input_dir, input_name, scenario)
  if (!"grounds_by_port" %in% sc$dyn_alloc_sce) {
    warnf("scenario '%s' does not enable grounds_by_port.", scenario)
  }
  ll <- read_displace_loglike(x, cfg, sim_name = sim_name)
  if (!"trip_port" %in% names(ll)) {
    stopf(paste0("this loglike has no trip_port column: the run did not use a ",
                 "grounds-by-port build with the grounds_by_port option."))
  }
  entries <- read_displace_fgrounds_harbours(input_dir, input_name)

  ## Quarter of a time step, from the simulation calendar.
  qstarts <- read_calendar_starts(input_dir, input_name, "quarters")
  quarter_of <- function(t) (findInterval(t, qstarts) %% 4L) + 1L

  ll$trip <- seq_len(nrow(ll))
  ll$q_dep <- quarter_of(ll$tstep_dep)
  ll$q_arr <- quarter_of(ll$tstep_arr)
  ll$metiers_used <- lapply(as.character(ll$freq_metiers), parse_freq_metiers)

  ## Fished nodes per trip.
  vms <- read_displace_output(x, "vmslike", sim_name = sim_name)
  vms <- vms[vms$state == 1L, , drop = FALSE]
  g <- read_displace_graph(input_dir, sc, edges = FALSE)
  vms$node <- nearest_node(vms$x, vms$y, g$nodes)
  key_v <- paste(vms$name, vms$tstep_dep)
  fished <- split(vms$node, key_v)
  ll$nodes_fished <- unname(lapply(paste(ll$VE_REF, ll$tstep_dep),
                                   function(k) unique(fished[[k]] %||% integer())))

  has_entries <- unique(paste(entries$vessel, entries$quarter))
  ll$eligible <- paste(ll$VE_REF, ll$q_dep) %in% has_entries
  tagged <- ll$trip_port >= 0L

  ## Entries of a trip's port, in its departure or arrival quarter.
  port_rows <- function(i, field) {
    e <- entries[entries$vessel == ll$VE_REF[i] & entries$harbour == ll$trip_port[i] &
                   entries$quarter %in% c(ll$q_dep[i], ll$q_arr[i]), , drop = FALSE]
    e[[field]]
  }
  ll$grounds_ok <- vapply(seq_len(nrow(ll)), function(i) {
    !tagged[i] || all(ll$nodes_fished[[i]] %in% port_rows(i, "pt_graph"))
  }, logical(1))
  ll$metiers_ok <- vapply(seq_len(nrow(ll)), function(i) {
    !tagged[i] || !length(ll$nodes_fished[[i]]) ||
      all(ll$metiers_used[[i]] %in% port_rows(i, "metier"))
  }, logical(1))

  ## Departure port vs the previous trip's landing node, per vessel.
  ll <- ll[order(ll$VE_REF, ll$tstep_dep), , drop = FALSE]
  prev_land <- stats::ave(ll$idx_node, ll$VE_REF, FUN = function(v) c(NA, utils::head(v, -1L)))
  ll$prev_landing <- prev_land
  tagged <- ll$trip_port >= 0L
  dep_ok <- is.na(prev_land) | ll$dep_port == prev_land

  summary <- data.frame(
    check = c("tagged", "lands_at_trip_port", "departs_from_last_landing",
              "grounds_in_trip_port", "metiers_in_trip_port"),
    n = c(sum(ll$eligible), sum(tagged), sum(!is.na(prev_land)), sum(tagged), sum(tagged)),
    n_fail = c(sum(ll$eligible & !tagged),
               sum(tagged & ll$idx_node != ll$trip_port),
               sum(!dep_ok),
               sum(!ll$grounds_ok),
               sum(!ll$metiers_ok)),
    stringsAsFactors = FALSE
  )
  ## Without pings the ground and metier checks are vacuous: say so.
  if (!nrow(vms)) {
    summary$n_fail[summary$check %in% c("grounds_in_trip_port", "metiers_in_trip_port")] <- NA
  }
  summary$ok <- !is.na(summary$n_fail) & summary$n_fail == 0L

  ## Shares. Expected: each trip contributes its departure quarter's shares.
  tt <- ll[tagged, , drop = FALSE]
  tt$metier <- trip_metier(tt$freq_metiers)
  port_tab <- share_table(tt, entries, "trip_port", "harbour")
  met_tab <- share_table(tt, entries, "metier", "metier")

  structure(list(summary = summary, trips = ll, port_shares = port_tab,
                 metier_shares = met_tab, entries = entries),
            class = "displace_gbp_check")
}

#' @export
print.displace_gbp_check <- function(x, ...) {
  cat("<grounds_by_port check>", nrow(x$trips), "trips\n")
  print(x$summary, row.names = FALSE)
  pv <- function(tab) {
    if (!nrow(tab)) return("none")
    p <- unique(tab[c("vessel", "p_value")])
    sprintf("min p = %.3g over %d vessels", min(p$p_value, na.rm = TRUE), nrow(p))
  }
  cat("port shares:   ", pv(x$port_shares), "\n")
  cat("metier shares: ", pv(x$metier_shares), "\n")
  invisible(x)
}

## "M(3)_1:0.5_3:0.5" -> c(1L, 3L): metiers of the trip's fishing pings. The
## M(...) prefix is the vessel's metier when the trip ended.
parse_freq_metiers <- function(s) {
  parts <- strsplit(s, "_", fixed = TRUE)[[1]][-1]
  if (!length(parts)) return(integer())
  as.integer(sub(":.*$", "", parts))
}

## The trip's metier for the share test: the M(...) prefix.
trip_metier <- function(s) {
  as.integer(sub("^M\\(([0-9]+)\\).*$", "\\1", as.character(s)))
}

## Observed vs expected counts of `what` per vessel, and a chi-squared p-value.
share_table <- function(trips, entries, what, entry_col) {
  rows <- list()
  for (v in unique(trips$VE_REF)) {
    tv <- trips[trips$VE_REF == v, , drop = FALSE]
    ev <- entries[entries$vessel == v, , drop = FALSE]
    exp_share <- lapply(split(ev, ev$quarter), function(e) {
      tapply(e$p_vessel, e[[entry_col]], sum)
    })
    levels <- sort(unique(c(ev[[entry_col]], tv[[what]])))
    expected <- stats::setNames(numeric(length(levels)), levels)
    for (q in tv$q_dep) {
      s <- exp_share[[as.character(q)]]
      if (!is.null(s)) expected[names(s)] <- expected[names(s)] + s
    }
    observed <- table(factor(tv[[what]], levels = levels))
    p <- if (length(levels) > 1L && all(expected[expected > 0] > 0)) {
      pos <- expected > 0
      if (any(observed[!pos] > 0)) 0 else
        suppressWarnings(stats::chisq.test(as.numeric(observed[pos]),
                                           p = expected[pos] / sum(expected[pos]),
                                           simulate.p.value = TRUE, B = 2000)$p.value)
    } else NA_real_
    rows[[v]] <- data.frame(vessel = v, value = as.integer(levels),
                            observed = as.integer(observed),
                            expected = round(as.numeric(expected), 2),
                            share_obs = as.numeric(observed) / max(1, sum(observed)),
                            share_exp = as.numeric(expected) / max(1e-12, sum(expected)),
                            p_value = p, stringsAsFactors = FALSE)
  }
  out <- do.call(rbind, rows)
  if (is.null(out)) {
    out <- data.frame(vessel = character(), value = integer(), observed = integer(),
                      expected = numeric(), share_obs = numeric(), share_exp = numeric(),
                      p_value = numeric())
  }
  names(out)[names(out) == "value"] <- if (what == "trip_port") "harbour" else "metier"
  rownames(out) <- NULL
  out
}

## Index (0-based node id) of the graph node nearest each ping. vmslike prints
## coordinates to 3 decimals, so exact matching would fail on rounding.
nearest_node <- function(x, y, nodes) {
  if (!length(x)) return(integer())
  vapply(seq_along(x), function(i) {
    nodes$node_id[which.min((nodes$lon - x[i])^2 + (nodes$lat - y[i])^2)]
  }, integer(1))
}

## First time step of each period after the first, from tstep_<unit>.dat (or the
## *_2009_2015 fallback name the loader also accepts). -1 terminates the list.
read_calendar_starts <- function(input_dir, input_name, unit) {
  dir <- file.path(input_dir, paste0("simusspe_", input_name))
  cand <- file.path(dir, c(sprintf("tstep_%s.dat", unit), sprintf("tstep_%s_2009_2015.dat", unit)))
  hit <- cand[file.exists(cand)]
  if (!length(hit)) {
    stopf("no tstep_%s.dat calendar in %s", unit, dir)
  }
  v <- suppressWarnings(as.integer(trim(readLines(hit[1], warn = FALSE))))
  v <- v[!is.na(v)]
  v[v >= 0L]
}

## Feature patches of a binary, from the build-info.json build-displace.sh puts
## beside it (or the record install_displace() writes). character(0) for a plain
## upstream build, NA when it cannot be told.
binary_feature_patches <- function(binary) {
  dir <- dirname(binary)
  rec <- file.path(dir, "displaceR-install.txt")
  if (file.exists(rec)) {
    hit <- grep("^feature_patches: ", readLines(rec, warn = FALSE), value = TRUE)
    if (length(hit)) {
      v <- trim(sub("^feature_patches: ", "", hit[1]))
      return(if (nzchar(v) && v != "none") strsplit(v, "[[:space:]]+")[[1]] else character())
    }
  }
  info <- read_build_info(dir)
  if (!is.null(info)) {
    v <- info$feature_patches %||% ""
    return(if (nzchar(v)) strsplit(trim(v), "[[:space:]]+")[[1]] else character())
  }
  NA_character_
}

#' Feature patches compiled into a DISPLACE binary
#'
#' A build made with `tools/build-displace.sh --patch NAME` records `NAME` in
#' its `build-info.json`. This reads it back, so code can require, for example,
#' the `grounds-by-port` patch before running a scenario that needs it.
#'
#' @param binary Path to the `displace` executable. Defaults to
#'   [displace_path()].
#' @return A character vector of feature patch names: empty for a plain
#'   upstream build, `NA` if the binary carries no build record.
#' @export
#' @examples
#' \dontrun{
#' "grounds-by-port" %in% displace_features()
#' }
displace_features <- function(binary = NULL) {
  binary <- binary %||% displace_path()
  binary_feature_patches(binary)
}

## dyn_alloc_sce options that only a feature-patched build understands. The
## simulator ignores option names it does not know, so without this check such
## a scenario runs as plain baseline on an unpatched binary, silently.
FEATURE_OPTIONS <- c(grounds_by_port = "grounds-by-port",
                     out_of_range_implicit = "out-of-range-implicit",
                     shortest_paths = "shortest-paths")

check_binary_features <- function(binary, input_dir, input_name, scenario) {
  path <- simusspe_file(input_dir, input_name, paste0(scenario, ".dat"))
  if (!file.exists(path)) {
    return(invisible(TRUE))
  }
  sc <- tryCatch(read_displace_scenario(path = path), error = function(e) NULL)
  if (is.null(sc)) {
    return(invisible(TRUE))
  }
  wanted <- FEATURE_OPTIONS[names(FEATURE_OPTIONS) %in% sc$dyn_alloc_sce]
  if (!length(wanted)) {
    return(invisible(TRUE))
  }
  have <- binary_feature_patches(binary)
  missing <- if (identical(have, NA_character_)) wanted else wanted[!wanted %in% have]
  if (length(missing)) {
    stopf(paste0("scenario '%s' uses dyn_alloc_sce option(s) %s, which need a DISPLACE ",
                 "build with the feature patch(es) %s, but %s %s. An unpatched simulator ",
                 "ignores the option and runs plain baseline.\nBuild one with ",
                 "tools/build-displace.sh --ref v1.8.0 --patch %s --patch headless-ipc-lazy, or pass ",
                 "check_features = FALSE to run anyway."),
          scenario, paste(names(missing), collapse = ", "),
          paste(unname(missing), collapse = ", "), binary,
          if (identical(have, NA_character_)) "has no build record (build-info.json)"
          else sprintf("was built with: %s", if (length(have)) paste(have, collapse = ", ") else "none"),
          unname(missing[1]))
  }
  invisible(TRUE)
}
