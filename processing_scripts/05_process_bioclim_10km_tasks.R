library(terra)
library(tidyverse)
library(gdalUtilities)

# ==============================================================================
# BMIP - ARRAY TASK: resample ONE year of 1 km bioclims to 10 km
#
# One SLURM array task = one region x year (SLURM_ARRAY_TASK_ID = row in tasks).
#
# Everything the task prints goes to the SLURM output file of THAT task
# (one file per task, see the sbatch example). A failed task exits non-zero, so
# SLURM marks it FAILED and sacct shows it. Which region/year combinations are
# actually finished is determined from the output files themselves.
#
# Interactive use (RStudio): set task_id_manual below to the row you want.
# ==============================================================================

## ---------------------------------------------------------------------
## 1. Settings, task ID and the prepared objects
## ---------------------------------------------------------------------
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data"      

task_id_manual <- 2     # used only when SLURM_ARRAY_TASK_ID is not set (interactive)
tmp_dir        <- file.path(transfer_dir, "tmp")   # NULL = use the system temp dir; or e.g. "/scratch/$USER/bio10km"

task_dir <- file.path(transfer_dir, "processing_scripts", "array_prep_bioclim10km")

tasks             <- readRDS(file.path(task_dir, "tasks_todo.rds"))
region_masks_meta <- readRDS(file.path(task_dir, "region_masks_meta.rds"))
config            <- readRDS(file.path(task_dir, "config.rds"))

method_name  <- config$method_name
res_m        <- config$res_m
expected_lyr <- config$expected_lyr

task_id <- as.integer(Sys.getenv("SLURM_ARRAY_TASK_ID"))
if (is.na(task_id)) {
  task_id <- task_id_manual
  cat("SLURM_ARRAY_TASK_ID not set - running interactively with task_id =", task_id, "\n")
}
if (task_id < 1 || task_id > nrow(tasks)) {
  stop("Invalid task id (", task_id, ") for ", nrow(tasks), " tasks.")
}

# own temp directory, so parallel array tasks never collide and the space used
# is visible and controllable
if (!is.null(tmp_dir)) {
  tmp_dir <- file.path(tmp_dir, paste0("bioclim10_task_", task_id))
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  terra::terraOptions(tempdir = tmp_dir, progress = 0)
} else {
  tmp_dir <- tempdir()
}

this_task <- tasks[task_id, ]
region    <- this_task$region
yr        <- this_task$year
src_file  <- this_task$src
out_file  <- this_task$out_file

log_progress <- function(msg) {
  cat(sprintf("[%s] Task %d (%s / %d): %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"), task_id, region, yr, msg))
  flush(stdout())
}

t_start <- Sys.time()
log_progress(paste("Task started -", basename(src_file)))

## ---------------------------------------------------------------------
## 2. The actual work, wrapped so that a failure is recorded
## ---------------------------------------------------------------------
# The result is written to a .part file and renamed only after all checks passed, so an
# error never deletes an existing good 10 km file (important when years are recomputed).
part_file <- paste0(out_file, ".part")

