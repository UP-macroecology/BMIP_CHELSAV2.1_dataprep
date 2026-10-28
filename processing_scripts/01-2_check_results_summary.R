# ============================================================================= #
## Result check, step 2: plausibility checks on the statistics of step 1
#
# Usage:  Rscript 01-2_check_results_summary.R <results_dir> <stats_dir> [qc_dir] [newer_than] [stats_dir_old]
#   results_dir : the same folder as in step 1 (used for stray-file checks)
#   stats_dir   : folder with files_*.csv / layers_*.csv from 01-1_check_results_stats.R
#   qc_dir      : (optional) QC folder of the run (qc_days_*.csv, qc_months_*.csv); enables the
#                 cross-check of flagged days against empty layers
#   newer_than  : (optional) date "YYYY-MM-DD"; files with an older modification time are listed
#   stats_dir_old : (optional) statistics (01-1_check_results_stats.R) of the existing results (the old
#                 GEOBON_results). If given, the checks run on the FINAL state: all files of
#                 stats_dir (new) plus the files of stats_dir_old whose region/method/variable/year
#                 are not in stats_dir. Use this if the new folder only contains the updated files,
#                 otherwise "missing_files" lists everything that was not recomputed.
#
# Output: <stats_dir>/report/*.csv (one file per finding, only written if there are findings)
# and check_summary.csv. Thresholds are set in the parameter block and can be changed
# without re-reading any raster.
# ============================================================================= #

suppressPackageStartupMessages(library(data.table))

args        <- commandArgs(trailingOnly = TRUE)
results_dir <- args[1]
stats_dir   <- args[2]
qc_dir      <- if (length(args) >= 3 && nzchar(args[3])) args[3] else NA_character_
newer_than  <- if (length(args) >= 4 && nzchar(args[4])) as.Date(args[4]) else NA

## PARAMETERS ----------------------------------------------------------------------------
years    <- 1941:2024
regions  <- c("Australia", "Europe", "USA", "Finland")
methods  <- c("monthly_1km", "daily_10km")
# Variables to check; override with the environment variable CHECK_VARS, e.g. CHECK_VARS=hurs
vars     <- strsplit(Sys.getenv("CHECK_VARS", "prec,tas,tasmin,tasmax,rsds"), ",")[[1]]
ranges   <- list(tas = c(180, 345), tasmin = c(180, 345), tasmax = c(180, 345),
                 rsds = c(0, 1000), prec = c(0, Inf), hurs = c(0, 100))
temp_order_tol <- 0.5      # K: tasmin <= tas <= tasmax must hold for regional means
cons_tol_abs   <- c(tas = 1, tasmin = 1, tasmax = 1, rsds = 15, hurs = 5)  # monthly (1 km) vs mean of daily (10 km)
cons_tol_rel_prec <- 0.10  # prec: relative tolerance of the monthly sum vs the sum of daily means
z_month        <- 8        # robust z-score for monthly regional means vs the same calendar month in other years
z_jump         <- 10       # robust z-score for day-to-day jumps of regional daily means
size_ratio     <- c(0.5, 2)
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
task_dir     <- file.path(transfer_dir, "processing_scripts", "array_prep_year")

## LOAD ----------------------------------------------------------------------------------------
report_dir <- file.path(stats_dir, "report"); dir.create(report_dir, showWarnings = FALSE)
stats_dir_old <- if (length(args) >= 5 && nzchar(args[5])) args[5] else NA_character_
load_stats <- function(d) {
  if (length(list.files(d, "^files_.*\\.csv$")) == 0) stop("no files_*.csv found in '", d, "' - check the path / the shell variable")
  f <- rbindlist(lapply(list.files(d, "^files_.*\\.csv$", full.names = TRUE), fread), fill = TRUE)
  l <- rbindlist(lapply(list.files(d, "^layers_.*\\.csv$", full.names = TRUE), fread,
                        colClasses = list(character = c("name", "time"))), fill = TRUE)
  f[, year := as.integer(year)]; l[, year := as.integer(year)]
  list(files = f, layers = l)
}
new <- load_stats(stats_dir)
files <- new$files; layers <- new$layers
stopifnot(nrow(files) > 0)
key_cols <- c("region", "method", "variable", "year")
if (anyDuplicated(files, by = key_cols) > 0) {
  stop(sum(duplicated(files, by = key_cols)), " files appear more than once in ", stats_dir,
       ". The statistics are inconsistent (chunks computed from different file lists, or the ",
       "folder changed while the array was running). Create <stats_dir>/filelist.txt and rerun the ",
       "statistics into a NEW folder (see 01-1_check_results_stats.R).")
}
files[, source := "new"]; layers[, source := "new"]
if (!is.na(stats_dir_old)) {
  old <- load_stats(stats_dir_old)
  if (anyDuplicated(old$files, by = key_cols) > 0) stop("duplicate files in ", stats_dir_old)
  key <- c("region", "method", "variable", "year")
  keep_old <- fsetdiff(unique(old$files[, ..key]), unique(files[, ..key]))
  cat("Files from the new results:", nrow(unique(files[, ..key])),
      "| taken from the old results (not recomputed):", nrow(keep_old), "\n")
  files  <- rbind(files,  old$files[keep_old, on = key][, source := "old"], fill = TRUE)
  layers <- rbind(layers, old$layers[keep_old, on = key][, source := "old"], fill = TRUE)
}
fwrite(unique(files[, .(region, method, variable, year, source)]), file.path(report_dir, "source_table.csv"))
cat("Files:", nrow(files), "| layers:", nrow(layers), "\n\n")

