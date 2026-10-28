# ============================================================================= #
## QC summary of the variable x year pipeline
# Reads qc_days_*.csv / qc_months_*.csv (written by 01_process_year_task.R)
# and creates:
#   flagged_days.csv         : all flagged days (replaces skip_files)
#   months_not_regular.csv   : months with flagged days / NA months (mainly prec)
# ============================================================================= #
library(data.table)

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
qc_dir <- file.path(transfer_dir, "processing_scripts", "qc_year_tasks")
# Usage: Rscript summarize_year_qc.R [qc_dir]   (test runs write their QC into <test folder>/qc)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1 && nzchar(args[1])) qc_dir <- args[1]

rd <- function(pattern) {
  f <- list.files(qc_dir, pattern = pattern, full.names = TRUE)
  if (length(f) == 0) return(data.table())
  # text columns only where they exist (qc_months has no "date"/"reason" column)
  read1 <- function(p) {
    hdr <- names(fread(p, nrows = 0))
    fread(p, colClasses = list(character = intersect(c("file", "date", "reason", "last_modified", "etag"), hdr)))
  }
  rbindlist(lapply(f, read1), fill = TRUE)
}

# Some QC tables (e.g. hurs from the other cluster) have an empty "date" column: derive the date
# from the file name (CHELSA_<var>_<DD>_<MM>_<YYYY>_V.2.1.tif)
fill_date <- function(d) {
  if (nrow(d) == 0 || !all(c("date", "file") %in% names(d))) return(d)
  d[, date := as.character(date)]
  ok <- grepl("_\\d{2}_\\d{2}_\\d{4}_V", d$file)
  fix <- (is.na(d$date) | d$date == "") & ok
  d[fix, date := sub(".*_(\\d{2})_(\\d{2})_(\\d{4})_V.*", "\\3-\\2-\\1", file)]
  d
}

days   <- rd("^qc_days_.*\\.csv$")
days   <- fill_date(days)
months <- rd("^qc_months_.*\\.csv$")
cat("Daily files checked:", nrow(days), "| variable-year combinations:",
    uniqueN(days[, .(variable, year)]), "\n")

flagged <- days[status == "flagged"][order(variable, date)]
cat("Flagged days:", nrow(flagged), "\n")
if (nrow(flagged) > 0) {
  print(flagged[, .N, by = .(variable, reason)][order(-N)])
  fwrite(flagged, file.path(qc_dir, "flagged_days.csv"))
}

irregular <- months[monthly_action != "ok"][order(variable, year, month)]
cat("\nMonths with irregularities:", nrow(irregular), "\n")
if (nrow(irregular) > 0) {
  print(irregular[, .N, by = .(variable, monthly_action)])
  fwrite(irregular, file.path(qc_dir, "months_not_regular.csv"))
}

prec_na <- months[variable == "prec" & monthly_action == "NA_prec_incomplete"]
cat("\nprec months set to NA because of missing days:", nrow(prec_na), "\n")
cat("Output in:", qc_dir, "\n")
