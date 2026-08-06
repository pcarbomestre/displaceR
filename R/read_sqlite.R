## SQLite output reader.
##
## This is the preferred path. The text outputs are whitespace-separated files
## with no headers and, in loglike's case, a column count that depends on the
## number of populations; the database is typed, indexed, and carries a schema
## version.
##
## Table names from SQLiteOutputStorage::SQLiteOutputStorage(),
## commons/storage/sqliteoutputstorage.cpp:74-91.
## CURRENT_DB_SCHEMA_VERSION = 4, written to Metadata under the key 'dbVersion'
## (same file, :35 and :1121). That key, not the DISPLACE version string, is the
## right thing to dispatch a reader on.

#' Known DISPLACE output database tables
#'
#' The table names created by `SQLiteOutputStorage`, as of output schema
#' version 4. Use [displace_db_tables()] to see what a particular database
#' actually contains.
#'
#' @format A character vector.
#' @rdname displace_db_table_names
#' @export
#' @examples
#' DISPLACE_DB_TABLES
DISPLACE_DB_TABLES <- c(
  "Metadata", "VesselDef", "VesselLogLike", "VesselLogLikeCatches",
  "VesselVmsLike", "VesselVmsFPingsOnlyLike", "Ships", "NodesDef",
  "NodesEnvt", "NodesStat", "NodesTariffStat", "PopDyn", "PopQuotas",
  "PopValues", "FuncGroups", "FishFarmsDef", "Fishfarms", "Windmills"
)

## Highest schema version this package has been checked against.
SUPPORTED_DB_SCHEMA_VERSION <- 4L

resolve_db_path <- function(x) {
  if (inherits(x, "displace_run")) {
    return(x$db_path)
  }
  if (is.character(x) && length(x) == 1L) {
    if (dir.exists(x)) {
      ## A run's output directory: find the single *_out.db inside it.
      hits <- list.files(x, pattern = "_out\\.db$", full.names = TRUE,
                         recursive = TRUE)
      if (!length(hits)) {
        stopf("no *_out.db found under %s", x)
      }
      if (length(hits) > 1L) {
        stopf("several output databases under %s:\n%s\nPass one explicitly.",
              x, paste0("  ", hits, collapse = "\n"))
      }
      return(hits)
    }
    return(x)
  }
  stopf("expected a displace_run, a database path, or an output directory.")
}

db_connect <- function(path) {
  need_pkg("DBI", "Reading DISPLACE SQLite output")
  need_pkg("RSQLite", "Reading DISPLACE SQLite output")
  if (!file.exists(path)) {
    stopf(paste0("no such database: %s\nIf the run used sqlite = FALSE, read the ",
                 "text outputs with read_displace_output() instead."), path)
  }
  DBI::dbConnect(RSQLite::SQLite(), path, flags = RSQLite::SQLITE_RO)
}

