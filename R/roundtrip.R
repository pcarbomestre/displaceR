## Verifying that a writer is faithful.
##
## The lesson from checking displaceR's own writers against
## DISPLACE_input_minitest is that a writer can produce syntactically valid
## files, load without complaint, and still change the model -- a header eaten
## here, a lost trailing record there. Reading the file back and comparing in R
## does not catch it either, because a reader and its matching writer share
## their assumptions and a wrong pair round-trips perfectly.
##
## The only test that settles it is: rewrite the inputs, run the simulator on
## both trees, and compare the outputs. That is what this does.
##
## One complication makes a naive comparison useless. DISPLACE is *not*
## reproducible run to run: with the same inputs, the same simulation name and
## the same step count, roughly a third of its text outputs differ between two
## runs. So the comparison has to establish which outputs are stable first, by
## running the reference inputs twice, and then compare only those.

#' Check that rewritten inputs still produce the same results
#'
#' Runs the simulator on an original case study and on a modified copy of it,
#' and reports whether the results agree. Use it to verify that anything which
#' rewrites DISPLACE inputs -- this package's writers, your own code, a
#' hand-edit -- has not quietly changed the model.
#'
#' @section Why this is not just "diff the files":
#'
#' A writer and its matching reader share their assumptions, so a wrong pair
#' round-trips through R perfectly while still corrupting the file. And the
#' files legitimately differ in ways that do not matter: trailing blank lines,
#' a missing final newline, `1.0` versus `1`. Only the simulator's own output
#' settles it.
#'
#' @section Why the reference is run twice:
#'
#' DISPLACE is not reproducible. Given identical inputs, an identical
#' `sim_name` and an identical step count, about a third of its text outputs
#' still differ between two runs. This function therefore runs the reference
#' twice to find which outputs are stable, and compares only those. Outputs
#' that vary on their own tell you nothing about your edit.
#'
#' @param reference_dir Input folder to treat as the reference.
#' @param modified_dir Input folder to compare against it.
#' @param input_name,scenario,steps As in [run_displace()]. Keep `steps` small:
#'   this runs the simulator three times.
#' @param sim_name Simulation name used for all three runs. It must be the same
#'   for all of them, since DISPLACE seeds from it.
#' @param binary Path to the simulator. Defaults to [displace_path()].
#' @param quiet Suppress progress messages.
#'
#' @return An object of class `displace_roundtrip`: a list with `ok`,
#'   `stable` (outputs reproducible between the two reference runs),
#'   `unstable`, `identical` and `differing` (among the stable ones).
#'
#' @export
#' @examples
#' \dontrun{
#' # Rewrite a case study, then prove the rewrite was faithful:
#' file.copy("case", "case_rewritten", recursive = TRUE)
#' # ... modify case_rewritten via displaceR writers ...
#' check_displace_roundtrip("case", "case_rewritten", "fake", steps = 2000)
#' }
check_displace_roundtrip <- function(reference_dir,
                                     modified_dir,
                                     input_name,
                                     scenario = "baseline",
                                     steps = 2000,
                                     sim_name = "rtcheck",
                                     binary = NULL,
                                     quiet = FALSE) {
  binary <- binary %||% displace_path()
  for (d in c(reference_dir, modified_dir)) {
    if (!dir.exists(d)) {
      stopf("no such input folder: %s", d)
    }
  }

  run_into <- function(input_dir, label) {
    out <- file.path(tempfile("displace-rt-"), label)
    dir.create(out, recursive = TRUE, showWarnings = FALSE)
    if (!quiet) {
      msgf("  running %s ...", label)
    }
    ## validate = FALSE: the point is to compare, not to gate. A tree that
    ## fails validation is still worth comparing, and run_displace() would
    ## refuse it.
    ##
    ## A modified tree that will not load at all is a result, not an error --
    ## it is the loudest possible answer to "did my rewrite break this" -- so
    ## catch it and report rather than throwing out of the check.
    tryCatch(
      suppressWarnings(run_displace(
        input_dir = input_dir, input_name = input_name, scenario = scenario,
        sim_name = sim_name, steps = steps, output_dir = out,
        binary = binary, echo = FALSE, verbosity = 0, validate = FALSE
      )),
      error = function(e) {
        structure(list(failed = TRUE, output_path = out,
                       message = conditionMessage(e)),
                  class = "displace_run_failure")
      }
    )
  }

  if (!quiet) {
    msgf("Checking whether rewritten inputs change the results.")
    msgf("DISPLACE is not reproducible run to run, so the reference is run")
    msgf("twice first to find which outputs are stable.")
  }

  ref_a <- run_into(reference_dir, "reference-1")
  ref_b <- run_into(reference_dir, "reference-2")
  if (inherits(ref_a, "displace_run_failure") ||
      inherits(ref_b, "displace_run_failure")) {
    stopf(paste0("the reference inputs themselves will not run, so there is ",
                 "nothing to compare against:\n%s"),
          (ref_a$message %||% ref_b$message))
  }

  mod <- run_into(modified_dir, "modified")
  if (inherits(mod, "displace_run_failure")) {
    out <- structure(
      list(ok = FALSE, load_failed = TRUE, message = mod$message,
           stable = character(), unstable = character(),
           identical = character(), differing = character(), steps = steps),
      class = "displace_roundtrip"
    )
    if (!quiet) {
      print(out)
    }
    return(invisible(out))
  }

  files_in <- function(res) {
    fs <- list.files(res$output_path, pattern = "\\.dat$")
    sort(fs)
  }
  common <- Reduce(intersect, list(files_in(ref_a), files_in(ref_b), files_in(mod)))

  same_file <- function(res1, res2, nm) {
    f1 <- file.path(res1$output_path, nm)
    f2 <- file.path(res2$output_path, nm)
    if (!file.exists(f1) || !file.exists(f2)) {
      return(FALSE)
    }
    identical(readLines(f1, warn = FALSE), readLines(f2, warn = FALSE))
  }

  stable <- common[vapply(common, function(nm) same_file(ref_a, ref_b, nm),
                          logical(1))]
  unstable <- setdiff(common, stable)

  agree <- stable[vapply(stable, function(nm) same_file(ref_a, mod, nm),
                         logical(1))]
  differ <- setdiff(stable, agree)

  out <- structure(
    list(ok = length(differ) == 0L,
         stable = stable, unstable = unstable,
         identical = agree, differing = differ,
         steps = steps),
    class = "displace_roundtrip"
  )
  if (!quiet) {
    print(out)
  }
  invisible(out)
}

