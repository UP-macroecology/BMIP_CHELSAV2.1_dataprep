# 1 SET UP ---------------------------------------------------------------------

## libraries ---------------------------------------------------------------
library(terra)
library(tidyverse)

# ==============================================================================
# BMIP - SETUP for the 10 km bioclim resampling as a SLURM ARRAY job
#
# Builds ONE task per region x year that still needs to be resampled from the
# 1 km bioclims, and saves everything the array tasks need. Replaces the
# foreach/doParallel chunking: no chunk index arithmetic, one task per file,
# and a failed task only costs that one year.
#
# Run this once, then submit the array with the size it prints at the end.
# ==============================================================================

## RUN ALL YEARS: YES OR NO ------------------------------------------------
run_for_all_years <- TRUE   # TRUE = redo every year, FALSE = missing years only
# force_years: only used with run_for_all_years = FALSE. Years whose 1 km bioclims were
# recomputed -> resample these years again even if a 10 km file already exists.
force_years <- NULL         # e.g. c(1945, 1949, 1955)

## parameters --------------------------------------------------------------
resolution_out <- 10                     # km, target resolution
res_m          <- resolution_out * 1000  # m, used for gdalwarp -tr
regions        <- c("Australia", "Europe", "USA", "Finland")
method_in      <- "annual_bioclim_1km"   # source
method_name    <- "annual_bioclim_10km"  # target
expected_lyr   <- 19                     # bio1 ... bio19

## directories -------------------------------------------------------------
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"     

mask_dir <- file.path(transfer_dir, "mask_files")
file_dir <- file.path(transfer_dir, "GEOBON_results")
out_dir  <- file.path(transfer_dir, "GEOBON_results")

# TEST MODE (optional): NULL = off
# test_out_dir       : results go here instead of GEOBON_results
# source_dir         : ONLY this folder is searched for 1 km bioclims (and for already
#                      existing 10 km files). Files in GEOBON_results are not used at all.
#                      NULL = search GEOBON_results.
# input_override_dir : 1 km bioclims in this folder take precedence over the ones in
#                      GEOBON_results (same folder structure)
test_out_dir       <- NULL   # e.g. "/import/ecoc9/data-zurell/reeg/test_task"
source_dir         <- NULL   # e.g. "/import/ecoc9/data-zurell/reeg/test_task"
input_override_dir <- NULL   # e.g. "/import/ecoc9/data-zurell/reeg/test_task"
if (!is.null(test_out_dir)) {
  if (startsWith(normalizePath(test_out_dir, mustWork = FALSE), normalizePath(file_dir)))
    stop("test_out_dir must not be inside GEOBON_results")
  out_dir <- test_out_dir
}

region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)

## CRS per region ----------------------------------------------------------
equal_crs <- data.frame(Australia = "EPSG:9473",
                        Europe    = "EPSG:3035",
                        USA       = "ESRI:102003",
                        Finland   = "EPSG:3035")

# directory for the objects handed to the array tasks
task_dir <- file.path(transfer_dir, "processing_scripts", "array_prep_bioclim10km")
if (!dir.exists(task_dir)) dir.create(task_dir, recursive = TRUE)

# -------------------------------------------------------------------------
# 2. MASKS AT THE TARGET RESOLUTION ---------------------------------------

mask_files <- list.files(mask_dir, pattern = paste0(".*", resolution_out, "km\\.tif$"),
                         full.names = TRUE)
mask_files <- mask_files[!grepl("EPSG4326", mask_files)]   # LAEA / equal-area only

region_masks_meta <- list()
for (region in regions) {
  f <- grep(region, mask_files, value = TRUE)
  if (length(f) != 1) {
    stop("No unique ", resolution_out, "km mask for region: ", region,
         " (found ", length(f), ")")
  }
  m <- terra::rast(f)
  region_masks_meta[[region]] <- list(
    mask_file = f,
    extent    = as.vector(terra::ext(m)),                 # xmin, xmax, ymin, ymax
    res       = terra::res(m),
    crs       = equal_crs[[region]],
    n_notNA   = terra::global(m[[1]], "notNA")$notNA)     # expected valid cells
  
  cat(sprintf("%-10s mask: %s | res %s | %s valid cells\n", region, basename(f),
              paste(terra::res(m), collapse = " x "),
              format(region_masks_meta[[region]]$n_notNA, big.mark = ",")))
  
  if (!isTRUE(all.equal(terra::res(m), c(res_m, res_m)))) {
    warning("Mask resolution of ", region, " is not ", res_m, " m - check the mask file.")
  }
  rm(m)
}

