## simusspe_<name>/<scenario>.dat
##
## Field layout transcribed from read_scenario_config_file() and
## importScenario(), commons/readdata.cpp:179 and :292.
##
## Note: commons/commons_tests/inputfiles_simusspe.cpp carries a fixture that
## predates the met_multiplier_on_arbitary_breaks_for_tariff field at line 47
## and is off by one from there on. readdata.cpp is the authority.
##
## The 'arbitary' spelling is upstream's and is preserved here: it is the key
## the parser looks for, and renaming it in R would only invite a mismatch.

SCENARIO_SPEC <- c(
  dyn_alloc_sce                                = 1L,
  dyn_pop_sce                                  = 3L,
  biolsce                                      = 5L,
  fleetsce                                     = 7L,
  freq_do_growth                               = 9L,
  freq_redispatch_the_pop                      = 11L,
  a_graph                                      = 13L,
  nrow_coord                                   = 15L,
  nrow_graph                                   = 17L,
  a_port                                       = 19L,
  graph_res                                    = 21L,
  is_individual_vessel_quotas                  = 23L,
  check_all_stocks_before_going_fishing        = 25L,
  dt_go_fishing                                = 27L,
  dt_choose_ground                             = 29L,
  dt_start_fishing                             = 31L,
  dt_change_ground                             = 33L,
  dt_stop_fishing                              = 35L,
  dt_change_port                               = 37L,
  use_dtrees                                   = 39L,
  tariff_pop                                   = 41L,
  freq_update_tariff_code                      = 43L,
  arbitary_breaks_for_tariff                   = 45L,
  met_multiplier_on_arbitary_breaks_for_tariff = 47L,
  total_amount_credited                        = 49L,
  tariff_annual_hcr_percent_change             = 51L,
  update_tariffs_based_on_lpue_or_dpue_code    = 53L,
  metier_closures                              = 55L
)

SCENARIO_COMMENTS <- c(
  dyn_alloc_sce                                = "dyn_alloc_sce",
  dyn_pop_sce                                  = "dyn_pop_sce",
  biolsce                                      = "biolsce",
  fleetsce                                     = "fleetsce",
  freq_do_growth                               = "Frequency to apply growth (0:daily; 1:weekly; 2:monthly; 3:quarterly; 4:semester)",
  freq_redispatch_the_pop                      = "Frequency to redispatch the pop (0:daily; 1:weekly; 2:monthly; 3:quarterly; 4:semester)",
  a_graph                                      = "a_graph",
  nrow_coord                                   = "nrow_coord",
  nrow_graph                                   = "nrow_graph",
  a_port                                       = "a_port",
  graph_res                                    = "grid res km",
  is_individual_vessel_quotas                  = "is_individual_vessel_quotas",
  check_all_stocks_before_going_fishing        = "check all stocks before going fishing (otherwise, explicit pops only)",
  dt_go_fishing                                = "Go Fishing DTree",
  dt_choose_ground                             = "Choose Ground DTree",
  dt_start_fishing                             = "Start Fishing DTree",
  dt_change_ground                             = "Change Ground DTree",
  dt_stop_fishing                              = "Stop Fishing DTree",
  dt_change_port                               = "Change Port DTree",
  use_dtrees                                   = "Use Dtrees",
  tariff_pop                                   = "tariff_pop",
  freq_update_tariff_code                      = "Freq_update_tariff_code",
  arbitary_breaks_for_tariff                   = "arbitrary_breaks_for_tariff",
  met_multiplier_on_arbitary_breaks_for_tariff = "met_multiplier_on_arbitrary_breaks_for_tariff",
  total_amount_credited                        = "total_amount_credited",
  tariff_annual_hcr_percent_change             = "tariff_annual_hcr_percent_change",
  update_tariffs_based_on_lpue_or_dpue_code    = "freq_update_tariffs_based_on_lpue_or_dpue_code",
  metier_closures                              = "banned metiers"
)

