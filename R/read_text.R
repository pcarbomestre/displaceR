## Text output reader.
##
## Prefer read_displace_db(). These files have no headers, no types, and in
## loglike's case a width that depends on the case study, so every read here
## involves an assumption that the SQLite path does not.
##
## Text outputs land in <outdir>/DISPLACE_outputs/<f>/<F>/, from
## simulator/main.cpp:1666 onward.

#' List a run's text output files
#'
#' @param x A `displace_run`, or a path to an output directory.
#' @return A data frame with `file`, `type` (`NA` if unrecognised), `path` and
#'   `size` in bytes, ordered largest first.
#' @export
#' @examples
#' \dontrun{
#' displace_output_files(res)
#' }
displace_output_files <- function(x) {
  dir <- resolve_output_dir(x)
  files <- list.files(dir, pattern = "\\.dat$", full.names = TRUE)
  if (!length(files)) {
    return(data.frame(file = character(0), type = character(0),
                      path = character(0), size = numeric(0),
                      stringsAsFactors = FALSE))
  }
  base <- basename(files)
  type <- vapply(base, classify_output, character(1))
  out <- data.frame(file = base, type = unname(type), path = files,
                    size = file.size(files), stringsAsFactors = FALSE)
  out[order(out$size, decreasing = TRUE), , drop = FALSE]
}

## Files DISPLACE writes into the output directory that are not tabular data,
## and must never be matched by a layout. memstats is a free-text memory report
## ("*** Memory Statistics:"); the freq_* files are diagnostic histograms.
NON_TABULAR_OUTPUTS <- "^(memstats_|freq_cpue|freq_distance|freq_profit)"

classify_output <- function(filename) {
  if (grepl(NON_TABULAR_OUTPUTS, filename)) {
    return(NA_character_)
  }
  for (nm in names(OUTPUT_SPECS)) {
    spec <- OUTPUT_SPECS[[nm]]
    if (grepl(spec$pattern, filename, perl = isTRUE(spec$perl))) {
      return(nm)
    }
  }
  NA_character_
}

resolve_output_dir <- function(x) {
  if (inherits(x, "displace_run")) {
    return(x$output_path)
  }
  if (is.character(x) && length(x) == 1L && dir.exists(x)) {
    return(x)
  }
  stopf("expected a displace_run or an existing output directory.")
}

