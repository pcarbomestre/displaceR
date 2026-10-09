## The launch gate that spaces replicate launches across parallel workers.

test_that("the launch gate is a no-op with lag 0", {
  gate <- tempfile()
  expect_true(is.na(wait_for_launch_slot(gate, 0)))
  expect_false(dir.exists(gate))
})

test_that("a launch right after another waits; a late one does not", {
  gate <- tempfile()
  t1 <- wait_for_launch_slot(gate, 1)
  t2 <- wait_for_launch_slot(gate, 1)
  expect_gte(t2 - t1, 0.95)
  Sys.sleep(1.1)
  t0 <- Sys.time()
  wait_for_launch_slot(gate, 1)
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 0.5)
  expect_false(dir.exists(file.path(gate, "lock")))   # released
})

test_that("a stale lock left by a dead worker is cleared", {
  gate <- tempfile()
  dir.create(file.path(gate, "lock"), recursive = TRUE)
  Sys.setFileTime(file.path(gate, "lock"), Sys.time() - 3600)
  t0 <- Sys.time()
  wait_for_launch_slot(gate, 0.5)
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2)
})

test_that("simultaneous workers are spaced by at least the lag", {
  skip_on_os("windows")   # forked workers
  gate <- tempfile()
  times <- parallel::mclapply(1:4, function(i) wait_for_launch_slot(gate, 1),
                              mc.cores = 2)   # R CMD check allows at most 2
  times <- sort(unlist(times))
  expect_length(times, 4L)
  expect_true(all(diff(times) >= 0.95))
})

test_that("a parallel campaign launches its runs start_lag apart", {
  skip_on_os("windows")
  inp <- make_fake_input()
  out <- tempfile()
  camp <- suppressWarnings(suppressMessages(run_displace_campaign(
    n = 3, steps = 10, input_dir = inp$dir, input_name = inp$input_name,
    output_dir = out, binary = exit_binary("true"), sqlite = FALSE,
    validate = FALSE, max_passes = 1, start_lag = 1,
    map = function(thunks) parallel::mclapply(thunks, function(f) f(), mc.cores = 2)
  )))
  starts <- sort(vapply(camp$runs, function(r) as.numeric(r$started_at), numeric(1)))
  expect_length(starts, 3L)
  expect_true(all(diff(starts) >= 0.95))
})