#' Read a DISPLACE scenario file
#'
#' Reads `<input_dir>/simusspe_<input_name>/<scenario>.dat`. This is the file
#' DISPLACE's `-F` selects, and `baseline.dat` is the default one upstream
#' ships.
#'
#' It carries `nrow_coord` and `nrow_graph`, which are the row counts the
#' stacked-column graph files in `graphsspe/` are parsed with. A scenario and
#' its graph must therefore agree, and [read_displace_graph()] takes those
#' counts from here.
#'
#' @param input_dir Folder containing the `simusspe_*` subfolder.
#' @param input_name Parameterisation name (DISPLACE's `-f`).
#' @param scenario Scenario name (DISPLACE's `-F`).
#' @param path Read this exact file instead.
#'
#' @return An object of class `displace_scenario`.
#' @export
#' @examples
#' f <- tempfile(fileext = ".dat")
#' write_displace_scenario(new_displace_scenario(nrow_coord = 10, nrow_graph = 20),
#'                         path = f)
#' read_displace_scenario(path = f)
read_displace_scenario <- function(input_dir = NULL, input_name = NULL,
                                   scenario = "baseline", path = NULL) {
  path <- path %||% simusspe_file(input_dir, input_name, paste0(scenario, ".dat"))
  raw <- read_linenumber_file(path, SCENARIO_SPEC)

  as_int1 <- function(x, field, default = NA_integer_) {
    x <- trim_or_empty(x)
    if (!nzchar(x)) {
      return(default)
    }
    v <- suppressWarnings(as.integer(x))
    if (is.na(v)) {
      stopf("scenario file: cannot read '%s' as an integer (got '%s') in %s",
            field, x, path)
    }
    v
  }
  as_dbl1 <- function(x, field, default = NA_real_) {
    x <- trim_or_empty(x)
    if (!nzchar(x)) {
      return(default)
    }
    v <- suppressWarnings(as.numeric(x))
    if (is.na(v)) {
      stopf("scenario file: cannot read '%s' as a number (got '%s') in %s",
            field, x, path)
    }
    v
  }
  as_opts <- function(x) {
    x <- trim_or_empty(x)
    if (!nzchar(x)) character(0) else strsplit(x, "[[:space:]]+")[[1]]
  }

  graph_res <- split_nums(raw$graph_res)
  ## The simulator duplicates a single value into (res_x, res_y).
  if (length(graph_res) == 1L) {
    graph_res <- rep(graph_res, 2L)
  }

  sc <- list(
    dyn_alloc_sce = as_opts(raw$dyn_alloc_sce),
    dyn_pop_sce = as_opts(raw$dyn_pop_sce),
    ## biolsce and fleetsce are used verbatim as filename suffixes
    ## (init_pops_per_szgroup_biolsce<N>.dat), so they stay strings.
    biolsce = trim_or_empty(raw$biolsce),
    fleetsce = trim_or_empty(raw$fleetsce),
    freq_do_growth = as_int1(raw$freq_do_growth, "freq_do_growth"),
    freq_redispatch_the_pop = as_int1(raw$freq_redispatch_the_pop, "freq_redispatch_the_pop"),
    a_graph = as_int1(raw$a_graph, "a_graph"),
    nrow_coord = as_int1(raw$nrow_coord, "nrow_coord"),
    nrow_graph = as_int1(raw$nrow_graph, "nrow_graph"),
    a_port = as_int1(raw$a_port, "a_port"),
    graph_res = graph_res,
    is_individual_vessel_quotas = as_int1(raw$is_individual_vessel_quotas,
                                          "is_individual_vessel_quotas") != 0L,
    check_all_stocks_before_going_fishing =
      as_int1(raw$check_all_stocks_before_going_fishing,
              "check_all_stocks_before_going_fishing") != 0L,
    dt_go_fishing = trim_or_empty(raw$dt_go_fishing),
    dt_choose_ground = trim_or_empty(raw$dt_choose_ground),
    dt_start_fishing = trim_or_empty(raw$dt_start_fishing),
    dt_change_ground = trim_or_empty(raw$dt_change_ground),
    dt_stop_fishing = trim_or_empty(raw$dt_stop_fishing),
    dt_change_port = trim_or_empty(raw$dt_change_port),
    use_dtrees = as_int1(raw$use_dtrees, "use_dtrees", 0L) != 0L,
    tariff_pop = split_nums(raw$tariff_pop, "integer"),
    freq_update_tariff_code = as_int1(raw$freq_update_tariff_code,
                                      "freq_update_tariff_code", 0L),
    arbitary_breaks_for_tariff = split_nums(raw$arbitary_breaks_for_tariff),
    met_multiplier_on_arbitary_breaks_for_tariff =
      split_nums(raw$met_multiplier_on_arbitary_breaks_for_tariff),
    total_amount_credited = as_int1(raw$total_amount_credited,
                                    "total_amount_credited", 0L),
    tariff_annual_hcr_percent_change =
      as_dbl1(raw$tariff_annual_hcr_percent_change,
              "tariff_annual_hcr_percent_change", 0),
    update_tariffs_based_on_lpue_or_dpue_code =
      as_int1(raw$update_tariffs_based_on_lpue_or_dpue_code,
              "update_tariffs_based_on_lpue_or_dpue_code", 0L),
    metier_closures = split_nums(raw$metier_closures, "integer"),
    path = path
  )
  structure(sc, class = "displace_scenario")
}

