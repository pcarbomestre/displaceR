## Building a DISPLACE graph from polygons -- an R port of the GUI's
## "Create Graph" and "Link Harbours" actions.
##
## Upstream this lives only in the Qt editor (qtgui/graphbuilder_shp.cpp, with
## the grid generators in qtgui/algo/ and harbour linking in
## MainWindow::on_actionLink_Harbours_triggered), which needs Qt6, CGAL and
## GDAL and is exactly what the headless build leaves out. The algorithm itself
## is short, so it is reimplemented here rather than compiled:
##
##   1. lay a hex or square grid of points over a lon/lat box
##      (SimpleGeodesicLineGraphBuilder / SimplePlanarGraphBuilder);
##   2. keep the points inside the "include" polygons and drop those inside the
##      "exclude" polygons (OGRLayer::Clip / SymDifference, planar in lon/lat);
##   3. Delaunay-triangulate the survivors in the lon/lat plane (CGAL) and turn
##      every triangulation edge into a pair of directed graph edges;
##   4. weight each edge by its WGS84 geodesic length in km, rounded as
##      floor(d + 0.5) (graphbuilder_shp.cpp, buildGraph());
##   5. optionally drop edges longer than a limit, and edges touching the
##      exclude polygons.
##
## Deliberate differences from upstream, all small:
##
##   - CGAL is run as a *constrained* Delaunay triangulation, constraining
##     consecutive points of a grid row. On a regular grid those segments are
##     Delaunay edges already, so an unconstrained triangulation (GEOS, via sf)
##     gives the same edges except, at most, for ties on a square grid.
##   - Points along a geodesic are spaced by equal distance, not equal arc on
##     the auxiliary sphere (GeodesicLine::ArcPosition). The two differ by far
##     less than a metre at graph resolutions.
##   - Geodesics use Vincenty's formulae rather than GeographicLib. Both are on
##     the WGS84 ellipsoid; they agree to well under a millimetre for any pair
##     of points that is not nearly antipodal, which graph edges never are.
##   - Node ids are contiguous. Upstream numbers points before clipping and
##     leaves holes that the GUI compacts later.

WGS84_A <- 6378137
WGS84_F <- 1 / 298.257223563
WGS84_B <- WGS84_A * (1 - WGS84_F)

deg2rad <- function(x) x * pi / 180
rad2deg <- function(x) x * 180 / pi

## Vincenty inverse on WGS84. Vectorised over all arguments. Returns distance in
## metres and the forward azimuth at point 1 in degrees.
geod_inverse <- function(lat1, lon1, lat2, lon2) {
  n <- max(length(lat1), length(lon1), length(lat2), length(lon2))
  lat1 <- rep_len(lat1, n); lon1 <- rep_len(lon1, n)
  lat2 <- rep_len(lat2, n); lon2 <- rep_len(lon2, n)
  f <- WGS84_F

  L <- deg2rad(lon2 - lon1)
  U1 <- atan((1 - f) * tan(deg2rad(lat1)))
  U2 <- atan((1 - f) * tan(deg2rad(lat2)))
  sinU1 <- sin(U1); cosU1 <- cos(U1)
  sinU2 <- sin(U2); cosU2 <- cos(U2)

  lambda <- L
  sin_sigma <- cos_sigma <- sigma <- cos2_alpha <- cos_2sm <- numeric(n)
  todo <- rep(TRUE, n)
  for (iter in seq_len(200)) {
    sl <- sin(lambda); cl <- cos(lambda)
    sin_sigma <- sqrt((cosU2 * sl)^2 + (cosU1 * sinU2 - sinU1 * cosU2 * cl)^2)
    cos_sigma <- sinU1 * sinU2 + cosU1 * cosU2 * cl
    sigma <- atan2(sin_sigma, cos_sigma)
    sin_alpha <- ifelse(sin_sigma == 0, 0, cosU1 * cosU2 * sl / sin_sigma)
    cos2_alpha <- 1 - sin_alpha^2
    cos_2sm <- ifelse(cos2_alpha == 0, 0,
                      cos_sigma - 2 * sinU1 * sinU2 / cos2_alpha)
    C <- f / 16 * cos2_alpha * (4 + f * (4 - 3 * cos2_alpha))
    lambda_new <- L + (1 - C) * f * sin_alpha *
      (sigma + C * sin_sigma * (cos_2sm + C * cos_sigma * (-1 + 2 * cos_2sm^2)))
    done <- abs(lambda_new - lambda) < 1e-12
    lambda <- ifelse(todo, lambda_new, lambda)
    todo <- todo & !done
    if (!any(todo)) break
  }

  u2 <- cos2_alpha * (WGS84_A^2 - WGS84_B^2) / WGS84_B^2
  A <- 1 + u2 / 16384 * (4096 + u2 * (-768 + u2 * (320 - 175 * u2)))
  B <- u2 / 1024 * (256 + u2 * (-128 + u2 * (74 - 47 * u2)))
  d_sigma <- B * sin_sigma * (cos_2sm + B / 4 * (cos_sigma * (-1 + 2 * cos_2sm^2) -
    B / 6 * cos_2sm * (-3 + 4 * sin_sigma^2) * (-3 + 4 * cos_2sm^2)))
  s <- WGS84_B * A * (sigma - d_sigma)
  sl <- sin(lambda); cl <- cos(lambda)
  azi1 <- rad2deg(atan2(cosU2 * sl, cosU1 * sinU2 - sinU1 * cosU2 * cl))

  s[sin_sigma == 0] <- 0
  list(s12 = s, azi1 = azi1)
}

