## Synthetic application for the grounds_by_port feature patch.
##
## Built on the public DISPLACE_input_minitest dataset (parameterisation "fake",
## a 41-node grid with one harbour), which is the only runnable case study the
## tests can count on. Everything vessel- and port-specific is synthetic:
##
##   * two more harbours, so there are three ports: 36 (NW), 40 (NE), 4 (SW);
##   * `n_vessels` vessels cloned from DNK001's features and economics;
##   * per vessel, port-tagged grounds near each port, with vessel-specific port
##     shares, and node 26 tagged twice (port 36 with metier 1, port 40 with
##     metier 0) to exercise a node shared by two ports and two metiers;
##   * the last vessel gets no fgrounds_harbours file (baseline fallback) and the
##     one before it only has one in quarter 1.
##
## Scenarios written next to minitest's own:
##   gbp          baseline + grounds_by_port
##   gbpnochange  as gbp, plus a ChangeGround dtree that never changes ground,
##                so a trip keeps the metier it was drawn with (clean shares)
##   gbpclosure   gbp + area_monthly_closure, with node 30 closed to metier 0
##                and node 26 closed to metier 0, all year, all sizes/nations
##
## No confidential data is involved anywhere.

GBP_PORTS <- c(36L, 40L, 4L)

## entries per port: ground node, metier, relative hours within the port
GBP_LAYOUT <- data.frame(
  harbour  = c(36L, 36L, 36L, 40L, 40L, 40L, 4L, 4L, 4L),
  pt_graph = c(30L, 25L, 26L, 33L, 34L, 26L, 5L, 0L, 12L),
  metier   = c(0L,  1L,  1L,  0L,  1L,  0L, 0L, 1L, 0L),
  rel      = c(3,   2,   1,   2,   2,   1,  4,  1,  1)
)

## port shares per synthetic vessel, recycled
GBP_SHARES <- list(c(0.6, 0.3, 0.1), c(0.2, 0.5, 0.3), c(1/3, 1/3, 1/3),
                   c(0.1, 0.1, 0.8), c(0.5, 0.5, 0), c(0.7, 0.2, 0.1))

minitest_source_dir <- function() {
  d <- Sys.getenv("DISPLACE_MINITEST_DIR", "")
  if (!nzchar(d) || !dir.exists(d)) NULL else d
}

## The patched simulator: DISPLACE_GBP_BINARY, else displace_path() if that
## build carries the grounds-by-port patch.
gbp_binary <- function() {
  b <- Sys.getenv("DISPLACE_GBP_BINARY", "")
  if (!nzchar(b)) b <- displace_path(error = FALSE)
  if (is.na(b) || !file.exists(b)) return(NULL)
  feats <- displaceR:::binary_feature_patches(b)
  if (!"grounds-by-port" %in% feats) return(NULL)
  b
}

skip_without_gbp <- function() {
  if (is.null(minitest_source_dir())) {
    testthat::skip("DISPLACE_MINITEST_DIR is not set to an unpacked minitest dataset")
  }
  if (is.null(gbp_binary())) {
    testthat::skip("no grounds-by-port DISPLACE build (set DISPLACE_GBP_BINARY)")
  }
}

## The port-tagged entries of the synthetic fleet, one row per vessel x quarter
## x entry, with weights in "hours".
gbp_entries <- function(vessels) {
  rows <- list()
  for (i in seq_along(vessels)) {
    sh <- GBP_SHARES[[(i - 1L) %% length(GBP_SHARES) + 1L]]
    qs <- if (i == length(vessels)) integer() else if (i == length(vessels) - 1L) 1L else 1:4
    for (q in qs) {
      lay <- GBP_LAYOUT
      ## quarter 3 swaps the first two ports' shares, so a quarterly reload shows
      s <- if (q == 3L) sh[c(2, 1, 3)] else sh
      port_share <- s[match(lay$harbour, GBP_PORTS)]
      within <- lay$rel / stats::ave(lay$rel, lay$harbour, FUN = sum)
      w <- 1000 * port_share * within
      keep <- w > 0
      rows[[length(rows) + 1L]] <- data.frame(
        vessel = vessels[i], quarter = q, pt_graph = lay$pt_graph[keep],
        metier = lay$metier[keep], harbour = lay$harbour[keep], weight = w[keep])
    }
  }
  do.call(rbind, rows)
}

