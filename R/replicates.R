## Replicate runs.
##
## DISPLACE writes into <outdir>/DISPLACE_outputs/<f>/<F>/ with filenames keyed
## by the simulation name, so replicates that share an output directory but
## differ in `sim_name` do not collide. Giving each replicate its own output
## directory as well is still worth it: it keeps a failed replicate from
## leaving half-written files next to good ones, and it makes cleanup a single
## unlink().

#' Run several DISPLACE replicates
#'
#' Runs the same configuration `n` times with different simulation names.
#' DISPLACE seeds its random number generator from the simulation name
#' (`SimModel::initRandom(namesimu)`), so distinct names are what makes
#' replicates distinct.
#'
#' @param n Number of replicates.
#' @param ... Passed to [run_displace()]. Do not pass `sim_name`; it is
#'   generated per replicate.
#' @param sim_names Names to use. Defaults to `sim1`...`simN`, matching
#'   upstream's convention.
#' @param output_dir Parent output directory. Each replicate gets its own
#'   subdirectory beneath it.
#' @param map A function taking `(index, sim_name, run_fn)` and returning the
#'   result of calling `run_fn()`. The default runs replicates sequentially.
#'   To parallelise, pass something built on `future`:
#'
#'   ```r
#'   library(future); library(furrr)
#'   plan(multisession, workers = 4)
#'   run_displace_replicates(
#'     n = 8, input_dir = "input", input_name = "minitest",
#'     map = function(i, nm, f) f()   # furrr handles the parallelism below
#'   )
#'   ```
#'
#'   See the details section for the thread-count caveat.
#' @param quiet Suppress per-replicate progress messages.
#'
#' @details
#' DISPLACE already parallelises vessel movement internally via
#' `--num_threads`. If you also run replicates in parallel, the load on the
#' machine is the product of the two. [run_displace()] defaults `num_threads`
#' to 1 for that reason; keep it there when parallelising over replicates, and
#' raise it only for a single long run.
#'
#' @return A list of `displace_run` objects, one per replicate.
#' @export
#' @examples
#' \dontrun{
#' runs <- run_displace_replicates(
#'   n = 4, input_dir = "input", input_name = "minitest", steps = 8762
#' )
#' vapply(runs, function(r) r$elapsed, numeric(1))
#' }
run_displace_replicates <- function(n,
                                    ...,
                                    sim_names = NULL,
                                    output_dir = NULL,
                                    map = NULL,
                                    quiet = FALSE) {
  n <- as.integer(n)
  if (is.na(n) || n < 1L) {
    stopf("n must be a positive integer.")
  }
  dots <- list(...)
  if ("sim_name" %in% names(dots)) {
    stopf("do not pass sim_name to run_displace_replicates(); use sim_names.")
  }

  sim_names <- sim_names %||% sprintf("sim%d", seq_len(n))
  if (length(sim_names) != n) {
    stopf("sim_names has length %d but n is %d", length(sim_names), n)
  }
  if (anyDuplicated(sim_names)) {
    stopf(paste0("sim_names must be unique: DISPLACE seeds its RNG from the ",
                 "simulation name, so duplicates produce identical replicates."))
  }

  output_dir <- output_dir %||% file.path(tempdir(), "displaceR-replicates")
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  map <- map %||% function(i, sim_name, run_fn) run_fn()

  results <- vector("list", n)
  for (i in seq_len(n)) {
    nm <- sim_names[i]
    rep_dir <- file.path(output_dir, nm)
    run_fn <- local({
      nm_i <- nm
      dir_i <- rep_dir
      function() {
        args <- c(dots, list(sim_name = nm_i, output_dir = dir_i))
        ## Replicates are usually many and noisy; let the caller opt back in.
        if (is.null(args$echo)) args$echo <- FALSE
        do.call(run_displace, args)
      }
    })
    if (!quiet) {
      msgf("replicate %d/%d (%s)", i, n, nm)
    }
    results[[i]] <- map(i, nm, run_fn)
  }
  names(results) <- sim_names
  results
}
