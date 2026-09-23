test_that("the skeleton suffixes the right folders and leaves graphsspe flat", {
  ## TextfileModelLoader.cpp:96 builds "<inputfolder>/graphsspe/coord<N>.dat":
  ## no parameterisation suffix. Getting this wrong makes every graph file
  ## unfindable.
  d <- tempfile()
  create_displace_input(d, "mycase", quiet = TRUE)
  dirs <- list.dirs(d, full.names = FALSE, recursive = FALSE)

  expect_true("simusspe_mycase" %in% dirs)
  expect_true("vesselsspe_mycase" %in% dirs)
  expect_true("metiersspe_mycase" %in% dirs)
  expect_true("graphsspe" %in% dirs)
  expect_false("graphsspe_mycase" %in% dirs)
})

test_that("a structurally complete input folder validates", {
  fx <- make_fake_input()
  v <- validate_displace_input(fx$dir, fx$input_name, fx$scenario)
  expect_true(v$ok)
  expect_length(v$errors, 0L)
})

test_that("a missing simusspe folder is reported against input_name", {
  d <- tempfile()
  dir.create(d)
  v <- validate_displace_input(d, "nope")
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "simusspe_nope")
})

test_that("calibration vectors inconsistent with nbpops fail validation", {
  fx <- make_fake_input(nbpops = 2L)
  ## Write a config.dat by hand where nbpops disagrees with the calib vectors,
  ## bypassing the check in write_displace_config().
  simus <- file.path(fx$dir, paste0("simusspe_", fx$input_name))
  lines <- readLines(file.path(simus, "config.dat"))
  lines[2] <- "3"       # nbpops = 3, but the calib vectors still have 2 values
  writeLines(lines, file.path(simus, "config.dat"))

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "calib_oth_landings")
})

test_that("a missing vessel quarter fails validation", {
  ## main.cpp loads fgrounds and harbours for all four quarters at startup,
  ## whatever period is simulated.
  fx <- make_fake_input()
  file.remove(file.path(fx$dir, paste0("vesselsspe_", fx$input_name),
                        "vesselsspe_fgrounds_quarter3.dat"))

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "quarter 3")
})

test_that("a graph inconsistent with the scenario's nrow_coord fails validation", {
  fx <- make_fake_input(nrow_coord = 5L)
  ## Bump nrow_coord in the scenario without touching the graph file.
  sc_path <- file.path(fx$dir, paste0("simusspe_", fx$input_name), "baseline.dat")
  lines <- readLines(sc_path)
  lines[16] <- "9"        # 0-indexed line 15 -> nrow_coord
  writeLines(lines, sc_path)

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "nrow_coord")
})

test_that("a short per-node layer fails validation", {
  ## DISPLACE 1.8.0 checks every graph_point_* vector against nrow_coord and
  ## throws on a mismatch.
  fx <- make_fake_input(nrow_coord = 5L)
  writeLines(rep("0", 4L), file.path(fx$dir, "graphsspe", "coord1_with_sst.dat"))

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "coord1_with_sst.dat holds 4 values")
})

test_that("a missing required per-node layer fails validation", {
  fx <- make_fake_input()
  file.remove(file.path(fx$dir, "graphsspe", "coord1_with_bathymetry.dat"))

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "coord1_with_bathymetry.dat")
})

test_that("a missing ICES rectangle layer only warns", {
  ## Optional upstream, and made optional again on 1.8.0 by the ices-optional
  ## build patch -- see docs/upstream-issues.md 16.
  fx <- make_fake_input()
  file.remove(file.path(fx$dir, "graphsspe", "coord1_with_icesrectanglecode.dat"))

  v <- validate_displace_input(fx$dir, fx$input_name)
  expect_true(v$ok)
  expect_match(paste(v$warnings, collapse = "\n"), "icesrectanglecode")
})

test_that("a missing scenario lists the ones that do exist", {
  fx <- make_fake_input()
  v <- validate_displace_input(fx$dir, fx$input_name, scenario = "closure")
  expect_false(v$ok)
  expect_match(paste(v$errors, collapse = "\n"), "Available scenarios: baseline")
})

test_that("either calendar filename is accepted", {
  ## The loader tries tstep_<unit>.dat and falls back to
  ## tstep_<unit>_2009_2015.dat.
  fx <- make_fake_input()
  simus <- file.path(fx$dir, paste0("simusspe_", fx$input_name))
  file.rename(file.path(simus, "tstep_months.dat"),
              file.path(simus, "tstep_months_2009_2015.dat"))

  expect_true(validate_displace_input(fx$dir, fx$input_name)$ok)
})

test_that("run_displace refuses to launch on failed validation", {
  fx <- make_fake_input()
  file.remove(file.path(fx$dir, paste0("simusspe_", fx$input_name), "config.dat"))

  expect_error(
    run_displace(fx$dir, fx$input_name, steps = 10, binary = exit_binary("true"),
                 output_dir = tempfile(), echo = FALSE),
    "input validation failed"
  )
})
