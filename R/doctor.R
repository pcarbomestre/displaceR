## One call that answers "will this work on this machine, and if not, why not".
##
## The failure modes displaceR actually hits on a locked-down server are
## specific and diagnosable: no binary installed, a binary built against a newer
## glibc than the host, missing shared libraries, a read-only cache directory,
## optional packages absent. Each of those produces a different and fairly
## opaque error at the point of use. Checking them up front, in one place, is
## worth more than any amount of documentation.

#' Check whether this machine can run DISPLACE
#'
#' Runs through everything displaceR needs and reports what is in place, what is
#' missing, and what to do about it. Safe to run anywhere: it never installs
#' anything and never modifies the cache.
#'
#' Start here when a run fails for an unclear reason, or when setting the
#' package up on a new server.
#'
#' @param verbose Print the report. `FALSE` returns the results silently, for
#'   programmatic use.
#'
#' @return A `displace_doctor` object: a data frame of checks with columns
#'   `check`, `status` (`"ok"`, `"warn"`, `"fail"` or `"info"`) and `detail`,
#'   carrying an `ok` attribute that is `TRUE` when nothing failed.
#'
#' @export
#' @examples
#' displace_doctor()
displace_doctor <- function(verbose = TRUE) {
  checks <- list()
  add <- function(check, status, detail) {
    checks[[length(checks) + 1L]] <<- data.frame(
      check = check, status = status, detail = detail,
      stringsAsFactors = FALSE
    )
  }

  ## --- platform -------------------------------------------------------------
  sysname <- Sys.info()[["sysname"]]
  machine <- Sys.info()[["machine"]]
  ## DISPLACE itself runs on all three platforms: upstream ships a Windows
  ## installer and a macOS DMG. What is Linux-only is this package's *download*
  ## path, because the build pipeline publishes Linux tarballs and nothing else.
  ## Those are different claims, and conflating them wrongly reports a working
  ## Windows or macOS install as unusable -- so a non-Linux host is never a
  ## failure here, only a note that the binary must come from elsewhere.
  ## Does the manifest offer a build this host can actually use? Asked once and
  ## reused: both the platform line and the "no binary found" advice depend on
  ## it, and deriving it twice from the OS is how they came to contradict each
  ## other -- "a prebuilt binary is available" next to "install upstream's macOS
  ## package".
  have_prebuilt <- tryCatch({
    m <- read_manifest()
    entry <- if (!is.null(m$default)) m$versions[[m$default]] else NULL
    builds <- names(entry$builds %||% list())
    if (identical(sysname, "Linux")) {
      ## Linux builds are glibc-keyed; any of them is a candidate, and
      ## select_build() decides which. Treat "some Linux build exists" as
      ## available rather than re-running the glibc comparison here.
      any(!grepl("^(macos|windows)-", builds))
    } else {
      keys <- host_build_keys()
      length(keys) && any(keys %in% builds)
    }
  }, error = function(e) FALSE)

  if (identical(sysname, "Linux")) {
    add("platform", if (identical(machine, "x86_64")) "ok" else "warn",
        if (identical(machine, "x86_64")) {
          sprintf("Linux %s", machine)
        } else {
          sprintf(paste0("Linux %s. Prebuilt binaries are x86_64 only; build ",
                         "from source with tools/build-displace.sh."), machine)
        })
  } else {
    ## Whether a prebuilt binary exists for this platform is a fact about the
    ## manifest, not about the operating system -- so ask the manifest rather
    ## than hardcoding "Linux only", which went stale the moment macOS builds
    ## were published.
    add("platform", "info",
        if (have_prebuilt) {
          sprintf("%s (%s). A prebuilt binary is available: install_displace().",
                  sysname, machine)
        } else {
          sprintf(paste0("%s (%s). DISPLACE runs here, but no prebuilt binary ",
                         "is published for it -- build one with ",
                         "tools/build-displace.sh, or point DISPLACE_BINARY at ",
                         "a simulator you already have."),
                  sysname, machine)
        })
  }

  ## glibc only means anything on Linux. Reporting "could not determine" on
  ## macOS or Windows is noise about a constraint that does not apply there.
  hg <- NA_character_
  if (identical(sysname, "Linux")) {
    hg <- host_glibc()
    add("glibc", if (is.na(hg)) "warn" else "info",
        if (is.na(hg)) {
          "could not determine the host glibc version (ldd unavailable)."
        } else {
          sprintf(paste0("%s. A binary must be built against this version or ",
                         "older; a newer one will not start."), hg)
        })
  }

  ## --- cache ----------------------------------------------------------------
  cache <- displace_cache_dir()
  if (dir.exists(cache)) {
    writable <- file.access(cache, mode = 2) == 0
    add("cache directory", if (writable) "ok" else "fail",
        sprintf("%s%s", cache,
                if (writable) "" else
                  " -- not writable. Set DISPLACER_CACHE to somewhere you can write."))
  } else {
    parent <- dirname(cache)
    while (!dir.exists(parent) && parent != dirname(parent)) {
      parent <- dirname(parent)
    }
    creatable <- file.access(parent, mode = 2) == 0
    add("cache directory", if (creatable) "ok" else "warn",
        sprintf("%s does not exist yet%s", cache,
                if (creatable) " (will be created on install)." else
                  sprintf(" and %s is not writable. Set DISPLACER_CACHE.", parent)))
  }

  ## --- binary ---------------------------------------------------------------
  env_binary <- Sys.getenv("DISPLACE_BINARY", "")
  if (nzchar(env_binary)) {
    add("DISPLACE_BINARY", if (file.exists(env_binary)) "ok" else "fail",
        sprintf("%s%s", env_binary,
                if (file.exists(env_binary)) " (overrides the cache)" else
                  " -- set, but no such file."))
  }

  path <- tryCatch(displace_path(error = FALSE), error = function(e) NA_character_)
  if (is.na(path)) {
    ## Lead with install_displace() wherever a build actually exists for this
    ## host, whatever the platform. Only suggest the manual routes when it
    ## genuinely has nothing to download.
    add("simulator", "fail", paste0(
      "no DISPLACE binary found. ",
      if (have_prebuilt) paste0(
        "Run\n",
        "      install_displace()\n",
        "  or, to use one you already have,\n") else paste0(
        "No prebuilt binary is published for this platform, so either\n",
        "      build one:  tools/build-displace.sh --ref <upstream-sha>\n",
        "      then:       install_displace(from = \"<built>.tar.gz\")\n",
        "  or point at a simulator you already have,\n"),
      sprintf("      Sys.setenv(DISPLACE_BINARY = \"/path/to/%s\")",
              displace_exe_name())))
  } else {
    add("simulator", "ok", path)

    ## Shared libraries. This is the check that catches a binary built on a
    ## newer distro than the host, which otherwise fails with a bare
    ## "error while loading shared libraries".
    missing <- if (identical(sysname, "Linux")) missing_shared_libs(path) else NULL
    if (is.null(missing)) {
      ## Off Linux there is nothing ldd could tell us, so say nothing rather
      ## than report a check that does not apply as inconclusive.
      if (identical(sysname, "Linux")) {
        add("shared libraries", "info", "could not run ldd to check them.")
      }
    } else if (length(missing)) {
      ## Two very different causes, and the advice for one is useless for the
      ## other. A missing libc/libstdc++ really does mean the binary is too new
      ## for this host. A missing Boost or GeographicLib does not -- those are
      ## build dependencies that a bare server has no reason to have, and the
      ## glibc advice sends the user chasing a version match that is already
      ## correct. Split on the ABI floor and say the right thing for each.
      floor_re <- "^(libc|libstdc\\+\\+|libgcc_s|libm|libpthread|libdl|librt|ld-linux)"
      abi <- grep(floor_re, missing, value = TRUE)
      third_party <- setdiff(missing, abi)
      add("shared libraries", "fail",
          paste0(
            sprintf("%d unresolved: %s.\n", length(missing),
                    paste(missing, collapse = ", ")),
            if (length(abi)) sprintf(paste0(
              "      %s belong to the C/C++ runtime, so this binary was built ",
              "on a newer\n      system than this one. Rebuild on a host whose ",
              "glibc is no newer than %s.\n"),
              paste(abi, collapse = ", "),
              if (is.na(hg)) "this host's" else hg),
            if (length(third_party)) paste0(
              "      ", paste(third_party, collapse = ", "),
              " should have been bundled in the payload.\n",
              "      Reinstall to pick up a newer build:\n",
              "          uninstall_displace(displace_version()$installed_version)\n",
              "          install_displace()\n",
              "      If that does not help, the tarball predates dependency ",
              "bundling; install\n      the matching system packages ",
              "(libboost1.83, libgeographiclib26) or rebuild\n",
              "      with tools/build-displace.sh.")))
    } else {
      add("shared libraries", "ok", "all resolved")
    }

    ## And the only test that really settles it. Judge on the exit status, not
    ## on the output text: the path itself contains "displace", so a message
    ## like "/opt/displace: Permission denied" would match a naive text check.
    banner <- tryCatch(
      suppressWarnings(system2(path, "--help", stdout = TRUE, stderr = TRUE)),
      error = function(e) NULL
    )
    st <- if (is.null(banner)) 1L else attr(banner, "status") %||% 0L
    ran <- identical(as.integer(st), 0L) && length(banner) > 0L
    add("simulator runs", if (ran) "ok" else "fail",
        if (ran) {
          trim(banner[1])
        } else {
          sprintf(paste0("--help exited with status %s%s. See the shared library ",
                         "check above, and confirm the file is executable."),
                  format(st),
                  if (length(banner)) sprintf(": %s", trim(banner[1])) else "")
        })

    info <- tryCatch(displace_version(), error = function(e) NULL)
    sha <- info$upstream_sha
    add("upstream commit",
        if (is.null(sha) || is.na(sha) || identical(sha, "unknown")) "warn" else "info",
        if (is.null(sha) || is.na(sha)) {
          paste0("unrecorded -- this binary was not installed by ",
                 "install_displace(), so there is no provenance to cite.")
        } else {
          sha
        })
  }

  ## --- optional packages ----------------------------------------------------
  for (pkg in c("DBI", "RSQLite")) {
    have <- requireNamespace(pkg, quietly = TRUE)
    add(sprintf("package %s", pkg), if (have) "ok" else "fail",
        if (have) "installed" else
          paste0("missing. Needed to read DISPLACE's SQLite output, which is ",
                 "the preferred format, and to tell a completed run from a ",
                 "crashed one."))
  }
  have_json <- requireNamespace("jsonlite", quietly = TRUE)
  add("package jsonlite", if (have_json) "ok" else "fail",
      if (have_json) "installed" else
        "missing. Needed to read the binary manifest, so install_displace() will fail.")

  ## --- manifest -------------------------------------------------------------
  if (have_json) {
    vs <- tryCatch(displace_versions(), error = function(e) NULL)
    if (is.null(vs)) {
      add("manifest", "warn", "inst/manifest.json could not be read.")
    } else if (!nrow(vs)) {
      add("manifest", "warn", paste0(
        "no binaries published yet, so install_displace() cannot download one.\n",
        "      Use install_displace(from = ...) or DISPLACE_BINARY meanwhile."))
    } else {
      add("manifest", "ok", sprintf("%d version(s) available: %s",
                                    nrow(vs), paste(vs$version, collapse = ", ")))
    }
  }

  out <- do.call(rbind, checks)
  attr(out, "ok") <- !any(out$status == "fail")
  class(out) <- c("displace_doctor", class(out))

  if (verbose) {
    print(out)
  }
  invisible(out)
}

