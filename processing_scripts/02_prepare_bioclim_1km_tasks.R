# ==============================================================================
# BMIP - Processing Climate Data
# 0. Prepare tasks for SLURM array processing (annual_bioclim_1km)
#
# Runs ONCE (no array, no foreach/doParallel) and creates the list of all open
# region-year combinations ("tasks_todo.rds"), which is then processed as a
# SLURM array by 03_process_bioclim_1km_task.R.
#
# Aim:            Calculating annual bioclimatic variables using the
#                 R package dismo/predicts.
# Input Data:     Monthly mean precipitation, minimum and maximum
#                 temperature values derived from CHELSA daily variables
# Pre-processing: monthly_1km results of 01_process_year_task.R
# Regions:        For all BMIP regions: USA, Australia, Finland and Europe.
# Resolution:     1 km
# ==============================================================================

library(data.table)

# 1 SET UP ---------------------------------------------------------------------

## directories -------
## general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster

## specify input directories
file_dir <- file.path(transfer_dir, "GEOBON_results") # splits into regions next

## general output directory
out_dir <- file.path(transfer_dir, "GEOBON_results") # it diversifies later in loop

## TEST MODE (optional) ------
# test_out_dir       : results are written here instead of GEOBON_results (nothing in
#                      GEOBON_results is changed). NULL = normal mode.
# input_override_dir : monthly_1km files in this folder take precedence over the files
#                      of the same region/variable/year in GEOBON_results. Use it while
#                      the recomputed files are not yet copied to GEOBON_results (e.g.
#                      the test_task folder). NULL = use GEOBON_results only.
test_out_dir       <- "/import/ecoc9/data-zurell/reeg/test_task"
input_override_dir <- "/import/ecoc9/data-zurell/reeg/test_task"

if (!is.null(test_out_dir)) {
  if (startsWith(normalizePath(test_out_dir, mustWork = FALSE), normalizePath(file_dir)))
    stop("test_out_dir must not be inside GEOBON_results")
  out_dir <- test_out_dir
}

## Define variables --------
regions <- c("Australia", "Europe", "USA", "Finland")
method_name <- "annual_bioclim_1km" # the method used in this script
clim_method <- "monthly_1km" # previous method used to process climate data
var_names <- c("prec", "tasmin","tasmax") # only those needed for bioclim calc.

## match region folder names
region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)

##--------------- TESTING SETUP ---------
testing <- FALSE

if (testing) {
  cat("\nTEST MODE ------------------------------")
  out_dir <- "/home/josh/Dokumente/HiWi/MacroEco/BMIP/bioclim-testing/"
  regions <- "Australia"
}

# print overview in console
cat("\nDirectories ------\n")
cat("Working Dir:", file_dir,"\n")
cat("Output Dir:", out_dir, "\n")
cat("\nDefined variables ------\n")
cat("Variables:", var_names,"\n")
cat("Regions:", regions, "\n")

# Directory for the intermediate results (RDS files) used by the array tasks
task_dir <- file.path(transfer_dir, "processing_scripts", "array_prep_bioclim")
if (!dir.exists(task_dir)) dir.create(task_dir, recursive = TRUE)


# list all files ------------------------------
# Only real .tif files (not .tif.aux.xml or .tif.part)
all_files <- list.files(file.path(file_dir), pattern = "\\.tif$",
                         full.names = TRUE, recursive = TRUE)

# Split the paths into their components. Shorter paths (bioclim files have no
# variable folder) are padded with "" at the END, exactly as before - this is why
# the last six columns hold different things for the bioclim files (see below).
parts <- tstrsplit(all_files, "/", fixed = TRUE, fill = "")
n_parts <- length(parts)

# select the last six columns only and set column names
df_all_files <- as.data.table(parts[(n_parts - 5):n_parts])
setnames(df_all_files, c("region_folder", "type", "sphere",
                         "method", "variable", "file"))

# extract year and region information, store as column
df_all_files[, year := as.numeric(gsub("\\.tif$", "", file))]
df_all_files[, region := names(region_folder_names)[match(region_folder, region_folder_names)]]
# extract full path information
df_all_files[, full_path := all_files]


