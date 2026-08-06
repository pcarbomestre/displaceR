## simusspe_<name>/config.dat
##
## Field layout transcribed from read_config_file(), commons/readdata.cpp:114.
## Values sit on 0-indexed lines 1, 3, 5, ... See R/linenumber.R for why the
## line numbers, not the '#' comments, are what matters.

CONFIG_SPEC <- c(
  nbpops                  = 1L,
  nbmets                  = 3L,
  nbbenthospops           = 5L,
  implicit_pops           = 7L,
  calib_oth_landings      = 9L,
  calib_weight_at_szgroup = 11L,
  calib_cpue_multiplier   = 13L,
  int_harbours            = 15L,
  implicit_pops_level2    = 17L,
  grouped_tacs            = 19L,
  nbcp_coupling_pops      = 21L
)

CONFIG_COMMENTS <- c(
  nbpops                  = "nbpops",
  nbmets                  = "nbmets",
  nbbenthospops           = "nbbenthospops",
  implicit_pops           = "implicit stocks",
  calib_oth_landings      = "calib the other landings per stock",
  calib_weight_at_szgroup = "calib weight-at-szgroup per stock",
  calib_cpue_multiplier   = "calib the cpue multiplier per stock",
  int_harbours            = "Interesting harbours",
  implicit_pops_level2    = "Implicit Pop Levels #2",
  grouped_tacs            = "Grouped TACs groups",
  nbcp_coupling_pops      = "nbcp coupling pops"
)

#' Read a DISPLACE `config.dat`
#'
#' Reads `<input_dir>/simusspe_<input_name>/config.dat`, the file that declares
#' how many populations, metiers and benthos groups a case study has, plus the
#' three per-population calibration vectors.
#'
#' The file is positional, not keyed: values live on fixed line numbers and the
#' `#` lines are decoration. See the package source for the full mapping.
#'
#' @param input_dir Folder containing the `simusspe_*` subfolder.
#' @param input_name Parameterisation name.
#' @param path Read this exact file instead, ignoring `input_dir`/`input_name`.
#'
#' @return An object of class `displace_config`: a list with `nbpops`,
#'   `nbmets`, `nbbenthospops` (integers) and `implicit_pops`,
#'   `calib_oth_landings`, `calib_weight_at_szgroup`, `calib_cpue_multiplier`,
#'   `int_harbours`, `implicit_pops_level2`, `grouped_tacs`,
#'   `nbcp_coupling_pops` (vectors, possibly empty).
#' @export
#' @examples
#' f <- tempfile()
#' write_displace_config(new_displace_config(nbpops = 2, nbmets = 3), path = f)
#' read_displace_config(path = f)
read_displace_config <- function(input_dir = NULL, input_name = NULL, path = NULL) {
  path <- path %||% simusspe_file(input_dir, input_name, "config.dat")
  raw <- read_linenumber_file(path, CONFIG_SPEC)

  as_int1 <- function(x, field) {
    v <- suppressWarnings(as.integer(trim_or_empty(x)))
    if (is.na(v)) {
      stopf("config.dat: cannot read '%s' as an integer (got '%s') in %s",
            field, x %||% "<missing>", path)
    }
    v
  }

  cfg <- list(
    nbpops                  = as_int1(raw$nbpops, "nbpops"),
    nbmets                  = as_int1(raw$nbmets, "nbmets"),
    nbbenthospops           = as_int1(raw$nbbenthospops, "nbbenthospops"),
    implicit_pops           = split_nums(raw$implicit_pops, "integer"),
    calib_oth_landings      = split_nums(raw$calib_oth_landings),
    calib_weight_at_szgroup = split_nums(raw$calib_weight_at_szgroup),
    calib_cpue_multiplier   = split_nums(raw$calib_cpue_multiplier),
    int_harbours            = split_nums(raw$int_harbours, "integer"),
    implicit_pops_level2    = split_nums(raw$implicit_pops_level2, "integer"),
    grouped_tacs            = split_nums(raw$grouped_tacs, "integer"),
    nbcp_coupling_pops      = split_nums(raw$nbcp_coupling_pops, "integer"),
    path                    = path
  )
  structure(cfg, class = "displace_config")
}

