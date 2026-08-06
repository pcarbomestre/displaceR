## Column layouts for the text outputs.
##
## Transcribed from docs/output_fileformats.md at upstream 7f2656fb. Unlike the
## input formats in config.R / scenario.R / graph.R, these were taken from
## documentation rather than from the writers, so they are the part of this
## package most likely to drift. The golden-file test in
## tests/testthat/test-golden.R exists to catch that.
##
## Files are whitespace separated with no header row.
##
## The dispatch seam: displace_output_spec() takes a version. There is only one
## schema in the wild today, so it has nothing to dispatch on yet; the argument
## is there so that adding a second layout is a data change, not a rewrite.

## simulator/values.h: NBSZGROUP 14, NBAGE 11.
N_SZGROUPS <- 14L
N_AGES <- 11L

OUTPUT_SPECS <- list(
  vmslike = list(
    pattern = "^vmslike_",
    cols = c("tstep", "name", "tstep_dep", "x", "y", "course", "cum_fuel", "state"),
    types = c("i", "c", "i", "d", "d", "d", "d", "i")
  ),
  popstats = list(
    pattern = "^popstats_",
    ## tstep, stock, then three blocks of 14 size groups: N (thousands),
    ## W (kg), SSB (kg).
    cols = c("tstep", "stock",
             sprintf("N_szgroup%d", 0:(N_SZGROUPS - 1L)),
             sprintf("W_szgroup%d", 0:(N_SZGROUPS - 1L)),
             sprintf("SSB_szgroup%d", 0:(N_SZGROUPS - 1L))),
    types = c("i", "i", rep("d", 3L * N_SZGROUPS))
  ),
  popnodes_start = list(
    pattern = "^popnodes_start_",
    cols = NULL,          # width depends on the number of populations
    builder = "popnodes_totals",
    types = NULL
  ),
  popnodes_inc = list(
    pattern = "^popnodes_inc_",
    cols = NULL,
    builder = "popnodes_totals",
    types = NULL
  ),
  popnodes_end = list(
    pattern = "^popnodes_end_",
    cols = NULL,
    builder = "popnodes_totals",
    types = NULL
  ),
  popnodes_impact = list(
    ## Anchored past the suffix: "^popnodes_impact_" alone also matches
    ## popnodes_impact_per_szgroup_*, which has a different width entirely.
    pattern = "^popnodes_impact_(?!per_szgroup)",
    perl = TRUE,
    cols = c("pop", "tstep", "node_idx", "long", "lat", "impact_on_pop"),
    types = c("i", "i", "i", "d", "d", "d")
  ),
  popnodes_impact_per_szgroup = list(
    pattern = "^popnodes_impact_per_szgroup_",
    ## pop, tstep, node, long, lat, then one value per population.
    ## Note upstream loops over impact_per_pop.size() rather than the szgroup
    ## vector it just fetched (commons/Node.cpp:2089), so despite the name the
    ## trailing block is per-population, not per-size-group.
    cols = NULL,
    builder = "impact_per_szgroup",
    types = NULL
  ),
  popnodes_cumulcatches_per_pop = list(
    pattern = "^popnodes_cumulcatches_per_pop_",
    ## Named "cumcatches" upstream but it holds landings.
    cols = c("pop", "tstep", "node_idx", "long", "lat", "cumcatches"),
    types = c("i", "i", "i", "d", "d", "d")
  ),
  popnodes_cumftime = list(
    pattern = "^popnodes_cumftime_",
    cols = c("tstep", "node", "long", "lat", "cumftime"),
    types = c("i", "i", "d", "d", "d")
  ),
  popnodes_cumsweptarea = list(
    pattern = "^popnodes_cumsweptarea_",
    cols = c("tstep", "node", "long", "lat", "cumsweptarea", "subsurfacecumsweptarea"),
    types = c("i", "i", "d", "d", "d", "d")
  ),
  popnodes_cumcatches = list(
    pattern = "^popnodes_cumcatches_[^w]",
    cols = c("tstep", "node_idx", "long", "lat", "cumcatches"),
    types = c("i", "i", "d", "d", "d")
  ),
  popnodes_cumdiscards = list(
    pattern = "^popnodes_cumdiscards_",
    cols = c("tstep", "node_idx", "long", "lat", "cumdiscards"),
    types = c("i", "i", "d", "d", "d")
  ),
  popnodes_cumcatches_with_threshold = list(
    pattern = "^popnodes_cumcatches_with_threshold_",
    cols = c("tstep", "node_idx", "long", "lat", "cumcatches", "threshold_percent"),
    types = c("i", "i", "d", "d", "d", "d")
  ),
  popnodes_tariffs = list(
    pattern = "^popnodes_tariffs_",
    cols = c("tstep", "node", "long", "lat", "tariffs"),
    types = c("i", "i", "d", "d", "d")
  ),
  benthosnodes_tot_biomasses = list(
    pattern = "^benthosnodes_tot_biomasses_",
    cols = c("funcgr_id", "tstep", "node", "long", "lat", "number", "biomass",
             "mean_weight", "benthosbiomassoverK", "benthosnumberoverK",
             "benthos_tot_biomass_K"),
    types = c("i", "i", "i", "d", "d", "d", "d", "d", "d", "d", "d")
  ),
  benthosnodes_tot_numbers = list(
    pattern = "^benthosnodes_tot_numbers_",
    cols = c("funcgr_id", "tstep", "node", "long", "lat", "number", "biomass",
             "mean_weight", "benthosbiomassoverK", "benthosnumberoverK",
             "benthos_tot_biomass_K"),
    types = c("i", "i", "i", "d", "d", "d", "d", "d", "d", "d", "d")
  ),
  tripcatchesperszgroup = list(
    pattern = "^tripcatchesperszgroup_",
    cols = c("tstep", "vessel", "tstep_dep", "popid",
             sprintf("catches_szgroup%d", 0:(N_SZGROUPS - 1L))),
    types = c("i", "c", "i", "i", rep("d", N_SZGROUPS))
  ),
  export_individual_tac = list(
    pattern = "^export_individual_tac_",
    cols = c("tstep", "vesselid", "pop", "remaining_quota", "discarded_if_zero"),
    types = c("i", "c", "i", "d", "d")
  ),
  fishfarmslogs = list(
    ## Upstream writes "fishfarmslogs_", with the s — the documentation and the
    ## receiving parameter name both say "fishfarmlogs", so a pattern taken from
    ## the docs never matches a real file.
    pattern = "^fishfarmslogs_",
    ## Also four columns wider than documented: Fishfarm::export_fishfarms_indicators
    ## (commons/Fishfarm.cpp) appends the nitrogen and phosphorus discharges.
    cols = c("tstep", "node", "long", "lat", "farmtype", "farmid", "meanw_kg",
             "fish_harvested_kg", "eggs_harvested_kg", "fishfarm_annualprofit",
             "net_discharge_N", "net_discharge_P",
             "cumul_net_discharge_N", "cumul_net_discharge_P"),
    types = c("i", "i", "d", "d", "d", "c", "d", "d", "d", "d",
              "d", "d", "d", "d")
  ),
  nodes_envt = list(
    pattern = "^nodes_envt_",
    cols = c("tstep", "node", "marine_landscape", "salinity", "sst", "wind",
             "nitrogen", "phosphorus", "oxygen", "dissolved_carbon",
             "bathymetry", "shipping_density", "silt_fraction"),
    types = c("i", "i", "i", "d", "d", "d", "d", "d", "d", "d", "d", "d", "d")
  ),
  quotasuptake = list(
    pattern = "^quotasuptake_",
    cols = c("tstep", "pop", "global_quota_uptake", "current_tac"),
    types = c("i", "i", "d", "d")
  ),
  popdyn_F = list(
    pattern = "^popdyn_F_",
    ## F at age, cumulated over months — note the comment in
    ## Population::export_popdyn_F warning that these are cumulative.
    cols = c("tstep", "stock", sprintf("F_age%d", 0:(N_AGES - 1L))),
    types = c("i", "i", rep("d", N_AGES))
  ),
  popdyn_SSB = list(
    pattern = "^popdyn_SSB_",
    cols = c("tstep", "stock", sprintf("SSB_szgroup%d", 0:(N_SZGROUPS - 1L))),
    types = c("i", "i", rep("d", N_SZGROUPS))
  ),
  popnodes_cumdiscardsratio = list(
    pattern = "^popnodes_cumdiscardsratio_",
    cols = c("tstep", "node", "long", "lat", "cumdiscardsratio"),
    types = c("i", "i", "d", "d", "d")
  ),
  popnodes_nbchoked = list(
    pattern = "^popnodes_nbchoked_",
    cols = c("tstep", "node", "long", "lat", "nbchoked"),
    types = c("i", "i", "d", "d", "d")
  ),
  shipslogs = list(
    pattern = "^shipslogs_",
    cols = c("tstep", "node", "long", "lat", "shiptype", "shipid", "nb_units",
             "fuel_use_h", "NOx_emission_gperkW",
             "SOx_emission_percentpertotalfuelmass", "GHG_emission_gperkW",
             "PME_emission_gperkW", "fuel_use_litre", "NOx_emission",
             "SOx_emission", "GHG_emissions", "PME_emission"),
    ## shiptype and nb_units read as integers in the documentation but are
    ## written with setprecision(3) fixed, i.e. "1.000". Only tstep, node and
    ## shipid are actually integral in the file.
    types = c("i", "i", "d", "d", "d", "i", "d", "d", "d", "d", "d", "d",
              "d", "d", "d", "d", "d")
  ),
  vmslikefpingsonly = list(
    pattern = "^vmslikefpingsonly_",
    ## tstep, vessel, start-trip tstep, lon, lat, nodeid, course, fuelcons,
    ## pop, then catches (landings + discards, weight) for szgroup 0..13.
    ## Upstream writes get_fuelcons(), not the cumulative value the
    ## documentation names, so the column is named for what it holds.
    cols = c("tstep", "vessel", "tstep_dep", "lon", "lat", "nodeid", "course",
             "fuelcons",  "pop",
             sprintf("catches_szgroup%d", 0:(N_SZGROUPS - 1L))),
    types = c("i", "c", "i", "d", "d", "i", "d", "d", "i",
              rep("d", N_SZGROUPS))
  ),
  popdyn = list(
    ## tstep, stock, then total N at each size group, in thousands.
    ## "^popdyn_" alone would also catch popdyn_F_, popdyn_SSB_ and
    ## popdyn_annual_indic_, which are different layouts.
    pattern = "^popdyn_(?!F_|SSB_|annual_indic_|test)",
    perl = TRUE,
    cols = c("tstep", "stock", sprintf("N_szgroup%d", 0:(N_SZGROUPS - 1L))),
    types = c("i", "i", rep("d", N_SZGROUPS))
  ),
  windmillslogs = list(
    pattern = "^windmillslogs_",
    cols = c("tstep", "node", "long", "lat", "windfarmtype", "windfarmid",
             "kWh", "kW_production"),
    types = c("i", "i", "d", "d", "i", "i", "d", "d")
  ),
  loglike = list(
    pattern = "^loglike_[^p]",
    cols = NULL,
    builder = "loglike",
    types = NULL
  )
)

