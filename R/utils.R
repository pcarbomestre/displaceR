## Small internal helpers. Nothing exported from this file.

`%||%` <- function(x, y) if (is.null(x)) y else x

stopf <- function(fmt, ...) {
  stop(sprintf(fmt, ...), call. = FALSE)
}

warnf <- function(fmt, ...) {
  warning(sprintf(fmt, ...), call. = FALSE)
}

msgf <- function(fmt, ...) {
  message(sprintf(fmt, ...))
}

need_pkg <- function(pkg, what) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stopf("%s requires the '%s' package. Install it with install.packages(\"%s\").",
          what, pkg, pkg)
  }
  invisible(TRUE)
}

## Trim in the same way boost::trim does: both ends, whitespace only.
trim <- function(x) sub("[[:space:]]+$", "", sub("^[[:space:]]+", "", x))

## A field whose line is past the end of the file reads as NA. Upstream's
## reader never sets the key in that case and the field takes its default, so
## every string field treats a missing line as "".
trim_or_empty <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) "" else trim(x)
}

## DISPLACE's stringToVector<T>(s, " ") on an empty or whitespace-only string
## yields an empty vector; on a normal string it splits on runs of spaces.
split_nums <- function(x, what = "numeric") {
  ## NA arrives when the field's line is past the end of the file. Upstream's
  ## reader simply never sets the key and the field takes its default, which for
  ## every vector field is "empty".
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(if (what == "integer") integer(0) else numeric(0))
  }
  x <- trim(x)
  if (!nzchar(x)) {
    return(if (what == "integer") integer(0) else numeric(0))
  }
  parts <- strsplit(x, "[[:space:]]+")[[1]]
  parts <- parts[nzchar(parts)]
  if (!length(parts)) {
    return(if (what == "integer") integer(0) else numeric(0))
  }
  out <- suppressWarnings(as.numeric(parts))
  if (anyNA(out)) {
    stopf("cannot parse as %s: %s", what, paste(parts[is.na(out)], collapse = ", "))
  }
  if (what == "integer") as.integer(out) else out
}

## The inverse: how DISPLACE expects a vector written back out.
join_nums <- function(x) paste(format(x, trim = TRUE, scientific = FALSE), collapse = " ")

## Format a numeric for a one-value-per-line .dat file. DISPLACE parses these
## with boost::lexical_cast<double>, which rejects the scientific notation R
## produces for very small or very large values in some locales, so pin the
## format explicitly.
fmt_num <- function(x) {
  format(x, trim = TRUE, scientific = FALSE, digits = 15)
}

is_abs_path <- function(p) {
  grepl("^(/|[A-Za-z]:[\\/])", p)
}

## Compare dotted version-ish strings (glibc "2.35" etc.) safely.
ver_gte <- function(a, b) {
  utils::compareVersion(a, b) >= 0
}

## Ascending sort of version-ish strings. utils::compareVersion is the only
## base facility that handles "2.9" < "2.35" correctly for these.
sort_versions <- function(v) {
  if (length(v) < 2L) {
    return(v)
  }
  ord <- order(vapply(v, function(x) {
    ## Rank by number of strictly-smaller elements: an O(n^2) sort, but n is
    ## the number of glibc targets, i.e. two or three.
    sum(vapply(v, function(y) utils::compareVersion(y, x) < 0, logical(1)))
  }, numeric(1)))
  v[ord]
}

host_glibc <- function() {
  ## Only meaningful on glibc Linux. Returns NA elsewhere; callers treat NA as
  ## "cannot tell, do not filter".
  if (Sys.info()[["sysname"]] != "Linux") {
    return(NA_character_)
  }
  out <- tryCatch(
    suppressWarnings(system2("ldd", "--version", stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0)
  )
  if (!length(out)) {
    return(NA_character_)
  }
  m <- regmatches(out[1], regexpr("[0-9]+\\.[0-9]+$", out[1]))
  if (!length(m)) NA_character_ else m
}
