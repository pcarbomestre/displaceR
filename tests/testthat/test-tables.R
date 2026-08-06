## The keyed-table format, and the two guards that stop it being applied to
## files it does not fit. Both guards exist because applying the format blindly
## to DISPLACE_input_minitest corrupted files and changed the simulator's
## results -- see docs/roadmap.md.

test_that("a keyed table reads, discarding the header as the loader does", {
  f <- withr_tempfile()
  writeLines(c("vid idx_nodes", "DNK001 1", "DNK001 2", "DNK002 5"), f)

  t <- read_displace_table(f)
  expect_equal(nrow(t), 3L)
  expect_equal(names(t), c("vid", "idx_nodes"))
  expect_equal(t$vid, c("DNK001", "DNK001", "DNK002"))
  expect_equal(t$idx_nodes, c(1L, 2L, 5L))
})

test_that("the header's content is irrelevant, only its presence", {
  ## The loader does getline() into a dummy and never parses it, so a
  ## descriptive sentence is as valid as column names -- but the line must be
  ## there or the first record is eaten.
  f <- withr_tempfile()
  writeLines(c("this is a descriptive sentence, not column names",
               "DNK001 1", "DNK002 2"), f)

  t <- read_displace_table(f)
  expect_equal(nrow(t), 2L)
  ## Names fall back to V1/V2 when the header does not have one field per column.
  expect_equal(names(t), c("V1", "V2"))
})

test_that("a headerless file is refused rather than silently losing a record", {
  ## popsspe_*/0spe_initial_tac.dat is a bare number. Read with header = TRUE it
  ## produced a table whose column name was the lost value, and a round trip
  ## wrote that corruption straight back.
  f <- withr_tempfile()
  writeLines("10000", f)
  expect_error(read_displace_table(f), "has no header")

  expect_equal(nrow(read_displace_table(f, header = FALSE)), 1L)
  expect_equal(read_displace_table(f, header = FALSE)[[1]], 10000L)
})

test_that("a multi-column headerless file is refused too", {
  f <- withr_tempfile()
  writeLines(c("2 5 0.35 10 15 10300 0.35"), f)
  expect_error(read_displace_table(f), "header = FALSE")
  expect_equal(ncol(read_displace_table(f, header = FALSE)), 7L)
})

test_that("a pipe-separated file read as whitespace is refused", {
  ## Otherwise it yields a single mangled column and no error at all.
  f <- withr_tempfile()
  writeLines(c("id|name|x", "1|firm1|10.11", "2|firm2|56.45"), f)
  expect_error(read_displace_table(f), 'sep = "\\|"')

  t <- read_displace_table(f, sep = "|")
  expect_equal(ncol(t), 3L)
  expect_equal(t$name, c("firm1", "firm2"))
})

test_that("an empty file stays empty through a round trip", {
  ## Empty metier_closure_* months are legitimate. Writing a header into one
  ## turns it into a file with a record the simulator will then read.
  f <- withr_tempfile()
  file.create(f)
  t <- read_displace_table(f)
  expect_equal(nrow(t), 0L)

  g <- withr_tempfile()
  write_displace_table(t, g)
  expect_equal(file.size(g), 0)
})

test_that("a header with no records round-trips to a header with no records", {
  f <- withr_tempfile()
  writeLines("vid idx_nodes", f)
  t <- read_displace_table(f)
  expect_equal(nrow(t), 0L)

  g <- withr_tempfile()
  write_displace_table(t, g)
  expect_equal(readLines(g), "vid idx_nodes")
})

test_that("values round-trip without gaining spurious precision", {
  ## shipsspe_lanes_lat.dat carries 54.3473507; a fixed digit count rewrote it
  ## as 54.34735070, which is equal but not identical.
  f <- withr_tempfile()
  writeLines(c("node lat", "0 54.3473507", "1 10.12187448"), f)
  g <- withr_tempfile()
  write_displace_table(read_displace_table(f), g)
  expect_equal(readLines(g), readLines(f))
})

test_that("writing a value containing whitespace is refused", {
  ## It would read back as two columns.
  x <- data.frame(name = "MY FAKE PORT", node = 36L, stringsAsFactors = FALSE)
  expect_error(write_displace_table(x, withr_tempfile()), "whitespace inside a value")
  ## The pipe format has no such problem.
  expect_silent(write_displace_table(x, withr_tempfile(), sep = "|"))
})

test_that("col_names and col_types are honoured", {
  f <- withr_tempfile()
  writeLines(c("a b", "1 2", "3 4"), f)
  t <- read_displace_table(f, col_names = c("x", "y"), col_types = c("d", "c"))
  expect_equal(names(t), c("x", "y"))
  expect_type(t$x, "double")
  expect_type(t$y, "character")

  expect_error(read_displace_table(f, col_names = "only_one"), "column names")
  expect_error(read_displace_table(f, col_types = c("d")), "col_types has 1")
  expect_error(read_displace_table(f, col_types = c("z", "z")), "\"i\", \"d\" or \"c\"")
})

## --- vessel features -------------------------------------------------------

test_that("vessel features parse into the parser's own field order", {
  ## The calendar block sits at 16-19, before firm_id at 20. Getting that
  ## backwards would swap a firm identifier for a weekday number.
  f <- withr_tempfile()
  writeLines("DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|7|1", f)

  v <- read_displace_vessel_features(path = f)
  expect_equal(nrow(v), 1L)
  expect_equal(v$VE_REF, "DNK001")
  expect_equal(v$speed, 10)
  expect_equal(v$weekEndStartDay, 4L)
  expect_equal(v$weekEndEndDay, 6L)
  expect_equal(v$workStartHour, 4L)
  expect_equal(v$workEndHour, 22L)
  expect_equal(v$firm_id, 7L)
  expect_equal(v$is_part_of_ref_fleet, 1L)
})

test_that("vessel features round-trip byte-identically", {
  line <- "DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|1|1"
  f <- withr_tempfile()
  writeLines(c(line, sub("DNK001", "DNK002", line)), f)

  g <- withr_tempfile()
  write_displace_vessel_features(read_displace_vessel_features(path = f), path = g)
  expect_equal(readLines(g), readLines(f))
})

test_that("a vessel features line with too few fields is rejected", {
  ## The simulator requires at least 22 and refuses the file otherwise, so
  ## catching it here saves an opaque load failure.
  f <- withr_tempfile()
  writeLines("DNK001|1|10", f)
  expect_error(read_displace_vessel_features(path = f), "at least 22")
})

test_that("writing vessel features requires every column", {
  f <- withr_tempfile()
  writeLines("DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|1|1", f)
  v <- read_displace_vessel_features(path = f)
  v$firm_id <- NULL
  expect_error(write_displace_vessel_features(v, path = withr_tempfile()),
               "missing column")
})

test_that("writing vessel features reorders to the positional layout", {
  ## The file has no header, so column order is the entire contract.
  f <- withr_tempfile()
  writeLines("DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|1|1", f)
  v <- read_displace_vessel_features(path = f)

  g <- withr_tempfile()
  write_displace_vessel_features(v[, rev(names(v))], path = g)
  expect_equal(readLines(g), readLines(f))
})
