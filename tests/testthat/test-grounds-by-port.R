## grounds_by_port feature patch: input file, loglike columns, run guard, and
## (with a patched binary and the public minitest dataset) the simulated
## behaviour. Synthetic data only.

test_that("fgrounds_harbours files round-trip and carry the derived shares", {
  d <- tempfile()
  dir.create(file.path(d, "vesselsspe_demo"), recursive = TRUE)
  x <- data.frame(vessel = c("V1", "V1", "V1", "V1", "V2"),
                  quarter = c(1, 1, 1, 2, 1),
                  pt_graph = c(10, 11, 10, 10, 12),
                  metier = c(0, 1, 1, 0, 2),
                  harbour = c(3, 3, 4, 3, 4),
                  weight = c(30, 10, 60, 5, 0.25))
  paths <- write_displace_fgrounds_harbours(x, d, "demo")
  expect_length(paths, 3L)
  expect_equal(readLines(file.path(d, "vesselsspe_demo", "V1_fgrounds_harbours_quarter1.dat")),
               c("pt_graph metier harbour weight", "10 0 3 30", "11 1 3 10", "10 1 4 60"))

  e <- read_displace_fgrounds_harbours(d, "demo")
  expect_equal(nrow(e), 5L)
  v1 <- e[e$vessel == "V1" & e$quarter == 1, ]
  ## within port 3: 30/40 and 10/40; port 4 alone: 1
  expect_equal(sort(v1$p_within_port), c(0.25, 0.75, 1))
  ## port shares are the weight sums: port 3 = 40/100, port 4 = 60/100
  expect_equal(sum(v1$p_vessel[v1$harbour == 3]), 0.4)
  expect_equal(sum(v1$p_vessel), 1)
  expect_equal(nrow(read_displace_fgrounds_harbours(d, "demo", vessels = "V2")), 1L)
  expect_equal(nrow(read_displace_fgrounds_harbours(d, "demo", quarters = 3)), 0L)
})

test_that("the writer rejects what DISPLACE would drop or misread", {
  d <- tempfile()
  dir.create(file.path(d, "vesselsspe_demo"), recursive = TRUE)
  ok <- data.frame(vessel = "V1", quarter = 1, pt_graph = 1, metier = 0, harbour = 2, weight = 1)
  bad <- function(...) { y <- ok; m <- list(...); y[names(m)] <- m; y }
  expect_error(write_displace_fgrounds_harbours(bad(weight = 0), d, "demo"), "positive")
  expect_error(write_displace_fgrounds_harbours(bad(quarter = 5), d, "demo"), "quarter")
  expect_error(write_displace_fgrounds_harbours(bad(pt_graph = 1.5), d, "demo"), "whole")
  expect_error(write_displace_fgrounds_harbours(bad(harbour = 70000), d, "demo"), "16-bit")
  expect_error(write_displace_fgrounds_harbours(rbind(ok, ok), d, "demo"), "duplicated")
  expect_error(write_displace_fgrounds_harbours(ok[-6], d, "demo"), "weight")
  expect_error(write_displace_fgrounds_harbours(ok, d, "other"), "no such folder")
})

test_that("loglike's trip_port and dep_port columns are recognised by width", {
  cfg <- new_displace_config(nbpops = 2L, nbmets = 3L, nbbenthospops = 1L,
                             implicit_pops = 1L)
  base <- displace_output_spec("loglike", nbpops = 2, explicit_pops = 0)
  expect_equal(utils::tail(displace_output_spec("loglike", nbpops = 2, explicit_pops = 0,
                                                grounds_by_port = TRUE), 2),
               c("trip_port", "dep_port"))

  fake_line <- function(extra = character()) {
    v <- rep("1", length(base))
    v[base == "VE_REF"] <- "V1"
    v[base == "freq_metiers"] <- "M(1)_1:1"
    paste(c(v, extra, ""), collapse = " ")
  }
  dir <- tempfile(); dir.create(dir)
  writeLines(rep(fake_line(c("36", "40")), 2), file.path(dir, "loglike_sim1.dat"))
  ll <- read_displace_loglike(dir, cfg, sim_name = "sim1")
  expect_equal(utils::tail(names(ll), 2), c("trip_port", "dep_port"))
  expect_equal(ll$trip_port, c(36L, 36L))

  writeLines(fake_line(), file.path(dir, "loglike_sim1.dat"))
  expect_false("trip_port" %in% names(read_displace_loglike(dir, cfg, sim_name = "sim1")))

  writeLines(fake_line("36"), file.path(dir, "loglike_sim1.dat"))
  expect_error(read_displace_loglike(dir, cfg, sim_name = "sim1"), "columns")
})

test_that("freq_metiers strings parse into the metiers used", {
  expect_equal(parse_freq_metiers("M(3)_1:0.5_3:0.5"), c(1L, 3L))
  expect_equal(parse_freq_metiers("M(0)"), integer())
  expect_equal(trip_metier(c("M(3)_1:0.5_3:0.5", "M(12)")), c(3L, 12L))
})

