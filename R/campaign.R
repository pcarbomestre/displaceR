## Running a campaign of replicates to completion.
##
## DISPLACE fails partway through a long run often enough that a single pass
## over N replicates reliably leaves gaps. The established workaround, and the
## shape this file reproduces, is the run_displace.py / check_displace.py pair
## that ships with the west coast case study: scan the outputs, work out which
## replicates fell short, re-run only those, and repeat until none are left.
##
## Two things in that script are worth preserving exactly.
##
## First, completeness is judged from the *last timestep actually written*, not
## from the exit status. DISPLACE segfaults during teardown on every SQLite run
## (docs/upstream-issues.md 3), so the status says nothing; and a run killed
## halfway still exits leaving a plausible-looking file behind.
##
## Second, the check allows a margin, and the margin is not a rounding
## tolerance -- it is the whole basis of the test. Replicates legitimately stop
## at different timesteps: the last recorded event depends on which vessels
## were still active and how many there are, so two perfectly good runs of the
## same 87673-step configuration end hundreds of steps apart. There is no exact
## target to compare against.
##
## So "complete" means "got close enough to the target", and the useful signal
## is that finished replicates cluster near it while failed ones fall far
## short. The upstream script uses a margin of 1000 out of 87673 -- a little
## over 1% -- and that default is kept here.

#' Check whether a replicate's outputs look complete
#'
#' Reads the last timestep recorded in `vmslike_<sim_name>.dat` and compares it
#' against the requested step count. This is the check DISPLACE itself does not
#' provide: the process exit status is unreliable (it crashes in teardown on
#' every SQLite run), and a run that died halfway leaves a file behind that
#' looks normal until you read the end of it.
#'
#' @param output_path Directory holding the outputs, i.e.
#'   `<output_dir>/DISPLACE_outputs/<input_name>/<scenario>`. A `displace_run`
#'   may be passed instead.
#' @param sim_name Simulation name, e.g. `"simu1"`.
#' @param steps Requested number of steps.
#' @param margin How far below `steps` still counts as complete. This is not a
#'   rounding tolerance: replicates genuinely end at different timesteps
#'   depending on which vessels were still active and how many there are, so
#'   there is no exact value to test for. Completed replicates cluster near the
#'   target while failed ones fall far short, and the margin separates the two.
#'   The default of 1000 matches the upstream runner (a little over 1% of an
#'   87673-step run); scale it to your own step count.
#'
#' @return A list with `complete` (logical), `last_tstep` (integer or `NA`) and
#'   `status`, one of `"complete"`, `"incomplete"`, `"empty"`, `"missing"` or
#'   `"unreadable"`.
#' @export
#' @examples
#' \dontrun{
#' replicate_status(res, "simu1", steps = 87673)
#' }
replicate_status <- function(output_path, sim_name, steps, margin = 1000L) {
  if (inherits(output_path, "displace_run")) {
    sim_name <- sim_name %||% output_path$sim_name
    steps <- steps %||% output_path$steps
    output_path <- output_path$output_path
  }
  steps <- as.integer(steps)
  margin <- as.integer(margin)

  out <- function(status, last = NA_integer_) {
    list(complete = identical(status, "complete"), last_tstep = last,
         status = status)
  }

  ## Which file, and which column, carries the progress signal depends on how
  ## the run was configured -- so try several rather than trusting one.
  ##
  ## The upstream Python runner reads vmslike_*.dat column 1. That works for a
  ## production run, which passes -e 10 so vessel pings are exported
  ## throughout. Without it, vmslike holds only the initial positions and every
  ## row is tstep 0, which would mark a perfectly good run as failed at step 0.
  ## loglike_*.dat is the better primary signal: it gains a row per completed
  ## trip regardless of -e, and its column 2 is the arrival tstep.
  ##
  ## Both are still only written when a vessel does something, so on a run too
  ## short for any trip to finish neither advances. That is reported honestly
  ## as "empty" rather than guessed at.
  sources <- list(
    list(file = sprintf("loglike_%s.dat", sim_name), col = 2L),
    list(file = sprintf("vmslike_%s.dat", sim_name), col = 1L),
    list(file = sprintf("popstats_%s.dat", sim_name), col = 1L)
  )
  best <- NA_integer_
  seen_any <- FALSE
  for (s in sources) {
    p <- file.path(output_path, s$file)
    if (!file.exists(p)) next
    seen_any <- TRUE
    if (file.size(p) == 0) next
    v <- tail_field(p, s$col)
    if (!is.na(v) && (is.na(best) || v > best)) best <- v
  }
  if (!seen_any) return(out("missing"))
  if (is.na(best)) return(out("empty"))
  return(if (best >= steps - margin) out("complete", best) else out("incomplete", best))
}