# -------------------------------------------------------------------------
# 3. FILE LISTING ----------------------------------------------------------

list_dir <- if (is.null(source_dir)) file_dir else source_dir
all_files <- list.files(list_dir, pattern = "\\.tif$", full.names = TRUE, recursive = TRUE)

# bioclim paths are .../<region_folder>/envdat/clim/<method>/<year>.tif
df_all <- tibble(full_path = all_files) %>%
  mutate(file          = basename(full_path),
         method        = basename(dirname(full_path)),
         region_folder = basename(dirname(dirname(dirname(dirname(full_path))))),
         year          = suppressWarnings(as.numeric(sub("\\.tif$", "", file))),
         region        = names(region_folder_names)[match(region_folder, region_folder_names)]) %>%
  filter(!is.na(year), !is.na(region))

df_source <- df_all %>% filter(method == method_in)    # 1 km bioclims
if (!is.null(input_override_dir)) {
  alt <- sub(file_dir, input_override_dir, df_source$full_path, fixed = TRUE)
  ex  <- file.exists(alt)
  df_source$full_path[ex] <- alt[ex]
  cat("\n1 km files taken from", input_override_dir, ":", sum(ex), "of", nrow(df_source), "\n")
}
df_done   <- df_all %>% filter(method == method_name)  # already resampled

cat("\nAvailable", method_in, "files:\n")
print(df_source %>% count(region, name = "n_files"))

cat("\nAlready processed", method_name, "files:\n")
if (nrow(df_done) == 0) cat("   none\n") else print(df_done %>% count(region, name = "n_files"))

if (nrow(df_source) == 0) stop("No ", method_in, " files found under ", list_dir)

# -------------------------------------------------------------------------
# 4. BUILD THE TASK LIST ---------------------------------------------------
# One row = one region x year = one SLURM array task.
# anti_join on region AND year (not year alone), so a year processed for one
# region is not skipped for the others.

tasks <- df_source %>%
  select(region, year, src = full_path)

if (!run_for_all_years) {
  # missing region-year combinations, plus the years listed in force_years
  tasks <- tasks %>%
    filter(!paste(region, year) %in% paste(df_done$region, df_done$year) |
             year %in% force_years)
} else {
  cat("\nrun_for_all_years = TRUE: every year will be redone.\n")
}

tasks <- tasks %>%
  arrange(region, year) %>%
  mutate(out_file = file.path(out_dir, region_folder_names[region], "envdat", "clim",
                              method_name, paste0(year, ".tif"))) %>%
  as.data.frame()

cat("\nTasks still to process:", nrow(tasks), "\n")
if (nrow(tasks) == 0) stop("...No years to process!...")
print(tasks %>% count(region, name = "n_tasks"))
print(head(tasks[, c("region", "year")], 10))

# -------------------------------------------------------------------------
# 5. SAVE OBJECTS FOR THE ARRAY TASKS --------------------------------------

config <- list(
  transfer_dir        = transfer_dir,
  out_dir             = out_dir,
  method_in           = method_in,
  method_name         = method_name,
  res_m               = res_m,
  expected_lyr        = expected_lyr,
  region_folder_names = region_folder_names)

saveRDS(tasks,             file.path(task_dir, "tasks_todo.rds"))
saveRDS(region_masks_meta, file.path(task_dir, "region_masks_meta.rds"))
saveRDS(config,            file.path(task_dir, "config.rds"))

cat("\nDone. Files written to:", task_dir, "\n")
cat("Set in the array submit script: #SBATCH --array=1-", nrow(tasks), "%<N>\n", sep = "")




