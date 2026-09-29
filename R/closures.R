## Area closures on the graph -- an R port of the editor GUI's "Add Penalty
## from File" / "Add Penalty on Polygon", and of the closure files
## InputFileExporter::exportGraph() writes alongside the graph.
##
## One GUI penalty does two independent things:
##
##   1. Every edge that intersects the polygon gets `weight` added to its
##      distance, once per polygon it intersects. Vessels route on these
##      weights, so a large value makes them steer around the area.
##   2. Every node inside the polygon is recorded as closed, for the chosen
##      months, to the chosen metiers, vessel sizes and nations, for
##      `nbOfDaysClosed` days per month.
##
## DisplaceModel::addPenaltyToNodesByAddWeight() is declared upstream but its
## definition is not in the tree at 96eadecb, so both rules were recovered from
## a GUI-built graph instead: the westcoast case study's graph 2 (graph 1 plus
## the 2024 California wind lease areas at weight 500). There, the rules above
## reproduce every changed edge weight and every closure line exactly.
##
## Closure file format (read_metier_closures(), commons/readdata.cpp), one line
## per closed node and polygon:
##
##   <polyId> <nbOfDaysClosed> <nodeId> <id> [<id> ...]
##
## where the ids are metiers, vessel-size classes or nations depending on the
## file. The simulator reads the monthly files only -- metier_, vsize_ and
## nation_closure_a_graph<N>_month<1..12>.dat -- and only when the scenario's
## dyn_alloc_sce includes area_monthly_closure. It then needs all 36. The
## quarterly metier_closure_*_quarter*.dat reader is commented out upstream as
## deprecated, so those files are not written.

#' Close polygons on a DISPLACE graph
#'
#' An R implementation of the editor GUI's "Add Penalty from File". For each
#' polygon, every edge crossing it gets `weight` added to its distance, so
#' vessels route around it. Every node inside it is recorded as closed to the
#' given metiers, vessel sizes and nations in the given months. Calls
#' accumulate, like repeated penalties in the GUI.
#'
#' Write the closures with [write_displace_closures()], and the penalised
#' weights with [write_displace_graph()]. The simulator only applies the
#' closures when the scenario's `dyn_alloc_sce` includes
#' `area_monthly_closure`.
#'
#' @param graph A `displace_graph`, e.g. from [build_displace_graph()] or
#'   [link_displace_harbours()].
#' @param polygons Polygons to close: an sf/sfc object or a path to any file
#'   [sf::st_read()] reads. Each feature is one polygon, as in the GUI.
#' @param weight Added to the weight (km) of every edge crossing a polygon,
#'   once per polygon crossed. `0` closes nodes without changing routing.
#' @param days_closed Days closed per month (the GUI's default is 31).
#' @param months Months (1-12) the closure applies to.
#' @param metiers,vessel_sizes,nations Integer ids the area is closed to. The
#'   GUI's vessel-size classes are 0-4 and its nations 0-5. An empty vector
#'   closes it to none of that kind, and the matching file then has no
#'   entries for the node.
#' @param poly_id Written as the first field of each closure line. The
#'   simulator reads and ignores it.
#'
#' @return The graph with penalised `edges$dist_km` and the closed nodes added
#'   to `graph$closures`.
#' @export
#' @examples
#' \dontrun{
#' g <- add_displace_closure(g, "ca_lease_areas_2024.shp", weight = 500,
#'                           metiers = 0:24, vessel_sizes = c(0, 1, 2, 4),
#'                           nations = 0)
#' write_displace_graph(g, "DISPLACE_input_mycase", a_graph = 2)
#' write_displace_closures(g, "DISPLACE_input_mycase", a_graph = 2)
#' }
add_displace_closure <- function(graph, polygons,
                                 weight = 0,
                                 days_closed = 31,
                                 months = 1:12,
                                 metiers = integer(),
                                 vessel_sizes = integer(),
                                 nations = integer(),
                                 poly_id = 0L) {
  need_pkg("sf", "add_displace_closure()")
  stopifnot(is.list(graph), is.data.frame(graph$nodes), is.data.frame(graph$edges))
  months <- as.integer(months)
  if (!length(months) || any(months < 1L | months > 12L)) {
    stopf("months must be a subset of 1:12.")
  }
  if (!(days_closed >= 0 && days_closed <= 31)) {
    stopf("days_closed must be between 0 and 31.")
  }

  old_s2 <- suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(old_s2)), add = TRUE)
  polys <- as_lonlat_polygons(polygons, "polygons")

  nodes <- graph$nodes
  edges <- graph$edges

  ## 1. Edge penalty: +weight per polygon an edge intersects. Only edges whose
  ##    bounding box overlaps the polygons' are tested.
  if (weight != 0 && nrow(edges)) {
    bb <- sf::st_bbox(polys)
    x1 <- nodes$lon[edges$from + 1L]; y1 <- nodes$lat[edges$from + 1L]
    x2 <- nodes$lon[edges$to + 1L];   y2 <- nodes$lat[edges$to + 1L]
    cand <- which(pmax(x1, x2) >= bb[["xmin"]] & pmin(x1, x2) <= bb[["xmax"]] &
                  pmax(y1, y2) >= bb[["ymin"]] & pmin(y1, y2) <= bb[["ymax"]])
    if (length(cand)) {
      lines <- sf::st_sfc(lapply(cand, function(i) {
        sf::st_linestring(rbind(c(x1[i], y1[i]), c(x2[i], y2[i])))
      }), crs = sf::st_crs(polys))
      hits <- lengths(suppressMessages(sf::st_intersects(lines, polys)))
      edges$dist_km[cand] <- edges$dist_km[cand] + weight * hits
    }
  }

  ## 2. Closed nodes, polygon by polygon in feature order, as the GUI appends
  ##    them to its penalty collection.
  pts <- sf::st_as_sf(nodes[, c("lon", "lat")], coords = c("lon", "lat"),
                      crs = sf::st_crs(polys))
  inside <- suppressMessages(sf::st_intersects(polys, pts))
  node_ids <- unlist(lapply(inside, function(i) nodes$node_id[i]), use.names = FALSE)
  if (!length(node_ids)) {
    warnf("no graph node lies inside the closure polygons; only edge weights changed.")
  }
  new <- data.frame(poly_id = rep(as.integer(poly_id), length(node_ids)),
                    days_closed = rep(days_closed, length(node_ids)),
                    node_id = node_ids)
  new$months <- rep(list(months), length(node_ids))
  new$metiers <- rep(list(as.integer(metiers)), length(node_ids))
  new$vessel_sizes <- rep(list(as.integer(vessel_sizes)), length(node_ids))
  new$nations <- rep(list(as.integer(nations)), length(node_ids))

  graph$edges <- edges
  graph$closures <- rbind(graph$closures, new)
  graph
}