## Read the last non-blank line of `path` and return field `col` as an integer,
## or NA. Seeks to the end rather than reading the file: these run to hundreds
## of megabytes on a real case study.
tail_field <- function(path, col) {
  tryCatch({
    con <- file(path, "rb")
    on.exit(close(con), add = TRUE)
    size <- file.size(path)
    chunk <- min(65536, size)
    seek(con, where = size - chunk, origin = "start")
    raw <- readBin(con, "raw", n = chunk)
    txt <- rawToChar(raw)
    Encoding(txt) <- "bytes"
    lines <- strsplit(txt, "\r?\n")[[1]]
    lines <- lines[nzchar(trimws(lines))]
    if (!length(lines)) return(NA_integer_)
    fields <- strsplit(trimws(lines[[length(lines)]]), "[[:space:]]+")[[1]]
    if (length(fields) < col) return(NA_integer_)
    v <- suppressWarnings(as.numeric(fields[[col]]))
    if (is.na(v)) NA_integer_ else as.integer(v)
  }, error = function(e) NA_integer_)
}

#' Summarise how far each replicate got
#'
#' Reports the last recorded timestep for every replicate in an output tree,
#' without running or changing anything -- the equivalent of the
#' `check_displace.py` checker that ships with the west coast case study.
#'
#' Because replicates legitimately end at different timesteps, the useful thing
#' to look at is the *spread*: completed runs cluster within a few hundred
#' steps of each other, and a run that failed sits far below that cluster. The
#' `gap_to_best` column makes that visible directly, so a margin can be chosen
#' from the data rather than guessed.
#'
#' @param output_path Directory holding the outputs, or a `displace_run`.
#' @param sim_names Replicate names to check.
#' @param steps Requested step count.
#' @param margin Completeness margin, see [replicate_status()].
#'
#' @return A data frame with one row per replicate: `sim_name`, `status`,
#'   `last_tstep`, `complete`, and `gap_to_best` (how far short of the furthest
#'   replicate this one stopped).
#' @export
#' @examples
#' \dontrun{
#' check_displace_replicates(camp$output_path, sprintf("simu%d", 1:30), 87673)
#' }
check_displace_replicates <- function(output_path, sim_names, steps,
                                      margin = 1000L) {
  if (inherits(output_path, "displace_run")) output_path <- output_path$output_path
  st <- lapply(sim_names, function(nm) replicate_status(output_path, nm, steps, margin))
  last <- vapply(st, function(x) x$last_tstep, integer(1))
  best <- if (all(is.na(last))) NA_integer_ else max(last, na.rm = TRUE)
  data.frame(
    sim_name = sim_names,
    status = vapply(st, function(x) x$status, character(1)),
    last_tstep = last,
    complete = vapply(st, function(x) x$complete, logical(1)),
    gap_to_best = best - last,
    stringsAsFactors = FALSE
  )
}