#' Build a DISPLACE scenario
#'
#' Defaults reproduce a plain baseline run: no dynamic allocation or population
#' options beyond `baseline`, decision trees off, tariffs off.
#'
#' @param nrow_coord Number of nodes. Must equal one third of the line count of
#'   `graphsspe/coord<a_graph>.dat`.
#' @param nrow_graph Number of edges. Must equal one third of the line count of
#'   `graphsspe/graph<a_graph>.dat`.
#' @param a_graph Graph number; selects `coord<N>.dat` / `graph<N>.dat`.
#' @param a_port Node id of the default port.
#' @param graph_res Grid resolution in km. A single value is duplicated into
#'   (x, y), matching the simulator.
#' @param dyn_alloc_sce,dyn_pop_sce Option names, as character vectors.
#' @param biolsce,fleetsce Scenario suffixes used in input filenames. Strings,
#'   not numbers, because that is how they are pasted into filenames.
#' @param freq_do_growth,freq_redispatch_the_pop Frequencies: 0 daily, 1
#'   weekly, 2 monthly, 3 quarterly, 4 semester.
#' @param is_individual_vessel_quotas,check_all_stocks_before_going_fishing
#'   Logical switches.
#' @param use_dtrees Whether to use decision trees.
#' @param dt_go_fishing,dt_choose_ground,dt_start_fishing,dt_change_ground,dt_stop_fishing,dt_change_port
#'   Decision tree names, only meaningful when `use_dtrees` is `TRUE`.
#' @param tariff_pop,freq_update_tariff_code,arbitary_breaks_for_tariff,met_multiplier_on_arbitary_breaks_for_tariff,total_amount_credited,tariff_annual_hcr_percent_change,update_tariffs_based_on_lpue_or_dpue_code
#'   Tariff (fishing credits) settings. The `arbitary` spelling is upstream's.
#' @param metier_closures Integer vector of banned metier ids.
#'
#' @return A `displace_scenario`.
#' @export
#' @examples
#' new_displace_scenario(nrow_coord = 1000, nrow_graph = 5000, a_graph = 1)
new_displace_scenario <- function(nrow_coord,
                                  nrow_graph,
                                  a_graph = 1L,
                                  a_port = 0L,
                                  graph_res = 10,
                                  dyn_alloc_sce = "baseline",
                                  dyn_pop_sce = "baseline",
                                  biolsce = "1",
                                  fleetsce = "1",
                                  freq_do_growth = 0L,
                                  freq_redispatch_the_pop = 0L,
                                  is_individual_vessel_quotas = FALSE,
                                  check_all_stocks_before_going_fishing = FALSE,
                                  use_dtrees = FALSE,
                                  dt_go_fishing = "",
                                  dt_choose_ground = "",
                                  dt_start_fishing = "",
                                  dt_change_ground = "",
                                  dt_stop_fishing = "",
                                  dt_change_port = "",
                                  tariff_pop = integer(0),
                                  freq_update_tariff_code = 0L,
                                  arbitary_breaks_for_tariff = numeric(0),
                                  met_multiplier_on_arbitary_breaks_for_tariff = numeric(0),
                                  total_amount_credited = 0L,
                                  tariff_annual_hcr_percent_change = 0,
                                  update_tariffs_based_on_lpue_or_dpue_code = 0L,
                                  metier_closures = integer(0)) {
  if (length(graph_res) == 1L) {
    graph_res <- rep(graph_res, 2L)
  }
  structure(
    list(
      dyn_alloc_sce = as.character(dyn_alloc_sce),
      dyn_pop_sce = as.character(dyn_pop_sce),
      biolsce = as.character(biolsce),
      fleetsce = as.character(fleetsce),
      freq_do_growth = as.integer(freq_do_growth),
      freq_redispatch_the_pop = as.integer(freq_redispatch_the_pop),
      a_graph = as.integer(a_graph),
      nrow_coord = as.integer(nrow_coord),
      nrow_graph = as.integer(nrow_graph),
      a_port = as.integer(a_port),
      graph_res = as.numeric(graph_res),
      is_individual_vessel_quotas = isTRUE(is_individual_vessel_quotas),
      check_all_stocks_before_going_fishing = isTRUE(check_all_stocks_before_going_fishing),
      dt_go_fishing = dt_go_fishing,
      dt_choose_ground = dt_choose_ground,
      dt_start_fishing = dt_start_fishing,
      dt_change_ground = dt_change_ground,
      dt_stop_fishing = dt_stop_fishing,
      dt_change_port = dt_change_port,
      use_dtrees = isTRUE(use_dtrees),
      tariff_pop = as.integer(tariff_pop),
      freq_update_tariff_code = as.integer(freq_update_tariff_code),
      arbitary_breaks_for_tariff = as.numeric(arbitary_breaks_for_tariff),
      met_multiplier_on_arbitary_breaks_for_tariff =
        as.numeric(met_multiplier_on_arbitary_breaks_for_tariff),
      total_amount_credited = as.integer(total_amount_credited),
      tariff_annual_hcr_percent_change = as.numeric(tariff_annual_hcr_percent_change),
      update_tariffs_based_on_lpue_or_dpue_code =
        as.integer(update_tariffs_based_on_lpue_or_dpue_code),
      metier_closures = as.integer(metier_closures),
      path = NA_character_
    ),
    class = "displace_scenario"
  )
}

