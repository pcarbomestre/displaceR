## Phase 3 — the runner.
##
## The CLI is the entire API surface of the simulator. Argument names below are
## verified against simulator/main.cpp at upstream 7f2656fb; the short options
## are single-dash single-letter (boost::program_options style: "-f name"), not
## GNU long options.

## Default step counts, from the simulator's own calendar:
##   8762 steps ~= 1 year of hourly steps
##  52586 steps ~= 6 years, the practical upper bound upstream documents
STEPS_PER_YEAR <- 8762L
MAX_STEPS <- 52586L

#' Run the DISPLACE simulator
#'
#' Runs one simulation and returns a handle describing where its outputs went.
#' Pass that handle to [read_displace_db()] or [read_displace_output()].
#'
#' @param input_dir Path to the folder that *contains* the parameterisation
#'   subfolders (`simusspe_<name>/`, `vesselsspe_<name>/`, `graphsspe/`, ...).
#'   This is DISPLACE's `-a`. For the demo dataset this is the directory holding
#'   `DISPLACE_input_minitest`'s contents.
#' @param input_name Parameterisation name, DISPLACE's `-f`. This is the suffix
#'   on the `*spe_<name>` subfolders. Defaults to the basename of `input_dir`
#'   with a leading `DISPLACE_input_` stripped, which is the upstream convention.
#' @param scenario Scenario name, DISPLACE's `-F`. Must match a `.dat` file in
#'   `simusspe_<input_name>/`; `"baseline"` is the default scenario upstream
#'   ships.
#' @param sim_name Simulation name, DISPLACE's `-s`. Becomes part of every
#'   output filename, so use it to distinguish replicates.
#' @param steps Number of hourly steps, DISPLACE's `-i`. `8762` is about one
#'   year. Values above 52586 (about six years) are rejected by the simulator.
#' @param output_dir Where to write outputs, DISPLACE's `-O`. The simulator
#'   creates `<output_dir>/DISPLACE_outputs/<input_name>/<scenario>/` beneath
#'   it. Defaults to a session temporary directory.
#' @param num_threads Threads used to move vessels, DISPLACE's `--num_threads`.
#'   Note that DISPLACE parallelises internally: if you are also running
#'   replicates in parallel with `future`, the product of the two is what lands
#'   on the machine. On a shared server, leave this at 1 and parallelise over
#'   replicates instead.
#' @param sqlite Whether to write the SQLite output database. `TRUE` is
#'   strongly preferred — it is structured, and its schema version is a reliable
#'   dispatch key, unlike the text formats. `FALSE` passes `--disable-sqlite`.
#' @param commit_rate Loops before committing to SQLite, DISPLACE's
#'   `--commit-rate`. Larger values are faster and lose more on a crash.
#' @param export_vmslike Passed as `-e`. `1` exports VMS-like pings, `0`
#'   suppresses them. These are among the largest text outputs. `NULL` leaves
#'   the simulator's default, which is `1`.
#' @param huge Passed as `--huge`. Controls the very large exports. Note that
#'   the simulator's own default is *enabled*; this wrapper defaults to
#'   `FALSE` and always passes the flag explicitly, so `run_displace()` does not
#'   fill a disk by surprise.
#' @param static_paths Passed as `-p`. Use precomputed static paths rather than
#'   computing shortest paths at runtime. Requires the `shortPaths_*` caches to
#'   have been generated for this case study.
#' @param selected_vessels_only Passed as `-v`. `1` restricts the run to the
#'   subset of vessels flagged in the vessel features file.
#' @param verbosity Passed as `-V`.
#' @param dparam Passed as `-d`.
#' @param indb Read inputs from a SQLite database instead of the text file tree,
#'   DISPLACE's `--indb`. The path is interpreted by the simulator relative to
#'   `input_dir`.
#' @param extra_args Character vector of additional raw CLI arguments, for
#'   options this wrapper does not model. Passed through verbatim.
#' @param binary Path to the `displace` executable. Defaults to
#'   [displace_path()].
#' @param echo Stream the simulator's stdout to the console as it runs. Useful
#'   for long runs; set `FALSE` when running many replicates.
#' @param dry_run Build and return the handle without running anything. The
#'   `args` element then shows exactly what would be executed.
#' @param validate Run [validate_displace_input()] before launching. Cheap, and
#'   it catches the input errors that otherwise surface as an opaque simulator
#'   abort.
#'
#' @section Defaults that differ from the raw CLI:
#'
#' `--disable-crash-handler` is always passed: the handler is not useful in a
#' headless process and interferes with getting a clean exit status back to R.
#'
#' `--use-gui` is never passed and cannot be enabled through this function; it
#' opens an IPC channel to the desktop GUI and will hang a headless run.
#'
#' `--huge` is always passed explicitly, with the value `huge` implies. The
#' simulator defaults `export_hugefiles` to `1`, so omitting the flag leaves the
#' large exports *on*, while a bare `--huge` turns them *off* (its boost
#' implicit value is `0`). Neither is what a reader of the R argument would
#' expect, hence the explicit form.
#'
#' `num_threads` defaults to 1 here, against the simulator's own default of 4,
#' so that a plain `run_displace()` inside `future`/`furrr` workers does not
#' quietly oversubscribe a shared server.
#'
#' @return An object of class `displace_run`: a list with the resolved
#'   arguments, the output paths, exit status, elapsed time and captured
#'   output.
#'
#' @export
#' @examples
#' # Show the command line that would be run, without needing a binary:
#' run_displace(
#'   input_dir = tempdir(), input_name = "minitest",
#'   steps = 100, dry_run = TRUE, validate = FALSE,
#'   binary = "/path/to/displace"
#' )
run_displace <- function(input_dir,
                         input_name = NULL,
                         scenario = "baseline",
                         sim_name = "sim1",
                         steps = STEPS_PER_YEAR,
                         output_dir = NULL,
                         num_threads = 1L,
                         sqlite = TRUE,
                         commit_rate = NULL,
                         export_vmslike = NULL,
                         huge = FALSE,
                         static_paths = FALSE,
                         selected_vessels_only = NULL,
                         verbosity = NULL,
                         dparam = NULL,
                         indb = NULL,
                         extra_args = character(),
                         binary = NULL,
                         echo = TRUE,
                         dry_run = FALSE,
                         validate = TRUE) {

  if (missing(input_dir) || !length(input_dir)) {
    stopf("input_dir is required.")
  }
  input_dir <- normalizePath(path.expand(input_dir), mustWork = FALSE)
  if (!dry_run && !dir.exists(input_dir)) {
    stopf("input_dir does not exist: %s", input_dir)
  }

  input_name <- input_name %||% default_input_name(input_dir)

  steps <- as.integer(steps)
  if (is.na(steps) || steps < 1L) {
    stopf("steps must be a positive integer.")
  }
  if (steps > MAX_STEPS) {
    stopf(paste0("steps = %d exceeds the simulator's maximum of %d (about six ",
                 "years of hourly steps)."), steps, MAX_STEPS)
  }

  output_dir <- output_dir %||% file.path(tempdir(), "displaceR-run")
  output_dir <- path.expand(output_dir)

  ## The simulator is not consistently defensive about missing output paths:
  ## it will happily run and then fail to write. Create the full tree first.
  out_leaf <- file.path(output_dir, "DISPLACE_outputs", input_name, scenario)
  if (!dry_run) {
    dir.create(out_leaf, recursive = TRUE, showWarnings = FALSE)
    if (!dir.exists(out_leaf)) {
      stopf("could not create the output directory: %s", out_leaf)
    }
  }
  output_dir <- normalizePath(output_dir, mustWork = FALSE)
  out_leaf <- file.path(output_dir, "DISPLACE_outputs", input_name, scenario)

  ## With --indb the model is loaded from a SQLite database and the text file
  ## tree need not exist at all, so the structural checks would fail on a
  ## perfectly good case study.
  if (validate && !is.null(indb)) {
    db_file <- if (is_abs_path(indb)) indb else file.path(input_dir, indb)
    if (!file.exists(db_file)) {
      stopf(paste0("indb = '%s' does not resolve to a file (looked at %s). The ",
                   "simulator interprets this path relative to input_dir."),
            indb, db_file)
    }
    validate <- FALSE
  }

  if (validate && !dry_run) {
    v <- validate_displace_input(input_dir, input_name, scenario)
    if (!v$ok) {
      stopf("input validation failed:\n%s\n\nPass validate = FALSE to run anyway.",
            paste0("  - ", v$errors, collapse = "\n"))
    }
  }

  args <- displace_args(
    input_dir = input_dir, input_name = input_name, scenario = scenario,
    sim_name = sim_name, steps = steps, output_dir = output_dir,
    num_threads = num_threads, sqlite = sqlite, commit_rate = commit_rate,
    export_vmslike = export_vmslike, huge = huge, static_paths = static_paths,
    selected_vessels_only = selected_vessels_only, verbosity = verbosity,
    dparam = dparam, indb = indb, extra_args = extra_args
  )

  res <- structure(
    list(
      binary = NA_character_,
      args = args,
      command = NA_character_,
      input_dir = input_dir,
      input_name = input_name,
      scenario = scenario,
      sim_name = sim_name,
      steps = steps,
      output_dir = output_dir,
      output_path = out_leaf,
      db_path = file.path(out_leaf, sprintf("%s_%s_out.db", input_name, sim_name)),
      status = NA_integer_,
      elapsed = NA_real_,
      stdout = character(),
      started_at = NA,
      crashed_at_exit = FALSE,
      last_tstep = NA_integer_
    ),
    class = "displace_run"
  )

  res$binary <- binary %||% (if (dry_run) displace_path(error = FALSE) else displace_path())
  res$command <- paste(shQuote(res$binary %||% "displace"),
                       paste(shQuote(args), collapse = " "))

  if (dry_run) {
    return(res)
  }

  res$started_at <- Sys.time()
  t0 <- proc.time()[["elapsed"]]

  out <- if (echo) "" else TRUE
  captured <- suppressWarnings(
    system2(res$binary, args, stdout = out, stderr = out)
  )

  res$elapsed <- proc.time()[["elapsed"]] - t0

  if (echo) {
    ## With stdout = "" the output went straight to the console and system2
    ## returns the exit status.
    res$status <- as.integer(captured)
    res$stdout <- character()
  } else {
    res$stdout <- as.character(captured)
    st <- attr(captured, "status")
    res$status <- if (is.null(st)) 0L else as.integer(st)
  }

  if (!identical(res$status, 0L)) {
    ## DISPLACE segfaults during static destruction whenever SQLite output is
    ## enabled: a global shared_ptr<SQLiteOutputStorage> outlives the sqlite3
    ## library and double-finalizes its statements. The simulation itself has
    ## already finished and every output file, including the database, is
    ## written and intact. Verified at upstream 7f2656fb; `--disable-sqlite`
    ## exits 0 on the same input. See docs/upstream-issues.md.
    ##
    ## Treating this as a failure would make the package unusable for its
    ## primary output format, but blanket-ignoring a crash would hide real
    ## ones. So verify completion from the database itself before forgiving it.
    completion <- run_completed_cleanly(res)
    if (isTRUE(completion$completed)) {
      res$crashed_at_exit <- TRUE
      res$last_tstep <- completion$last_tstep
      warnf(paste0(
        "DISPLACE exited with status %d, but the run completed: the output ",
        "database is intact and reports lastTStep = %s for %d requested steps.\n",
        "This is a known upstream crash during static destruction that only ",
        "happens when SQLite output is enabled; the results are unaffected.\n",
        "Pass sqlite = FALSE to avoid it, at the cost of the database output."),
        res$status, format(completion$last_tstep), res$steps)
      return(res)
    }

    tail_out <- if (length(res$stdout)) {
      paste0("\nLast lines of output:\n",
             paste0("  ", utils::tail(res$stdout, 20), collapse = "\n"))
    } else {
      "\n(Run with echo = FALSE to capture the simulator's output.)"
    }
    stopf("DISPLACE exited with status %d.\nCommand: %s%s%s",
          res$status, res$command, tail_out,
          if (nzchar(completion$reason)) {
            paste0("\n\nCompletion check: ", completion$reason)
          } else "")
  }

  res
}