#' Column layout of a DISPLACE text output file
#'
#' Returns the column names for one of DISPLACE's text output files. Several
#' layouts are not fixed: their width depends on the number of populations in
#' the case study, so `nbpops` (and, for `loglike`, `explicit_pops`) must be
#' supplied.
#'
#' @param type Output type, one of `names(displace_output_types())`.
#' @param nbpops Number of populations, from `config.dat`. Required for the
#'   variable-width layouts.
#' @param explicit_pops Zero-based ids of the explicitly modelled populations,
#'   i.e. `setdiff(0:(nbpops-1), implicit_pops)`. Required for `loglike`.
#' @param db_version Output schema version, for future dispatch. Currently
#'   unused: there is one layout in the wild.
#'
#' @return A character vector of column names.
#' @export
#' @examples
#' displace_output_spec("popstats")
#' displace_output_spec("loglike", nbpops = 3, explicit_pops = c(0, 2))
displace_output_spec <- function(type, nbpops = NULL, explicit_pops = NULL,
                                 db_version = NULL) {
  spec <- OUTPUT_SPECS[[type]]
  if (is.null(spec)) {
    stopf("unknown output type '%s'. Known: %s",
          type, paste(names(OUTPUT_SPECS), collapse = ", "))
  }
  if (!is.null(spec$cols)) {
    return(spec$cols)
  }
  switch(
    spec$builder,
    popnodes_totals = popnodes_totals_cols(nbpops),
    impact_per_szgroup = impact_per_szgroup_cols(nbpops),
    loglike = loglike_cols(nbpops, explicit_pops),
    stopf("no column builder for '%s'", type)
  )
}