## Vincenty direct on WGS84: start point, azimuth (degrees) and distance
## (metres) to end point. Vectorised.
geod_direct <- function(lat1, lon1, azi1, s12) {
  n <- max(length(lat1), length(lon1), length(azi1), length(s12))
  lat1 <- rep_len(lat1, n); lon1 <- rep_len(lon1, n)
  azi1 <- rep_len(azi1, n); s12 <- rep_len(s12, n)
  f <- WGS84_F

  a1 <- deg2rad(azi1)
  sin_a1 <- sin(a1); cos_a1 <- cos(a1)
  tanU1 <- (1 - f) * tan(deg2rad(lat1))
  cosU1 <- 1 / sqrt(1 + tanU1^2)
  sinU1 <- tanU1 * cosU1
  sigma1 <- atan2(tanU1, cos_a1)
  sin_alpha <- cosU1 * sin_a1
  cos2_alpha <- 1 - sin_alpha^2
  u2 <- cos2_alpha * (WGS84_A^2 - WGS84_B^2) / WGS84_B^2
  A <- 1 + u2 / 16384 * (4096 + u2 * (-768 + u2 * (320 - 175 * u2)))
  B <- u2 / 1024 * (256 + u2 * (-128 + u2 * (74 - 47 * u2)))

  sigma <- s12 / (WGS84_B * A)
  for (iter in seq_len(200)) {
    cos_2sm <- cos(2 * sigma1 + sigma)
    sin_s <- sin(sigma); cos_s <- cos(sigma)
    d_sigma <- B * sin_s * (cos_2sm + B / 4 * (cos_s * (-1 + 2 * cos_2sm^2) -
      B / 6 * cos_2sm * (-3 + 4 * sin_s^2) * (-3 + 4 * cos_2sm^2)))
    sigma_new <- s12 / (WGS84_B * A) + d_sigma
    if (all(abs(sigma_new - sigma) < 1e-12)) {
      sigma <- sigma_new
      break
    }
    sigma <- sigma_new
  }

  cos_2sm <- cos(2 * sigma1 + sigma)
  sin_s <- sin(sigma); cos_s <- cos(sigma)
  tmp <- sinU1 * sin_s - cosU1 * cos_s * cos_a1
  lat2 <- atan2(sinU1 * cos_s + cosU1 * sin_s * cos_a1,
                (1 - f) * sqrt(sin_alpha^2 + tmp^2))
  lam <- atan2(sin_s * sin_a1, cosU1 * cos_s - sinU1 * sin_s * cos_a1)
  C <- f / 16 * cos2_alpha * (4 + f * (4 - 3 * cos2_alpha))
  L <- lam - (1 - C) * f * sin_alpha *
    (sigma + C * sin_s * (cos_2sm + C * cos_s * (-1 + 2 * cos_2sm^2)))
  list(lat = rad2deg(lat2), lon = lon1 + rad2deg(L))
}

