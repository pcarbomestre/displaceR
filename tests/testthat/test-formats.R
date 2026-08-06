test_that("fixed-width layouts have the documented column counts", {
  ## popstats is tstep + stock + three blocks of 14 size groups.
  expect_length(displace_output_spec("popstats"), 2L + 3L * 14L)
  expect_length(displace_output_spec("vmslike"), 8L)
  expect_length(displace_output_spec("popnodes_cumftime"), 5L)
  expect_length(displace_output_spec("shipslogs"), 17L)
})

test_that("popnodes layouts widen with the number of populations", {
  ## tstep, node, long, lat, then (tot N, tot W) per population.
  cols <- displace_output_spec("popnodes_start", nbpops = 3L)
  expect_length(cols, 4L + 2L * 3L)
  expect_equal(cols[1:4], c("tstep", "node", "long", "lat"))
  expect_equal(cols[5:6], c("tot_N_sp0", "tot_W_sp0"))
  expect_equal(cols[9:10], c("tot_N_sp2", "tot_W_sp2"))
})

test_that("loglike includes the disc.* block upstream's R idiom adds", {
  ## The flat field list in the documentation omits these; upstream's own
  ## colnames() construction includes them, and it is the one that matches real
  ## files.
  cols <- displace_output_spec("loglike", nbpops = 4L, explicit_pops = c(0, 2))

  expect_true(all(sprintf("pop.%d", 0:3) %in% cols))
  expect_equal(grep("^disc\\.", cols, value = TRUE), c("disc.0", "disc.2"))
  ## disc.* sits between revpersweptarea and GVA.
  expect_equal(which(cols == "GVA") - which(cols == "revpersweptarea"), 3L)
  expect_equal(cols[length(cols)], "numTrips")

  ## 10 fixed + nbpops + 10 + n_explicit + 12
  expect_length(cols, 10L + 4L + 10L + 2L + 12L)
})

test_that("variable-width layouts refuse to guess", {
  expect_error(displace_output_spec("popnodes_start"), "nbpops")
  expect_error(displace_output_spec("loglike", nbpops = 2L), "explicit_pops")
})

test_that("unknown output types list the known ones", {
  expect_error(displace_output_spec("nonsense"), "Known:")
})

test_that("filename patterns classify without colliding", {
  ## cumcatches and cumcatches_with_threshold share a prefix; loglike and
  ## loglike_prop_met do too.
  expect_equal(displaceR:::classify_output("popnodes_cumcatches_sim1.dat"),
               "popnodes_cumcatches")
  expect_equal(displaceR:::classify_output("popnodes_cumcatches_with_threshold_sim1.dat"),
               "popnodes_cumcatches_with_threshold")
  expect_equal(displaceR:::classify_output("loglike_sim1.dat"), "loglike")
  expect_true(is.na(displaceR:::classify_output("loglike_prop_met_sim1.dat")))
  expect_true(is.na(displaceR:::classify_output("something_else.dat")))
})

test_that("displace_output_types describes every spec", {
  types <- displace_output_types()
  expect_equal(nrow(types), length(displaceR:::OUTPUT_SPECS))
  expect_true(all(c("type", "filename_pattern", "fixed_width") %in% names(types)))
  ## The variable-width ones are exactly the popnodes totals and loglike.
  expect_setequal(types$type[!types$fixed_width],
                  c("popnodes_start", "popnodes_inc", "popnodes_end",
                    "popnodes_impact_per_szgroup", "loglike"))
})

test_that("read_displace_output applies the layout to a real file", {
  d <- tempfile()
  dir.create(d)
  ## Two tsteps of popnodes_cumftime: tstep, node, long, lat, cumftime.
  writeLines(c("1 0 10.5 55.5 0", "1 1 11.0 56.0 3.25"),
             file.path(d, "popnodes_cumftime_sim1.dat"))

  df <- read_displace_output(d, "popnodes_cumftime")
  expect_equal(names(df), c("tstep", "node", "long", "lat", "cumftime"))
  expect_equal(nrow(df), 2L)
  expect_type(df$tstep, "integer")
  expect_equal(df$cumftime, c(0, 3.25))
})

test_that("a column-count mismatch names the likely cause", {
  d <- tempfile()
  dir.create(d)
  writeLines("1 0 10.5 55.5", file.path(d, "popnodes_cumftime_sim1.dat"))

  expect_error(read_displace_output(d, "popnodes_cumftime"),
               "expects 5")
})

test_that("read_displace_loglike insists on a config", {
  expect_error(read_displace_loglike(tempdir()), "read_displace_config")
})

test_that("displace_output_files classifies what it finds", {
  d <- tempfile()
  dir.create(d)
  file.create(file.path(d, c("popstats_sim1.dat", "vmslike_sim1.dat",
                             "mystery_sim1.dat")))

  files <- displace_output_files(d)
  expect_equal(nrow(files), 3L)
  expect_equal(files$type[files$file == "popstats_sim1.dat"], "popstats")
  expect_true(is.na(files$type[files$file == "mystery_sim1.dat"]))
})
