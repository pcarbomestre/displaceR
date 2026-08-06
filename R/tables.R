## The keyed-table format.
##
## A large share of DISPLACE's input files are the same shape: a header line
## that the loader discards, then whitespace-separated columns. Upstream reads
## them through nine near-identical helpers in commons/myutils.cpp --
## fill_map_from_specifications_i_d, fill_multimap_from_specifications_s_i and
## so on -- which differ only in the types of the two columns and in whether
## repeated keys are kept.
##
## Every one of them begins with
##
##     std::string dummystring;
##     getline(in, dummystring);   // eat the heading
##
## so the header line's *content* is never parsed. It has to be present -- the
## first line is unconditionally thrown away, so a file without one silently
## loses its first record -- but what it says does not matter. Writers should
## still emit the conventional name so the files stay readable by humans and by
## upstream's R routines.
##
## Handling this as one format rather than nine covers vesselsspe_fgrounds,
## vesselsspe_harbours, the freq_ variants, names_harbours, and many more with
## a single reader and writer.

#' Read a keyed DISPLACE input table
#'
#' Reads the whitespace-separated, one-header-line format used by many of
#' DISPLACE's per-vessel, per-metier and per-harbour input files -- for example
#' `vesselsspe_fgrounds_quarter1.dat`, `vesselsspe_harbours_quarter3.dat` or
#' `names_harbours.dat`.
#'
#' For those files the first line is a header that the simulator reads and
#' discards without parsing, so its content is arbitrary. It must be present:
#' the loader always consumes one line before it starts reading records.
#'
#' @section This format is not universal:
#'
#' DISPLACE's input tree mixes several shapes, and applying this one blindly
#' corrupts files. Two failure modes are common enough that this function
#' refuses rather than guesses:
#'
#' * **No header.** Files such as `popsspe_*/0spe_initial_tac.dat` are bare
#'   records with no header line. Reading one with `header = TRUE` silently
#'   discards its first row. Any first line that is entirely numeric is
#'   rejected with a message telling you to pass `header = FALSE`.
#' * **`|` separated.** `shipsspe_features.dat` and `firms_specs.dat` use
#'   pipes. Reading them as whitespace yields a single mangled column and no
#'   error, so that is rejected too.
#'
#' Round-tripping a whole case study through this function has been checked
#' against `DISPLACE_input_minitest` by rewriting each family and re-running
#' the simulator. `harboursspe_`, `benthosspe_`, `fishfarmsspe_`,
#' `windmillsspe_`, `metiersspe_` and `popsspe_` reproduce byte-identical
#' outputs. `vesselsspe_` and `shipsspe_` do not yet, so treat writes there as
#' unverified and check them with [check_displace_roundtrip()].
#'
#' @param path Path to the file.
#' @param col_names Names for the resulting columns. Defaults to the header
#'   line's own fields when it has the right number of them, and to
#'   `V1`, `V2`, ... otherwise. Note that this is a convenience for the R side
#'   only -- the simulator never looks at the header.
#' @param col_types Optional character vector, one entry per column, each of
#'   `"i"` (integer), `"d"` (double) or `"c"` (character). Defaults to letting
#'   R infer them.
#' @param sep Field separator. `"whitespace"` (the default) covers most of
#'   DISPLACE's input files. A few, such as `firms_specs.dat` and the vessel
#'   features files, use `"|"` instead. Reading a `|`-separated file as
#'   whitespace is an error rather than a silent one-column result.
#' @param header Whether the file starts with a header line the simulator
#'   discards. True for the `fill_*_from_specifications_*` family; false for the
#'   handful of files read without one.
#'
#' @return A data frame. Zero rows if the file is empty or holds only a header.
#' @export
#' @examples
#' f <- tempfile()
#' writeLines(c("vid idx_nodes", "DNK001 1", "DNK001 2", "DNK002 5"), f)
#' read_displace_table(f)
read_displace_table <- function(path, col_names = NULL, col_types = NULL,
                                sep = c("whitespace", "|"), header = TRUE) {
  sep <- match.arg(sep)
  if (!file.exists(path)) {
    stopf("no such file: %s", path)
  }
  lines <- readLines(path, warn = FALSE)
  lines <- lines[!is.na(lines)]

  ## An empty file is legitimate -- an unused metier_closure_* month, say --
  ## and the simulator reads it as "no records". Return that shape rather than
  ## erroring, so callers can loop over a whole case study.
  if (!length(lines) || !any(nzchar(trim(lines)))) {
    return(empty_table(col_names))
  }

  split_re <- if (identical(sep, "|")) "\\|" else "[[:space:]]+"

  if (header) {
    header_line <- trim(lines[1])
    body <- lines[-1]
  } else {
    header_line <- ""
    body <- lines
  }
  body <- body[nzchar(trim(body))]

  header_fields <- if (nzchar(header_line)) {
    strsplit(header_line, split_re)[[1]]
  } else {
    character(0)
  }

  ## Reading a pipe-separated file as whitespace yields one mangled column and
  ## no error, which is the worst possible outcome. Refuse instead.
  if (identical(sep, "whitespace") && length(body) &&
      grepl("|", body[1], fixed = TRUE)) {
    stopf(paste0("%s looks '|'-separated, not whitespace-separated: its first ",
                 "record is\n  %s\nPass sep = \"|\"."),
          basename(path), trim(body[1]))
  }

  ## Many DISPLACE input files have no header at all -- popsspe_/0spe_initial_tac.dat
  ## is a single bare number. Reading one of those with header = TRUE silently
  ## eats the first record and, if it was the only one, produces a table whose
  ## column name is the lost value. That is a corruption that a round trip would
  ## write straight back out, so refuse rather than guess.
  if (header && length(header_fields) &&
      all(!is.na(suppressWarnings(as.numeric(header_fields))))) {
    stopf(paste0("%s has no header: its first line (\"%s\") is all numbers, so ",
                 "it is a record, not column names.\nReading it as a header ",
                 "would silently discard that row. Pass header = FALSE."),
          basename(path), header_line)
  }

  if (!length(body)) {
    ## A header and nothing else is legitimate -- an empty fishing-ground list,
    ## say. Return the right shape rather than erroring.
    return(empty_table(col_names %||% header_fields))
  }

  ncol_body <- length(strsplit(trim(body[1]), split_re)[[1]])

  nm <- col_names
  if (is.null(nm)) {
    ## Only trust the header for names when it has one field per column; some
    ## files carry a descriptive sentence rather than column names.
    nm <- if (length(header_fields) == ncol_body) {
      header_fields
    } else {
      paste0("V", seq_len(ncol_body))
    }
  }
  if (length(nm) != ncol_body) {
    stopf("%s has %d columns but %d column names were given: %s",
          basename(path), ncol_body, length(nm), paste(nm, collapse = ", "))
  }

  colClasses <- NA
  if (!is.null(col_types)) {
    if (length(col_types) != ncol_body) {
      stopf("col_types has %d entries but %s has %d columns",
            length(col_types), basename(path), ncol_body)
    }
    colClasses <- unname(
      c(i = "integer", d = "numeric", c = "character")[col_types]
    )
    if (anyNA(colClasses)) {
      stopf("col_types entries must each be one of \"i\", \"d\" or \"c\".")
    }
  }

  utils::read.table(
    text = body, header = FALSE,
    sep = if (identical(sep, "|")) "|" else "",
    col.names = nm,
    colClasses = colClasses, comment.char = "", stringsAsFactors = FALSE
  )
}

