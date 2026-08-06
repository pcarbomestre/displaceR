## graphsspe/coord<N>.dat, graph<N>.dat, code_area_for_graph<N>_points.dat
##
## These are column-stacked, not row-wise. There are no delimiters and no
## header: one value per line, and the file is three blocks of `nrow` values
## concatenated. Transcribed from fill_from_coord(), fill_from_graph() and
## fill_from_code_area() in commons/myutils.cpp:324-435.
##
## Two details from those functions that a naive implementation gets wrong:
##
##   - blank lines are skipped *without* advancing the row counter
##     (`continue` precedes `++linenum`), so padding a block with blanks does
##     not work and stray blank lines are harmless rather than fatal;
##   - reading stops at 3*nrow, so trailing content is ignored rather than
##     rejected. A file with too many rows loads silently and wrongly.
##
## `nrow` is not stored in the graph file. It comes from the *scenario* file's
## nrow_coord / nrow_graph. That coupling is the reason these functions take a
## scenario or explicit counts rather than inferring anything.
##
## graphsspe/ is a flat folder: unlike simusspe_/vesselsspe_/etc. it carries no
## `_<parameterisation>` suffix. Files are keyed by graph number instead.

read_stacked <- function(path, nrow, blocks) {
  ## blocks: named character vector, name -> "numeric" | "integer" | "skip"
  if (!file.exists(path)) {
    stopf("no such file: %s", path)
  }
  lines <- trim(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines)]          # matches the loader's blank-line skip

  need <- nrow * length(blocks)
  if (length(lines) < need) {
    stopf(paste0("%s has %d non-blank values but %d blocks of %d rows need %d. ",
                 "Either nrow is wrong (it comes from the scenario file's ",
                 "nrow_coord/nrow_graph) or the file is truncated."),
          path, length(lines), length(blocks), nrow, need)
  }
  if (length(lines) > need) {
    ## The loader would silently ignore the excess. Say so instead: it almost
    ## always means nrow and the file disagree.
    warnf(paste0("%s has %d non-blank values but only the first %d are read. ",
                 "The simulator will ignore the rest silently; check nrow."),
          path, length(lines), need)
  }

  out <- list()
  for (i in seq_along(blocks)) {
    type <- blocks[[i]]
    if (identical(type, "skip")) {
      next
    }
    chunk <- lines[((i - 1L) * nrow + 1L):(i * nrow)]
    v <- suppressWarnings(as.numeric(chunk))
    bad <- which(is.na(v))
    if (length(bad)) {
      stopf("%s: cannot parse value '%s' in block %d (%s) at row %d",
            path, chunk[bad[1]], i, names(blocks)[i], bad[1])
    }
    out[[names(blocks)[i]]] <- if (identical(type, "integer")) as.integer(v) else v
  }
  out
}

write_stacked <- function(path, columns) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  lens <- vapply(columns, length, integer(1))
  if (length(unique(lens)) != 1L) {
    stopf("all blocks must have the same length; got %s",
          paste(sprintf("%s=%d", names(lens), lens), collapse = ", "))
  }
  writeLines(unlist(lapply(columns, fmt_num), use.names = FALSE), path)
  invisible(path)
}

graphsspe_file <- function(input_dir, a_graph, what) {
  file.path(input_dir, "graphsspe", switch(
    what,
    coord = sprintf("coord%d.dat", a_graph),
    graph = sprintf("graph%d.dat", a_graph),
    code_area = sprintf("code_area_for_graph%d_points.dat", a_graph),
    landscape = sprintf("coord%d_with_landscape.dat", a_graph),
    stopf("unknown graphsspe file kind: %s", what)
  ))
}

