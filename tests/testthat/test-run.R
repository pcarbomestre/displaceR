test_that("displace_args builds the documented CLI", {
  a <- displace_args("/data/in", "minitest", scenario = "baseline",
                     sim_name = "sim1", steps = 8762, output_dir = "/tmp/out")

  ## Options taking a separate value token.
  expect_equal(a[which(a == "-f") + 1L], "minitest")
  expect_equal(a[which(a == "-F") + 1L], "baseline")
  expect_equal(a[which(a == "-a") + 1L], "/data/in")
  expect_equal(a[which(a == "-O") + 1L], "/tmp/out")
  expect_equal(a[which(a == "-s") + 1L], "sim1")
  expect_equal(a[which(a == "-i") + 1L], "8762")

  expect_true("--disable-crash-handler" %in% a)
  expect_false(any(grepl("use-gui", a)))
})

test_that("implicit-value options carry their value adjacent to the flag", {
  ## boost::program_options only consumes a separate token for options without
  ## an implicit value. "-p 1" would set use_static_paths to the implicit 0 and
  ## leave "1" as an unexpected positional argument.
  a <- displace_args("/in", "case", static_paths = TRUE, export_vmslike = 0,
                     selected_vessels_only = 1)

  expect_true("-p1" %in% a)
  expect_true("-e0" %in% a)
  expect_true("-v1" %in% a)
  expect_false("-p" %in% a)
  expect_false("-e" %in% a)
})

test_that("--huge is always explicit, because its default is on upstream", {
  ## export_hugefiles defaults to 1 in main.cpp while --huge's implicit value is
  ## 0, so omitting the flag leaves huge exports enabled and a bare --huge
  ## disables them. Neither matches what huge = FALSE/TRUE reads as.
  expect_true("--huge=0" %in% displace_args("/in", "case"))
  expect_true("--huge=0" %in% displace_args("/in", "case", huge = FALSE))
  expect_true("--huge=1" %in% displace_args("/in", "case", huge = TRUE))
})

test_that("optional numeric arguments are omitted when NULL", {
  a <- displace_args("/in", "case", verbosity = NULL, dparam = NULL,
                     commit_rate = NULL, indb = NULL, num_threads = NULL)
  expect_false("-V" %in% a)
  expect_false("-d" %in% a)
  expect_false("--commit-rate" %in% a)
  expect_false("--indb" %in% a)
  expect_false("--num_threads" %in% a)
})

test_that("sqlite = FALSE disables the database output", {
  expect_true("--disable-sqlite" %in% displace_args("/in", "case", sqlite = FALSE))
  expect_false("--disable-sqlite" %in% displace_args("/in", "case", sqlite = TRUE))
})

test_that("--use-gui is refused even through extra_args", {
  expect_error(displace_args("/in", "case", extra_args = "--use-gui"), "use-gui")
})

test_that("extra_args are passed through verbatim", {
  a <- displace_args("/in", "case", extra_args = c("--rate", "5"))
  expect_equal(tail(a, 2), c("--rate", "5"))
})

test_that("input_name defaults to the upstream folder convention", {
  expect_equal(displaceR:::default_input_name("/data/DISPLACE_input_minitest"),
               "minitest")
  expect_equal(displaceR:::default_input_name("/data/DISPLACE_input_minitest/"),
               "minitest")
  expect_equal(displaceR:::default_input_name("/data/mycase"), "mycase")
})

test_that("run_displace does not impose a maximum step count", {
  ## This test previously asserted the opposite, which is how the bug survived:
  ## run_displace() rejected anything above 52586 steps. That figure comes from
  ## upstream's README describing a slider in the *GUI's* Setup menu; the
  ## headless simulator parses -i into a plain unvalidated int. Real case
  ## studies exceed it routinely -- a 10-year run is 87673 steps -- so the cap
  ## refused workloads DISPLACE runs perfectly well.
  r <- run_displace("/in", "case", steps = 87673, dry_run = TRUE,
                    validate = FALSE, binary = exit_binary("true"))
  expect_equal(r$steps, 87673L)
  ## Arguments are shell-quoted individually, so the pair reads '-i' '87673'.
  expect_match(r$command, "'-i'[[:space:]]*'87673'")

  ## Nonsense is still refused.
  expect_error(
    run_displace("/in", "case", steps = 0, dry_run = TRUE, validate = FALSE,
                 binary = exit_binary("true")),
    "positive integer"
  )
})

test_that("a dry run reports the command without needing a binary", {
  r <- run_displace("/data/in", "minitest", steps = 100, dry_run = TRUE,
                    validate = FALSE, binary = "/opt/displace/displace",
                    output_dir = "/tmp/o")

  expect_s3_class(r, "displace_run")
  expect_true(is.na(r$status))
  expect_match(r$command, "/opt/displace/displace")
  expect_match(r$command, "-f")
  expect_equal(r$output_path, "/tmp/o/DISPLACE_outputs/minitest/baseline")
  ## Path built in simulator/main.cpp:740 as <f>_<s>_out.db.
  expect_equal(basename(r$db_path), "minitest_sim1_out.db")
})

test_that("run_displace creates the output tree before launching", {
  ## The simulator is not consistently defensive about missing output paths.
  d <- tempfile()
  input <- tempfile()
  dir.create(input)
  suppressMessages(
    run_displace(input, "minitest", steps = 10, validate = FALSE,
                 output_dir = d, binary = exit_binary("true"), echo = FALSE)
  )
  expect_true(dir.exists(file.path(d, "DISPLACE_outputs", "minitest", "baseline")))
})

test_that("a non-zero exit status is an error carrying the command", {
  input <- tempfile()
  dir.create(input)
  expect_error(
    run_displace(input, "minitest", steps = 10, validate = FALSE,
                 output_dir = tempfile(), binary = exit_binary("false"), echo = FALSE),
    "DISPLACE exited with status"
  )
})

test_that("a missing input_dir is caught before anything is launched", {
  expect_error(
    run_displace("/no/such/input", "minitest", steps = 10, validate = FALSE,
                 binary = exit_binary("true")),
    "input_dir does not exist"
  )
})