## Port of SimpleGeodesicLineGraphBuilder (qtgui/algo/). Rows are laid along
## the meridian lonMin at a spacing of stepY; each row is the *geodesic* from
## (lat, lonMin) to (lat, lonMax) -- not a parallel -- sampled every `step`,
## with odd rows offset by half a step on a hex grid. As upstream, the last row
## stops short of latMax (j < num_y) and a row may overshoot lonMax by up to
## half a step.
grid_geodesic <- function(bbox, step_m, type) {
  step_x <- step_m / 2
  hex <- identical(type, "hex")
  step_y <- if (hex) step_m * sqrt(3) / 2 else step_m

  col <- geod_inverse(bbox[["ymin"]], bbox[["xmin"]], bbox[["ymax"]], bbox[["xmin"]])
  num_y <- ceiling(col$s12 / step_y)
  row_lat <- geod_direct(bbox[["ymin"]], bbox[["xmin"]], col$azi1,
                         (seq_len(num_y) - 1L) * col$s12 / num_y)$lat

  rows <- lapply(seq_along(row_lat), function(r) {
    j <- r - 1L
    lat <- row_lat[r]
    ln <- geod_inverse(lat, bbox[["xmin"]], lat, bbox[["xmax"]])
    num <- ceiling(ln$s12 / step_x)
    k <- seq(0L, num, by = 2L) + if (hex) j %% 2L else 0L
    p <- geod_direct(lat, bbox[["xmin"]], ln$azi1, k * ln$s12 / num)
    data.frame(lon = p$lon, lat = p$lat)
  })
  do.call(rbind, rows)
}

## Port of SimplePlanarGraphBuilder (qtgui/algo/). A lon/lat-rectangular
## lattice: the columns are fixed longitudes, spaced by `step` along the
## geodesic heading east from the south-west corner, and rows are stepped north
## from there. Every row keeps the same longitudes, so the east-west spacing in
## km shrinks with latitude. Rows run while lat <= latMax.
grid_planar <- function(bbox, step_m, type) {
  hex <- identical(type, "hex")
  step_x <- if (hex) step_m / 2 else step_m
  step_y <- if (hex) sqrt(3) * step_m / 2 else step_m

  lons <- numeric()
  p <- list(lat = bbox[["ymin"]], lon = bbox[["xmin"]])
  while (p$lon < bbox[["xmax"]]) {
    lons <- c(lons, p$lon)
    p <- geod_direct(p$lat, p$lon, 90, step_x)
  }

  rows <- list()
  lat <- bbox[["ymin"]]
  r <- 0L
  while (lat <= bbox[["ymax"]]) {
    start <- if (hex) (r %% 2L) + 1L else 1L
    idx <- seq(start, length(lons), by = if (hex) 2L else 1L)
    idx <- idx[idx <= length(lons)]
    rows[[length(rows) + 1L]] <- data.frame(lon = lons[idx], lat = rep(lat, length(idx)))
    lat <- geod_direct(lat, lons[1], 0, step_y)$lat
    r <- r + 1L
  }
  do.call(rbind, rows)
}

make_grid <- function(bbox, step_km, type, method) {
  if (!is.numeric(step_km) || length(step_km) != 1L || !(step_km > 0)) {
    stopf("grid steps must be single positive numbers of km; got %s",
          paste(format(step_km), collapse = ", "))
  }
  fun <- switch(method, geodesic = grid_geodesic, planar = grid_planar)
  fun(bbox, step_km * 1000, type)
}

## Polygons can be sf / sfc objects or paths to anything sf::st_read() reads.
## Everything ends up in WGS84 lon/lat: this is what tools/convshp.py does
## upstream before a shapefile is handed to the GUI.
as_lonlat_polygons <- function(x, what) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.character(x)) {
    if (length(x) != 1L || !file.exists(x)) {
      stopf("%s: no such file: %s", what, paste(x, collapse = ", "))
    }
    x <- sf::st_read(x, quiet = TRUE)
  }
  geom <- if (inherits(x, "sf")) sf::st_geometry(x) else x
  if (!inherits(geom, "sfc")) {
    stopf("%s must be an sf/sfc object or a path to a vector file", what)
  }
  crs <- sf::st_crs(geom)
  if (is.na(crs)) {
    warnf("%s has no CRS; assuming WGS84 longitude/latitude.", what)
    sf::st_crs(geom) <- 4326
  } else if (!isTRUE(sf::st_is_longlat(geom))) {
    geom <- sf::st_transform(geom, 4326)
  }
  geom
}