#' @export
print.displace_roundtrip <- function(x, ...) {
  cat("<displace_roundtrip>\n")
  if (isTRUE(x$load_failed)) {
    cat("  The modified inputs do not load at all.\n\n")
    cat("  ", gsub("\n", "\n  ", trim(x$message)), "\n\n", sep = "")
    cat("  The rewrite is not faithful; the simulator rejected it outright.\n")
    return(invisible(x))
  }
  cat("  steps:                    ", x$steps, "\n", sep = "")
  cat("  reproducible outputs:     ", length(x$stable), "\n", sep = "")
  cat("  not reproducible (ignored):", length(x$unstable), "\n", sep = "")
  cat("  of the reproducible ones:\n")
  cat("    identical:              ", length(x$identical), "\n", sep = "")
  cat("    differing:              ", length(x$differing), "\n", sep = "")
  if (length(x$differing)) {
    cat("\n  The rewrite changed the model. Outputs affected:\n")
    for (f in utils::head(x$differing, 15)) {
      cat("    ", f, "\n", sep = "")
    }
    if (length(x$differing) > 15) {
      cat("    ... and ", length(x$differing) - 15, " more\n", sep = "")
    }
    cat("\n  Bisect by rewriting one input folder at a time to find the cause.\n")
  } else {
    cat("\n  The rewrite is faithful: every reproducible output is unchanged.\n")
  }
  invisible(x)
}