empty_table <- function(nm) {
  nm <- nm %||% character(0)
  as.data.frame(
    stats::setNames(rep(list(character(0)), length(nm)), nm),
    stringsAsFactors = FALSE
  )
}

#' Write a keyed DISPLACE input table
#'
#' Writes the header-plus-records format described in [read_displace_table()].
#'
#' The header line is emitted from `header` or, failing that, from the data
#' frame's column names. The simulator discards it unparsed, but it must be
#' there: without it the first record would be eaten instead.
#'
#' @param x A data frame.
#' @param path Path to write to. Parent directories are created.
#' @param header Header line text, or `NULL` for the column names space
#'   separated, which is what upstream's own files carry. `NA` writes no header
#'   at all, for the few files read without one.
#' @param sep Field separator, as in [read_displace_table()].
#'
#' @return `path`, invisibly.
#' @export
#' @examples
#' fg <- data.frame(vid = c("DNK001", "DNK001"), idx_nodes = c(1L, 2L))
#' write_displace_table(fg, tempfile())
write_displace_table <- function(x, path, header = NULL,
                                 sep = c("whitespace", "|")) {
  sep <- match.arg(sep)
  if (!is.data.frame(x)) {
    stopf("x must be a data frame.")
  }
  if (identical(sep, "whitespace")) {
    ## A value containing whitespace would be read back as two columns.
    for (col in names(x)) {
      if (is.character(x[[col]]) && any(grepl("[[:space:]]", x[[col]]))) {
        stopf(paste0("column '%s' contains whitespace inside a value, which ",
                     "would be read back as extra columns. Remove it, or write ",
                     "with sep = \"|\"."), col)
      }
    }
  }

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)

  ## A table with neither rows nor columns came from an empty file, and must go
  ## back as one. Writing a header into it would turn a legitimately empty
  ## closure file into a one-line file, which is a real corruption -- the
  ## simulator would then read that line as a record.
  if (nrow(x) == 0L && ncol(x) == 0L) {
    file.create(path)
    return(invisible(path))
  }

  con <- file(path, "w")
  on.exit(close(con), add = TRUE)

  if (!identical(header, NA) && !identical(header, NA_character_)) {
    writeLines(header %||% paste(names(x), collapse = " "), con)
  }
  if (nrow(x)) {
    fmt <- lapply(x, function(col) {
      if (is.numeric(col)) fmt_num(col) else as.character(col)
    })
    joiner <- if (identical(sep, "|")) {
      function(...) paste(..., sep = "|")
    } else {
      paste
    }
    writeLines(do.call(joiner, fmt), con)
  }
  invisible(path)
}