result <- tryCatch({
  
  meta  <- region_masks_meta[[region]]
  n_exp <- meta$n_notNA
  mask_r <- terra::rast(meta$mask_file)
  
  if (!file.exists(src_file)) stop("source file does not exist: ", src_file)
  
  region_out_dir <- dirname(out_file)
  if (!dir.exists(region_out_dir)) dir.create(region_out_dir, recursive = TRUE, showWarnings = FALSE)
  
  # source header: layer count and names are needed later
  src <- terra::rast(src_file)
  if (terra::nlyr(src) != expected_lyr) {
    stop("source has ", terra::nlyr(src), " layers, expected ", expected_lyr)
  }
  src_names <- names(src)
  src_time  <- tryCatch(terra::time(src), error = function(e) NULL)
  log_progress(paste("source layers:", paste(head(src_names, 3), collapse = ", "), "..."))
  
  ## --- gdalwarp: 1 km -> 10 km, snapped to the mask grid
  tmp_file <- file.path(tmp_dir, paste0(region, "_", yr, "_warp.tif"))
  
  log_progress("running gdalwarp")
  gdalUtilities::gdalwarp(
    srcfile   = src_file,
    dstfile   = tmp_file,
    overwrite = TRUE,
    tr        = c(res_m, res_m),
    r         = "average",
    t_srs     = meta$crs,
    te        = c(meta$extent[1], meta$extent[3], meta$extent[2], meta$extent[4]),
    srcnodata = "nan",      # make NA explicit so "average" ignores it
    dstnodata = "nan")
  
  if (!file.exists(tmp_file)) stop("gdalwarp produced no output")
  
  ## --- restore layer names, then write the final file
  warped <- terra::rast(tmp_file)
  if (terra::nlyr(warped) != expected_lyr) {
    stop("warped file has ", terra::nlyr(warped), " layers, expected ", expected_lyr)
  }
  if (!isTRUE(terra::compareGeom(warped, mask_r, stopOnError = FALSE))) {
    stop("warped grid does not match ", basename(meta$mask_file))
  }
  
  # GDAL usually drops band descriptions - put the bio names back
  names(warped) <- src_names
  if (!is.null(src_time) && length(src_time) == expected_lyr && !all(is.na(src_time))) {
    terra::time(warped) <- src_time
  }
  
  log_progress("writing output")
  terra::writeRaster(warped, part_file, datatype = "FLT4S", filetype = "GTiff", overwrite = TRUE)
  
  ## --- verify what was written
  chk     <- terra::rast(part_file)
  n_valid <- terra::global(chk, "notNA")$notNA        # one value per layer
  
  log_progress(sprintf("valid cells per layer: %s - %s (mask: %s)",
                       format(min(n_valid), big.mark = ","),
                       format(max(n_valid), big.mark = ","),
                       format(n_exp, big.mark = ",")))
  
  if (!identical(names(chk), src_names)) {
    stop("layer names were not stored correctly: ", paste(head(names(chk), 3), collapse = ", "))
  }
  if (any(n_valid == 0)) {
    stop("layer(s) completely NA: ", paste(which(n_valid == 0), collapse = ", "))
  }
  
  # all checks passed -> replace the final file
  rm(chk)
  if (!file.rename(part_file, out_file)) stop("could not rename ", part_file)
  
  note <- NA_character_
  if (any(n_valid != n_exp)) {
    # bio15 is undefined (NaN) where annual precipitation is 0, so this can be
    # legitimate - compare with the same layer at 1 km before acting on it
    d <- n_valid - n_exp
    note <- sprintf("valid cells differ from mask by %+d to %+d in layer(s) %s",
                    min(d), max(d), paste(which(n_valid != n_exp), collapse = ","))
    log_progress(paste("WARNING -", note))
  }
  
  list(status = if (is.na(note)) "ok" else "ok_with_warning", note = note,
       n_valid_min = min(n_valid), n_valid_max = max(n_valid), n_expected = n_exp)
  
}, error = function(e) {
  # remove the half-written .part file only (an existing final file stays untouched)
  if (file.exists(part_file)) {
    unlink(part_file)
    cat("removed incomplete output:", part_file, "\n")
  }
  list(status = "failed", note = conditionMessage(e),
       n_valid_min = NA_real_, n_valid_max = NA_real_, n_expected = NA_real_)
})

## ---------------------------------------------------------------------
## 3. Report the outcome and exit
## ---------------------------------------------------------------------
log_progress(sprintf("Task %s in %.1f min", result$status,
                     as.numeric(difftime(Sys.time(), t_start, units = "mins"))))

# remove the temporaray directory ---
unlink(tmp_dir, recursive = TRUE)

if (result$status == "failed") {
  # non-zero exit, so SLURM marks the task FAILED and sacct shows it
  stop("Task ", task_id, " (", region, " ", yr, ") failed: ", result$note)
}


