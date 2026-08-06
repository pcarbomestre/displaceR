## The positional reader is the foundation both simusspe_ formats sit on, so it
## is tested directly against the upstream test case in
## formats/test/linenumberreader.cpp.

test_that("read_linenumber_lines matches upstream's LineNumberReader test case", {
  lines <- c("Line0", "Empty", "Line2", "Empty", "Empty", "Line5")
  spec <- c(Line0 = 0L, Line2 = 2L, Line5 = 5L)

  got <- displaceR:::read_linenumber_lines(lines, spec)

  expect_equal(got$Line0, "Line0")
  expect_equal(got$Line2, "Line2")
  expect_equal(got$Line5, "Line5")
})

test_that("lines are trimmed, as boost::trim does", {
  lines <- c("x", "  padded  ")
  got <- displaceR:::read_linenumber_lines(lines, c(v = 1L))
  expect_equal(got$v, "padded")
})

test_that("a line past the end of the file yields NA, not an error", {
  ## Upstream's reader simply never sets the key, and the field falls back to
  ## its default. Mirroring that is what lets the scenario reader treat late
  ## optional fields as optional.
  got <- displaceR:::read_linenumber_lines(c("a", "b"), c(present = 1L, absent = 99L))
  expect_equal(got$present, "b")
  expect_true(is.na(got$absent))
})

test_that("'#' is not a comment character; only line numbers matter", {
  ## If '#' were treated as a comment, field v would pick up "value" instead of
  ## the '#' line. This is exactly the misreading the format invites.
  lines <- c("value", "# not a comment to the parser")
  got <- displaceR:::read_linenumber_lines(lines, c(v = 1L))
  expect_equal(got$v, "# not a comment to the parser")
})

test_that("write_linenumber_file round-trips through the reader", {
  spec <- c(a = 1L, b = 3L, c = 5L)
  f <- withr_tempfile()
  displaceR:::write_linenumber_file(f, spec, list(a = "1", b = "two", c = "3 4 5"))

  got <- displaceR:::read_linenumber_file(f, spec)
  expect_equal(got$a, "1")
  expect_equal(got$b, "two")
  expect_equal(got$c, "3 4 5")

  ## And the layout is the conventional one: comments on the even lines.
  lines <- readLines(f)
  expect_equal(length(lines), 6L)
  expect_match(lines[1], "^# ")
  expect_match(lines[3], "^# ")
})
