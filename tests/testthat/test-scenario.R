test_that("read_displace_scenario parses a file laid out per readdata.cpp", {
  ## Built from the SCENARIO_SPEC line numbers, which come from
  ## read_scenario_config_file() in commons/readdata.cpp. Note this includes
  ## met_multiplier_on_arbitary_breaks_for_tariff at line 47, which upstream's
  ## own test fixture predates.
  f <- withr_tempfile(".dat")
  writeLines(c(
    "# dyn_alloc_sce",       "baseline focus_on_high_profit_grounds",
    "# dyn_pop_sce",         "baseline",
    "# biolsce",             "1",
    "# fleetsce",            "2",
    "# freq_do_growth",      "1",
    "# freq_redispatch",     "2",
    "# a_graph",             "56",
    "# nrow_coord",          "10140",
    "# nrow_graph",          "57555",
    "# a_port",              "6",
    "# grid res km",         "7.1",
    "# is_individual_vessel_quotas", "1",
    "# check_all_stocks",    "0",
    "# Go Fishing DTree",    "dt_go_fishing",
    "# Choose Ground DTree", "dt_choose_ground",
    "# Start Fishing DTree", "dt_start_fishing",
    "# Change Ground DTree", "dt_change_ground",
    "# Stop Fishing DTree",  "dt_stop_fishing",
    "# Change Port DTree",   "dt_change_port",
    "# Use Dtrees",          "1",
    "# tariff_pop",          "0 1",
    "# freq_update_tariff",  "2",
    "# arbitrary_breaks",    "0 1 5 10",
    "# met_multiplier",      "1 1",
    "# total_amount_credited", "100000",
    "# tariff_annual_hcr",   "10.0",
    "# lpue_or_dpue_code",   "1",
    "# banned metiers",      "10 11 12"
  ), f)

  sc <- read_displace_scenario(path = f)

  expect_equal(sc$dyn_alloc_sce, c("baseline", "focus_on_high_profit_grounds"))
  expect_equal(sc$dyn_pop_sce, "baseline")
  expect_equal(sc$biolsce, "1")
  expect_equal(sc$fleetsce, "2")
  expect_equal(sc$a_graph, 56L)
  expect_equal(sc$nrow_coord, 10140L)
  expect_equal(sc$nrow_graph, 57555L)
  expect_equal(sc$a_port, 6L)
  expect_true(sc$is_individual_vessel_quotas)
  expect_false(sc$check_all_stocks_before_going_fishing)
  expect_equal(sc$dt_go_fishing, "dt_go_fishing")
  expect_equal(sc$dt_change_port, "dt_change_port")
  expect_true(sc$use_dtrees)
  expect_equal(sc$tariff_pop, c(0L, 1L))
  expect_equal(sc$arbitary_breaks_for_tariff, c(0, 1, 5, 10))
  expect_equal(sc$met_multiplier_on_arbitary_breaks_for_tariff, c(1, 1))
  expect_equal(sc$total_amount_credited, 100000L)
  expect_equal(sc$tariff_annual_hcr_percent_change, 10)
  expect_equal(sc$metier_closures, c(10L, 11L, 12L))
})

test_that("a single graph_res value is duplicated into (x, y)", {
  ## importScenario() does this: "res x and y required".
  f <- withr_tempfile(".dat")
  sc <- new_displace_scenario(nrow_coord = 10L, nrow_graph = 20L, graph_res = 7.1)
  expect_equal(sc$graph_res, c(7.1, 7.1))

  write_displace_scenario(sc, path = f)
  ## Rewrite line 22 (0-indexed 21) with a single value to check the reader too.
  lines <- readLines(f)
  lines[22] <- "7.1"
  writeLines(lines, f)
  expect_equal(read_displace_scenario(path = f)$graph_res, c(7.1, 7.1))
})

test_that("scenario round-trips", {
  sc <- new_displace_scenario(
    nrow_coord = 1000L, nrow_graph = 4000L, a_graph = 3L, a_port = 12L,
    graph_res = c(5, 6), dyn_alloc_sce = c("baseline", "area_closure"),
    biolsce = "2", fleetsce = "1", use_dtrees = TRUE,
    dt_go_fishing = "go", metier_closures = c(4L, 5L)
  )
  f <- withr_tempfile(".dat")
  write_displace_scenario(sc, path = f)
  back <- read_displace_scenario(path = f)

  for (field in c("dyn_alloc_sce", "dyn_pop_sce", "biolsce", "fleetsce",
                  "a_graph", "nrow_coord", "nrow_graph", "a_port", "graph_res",
                  "use_dtrees", "dt_go_fishing", "metier_closures",
                  "is_individual_vessel_quotas")) {
    expect_equal(back[[field]], sc[[field]], info = field)
  }
})

test_that("scenario values land on the line numbers the parser reads", {
  sc <- new_displace_scenario(nrow_coord = 111L, nrow_graph = 222L, a_graph = 33L)
  f <- withr_tempfile(".dat")
  write_displace_scenario(sc, path = f)
  lines <- readLines(f)

  expect_equal(lines[14], "33")    # 0-indexed 13 -> a_graph
  expect_equal(lines[16], "111")   # 0-indexed 15 -> nrow_coord
  expect_equal(lines[18], "222")   # 0-indexed 17 -> nrow_graph
  ## The file must extend to line 55 (0-indexed) or the closures field is lost.
  expect_gte(length(lines), 56L)
})

test_that("optional trailing fields default rather than erroring", {
  ## importScenario() supplies defaults for total_amount_credited and the two
  ## tariff fields after it, so a short file must load.
  f <- withr_tempfile(".dat")
  sc <- new_displace_scenario(nrow_coord = 10L, nrow_graph = 20L)
  write_displace_scenario(sc, path = f)
  writeLines(readLines(f)[1:46], f)   # truncate before total_amount_credited

  back <- read_displace_scenario(path = f)
  expect_equal(back$total_amount_credited, 0L)
  expect_equal(back$tariff_annual_hcr_percent_change, 0)
  expect_equal(back$metier_closures, integer(0))
})