## Which rows of `pts` (a lon/lat data frame) fall inside or on `polys`.
## Planar in lon/lat, as OGR's Clip is: s2 is switched off by the caller.
points_in <- function(pts, polys) {
  if (is.null(polys) || !nrow(pts)) {
    return(rep(FALSE, nrow(pts)))
  }
  p <- sf::st_as_sf(pts, coords = c("lon", "lat"), crs = sf::st_crs(polys))
  ## s2 is off on purpose, so sf's "assumes planar" note is expected.
  lengths(suppressMessages(sf::st_intersects(p, polys))) > 0L
}

#' Build a DISPLACE graph from polygons
#'
#' An R implementation of the "Create Graph" action in the DISPLACE editor
#' GUI (`qtgui/graphbuilder_shp.cpp` upstream). The headless simulator this
#' package installs does not include it. It lays a regular grid of nodes over
#' a longitude/latitude box, keeps the nodes inside `include` and drops those
#' inside `exclude`, then connects neighbouring nodes by Delaunay
#' triangulation. Each edge is weighted by its WGS84 geodesic length in km.
#'
#' The result can be passed to [link_displace_harbours()] to add ports, then
#' to [write_displace_graph()]. Remember to put `nrow(g$nodes)` and
#' `nrow(g$edges)` into the scenario file as `nrow_coord` and `nrow_graph`.
#'
#' Options map onto the GUI dialog as follows. `include`/`step_km` are
#' "including shapefile 1" and its distance, `include2`/`step2_km` are
#' "including shapefile 2", and `outside_step_km` is "outside" with its
#' default distance. Where the two include areas overlap, the finer grid wins.
#' With no `include`, the whole of `bbox` is gridded at `step_km`.
#'
#' Differences from the GUI are listed at the top of `R/graph_build.R`. All of
#' them are far smaller than a grid step.
#'
#' @param bbox Area to grid: `c(xmin, ymin, xmax, ymax)` in degrees, or an
#'   `sf::st_bbox()`. Defaults to the bounding box of `include` (and
#'   `include2`).
#' @param step_km Node spacing in km inside `include`, or over the whole box
#'   when `include` is `NULL`.
#' @param include,include2 Optional polygons (sf/sfc object, or a path to a
#'   shapefile or any file [sf::st_read()] can open) where nodes are placed.
#' @param step2_km Node spacing inside `include2`.
#' @param outside_step_km If given, the part of `bbox` outside both include
#'   areas is gridded at this spacing too. `NULL` (the default) leaves it
#'   empty.
#' @param exclude Optional polygons (usually land) where no node may lie.
#' @param type `"hex"` (the GUI default) or `"quad"`.
#' @param method `"geodesic"` (the GUI's "Hex"/"Quad") spaces nodes evenly
#'   along geodesics. `"planar"` (the GUI's "trivial" types) uses fixed
#'   longitude columns, so the east-west spacing shrinks towards the poles.
#' @param max_edge_km Drop edges at least this long. `NULL` keeps all edges,
#'   as the GUI does by default, but some value is almost always wanted.
#'   Triangulation closes the convex hull of the nodes, so it draws long edges
#'   across bays, around headlands and, with `method = "geodesic"`, along the
#'   south (or north) edge of the box, where the geodesic rows bow away from
#'   the straight hull. About 1.5 times the coarsest step keeps every lattice
#'   edge and drops those.
#' @param drop_edges_touching_exclude Drop edges that cross or touch `exclude`.
#'   The GUI always does this when an exclusion shapefile is given.
#' @param a_graph Graph number, stored on the result for
#'   [write_displace_graph()].
#'
#' @return A `displace_graph` (see [read_displace_graph()]). `nodes` has
#'   `harbour = 0` throughout, and `edges` lists every link in both
#'   directions.
#' @export
#' @examples
#' \dontrun{
#' sea  <- sf::st_read("study_area.shp")
#' land <- sf::st_read("coastline.shp")
#' g <- build_displace_graph(step_km = 10, include = sea, exclude = land,
#'                           max_edge_km = 30)
#' g <- link_displace_harbours(g, ports)
#' write_displace_graph(g, "DISPLACE_input_mycase", a_graph = 1)
#' }
build_displace_graph <- function(bbox = NULL,
                                 step_km,
                                 include = NULL,
                                 include2 = NULL,
                                 step2_km = NULL,
                                 outside_step_km = NULL,
                                 exclude = NULL,
                                 type = c("hex", "quad"),
                                 method = c("geodesic", "planar"),
                                 max_edge_km = NULL,
                                 drop_edges_touching_exclude = TRUE,
                                 a_graph = 1L) {
  need_pkg("sf", "build_displace_graph()")
  type <- match.arg(type)
  method <- match.arg(method)

  old_s2 <- suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(old_s2)), add = TRUE)

  include <- as_lonlat_polygons(include, "include")
  include2 <- as_lonlat_polygons(include2, "include2")
  exclude <- as_lonlat_polygons(exclude, "exclude")

  if (!is.null(include2) && is.null(include)) {
    stopf("include2 needs include; pass a single area as include.")
  }
  if (!is.null(include2) && is.null(step2_km)) {
    stopf("include2 needs step2_km.")
  }

  if (is.null(bbox)) {
    if (is.null(include)) {
      stopf("give bbox, or include to take the box from.")
    }
    bbox <- sf::st_bbox(if (is.null(include2)) include else c(include, include2))
  }
  bbox <- unclass(bbox)[1:4]
  names(bbox) <- c("xmin", "ymin", "xmax", "ymax")
  if (!(bbox[["xmax"]] > bbox[["xmin"]] && bbox[["ymax"]] > bbox[["ymin"]])) {
    stopf("bbox must have xmax > xmin and ymax > ymin.")
  }

  ## createMainGrid(): each grid is clipped to its own area, and an overlap
  ## goes to whichever grid is finer.
  parts <- list()
  if (is.null(include)) {
    parts$main <- make_grid(bbox, step_km, type, method)
  } else {
    g <- make_grid(bbox, step_km, type, method)
    keep <- points_in(g, include)
    if (!is.null(include2) && step2_km < step_km) {
      keep <- keep & !points_in(g, include2)
    }
    parts$include <- g[keep, , drop = FALSE]

    if (!is.null(include2)) {
      g <- make_grid(bbox, step2_km, type, method)
      keep <- points_in(g, include2)
      if (step_km < step2_km) {
        keep <- keep & !points_in(g, include)
      }
      parts$include2 <- g[keep, , drop = FALSE]
    }

    if (!is.null(outside_step_km)) {
      g <- make_grid(bbox, outside_step_km, type, method)
      parts$outside <- g[!points_in(g, include) & !points_in(g, include2), , drop = FALSE]
    }
  }

  pts <- do.call(rbind, unname(parts))
  pts <- pts[!points_in(pts, exclude), , drop = FALSE]
  pts <- pts[!duplicated(pts), , drop = FALSE]
  rownames(pts) <- NULL
  if (nrow(pts) < 3L) {
    stopf(paste0("only %d node(s) survive clipping; need at least 3 to ",
                 "triangulate. Check step_km, bbox and the include/exclude ",
                 "polygons."), nrow(pts))
  }

  edges <- delaunay_edges(pts)
  dist_m <- geod_inverse(pts$lat[edges$a], pts$lon[edges$a],
                         pts$lat[edges$b], pts$lon[edges$b])$s12
  if (!is.null(max_edge_km)) {
    keep <- dist_m < max_edge_km * 1000
    edges <- edges[keep, , drop = FALSE]
    dist_m <- dist_m[keep]
  }
  ## buildGraph(): std::floor(d / 1000 + 0.5), i.e. whole km.
  edges$dist_km <- floor(dist_m / 1000 + 0.5)

  if (!is.null(exclude) && isTRUE(drop_edges_touching_exclude) && nrow(edges)) {
    lines <- sf::st_sfc(lapply(seq_len(nrow(edges)), function(i) {
      sf::st_linestring(rbind(
        c(pts$lon[edges$a[i]], pts$lat[edges$a[i]]),
        c(pts$lon[edges$b[i]], pts$lat[edges$b[i]])
      ))
    }), crs = sf::st_crs(exclude))
    hit <- suppressMessages(sf::st_intersects(lines, exclude))
    edges <- edges[lengths(hit) == 0L, , drop = FALSE]
  }

  graph_from_parts(pts, edges, a_graph)
}

