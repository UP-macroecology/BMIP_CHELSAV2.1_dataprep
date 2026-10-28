# ============================================================================= #
## List of excluded (faulty) days and affected months for the data documentation
#
# Usage:  Rscript make_excluded_days_list.R <qc_dir> <out_dir>
#   qc_dir : folder with flagged_days.csv and months_not_regular.csv
#            (written by summarize_year_qc.R from the qc_days_*/qc_months_* tables)
#   out_dir: writes excluded_days_list.csv and affected_months_list.csv there
#
# Only years 1941-2024 are listed (2025 is not part of the delivered data).
# ============================================================================= #
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly = TRUE)
qc_dir <- args[1]; out_dir <- args[2]
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

reason_text <- c(
  download_failed      = "file not available on the CHELSA server (download failed after 3 tries)",
  checksum_error       = "checksum of the downloaded file does not match the server",
  size_mismatch        = "file size does not match the server",
  read_error           = "file cannot be read",
  all_NA               = "all cells NA",
  out_of_range         = "values outside the plausible range of the variable",
  too_many_NA          = "NA fraction clearly above that of the other days of the year",
  constant_file        = "all cells have the same value",
  implausible_max      = "global maximum implausibly low (source-data error)",
  implausible_low_mean = "global mean implausibly low compared with the other days (source-data error)"
)
explain <- function(r) vapply(strsplit(r, "+", fixed = TRUE), function(p)
  paste(ifelse(is.na(reason_text[p]), p, reason_text[p]), collapse = "; "), character(1))

fd <- fread(file.path(qc_dir, "flagged_days.csv"), colClasses = list(character = c("file", "date", "reason")))
# date from the file name if the column is empty: CHELSA_<var>_<DD>_<MM>_<YYYY>_V.2.1.tif
fix <- (is.na(fd$date) | fd$date == "") & grepl("_\\d{2}_\\d{2}_\\d{4}_V", fd$file)
fd[fix, date := sub(".*_(\\d{2})_(\\d{2})_(\\d{4})_V.*", "\\3-\\2-\\1", file)]
fd <- fd[year <= 2024]
out <- fd[order(variable, date), .(variable, date, year, reason_code = reason, reason = explain(reason),
                                   regions = "all (Australia, Europe, Finland, USA)",
                                   effect_daily_10km = "layer present but empty (all NA)",
                                   effect_monthly_1km = "day not used in the monthly value")]
fwrite(out, file.path(out_dir, "excluded_days_list.csv"))
cat("Excluded days (1941-2024):", nrow(out), "\n"); print(out[, .N, by = .(variable, reason_code)][order(variable, -N)])

mn <- fread(file.path(qc_dir, "months_not_regular.csv"))[year <= 2024]
action_text <- c(
  computed_from_remaining_days = "monthly value computed from the remaining days",
  NA_prec_incomplete           = "precipitation sum set to NA (days missing)",
  NA_no_valid_day              = "monthly value NA (no valid day)"
)
mn[, meaning := unname(action_text[monthly_action])]
mn[is.na(meaning), meaning := monthly_action]      # unknown action: keep the code
mn <- mn[order(variable, year, month), .(variable, year, month, n_days, n_flagged, n_good, monthly_action, meaning)]
fwrite(mn, file.path(out_dir, "affected_months_list.csv"))
cat("Affected months:", nrow(mn), "\n")