## Did the simulation actually finish, despite a non-zero exit status?
##
## The authority is the output database's Metadata table: the simulator writes
## lastTStep there as it goes, and createAllIndexes()/close() run at the very
## end of main(). An intact database whose lastTStep has reached the requested
## horizon means the work is done and only the teardown failed.
run_completed_cleanly <- function(res) {
  no <- function(reason) list(completed = FALSE, last_tstep = NA_integer_,
                              reason = reason)

  if (!file.exists(res$db_path)) {
    return(no(sprintf("no output database at %s, so the run cannot be confirmed complete.",
                      res$db_path)))
  }
  if (!requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("RSQLite", quietly = TRUE)) {
    return(no(paste0("an output database exists but DBI/RSQLite are not ",
                     "installed, so it cannot be checked. Install them to let ",
                     "displaceR distinguish a completed run from a real crash.")))
  }

  out <- tryCatch({
    con <- DBI::dbConnect(RSQLite::SQLite(), res$db_path, flags = RSQLite::SQLITE_RO)
    on.exit(DBI::dbDisconnect(con), add = TRUE)

    if (!identical(DBI::dbGetQuery(con, "PRAGMA integrity_check")[[1]][1], "ok")) {
      return(no("the output database fails PRAGMA integrity_check."))
    }
    if (!DBI::dbExistsTable(con, "Metadata")) {
      return(no("the output database has no Metadata table."))
    }
    md <- DBI::dbReadTable(con, "Metadata")
    hit <- which(as.character(md[[1]]) == "lastTStep")
    if (!length(hit)) {
      return(no("the output database's Metadata has no lastTStep entry."))
    }
    last <- suppressWarnings(as.integer(md[[2]][hit[1]]))
    if (is.na(last)) {
      return(no("the output database's lastTStep is not an integer."))
    }
    ## The simulator's last written step is steps - 1. Allow it to fall short
    ## by one for off-by-one differences in how the final step is recorded, but
    ## not further: a run that died halfway must still be reported as failed.
    if (last < res$steps - 2L) {
      return(no(sprintf(paste0("the run stopped at tstep %d of %d requested, so ",
                               "it did not finish."), last, res$steps)))
    }
    list(completed = TRUE, last_tstep = last, reason = "")
  }, error = function(e) {
    no(sprintf("the output database could not be read: %s", conditionMessage(e)))
  })

  out
}

