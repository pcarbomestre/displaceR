## Both simusspe_ files (config.dat and the scenario .dat) are parsed by
## displace::formats::helpers::LineNumberReader (formats/utils/LineNumberReader.cpp).
##
## That reader does exactly one thing: it walks the file counting lines from 0,
## trims each line, and keeps the ones whose *line number* appears in a fixed
## specification. Nothing else is inspected. In particular:
##
##   - '#' is not a comment character. The even lines look like comments by
##     convention, but they are simply lines the specification does not name.
##   - blank lines count.
##   - a missing trailing line yields a missing key, not an error, and the
##     field silently takes its default.
##
## So these files are strictly positional: inserting or deleting one line
## shifts every field after it, and the simulator will load the shifted values
## without complaint. This is the most fragile input format in DISPLACE, which
## is why reading and writing it goes through one implementation here.

read_linenumber_file <- function(path, spec) {
  if (!file.exists(path)) {
    stopf("no such file: %s", path)
  }
  lines <- readLines(path, warn = FALSE)
  read_linenumber_lines(lines, spec)
}

read_linenumber_lines <- function(lines, spec) {
  ## spec is a named integer vector: names are field names, values are
  ## 0-indexed line numbers.
  idx <- unname(spec) + 1L        # R is 1-indexed
  vals <- rep(NA_character_, length(spec))
  present <- idx <= length(lines)
  vals[present] <- trim(lines[idx[present]])
  stats::setNames(as.list(vals), names(spec))
}

## Render a positional file: value lines at the spec's line numbers, comment
## lines everywhere else. `comments` is a named character vector giving the
## comment text for each field; the comment goes on the line immediately above.
write_linenumber_file <- function(path, spec, values, comments = character()) {
  n <- max(unname(spec)) + 1L
  lines <- rep("", n)
  for (field in names(spec)) {
    ln <- spec[[field]] + 1L
    v <- values[[field]]
    lines[ln] <- if (is.null(v) || (length(v) == 1L && is.na(v))) "" else as.character(v)
    if (ln > 1L) {
      label <- if (field %in% names(comments)) comments[[field]] else field
      lines[ln - 1L] <- paste0("# ", label)
    }
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, path)
  invisible(path)
}
