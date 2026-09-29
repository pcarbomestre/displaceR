test_that("geodesics match Vincenty's published test case", {
  ## Flinders Peak -> Buninyong, the standard check for Vincenty's formulae.
  r <- geod_inverse(-37.95103342, 144.42486789, -37.65282114, 143.92649554)
  expect_lt(abs(r$s12 - 54972.271), 1e-3)
  expect_lt(abs(r$azi1 %% 360 - 306.86816), 1e-5)

  d <- geod_direct(-37.95103342, 144.42486789, 306.86816, 54972.271)
  expect_lt(abs(d$lat - -37.65282114), 1e-7)
  expect_lt(abs(d$lon - 143.92649554), 1e-7)

  expect_equal(geod_inverse(10, 20, 10, 20)$s12, 0)
})

test_that("the geodesic hex grid is spaced at the requested step", {
  bbox <- c(xmin = -121, ymin = 34, xmax = -120, ymax = 35)
  g <- grid_geodesic(bbox, 5000, "hex")
  ## Neighbours along a row are one step apart.
  row1 <- g[g$lat == g$lat[1], ]
  s <- geod_inverse(row1$lat[-nrow(row1)], row1$lon[-nrow(row1)],
                    row1$lat[-1], row1$lon[-1])$s12
  expect_equal(s, rep(5000, length(s)), tolerance = 1)
  ## As upstream, the grid starts at the south-west corner and the last row
  ## stops short of ymax.
  expect_equal(g$lon[1], -121)
  expect_equal(g$lat[1], 34)
  expect_lt(max(g$lat), 35)
})

make_box <- function(x0, y0, x1, y1) {
  sf::st_sfc(sf::st_polygon(list(rbind(c(x0, y0), c(x1, y0), c(x1, y1),
                                       c(x0, y1), c(x0, y0)))), crs = 4326)
}

test_that("a hex graph has six neighbours inside and km weights on edges", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)

  expect_s3_class(g, "displace_graph")
  expect_equal(g$nodes$node_id, seq_len(nrow(g$nodes)) - 1L)
  expect_true(all(g$nodes$harbour == 0L))
  expect_equal(g$nrow_coord, nrow(g$nodes))
  expect_equal(g$nrow_graph, nrow(g$edges))

  ## Interior nodes of a hex lattice have exactly six neighbours.
  expect_equal(max(tabulate(g$edges$from + 1L)), 6L)
  ## Weights are whole km, as upstream writes them; lattice edges are 5 km.
  expect_true(all(g$edges$dist_km == round(g$edges$dist_km)))
  expect_equal(as.numeric(names(which.max(table(g$edges$dist_km)))), 5)

  ## Every edge is present in both directions with the same weight.
  fwd <- paste(g$edges$from, g$edges$to, g$edges$dist_km)
  rev <- paste(g$edges$to, g$edges$from, g$edges$dist_km)
  expect_setequal(fwd, rev)
})

test_that("without max_edge_km the hull chord across the bowed rows survives", {
  skip_if_not_installed("sf")
  ## Grid rows are geodesics, which bow poleward, so the convex hull closes the
  ## bottom of the grid with one long chord. Upstream's triangulation does the
  ## same; max_edge_km is the remedy.
  g <- build_displace_graph(bbox = c(-121, 34, -119, 35.5), step_km = 5)
  expect_gt(max(g$edges$dist_km), 100)
})

test_that("nodes and edges stay out of the exclude polygons", {
  skip_if_not_installed("sf")
  sea <- make_box(-121, 34, -119, 35.5)
  land <- make_box(-120.3, 34.5, -119.7, 34.9)
  g <- build_displace_graph(step_km = 5, include = sea, exclude = land)

  inside <- g$nodes$lon > -120.3 & g$nodes$lon < -119.7 &
    g$nodes$lat > 34.5 & g$nodes$lat < 34.9
  expect_false(any(inside))

  crosses <- function(g) {
    e <- g$edges[g$edges$from < g$edges$to, ]
    n <- g$nodes
    lines <- sf::st_sfc(lapply(seq_len(nrow(e)), function(i) sf::st_linestring(
      rbind(c(n$lon[e$from[i] + 1], n$lat[e$from[i] + 1]),
            c(n$lon[e$to[i] + 1], n$lat[e$to[i] + 1])))), crs = 4326)
    old <- suppressMessages(sf::sf_use_s2(FALSE))
    on.exit(suppressMessages(sf::sf_use_s2(old)))
    sum(lengths(suppressMessages(sf::st_intersects(lines, land))) > 0)
  }
  expect_equal(crosses(g), 0)

  ## Without edge removal, the triangulation bridges the hole.
  g_keep <- build_displace_graph(step_km = 5, include = sea, exclude = land,
                                 drop_edges_touching_exclude = FALSE)
  expect_gt(crosses(g_keep), 0)

  g_short <- build_displace_graph(step_km = 5, include = sea, exclude = land,
                                  drop_edges_touching_exclude = FALSE,
                                  max_edge_km = 8)
  expect_lt(max(g_short$edges$dist_km), 8)
})