#' Write a DISPLACE scenario file
#'
#' @param scenario_obj A `displace_scenario`.
#' @param input_dir,input_name Destination folder and parameterisation name.
#' @param scenario Scenario name; becomes `<scenario>.dat`.
#' @param path Write to this exact file instead.
#'
#' @return The path written, invisibly.
#' @export
#' @examples
#' sc <- new_displace_scenario(nrow_coord = 100, nrow_graph = 400)
#' write_displace_scenario(sc, path = tempfile(fileext = ".dat"))
write_displace_scenario <- function(scenario_obj, input_dir = NULL,
                                    input_name = NULL, scenario = "baseline",
                                    path = NULL) {
  stopifnot(inherits(scenario_obj, "displace_scenario"))
  path <- path %||% simusspe_file(input_dir, input_name, paste0(scenario, ".dat"))
  x <- scenario_obj

  values <- list(
    dyn_alloc_sce = paste(x$dyn_alloc_sce, collapse = " "),
    dyn_pop_sce = paste(x$dyn_pop_sce, collapse = " "),
    biolsce = x$biolsce,
    fleetsce = x$fleetsce,
    freq_do_growth = as.character(x$freq_do_growth),
    freq_redispatch_the_pop = as.character(x$freq_redispatch_the_pop),
    a_graph = as.character(x$a_graph),
    nrow_coord = as.character(x$nrow_coord),
    nrow_graph = as.character(x$nrow_graph),
    a_port = as.character(x$a_port),
    graph_res = join_nums(x$graph_res),
    is_individual_vessel_quotas = as.character(as.integer(x$is_individual_vessel_quotas)),
    check_all_stocks_before_going_fishing =
      as.character(as.integer(x$check_all_stocks_before_going_fishing)),
    dt_go_fishing = x$dt_go_fishing,
    dt_choose_ground = x$dt_choose_ground,
    dt_start_fishing = x$dt_start_fishing,
    dt_change_ground = x$dt_change_ground,
    dt_stop_fishing = x$dt_stop_fishing,
    dt_change_port = x$dt_change_port,
    use_dtrees = as.character(as.integer(x$use_dtrees)),
    tariff_pop = join_nums(x$tariff_pop),
    freq_update_tariff_code = as.character(x$freq_update_tariff_code),
    arbitary_breaks_for_tariff = join_nums(x$arbitary_breaks_for_tariff),
    met_multiplier_on_arbitary_breaks_for_tariff =
      join_nums(x$met_multiplier_on_arbitary_breaks_for_tariff),
    total_amount_credited = as.character(x$total_amount_credited),
    tariff_annual_hcr_percent_change = fmt_num(x$tariff_annual_hcr_percent_change),
    update_tariffs_based_on_lpue_or_dpue_code =
      as.character(x$update_tariffs_based_on_lpue_or_dpue_code),
    metier_closures = join_nums(x$metier_closures)
  )

  write_linenumber_file(path, SCENARIO_SPEC, values, SCENARIO_COMMENTS)
}

#' @export
print.displace_scenario <- function(x, ...) {
  cat("<displace_scenario>\n")
  cat("  graph:       a_graph", x$a_graph,
      sprintf("  (%d nodes, %d edges)", x$nrow_coord, x$nrow_graph), "\n", sep = "")
  cat("  resolution:  ", join_nums(x$graph_res), " km\n", sep = "")
  cat("  allocation:  ", paste(x$dyn_alloc_sce, collapse = " "), "\n", sep = "")
  cat("  population:  ", paste(x$dyn_pop_sce, collapse = " "), "\n", sep = "")
  cat("  biolsce:     ", x$biolsce, "   fleetsce: ", x$fleetsce, "\n", sep = "")
  cat("  dtrees:      ", if (x$use_dtrees) "on" else "off", "\n", sep = "")
  if (length(x$metier_closures)) {
    cat("  closures:    metiers ", join_nums(x$metier_closures), "\n", sep = "")
  }
  invisible(x)
}
