test_that("coord files are read as three stacked blocks, not as rows", {
  ## This is the format's defining quirk: with 3 nodes, longitude is lines 1-3,
  ## latitude lines 4-6, harbour flag lines 7-9. A row-wise reader would give
  ## completely different, plausible-looking numbers.
  d <- tempfile()
  dir.create(file.path(d, "graphsspe"), recursive = TRUE)
  writeLines(
    c("10.0", "11.0", "12.0",     # lon
      "55.0", "56.0", "57.0",     # lat
      "1", "0", "0"),             # harbour
    file.path(d, "graphsspe", "coord1.dat")
  )
  writeLines(
    c("0", "1",        # from
      "1", "2",        # to
      "3.2", "4.8"),   # dist_km
    file.path(d, "graphsspe", "graph1.dat")
  )

  g <- read_displace_graph(d, a_graph = 1L, nrow_coord = 3L, nrow_graph = 2L)

  expect_equal(g$nodes$lon, c(10, 11, 12))
  expect_equal(g$nodes$lat, c(55, 56, 57))
  expect_equal(g$nodes$harbour, c(1L, 0L, 0L))
  expect_equal(g$nodes$node_id, 0:2)      # DISPLACE node ids are 0-based
  expect_equal(g$edges$from, c(0L, 1L))
  expect_equal(g$edges$to, c(1L, 2L))
  expect_equal(g$edges$dist_km, c(3.2, 4.8))
})

test_that("edge distances are reported as the simulator will truncate them", {
  ## fill_from_graph() lexical_casts to double and pushes into a vector<int>,
  ## which truncates. Rounding here would misreport what the model uses.
  d <- tempfile()
  dir.create(file.path(d, "graphsspe"), recursive = TRUE)
  writeLines(c("0", "1", "1", "2", "3.9", "4.1"),
             file.path(d, "graphsspe", "graph1.dat"))
  writeLines(c("1", "2", "3", "1", "2", "3", "0", "0", "0"),
             file.path(d, "graphsspe", "coord1.dat"))

  g <- read_displace_graph(d, a_graph = 1L, nrow_coord = 3L, nrow_graph = 2L)
  expect_equal(g$edges$dist_km_as_used, c(3L, 4L))
})

test_that("blank lines are skipped without shifting the blocks", {
  ## fill_from_coord() does `continue` before `++linenum`, so blank lines do not
  ## count towards a block.
  d <- tempfile()
  dir.create(file.path(d, "graphsspe"), recursive = TRUE)
  writeLines(c("10.0", "", "11.0", "55.0", "56.0", "", "1", "0"),
             file.path(d, "graphsspe", "coord1.dat"))

  g <- read_displace_graph(d, a_graph = 1L, nrow_coord = 2L, edges = FALSE)
  expect_equal(g$nodes$lon, c(10, 11))
  expect_equal(g$nodes$lat, c(55, 56))
  expect_equal(g$nodes$harbour, c(1L, 0L))
})

test_that("a truncated graph file is an error, naming where nrow comes from", {
  d <- tempfile()
  dir.create(file.path(d, "graphsspe"), recursive = TRUE)
  writeLines(c("10.0", "11.0", "55.0"), file.path(d, "graphsspe", "coord1.dat"))

  expect_error(
    read_displace_graph(d, a_graph = 1L, nrow_coord = 2L, edges = FALSE),
    "nrow_coord"
  )
})

test_that("an over-long graph file warns rather than silently truncating", {
  ## The simulator reads the first 3*nrow values and ignores the rest without
  ## complaint, which is exactly how a graph/scenario mismatch stays hidden.
  d <- tempfile()
  dir.create(file.path(d, "graphsspe"), recursive = TRUE)
  writeLines(as.character(c(1:2, 3:4, 0, 0, 99)),
             file.path(d, "graphsspe", "coord1.dat"))

  expect_warning(
    read_displace_graph(d, a_graph = 1L, nrow_coord = 2L, edges = FALSE),
    "silently"
  )
})

test_that("graph round-trips through write and read", {
  d <- tempfile()
  nodes <- data.frame(node_id = 0:4,
                      lon = c(10, 10.5, 11, 11.5, 12),
                      lat = c(55, 55.5, 56, 56.5, 57),
                      harbour = c(1L, 0L, 0L, 1L, 0L))
  edges <- data.frame(from = c(0L, 1L, 2L), to = c(1L, 2L, 3L),
                      dist_km = c(1.25, 2.5, 3.75))

  write_displace_graph(list(nodes = nodes, edges = edges), d, a_graph = 7L,
                       code_area = c(1L, 1L, 2L, 10L, 10L))
  g <- read_displace_graph(d, a_graph = 7L, nrow_coord = 5L, nrow_graph = 3L)

  expect_equal(g$nodes$lon, nodes$lon)
  expect_equal(g$nodes$lat, nodes$lat)
  expect_equal(g$nodes$harbour, nodes$harbour)
  expect_equal(g$edges$from, edges$from)
  expect_equal(g$edges$to, edges$to)
  expect_equal(g$edges$dist_km, edges$dist_km)

  expect_equal(read_displace_code_area(d, 7L, 5L), c(1L, 1L, 2L, 10L, 10L))
})

