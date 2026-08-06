## `withr` is not a dependency, so these two stand in for the pieces of it the
## tests need.

withr_tempfile <- function(fileext = "") {
  tempfile(fileext = fileext)
}

## Set environment variables for the duration of `code`, restoring whatever was
## there before -- including the difference between "unset" and "set to empty".
## `code` stays a promise until the variables are in place, so the block runs
## under them.
withr_env <- function(vars, code) {
  old <- Sys.getenv(names(vars), names = TRUE, unset = NA)
  on.exit({
    still_set <- old[!is.na(old)]
    if (length(still_set)) do.call(Sys.setenv, as.list(still_set))
    was_unset <- names(old)[is.na(old)]
    if (length(was_unset)) Sys.unsetenv(was_unset)
  }, add = TRUE)

  do.call(Sys.setenv, as.list(vars))
  force(code)
}

## Trivial binaries that stand in for the simulator: one exits 0, one exits 1.
## Their location is not portable -- /bin/true and /bin/false on Linux, but
## /usr/bin on macOS, where /bin has neither -- and a wrong path makes
## `system2()` fail with "error in running command", which looks like a package
## bug rather than a missing file. Resolve them against PATH instead.
exit_binary <- function(name = c("true", "false")) {
  name <- match.arg(name)
  found <- Sys.which(name)[[1]]
  if (nzchar(found)) return(unname(found))
  for (cand in file.path(c("/bin", "/usr/bin"), name)) {
    if (file.exists(cand)) return(cand)
  }
  testthat::skip(paste0("no `", name, "` executable on this host"))
}

## Build a minimal but structurally complete input tree, sufficient for
## validate_displace_input() to pass. It is not a runnable case study -- the
## per-population and per-metier data files are empty -- but it exercises every
## structural rule the validator knows about.
make_fake_input <- function(dir = tempfile(), input_name = "testcase",
                            nbpops = 2L, nrow_coord = 5L, nrow_graph = 4L,
                            a_graph = 1L, scenario = "baseline") {
  create_displace_input(dir, input_name, a_graph = a_graph, quiet = TRUE)

  cfg <- new_displace_config(nbpops = nbpops, nbmets = 3L, nbbenthospops = 2L)
  write_displace_config(cfg, dir, input_name)

  sc <- new_displace_scenario(nrow_coord = nrow_coord, nrow_graph = nrow_graph,
                              a_graph = a_graph)
  write_displace_scenario(sc, dir, input_name, scenario = scenario)

  nodes <- data.frame(
    node_id = seq_len(nrow_coord) - 1L,
    lon = seq(10, 11, length.out = nrow_coord),
    lat = seq(55, 56, length.out = nrow_coord),
    harbour = c(1L, rep(0L, nrow_coord - 1L))
  )
  edges <- data.frame(
    from = (seq_len(nrow_graph) - 1L) %% nrow_coord,
    to = seq_len(nrow_graph) %% nrow_coord,
    dist_km = seq(1.5, 4.5, length.out = nrow_graph)
  )
  write_displace_graph(list(nodes = nodes, edges = edges), dir,
                       a_graph = a_graph,
                       code_area = rep(10L, nrow_coord))

  vess <- file.path(dir, paste0("vesselsspe_", input_name))
  for (kind in c("fgrounds", "harbours")) {
    for (q in 1:4) {
      file.create(file.path(vess, sprintf("vesselsspe_%s_quarter%d.dat", kind, q)))
    }
  }

  simus <- file.path(dir, paste0("simusspe_", input_name))
  for (unit in c("months", "quarters", "semesters", "years")) {
    writeLines(c("1", "745", "-1"), file.path(simus, sprintf("tstep_%s.dat", unit)))
  }

  list(dir = dir, input_name = input_name, scenario = scenario,
       config = cfg, scenario_obj = sc, nodes = nodes, edges = edges)
}
