## Phase 2 -- binary distribution.
##
## The R package never compiles DISPLACE. It downloads a tarball built by
## .github/workflows/build-displace.yml and unpacks it into a user-writable
## cache directory. This mirrors r4ss::get_ss3_exe() and cmdstanr::install_cmdstan().

#' Cache directory used for installed DISPLACE binaries
#'
#' Defaults to `tools::R_user_dir("displaceR", "cache")`. Override with the
#' `DISPLACER_CACHE` environment variable, for example to put the binary on a
#' shared filesystem so several users on a server share one copy.
#'
#' @return A file path. The directory is not created.
#' @export
#' @examples
#' displace_cache_dir()
displace_cache_dir <- function() {
  from_env <- Sys.getenv("DISPLACER_CACHE", "")
  if (nzchar(from_env)) {
    return(path.expand(from_env))
  }
  tools::R_user_dir("displaceR", "cache")
}

manifest_file <- function() {
  system.file("manifest.json", package = "displaceR", mustWork = TRUE)
}

read_manifest <- function(path = manifest_file()) {
  need_pkg("jsonlite", "Reading the binary manifest")
  m <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (!identical(m$manifest_version, 1L) && !identical(m$manifest_version, 1)) {
    stopf(paste0("manifest.json declares manifest_version %s, but this version of ",
                 "displaceR only understands version 1. Upgrade the package."),
          format(m$manifest_version))
  }
  m
}

