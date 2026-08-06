test_that("the shipped manifest parses and declares a version this package knows", {
  m <- displaceR:::read_manifest()
  expect_equal(as.integer(m$manifest_version), 1L)
  expect_true(is.list(m$versions))
})

test_that("displace_versions returns the documented columns even when empty", {
  v <- displace_versions()
  expect_s3_class(v, "data.frame")
  expect_true(all(c("version", "upstream_sha", "displace_version", "released",
                    "glibc", "is_default") %in% names(v)))
})

test_that("a manifest with entries is summarised correctly", {
  skip_if_not_installed("jsonlite")
  f <- withr_tempfile(".json")
  jsonlite::write_json(list(
    manifest_version = 1L,
    default = "1.6.6-aaaa",
    versions = list(
      "1.6.6-aaaa" = list(upstream_sha = "aaaa", displace_version = "1.6.6",
                          released = "2026-08-01",
                          builds = list("2.35" = list(url = "u1", sha256 = "s1"),
                                        "2.39" = list(url = "u2", sha256 = "s2"))),
      "1.6.6-bbbb" = list(upstream_sha = "bbbb", displace_version = "1.6.6",
                          released = "2026-07-01",
                          builds = list("2.35" = list(url = "u3", sha256 = "s3")))
    )
  ), f, auto_unbox = TRUE)

  m <- displaceR:::read_manifest(f)
  expect_equal(m$default, "1.6.6-aaaa")
  expect_length(m$versions, 2L)
})

test_that("the glibc build selection never picks something the host cannot run", {
  entry <- list(builds = list(
    "2.31" = list(url = "old"),
    "2.35" = list(url = "mid"),
    "2.39" = list(url = "new")
  ))

  ## A host with glibc 2.35 can run the 2.31 and 2.35 builds; the newest usable
  ## one wins.
  local_mocked_bindings(host_glibc = function() "2.35")
  expect_equal(displaceR:::select_build(entry, "v")$target, "2.35")

  local_mocked_bindings(host_glibc = function() "2.40")
  expect_equal(displaceR:::select_build(entry, "v")$target, "2.39")

  ## Nothing usable is an error naming the host's version, not a silent
  ## download that fails to start.
  local_mocked_bindings(host_glibc = function() "2.28")
  expect_error(displaceR:::select_build(entry, "v"), "glibc 2\\.28")
})

test_that("an unknown host glibc falls back to the oldest build, with a warning", {
  entry <- list(builds = list("2.31" = list(url = "old"),
                              "2.39" = list(url = "new")))
  local_mocked_bindings(host_glibc = function() NA_character_)
  expect_warning(sel <- displaceR:::select_build(entry, "v"), "glibc")
  expect_equal(sel$target, "2.31")
})

test_that("version strings sort numerically, not lexically", {
  ## "2.9" must sort below "2.35", which a plain sort() gets backwards.
  expect_equal(displaceR:::sort_versions(c("2.35", "2.9", "2.31")),
               c("2.9", "2.31", "2.35"))
})

test_that("DISPLACE_BINARY overrides everything", {
  fake <- withr_tempfile()
  file.create(fake)
  withr_env(list(DISPLACE_BINARY = fake), {
    expect_equal(displace_path(), normalizePath(fake))
  })
})

test_that("a DISPLACE_BINARY pointing nowhere is an error, not a silent fallback", {
  withr_env(list(DISPLACE_BINARY = "/no/such/displace"), {
    expect_error(displace_path(), "DISPLACE_BINARY")
  })
})

test_that("displace_path returns NA rather than erroring when asked", {
  withr_env(list(DISPLACE_BINARY = "", DISPLACER_CACHE = tempfile()), {
    expect_true(is.na(displace_path(error = FALSE)))
    expect_error(displace_path(), "no DISPLACE binary found")
  })
})

test_that("the cache directory honours DISPLACER_CACHE", {
  withr_env(list(DISPLACER_CACHE = "/custom/cache"), {
    expect_equal(displace_cache_dir(), "/custom/cache")
  })
})

test_that("install_displace explains itself when no binaries are published", {
  ## The shipped manifest is empty until the build workflow publishes one, and
  ## that state must produce actionable advice rather than a subscript error.
  expect_error(install_displace(), "DISPLACE_BINARY")
})

test_that("uninstall_displace refuses to wipe the whole cache", {
  expect_error(uninstall_displace(""), "refusing")
  expect_error(uninstall_displace(), "refusing")
})

test_that("displace_installed reports what is in the cache", {
  cache <- tempfile()
  dir.create(file.path(cache, "1.6.6-test"), recursive = TRUE)
  file.create(file.path(cache, "1.6.6-test", "displace"))
  writeLines("upstream_sha: deadbeef",
             file.path(cache, "1.6.6-test", "displaceR-install.txt"))

  withr_env(list(DISPLACER_CACHE = cache), {
    inst <- displace_installed()
    expect_equal(nrow(inst), 1L)
    expect_equal(inst$version, "1.6.6-test")
    expect_equal(inst$upstream_sha, "deadbeef")
  })
})