impact_per_szgroup_cols <- function(nbpops) {
  if (is.null(nbpops)) {
    stopf(paste0("this layout's width depends on the number of populations; ",
                 "pass nbpops (it is in config.dat)."))
  }
  nbpops <- as.integer(nbpops)
  c("pop", "tstep", "node_idx", "long", "lat",
    sprintf("impact_sp%d", 0:(nbpops - 1L)))
}

## popnodes_start_/inc_/end_: tstep, node, long, lat, then (tot N, tot W) per
## population, interleaved.
popnodes_totals_cols <- function(nbpops) {
  if (is.null(nbpops)) {
    stopf(paste0("this layout's width depends on the number of populations; ",
                 "pass nbpops (it is in config.dat)."))
  }
  nbpops <- as.integer(nbpops)
  per_pop <- as.vector(rbind(sprintf("tot_N_sp%d", 0:(nbpops - 1L)),
                             sprintf("tot_W_sp%d", 0:(nbpops - 1L))))
  c("tstep", "node", "long", "lat", per_pop)
}

## loglike_*.dat — the economics file.
##
## Upstream supplies an R idiom for naming these columns, and it inserts a
## `disc.*` block for the explicit populations that the flat field list in the
## documentation omits. Where the two disagree, the R idiom is the one that
## matches real files, so it is what is reproduced here.
loglike_cols <- function(nbpops, explicit_pops) {
  if (is.null(nbpops)) {
    stopf(paste0("loglike's width depends on the number of populations; pass ",
                 "nbpops (it is in config.dat)."))
  }
  if (is.null(explicit_pops)) {
    stopf(paste0("loglike carries one discard column per *explicit* population; ",
                 "pass explicit_pops, e.g. ",
                 "setdiff(0:(nbpops-1), config$implicit_pops)."))
  }
  nbpops <- as.integer(nbpops)
  c(
    "tstep_dep", "tstep_arr", "reason_back", "cumsteaming", "idx_node",
    "idx_vessel", "VE_REF", "timeatsea", "fuelcons", "traveled_dist",
    sprintf("pop.%d", 0:(nbpops - 1L)),
    "freq_metiers", "revenue", "rev_from_av_prices",
    "rev_explicit_from_av_prices", "fuelcost", "vpuf", "gav", "gradva",
    "sweptr", "revpersweptarea",
    sprintf("disc.%s", explicit_pops),
    "GVA", "GVAPerRevenue", "LabourSurplus", "GrossProfit", "NetProfit",
    "NetProfitMargin", "GVAPerFTE", "RoFTA", "BER", "CRBER",
    "NetPresentValue", "numTrips"
  )
}

#' DISPLACE text output types this package can read
#'
#' @return A data frame with `type`, `filename_pattern` and `fixed_width`
#'   (whether the column layout is fixed or depends on `nbpops`).
#' @export
#' @examples
#' displace_output_types()
displace_output_types <- function() {
  data.frame(
    type = names(OUTPUT_SPECS),
    filename_pattern = vapply(OUTPUT_SPECS, function(s) s$pattern, character(1)),
    fixed_width = vapply(OUTPUT_SPECS, function(s) !is.null(s$cols), logical(1)),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}
