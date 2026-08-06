## Builds a database with the shape DISPLACE writes, so the reader is exercised
## without needing a simulator binary. It is not a substitute for reading a real
## output database -- see test-golden.R -- but it does pin down the metadata and
## dispatch behaviour, which is where version drift will first show up.

make_fake_db <- function(path = withr_tempfile(".db"), db_version = 4L) {
  skip_if_not_installed("DBI")
  skip_if_not_installed("RSQLite")

  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  DBI::dbWriteTable(con, "Metadata", data.frame(
    key = c("dbVersion", "simulationName"),
    value = c(as.character(db_version), "sim1"),
    stringsAsFactors = FALSE
  ))
  DBI::dbWriteTable(con, "VesselLogLike", data.frame(
    tstep = c(1L, 2L, 3L),
    vesselId = c(0L, 0L, 1L),
    revenue = c(100.5, 200.25, 50),
    stringsAsFactors = FALSE
  ))
  DBI::dbWriteTable(con, "NodesDef", data.frame(
    nodeId = 0:2, x = c(10, 11, 12), y = c(55, 56, 57),
    stringsAsFactors = FALSE
  ))
  path
}

test_that("metadata and the schema version are read", {
  db <- make_fake_db()
  md <- displace_db_metadata(db)
  expect_equal(md[["dbVersion"]], "4")
  expect_equal(displace_db_version(db), 4L)
})

test_that("a database with no dbVersion yields NA rather than an error", {
  skip_if_not_installed("RSQLite")
  db <- withr_tempfile(".db")
  con <- DBI::dbConnect(RSQLite::SQLite(), db)
  DBI::dbWriteTable(con, "Metadata",
                    data.frame(key = "simulationName", value = "sim1"))
  DBI::dbDisconnect(con)

  expect_true(is.na(displace_db_version(db)))
})

test_that("only known DISPLACE tables are listed by default", {
  db <- make_fake_db()
  skip_if_not_installed("RSQLite")
  con <- DBI::dbConnect(RSQLite::SQLite(), db)
  DBI::dbWriteTable(con, "SomethingElse", data.frame(a = 1))
  DBI::dbDisconnect(con)

  expect_false("SomethingElse" %in% displace_db_tables(db)$table)
  expect_true("SomethingElse" %in% displace_db_tables(db, all = TRUE)$table)

  tabs <- displace_db_tables(db)
  expect_equal(tabs$rows[tabs$table == "VesselLogLike"], 3L)
})

test_that("read_displace_db supports WHERE and LIMIT", {
  db <- make_fake_db()
  expect_equal(nrow(read_displace_db(db, "VesselLogLike")), 3L)
  expect_equal(nrow(read_displace_db(db, "VesselLogLike", where = "tstep > 1")), 2L)
  expect_equal(nrow(read_displace_db(db, "VesselLogLike", limit = 1)), 1L)
})

test_that("a newer schema version warns rather than failing silently", {
  ## Schema drift is the thing Phase 4 exists to catch; a reader that keeps
  ## quiet about it is worse than one that errors.
  db <- make_fake_db(db_version = 99L)
  expect_warning(read_displace_db(db, "VesselLogLike"), "schema version 99")
  expect_silent(read_displace_db(db, "VesselLogLike", check_version = FALSE))
})

test_that("a missing table lists the ones that exist", {
  db <- make_fake_db()
  expect_error(read_displace_db(db, "Windmills"), "Tables present")
})

test_that("a run's output directory resolves to its single database", {
  d <- tempfile()
  dir.create(d, recursive = TRUE)
  make_fake_db(file.path(d, "minitest_sim1_out.db"))

  expect_equal(displace_db_version(d), 4L)
})

test_that("several databases in one directory is an error, not a guess", {
  d <- tempfile()
  dir.create(d, recursive = TRUE)
  make_fake_db(file.path(d, "minitest_sim1_out.db"))
  make_fake_db(file.path(d, "minitest_sim2_out.db"))

  expect_error(displace_db_version(d), "several output databases")
})

test_that("a missing database points at the text reader", {
  expect_error(displace_db_version(withr_tempfile(".db")), "read_displace_output")
})

test_that("arbitrary SQL runs against the database", {
  db <- make_fake_db()
  res <- displace_db_query(db, "SELECT vesselId, SUM(revenue) AS total
                                FROM VesselLogLike GROUP BY vesselId")
  expect_equal(nrow(res), 2L)
  expect_equal(res$total[res$vesselId == 0L], 300.75)
})

test_that("the connection is read-only", {
  db <- make_fake_db()
  expect_error(displace_db_query(db, "DELETE FROM VesselLogLike"))
})