#' DISPLACE binary versions known to this package
#'
#' Lists the entries in the package manifest -- the builds that
#' [install_displace()] can fetch. This is not a list of what is installed; use
#' [displace_path()] for that.
#'
#' @return A data frame with one row per version, or a zero-row data frame if
#'   no binaries have been published yet. Columns: `version`, `upstream_sha`,
#'   `displace_version`, `released`, `glibc` (comma-separated targets available)
#'   and `is_default`.
#' @export
#' @examples
#' displace_versions()
displace_versions <- function() {
  m <- read_manifest()
  vs <- m$versions
  empty <- data.frame(
    version = character(0), upstream_sha = character(0),
    displace_version = character(0), released = character(0),
    glibc = character(0), is_default = logical(0),
    stringsAsFactors = FALSE
  )
  if (!length(vs)) {
    return(empty)
  }
  rows <- lapply(names(vs), function(v) {
    e <- vs[[v]]
    data.frame(
      version = v,
      upstream_sha = e$upstream_sha %||% NA_character_,
      displace_version = e$displace_version %||% NA_character_,
      released = e$released %||% NA_character_,
      glibc = paste(names(e$builds %||% list()), collapse = ","),
      is_default = identical(v, m$default %||% ""),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out[order(out$released, out$version, decreasing = TRUE), , drop = FALSE]
}

#' @rdname displace_versions
#' @return `displace_default_version()` returns the version label
#'   [install_displace()] uses when none is given, or `NULL` if the manifest
#'   pins no default.
#' @export
displace_default_version <- function() {
  read_manifest()$default
}

## Pick the build for this host: the newest glibc target the host can still run.
select_build <- function(entry, version) {
  builds <- entry$builds %||% list()
  if (!length(builds)) {
    stopf("manifest entry '%s' lists no builds.", version)
  }
  hg <- host_glibc()
  targets <- names(builds)
  if (is.na(hg)) {
    ## Cannot determine host glibc (non-Linux, or ldd unavailable). Take the
    ## oldest target, which is the most likely to run anywhere.
    pick <- sort_versions(targets)[1]
    warnf(paste0("could not determine this host's glibc version; falling back to ",
                 "the glibc %s build. If it fails to start, install a build for ",
                 "your glibc or set DISPLACE_BINARY."), pick)
    return(list(target = pick, build = builds[[pick]]))
  }
  usable <- targets[vapply(targets, function(t) ver_gte(hg, t), logical(1))]
  if (!length(usable)) {
    stopf(paste0("no build in version '%s' runs on this host: it has glibc %s and ",
                 "the available builds need %s or newer. Build DISPLACE on a host ",
                 "matching yours (see tools/build-displace.sh) and point ",
                 "DISPLACE_BINARY at the result."),
          version, hg, paste(sort(targets), collapse = " / "))
  }
  ## Newest usable target: linked against the most recent libraries the host has.
  pick <- rev(sort_versions(usable))[1]
  list(target = pick, build = builds[[pick]])
}

## tools::md5sum has no sha256 equivalent in base R, and taking a hard
## dependency on digest for one call is not worth it. Prefer the system
## sha256sum, which is present on every Linux host we target, and fall back to
## digest only if it is missing.
sha256_of <- function(path) {
  if (nzchar(Sys.which("sha256sum"))) {
    out <- system2("sha256sum", shQuote(path), stdout = TRUE, stderr = FALSE)
    return(sub("[[:space:]].*$", "", out[1]))
  }
  if (requireNamespace("digest", quietly = TRUE)) {
    return(digest::digest(path, algo = "sha256", file = TRUE))
  }
  NA_character_
}

#' Install the DISPLACE simulator binary
#'
#' Downloads a prebuilt headless DISPLACE simulator, verifies its checksum,
#' unpacks it into [displace_cache_dir()] and makes it executable. No compiler,
#' CMake or root access is needed on this machine.
#'
#' Run this once per machine (or once per shared cache directory). The
#' installation is keyed by version, so several versions can coexist and
#' [displace_path()] can select between them.
#'
#' @param version Version label from [displace_versions()]. Defaults to the
#'   version pinned in the package manifest, which is what makes results
#'   reproducible across users of the same package version.
#' @param overwrite Reinstall even if this version is already present.
#' @param quiet Suppress progress messages.
#' @param timeout Download timeout in seconds. The tarball is a few MB, but
#'   R's default of 60s is tight on a slow link.
#' @param from Install from a local build instead of downloading. Either a
#'   tarball produced by `tools/build-displace.sh`, or the `dist/payload`
#'   directory it stages. This is the route to use on a server with no outbound
#'   network access, or before any release has been published: build on any
#'   machine with a compiler, copy the tarball over, and install it here. No
#'   checksum is verified, because you are vouching for the file yourself.
#'
#' @return The path to the installed `displace` executable, invisibly.
#' @export
#' @examples
#' \dontrun{
#' install_displace()
#'
#' # From a locally built payload, e.g. on an offline server:
#' install_displace(from = "displace-7f2656fb-linux-x86_64.tar.gz",
#'                  version = "local")
#'
#' displace_version()
#' }
install_displace <- function(version = NULL,
                             overwrite = FALSE,
                             quiet = FALSE,
                             timeout = 600,
                             from = NULL) {

  if (!is.null(from)) {
    return(invisible(install_displace_local(from, version = version,
                                            overwrite = overwrite,
                                            quiet = quiet)))
  }

  m <- read_manifest()
  versions <- m$versions %||% list()

  if (!length(versions)) {
    stopf(paste0(
      "No DISPLACE binaries have been published yet: inst/manifest.json is empty.\n",
      "Three ways forward:\n",
      "  - if you already have a build, point at it:\n",
      "      Sys.setenv(DISPLACE_BINARY = \"/path/to/displace\")\n",
      "  - install from a locally built tarball or payload directory:\n",
      "      install_displace(from = \"displace-<sha>-linux-x86_64.tar.gz\")\n",
      "    (build one anywhere with tools/build-displace.sh)\n",
      "  - run the 'Build DISPLACE binary' workflow in the displaceR repository\n",
      "    and add its manifest entry.\n",
      "See docs/roadmap.md."
    ))
  }

  version <- version %||% m$default
  if (is.null(version)) {
    stopf(paste0("the manifest pins no default version. Pass one explicitly, ",
                 "one of: %s"), paste(names(versions), collapse = ", "))
  }
  entry <- versions[[version]]
  if (is.null(entry)) {
    stopf("unknown version '%s'. Known versions: %s",
          version, paste(names(versions), collapse = ", "))
  }

  dest <- file.path(displace_cache_dir(), version)
  exe <- file.path(dest, "displace")

  if (file.exists(exe) && !overwrite) {
    if (!quiet) {
      msgf("DISPLACE %s is already installed at %s (use overwrite = TRUE to reinstall).",
           version, dest)
    }
    return(invisible(exe))
  }

  sel <- select_build(entry, version)
  build <- sel$build
  url <- build$url %||% stopf("manifest entry '%s' build '%s' has no url", version, sel$target)

  if (!quiet) {
    msgf("Installing DISPLACE %s (glibc %s build) into %s", version, sel$target, dest)
    msgf("  upstream commit: %s", entry$upstream_sha %||% "unknown")
  }

  tmp <- tempfile("displace-", fileext = ".tar.gz")
  on.exit(unlink(tmp), add = TRUE)

  old_timeout <- getOption("timeout")
  options(timeout = max(timeout, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)

  ok <- tryCatch(
    {
      utils::download.file(url, tmp, mode = "wb", quiet = quiet)
      TRUE
    },
    error = function(e) {
      stopf("failed to download %s: %s", url, conditionMessage(e))
    }
  )
  stopifnot(ok)

  expected <- build$sha256
  if (!is.null(expected) && nzchar(expected)) {
    got <- sha256_of(tmp)
    if (is.na(got)) {
      warnf(paste0("cannot verify the checksum: neither the sha256sum utility nor ",
                   "the 'digest' package is available. Proceeding unverified."))
    } else if (!identical(tolower(got), tolower(expected))) {
      stopf(paste0("checksum mismatch for %s\n  expected %s\n  got      %s\n",
                   "Refusing to install. This is either a corrupted download or a ",
                   "tampered asset."), url, expected, got)
    } else if (!quiet) {
      msgf("  sha256 verified")
    }
  } else {
    warnf("manifest entry '%s' has no sha256; installing unverified.", version)
  }

  install_payload(tmp, dest, source_desc = url)

  ## Record what we installed so displace_version() can report it without
  ## running the binary, and so a stale cache is diagnosable.
  writeLines(
    c(sprintf("version: %s", version),
      sprintf("upstream_sha: %s", entry$upstream_sha %||% "unknown"),
      sprintf("displace_version: %s", entry$displace_version %||% "unknown"),
      sprintf("glibc_target: %s", sel$target),
      sprintf("url: %s", url),
      sprintf("installed_at: %s", format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))),
    file.path(dest, "displaceR-install.txt")
  )

  if (!quiet) {
    msgf("Installed. displace_path() -> %s", exe)
  }
  invisible(exe)
}

## Unpack (or copy) a payload into `dest`, atomically.
##
## Everything lands in a staging directory first and is moved into place only
## once complete, so an interrupted or failed install never leaves a
## half-populated version directory that displace_path() would then find and
## hand to run_displace().
install_payload <- function(src, dest, source_desc = src) {
  staging <- paste0(dest, ".tmp-", Sys.getpid())
  unlink(staging, recursive = TRUE)
  dir.create(staging, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)

  if (dir.exists(src)) {
    ok <- file.copy(list.files(src, full.names = TRUE, all.files = TRUE,
                               no.. = TRUE),
                    staging, recursive = TRUE, copy.mode = TRUE)
    if (!all(ok)) {
      stopf("could not copy every file out of %s", src)
    }
  } else {
    utils::untar(src, exdir = staging)
  }

  if (!file.exists(file.path(staging, "displace"))) {
    ## Some tarballs carry a leading directory. Find the executable below and
    ## flatten that level away.
    found <- list.files(staging, pattern = "^displace$", recursive = TRUE,
                        full.names = TRUE)
    if (!length(found)) {
      stopf(paste0("%s contains no 'displace' executable. Expected the payload ",
                   "staged by tools/build-displace.sh: displace plus its three ",
                   ".so files."), source_desc)
    }
    inner <- dirname(found[1])
    flat <- paste0(staging, "-flat")
    unlink(flat, recursive = TRUE)
    file.rename(inner, flat)
    unlink(staging, recursive = TRUE)
    file.rename(flat, staging)
  }

  Sys.chmod(file.path(staging, "displace"), "0755")

  unlink(dest, recursive = TRUE)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  if (!file.rename(staging, dest)) {
    ## Rename across filesystems fails; fall back to a copy.
    dir.create(dest, recursive = TRUE, showWarnings = FALSE)
    file.copy(list.files(staging, full.names = TRUE, all.files = TRUE,
                         no.. = TRUE),
              dest, recursive = TRUE, copy.mode = TRUE)
  }
  Sys.chmod(file.path(dest, "displace"), "0755")
  invisible(file.path(dest, "displace"))
}

## build-displace.sh writes build-info.json both inside the payload and beside
## it, so a payload directory, a tarball, and an outdir all carry provenance.
read_build_info <- function(from) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    return(NULL)
  }
  parse <- function(path) {
    tryCatch(jsonlite::fromJSON(path), error = function(e) NULL)
  }

  if (dir.exists(from)) {
    for (cand in c(file.path(from, "build-info.json"),
                   file.path(dirname(from), "build-info.json"))) {
      if (file.exists(cand)) {
        got <- parse(cand)
        if (!is.null(got)) {
          return(got)
        }
      }
    }
    return(NULL)
  }

  ## A tarball: extract just the metadata rather than unpacking the whole thing
  ## twice.
  tmp <- tempfile("displace-info-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  inside <- tryCatch(utils::untar(from, list = TRUE), error = function(e) character())
  hit <- grep("(^|/)build-info\\.json$", inside, value = TRUE)
  if (!length(hit)) {
    return(NULL)
  }
  ok <- tryCatch({
    utils::untar(from, files = hit[1], exdir = tmp)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) {
    return(NULL)
  }
  parse(file.path(tmp, hit[1]))
}

## Install from a locally built tarball or payload directory.
##
## This is the offline route: build on any machine with a compiler, copy the
## artefact to the server, install it here. There is no manifest entry and no
## checksum to check against -- the caller is vouching for the file -- so this
## reads the build's own build-info.json for provenance where it can.
install_displace_local <- function(from, version = NULL, overwrite = FALSE,
                                   quiet = FALSE) {
  from <- path.expand(from)
  if (!file.exists(from)) {
    stopf("no such file or directory: %s", from)
  }

  info <- read_build_info(from)

  version <- version %||% local_version_label(info)

  dest <- file.path(displace_cache_dir(), version)
  if (file.exists(file.path(dest, "displace")) && !overwrite) {
    stopf(paste0("version '%s' is already installed at %s. Pass overwrite = TRUE ",
                 "to replace it, or version = to install alongside it."),
          version, dest)
  }

  if (!quiet) {
    msgf("Installing DISPLACE from %s into %s", from, dest)
  }

  install_payload(from, dest, source_desc = from)

  writeLines(
    c(sprintf("version: %s", version),
      sprintf("upstream_sha: %s", info$upstream_sha %||% "unknown (local build)"),
      sprintf("displace_version: %s", info$displace_version %||% "unknown"),
      sprintf("glibc_target: %s", info$glibc %||% "unknown"),
      sprintf("url: local:%s", from),
      sprintf("build_patches: %s", info$build_patches %||% "unknown"),
      sprintf("installed_at: %s", format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))),
    file.path(dest, "displaceR-install.txt")
  )

  if (!quiet) {
    msgf("Installed. displace_path() -> %s", file.path(dest, "displace"))
    if (is.null(info)) {
      msgf(paste0("No build-info.json was found alongside the payload, so the ",
                  "upstream commit is unrecorded. displace_version() will say so."))
    }
  }
  file.path(dest, "displace")
}

## Label a local build by its upstream commit where that is known, so two
## builds from different upstream refs do not silently overwrite each other.
local_version_label <- function(info) {
  sha <- info$upstream_sha
  if (!is.null(sha) && nzchar(sha)) {
    ver <- info$displace_version %||% "displace"
    return(sprintf("%s-%s-local", ver, substr(sha, 1, 12)))
  }
  "local"
}

#' Path to the DISPLACE executable
#'
#' Resolution order:
#' 1. the `DISPLACE_BINARY` environment variable, if set;
#' 2. the requested `version` in [displace_cache_dir()];
#' 3. the manifest default version, if installed;
#' 4. any single installed version.
#'
#' @param version Version label. `NULL` uses the resolution order above.
#' @param error Whether to raise an error when nothing is found. `FALSE`
#'   returns `NA_character_` instead, which is useful for skipping tests.
#'
#' @return An absolute path to the executable, or `NA_character_`.
#' @export
#' @examples
#' displace_path(error = FALSE)
displace_path <- function(version = NULL, error = TRUE) {
  from_env <- Sys.getenv("DISPLACE_BINARY", "")
  if (nzchar(from_env)) {
    p <- path.expand(from_env)
    if (!file.exists(p)) {
      stopf("DISPLACE_BINARY is set to '%s' but no such file exists.", from_env)
    }
    return(normalizePath(p))
  }

  cache <- displace_cache_dir()

  candidate <- function(v) {
    p <- file.path(cache, v, "displace")
    if (file.exists(p)) normalizePath(p) else NULL
  }

  if (!is.null(version)) {
    p <- candidate(version)
    if (!is.null(p)) {
      return(p)
    }
    if (error) {
      stopf("DISPLACE version '%s' is not installed. Run install_displace(\"%s\").",
            version, version)
    }
    return(NA_character_)
  }

  default <- tryCatch(read_manifest()$default, error = function(e) NULL)
  if (!is.null(default)) {
    p <- candidate(default)
    if (!is.null(p)) {
      return(p)
    }
  }

  installed <- displace_installed()
  if (nrow(installed) == 1L) {
    return(normalizePath(installed$path[1]))
  }
  if (nrow(installed) > 1L) {
    ## Ambiguous but recoverable: prefer the most recently installed.
    return(normalizePath(installed$path[which.max(installed$installed_at)]))
  }

  if (error) {
    stopf(paste0("no DISPLACE binary found.\n",
                 "Run install_displace(), or set DISPLACE_BINARY to a local build."))
  }
  NA_character_
}

#' Installed DISPLACE binaries
#'
#' Scans [displace_cache_dir()] for installations made by [install_displace()].
#'
#' @return A data frame with columns `version`, `path`, `upstream_sha` and
#'   `installed_at`; zero rows if nothing is installed.
#' @export
#' @examples
#' displace_installed()
displace_installed <- function() {
  cache <- displace_cache_dir()
  empty <- data.frame(version = character(0), path = character(0),
                      upstream_sha = character(0),
                      installed_at = as.POSIXct(character(0)),
                      stringsAsFactors = FALSE)
  if (!dir.exists(cache)) {
    return(empty)
  }
  dirs <- list.dirs(cache, recursive = FALSE)
  dirs <- dirs[file.exists(file.path(dirs, "displace"))]
  if (!length(dirs)) {
    return(empty)
  }
  rows <- lapply(dirs, function(d) {
    info_file <- file.path(d, "displaceR-install.txt")
    sha <- NA_character_
    if (file.exists(info_file)) {
      lines <- readLines(info_file, warn = FALSE)
      hit <- grep("^upstream_sha: ", lines, value = TRUE)
      if (length(hit)) sha <- sub("^upstream_sha: ", "", hit[1])
    }
    data.frame(
      version = basename(d),
      path = file.path(d, "displace"),
      upstream_sha = sha,
      installed_at = file.info(file.path(d, "displace"))$mtime,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Version of the installed DISPLACE simulator
#'
#' Reports both identities of the binary, because they are not equivalent.
#' `displace_version` is the string DISPLACE prints, which comes from a
#' hardcoded `#define` in `include/version.h` and changes rarely -- many
#' different upstream commits report `1.6.6`. `upstream_sha` is the commit the
#' binary was actually built from, and is the value to cite in a methods
#' section or to compare across machines.
#'
#' @param version Which installed version to inspect. `NULL` uses
#'   [displace_path()]'s resolution order.
#'
#' @return A list with elements `displace_version`, `upstream_sha`, `path`,
#'   `installed_version` and `banner` (the first lines of `displace --help`).
#' @export
#' @examples
#' \dontrun{
#' displace_version()
#' }
displace_version <- function(version = NULL) {
  path <- displace_path(version)

  info <- list(displace_version = NA_character_, upstream_sha = NA_character_,
               installed_version = NA_character_)
  info_file <- file.path(dirname(path), "displaceR-install.txt")
  if (file.exists(info_file)) {
    lines <- readLines(info_file, warn = FALSE)
    get1 <- function(key) {
      hit <- grep(paste0("^", key, ": "), lines, value = TRUE)
      if (length(hit)) sub(paste0("^", key, ": "), "", hit[1]) else NA_character_
    }
    info$displace_version <- get1("displace_version")
    info$upstream_sha <- get1("upstream_sha")
    info$installed_version <- get1("version")
  }

  banner <- tryCatch(
    suppressWarnings(system2(path, "--help", stdout = TRUE, stderr = TRUE)),
    error = function(e) NA_character_
  )

  structure(
    list(
      displace_version = info$displace_version,
      upstream_sha = info$upstream_sha,
      installed_version = info$installed_version,
      path = path,
      banner = if (length(banner)) utils::head(banner, 5) else NA_character_
    ),
    class = "displace_version"
  )
}

#' @export
print.displace_version <- function(x, ...) {
  cat("DISPLACE simulator\n")
  cat("  path:             ", x$path, "\n", sep = "")
  cat("  reported version: ", x$displace_version %||% "unknown", "\n", sep = "")
  cat("  upstream commit:  ", x$upstream_sha %||% "unknown", "\n", sep = "")
  cat("  displaceR label:  ", x$installed_version %||% "unknown", "\n", sep = "")
  cat("\nThe reported version comes from a hardcoded #define upstream and is\n")
  cat("not unique per commit. Cite the upstream commit instead.\n")
  invisible(x)
}

#' Remove an installed DISPLACE binary
#'
#' @param version Version label to remove. Required -- this function will not
#'   wipe the whole cache without being told which version to drop.
#' @return `TRUE` if something was removed, invisibly.
#' @export
#' @examples
#' \dontrun{
#' uninstall_displace("1.6.6-7f2656fb")
#' }
uninstall_displace <- function(version) {
  if (missing(version) || !length(version) || !nzchar(version)) {
    stopf("version is required; refusing to remove the whole cache directory.")
  }
  dest <- file.path(displace_cache_dir(), version)
  if (!dir.exists(dest)) {
    msgf("nothing to remove: %s does not exist", dest)
    return(invisible(FALSE))
  }
  unlink(dest, recursive = TRUE)
  msgf("removed %s", dest)
  invisible(TRUE)
}