#' Read a DISPLACE text output file
#'
#' Reads one of the whitespace-separated `.dat` files DISPLACE writes and
#' applies the documented column layout.
#'
#' The layout of several files depends on how many populations the case study
#' has. Rather than make you look that up, pass `config` (from
#' [read_displace_config()]) and both `nbpops` and the explicit-population list
#' are derived from it.
#'
#' Prefer [read_displace_db()] where you can. These layouts are transcribed from
#' upstream documentation rather than from the writing code, and the files carry
#' nothing that would let a reader detect a layout change.
#'
#' @param x A `displace_run`, or a path to an output directory, or a direct path
#'   to a `.dat` file.
#' @param type Output type, e.g. `"popstats"`. See [displace_output_types()].
#'   Ignored when `x` is a direct file path and `type` is `NULL`, in which case
#'   the type is inferred from the filename.
#' @param sim_name Simulation name, used to pick the file when several
#'   simulations wrote into the same directory. Defaults to the run's own.
#' @param config A `displace_config`, supplying `nbpops` and `implicit_pops` for
#'   the variable-width layouts.
#' @param nbpops,explicit_pops Given directly, if `config` is not to hand.
#' @param n_max Maximum rows to read. These files get very large; `n_max` reads
#'   a head without loading the whole thing.
#'
#' @return A data frame.
#' @export
#' @examples
#' \dontrun{
#' cfg <- read_displace_config("input", "minitest")
#' read_displace_output(res, "loglike", config = cfg)
#' }
read_displace_output <- function(x,
                                 type = NULL,
                                 sim_name = NULL,
                                 config = NULL,
                                 nbpops = NULL,
                                 explicit_pops = NULL,
                                 n_max = Inf) {

  ## Resolve the file.
  if (is.character(x) && length(x) == 1L && file.exists(x) && !dir.exists(x)) {
    path <- x
    type <- type %||% classify_output(basename(path))
    if (is.na(type) || is.null(type)) {
      stopf(paste0("cannot infer an output type from '%s'. Pass type = explicitly; ",
                   "see displace_output_types()."), basename(path))
    }
  } else {
    if (is.null(type)) {
      stopf("type is required when x is a run or a directory. See displace_output_types().")
    }
    dir <- resolve_output_dir(x)
    sim_name <- sim_name %||% (if (inherits(x, "displace_run")) x$sim_name else NULL)
    spec <- OUTPUT_SPECS[[type]]
    if (is.null(spec)) {
      stopf("unknown output type '%s'. Known: %s",
            type, paste(names(OUTPUT_SPECS), collapse = ", "))
    }
    ## Match on the basename with the same engine classify_output() uses:
    ## list.files(pattern=) is unanchored against the name only, and several
    ## patterns rely on a perl look-ahead to exclude a longer sibling.
    candidates <- list.files(dir, pattern = "\\.dat$", full.names = TRUE)
    candidates <- candidates[
      vapply(basename(candidates), function(b) identical(classify_output(b), type),
             logical(1))
    ]
    if (!is.null(sim_name)) {
      narrowed <- grep(sprintf("%s\\.dat$", sim_name), candidates, value = TRUE)
      if (length(narrowed)) {
        candidates <- narrowed
      }
    }
    if (!length(candidates)) {
      stopf("no '%s' output found in %s", type, dir)
    }
    if (length(candidates) > 1L) {
      stopf("several '%s' outputs in %s:\n%s\nDisambiguate with sim_name.",
            type, dir, paste0("  ", basename(candidates), collapse = "\n"))
    }
    path <- candidates
  }

  if (!is.null(config)) {
    nbpops <- nbpops %||% config$nbpops
    explicit_pops <- explicit_pops %||%
      setdiff(seq_len(config$nbpops) - 1L, config$implicit_pops)
  }

  cols <- displace_output_spec(type, nbpops = nbpops, explicit_pops = explicit_pops)
  spec <- OUTPUT_SPECS[[type]]

  ## Check the width before reading. read.table() with an explicit colClasses
  ## fails inside scan() on a mismatch, and its message ("line 1 did not have 5
  ## elements") says nothing about which layout was assumed or why.
  first <- utils::head(readLines(path, n = 5L, warn = FALSE), 5L)
  first <- first[nzchar(trim(first))]
  if (!length(first)) {
    ## An empty output file is normal -- the run simply produced no rows of this
    ## kind -- so return the right shape rather than erroring.
    df <- as.data.frame(
      stats::setNames(rep(list(logical(0)), length(cols)), cols),
      stringsAsFactors = FALSE
    )
    attr(df, "displace_output_type") <- type
    attr(df, "displace_output_path") <- path
    return(df)
  }
  observed <- length(strsplit(trim(first[1]), "[[:space:]]+")[[1]])

  if (observed != length(cols)) {
    hint <- if (is.null(spec$cols)) {
      sprintf(paste0("\nThis layout's width depends on nbpops (given as %s). ",
                     "Check it against the case study's config.dat."),
              format(nbpops %||% NA))
    } else {
      paste0("\nThe expected layout is transcribed from upstream documentation, ",
             "which drifts. If the file is right, the spec in R/formats.R is stale.")
    }
    stopf("%s has %d columns but the '%s' layout expects %d.%s",
          basename(path), observed, type, length(cols), hint)
  }

  colClasses <- if (!is.null(spec$types)) {
    unname(c(i = "integer", d = "numeric", c = "character")[spec$types])
  } else {
    NA
  }

  df <- utils::read.table(
    path,
    header = FALSE,
    sep = "",                       # any run of whitespace
    colClasses = colClasses,
    col.names = cols,
    nrows = if (is.finite(n_max)) as.integer(n_max) else -1L,
    comment.char = "",
    stringsAsFactors = FALSE
  )
  attr(df, "displace_output_type") <- type
  attr(df, "displace_output_path") <- path
  df
}

#' Read the loglike economics output
#'
#' Convenience wrapper for the most-used and most-awkward text output. The
#' column count of `loglike_*.dat` depends on the number of populations and on
#' which of them are modelled explicitly, so it cannot be read without the case
#' study's `config.dat`.
#'
#' @param x A `displace_run` or an output directory.
#' @param config A `displace_config` from [read_displace_config()].
#' @param ... Passed to [read_displace_output()].
#' @return A data frame.
#' @export
#' @examples
#' \dontrun{
#' cfg <- read_displace_config("input", "minitest")
#' loglike <- read_displace_loglike(res, cfg)
#' }
read_displace_loglike <- function(x, config, ...) {
  if (missing(config) || !inherits(config, "displace_config")) {
    stopf(paste0("read_displace_loglike() needs the case study's config: ",
                 "config = read_displace_config(input_dir, input_name)."))
  }
  read_displace_output(x, type = "loglike", config = config, ...)
}