#' Build a DISPLACE configuration
#'
#' Creates a `displace_config` with sensible defaults for the vectors whose
#' length the simulator checks against `nbpops`.
#'
#' @param nbpops Number of populations (stocks).
#' @param nbmets Number of metiers.
#' @param nbbenthospops Number of benthos functional groups.
#' @param implicit_pops Zero-based indices of populations modelled implicitly.
#' @param calib_oth_landings,calib_weight_at_szgroup,calib_cpue_multiplier
#'   Per-population calibration vectors. Each must have length `nbpops`; each
#'   defaults to a vector of ones.
#' @param int_harbours Node ids of harbours to report on.
#' @param implicit_pops_level2,grouped_tacs,nbcp_coupling_pops Optional integer
#'   vectors. `grouped_tacs` defaults, inside the simulator, to `0:(nbpops-1)`
#'   when left empty.
#'
#' @return A `displace_config`.
#' @export
#' @examples
#' new_displace_config(nbpops = 3, nbmets = 12)
new_displace_config <- function(nbpops,
                                nbmets,
                                nbbenthospops = 0L,
                                implicit_pops = integer(0),
                                calib_oth_landings = rep(1, nbpops),
                                calib_weight_at_szgroup = rep(1, nbpops),
                                calib_cpue_multiplier = rep(1, nbpops),
                                int_harbours = integer(0),
                                implicit_pops_level2 = integer(0),
                                grouped_tacs = integer(0),
                                nbcp_coupling_pops = integer(0)) {
  structure(
    list(
      nbpops = as.integer(nbpops),
      nbmets = as.integer(nbmets),
      nbbenthospops = as.integer(nbbenthospops),
      implicit_pops = as.integer(implicit_pops),
      calib_oth_landings = as.numeric(calib_oth_landings),
      calib_weight_at_szgroup = as.numeric(calib_weight_at_szgroup),
      calib_cpue_multiplier = as.numeric(calib_cpue_multiplier),
      int_harbours = as.integer(int_harbours),
      implicit_pops_level2 = as.integer(implicit_pops_level2),
      grouped_tacs = as.integer(grouped_tacs),
      nbcp_coupling_pops = as.integer(nbcp_coupling_pops),
      path = NA_character_
    ),
    class = "displace_config"
  )
}

#' Write a DISPLACE `config.dat`
#'
#' Emits the positional layout the simulator expects, with the conventional
#' comment lines in the gaps so the file stays readable.
#'
#' The three `calib_*` vectors are checked against `nbpops` first: the
#' simulator throws on that mismatch at load time, and finding out here is
#' considerably cheaper.
#'
#' @param config A `displace_config`, from [new_displace_config()] or
#'   [read_displace_config()].
#' @param input_dir,input_name Destination, as in [read_displace_config()].
#' @param path Write to this exact file instead.
#'
#' @return The path written, invisibly.
#' @export
#' @examples
#' cfg <- new_displace_config(nbpops = 2, nbmets = 4)
#' write_displace_config(cfg, path = tempfile())
write_displace_config <- function(config, input_dir = NULL, input_name = NULL,
                                  path = NULL) {
  stopifnot(inherits(config, "displace_config"))
  path <- path %||% simusspe_file(input_dir, input_name, "config.dat")

  for (f in c("calib_oth_landings", "calib_weight_at_szgroup", "calib_cpue_multiplier")) {
    if (length(config[[f]]) != config$nbpops) {
      stopf(paste0("config.dat: %s has length %d but nbpops is %d. The simulator ",
                   "throws on this at load time."),
            f, length(config[[f]]), config$nbpops)
    }
  }

  values <- list(
    nbpops                  = as.character(config$nbpops),
    nbmets                  = as.character(config$nbmets),
    nbbenthospops           = as.character(config$nbbenthospops),
    implicit_pops           = join_nums(config$implicit_pops),
    calib_oth_landings      = join_nums(config$calib_oth_landings),
    calib_weight_at_szgroup = join_nums(config$calib_weight_at_szgroup),
    calib_cpue_multiplier   = join_nums(config$calib_cpue_multiplier),
    int_harbours            = join_nums(config$int_harbours),
    implicit_pops_level2    = join_nums(config$implicit_pops_level2),
    grouped_tacs            = join_nums(config$grouped_tacs),
    nbcp_coupling_pops      = join_nums(config$nbcp_coupling_pops)
  )

  write_linenumber_file(path, CONFIG_SPEC, values, CONFIG_COMMENTS)
}

#' @export
print.displace_config <- function(x, ...) {
  cat("<displace_config>\n")
  cat("  populations:  ", x$nbpops,
      if (length(x$implicit_pops)) sprintf(" (implicit: %s)", join_nums(x$implicit_pops)) else "",
      "\n", sep = "")
  cat("  metiers:      ", x$nbmets, "\n", sep = "")
  cat("  benthos grps: ", x$nbbenthospops, "\n", sep = "")
  if (length(x$int_harbours)) {
    cat("  harbours:     ", join_nums(x$int_harbours), "\n", sep = "")
  }
  invisible(x)
}

simusspe_file <- function(input_dir, input_name, file) {
  if (is.null(input_dir) || is.null(input_name)) {
    stopf("supply either `path`, or both `input_dir` and `input_name`.")
  }
  file.path(input_dir, paste0("simusspe_", input_name), file)
}
