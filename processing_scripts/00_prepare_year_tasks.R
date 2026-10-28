# ============================================================================= #
## 0. Preparation of the variable x year pipeline
#
# Creates the task table (one row = one variable x one year x months), the mask
# metadata (1 km AND 10 km) and the configuration. Each array task of
# 01_process_year_task.R processes exactly one row.
#
# Two modes:
#   mode = "params"          : set variables, years and months below
#   mode = "files_to_update" : read files_to_update.txt; for each variable and
#                              year only the affected months are computed
#
# A task downloads the daily files only temporarily (scratch), tests them,
# computes monthly_1km AND daily_10km for all regions and deletes the raw data.
# Bioclims (1 km, then 10 km) are computed afterwards with the existing scripts.
# ============================================================================= #

library(terra)
library(data.table)

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
source(file.path(transfer_dir, "processing_scripts", "chelsa_pipeline_functions.R"))


## PARAMETERS -----------------------------------------------------------------

mode <- "params"                       # "params" or "files_to_update"

# --- only mode = "params" ---
sel_variables <- c("prec", "tas", "tasmin", "tasmax", "rsds")   # add "hurs" if needed
sel_years     <- 1941:2024
sel_months    <- 1:12                  # subsets are possible, see note below
force         <- FALSE                 # TRUE: also recompute combinations that are already complete

# --- applies to both modes: which products are computed ---
# "monthly_1km" and/or "daily_10km". Download and test always happen; only the
# selected products are computed and written.
sel_methods   <- c("monthly_1km", "daily_10km")

# --- only mode = "files_to_update" ---
files_to_update_path <- file.path(transfer_dir, "processing_scripts", "files_to_update.txt")

# Note on partial months: if only some months are selected (or they come from
# files_to_update.txt), only these months are inserted into the EXISTING yearly
# files. If the yearly files of a variable-year combination are missing (e.g.
# new variable hurs), this combination is computed completely (1-12).

regions <- c("Australia", "Europe", "USA", "Finland")

region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)

## Directories
mask_dir     <- file.path(transfer_dir, "mask_files")
out_dir      <- file.path(transfer_dir, "GEOBON_results")      # all results go into the same folder
scratch_root <- "/import/ecoc9/data-zurell/reeg"               # temporary raw data (7 TB)
qc_dir       <- file.path(transfer_dir, "processing_scripts", "qc_year_tasks")
task_dir     <- file.path(transfer_dir, "processing_scripts", "array_prep_year")

## Download and test (see chelsa_pipeline_functions.R)
base_url         <- "https://os.unil.cloud.switch.ch/chelsa02/"
raw_nodata_value <- 65535        # raw NoData value, confirmed by diagnostics
download_tries   <- 3
max_parallel_downloads <- 4      # upper limit of simultaneous downloads/tests per task (be considerate to the server)

# Common temperature range for tas, tasmin, tasmax: lower bound from tasmin,
# upper bound from tasmax (values from the previous daily script, in K).
temp_range <- c(180, 345)
ranges <- list(
  tas    = temp_range,
  tasmin = temp_range,
  tasmax = temp_range,
  rsds   = c(0, 1000),
  prec   = NULL,                 # no range check (0 is valid)
  hurs   = c(0, 100)             # percent, AFTER the conversion by value_factor (see below)
)
# Checks for broken days that stay inside the range (found in the result check:
# rsds days with a constant value of 0/1 or a tiny global mean):
#  - a file whose max == min is always flagged ("constant_file")
#  - min_global_max: a day whose global maximum is below this value is flagged
#  - min_mean_ratio: a day whose global mean is below ratio x median of the days of the task
#    is flagged. ESTIMATES: a real rsds day has a clearly sunlit area (max >> 50 W/m2) and the
#    seasonal course of the global land mean stays well above 30 % of the annual median.
#    Check the flagged days in qc_days_*.csv (column mean_val) after the first run and adjust.
min_global_max <- list(rsds = 50)
min_mean_ratio <- list(rsds = 0.3, hurs = 0.3)   # hurs: found days with a regional mean of ~5 % of the neighbouring days

# Conversion factor applied to the values right after reading (after the NoData flag).
# hurs: the raw file says variable_unit=percent but is scaled by 0.001 (terra returns 0-1);
# multiplied by 100 the values are percent (0-100), as declared in the EBV json files.
# ranges, QC statistics and results are all in the converted unit.
value_factor <- list(hurs = 100)

# CHELSA is NoData over the oceans -> a high NA fraction is normal. A day is
# flagged if its NA fraction exceeds the median of the days of the task by more
# than max_na_excess.
max_na_excess    <- 0.01         # estimate (1 percentage point)
max_flagged_fraction <- 0.2      # task aborts if more than 20 % of the days are flagged (e.g. server problem)

# prec: a month with missing/flagged days is strongly distorted because the
# monthly value is a sum. "NA" = the monthly prec value is set to NA, "keep" =
# keep the sum over the remaining days (not recommended).
prec_incomplete_month_action <- "NA"