## vesselsspe_features_quarter*.dat
##
## The one common input file that is not whitespace separated: 22 '|'-separated
## fields per vessel, no header. Read by fill_from_vessels_specifications()
## (commons/myutils.cpp:1363), a hand-rolled parser that requires at least 22
## fields and reads indices 0..21.
##
## Field names and types come from the order in which that function assigns
## them. Note the calendar block sits at 16-19, *before* firm_id at 20 -- the
## natural guess of firm_id first is wrong, and would silently swap a firm
## identifier for a weekday number.
VESSEL_FEATURE_COLS <- c(
  "VE_REF",                       # 0
  "is_active",                    # 1
  "speed",                        # 2
  "fuelcons",                     # 3
  "length",                       # 4
  "vKW",                          # 5
  "carrycapacity",                # 6
  "tankcapacity",                 # 7
  "nbfpingspertrip",              # 8
  "resttime_par1",                # 9
  "resttime_par2",                # 10
  "av_trip_duration",             # 11
  "mult_fuelcons_when_steaming",  # 12
  "mult_fuelcons_when_fishing",   # 13
  "mult_fuelcons_when_returning", # 14
  "mult_fuelcons_when_inactive",  # 15
  "weekEndStartDay",              # 16  } VesselCalendar
  "weekEndEndDay",                # 17  }
  "workStartHour",                # 18  }
  "workEndHour",                  # 19  }
  "firm_id",                      # 20
  "is_part_of_ref_fleet"          # 21
)

## Fields the parser reads with get_int() rather than get_double().
VESSEL_FEATURE_INT_COLS <- c(
  "is_active", "weekEndStartDay", "weekEndEndDay", "workStartHour",
  "workEndHour", "firm_id", "is_part_of_ref_fleet"
)

