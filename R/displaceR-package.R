#' displaceR: run the DISPLACE fisheries simulator from R
#'
#' displaceR is a thin wrapper around the DISPLACE individual-based fisheries
#' simulator. It contains no compiled code. The simulator itself is a separate
#' backend, installed once with [install_displace()] into a user-writable cache
#' directory, in the same way `cmdstanr` installs CmdStan and `r4ss` fetches the
#' Stock Synthesis executable.
#'
#' @section This package is not DISPLACE:
#'
#' DISPLACE is developed by Francois Bastardie and colleagues at DTU Aqua
#' (<https://github.com/frabas/DISPLACE_GUI>,
#' <https://displace-project.org/>). The model, the science behind it, and its
#' validation are entirely theirs.
#'
#' This package is an unaffiliated R interface. It implements no model
#' behaviour: it installs the simulator, writes its input files, launches it,
#' and reads its outputs. Every number it returns was computed by DISPLACE.
#'
#' **Cite DISPLACE, not this package.** `citation("displaceR")` returns the
#' DISPLACE references. Questions about the model belong with the DISPLACE
#' project; only problems with this R interface belong in this package's issue
#' tracker.
#'
#' @section Getting started:
#'
#' ```r
#' install_displace()             # download and unpack the simulator, once
#' displace_version()             # check what got installed
#'
#' res <- run_displace(
#'   input_dir = "path/to/DISPLACE_input_minitest",
#'   input_name = "minitest",
#'   steps = 8762                 # about one year, hourly
#' )
#'
#' catches <- read_displace_db(res, "VesselLogLikeCatches")
#' ```
#'
#' @section Where the pieces live:
#'
#' The package is deliberately three separable layers. Upstream DISPLACE is
#' never forked or vendored; a GitHub Actions workflow in this repository builds
#' it and publishes a tarball; this package downloads that tarball. A new
#' upstream release means re-running the build workflow and adding a manifest
#' entry, not editing R code.
#'
#' @section Environment variables:
#'
#' \describe{
#'   \item{`DISPLACE_BINARY`}{Absolute path to a `displace` executable. When
#'     set, it overrides everything else -- [displace_path()] returns it and
#'     [install_displace()] is not needed. Use this if you have built DISPLACE
#'     yourself, or to test a new build before publishing it.}
#'   \item{`DISPLACER_CACHE`}{Overrides the cache directory that
#'     [install_displace()] writes to. Defaults to
#'     `tools::R_user_dir("displaceR", "cache")`.}
#' }
#'
#' @section Licensing:
#'
#' DISPLACE is GPL-2.0 and so is this package. Binaries distributed through
#' [install_displace()] are accompanied by their corresponding source: the
#' upstream commit SHA recorded in the manifest plus the build recipe in
#' `tools/build-displace.sh`. See `LICENSE.note` in the repository.
#'
#' @keywords internal
"_PACKAGE"

## A one-line reminder at attach time. Attribution that lives only in a README
## reaches the people who read READMEs; this reaches everyone else, and it is
## the message that matters most -- who to credit for the results.
.onAttach <- function(libname, pkgname) {
  packageStartupMessage(
    "displaceR runs DISPLACE, developed by Francois Bastardie and colleagues ",
    "at DTU Aqua.\n",
    "The model and all its science are theirs: https://displace-project.org/\n",
    "Cite the DISPLACE papers when publishing results -- citation(\"displaceR\")."
  )
}