## SAVE CONFIGURATION ---------------------------------------------------------

for (d in c(task_dir, qc_dir)) if (!dir.exists(d)) dir.create(d, recursive = TRUE)

cfg <- list(
  transfer_dir = transfer_dir, out_dir = out_dir, mask_dir = mask_dir,
  scratch_root = scratch_root, qc_dir = qc_dir,
  regions = regions, region_folder_names = region_folder_names,
  base_url = base_url, raw_nodata_value = raw_nodata_value,
  download_tries = download_tries, max_parallel_downloads = max_parallel_downloads,
  ranges = ranges, max_na_excess = max_na_excess,
  min_global_max = min_global_max, min_mean_ratio = min_mean_ratio, value_factor = value_factor,
  max_flagged_fraction = max_flagged_fraction,
  prec_incomplete_month_action = prec_incomplete_month_action
)


## MASKS (1 km and 10 km) -----------------------------------------------------
# As before: LAEA masks exist, EPSG:4326 masks are created if needed.

region_masks_meta <- list()

for (res_km in c(1, 10)) {
  res_name <- paste0(res_km, "km")

  mask_files <- list.files(mask_dir, pattern = paste0(".*", res_km, "km\\.tif$"), full.names = TRUE)
  mask_laea_files <- mask_files[-grep("EPSG4326", mask_files)]
  mask_4326_files <- mask_files[grep("EPSG4326", mask_files)]

  for (region in regions) {
    mask_laea_file <- grep(region, mask_laea_files, value = TRUE)
    if (length(mask_laea_file) != 1) stop("No unique LAEA mask for ", region, " (", res_name, ")")

    mask_4326_file <- file.path(mask_dir, paste0("mask_", region, "_EPSG4326_", res_km, "km.tif"))
    if (!file.exists(mask_4326_file)) {
      cat("Creating EPSG:4326 mask:", basename(mask_4326_file), "\n")
      m <- terra::project(terra::rast(mask_laea_file), "EPSG:4326")
      terra::writeRaster(m, mask_4326_file, overwrite = TRUE)
    }

    region_masks_meta[[region]][[res_name]] <- list(laea = mask_laea_file, e4326 = mask_4326_file)
  }
}


## TASK TABLE -----------------------------------------------------------------

if (!all(sel_methods %in% c("monthly_1km", "daily_10km"))) stop("Unknown method in sel_methods")

outputs_complete <- function(var, yr, methods) {
  ms <- strsplit(methods, ",")[[1]]
  paths <- unlist(lapply(regions, function(r) vapply(ms, function(me) out_path(cfg, r, me, var, yr), "")))
  all(file.exists(paths))
}

all_months <- months_to_string(1:12)

if (mode == "files_to_update") {

  f <- readLines(files_to_update_path)
  f <- f[nzchar(f)]
  parts <- data.table::tstrsplit(basename(f), "_")     # CHELSA, variable, dd, mm, yyyy, V.2.1.tif
  upd <- data.table(variable = parts[[2]], month = as.integer(parts[[4]]), year = as.integer(parts[[5]]))
  tasks <- upd[, .(months = months_to_string(month)), by = .(variable, year)]

} else if (mode == "params") {

  tasks <- CJ(variable = sel_variables, year = sel_years)
  tasks[, months := months_to_string(sel_months)]

} else {
  stop("Unknown mode: ", mode)
}

tasks[, methods := paste(sel_methods, collapse = ",")]
tasks[, complete := mapply(outputs_complete, variable, year, methods, USE.NAMES = FALSE)]

# Without existing yearly files, single months cannot be inserted -> compute everything
needs_full <- tasks$months != all_months & !tasks$complete
if (any(needs_full)) {
  cat("Note:", sum(needs_full), "combination(s) without complete result files will be computed completely (1-12).\n")
  tasks[needs_full, months := all_months]
}

# Skip combinations that are already complete (params mode only, full years)
if (mode == "params" && !force) {
  tasks <- tasks[!(complete & months == all_months)]
}

tasks[, complete := NULL]
setorder(tasks, variable, year)
tasks <- as.data.frame(tasks)

cat("\nNumber of tasks:", nrow(tasks), "\n")
print(head(tasks, 20))


## SAVE -----------------------------------------------------------------------

saveRDS(tasks,             file.path(task_dir, "tasks_todo.rds"))
saveRDS(region_masks_meta, file.path(task_dir, "region_masks_meta.rds"))
saveRDS(cfg,               file.path(task_dir, "config.rds"))

cat("\nDone. Files in:", task_dir, "\n")
if (nrow(tasks) <= 1000) {
  cat("In the submit script: #SBATCH --array=1-", nrow(tasks), "%<N>\n", sep = "")
} else {
  cat("MaxArraySize is 1001: submit the array in blocks of 1000 (increase TASK_OFFSET in the submit script).\n")
}
