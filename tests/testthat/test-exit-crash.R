## Upstream segfaults during static destruction whenever SQLite output is
## enabled, after the simulation has finished and every file is written
## (docs/upstream-issues.md, issue 3). run_displace() forgives that specific
## case and nothing else. These tests pin down where the line is, without
## needing a simulator: they build the output database by hand.

skip_unless_sqlite <- function() {
  skip_if_not_installed("DBI")
  skip_if_not_installed("RSQLite")
}

## Build a run handle pointing at a database we control, as if the binary had
## just exited with `status`.
fake_run <- function(steps = 100L, last_tstep = 99L, status = 139L,
                     write_db = TRUE, metadata = TRUE, corrupt = FALSE) {
  out <- tempfile()
  leaf <- file.path(out, "DISPLACE_outputs", "case", "baseline")
  dir.create(leaf, recursive = TRUE)
  db <- file.path(leaf, "case_sim1_out.db")

  if (write_db) {
    con <- DBI::dbConnect(RSQLite::SQLite(), db)
    if (metadata) {
      DBI::dbWriteTable(con, "Metadata", data.frame(
        Key = c("dbVersion", "lastTStep"),
        Value = c("4", as.character(last_tstep)),
        stringsAsFactors = FALSE
      ))
    }
    DBI::dbWriteTable(con, "VesselLogLike", data.frame(tstep = 1L))
    DBI::dbDisconnect(con)
    if (corrupt) {
      ## Overwrite the header so PRAGMA integrity_check cannot pass.
      con2 <- file(db, "r+b")
      writeBin(as.raw(rep(0, 64)), con2)
      close(con2)
    }
  }

  structure(
    list(binary = "/bin/false", args = character(), command = "displace ...",
         input_dir = "in", input_name = "case", scenario = "baseline",
         sim_name = "sim1", steps = as.integer(steps), output_dir = out,
         output_path = leaf, db_path = db, status = as.integer(status),
         elapsed = 1, stdout = character(), started_at = Sys.time(),
         crashed_at_exit = FALSE, last_tstep = NA_integer_),
    class = "displace_run"
  )
}

test_that("a completed run is recognised despite a crash exit status", {
  skip_unless_sqlite()
  res <- displaceR:::run_completed_cleanly(fake_run(steps = 100L, last_tstep = 99L))
  expect_true(res$completed)
  expect_equal(res$last_tstep, 99L)
})

test_that("a run that died halfway is not forgiven", {
  ## This is the case that must never be mistaken for the teardown crash: the
  ## database exists and is valid, but the simulation stopped early.
  skip_unless_sqlite()
  res <- displaceR:::run_completed_cleanly(fake_run(steps = 100L, last_tstep = 12L))
  expect_false(res$completed)
  expect_match(res$reason, "stopped at tstep 12 of 100")
})

test_that("the off-by-one tolerance is one step, not open-ended", {
  skip_unless_sqlite()
  ## steps - 1 is the normal last written step; steps - 2 is tolerated.
  expect_true(displaceR:::run_completed_cleanly(fake_run(100L, 99L))$completed)
  expect_true(displaceR:::run_completed_cleanly(fake_run(100L, 98L))$completed)
  expect_false(displaceR:::run_completed_cleanly(fake_run(100L, 97L))$completed)
})

test_that("a missing database is never treated as a completed run", {
  skip_unless_sqlite()
  res <- displaceR:::run_completed_cleanly(fake_run(write_db = FALSE))
  expect_false(res$completed)
  expect_match(res$reason, "no output database")
})

test_that("a database without lastTStep is not treated as complete", {
  skip_unless_sqlite()
  res <- displaceR:::run_completed_cleanly(fake_run(metadata = FALSE))
  expect_false(res$completed)
  expect_match(res$reason, "Metadata")
})

test_that("a corrupt database is not treated as complete", {
  skip_unless_sqlite()
  res <- suppressWarnings(displaceR:::run_completed_cleanly(fake_run(corrupt = TRUE)))
  expect_false(res$completed)
  ## Either the integrity check fails or the file will not open at all; both
  ## are correct refusals.
  expect_true(grepl("integrity_check|could not be read|Metadata", res$reason))
})

test_that("run_displace errors, not warns, when a real crash left no database", {
  input <- tempfile()
  dir.create(input)
  expect_error(
    run_displace(input, "case", steps = 10, validate = FALSE,
                 output_dir = tempfile(), binary = "/bin/false", echo = FALSE),
    "DISPLACE exited with status"
  )
})

test_that("--indb skips text-tree validation but checks the database exists", {
  ## With --indb the model comes from SQLite and the *spe_ folders need not
  ## exist, so validating them would reject a perfectly good case study.
  input <- tempfile()
  dir.create(input)
  file.create(file.path(input, "case.db"))

  r <- run_displace(input, "case", steps = 10, indb = "case.db",
                    dry_run = TRUE, binary = "/bin/true")
  expect_true("--indb" %in% r$args)
  expect_equal(r$args[which(r$args == "--indb") + 1L], "case.db")

  ## A path that does not resolve is caught up front, naming the resolution rule.
  expect_error(
    run_displace(input, "case", steps = 10, indb = "missing.db",
                 binary = "/bin/true", output_dir = tempfile()),
    "relative to input_dir"
  )
})

test_that("the crash is forgiven on any signal, not just SIGSEGV", {
  ## The teardown crash does not report a stable status: over six identical
  ## runs it alternated between 139 (SIGSEGV) and 134 (SIGABRT), the latter
  ## being glibc catching the heap corruption first. Anything that keys on one
  ## specific status will pass or fail by coin flip.
  skip_unless_sqlite()
  for (st in c(139L, 134L, 1L, 255L)) {
    res <- displaceR:::run_completed_cleanly(fake_run(status = st))
    expect_true(res$completed, info = paste("status", st))
  }
})

test_that("a completed run is forgiven end to end whatever the status", {
  ## Guards the run_displace() path, not just the helper: it must warn and
  ## return rather than error, for a status it has never seen before.
  skip_unless_sqlite()
  ## fake_run() has already written a complete-looking database under
  ## output_dir, so /bin/false standing in for the binary reproduces exactly
  ## the situation: non-zero exit, finished run.
  fr <- fake_run(steps = 100L, last_tstep = 99L, status = 134L)
  input <- tempfile()
  dir.create(input)

  expect_warning(
    res <- run_displace(
      input_dir = input, input_name = "case", steps = 100,
      validate = FALSE, echo = FALSE,
      binary = "/bin/false", output_dir = fr$output_dir
    ),
    "the run completed"
  )
  expect_true(res$crashed_at_exit)
  expect_equal(res$last_tstep, 99L)
})
