## install_displace(from = ...) is the route that works with no published
## release and no outbound network: build on any machine with a compiler, copy
## the artefact over, install it here. It is what makes the package usable on a
## locked-down server today.

## A stand-in for the payload tools/build-displace.sh stages. The contents do
## not need to be a real ELF binary -- these tests are about the staging,
## provenance and atomicity, not about running the simulator.
make_payload <- function(dir = tempfile(), build_info = TRUE, exe = TRUE) {
  dir.create(dir, recursive = TRUE)
  if (exe) {
    writeLines("#!/bin/sh\necho 'This is displace, version 1.6.6 build 0'",
               file.path(dir, "displace"))
  }
  writeLines("so", file.path(dir, "libcommons.so"))
  writeLines("so", file.path(dir, "libformats.so"))
  if (build_info) {
    skip_if_not_installed("jsonlite")
    jsonlite::write_json(list(
      upstream_ref = "master",
      upstream_sha = "7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de",
      displace_version = "1.6.6",
      glibc = "2.39",
      build_patches = "cxx17 msqlitecpp-includes"
    ), file.path(dir, "build-info.json"), auto_unbox = TRUE)
  }
  dir
}

make_tarball <- function(payload = make_payload()) {
  skip_if(!nzchar(Sys.which("tar")), "tar not available")
  tgz <- tempfile(fileext = ".tar.gz")
  ## Flat archive, matching what the build workflow publishes.
  st <- system2("tar", c("-czf", shQuote(tgz), "-C", shQuote(payload), "."),
                stdout = FALSE, stderr = FALSE)
  skip_if(!identical(as.integer(st), 0L), "could not create a test tarball")
  tgz
}

test_that("a payload directory installs and records its provenance", {
  cache <- tempfile()
  payload <- make_payload()

  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    exe <- suppressMessages(install_displace(from = payload))
    expect_true(file.exists(exe))

    ## The version label is derived from the upstream commit, so two builds
    ## from different refs cannot silently overwrite each other.
    inst <- displace_installed()
    expect_equal(nrow(inst), 1L)
    expect_equal(inst$version, "1.6.6-7f2656fb7cd4-local")
    expect_equal(inst$upstream_sha, "7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de")
  })
})

test_that("the whole payload is installed, not just the executable", {
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    exe <- suppressMessages(install_displace(from = make_payload()))
    ## commons and formats are built SHARED, so the .so files must travel with
    ## the binary or it will not start.
    expect_true(file.exists(file.path(dirname(exe), "libcommons.so")))
    expect_true(file.exists(file.path(dirname(exe), "libformats.so")))
  })
})

test_that("the installed executable is made executable", {
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    exe <- suppressMessages(install_displace(from = make_payload()))
    expect_true(file.access(exe, mode = 1) == 0)
  })
})

test_that("a payload without build-info.json still installs, labelled 'local'", {
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    exe <- suppressMessages(install_displace(from = make_payload(build_info = FALSE)))
    expect_true(file.exists(exe))
    inst <- displace_installed()
    expect_equal(inst$version, "local")
    ## Provenance is unknown and says so, rather than claiming a commit.
    expect_match(inst$upstream_sha, "unknown")
  })
})

test_that("a tarball installs and carries its provenance", {
  skip_if_not_installed("jsonlite")
  cache <- tempfile()
  tgz <- make_tarball()

  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    exe <- suppressMessages(install_displace(from = tgz))
    expect_true(file.exists(exe))
    ## build-info.json is copied into the payload by build-displace.sh, so a
    ## tarball is self-describing.
    expect_equal(displace_installed()$upstream_sha,
                 "7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de")
  })
})

test_that("an explicit version label overrides the derived one", {
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    suppressMessages(install_displace(from = make_payload(), version = "mybuild"))
    expect_equal(displace_installed()$version, "mybuild")
  })
})

test_that("reinstalling the same version needs overwrite = TRUE", {
  cache <- tempfile()
  payload <- make_payload()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    suppressMessages(install_displace(from = payload, version = "v1"))
    expect_error(install_displace(from = payload, version = "v1"), "already installed")
    expect_silent(suppressMessages(
      install_displace(from = payload, version = "v1", overwrite = TRUE)
    ))
  })
})

test_that("a payload with no displace executable is rejected, naming what it wanted", {
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    expect_error(
      suppressMessages(install_displace(from = make_payload(exe = FALSE))),
      "no 'displace' executable"
    )
  })
})

test_that("a nonexistent source is reported before anything is touched", {
  expect_error(install_displace(from = "/no/such/payload"), "no such file or directory")
})

test_that("a failed install leaves no half-populated version directory", {
  ## displace_path() scans the cache for directories containing a `displace`,
  ## so an aborted install must not leave one behind for it to find.
  cache <- tempfile()
  withr_env(list(DISPLACER_CACHE = cache, DISPLACE_BINARY = ""), {
    try(suppressMessages(install_displace(from = make_payload(exe = FALSE),
                                          version = "broken")), silent = TRUE)
    expect_equal(nrow(displace_installed()), 0L)
    expect_false(dir.exists(file.path(cache, "broken")))
  })
})