summary_rows <- list()
finding <- function(name, dt, note = "") {
  n <- if (is.null(dt)) 0L else nrow(dt)
  f_out <- file.path(report_dir, paste0(name, ".csv"))
  if (file.exists(f_out)) file.remove(f_out)          # remove stale reports of earlier runs
  if (n > 0) fwrite(dt, f_out)
  summary_rows[[length(summary_rows) + 1]] <<- data.table(check = name, n_findings = n, note = note)
  cat(sprintf("%-38s %8d %s\n", name, n, if (n > 0) "<-- see report" else "ok"))
}
is_leap <- function(y) (y %% 4 == 0 & y %% 100 != 0) | y %% 400 == 0

## MASK INFO (extent, resolution, number of NA cells of the mask) ----------------
meta <- readRDS(file.path(task_dir, "region_masks_meta.rds"))
mask_info <- rbindlist(lapply(regions, function(r) rbindlist(lapply(methods, function(me) {
  m <- terra::rast(meta[[r]][[if (me == "monthly_1km") "1km" else "10km"]]$laea)
  e <- as.vector(terra::ext(m))
  data.table(region = r, method = me, m_ncell = terra::ncell(m), n_na_mask = terra::global(m, "isNA")[[1]],
             m_xmin = e[["xmin"]], m_xmax = e[["xmax"]], m_ymin = e[["ymin"]], m_ymax = e[["ymax"]],
             m_resx = terra::res(m)[1], m_resy = terra::res(m)[2])
}))))

cat("CHECK                                  FINDINGS\n")

## 1. completeness ----------------------------------------------------------------------------
expected <- CJ(region = regions, method = methods, variable = vars, year = years)
found <- unique(files[, .(region, method, variable, year)])
finding("missing_files", fsetdiff(expected, found), "region x method x variable x year without a file")
finding("unreadable_files", files[read_ok == FALSE, .(path, error)])

## 2. layer count, names and dates ------------------------------------------------------------
files[, expected_n := fifelse(method == "monthly_1km", 12L, fifelse(is_leap(year), 366L, 365L))]
finding("bad_layer_count", files[read_ok == TRUE & nlyr != expected_n, .(path, nlyr, expected_n)])

layers[, exp_num := ifelse(method == "monthly_1km",
                           as.numeric(as.Date(sprintf("%d-%02d-01", year, pmin(layer, 12L)))),
                           as.numeric(as.Date(sprintf("%d-01-01", year))) + layer - 1)]
layers[, exp_date := as.Date(exp_num, origin = "1970-01-01")]
layers[, exp_name := ifelse(method == "monthly_1km",
                            sprintf("%s_01_%02d_%d", variable, layer, year),
                            sprintf("%s_%s_%s_%d", variable, format(exp_date, "%d"), format(exp_date, "%m"), year))]
finding("bad_names_or_dates",
        layers[name != exp_name | is.na(time) | time != as.character(exp_date),
               .(region, method, variable, year, layer, name, exp_name, time, exp_date)],
        "layer name or time stamp does not match the position (day alignment!)")

## 3. geometry ---------------------------------------------------------------------------------
g <- merge(files[read_ok == TRUE], mask_info, by = c("region", "method"))
tol <- 1e-6
finding("bad_geometry",
        g[abs(xmin - m_xmin) > tol | abs(xmax - m_xmax) > tol | abs(ymin - m_ymin) > tol |
            abs(ymax - m_ymax) > tol | abs(resx - m_resx) > tol | abs(resy - m_resy) > tol | ncell != m_ncell,
          .(path, ncell, m_ncell, xmin, m_xmin, resx, m_resx)],
        "extent/resolution differ from the region mask")
crs_mode <- files[read_ok == TRUE, .(crs_ref = names(which.max(table(crs)))), by = .(region, method)]
finding("bad_crs", merge(files[read_ok == TRUE], crs_mode, by = c("region", "method"))[crs != crs_ref, .(path, crs, crs_ref)])

