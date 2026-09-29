make_box <- function(x0, y0, x1, y1) {
  sf::st_sfc(sf::st_polygon(list(rbind(c(x0, y0), c(x1, y0), c(x1, y1),
                                       c(x0, y1), c(x0, y0)))), crs = 4326)
}

test_that("a closure penalises crossing edges once per polygon and closes inner nodes", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)
  ## Two touching boxes: edges across their shared side cross both.
  a <- make_box(-120.6, 34.4, -120.5, 34.6)
  b <- make_box(-120.5, 34.4, -120.4, 34.6)
  c2 <- add_displace_closure(g, c(a, b), weight = 500, metiers = 0:2,
                             vessel_sizes = c(0L, 4L), nations = 0L)

  delta <- c2$edges$dist_km - g$edges$dist_km
  expect_setequal(unique(delta), c(0, 500, 1000))
  expect_true(any(delta == 1000))
  expect_equal(c2$edges[, c("from", "to")], g$edges[, c("from", "to")])

  n <- g$nodes
  inside <- n$node_id[n$lon >= -120.6 & n$lon <= -120.4 & n$lat >= 34.4 & n$lat <= 34.6]
  expect_setequal(unique(c2$closures$node_id), inside)
  ## An edge between two closed nodes is always penalised.
  both <- g$edges$from %in% inside & g$edges$to %in% inside
  expect_true(all(delta[both] >= 500))
})

test_that("closure files follow read_metier_closures()'s line format", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)
  c2 <- add_displace_closure(g, make_box(-120.6, 34.4, -120.4, 34.6),
                             days_closed = 15, months = c(1, 7),
                             metiers = 0:2, vessel_sizes = c(0L, 4L), nations = 3L)
  d <- tempfile()
  p <- write_displace_closures(c2, d, a_graph = 2)
  expect_length(p, 36)

  gs <- file.path(d, "graphsspe")
  m1 <- readLines(file.path(gs, "metier_closure_a_graph2_month1.dat"))
  expect_length(m1, nrow(c2$closures))
  expect_equal(m1[1], sprintf("0 15 %d 0 1 2", c2$closures$node_id[1]))
  expect_equal(readLines(file.path(gs, "vsize_closure_a_graph2_month7.dat"))[1],
               sprintf("0 15 %d 0 4", c2$closures$node_id[1]))
  expect_equal(readLines(file.path(gs, "nation_closure_a_graph2_month1.dat"))[1],
               sprintf("0 15 %d 3", c2$closures$node_id[1]))
  ## Months without a closure still get a file, empty.
  expect_length(readLines(file.path(gs, "metier_closure_a_graph2_month2.dat")), 0)

  ## weight = 0 (the default) closes nodes without touching routing.
  expect_equal(c2$edges, g$edges)
})

test_that("a graph with no closures writes 36 empty files", {
  g <- list(nodes = data.frame(node_id = 0:1, lon = 0:1, lat = 0:1, harbour = 0L),
            edges = data.frame(from = 0L, to = 1L, dist_km = 1), a_graph = 3L)
  d <- tempfile()
  p <- write_displace_closures(g, d)
  expect_length(p, 36)
  expect_true(all(vapply(p, function(f) length(readLines(f)) == 0L, logical(1))))
})

test_that("closure arguments are validated", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)
  box <- make_box(-120.6, 34.4, -120.4, 34.6)
  expect_error(add_displace_closure(g, box, months = 13), "1:12")
  expect_error(add_displace_closure(g, box, days_closed = 40), "between 0 and 31")
  expect_warning(add_displace_closure(g, make_box(10, 10, 11, 11)), "no graph node")
})

test_that("closures survive adding harbours afterwards", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)
  c2 <- add_displace_closure(g, make_box(-120.6, 34.4, -120.4, 34.6),
                             weight = 500, metiers = 0L)
  h <- link_displace_harbours(c2, data.frame(lon = -120.9, lat = 34.1))
  expect_equal(h$closures, c2$closures)
  expect_equal(sum(h$edges$dist_km >= 500), sum(c2$edges$dist_km >= 500))
})