#' Build the DISPLACE command line
#'
#' Exposed separately from [run_displace()] so a command line can be inspected,
#' logged, or handed to a scheduler without running anything. Arguments are as
#' documented in [run_displace()].
#'
#' @inheritParams run_displace
#' @return A character vector of arguments, suitable for [system2()].
#' @export
#' @examples
#' displace_args("/data/minitest", "minitest", steps = 100)
displace_args <- function(input_dir,
                          input_name,
                          scenario = "baseline",
                          sim_name = "sim1",
                          steps = STEPS_PER_YEAR,
                          output_dir = ".",
                          num_threads = 1L,
                          sqlite = TRUE,
                          commit_rate = NULL,
                          export_vmslike = NULL,
                          huge = FALSE,
                          static_paths = FALSE,
                          selected_vessels_only = NULL,
                          verbosity = NULL,
                          dparam = NULL,
                          indb = NULL,
                          extra_args = character()) {

  args <- c(
    "-f", input_name,
    "-F", scenario,
    "-a", input_dir,
    "-O", output_dir,
    "-s", sim_name,
    "-i", as.character(as.integer(steps))
  )

  add <- function(args, flag, value) {
    if (is.null(value)) args else c(args, flag, as.character(value))
  }

  args <- add(args, "-V", verbosity)
  args <- add(args, "-d", dparam)
  args <- add(args, "--num_threads", if (!is.null(num_threads)) as.integer(num_threads))
  args <- add(args, "--commit-rate", if (!is.null(commit_rate)) as.integer(commit_rate))
  args <- add(args, "--indb", indb)

  ## Options declared with boost implicit_value() must carry their value
  ## *adjacent* to the flag. "-p 1" would set use_static_paths to the implicit
  ## 0 and then choke on "1" as an unexpected positional argument. Upstream
  ## declares -p, -e, -v and --huge this way.
  adj <- function(args, flag, value, sep = "") {
    if (is.null(value)) args else c(args, paste0(flag, sep, as.integer(value)))
  }

  args <- adj(args, "-e", export_vmslike)
  args <- adj(args, "-v", selected_vessels_only)
  args <- adj(args, "-p", static_paths)

  ## --huge is always emitted explicitly. Upstream's default for
  ## export_hugefiles is 1 (on) while the flag's implicit value is 0, so a bare
  ## "--huge" *disables* huge exports and omitting it leaves them *enabled*.
  ## Being explicit is the only way to make the R-side default mean what it says.
  args <- c(args, paste0("--huge=", as.integer(isTRUE(huge))))

  if (!isTRUE(sqlite)) {
    args <- c(args, "--disable-sqlite")
  }

  ## Always. The crash handler is unhelpful headless and muddies the exit status.
  args <- c(args, "--disable-crash-handler")

  if (length(extra_args)) {
    if (any(grepl("^--use-gui", extra_args))) {
      stopf(paste0("--use-gui opens an IPC channel to the desktop GUI and will ",
                   "hang a headless run. Refusing to pass it."))
    }
    args <- c(args, as.character(extra_args))
  }

  args
}