## 4. NA cells ---------------------------------------------------------------------------------
layers <- merge(layers, files[, .(region, method, variable, year, ncell)], by = c("region", "method", "variable", "year"))
layers <- merge(layers, mask_info[, .(region, method, n_na_mask)], by = c("region", "method"))
layers[, n_na_use := ifelse(method == "monthly_1km", n_na_masked, n_na)]   # inside the mask for monthly
layers[, empty := n_na >= ncell]
layers[, extra_na := n_na_use - n_na_mask]      # NA cells in addition to the cells outside the mask
finding("na_deviations", layers[empty == FALSE & extra_na != 0,
          .(region, method, variable, year, layer, name, n_na_use, n_na_mask, extra_na)],
        "non-empty layers whose NA count differs from the NA count of the mask")
na_ref <- layers[empty == FALSE, .(n_na_mode = as.numeric(names(which.max(table(n_na_use)))),
                                   n_na_mask = n_na_mask[1], n_layers = .N), by = .(region, method, variable)]
fwrite(na_ref, file.path(report_dir, "na_reference_table.csv"))
raw_below <- layers[method == "monthly_1km" & empty == FALSE & n_na < n_na_mask, .N, by = variable]
if (nrow(raw_below) > 0) {
  cat("  note: monthly layers with fewer raw NA than the mask (values outside the mask, e.g. prec sum = 0):\n")
  print(raw_below)
}

## 5. value ranges -----------------------------------------------------------------------------
layers[, lo := vapply(variable, function(v) if (!is.null(ranges[[v]])) ranges[[v]][1] else -Inf, 0)]
layers[, hi := vapply(variable, function(v) if (!is.null(ranges[[v]])) ranges[[v]][2] else Inf, 0)]
finding("range_violations", layers[empty == FALSE & (min < lo | max > hi),
          .(region, method, variable, year, layer, name, min, max, lo, hi)])
finding("non_finite_values", layers[empty == FALSE & (!is.finite(min) | !is.finite(max) | !is.finite(mean)),
          .(region, method, variable, year, layer, name, min, max, mean)])
finding("constant_layers", layers[empty == FALSE & variable != "prec" & min == max,
          .(region, method, variable, year, layer, name, min)], "min == max (e.g. fill values)")
cat("  maxima per variable and method (for a visual range check):\n")
print(layers[empty == FALSE, .(min = min(min), max = max(max)), by = .(variable, method)][order(variable, method)])

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

## 6. empty layers vs QC ---------------------------------------------------------------------
empty_l <- layers[empty == TRUE]
if (!is.na(qc_dir) && dir.exists(qc_dir)) {
  qd <- rbindlist(lapply(list.files(qc_dir, "^qc_days_.*\\.csv$", full.names = TRUE), fread,
                         colClasses = list(character = c("date", "reason"))), fill = TRUE)
  qm <- rbindlist(lapply(list.files(qc_dir, "^qc_months_.*\\.csv$", full.names = TRUE), fread), fill = TRUE)
  qd <- fill_date(qd)
  fl <- unique(qd[status == "flagged", .(variable, date_chr = date)])
  d_empty <- empty_l[method == "daily_10km"]; d_empty[, date_chr := as.character(exp_date)]
  d_empty[, flagged := paste(variable, date_chr) %in% paste(fl$variable, fl$date_chr)]
  finding("empty_daily_not_flagged", d_empty[flagged == FALSE, .(region, variable, year, layer, date_chr)],
          "empty daily layer without a flagged day in the QC tables")
  fl_all <- fl[, .(region = regions), by = .(variable, date_chr)]
  nonempty_d <- layers[method == "daily_10km" & empty == FALSE, .(region, variable, date_chr = as.character(exp_date), year, layer)]
  finding("flagged_but_layer_not_empty", merge(fl_all, nonempty_d, by = c("region", "variable", "date_chr")),
          "flagged day in the QC tables but the daily layer contains values (alignment problem?)")
  qm_na <- qm[monthly_action %in% c("NA_prec_incomplete", "NA_no_valid_day"), .(variable, year, month, monthly_action)]
  m_empty <- empty_l[method == "monthly_1km", .(region, variable, year, month = layer)]
  finding("empty_monthly_not_in_qc", merge(m_empty, qm_na, by = c("variable", "year", "month"), all.x = TRUE)[is.na(monthly_action)],
          "empty monthly layer without NA action in the QC tables")
  finding("qc_na_month_not_empty", merge(qm_na[, .(variable, year, month, monthly_action)],
          layers[method == "monthly_1km" & empty == FALSE, .(region, variable, year, month = layer)],
          by = c("variable", "year", "month")), "QC says the month should be NA but the layer has values")
} else {
  cat("  (no qc_dir given: skipping the cross-check of flagged days)\n")
  finding("empty_layers", empty_l[, .(region, method, variable, year, layer, name)], "empty layers (no QC given to explain them)")
}
part <- empty_l[method == "daily_10km", .(n_regions_empty = .N), by = .(variable, year, layer)][n_regions_empty != length(regions)]
finding("empty_daily_not_in_all_regions", part, "a day is empty in some regions but not in all")
pk <- c("variable", "year", "month")
pm_d <- unique(empty_l[method == "daily_10km" & variable == "prec",
                       .(variable = as.character(variable), year = as.integer(year),
                         month = as.integer(format(exp_date, "%m")))])