make_grounds_by_port_app <- function(base = minitest_source_dir(), dest = tempfile("gbp-"),
                                     n_vessels = 6L) {
  stopifnot(!is.null(base), dir.exists(base))
  dir.create(dest, recursive = TRUE)
  file.copy(list.files(base, full.names = TRUE, all.files = FALSE), dest, recursive = TRUE)
  name <- "fake"
  vdir <- file.path(dest, paste0("vesselsspe_", name))
  hdir <- file.path(dest, paste0("harboursspe_", name))

  ## Harbours: flag the new ports in the third block of coord0.dat and give them
  ## the same prices as port 36.
  sc <- read_displace_scenario(dest, name, "baseline")
  n <- sc$nrow_coord
  coord <- readLines(file.path(dest, "graphsspe", sprintf("coord%d.dat", sc$a_graph)))
  coord[2L * n + GBP_PORTS + 1L] <- "1"
  writeLines(coord, file.path(dest, "graphsspe", sprintf("coord%d.dat", sc$a_graph)))
  for (p in setdiff(GBP_PORTS, 36L)) {
    for (f in list.files(hdir, pattern = "^36_quarter")) {
      file.copy(file.path(hdir, f), file.path(hdir, sub("^36_", paste0(p, "_"), f)))
    }
  }
  writeLines(c("pt_graph name_harbour", "36 PORT_NW", "40 PORT_NE", "4 PORT_SW"),
             file.path(hdir, "names_harbours.dat"))

  ## Vessels, cloned from DNK001.
  vessels <- sprintf("DNK%03d", seq_len(n_vessels))
  clone_lines <- function(file, sep) {
    p <- file.path(vdir, file)
    l <- readLines(p, warn = FALSE)
    hdr <- if (sep == "|") character() else l[1]
    body <- if (sep == "|") l else l[-1]
    body <- body[nzchar(trim(body))]
    first <- vapply(strsplit(body, sep, fixed = TRUE), `[`, "", 1)
    proto <- body[first == "DNK001"]
    out <- unlist(lapply(vessels, function(v) sub("^DNK001", v, proto)))
    writeLines(c(hdr, out), p)
  }
  for (q in 1:4) clone_lines(sprintf("vesselsspe_features_quarter%d.dat", q), "|")
  clone_lines("vesselsspe_economic_features.dat", "|")
  for (s in 1:2) {
    clone_lines(sprintf("vesselsspe_betas_semester%d.dat", s), " ")
    clone_lines(sprintf("vesselsspe_percent_tacs_per_pop_semester%d.dat", s), " ")
  }
  clone_lines("initial_share_fishing_credits_per_vid.dat", " ")
  unlink(list.files(vdir, pattern = "^(DNK|not_used)", full.names = TRUE))

  entries <- gbp_entries(vessels)
  write_displace_fgrounds_harbours(entries, dest, name)

  ## The vessel-wide files every vessel still needs: grounds (the union of its
  ## entries' nodes, plus the full layout for the vessels without entries),
  ## harbours, metiers on grounds and per-node catch parameters.
  cfg <- read_displace_config(dest, name)
  lines <- list(fg = "vid idx_nodes", ffg = "vid freq", h = "vid idxnode", fh = "vid freq")
  for (q in 1:4) {
    fg <- lines$fg; ffg <- lines$ffg; h <- lines$h; fh <- lines$fh
    for (i in seq_along(vessels)) {
      v <- vessels[i]
      e <- entries[entries$vessel == v & entries$quarter == q, , drop = FALSE]
      if (!nrow(e)) {
        lay <- GBP_LAYOUT
        e <- data.frame(pt_graph = lay$pt_graph, metier = lay$metier,
                        harbour = lay$harbour, weight = lay$rel)
      }
      node_w <- tapply(e$weight, e$pt_graph, sum)
      node_w <- node_w[order(as.integer(names(node_w)))]
      fg <- c(fg, paste(v, names(node_w)))
      ffg <- c(ffg, paste(v, signif(node_w / sum(node_w), 6)))
      port_w <- tapply(e$weight, e$harbour, sum)
      port_w <- port_w[order(as.integer(names(port_w)))]
      h <- c(h, paste(v, names(port_w)))
      fh <- c(fh, paste(v, signif(port_w / sum(port_w), 6)))

      pm <- unique(e[c("pt_graph", "metier")])
      pm$w <- tapply(e$weight, paste(e$pt_graph, e$metier), sum)[paste(pm$pt_graph, pm$metier)]
      pm$f <- pm$w / stats::ave(pm$w, pm$pt_graph, FUN = sum)
      pm <- pm[order(pm$pt_graph, pm$metier), ]
      writeLines(c("fground metier", paste(pm$pt_graph, pm$metier)),
                 file.path(vdir, sprintf("%s_possible_metiers_quarter%d.dat", v, q)))
      writeLines(c("fground freq", paste(pm$pt_graph, signif(pm$f, 6))),
                 file.path(vdir, sprintf("%s_freq_possible_metiers_quarter%d.dat", v, q)))
      nodes <- sort(as.integer(names(node_w)))
      for (kind in c("gshape", "gscale")) {
        val <- if (kind == "gshape") 1 else 100
        writeLines(c(paste("pt_graph", kind),
                     paste(rep(nodes, each = cfg$nbpops), val)),
                   file.path(vdir, sprintf("%s_%s_cpue_per_stk_on_nodes_quarter%d.dat", v, kind, q)))
      }
    }
    writeLines(fg, file.path(vdir, sprintf("vesselsspe_fgrounds_quarter%d.dat", q)))
    writeLines(ffg, file.path(vdir, sprintf("vesselsspe_freq_fgrounds_quarter%d.dat", q)))
    writeLines(h, file.path(vdir, sprintf("vesselsspe_harbours_quarter%d.dat", q)))
    writeLines(fh, file.path(vdir, sprintf("vesselsspe_freq_harbours_quarter%d.dat", q)))
  }

  ## Scenarios.
  gbp <- sc
  gbp$dyn_alloc_sce <- c("baseline", "grounds_by_port")
  write_displace_scenario(gbp, dest, name, scenario = "gbp")

  writeLines(c("#TreeVersion: 7", "#TreeType: ChangeGround",
               "# id,variable,posx,posy,nchld,children...,value",
               "0,probability,0,0,0,0"),
             file.path(dest, "dtrees", "ChangeGround_never.dt.csv"))
  nochange <- gbp
  nochange$dt_change_ground <- "ChangeGround_never.dt.csv"
  nochange$use_dtrees <- 1L
  write_displace_scenario(nochange, dest, name, scenario = "gbpnochange")

  closure <- gbp
  closure$dyn_alloc_sce <- c("baseline", "grounds_by_port", "area_monthly_closure")
  write_displace_scenario(closure, dest, name, scenario = "gbpclosure")
  closed <- data.frame(node = c(30L, 26L), metier = c(0L, 0L))
  for (m in 1:12) {
    gdir <- file.path(dest, "graphsspe")
    writeLines(paste(1, 31, closed$node, closed$metier),
               file.path(gdir, sprintf("metier_closure_a_graph%d_month%d.dat", sc$a_graph, m)))
    writeLines(paste(1, 31, closed$node, paste(0:4, collapse = " ")),
               file.path(gdir, sprintf("vsize_closure_a_graph%d_month%d.dat", sc$a_graph, m)))
    writeLines(paste(1, 31, closed$node, paste(0:5, collapse = " ")),
               file.path(gdir, sprintf("nation_closure_a_graph%d_month%d.dat", sc$a_graph, m)))
  }

  list(dir = dest, input_name = name, vessels = vessels, entries = entries,
       closed = closed)
}
