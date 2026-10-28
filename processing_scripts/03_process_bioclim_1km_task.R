# ==============================================================================
# BMIP - Processing Climate Data
# 5. Process a single region-year combination (SLURM array task)
#
# Called once per SLURM array task. SLURM_ARRAY_TASK_ID selects the row of
# tasks_todo.rds (created by 02_prepare_bioclim_1km_tasks.R) that is processed.
#
# The calculation itself (reading prec/tasmin/tasmax, Kelvin -> Celsius, layer
# check, predicts::bcvars, writeRaster) is taken UNCHANGED from the original
# script - only the outer foreach/doParallel loop over workers/regions/years
# was removed, because exactly one region-year combination is processed per
# task. The tidyverse (filter/pull) was replaced by data.table; the terra and
# predicts calls are untouched, so the results are identical.
# ==============================================================================

library(terra)
library(data.table)
library(predicts)

## ---------------------------------------------------------------------
## 1. Load task ID and prepared objects
## ---------------------------------------------------------------------

task_id <- as.integer(Sys.getenv("SLURM_ARRAY_TASK_ID"))

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
task_dir <- file.path(transfer_dir, "processing_scripts", "array_prep_bioclim")

tasks                 <- readRDS(file.path(task_dir, "tasks_todo.rds"))
df_years_to_process   <- as.data.table(readRDS(file.path(task_dir, "df_years_to_process.rds")))
config                <- readRDS(file.path(task_dir, "config.rds"))

out_dir             <- config$out_dir
region_folder_names <- config$region_folder_names
testing             <- config$testing

if (is.na(task_id) || task_id < 1 || task_id > nrow(tasks)) {
  stop("Invalid SLURM_ARRAY_TASK_ID (", task_id, ") for ", nrow(tasks), " tasks.")
}

this_task <- tasks[task_id, ]
reg <- this_task$region
yr  <- this_task$year

log_msg <- function(region = NA, year = NA, msg) {
  cat(sprintf("[%s] Task %04d | Region: %-10s | Year: %-6s | %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
              task_id,
              ifelse(is.na(region), "-", region),
              ifelse(is.na(year), "-", year),
              msg))
  flush(stdout())  # force it out immediately instead of buffering
}

log_msg(reg, yr, "Task started")

## ---------------------------------------------------------------------
## 2. Create output directory
## ---------------------------------------------------------------------

# Create region output directory
region_out_dir <- file.path(out_dir, region_folder_names[[reg]],
                            "envdat", "clim", config$method_name)
if (!dir.exists(region_out_dir)) {
  dir.create(region_out_dir, recursive = TRUE, showWarnings = FALSE)
}

## ---------------------------------------------------------------------
## 3. Bioclim calculation for this region-year combination
##    (identical to the original calculation)
## ---------------------------------------------------------------------

# extract pr, tasmin and tasmax file paths (reg / yr are the task values, the
# columns region / variable / year belong to df_years_to_process)
get_file <- function(v) {
  df_years_to_process[region == reg & variable == v & year == yr, full_path]
}

pr_file     <- get_file("prec")
tasmin_file <- get_file("tasmin")
tasmax_file <- get_file("tasmax")

if (length(pr_file) == 0 | length(tasmin_file) == 0 | length(tasmax_file) == 0) {
  log_msg(reg, yr, sprintf(
    "ERROR - missing file(s): prec=%s tasmin=%s tasmax=%s",
    ifelse(length(pr_file)==0, "MISSING", "ok"),
    ifelse(length(tasmin_file)==0, "MISSING", "ok"),
    ifelse(length(tasmax_file)==0, "MISSING", "ok")))
  stop("Error: Empty clim file...")
}

pr_terra <- terra::rast(pr_file)
tasmin_terra <- terra::rast(tasmin_file)
tasmax_terra <- terra::rast(tasmax_file)

# Convert temperature from Kelvin to Celsius
tasmin_terra <- tasmin_terra - 273.15
tasmax_terra <- tasmax_terra - 273.15

# Check if the RasterStacks have 12 monthly layers each
if (nlyr(pr_terra) != 12 | nlyr(tasmin_terra) != 12 | nlyr(tasmax_terra) != 12) {
  log_msg(reg, yr, "ERROR - missing monthly layers")
  stop("Error: Missing Layers...")
}

# Calculate the bioclimatic variables using the dismo::biovars function
bioclim_terra <- predicts::bcvars(prec = pr_terra,
                                  tmin = tasmin_terra,
                                  tmax = tasmax_terra)

log_msg(reg, yr, sprintf("Done - %d layers written (%s)",
                            terra::nlyr(bioclim_terra),
                            paste(names(bioclim_terra), collapse = ", ")))

# Save single year
writeRaster(bioclim_terra,
            filename = file.path(region_out_dir, paste0(yr, ".tif")),
            overwrite = TRUE)

# clean workspace
rm(pr_terra, tasmin_terra, tasmax_terra,
   pr_file, tasmin_file, tasmax_file,
   bioclim_terra)
gc()

if (testing) {stop("STOP TESTING ----")}

log_msg(reg, yr, "Task completed")