pm_m <- unique(empty_l[method == "monthly_1km" & variable == "prec",
                       .(variable = as.character(variable), year = as.integer(year), month = as.integer(layer))])
pm_issue <- rbind(pm_m[!pm_d, on = pk][, .(variable, year, month, issue = rep("monthly empty, no empty day", .N))],
                  pm_d[!pm_m, on = pk][, .(variable, year, month, issue = rep("empty day, monthly value present", .N))])
finding("prec_month_vs_empty_days", pm_issue,
        "prec: a month with empty days must be NA in monthly_1km (and vice versa)")

## 7. temperature order (tasmin <= tas <= tasmax) --------------------------------------------
tw <- dcast(layers[variable %in% c("tas", "tasmin", "tasmax") & empty == FALSE],
            region + method + year + layer ~ variable, value.var = "mean")
if (all(c("tas", "tasmin", "tasmax") %in% names(tw))) {
  finding("temp_order_violations", tw[tasmin > tas + temp_order_tol | tas > tasmax + temp_order_tol | tasmin > tasmax + temp_order_tol])
}

## 8. consistency monthly (1 km) vs daily (10 km) ------------------------------------------
dly <- layers[method == "daily_10km"][, month := as.integer(format(exp_date, "%m"))]
dmon <- dly[, .(n_empty = sum(empty), mean_of_means = mean(mean[!empty]), sum_of_means = sum(mean[!empty])),
            by = .(region, variable, year, month)]
mon <- layers[method == "monthly_1km" & empty == FALSE, .(region, variable, year, month = layer, monthly_mean = mean)]
cc <- merge(mon, dmon[n_empty == 0], by = c("region", "variable", "year", "month"))
cc[, daily_stat := ifelse(variable == "prec", sum_of_means, mean_of_means)]
cc[, diff := monthly_mean - daily_stat]
cc[, bad := ifelse(variable == "prec", abs(diff) > cons_tol_rel_prec * pmax(abs(daily_stat), 1),
                   abs(diff) > cons_tol_abs[variable])]
finding("monthly_vs_daily_mismatch", cc[bad == TRUE, .(region, variable, year, month, monthly_mean, daily_stat, diff)],
        "regional mean of the monthly 1 km layer differs from the 10 km daily layers (also catches misaligned days)")

## 9. statistical outliers ---------------------------------------------------------------------
mm <- layers[method == "monthly_1km" & empty == FALSE, .(region, variable, year, month = layer, mean)]
mm[, `:=`(med = median(mean), madv = mad(mean)), by = .(region, variable, month)]
mm[, z := (mean - med) / pmax(madv, 1e-9)]
finding("monthly_outliers", mm[abs(z) > z_month][order(-abs(z))], "monthly regional mean far from the same calendar month in other years")
dj <- layers[method == "daily_10km" & empty == FALSE & variable != "prec"][order(region, variable, year, layer)]
dj[, d := mean - data.table::shift(mean), by = .(region, variable, year)]
dj[, z := (d - median(d, na.rm = TRUE)) / pmax(mad(d, na.rm = TRUE), 1e-9), by = .(region, variable)]
jumps <- dj[abs(z) > z_jump, .(region, variable, year, layer, name, mean, d, z)][order(-abs(z))]
finding("daily_jumps", head(jumps, 1000), "large day-to-day jumps of the regional mean (first 1000)")

## 10. files ----------------------------------------------------------------------------------------
files[, size_med := median(size, na.rm = TRUE), by = .(region, method, variable)]
finding("size_outliers", files[size / size_med < size_ratio[1] | size / size_med > size_ratio[2], .(path, size, size_med)])
stray <- list.files(results_dir, pattern = "\\.part$", recursive = TRUE, full.names = TRUE)
finding("leftover_part_files", data.table(path = stray))
files[, mtime_d := as.Date(substr(mtime, 1, 10))]
cat("\nModification times of the files:", format(min(files$mtime_d, na.rm = TRUE)), "to", format(max(files$mtime_d, na.rm = TRUE)), "\n")
if (!is.na(newer_than)) finding("files_older_than_threshold", files[mtime_d < newer_than, .(path, mtime)])

fwrite(rbindlist(summary_rows), file.path(stats_dir, "check_summary.csv"))
cat("\nReport files in:", report_dir, "\n")
