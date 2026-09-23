## Input folder structure and pre-flight validation.
##
## Scope note: this is deliberately not a case-study generator. Building a
## complete DISPLACE_input_xx tree from R objects means emitting the ~150 files
## catalogued in CLAUDE.md Appendix B, and doing that responsibly needs real
## data to validate against. What is here is the folder skeleton, the formats
## whose parsers have been read line by line, and a validator that catches the
## errors the loader actually throws on. See docs/roadmap.md.

## Subfolders that carry the `_<parameterisation>` suffix. graphsspe is
## deliberately absent: TextfileModelLoader.cpp:96 builds
## "<inputfolder>/graphsspe/coord<N>.dat", with no suffix.
SUFFIXED_SUBFOLDERS <- c(
  "simusspe", "popsspe", "vesselsspe", "metiersspe", "harboursspe",
  "benthosspe", "shipsspe", "fishfarmsspe", "firmsspe", "windmillsspe",
  "externalforcing"
)

FLAT_SUBFOLDERS <- c("graphsspe", "dtrees", "timeseries")

#' Create an empty DISPLACE input folder skeleton
#'
#' Makes the directory tree a DISPLACE case study needs, so that writers have
#' somewhere to put files and so the layout is obvious before any data exists.
#' It creates directories only; it does not invent input files.
#'
#' Note which folders take the parameterisation suffix and which do not:
#' `simusspe_<name>/`, `vesselsspe_<name>/` and friends are per-case-study,
#' while `graphsspe/` is flat and shared, keyed by graph number instead.
#'
#' @param input_dir Root folder to create.
#' @param input_name Parameterisation name (DISPLACE's `-f`).
#' @param a_graph Graph number, used for the `shortPaths_*` folder name.
#' @param quiet Suppress the summary message.
#'
#' @return The paths created, invisibly.
#' @export
#' @examples
#' d <- file.path(tempdir(), "case")
#' create_displace_input(d, "mycase")
#' list.dirs(d, full.names = FALSE, recursive = FALSE)
create_displace_input <- function(input_dir, input_name, a_graph = 1L,
                                  quiet = FALSE) {
  dirs <- c(
    file.path(input_dir, paste0(SUFFIXED_SUBFOLDERS, "_", input_name)),
    file.path(input_dir, FLAT_SUBFOLDERS),
    ## Path caches. Whether these must be pre-generated is an open question;
    ## see docs/roadmap.md. Created empty so the layout is at least visible.
    file.path(input_dir, sprintf("shortPaths_%s_a_graph%d", input_name, a_graph)),
    file.path(input_dir, paste0("min_distance_", input_name)),
    file.path(input_dir, paste0("previous_", input_name))
  )
  for (d in dirs) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  if (!quiet) {
    msgf("Created %d directories under %s.", length(dirs), input_dir)
    msgf("Next: write config.dat and a scenario with write_displace_config() /")
    msgf("write_displace_scenario(), and the graph with write_displace_graph().")
  }
  invisible(dirs)
}