test_that("run_displace refuses grounds_by_port on a binary without the patch", {
  inp <- make_fake_input()
  sc <- inp$scenario_obj
  sc$dyn_alloc_sce <- c("baseline", "grounds_by_port")
  write_displace_scenario(sc, inp$dir, inp$input_name, scenario = "gbp")

  ## a "simulator" with a build record that lacks the patch
  bindir <- tempfile(); dir.create(bindir)
  bin <- file.path(bindir, "displace")
  file.copy(exit_binary("true"), bin)
  Sys.chmod(bin, "0755")
  skip_if_not_installed("jsonlite")
  jsonlite::write_json(list(upstream_sha = "96eadecb", feature_patches = ""),
                       file.path(bindir, "build-info.json"), auto_unbox = TRUE)
  expect_identical(displace_features(bin), character())

  expect_error(
    run_displace(inp$dir, inp$input_name, scenario = "gbp", steps = 10,
                 binary = bin, echo = FALSE, sqlite = FALSE, output_dir = tempfile()),
    "grounds-by-port"
  )
  ## the plain scenario is unaffected, and the guard can be switched off
  expect_silent(run_displace(inp$dir, inp$input_name, scenario = "baseline", steps = 10,
                             binary = bin, echo = FALSE, sqlite = FALSE,
                             output_dir = tempfile()))
  expect_silent(run_displace(inp$dir, inp$input_name, scenario = "gbp", steps = 10,
                             binary = bin, echo = FALSE, sqlite = FALSE,
                             output_dir = tempfile(), check_features = FALSE))

  ## with the patch on record it runs
  jsonlite::write_json(list(upstream_sha = "96eadecb", feature_patches = "grounds-by-port"),
                       file.path(bindir, "build-info.json"), auto_unbox = TRUE)
  expect_identical(displace_features(bin), "grounds-by-port")
  expect_silent(run_displace(inp$dir, inp$input_name, scenario = "gbp", steps = 10,
                             binary = bin, echo = FALSE, sqlite = FALSE,
                             output_dir = tempfile()))
})

test_that("a feature-patched local build gets its own install label", {
  info <- list(upstream_sha = "96eadecb1980d6f9ad22571cd6f963cc05379815",
               displace_version = "1.8.0")
  expect_equal(local_version_label(info), "1.8.0-96eadecb1980-local")
  info$feature_patches <- "grounds-by-port"
  expect_equal(local_version_label(info), "1.8.0-96eadecb1980-grounds-by-port-local")
})

## --- simulated behaviour: needs the patched binary and minitest -------------

gbp_run <- function(app, scenario, steps = 2L * 8762L, sim_name = "simu1") {
  suppressWarnings(run_displace(app$dir, app$input_name, scenario = scenario,
                                sim_name = sim_name, steps = steps,
                                binary = gbp_binary(), echo = FALSE,
                                export_vmslike = 10, huge = TRUE, sqlite = FALSE,
                                output_dir = tempfile("gbp-out-")))
}

test_that("grounds_by_port trips run A -> grounds of B -> B", {
  skip_without_gbp()
  app <- make_grounds_by_port_app()
  res <- gbp_run(app, "gbp")
  chk <- check_grounds_by_port(res)
  if (!all(chk$summary$ok)) print(chk)
  expect_true(all(chk$summary$ok))
  expect_gt(sum(chk$trips$trip_port >= 0), 200)

  ## trips go to every port, and are not confined to one
  expect_setequal(unique(chk$trips$trip_port[chk$trips$trip_port >= 0]), GBP_PORTS)
  ## the vessel without any file, and the one with quarter 1 only, use the
  ## baseline draws outside their tagged quarters
  last <- app$vessels[length(app$vessels)]
  expect_true(all(chk$trips$trip_port[chk$trips$VE_REF == last] == -1L))
  expect_true(any(chk$trips$trip_port[chk$trips$VE_REF == app$vessels[length(app$vessels) - 1L]] >= 0))

  ## port shares follow the weights (fixed seed, so this is not flaky)
  ps <- unique(chk$port_shares[c("vessel", "p_value")])
  expect_true(all(ps$p_value > 1e-3))
})

test_that("without changes of ground, trip metiers follow the weights too", {
  skip_without_gbp()
  app <- make_grounds_by_port_app()
  res <- gbp_run(app, "gbpnochange")
  chk <- check_grounds_by_port(res)
  expect_true(all(chk$summary$ok))
  ## a trip uses a single metier when it never changes ground
  tagged <- chk$trips[chk$trips$trip_port >= 0, ]
  expect_true(all(lengths(tagged$metiers_used) <= 1L))
  ms <- unique(chk$metier_shares[c("vessel", "p_value")])
  expect_true(all(ms$p_value > 1e-3))
})

test_that("closures remove a port's banned entries, metier by metier", {
  skip_without_gbp()
  app <- make_grounds_by_port_app()
  res <- gbp_run(app, "gbpclosure")
  chk <- check_grounds_by_port(res)
  expect_true(all(chk$summary$ok))
  tagged <- chk$trips[chk$trips$trip_port >= 0, ]
  fished <- unlist(tagged$nodes_fished)
  ## node 30 has a single entry (port 36, metier 0), closed: never fished
  expect_false(30L %in% fished)
  ## node 26 is closed to metier 0 (port 40's entry) but open to metier 1
  ## (port 36's entry): it is still fished, from port 36 only
  on26 <- vapply(tagged$nodes_fished, function(n) 26L %in% n, logical(1))
  expect_true(any(on26))
  expect_true(all(tagged$trip_port[on26] == 36L))
})

test_that("the patched binary without the option writes the plain loglike", {
  skip_without_gbp()
  app <- make_grounds_by_port_app()
  res <- gbp_run(app, "baseline", steps = 8762L)
  ll <- read_displace_loglike(res, read_displace_config(app$dir, app$input_name))
  expect_false(any(c("trip_port", "dep_port") %in% names(ll)))
  expect_gt(nrow(ll), 50)
})