test_that("code_area writes three blocks even though two are discarded", {
  ## fill_from_code_area() skips the first 2*nrow lines. Writing only the codes
  ## would put them where the parser is not looking.
  d <- tempfile()
  nodes <- data.frame(node_id = 0:1, lon = c(1, 2), lat = c(3, 4),
                      harbour = c(0L, 0L))
  write_displace_graph(list(nodes = nodes, edges = NULL), d, a_graph = 1L,
                       code_area = c(5L, 6L))

  lines <- readLines(file.path(d, "graphsspe", "code_area_for_graph1_points.dat"))
  expect_equal(length(lines), 6L)
  expect_equal(lines[5:6], c("5", "6"))
})

test_that("edges referencing a nonexistent node are rejected", {
  nodes <- data.frame(node_id = 0:1, lon = c(1, 2), lat = c(3, 4),
                      harbour = c(0L, 0L))
  edges <- data.frame(from = 0L, to = 5L, dist_km = 1)
  expect_error(
    write_displace_graph(list(nodes = nodes, edges = edges), tempfile(), a_graph = 1L),
    "only 2 nodes"
  )
})

test_that("reading a graph needs nrow from a scenario, and says so", {
  expect_error(read_displace_graph(tempfile()), "simusspe")
})

test_that("code_area's first two blocks hold the node coordinates, as the GUI writes them", {
  d <- tempfile()
  nodes <- data.frame(node_id = 0:1, lon = c(-124.5, -124.25), lat = c(40.5, 40.75),
                      harbour = c(0L, 0L))
  write_displace_graph(list(nodes = nodes, edges = NULL), d, a_graph = 1L,
                       code_area = c(5L, 6L))
  lines <- readLines(file.path(d, "graphsspe", "code_area_for_graph1_points.dat"))
  expect_equal(lines, c("-124.5", "-124.25", "40.5", "40.75", "5", "6"))
  expect_equal(read_displace_code_area(d, 1L, 2L), c(5L, 6L))
})

test_that("node_files writes code_area and every required per-node layer", {
  d <- tempfile()
  nodes <- data.frame(node_id = 0:2, lon = c(1, 2, 3), lat = c(4, 5, 6),
                      harbour = c(0L, 0L, 1L))
  paths <- write_displace_graph(list(nodes = nodes, edges = NULL), d,
                                a_graph = 2L, node_files = TRUE)
  required <- setdiff(PER_NODE_LAYERS, "icesrectanglecode")
  for (layer in required) {
    p <- file.path(d, "graphsspe", sprintf("coord2_with_%s.dat", layer))
    expect_true(file.exists(p), info = layer)
    expected <- if (startsWith(layer, "benthos_total_")) c("0", "0", "1") else rep("0", 3)
    expect_equal(readLines(p), expected, info = layer)
  }
  expect_false(file.exists(file.path(d, "graphsspe", "coord2_with_icesrectanglecode.dat")))
  expect_equal(read_displace_code_area(d, 2L, 3L), c(0L, 0L, 0L))
  expect_setequal(names(paths), c("coord", "code_area", required))
})

test_that("layers replace the defaults and are checked", {
  d <- tempfile()
  nodes <- data.frame(node_id = 0:1, lon = c(1, 2), lat = c(3, 4), harbour = c(0L, 0L))
  g <- list(nodes = nodes, edges = NULL)
  write_displace_graph(g, d, a_graph = 1L, node_files = TRUE,
                       layers = list(bathymetry = c(-120.5, -80), icesrectanglecode = c(7, 8)))
  expect_equal(readLines(file.path(d, "graphsspe", "coord1_with_bathymetry.dat")), c("-120.5", "-80"))
  expect_equal(readLines(file.path(d, "graphsspe", "coord1_with_icesrectanglecode.dat")), c("7", "8"))

  d2 <- tempfile()
  write_displace_graph(g, d2, a_graph = 1L, layers = list(sst = c(12, 13)))
  expect_equal(list.files(file.path(d2, "graphsspe")), c("coord1.dat", "coord1_with_sst.dat"))

  expect_error(write_displace_graph(g, tempfile(), a_graph = 1L, layers = list(depth = 1:2)),
               "unknown layer")
  expect_error(write_displace_graph(g, tempfile(), a_graph = 1L, layers = list(sst = 1:3)),
               "has 3 values but there are 2 nodes")
  expect_error(write_displace_graph(g, tempfile(), a_graph = 1L, layers = list(1:2)),
               "named list")
})

test_that("node_files output passes the input validator's per-node checks", {
  d <- tempfile()
  nodes <- data.frame(node_id = 0:2, lon = c(1, 2, 3), lat = c(4, 5, 6), harbour = c(0L, 0L, 1L))
  write_displace_graph(list(nodes = nodes, edges = NULL), d, a_graph = 0L, node_files = TRUE)
  for (layer in setdiff(PER_NODE_LAYERS, "icesrectanglecode")) {
    p <- file.path(d, "graphsspe", sprintf("coord0_with_%s.dat", layer))
    expect_gte(sum(nzchar(trimws(readLines(p)))), 3L)
  }
})
