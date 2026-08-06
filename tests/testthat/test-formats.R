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

## The layouts below were read off the writers in commons/ and simulator/, then
## checked against the column counts of a real 3000-step minitest run. Where the
## writers and docs/output_fileformats.md disagree, the writers won.

test_that("fishfarmslogs uses upstream's filename and its real width", {
  ## Upstream writes "fishfarmslogs_" with the s, while the documentation and
  ## the receiving parameter both say "fishfarmlogs" — a pattern taken from the
  ## docs never matches a real file.
  expect_equal(displaceR:::classify_output("fishfarmslogs_sim1.dat"), "fishfarmslogs")
  expect_true(is.na(displaceR:::classify_output("fishfarmlogs_sim1.dat")))

  ## 14 columns, not the documented 10: export_fishfarms_indicators appends the
  ## nitrogen and phosphorus discharges. Verified against a real run.
  expect_length(displace_output_spec("fishfarmslogs"), 14L)
})

test_that("popdyn variants have distinct patterns and widths", {
  ## popdyn_, popdyn_F_, popdyn_SSB_ and popdyn_annual_indic_ all share a
  ## prefix but are different layouts.
  expect_equal(displaceR:::classify_output("popdyn_sim1.dat"), "popdyn")
  expect_equal(displaceR:::classify_output("popdyn_F_sim1.dat"), "popdyn_F")
  expect_equal(displaceR:::classify_output("popdyn_SSB_sim1.dat"), "popdyn_SSB")
  expect_true(is.na(displaceR:::classify_output("popdyn_annual_indic_sim1.dat")))
  expect_true(is.na(displaceR:::classify_output("popdyn_testsim1.dat")))

  expect_length(displace_output_spec("popdyn"), 2L + 14L)      # N at szgroup
  expect_length(displace_output_spec("popdyn_F"), 2L + 11L)    # F at age
  expect_length(displace_output_spec("popdyn_SSB"), 2L + 14L)  # SSB at szgroup
})

test_that("popnodes_impact and its per_szgroup sibling do not collide", {
  ## "^popnodes_impact_" also matches popnodes_impact_per_szgroup_, which would
  ## silently apply a 6-column layout to a wider file.
  expect_equal(displaceR:::classify_output("popnodes_impact_sim1.dat"),
               "popnodes_impact")
  expect_equal(displaceR:::classify_output("popnodes_impact_per_szgroup_sim1.dat"),
               "popnodes_impact_per_szgroup")

  ## Despite the name, the trailing block is per-population: upstream fetches
  ## the szgroup vector and then writes impact_per_pop (Node.cpp:2089).
  cols <- displace_output_spec("popnodes_impact_per_szgroup", nbpops = 3L)
  expect_length(cols, 5L + 3L)
  expect_equal(cols[6:8], c("impact_sp0", "impact_sp1", "impact_sp2"))
})

test_that("vmslikefpingsonly is nine key columns plus the size groups", {
  expect_length(displace_output_spec("vmslikefpingsonly"), 9L + 14L)
})

test_that("reports and diagnostics are never classified as tables", {
  ## memstats is free text ("*** Memory Statistics:"); the freq_* files are
  ## diagnostic histograms. Reading either with a column layout is meaningless.
  expect_true(is.na(displaceR:::classify_output("memstats_sim1.dat")))
  expect_true(is.na(displaceR:::classify_output("freq_cpuesim1.dat")))
  expect_true(is.na(displaceR:::classify_output("freq_distancesim1.dat")))
  expect_true(is.na(displaceR:::classify_output("freq_profitsim1.dat")))
})

test_that("shipslogs treats the fields upstream writes as decimals as numeric", {
  ## shiptype and nb_units are documented as integers but written with
  ## setprecision(3) fixed, i.e. "1.000", which an integer colClass rejects.
  d <- tempfile()
  dir.create(d)
  writeLines(
    "0 0 10.122 54.347 1.000 0 0.000 200.000 9.000 0.100 0.200 0.000 200.000 2250.000 20.000 50.000 0.000",
    file.path(d, "shipslogs_sim1.dat")
  )
  df <- read_displace_output(d, "shipslogs")
  expect_equal(ncol(df), 17L)
  expect_equal(df$shiptype, 1)
})
