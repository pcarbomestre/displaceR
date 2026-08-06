## displace_doctor() is the first thing to run when something is wrong on a new
## machine, so it must never itself error -- whatever state the environment is
## in, it has to produce a report.

test_that("the doctor reports rather than erroring when nothing is set up", {
  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = ""), {
    d <- displace_doctor(verbose = FALSE)
    expect_s3_class(d, "displace_doctor")
    expect_true(all(c("check", "status", "detail") %in% names(d)))
    expect_true(all(d$status %in% c("ok", "warn", "fail", "info")))
  })
})

test_that("a missing simulator is a failure, with the ways to fix it", {
  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = ""), {
    d <- displace_doctor(verbose = FALSE)
    sim <- d[d$check == "simulator", ]
    expect_equal(sim$status, "fail")
    expect_match(sim$detail, "install_displace")
    expect_match(sim$detail, "DISPLACE_BINARY")
    expect_false(attr(d, "ok"))
  })
})

test_that("a DISPLACE_BINARY pointing nowhere is called out specifically", {
  withr_env(list(DISPLACER_CACHE = tempfile(),
                 DISPLACE_BINARY = "/no/such/displace"), {
    d <- displace_doctor(verbose = FALSE)
    row <- d[d$check == "DISPLACE_BINARY", ]
    expect_equal(nrow(row), 1L)
    expect_equal(row$status, "fail")
    expect_match(row$detail, "no such file")
  })
})

test_that("a working binary passes the simulator checks", {
  ## A shell script stands in for the real thing: displace_doctor() only needs
  ## something executable that mentions displace when run.
  fake <- tempfile()
  dir.create(fake)
  exe <- file.path(fake, "displace")
  writeLines(c("#!/bin/sh", "echo 'This is displace, version 1.6.6 build 0'"), exe)
  Sys.chmod(exe, "0755")
  skip_if_not(file.access(exe, mode = 1) == 0, "cannot mark a file executable here")

  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = exe), {
    d <- displace_doctor(verbose = FALSE)
    expect_equal(d$status[d$check == "simulator"], "ok")
    expect_equal(d$status[d$check == "simulator runs"], "ok")
    expect_match(d$detail[d$check == "simulator runs"], "displace")
  })
})

test_that("a binary that does not run is reported as a failure", {
  fake <- tempfile()
  dir.create(fake)
  exe <- file.path(fake, "displace")
  writeLines("not an executable", exe)   # deliberately not chmod +x

  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = exe), {
    d <- displace_doctor(verbose = FALSE)
    expect_equal(d$status[d$check == "simulator runs"], "fail")
    expect_false(attr(d, "ok"))
  })
})

test_that("an empty manifest warns rather than failing", {
  ## Not having published a release yet is a normal state -- there are other
  ## ways to install -- so it must not read as a broken environment.
  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = ""), {
    d <- displace_doctor(verbose = FALSE)
    row <- d[d$check == "manifest", ]
    expect_equal(row$status, "warn")
    expect_match(row$detail, "install_displace\\(from")
  })
})

test_that("the report prints without error in both states", {
  withr_env(list(DISPLACER_CACHE = tempfile(), DISPLACE_BINARY = ""), {
    expect_output(displace_doctor(), "displaceR environment check")
    expect_output(displace_doctor(), "Not ready")
  })
})

test_that("missing_shared_libs returns nothing for a resolvable binary", {
  skip_if(!nzchar(Sys.which("ldd")), "ldd not available")
  skip_if(!nzchar(Sys.which("ls")), "ls not available")
  expect_length(displaceR:::missing_shared_libs(Sys.which("ls")), 0L)
})