test_that("the finer include grid wins where two areas overlap", {
  skip_if_not_installed("sf")
  coarse <- make_box(-121, 34, -119, 36)
  fine <- make_box(-120.5, 34.5, -120, 35)
  g <- build_displace_graph(step_km = 20, include = coarse,
                            include2 = fine, step2_km = 4)
  in_fine <- g$nodes$lon >= -120.5 & g$nodes$lon <= -120 &
    g$nodes$lat >= 34.5 & g$nodes$lat <= 35
  mode_km <- function(sel) {
    e <- g$edges[sel[g$edges$from + 1L] & sel[g$edges$to + 1L], ]
    as.numeric(names(which.max(table(e$dist_km))))
  }
  expect_equal(mode_km(in_fine), 4)
  expect_equal(mode_km(!in_fine), 20)

  ## outside_step_km fills the rest of the box.
  g2 <- build_displace_graph(bbox = c(-122, 33, -118, 37), step_km = 20,
                             include = coarse, outside_step_km = 50)
  expect_true(any(g2$nodes$lon < -121))
})

test_that("harbours are appended and linked to their nearest sea nodes", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5)
  n <- nrow(g$nodes)
  ports <- data.frame(name = c("A", "B"), lon = c(-120.5, -120.2),
                      lat = c(34.5, 34.7), harbour = c(7L, 9L))

  h <- link_displace_harbours(g, ports, max_links = 3)
  expect_equal(nrow(h$nodes), n + 2L)
  expect_equal(h$nodes$harbour[n + 1:2], c(7L, 9L))
  expect_equal(h$nodes$harbour_name[n + 1:2], c("A", "B"))
  for (id in c(n, n + 1L)) {
    expect_equal(sum(h$edges$from == id), 3L)
    expect_equal(sum(h$edges$to == id), 3L)
  }
  ## The original sea edges are untouched.
  expect_equal(nrow(h$edges), nrow(g$edges) + 12L)

  ## A port far from every node still gets linked by widening the search...
  far <- data.frame(lon = -119.3, lat = 34.5)
  expect_equal(sum(link_displace_harbours(g, far)$edges$from == n), 3L)
  ## ...unless that is switched off.
  expect_warning(
    expect_warning(link_displace_harbours(g, far, avoid_lonely = FALSE),
                   "no node within"),
    "no edges")

  expect_error(link_displace_harbours(g, transform(far, harbour = 0L)),
               "non-zero")
})

test_that("the GUI harbour file format is read", {
  f <- tempfile(fileext = ".dat")
  writeLines(c("name;x;y;id", "Port A;-120.5;34.5;1", "Port B;-120.2;34.7;2"), f)
  h <- read_gui_harbour_file(f)
  expect_equal(h$name, c("Port A", "Port B"))
  expect_equal(h$lon, c(-120.5, -120.2))
  expect_equal(h$harbour, 1:2)
})

test_that("a built graph round-trips through write/read_displace_graph", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120.5, 34.5), step_km = 5)
  g <- link_displace_harbours(g, data.frame(lon = -120.7, lat = 34.2))
  d <- tempfile()
  write_displace_graph(g, d)
  back <- read_displace_graph(d, a_graph = g$a_graph,
                              nrow_coord = g$nrow_coord,
                              nrow_graph = g$nrow_graph)
  expect_equal(back$nodes[, c("node_id", "lon", "lat", "harbour")],
               g$nodes[, c("node_id", "lon", "lat", "harbour")])
  expect_equal(back$edges[, c("from", "to", "dist_km")],
               g$edges[, c("from", "to", "dist_km")])
})

test_that("inputs are validated", {
  skip_if_not_installed("sf")
  expect_error(build_displace_graph(step_km = 5), "bbox")
  expect_error(build_displace_graph(bbox = c(0, 0, 1, 1), step_km = -1), "positive")
  expect_error(build_displace_graph(bbox = c(0, 0, 1, 1), step_km = 500), "at least 3")
  expect_error(build_displace_graph(bbox = c(0, 0, 1, 1), step_km = 5,
                                    include2 = make_box(0, 0, 1, 1)), "needs include")
})

test_that("harbour links carry exact km, as the GUI writes them", {
  skip_if_not_installed("sf")
  g <- build_displace_graph(bbox = c(-121, 34, -120, 35), step_km = 5,
                            max_edge_km = 7.5)
  h <- link_displace_harbours(g, data.frame(lon = -120.51, lat = 34.52))
  w <- h$edges$dist_km[h$edges$from == nrow(g$nodes)]
  expect_false(all(w == round(w)))
  ## Sea edges keep the builder's whole-km rounding.
  expect_true(all(g$edges$dist_km == round(g$edges$dist_km)))
})

test_that("digits = 6 writes numbers the way the GUI's QTextStream does", {
  g <- list(
    nodes = data.frame(node_id = 0:2, lon = c(-119.7, -118.62137, -125.85651),
                       lat = c(31.9965, 48.77991234, 32), harbour = c(0L, 0L, 3L)),
    edges = data.frame(from = c(0L, 1L), to = c(1L, 2L), dist_km = c(4, 4.928155))
  )
  d <- tempfile()
  write_displace_graph(g, d, a_graph = 1, digits = 6)
  expect_equal(readLines(file.path(d, "graphsspe", "coord1.dat")),
               c("-119.7", "-118.621", "-125.857", "31.9965", "48.7799", "32",
                 "0", "0", "3"))
  expect_equal(readLines(file.path(d, "graphsspe", "graph1.dat")),
               c("0", "1", "1", "2", "4", "4.92816"))
})