## Undirected Delaunay edges of a point set, as 1-based index pairs (a < b).
## GEOS returns the input coordinates unchanged, so edges are matched back to
## points by exact coordinate.
delaunay_edges <- function(pts) {
  mp <- sf::st_sfc(sf::st_multipoint(as.matrix(pts[, c("lon", "lat")])))
  tri <- sf::st_triangulate(mp, bOnlyEdges = TRUE)
  xy <- sf::st_coordinates(tri)
  seg <- xy[, "L1"]
  key <- function(x, y) paste(sprintf("%.17g", x), sprintf("%.17g", y))
  idx <- match(key(xy[, "X"], xy[, "Y"]), key(pts$lon, pts$lat))
  if (anyNA(idx)) {
    stopf("internal error: triangulation returned coordinates not in the grid.")
  }
  first <- !duplicated(seg)
  last <- !duplicated(seg, fromLast = TRUE)
  a <- idx[first]
  b <- idx[last]
  e <- data.frame(a = pmin(a, b), b = pmax(a, b))
  e <- e[e$a != e$b & !duplicated(e), , drop = FALSE]
  e[order(e$a, e$b), , drop = FALSE]
}

## Assemble a displace_graph from 1-based undirected edges carrying dist_km.
## Every edge is written in both directions, grouped by source node -- the
## order InputFileExporter::exportGraph() produces.
graph_from_parts <- function(nodes, edges, a_graph, harbour = NULL) {
  n <- nrow(nodes)
  d_km <- edges$dist_km
  directed <- data.frame(
    from = c(edges$a, edges$b) - 1L,
    to = c(edges$b, edges$a) - 1L,
    dist_km = c(d_km, d_km)
  )
  directed <- directed[order(directed$from, directed$to), , drop = FALSE]
  rownames(directed) <- NULL

  node_df <- data.frame(
    node_id = seq_len(n) - 1L,
    lon = nodes$lon,
    lat = nodes$lat,
    harbour = if (is.null(harbour)) rep(0L, n) else as.integer(harbour)
  )
  if (!is.null(nodes$harbour_name)) {
    node_df$harbour_name <- nodes$harbour_name
  }

  degree <- tabulate(directed$from + 1L, nbins = n)
  if (any(degree == 0L)) {
    warnf(paste0("%d node(s) have no edges and cannot be reached by vessels ",
                 "(first: node %d). Relax max_edge_km or check the exclude ",
                 "polygons."),
          sum(degree == 0L), which(degree == 0L)[1] - 1L)
  }

  structure(list(nodes = node_df, edges = directed, a_graph = a_graph,
                 nrow_coord = n, nrow_graph = nrow(directed)),
            class = "displace_graph")
}