#' Run replicates until they all complete
#'
#' Runs `n` replicates, checks which ones finished, re-runs the ones that did
#' not, and repeats until all are complete or `max_passes` is reached. This is
#' the R equivalent of the `run_displace.py` runner that ships with the west
#' coast case study.
#'
#' Long DISPLACE runs fail partway often enough that a single pass over many
#' replicates normally leaves gaps, and the failures are silent: the process
#' exits, output files exist, and only the last timestep in
#' `vmslike_<sim>.dat` reveals that the run stopped early. See
#' [replicate_status()].
#'
#' @param n Number of replicates.
#' @param steps Number of steps, passed to [run_displace()]. Required here
#'   because completeness cannot be judged without it.
#' @param ... Passed to [run_displace()] (`input_dir`, `input_name`,
#'   `scenario`, `num_threads`, `sqlite`, ...).
#' @param sim_names Simulation names. Defaults to `simu1..simuN`, matching the
#'   upstream convention. DISPLACE seeds its RNG from this name, so they must
#'   be unique.
#' @param output_dir Where outputs go. Every replicate writes into the same
#'   tree, exactly as the upstream `.bat` does, so a resumed campaign can see
#'   what earlier passes produced. Strongly recommended: the default is a
#'   temporary directory that disappears when R exits.
#' @param margin Completeness margin, see [replicate_status()].
#' @param max_passes Give up after this many passes. Guards against a
#'   replicate that fails deterministically, which would otherwise loop for
#'   ever.
#' @param map Optional mapper for parallelism, as in
#'   [run_displace_replicates()]. Note DISPLACE threads vessel movement
#'   internally, so the load is the product of the two.
#' @param quiet Suppress progress messages.
#'
#' @return A list with `runs` (named list of the last `displace_run` per
#'   replicate, `NULL` where every attempt errored), `status` (a data frame of
#'   the final state of each replicate) and `passes` (how many were needed).
#' @export
#' @examples
#' \dontrun{
#' camp <- run_displace_campaign(
#'   n = 30, steps = 87673,
#'   input_dir  = "/data/DISPLACE_input_westcoast_pscenario_1.0",
#'   input_name = "westcoast_pscenario_1.0",
#'   scenario   = "baseline",
#'   output_dir = "~/displace-runs/baseline",
#'   num_threads = 3, sqlite = FALSE
#' )
#' camp$status
#' }
run_displace_campaign <- function(n,
                                  steps,
                                  ...,
                                  sim_names = NULL,
                                  output_dir = NULL,
                                  margin = 1000L,
                                  max_passes = 10L,
                                  map = NULL,
                                  quiet = FALSE) {
  n <- as.integer(n)
  if (is.na(n) || n < 1L) stopf("n must be a positive integer.")
  steps <- as.integer(steps)
  if (is.na(steps) || steps < 1L) stopf("steps must be a positive integer.")

  dots <- list(...)
  if ("sim_name" %in% names(dots)) {
    stopf("do not pass sim_name to run_displace_campaign(); use sim_names.")
  }

  ## simu1..simuN rather than sim1..simN: the upstream scheduler, the .dsf
  ## files and the Python runner all assume that spelling, and matching it
  ## means an existing output tree is recognised rather than re-run.
  sim_names <- sim_names %||% sprintf("simu%d", seq_len(n))
  if (length(sim_names) != n) {
    stopf("sim_names has length %d but n is %d", length(sim_names), n)
  }
  if (anyDuplicated(sim_names)) {
    stopf(paste0("sim_names must be unique: DISPLACE seeds its RNG from the ",
                 "simulation name, so duplicates produce identical replicates."))
  }

  if (is.null(output_dir)) {
    output_dir <- file.path(tempdir(), "displaceR-campaign")
    if (!quiet) {
      msgf(paste0("output_dir not set; using %s, which is deleted when R ",
                  "exits. Set it for a real campaign."), output_dir)
    }
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  map <- map %||% function(i, sim_name, run_fn) run_fn()

  ## Every replicate shares one output tree, as the upstream .bat does. That is
  ## what lets a campaign resume: replicates already complete on disk are
  ## detected and skipped rather than recomputed.
  leaf <- function() {
    input_name <- dots$input_name
    scenario <- dots$scenario %||% "baseline"
    file.path(output_dir, "DISPLACE_outputs", input_name, scenario)
  }

  runs <- stats::setNames(vector("list", n), sim_names)
  pass <- 0L

  repeat {
    pass <- pass + 1L

    st <- lapply(sim_names, function(nm) replicate_status(leaf(), nm, steps, margin))
    names(st) <- sim_names
    todo <- sim_names[!vapply(st, function(x) x$complete, logical(1))]

    if (!length(todo)) {
      if (!quiet) msgf("all %d replicates complete after %d pass(es).", n, pass - 1L)
      break
    }
    if (pass > max_passes) {
      warnf(paste0("giving up after %d passes with %d replicate(s) still ",
                   "incomplete: %s. Inspect the outputs, or raise max_passes."),
            max_passes, length(todo), paste(todo, collapse = ", "))
      break
    }

    if (!quiet) {
      msgf("pass %d: %d of %d replicate(s) to run (%s)", pass, length(todo), n,
           paste(utils::head(todo, 5), collapse = ", "))
    }

    for (i in seq_along(todo)) {
      nm <- todo[[i]]
      run_fn <- local({
        nm_i <- nm
        function() {
          args <- c(dots, list(sim_name = nm_i, steps = steps,
                               output_dir = output_dir))
          if (is.null(args$echo)) args$echo <- FALSE
          ## A replicate that errors must not abort the campaign: that is the
          ## whole point of retrying. Record it and let the next pass decide.
          tryCatch(do.call(run_displace, args),
                   error = function(e) {
                     warnf("replicate %s failed: %s", nm_i, conditionMessage(e))
                     NULL
                   })
        }
      })
      r <- map(i, nm, run_fn)
      if (!is.null(r)) runs[[nm]] <- r
    }
  }

  final <- lapply(sim_names, function(nm) replicate_status(leaf(), nm, steps, margin))
  status <- data.frame(
    sim_name = sim_names,
    status = vapply(final, function(x) x$status, character(1)),
    last_tstep = vapply(final, function(x) x$last_tstep, integer(1)),
    complete = vapply(final, function(x) x$complete, logical(1)),
    stringsAsFactors = FALSE
  )

  list(runs = runs, status = status, passes = pass - 1L, output_path = leaf())
}