#' Write DISPLACE monthly closure files
#'
#' Writes `graphsspe/metier_closure_a_graph<N>_month<M>.dat`, and the
#' `vsize_closure_` and `nation_closure_` files, for all twelve months, from
#' the closures recorded by [add_displace_closure()]. Months with no closure
#' get an empty file, because the simulator needs all 36 files once
#' `area_monthly_closure` is on.
#'
#' @param graph A `displace_graph` with `closures`. A graph without any gets
#'   36 empty files, which is what the GUI writes for an unclosed graph.
#' @param input_dir Folder to write `graphsspe/` into.
#' @param a_graph Graph number. Defaults to the graph's own.
#'
#' @return The paths written, invisibly.
#' @export
write_displace_closures <- function(graph, input_dir, a_graph = NULL) {
  a_graph <- a_graph %||% graph$a_graph %||%
    stopf("a_graph is required (it is part of the filename).")
  cl <- graph$closures
  dir.create(file.path(input_dir, "graphsspe"), recursive = TRUE, showWarnings = FALSE)

  kinds <- c(metier = "metiers", vsize = "vessel_sizes", nation = "nations")
  paths <- character()
  for (m in 1:12) {
    sel <- if (is.null(cl)) integer() else
      which(vapply(cl$months, function(x) m %in% x, logical(1)) & cl$days_closed > 0)
    for (k in names(kinds)) {
      ## InputFileExporter::outputClosedPolyFile(): the id list may be empty,
      ## and the line is still written.
      lines <- vapply(sel, function(i) {
        paste(c(cl$poly_id[i], fmt_num(cl$days_closed[i]), cl$node_id[i],
                cl[[kinds[[k]]]][[i]]), collapse = " ")
      }, "")
      p <- file.path(input_dir, "graphsspe",
                     sprintf("%s_closure_a_graph%d_month%d.dat", k, a_graph, m))
      writeLines(lines, p)
      paths[length(paths) + 1L] <- p
    }
  }
  invisible(paths)
}