#' Read the DISPLACE spatial graph
#'
#' Reads the node coordinates and the edge list of a case study's graph from
#' `graphsspe/coord<N>.dat` and `graphsspe/graph<N>.dat`.
#'
#' Both files are column-stacked with no header or delimiter: one value per
#' line, three blocks back to back. The number of rows per block is not in the
#' file -- it comes from `nrow_coord` / `nrow_graph` in the scenario file, which
#' is why this function wants a scenario or explicit counts.
#'
#' @param input_dir Folder containing `graphsspe/`. Note that `graphsspe` is
#'   flat: it takes no parameterisation suffix.
#' @param scenario A `displace_scenario` from [read_displace_scenario()],
#'   supplying `a_graph`, `nrow_coord` and `nrow_graph`. Alternatively give
#'   those three directly.
#' @param a_graph,nrow_coord,nrow_graph Used when `scenario` is not given.
#' @param edges Whether to read the edge file as well. `FALSE` reads nodes only,
#'   which is much cheaper on a large graph.
#'
#' @return An object of class `displace_graph`: a list with `nodes` (data frame
#'   of `node_id`, `lon`, `lat`, `harbour`) and, unless `edges = FALSE`, `edges`
#'   (data frame of `from`, `to`, `dist_km`). Node ids are 0-based, matching
#'   DISPLACE.
#' @export
#' @examples
#' \dontrun{
#' sc <- read_displace_scenario("input", "minitest")
#' g <- read_displace_graph("input", sc)
#' }
read_displace_graph <- function(input_dir,
                                scenario = NULL,
                                a_graph = NULL,
                                nrow_coord = NULL,
                                nrow_graph = NULL,
                                edges = TRUE) {
  if (!is.null(scenario)) {
    stopifnot(inherits(scenario, "displace_scenario"))
    a_graph <- a_graph %||% scenario$a_graph
    nrow_coord <- nrow_coord %||% scenario$nrow_coord
    nrow_graph <- nrow_graph %||% scenario$nrow_graph
  }
  if (is.null(a_graph) || is.null(nrow_coord)) {
    stopf(paste0("need a scenario, or both a_graph and nrow_coord. These come ",
                 "from simusspe_<name>/<scenario>.dat, not from the graph file."))
  }

  coord <- read_stacked(
    graphsspe_file(input_dir, a_graph, "coord"),
    nrow_coord,
    c(lon = "numeric", lat = "numeric", harbour = "integer")
  )

  nodes <- data.frame(
    node_id = seq_len(nrow_coord) - 1L,   # DISPLACE node ids are 0-based
    lon = coord$lon,
    lat = coord$lat,
    harbour = coord$harbour,
    stringsAsFactors = FALSE
  )

  out <- list(nodes = nodes, a_graph = a_graph,
              nrow_coord = nrow_coord, nrow_graph = nrow_graph,
              edges = NULL)

  if (isTRUE(edges)) {
    if (is.null(nrow_graph)) {
      stopf("need nrow_graph to read edges; pass edges = FALSE to skip them.")
    }
    e <- read_stacked(
      graphsspe_file(input_dir, a_graph, "graph"),
      nrow_graph,
      c(from = "integer", to = "integer", dist_km = "numeric")
    )
    out$edges <- data.frame(
      from = e$from, to = e$to,
      ## The simulator stores this in a vector<int> after a
      ## lexical_cast<double>, i.e. it truncates. Keep the file's value here
      ## and expose what the simulator will actually use alongside it.
      dist_km = e$dist_km,
      dist_km_as_used = as.integer(trunc(e$dist_km)),
      stringsAsFactors = FALSE
    )
  }

  structure(out, class = "displace_graph")
}