#' Validate a DISPLACE input folder
#'
#' A pre-flight check run by [run_displace()] before launching. It looks for the
#' failures that would otherwise surface as an opaque simulator abort several
#' seconds into loading, and it is cheap enough to run every time.
#'
#' What it checks:
#' * `simusspe_<name>/` exists and holds `config.dat` and `<scenario>.dat`;
#' * `config.dat` parses, and the three `calib_*` vectors have length `nbpops`
#'   -- the simulator throws on exactly this;
#' * the scenario file parses and names a graph;
#' * `graphsspe/coord<N>.dat` and `graph<N>.dat` exist and have a line count
#'   consistent with the scenario's `nrow_coord` / `nrow_graph`;
#' * every per-node layer `graphsspe/coord<N>_with_<layer>.dat` exists and holds
#'   at least `nrow_coord` values -- DISPLACE 1.8.0 aborts otherwise. The ICES
#'   rectangle layer is optional and only warned about;
#' * all four quarters of `vesselsspe_fgrounds_quarter*.dat` and
#'   `vesselsspe_harbours_quarter*.dat` exist -- `main.cpp` loads all four at
#'   startup regardless of the simulated period;
#' * a calendar file is present under one of its two accepted names.
#'
#' What it does not check: the contents of the ~150 other input files. A clean
#' result means the run will start, not that it is scientifically sensible.
#'
#' @param input_dir Folder containing the parameterisation subfolders.
#' @param input_name Parameterisation name.
#' @param scenario Scenario name.
#'
#' @return An object of class `displace_validation`: a list with `ok`,
#'   `errors` and `warnings`. Printing it gives a readable report.
#' @export
#' @examples
#' validate_displace_input(tempdir(), "nonexistent")
validate_displace_input <- function(input_dir, input_name, scenario = "baseline") {
  errors <- character()
  warnings <- character()

  err <- function(...) errors <<- c(errors, sprintf(...))
  warn <- function(...) warnings <<- c(warnings, sprintf(...))

  if (!dir.exists(input_dir)) {
    return(validation_result(sprintf("input_dir does not exist: %s", input_dir),
                             character()))
  }

  simus <- file.path(input_dir, paste0("simusspe_", input_name))
  if (!dir.exists(simus)) {
    err(paste0("missing %s. Check input_name: it is the suffix on the *spe_ ",
               "folders, not the folder name."), simus)
    return(validation_result(errors, warnings))
  }

  ## --- config.dat -----------------------------------------------------------
  cfg_path <- file.path(simus, "config.dat")
  cfg <- NULL
  if (!file.exists(cfg_path)) {
    err("missing %s", cfg_path)
  } else {
    cfg <- tryCatch(read_displace_config(path = cfg_path),
                    error = function(e) {
                      err("config.dat is unreadable: %s", conditionMessage(e))
                      NULL
                    })
  }
  if (!is.null(cfg)) {
    for (f in c("calib_oth_landings", "calib_weight_at_szgroup",
                "calib_cpue_multiplier")) {
      if (length(cfg[[f]]) != cfg$nbpops) {
        err(paste0("config.dat: %s has %d values but nbpops is %d. The simulator ",
                   "throws on this during loading."),
            f, length(cfg[[f]]), cfg$nbpops)
      }
    }
    if (cfg$nbpops < 1L) {
      err("config.dat: nbpops is %d", cfg$nbpops)
    }
    if (length(cfg$implicit_pops) && max(cfg$implicit_pops) >= cfg$nbpops) {
      warn(paste0("config.dat: implicit_pops references population %d but ",
                  "nbpops is %d (ids are 0-based)."),
           max(cfg$implicit_pops), cfg$nbpops)
    }
  }

  ## --- scenario -------------------------------------------------------------
  sc_path <- file.path(simus, paste0(scenario, ".dat"))
  sc <- NULL
  if (!file.exists(sc_path)) {
    available <- list.files(simus, pattern = "\\.dat$")
    available <- setdiff(available, c("config.dat"))
    available <- grep("^tstep_", available, invert = TRUE, value = TRUE)
    err("missing scenario file %s%s", sc_path,
        if (length(available)) {
          sprintf(". Available scenarios: %s",
                  paste(sub("\\.dat$", "", available), collapse = ", "))
        } else ""
    )
  } else {
    sc <- tryCatch(read_displace_scenario(path = sc_path),
                   error = function(e) {
                     err("scenario file is unreadable: %s", conditionMessage(e))
                     NULL
                   })
  }

  ## --- graph ----------------------------------------------------------------
  if (!is.null(sc)) {
    if (is.na(sc$a_graph)) {
      err("scenario file %s does not set a_graph", sc_path)
    } else {
      check_stacked <- function(kind, n, label) {
        p <- graphsspe_file(input_dir, sc$a_graph, kind)
        if (!file.exists(p)) {
          err("missing %s", p)
          return(invisible(NULL))
        }
        if (is.na(n)) {
          err("scenario file does not set %s, needed to parse %s", label, basename(p))
          return(invisible(NULL))
        }
        lines <- readLines(p, warn = FALSE)
        nvals <- sum(nzchar(trim(lines)))
        if (nvals < 3L * n) {
          err(paste0("%s holds %d values but %s = %d needs %d (three stacked ",
                     "blocks). Either the file is truncated or %s is wrong."),
              basename(p), nvals, label, n, 3L * n, label)
        } else if (nvals > 3L * n) {
          warn(paste0("%s holds %d values but only the first %d are read ",
                      "(%s = %d). The extra rows are silently ignored."),
               basename(p), nvals, 3L * n, label, n)
        }
      }
      check_stacked("coord", sc$nrow_coord, "nrow_coord")
      check_stacked("graph", sc$nrow_graph, "nrow_graph")

      code_area <- graphsspe_file(input_dir, sc$a_graph, "code_area")
      if (!file.exists(code_area)) {
        err("missing %s", code_area)
      }

      ## Per-node layers: one value per node, nrow_coord of them. The loader
      ## refuses to start without each file, and from 1.8.0 it also throws
      ## unless every one holds at least nrow_coord values (earlier versions
      ## read past the end instead). See docs/upstream-issues.md 16.
      if (!is.na(sc$nrow_coord)) {
        for (layer in PER_NODE_LAYERS) {
          p <- file.path(input_dir, "graphsspe",
                         sprintf("coord%d_with_%s.dat", sc$a_graph, layer))
          if (!file.exists(p)) {
            if (identical(layer, "icesrectanglecode")) {
              warn(paste0("missing %s. It is optional, but DISPLACE 1.8.0 built ",
                          "without displaceR's 'ices-optional' patch refuses to ",
                          "start without it."), basename(p))
            } else {
              err("missing %s", p)
            }
            next
          }
          nvals <- sum(nzchar(trim(readLines(p, warn = FALSE))))
          if (nvals < sc$nrow_coord) {
            err(paste0("%s holds %d values but nrow_coord = %d. DISPLACE 1.8.0 ",
                       "aborts on this (\"One or more vectors have unexpected ",
                       "size\"); earlier versions read past the end of the data."),
                basename(p), nvals, sc$nrow_coord)
          }
        }
      }
    }
  }

  ## --- vessels: all four quarters -------------------------------------------
  ## main.cpp loads fgrounds and harbours for quarters 1-4 at startup, whatever
  ## period is simulated, so a missing quarter fails the run rather than one
  ## quarter of it.
  vess <- file.path(input_dir, paste0("vesselsspe_", input_name))
  if (!dir.exists(vess)) {
    err("missing %s", vess)
  } else {
    for (kind in c("fgrounds", "harbours")) {
      missing_q <- Filter(function(q) {
        !file.exists(file.path(vess, sprintf("vesselsspe_%s_quarter%d.dat", kind, q)))
      }, 1:4)
      if (length(missing_q)) {
        err(paste0("vesselsspe_%s: missing quarter%s %s. The simulator loads all ",
                   "four quarters at startup regardless of the simulated period."),
            kind, if (length(missing_q) > 1) "s" else "",
            paste(missing_q, collapse = ", "))
      }
    }
  }

  ## --- calendar -------------------------------------------------------------
  ## The loader tries tstep_<unit>.dat first, then tstep_<unit>_2009_2015.dat.
  for (unit in c("months", "quarters", "semesters", "years")) {
    a <- file.path(simus, sprintf("tstep_%s.dat", unit))
    b <- file.path(simus, sprintf("tstep_%s_2009_2015.dat", unit))
    if (!file.exists(a) && !file.exists(b)) {
      err("missing calendar file: %s or %s", basename(a), basename(b))
    }
  }

  validation_result(errors, warnings)
}

validation_result <- function(errors, warnings) {
  structure(
    list(ok = length(errors) == 0L, errors = errors, warnings = warnings),
    class = "displace_validation"
  )
}

#' @export
print.displace_validation <- function(x, ...) {
  if (x$ok && !length(x$warnings)) {
    cat("Input validation passed.\n")
  } else if (x$ok) {
    cat("Input validation passed with ", length(x$warnings), " warning(s).\n", sep = "")
  } else {
    cat("Input validation FAILED: ", length(x$errors), " error(s).\n", sep = "")
  }
  for (e in x$errors) cat("  [error] ", e, "\n", sep = "")
  for (w in x$warnings) cat("  [warn]  ", w, "\n", sep = "")
  if (!x$ok) {
    cat("\nThis check covers the structural failures that abort loading.\n")
    cat("It does not validate the contents of the remaining input files.\n")
  }
  invisible(x)
}