# filter for input clim files -------
df_clim_files <- df_all_files[method %in% clim_method &      # "monthly_1km"
                              variable %in% var_names]       # "prec", "tasmin", "tasmax"
df_clim_files[, clim_file_exists := TRUE]

# Test mode: prefer recomputed files from input_override_dir (same folder structure)
if (!is.null(input_override_dir)) {
  alt_path <- sub(file_dir, input_override_dir, df_clim_files$full_path, fixed = TRUE)
  use_alt  <- file.exists(alt_path)
  df_clim_files[use_alt, full_path := alt_path[use_alt]]
  cat("\nInput files taken from", input_override_dir, ":", sum(use_alt),
      "of", nrow(df_clim_files), "\n")
}

cat("\nAll available climate files.....\n")
print(df_clim_files[clim_file_exists == TRUE,
                    .(n.files = .N), by = .(region, method, variable)])

# filter for already processed output files ------
# For the bioclim files the file path has no variable folder, so the year ends
# up in the column "variable" (the padded "" is in "file"). We rename the column
# and extract year and region again.
df_processed <- df_all_files[method %in% method_name,       # "annual_bioclim_1km"
                             .(region_folder, type, sphere, method, variable, full_path)]
setnames(df_processed, "variable", "file")
df_processed[, `:=`(year = as.numeric(gsub("\\.tif$", "", file)),
                    region = names(region_folder_names)[match(region_folder, region_folder_names)],
                    processed = TRUE)]

cat("\nAll processed bioclim files.....\n")
print(df_processed[processed == TRUE, .(n.files = .N), by = .(region, method)])


#  Filter data to send to workers for calculations --------------------
# only use those year~region combinations where all three variables are complete
complete_rows <- df_clim_files[, .I[uniqueN(variable) == length(var_names)],
                               by = .(region, year)]$V1
df_complete_years <- df_clim_files[complete_rows]

cat(paste("\nPrec, tasmin and tasmax complete for",
          length(unique(df_complete_years$year)), "years.\n"))

# filter for years that have not been processed already
# force_years: years whose monthly_1km results were recomputed (e.g. through
# files_to_update or new QC flags) -> recompute the bioclims of these years even
# if a bioclim file already exists. NULL = only missing years.
force_years <- NULL   # e.g. c(1951, 1990)

processed_keys <- paste(df_processed$region, df_processed$year)
df_years_to_process <- df_complete_years[!paste(region, year) %in% processed_keys |
                                           year %in% force_years]

cat(paste("\nBioclim calculations missing for",
          length(unique(df_years_to_process$year)), "years.\n"))

# stop workflow if there are no years to process
if (nrow(df_years_to_process) == 0) stop("...No years to process!...")

# group all year~region combinations for all 3 variables
df_years_to_process_grouped <- df_years_to_process[order(region, year),
                                                   .(n_vars = .N), by = .(region, year)]


# -------------------------------------------------------------------------
# TASK LIST FOR SLURM ARRAY ------------------------------------------------
#
# One row per region-year combination that still has to be computed. Each row
# is later processed by exactly one SLURM array task (SLURM_ARRAY_TASK_ID =
# row number).

tasks <- as.data.frame(df_years_to_process_grouped[, .(region, year)])

cat("Number of tasks still to process:", nrow(tasks), "\n")
print(head(tasks, 20))


# -------------------------------------------------------------------------
# SAVE ALL OBJECTS NEEDED BY THE ARRAY TASKS -------------------------------

config <- list(
  transfer_dir        = transfer_dir,
  out_dir             = out_dir,
  method_name         = method_name,
  region_folder_names = region_folder_names,
  testing             = testing
)

saveRDS(tasks,                file.path(task_dir, "tasks_todo.rds"))
saveRDS(df_years_to_process,  file.path(task_dir, "df_years_to_process.rds"))
saveRDS(config,                file.path(task_dir, "config.rds"))

cat("\nDone. Files are in:", task_dir, "\n")
cat("Set in the array submit script: #SBATCH --array=1-", nrow(tasks), "%<N>\n", sep = "")