## Shared libraries the loader cannot resolve. NULL when ldd is unusable.
missing_shared_libs <- function(path) {
  if (!nzchar(Sys.which("ldd"))) {
    return(NULL)
  }
  out <- tryCatch(
    suppressWarnings(system2("ldd", shQuote(path), stdout = TRUE, stderr = TRUE)),
    error = function(e) NULL
  )
  if (is.null(out) || !length(out)) {
    return(NULL)
  }
  hits <- grep("not found", out, value = TRUE)
  trim(sub("[[:space:]]*=>.*$", "", hits))
}

#' @export
print.displace_doctor <- function(x, ...) {
  mark <- c(ok = "OK  ", warn = "WARN", fail = "FAIL", info = "    ")
  cat("displaceR environment check\n\n")
  width <- max(nchar(x$check))
  for (i in seq_len(nrow(x))) {
    cat(sprintf("  [%s] %-*s  %s\n", mark[[x$status[i]]], width, x$check[i],
                x$detail[i]))
  }
  cat("\n")
  if (isTRUE(attr(x, "ok"))) {
    nwarn <- sum(x$status == "warn")
    if (nwarn) {
      cat(sprintf("Ready to run, with %d warning(s).\n", nwarn))
    } else {
      cat("Ready to run.\n")
    }
  } else {
    cat(sprintf("Not ready: %d check(s) failed. See the detail above.\n",
                sum(x$status == "fail")))
  }
  invisible(x)
}
