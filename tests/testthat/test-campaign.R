## The campaign runner reproduces the run_displace.py / check_displace.py pair
## that ships with the west coast case study: judge completeness from the last
## timestep written, re-run whatever fell short, repeat.

make_output_leaf <- function(dir = tempfile()) {
  leaf <- file.path(dir, "DISPLACE_outputs", "case", "baseline")
  dir.create(leaf, recursive = TRUE)
  leaf
}

## loglike column 2 is the arrival tstep; that is what replicate_status reads.
write_loglike <- function(leaf, sim, last_tstep, n = 3L) {
  lines <- vapply(seq_len(n), function(i) {
    paste(c(0, last_tstep, 1, 0, 0, i, sprintf("VE%03d", i), 0, 0, 0),
          collapse = " ")
  }, character(1))
  writeLines(lines, file.path(leaf, sprintf("loglike_%s.dat", sim)))
}

test_that("a replicate that reached the target is complete", {
  leaf <- make_output_leaf()
  write_loglike(leaf, "simu1", 87600)
  s <- replicate_status(leaf, "simu1", steps = 87673, margin = 1000)
  expect_true(s$complete)
  expect_equal(s$last_tstep, 87600L)
  expect_equal(s$status, "complete")
})

test_that("a replicate that stopped far short is incomplete", {
  leaf <- make_output_leaf()
  write_loglike(leaf, "simu1", 4200)
  s <- replicate_status(leaf, "simu1", steps = 87673, margin = 1000)
  expect_false(s$complete)
  expect_equal(s$status, "incomplete")
  expect_equal(s$last_tstep, 4200L)
})

test_that("the margin is what makes the test work at all", {
  ## Replicates genuinely end at different timesteps depending on which vessels
  ## were still active, so there is no exact target. Two runs of the same
  ## configuration finishing 400 steps apart must both count as complete.
  leaf <- make_output_leaf()
  write_loglike(leaf, "simuA", 87673)
  write_loglike(leaf, "simuB", 87280)
  for (nm in c("simuA", "simuB")) {
    expect_true(replicate_status(leaf, nm, steps = 87673, margin = 1000)$complete)
  }
  ## With no margin the second is wrongly condemned -- which is the bug the
  ## margin exists to prevent.
  expect_false(replicate_status(leaf, "simuB", steps = 87673, margin = 0)$complete)
})

test_that("a missing or empty replicate is distinguished from a short one", {
  leaf <- make_output_leaf()
  expect_equal(replicate_status(leaf, "simu1", steps = 100)$status, "missing")

  file.create(file.path(leaf, "loglike_simu2.dat"))
  expect_equal(replicate_status(leaf, "simu2", steps = 100)$status, "empty")
})

test_that("vmslike is used when loglike is absent", {
  ## The upstream Python runner reads vmslike column 1. Runs configured without
  ## -e leave it holding only initial positions, which is why loglike is
  ## preferred -- but it must still work when only vmslike exists.
  leaf <- make_output_leaf()
  writeLines(c("8700 VE001 0 -124.0 46.3 0 0 3"),
             file.path(leaf, "vmslike_simu1.dat"))
  s <- replicate_status(leaf, "simu1", steps = 8762, margin = 100)
  expect_true(s$complete)
  expect_equal(s$last_tstep, 8700L)
})

test_that("check_displace_replicates reports the spread across replicates", {
  leaf <- make_output_leaf()
  write_loglike(leaf, "simu1", 87673)
  write_loglike(leaf, "simu2", 87500)
  write_loglike(leaf, "simu3", 2000)

  df <- check_displace_replicates(leaf, c("simu1", "simu2", "simu3"),
                                  steps = 87673, margin = 1000)
  expect_equal(nrow(df), 3L)
  expect_equal(df$complete, c(TRUE, TRUE, FALSE))
  ## gap_to_best is what makes a failed run obvious without picking a margin
  ## first: the healthy replicates sit together and the broken one is far off.
  expect_equal(df$gap_to_best, c(0L, 173L, 85673L))
})

test_that("a campaign skips replicates that are already complete", {
  ## Resumability is the point: re-running a finished campaign must launch
  ## nothing at all.
  out <- tempfile()
  leaf <- file.path(out, "DISPLACE_outputs", "case", "baseline")
  dir.create(leaf, recursive = TRUE)
  for (nm in c("simu1", "simu2")) write_loglike(leaf, nm, 995)

  launched <- character(0)
  camp <- suppressMessages(run_displace_campaign(
    n = 2, steps = 1000, margin = 50,
    input_dir = "unused", input_name = "case", scenario = "baseline",
    output_dir = out,
    map = function(thunks) {
      launched <<- c(launched, names(thunks))
      lapply(thunks, function(f) f())
    }
  ))

  expect_length(launched, 0L)
  expect_equal(camp$passes, 0L)
  expect_true(all(camp$status$complete))
})

test_that("map receives the whole batch at once, not one replicate at a time", {
  ## This is what makes parallelism possible. The first version called map()
  ## inside a for loop, so it blocked on each replicate in turn and no mapper --
  ## furrr or otherwise -- could have run them concurrently.
  out <- tempfile()
  leaf <- file.path(out, "DISPLACE_outputs", "case", "baseline")
  dir.create(leaf, recursive = TRUE)

  batch_sizes <- integer(0)
  suppressWarnings(suppressMessages(run_displace_campaign(
    n = 5, steps = 1000, margin = 50, max_passes = 1,
    input_dir = "unused", input_name = "case", scenario = "baseline",
    output_dir = out,
    map = function(thunks) {
      batch_sizes <<- c(batch_sizes, length(thunks))
      ## Names identify which replicate each thunk belongs to, which a parallel
      ## mapper needs in order to report progress meaningfully.
      expect_equal(names(thunks), sprintf("simu%d", 1:5))
      vector("list", length(thunks))
    }
  )))

  expect_equal(batch_sizes, 5L)   # one call carrying all five, not five calls
})

test_that("a campaign gives up rather than looping for ever", {
  ## A replicate that fails deterministically must not spin: max_passes caps it
  ## and the failure is reported.
  out <- tempfile()
  dir.create(file.path(out, "DISPLACE_outputs", "case", "baseline"), recursive = TRUE)

  attempts <- 0L
  expect_warning(
    camp <- suppressMessages(run_displace_campaign(
      n = 1, steps = 1000, margin = 50, max_passes = 3,
      input_dir = "unused", input_name = "case", scenario = "baseline",
      output_dir = out,
      map = function(thunks) {
        attempts <<- attempts + 1L
        vector("list", length(thunks))   # never produces output
      }
    )),
    "giving up after 3 passes"
  )
  expect_equal(attempts, 3L)
  expect_false(camp$status$complete)
})