#' Add harbours to a DISPLACE graph and link them to nearby nodes
#'
#' An R implementation of the editor GUI's "Load Harbours" and "Link
#' Harbours" actions. Each harbour is appended to the graph as a new node with
#' its harbour code in the `harbour` column. It is then linked, in both
#' directions, to its `max_links` nearest nodes within `max_dist_km`.
#'
#' @param graph A `displace_graph`, e.g. from [build_displace_graph()].
#' @param harbours A data frame with `lon`, `lat` and, optionally, `name` and
#'   `harbour` (the non-zero code written to the coord file; defaults to
#'   `1`). Or a path to a GUI harbour file: `name;lon;lat;code` with a header
#'   line.
#' @param max_dist_km Search radius. The GUI default is 15 km.
#' @param max_links Maximum links per harbour, nearest first. `NA` means no
#'   limit. The GUI default is 3.
#' @param avoid_lonely If a harbour finds nothing within `max_dist_km`, keep
#'   doubling the radius until it does. The GUI does this by default.
#' @param avoid_harbour_links Never link a harbour to another harbour. The GUI
#'   does this by default.
#'
#' @return The graph with harbours appended to `nodes` and their links added
#'   to `edges`. As in the GUI, link weights are exact km, not rounded like sea
#'   edges. The simulator truncates weights when it loads them, so a harbour
#'   link shorter than 1 km weighs 0 in the model.
#' @export
link_displace_harbours <- function(graph, harbours,
                                   max_dist_km = 15,
                                   max_links = 3L,
                                   avoid_lonely = TRUE,
                                   avoid_harbour_links = TRUE) {
  stopifnot(is.list(graph), is.data.frame(graph$nodes))
  if (is.character(harbours)) {
    harbours <- read_gui_harbour_file(harbours)
  }
  for (col in c("lon", "lat")) {
    if (is.null(harbours[[col]])) {
      stopf("harbours needs a '%s' column", col)
    }
  }
  code <- as.integer(harbours$harbour %||% rep(1L, nrow(harbours)))
  if (any(code == 0L)) {
    stopf("harbour codes must be non-zero: 0 marks a sea node in coord<N>.dat.")
  }

  old <- graph$nodes
  n_old <- nrow(old)
  nodes <- data.frame(
    lon = c(old$lon, harbours$lon),
    lat = c(old$lat, harbours$lat)
  )
  harbour_flag <- c(old$harbour, code)
  nodes$harbour_name <- c(old$harbour_name %||% rep(NA_character_, n_old),
                          as.character(harbours$name %||% rep(NA_character_, nrow(harbours))))

  ## Existing edges back to 1-based undirected pairs.
  e <- graph$edges
  keep <- e$from < e$to
  edges <- data.frame(a = e$from[keep] + 1L, b = e$to[keep] + 1L,
                      dist_km = e$dist_km[keep])

  new_edges <- list()
  for (h in seq_len(nrow(harbours))) {
    hi <- n_old + h
    cand <- setdiff(seq_len(nrow(nodes)), hi)
    if (avoid_harbour_links) {
      cand <- cand[harbour_flag[cand] == 0L]
    }
    if (!length(cand)) {
      warnf("harbour %d has no node it may link to.", h)
      next
    }
    d <- geod_inverse(nodes$lat[hi], nodes$lon[hi], nodes$lat[cand], nodes$lon[cand])$s12
    radius <- max_dist_km * 1000
    repeat {
      within <- which(d <= radius)
      if (length(within) || !avoid_lonely) break
      radius <- radius * 2
    }
    if (!length(within)) {
      warnf("harbour %d has no node within %g km and is left unlinked.", h, max_dist_km)
      next
    }
    within <- within[order(d[within])]
    if (!is.na(max_links) && max_links >= 0L) {
      within <- utils::head(within, max_links)
    }
    ## The GUI adds these as snodes[i].weight / 1000.0, unrounded.
    new_edges[[h]] <- data.frame(a = pmin(hi, cand[within]),
                                 b = pmax(hi, cand[within]),
                                 dist_km = d[within] / 1000)
  }

  edges <- do.call(rbind, c(list(edges), new_edges))
  out <- graph_from_parts(nodes, edges, graph$a_graph, harbour = harbour_flag)
  ## Harbours are appended, so existing node ids -- and any closures recorded
  ## against them by add_displace_closure() -- are unchanged.
  out$closures <- graph$closures
  out
}

## The file the GUI's "Load Harbours" reads (InputFileParser::parseHarbourFile):
## one header line, then `name;x;y;code`.
read_gui_harbour_file <- function(path) {
  lines <- readLines(path, warn = FALSE)[-1]
  lines <- lines[nzchar(trim(lines))]
  f <- strsplit(lines, ";", fixed = TRUE)
  bad <- which(lengths(f) < 4L)
  if (length(bad)) {
    stopf("%s: line %d does not have 4 ';'-separated fields", path, bad[1] + 1L)
  }
  out <- data.frame(
    name = vapply(f, `[`, "", 1L),
    lon = as.numeric(vapply(f, `[`, "", 2L)),
    lat = as.numeric(vapply(f, `[`, "", 3L)),
    harbour = as.integer(vapply(f, `[`, "", 4L)),
    stringsAsFactors = FALSE
  )
  if (anyNA(out[, c("lon", "lat", "harbour")])) {
    stopf("%s: cannot parse coordinates or harbour codes", path)
  }
  out
}