#' Metadata of a DISPLACE output database
#'
#' Reads the `Metadata` table, which holds the schema version among other keys.
#'
#' @param x A `displace_run`, a path to a `*_out.db`, or a run output directory.
#' @return A named character vector of metadata keys.
#' @export
#' @examples
#' \dontrun{
#' displace_db_metadata(res)
#' }
displace_db_metadata <- function(x) {
  path <- resolve_db_path(x)
  con <- db_connect(path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  if (!DBI::dbExistsTable(con, "Metadata")) {
    return(character(0))
  }
  m <- DBI::dbReadTable(con, "Metadata")
  ## Column naming has varied; take the first two columns positionally.
  stats::setNames(as.character(m[[2]]), as.character(m[[1]]))
}

#' Schema version of a DISPLACE output database
#'
#' Returns the integer stored under `dbVersion` in the `Metadata` table. This
#' is the correct key for version-aware readers: unlike the DISPLACE version
#' string, which is a hardcoded `#define` shared across many commits, it changes
#' when the output schema changes.
#'
#' @param x A `displace_run`, a database path, or an output directory.
#' @return An integer, or `NA_integer_` if the database predates the key.
#' @export
#' @examples
#' \dontrun{
#' displace_db_version(res)
#' }
displace_db_version <- function(x) {
  md <- displace_db_metadata(x)
  if (!"dbVersion" %in% names(md)) {
    return(NA_integer_)
  }
  as.integer(md[["dbVersion"]])
}

#' Tables in a DISPLACE output database
#'
#' @param x A `displace_run`, a database path, or an output directory.
#' @param all Include tables not in the known DISPLACE set (indices, anything a
#'   newer upstream added).
#' @return A data frame with `table` and `rows`.
#' @export
#' @examples
#' \dontrun{
#' displace_db_tables(res)
#' }
displace_db_tables <- function(x, all = FALSE) {
  path <- resolve_db_path(x)
  con <- db_connect(path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tabs <- DBI::dbListTables(con)
  if (!all) {
    tabs <- intersect(tabs, DISPLACE_DB_TABLES)
  }
  if (!length(tabs)) {
    return(data.frame(table = character(0), rows = integer(0),
                      stringsAsFactors = FALSE))
  }
  rows <- vapply(tabs, function(t) {
    as.integer(DBI::dbGetQuery(
      con, sprintf("SELECT COUNT(*) AS n FROM %s", DBI::dbQuoteIdentifier(con, t))
    )$n)
  }, integer(1))
  data.frame(table = tabs, rows = unname(rows), stringsAsFactors = FALSE)
}

#' Read a table from a DISPLACE output database
#'
#' @param x A `displace_run`, a path to a `*_out.db`, or a run output directory.
#' @param table Table name. See [DISPLACE_DB_TABLES] for the known set, or call
#'   [displace_db_tables()] on an actual database.
#' @param where Optional SQL `WHERE` clause, without the keyword. Use this
#'   rather than reading everything and subsetting in R: `VesselVmsLike` on a
#'   multi-year run has tens of millions of rows.
#' @param limit Optional row limit.
#' @param check_version Warn if the database's schema version is newer than the
#'   one this package was checked against.
#'
#' @return A data frame.
#' @export
#' @examples
#' \dontrun{
#' read_displace_db(res, "VesselLogLike", where = "tstep < 1000")
#' }
read_displace_db <- function(x, table, where = NULL, limit = NULL,
                             check_version = TRUE) {
  path <- resolve_db_path(x)
  con <- db_connect(path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  if (isTRUE(check_version)) {
    v <- tryCatch({
      md <- DBI::dbReadTable(con, "Metadata")
      hit <- which(as.character(md[[1]]) == "dbVersion")
      if (length(hit)) as.integer(md[[2]][hit[1]]) else NA_integer_
    }, error = function(e) NA_integer_)
    if (!is.na(v) && v > SUPPORTED_DB_SCHEMA_VERSION) {
      warnf(paste0("this database uses output schema version %d; displaceR has ",
                   "been checked against version %d. Column names or types may ",
                   "have changed upstream."),
            v, SUPPORTED_DB_SCHEMA_VERSION)
    }
  }

  if (!DBI::dbExistsTable(con, table)) {
    stopf("no table '%s' in %s.\nTables present: %s",
          table, path, paste(DBI::dbListTables(con), collapse = ", "))
  }

  sql <- sprintf("SELECT * FROM %s", DBI::dbQuoteIdentifier(con, table))
  if (!is.null(where)) {
    sql <- paste(sql, "WHERE", where)
  }
  if (!is.null(limit)) {
    sql <- paste(sql, "LIMIT", as.integer(limit))
  }
  DBI::dbGetQuery(con, sql)
}

#' Run arbitrary SQL against a DISPLACE output database
#'
#' The escape hatch for aggregation the helpers do not cover. Aggregating in
#' SQL is usually much faster than pulling a whole table into R.
#'
#' @param x A `displace_run`, a database path, or an output directory.
#' @param sql A `SELECT` statement. The connection is read-only, so anything
#'   that writes will fail.
#' @return A data frame.
#' @export
#' @examples
#' \dontrun{
#' displace_db_query(res, "
#'   SELECT tstep, SUM(catches) AS total
#'   FROM VesselLogLikeCatches GROUP BY tstep ORDER BY tstep
#' ")
#' }
displace_db_query <- function(x, sql) {
  path <- resolve_db_path(x)
  con <- db_connect(path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbGetQuery(con, sql)
}
