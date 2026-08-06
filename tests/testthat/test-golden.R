## Phase 4 — golden-file regression against a real DISPLACE run.
##
## This is the test that catches upstream interface drift, and it is the only
## one here that needs an actual simulator and dataset. Everything else in this
## suite pins down what displaceR believes about DISPLACE's formats; this pins
## down whether DISPLACE still agrees.
##
## It is skipped unless both are available:
##
##   DISPLACE_BINARY       path to a displace executable (or an install_displace()
##                         installation in the cache)
##   DISPLACE_MINITEST_DIR path to an unpacked DISPLACE_input_minitest dataset
##                         (https://displace-project.org/blog/download/)
##
## The build workflow sets both, so a new upstream build runs this before its
## tarball is published.

minitest_dir <- function() {
  d <- Sys.getenv("DISPLACE_MINITEST_DIR", "")
  if (!nzchar(d) || !dir.exists(d)) {
    return(NULL)
  }
  d
}

skip_without_simulator <- function() {
  if (is.null(minitest_dir())) {
    skip("DISPLACE_MINITEST_DIR is not set to an unpacked minitest dataset")
  }
  if (is.na(displace_path(error = FALSE))) {
    skip("no DISPLACE binary available (set DISPLACE_BINARY or run install_displace())")
  }
}

test_that("the minitest dataset passes validation", {
  skip_without_simulator()
  v <- validate_displace_input(minitest_dir(), "minitest")
  if (!v$ok) {
    print(v)
  }
  expect_true(v$ok)
})

test_that("the minitest case study's own files round-trip through our readers", {
  ## Reading a real case study and writing it back byte-comparably is the
  ## strongest available check that the positional layouts are right: a
  ## one-line offset that both our reader and writer share would survive a
  ## synthetic round trip but not this one.
  skip_without_simulator()
  d <- minitest_dir()

  cfg <- read_displace_config(d, "minitest")
  expect_gt(cfg$nbpops, 0L)
  expect_length(cfg$calib_oth_landings, cfg$nbpops)

  sc <- read_displace_scenario(d, "minitest", "baseline")
  expect_gt(sc$nrow_coord, 0L)
  expect_gt(sc$nrow_graph, 0L)

  g <- read_displace_graph(d, sc)
  expect_equal(nrow(g$nodes), sc$nrow_coord)
  expect_equal(nrow(g$edges), sc$nrow_graph)
  ## Coordinates must look like coordinates. If the stacked blocks were read in
  ## the wrong order this is what would catch it.
  expect_true(all(abs(g$nodes$lon) <= 180))
  expect_true(all(abs(g$nodes$lat) <= 90))
  expect_true(all(g$edges$from >= 0 & g$edges$from < sc$nrow_coord))
  expect_true(all(g$edges$to >= 0 & g$edges$to < sc$nrow_coord))

  ## Rewrite and re-read: the values must survive our writers unchanged.
  tmp <- tempfile()
  create_displace_input(tmp, "minitest", a_graph = sc$a_graph, quiet = TRUE)
  write_displace_config(cfg, tmp, "minitest")
  write_displace_scenario(sc, tmp, "minitest", "baseline")
  write_displace_graph(g, tmp, a_graph = sc$a_graph)

  cfg2 <- read_displace_config(tmp, "minitest")
  sc2 <- read_displace_scenario(tmp, "minitest", "baseline")
  g2 <- read_displace_graph(tmp, sc2)

  expect_equal(cfg2$nbpops, cfg$nbpops)
  expect_equal(cfg2$calib_cpue_multiplier, cfg$calib_cpue_multiplier)
  expect_equal(sc2$a_graph, sc$a_graph)
  expect_equal(sc2$nrow_coord, sc$nrow_coord)
  expect_equal(sc2$dyn_alloc_sce, sc$dyn_alloc_sce)
  expect_equal(g2$nodes$lon, g$nodes$lon)
  expect_equal(g2$edges$dist_km, g$edges$dist_km)
})

test_that("a short minitest run produces readable outputs", {
  skip_without_simulator()
  skip_on_cran()

  out <- tempfile()
  res <- run_displace(
    input_dir = minitest_dir(),
    input_name = "minitest",
    sim_name = "golden",
    steps = 50,
    output_dir = out,
    echo = FALSE,
    verbosity = 0
  )

  expect_equal(res$status, 0L)
  expect_true(dir.exists(res$output_path))

  ## --- SQLite ---------------------------------------------------------------
  expect_true(file.exists(res$db_path))

  ## The schema version is the dispatch key for version-aware readers. If this
  ## changes, the readers need looking at before the build is published.
  expect_equal(displace_db_version(res), 4L)

  tabs <- displace_db_tables(res)
  expect_true(nrow(tabs) > 0L)
  ## Every table the package claims exists should still exist upstream.
  expect_true(all(tabs$table %in% DISPLACE_DB_TABLES))

  ## --- text outputs ---------------------------------------------------------
  files <- displace_output_files(res)
  expect_true(nrow(files) > 0L)

  unrecognised <- files$file[is.na(files$type)]
  if (length(unrecognised)) {
    ## Not a failure: upstream adds outputs, and the package does not claim to
    ## know all of them. Worth surfacing so the spec table can be extended.
    message("text outputs with no layout in R/formats.R: ",
            paste(unrecognised, collapse = ", "))
  }

  cfg <- read_displace_config(minitest_dir(), "minitest")

  ## Read every recognised fixed-width output. A column-count mismatch means
  ## either upstream changed the layout or the transcription in R/formats.R is
  ## wrong, and both need to be caught before a release.
  for (i in seq_len(nrow(files))) {
    type <- files$type[i]
    if (is.na(type) || files$size[i] == 0) {
      next
    }
    expect_no_error(
      read_displace_output(files$path[i], type = type, config = cfg, n_max = 20),
      message = sprintf("reading %s as '%s'", files$file[i], type)
    )
  }
})