#' Read a DISPLACE vessel features file
#'
#' Reads `vesselsspe_<name>/vesselsspe_features_quarter<q>.dat`, the one
#' commonly edited input file that is `|`-separated rather than whitespace
#' separated, and which carries no header line.
#'
#' The simulator requires at least 22 fields per line and reads exactly the
#' first 22. A file with fewer is rejected at load time; a file with more has
#' the extras ignored.
#'
#' @param input_dir Folder containing the `vesselsspe_*` subfolder.
#' @param input_name Parameterisation name.
#' @param quarter Quarter, 1 to 4.
#' @param path Read this exact file instead.
#'
#' @return A data frame with one row per vessel and 22 named columns.
#' @export
#' @examples
#' f <- tempfile()
#' writeLines("DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|1|1", f)
#' read_displace_vessel_features(path = f)
read_displace_vessel_features <- function(input_dir = NULL, input_name = NULL,
                                          quarter = 1L, path = NULL) {
  path <- path %||% vesselsspe_file(
    input_dir, input_name, sprintf("vesselsspe_features_quarter%d.dat", quarter)
  )
  if (!file.exists(path)) {
    stopf("no such file: %s", path)
  }
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(trim(lines))]
  if (!length(lines)) {
    stopf("%s has no vessel records.", path)
  }

  n_expected <- length(VESSEL_FEATURE_COLS)
  widths <- vapply(strsplit(lines, "|", fixed = TRUE), length, integer(1))
  short <- which(widths < n_expected)
  if (length(short)) {
    stopf(paste0("%s line %d has %d '|'-separated fields; the simulator requires ",
                 "at least %d and rejects the file otherwise."),
          basename(path), short[1], widths[short[1]], n_expected)
  }
  if (any(widths > n_expected)) {
    warnf(paste0("%s has lines with more than %d fields; the simulator reads ",
                 "only the first %d and ignores the rest."),
          basename(path), n_expected, n_expected)
  }

  df <- utils::read.table(text = lines, sep = "|", header = FALSE,
                          colClasses = "character", comment.char = "",
                          stringsAsFactors = FALSE)
  df <- df[, seq_len(n_expected), drop = FALSE]
  names(df) <- VESSEL_FEATURE_COLS

  ## Everything but the vessel identifier is numeric; the fields the parser
  ## reads with get_int() come back as integers so a round trip does not turn
  ## a firm id into "4.0".
  for (col in setdiff(VESSEL_FEATURE_COLS, "VE_REF")) {
    v <- as.numeric(trim(df[[col]]))
    df[[col]] <- if (col %in% VESSEL_FEATURE_INT_COLS) as.integer(v) else v
  }
  df$VE_REF <- trim(df$VE_REF)
  df
}

#' Write a DISPLACE vessel features file
#'
#' @param x A data frame with the columns [read_displace_vessel_features()]
#'   returns. Extra columns are an error rather than being silently dropped,
#'   since a mis-ordered file would load and give wrong answers.
#' @param input_dir,input_name,quarter Destination, as in
#'   [read_displace_vessel_features()].
#' @param path Write to this exact file instead.
#'
#' @return `path`, invisibly.
#' @export
#' @examples
#' f <- tempfile()
#' writeLines("DNK001|1|10|100|15|150|1000|20000|3|1|60|12|1|1.1|1.1|0.2|4|6|4|22|1|1", f)
#' v <- read_displace_vessel_features(path = f)
#' v$speed <- v$speed * 1.1
#' write_displace_vessel_features(v, path = tempfile())
write_displace_vessel_features <- function(x, input_dir = NULL,
                                           input_name = NULL, quarter = 1L,
                                           path = NULL) {
  if (!is.data.frame(x)) {
    stopf("x must be a data frame.")
  }
  missing_cols <- setdiff(VESSEL_FEATURE_COLS, names(x))
  if (length(missing_cols)) {
    stopf("missing column(s): %s", paste(missing_cols, collapse = ", "))
  }
  path <- path %||% vesselsspe_file(
    input_dir, input_name, sprintf("vesselsspe_features_quarter%d.dat", quarter)
  )

  ## Reorder to the layout the parser reads positionally, and drop anything
  ## extra: the file has no header, so column order is the whole contract.
  x <- x[, VESSEL_FEATURE_COLS, drop = FALSE]

  fields <- lapply(x, function(col) {
    if (is.numeric(col)) fmt_num(col) else as.character(col)
  })
  lines <- do.call(function(...) paste(..., sep = "|"), fields)

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, path)
  invisible(path)
}

vesselsspe_file <- function(input_dir, input_name, file) {
  if (is.null(input_dir) || is.null(input_name)) {
    stopf("supply either `path`, or both `input_dir` and `input_name`.")
  }
  file.path(input_dir, paste0("vesselsspe_", input_name), file)
}
