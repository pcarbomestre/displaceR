test_that("read_displace_config parses upstream's own config.dat fixture", {
  ## Verbatim from commons/commons_tests/inputfiles_simusspe.cpp,
  ## BOOST_AUTO_TEST_CASE(test_config_dat). Reproducing upstream's fixture is
  ## the strongest available check that the line mapping is right.
  f <- withr_tempfile()
  writeLines(c(
    "# nbpops",
    "3",
    "# nbmets",
    "2",
    "# nbbenthospops",
    "22",
    "# implicit stocks",
    "1 3",
    "# calib the other landings per stock",
    "2 4 ",
    "# calib weight-at-szgroup per stock",
    "16 32.6 ",
    "# calib the cpue multiplier per stock",
    "11 11.11 ",
    "# Interesting harbours",
    "3 6 18 29",
    "# Implicit Pop Levels #2",
    "",
    "# Grouped TACs groups",
    ""
  ), f)

  cfg <- read_displace_config(path = f)

  expect_equal(cfg$nbpops, 3L)
  expect_equal(cfg$nbmets, 2L)
  expect_equal(cfg$nbbenthospops, 22L)
  expect_equal(cfg$implicit_pops, c(1L, 3L))
  expect_equal(cfg$calib_oth_landings, c(2, 4))
  expect_equal(cfg$calib_weight_at_szgroup, c(16, 32.6))
  expect_equal(cfg$calib_cpue_multiplier, c(11, 11.11))
  expect_equal(cfg$int_harbours, c(3L, 6L, 18L, 29L))
  expect_equal(cfg$implicit_pops_level2, integer(0))
  expect_equal(cfg$grouped_tacs, integer(0))
})

test_that("config.dat round-trips", {
  cfg <- new_displace_config(
    nbpops = 3L, nbmets = 12L, nbbenthospops = 4L,
    implicit_pops = c(1L, 2L),
    calib_oth_landings = c(1, 2, 3),
    calib_weight_at_szgroup = c(0.5, 1, 1.5),
    calib_cpue_multiplier = c(2, 2, 2),
    int_harbours = c(0L, 7L)
  )
  f <- withr_tempfile()
  write_displace_config(cfg, path = f)
  back <- read_displace_config(path = f)

  for (field in c("nbpops", "nbmets", "nbbenthospops", "implicit_pops",
                  "calib_oth_landings", "calib_weight_at_szgroup",
                  "calib_cpue_multiplier", "int_harbours")) {
    expect_equal(back[[field]], cfg[[field]], info = field)
  }
})

test_that("writing rejects calibration vectors that do not match nbpops", {
  ## The simulator throws on this during loading; catching it at write time is
  ## the entire point of validating here.
  cfg <- new_displace_config(nbpops = 3L, nbmets = 1L)
  cfg$calib_cpue_multiplier <- c(1, 1)

  expect_error(write_displace_config(cfg, path = withr_tempfile()),
               "calib_cpue_multiplier has length 2 but nbpops is 3")
})

test_that("a config.dat written by us sits at the line numbers the parser reads", {
  ## Guards against an off-by-one creeping into CONFIG_SPEC: check the raw
  ## file, not just the round trip, since a consistent shift would round-trip
  ## fine and still break the simulator.
  cfg <- new_displace_config(nbpops = 1L, nbmets = 9L, nbbenthospops = 7L)
  f <- withr_tempfile()
  write_displace_config(cfg, path = f)
  lines <- readLines(f)

  expect_equal(lines[2], "1")     # 0-indexed line 1 -> nbpops
  expect_equal(lines[4], "9")     # 0-indexed line 3 -> nbmets
  expect_equal(lines[6], "7")     # 0-indexed line 5 -> nbbenthospops
})

test_that("a non-numeric nbpops is reported against its field name", {
  f <- withr_tempfile()
  writeLines(c("# nbpops", "x", "# nbmets", "2"), f)
  expect_error(read_displace_config(path = f), "nbpops")
})