#' Write the DISPLACE spatial graph
#'
#' Emits `coord<N>.dat` and `graph<N>.dat` in the column-stacked layout the
#' simulator expects.
#'
#' @param graph A `displace_graph`, or a list with `nodes` and `edges` data
#'   frames using the same column names [read_displace_graph()] returns.
#' @param input_dir Folder to write `graphsspe/` into.
#' @param a_graph Graph number. Defaults to the graph's own.
#' @param code_area Optional integer vector of area codes, one per node. When
#'   given, `code_area_for_graph<N>_points.dat` is written too. The simulator
#'   reads and discards the first two blocks of that file, so they are filled
#'   with zeros.
#'
#' @return The paths written, invisibly.
#' @export
#' @examples
#' g <- list(
#'   nodes = data.frame(node_id = 0:2, lon = c(10, 11, 12),
#'                      lat = c(55, 56, 57), harbour = c(1L, 0L, 0L)),
#'   edges = data.frame(from = c(0L, 1L), to = c(1L, 2L), dist_km = c(3.2, 4.8))
#' )
#' write_displace_graph(g, tempdir(), a_graph = 1)
write_displace_graph <- function(graph, input_dir, a_graph = NULL,
                                 code_area = NULL) {
  nodes <- graph$nodes
  edges <- graph$edges
  a_graph <- a_graph %||% graph$a_graph %||%
    stopf("a_graph is required (it is part of the filename).")

  for (col in c("lon", "lat", "harbour")) {
    if (is.null(nodes[[col]])) {
      stopf("graph$nodes needs a '%s' column", col)
    }
  }

  paths <- character()

  paths["coord"] <- write_stacked(
    graphsspe_file(input_dir, a_graph, "coord"),
    list(lon = nodes$lon, lat = nodes$lat, harbour = as.integer(nodes$harbour))
  )

  if (!is.null(edges)) {
    for (col in c("from", "to", "dist_km")) {
      if (is.null(edges[[col]])) {
        stopf("graph$edges needs a '%s' column", col)
      }
    }
    if (max(c(edges$from, edges$to)) > nrow(nodes) - 1L) {
      stopf(paste0("edge endpoints reference node %d but there are only %d nodes ",
                   "(ids 0..%d)."),
            max(c(edges$from, edges$to)), nrow(nodes), nrow(nodes) - 1L)
    }
    paths["graph"] <- write_stacked(
      graphsspe_file(input_dir, a_graph, "graph"),
      list(from = as.integer(edges$from),
           to = as.integer(edges$to),
           dist_km = edges$dist_km)
    )
  }

  if (!is.null(code_area)) {
    if (length(code_area) != nrow(nodes)) {
      stopf("code_area has length %d but there are %d nodes",
            length(code_area), nrow(nodes))
    }
    ## fill_from_code_area() reads three blocks and uses only the third.
    filler <- rep(0L, nrow(nodes))
    paths["code_area"] <- write_stacked(
      graphsspe_file(input_dir, a_graph, "code_area"),
      list(ignored1 = filler, ignored2 = filler, code = as.integer(code_area))
    )
  }

  invisible(paths)
}

#' Read the per-node area codes
#'
#' Reads `graphsspe/code_area_for_graph<N>_points.dat`. The file holds three
#' stacked blocks; the simulator reads and discards the first two and uses only
#' the third, so only that one is returned.
#'
#' @param input_dir Folder containing `graphsspe/`.
#' @param a_graph Graph number.
#' @param nrow_coord Number of nodes, from the scenario file.
#'
#' @return An integer vector of length `nrow_coord`.
#' @export
#' @examples
#' \dontrun{
#' read_displace_code_area("input", a_graph = 1, nrow_coord = 1000)
#' }
read_displace_code_area <- function(input_dir, a_graph, nrow_coord) {
  res <- read_stacked(
    graphsspe_file(input_dir, a_graph, "code_area"),
    nrow_coord,
    c(ignored1 = "skip", ignored2 = "skip", code = "integer")
  )
  res$code
}

#' @export
print.displace_graph <- function(x, ...) {
  cat("<displace_graph> a_graph", x$a_graph, "\n")
  cat("  nodes: ", nrow(x$nodes),
      sprintf(" (%d harbours)", sum(x$nodes$harbour != 0L)), "\n", sep = "")
  if (!is.null(x$edges)) {
    cat("  edges: ", nrow(x$edges), "\n", sep = "")
  } else {
    cat("  edges: not read\n")
  }
  rng <- function(v) sprintf("[%.4f, %.4f]", min(v), max(v))
  cat("  lon:   ", rng(x$nodes$lon), "   lat: ", rng(x$nodes$lat), "\n", sep = "")
  invisible(x)
}