## Upstream's convention is a folder called DISPLACE_input_<name>, with the
## parameterisation name being <name>.
default_input_name <- function(input_dir) {
  base <- basename(sub("/+$", "", input_dir))
  sub("^DISPLACE_input_", "", base)
}

#' @export
print.displace_run <- function(x, ...) {
  cat("<displace_run>\n")
  cat("  input:    ", x$input_dir, " (-f ", x$input_name, ")\n", sep = "")
  cat("  scenario: ", x$scenario, "   simulation: ", x$sim_name, "\n", sep = "")
  cat("  steps:    ", x$steps, sprintf(" (~%.2f years)", x$steps / STEPS_PER_YEAR), "\n", sep = "")
  cat("  outputs:  ", x$output_path, "\n", sep = "")
  if (!is.na(x$status)) {
    cat("  status:   ", x$status,
        if (isTRUE(x$crashed_at_exit)) " (completed; crashed in teardown)" else "",
        sprintf("   elapsed: %.1fs", x$elapsed), "\n", sep = "")
    cat("  database: ", x$db_path,
        if (file.exists(x$db_path)) "" else "  (not written)", "\n", sep = "")
  } else {
    cat("  status:    not run\n")
    cat("  command:  ", x$command, "\n", sep = "")
  }
  invisible(x)
}
