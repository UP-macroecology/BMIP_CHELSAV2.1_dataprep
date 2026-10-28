# ============================================================================= #
## One-off conversion of existing hurs result files from a fraction (0-1) to percent (0-100)
#
# Usage:  Rscript convert_hurs_to_percent.R <in_dir> <out_dir> [task_id n_tasks]
#   in_dir  : folder with the existing results (e.g. GEOBON_results)
#   out_dir : folder for the converted files (same layout; use a TEST folder, then copy
#             after the result check). The input is never modified.
#   task_id, n_tasks : optional, split the file list for a SLURM array (round-robin)
#
# Only .../clim/{monthly_1km,daily_10km}/hurs/<year>.tif are converted. A file that already
# looks like percent (global maximum > 1.5) is skipped, so the script can be rerun safely.
# Names, dates (terra::time) and NA cells are kept; the output is written as .part first.
# New computations with 05_process_year_task.R produce percent directly (value_factor).
# ============================================================================= #
suppressPackageStartupMessages(library(terra))

args    <- commandArgs(trailingOnly = TRUE)
in_dir  <- args[1]; out_dir <- args[2]
task_id <- if (length(args) >= 4) as.integer(args[3]) else 1L
n_tasks <- if (length(args) >= 4) as.integer(args[4]) else 1L
stopifnot(dir.exists(in_dir), nzchar(out_dir), normalizePath(in_dir) != normalizePath(out_dir, mustWork = FALSE))

files <- list.files(in_dir, pattern = "\\.tif$", recursive = TRUE, full.names = FALSE)
files <- files[grepl("/clim/(monthly_1km|daily_10km)/hurs/[0-9]{4}\\.tif$", files)]
files <- sort(files)
files <- files[seq_along(files) %% n_tasks == task_id %% n_tasks]
cat("Files in this task:", length(files), "\n")

for (f in files) {
  dest <- file.path(out_dir, f)
  if (file.exists(dest)) { cat("exists, skipped:", f, "\n"); next }
  r <- rast(file.path(in_dir, f))
  mx <- global(r, "max", na.rm = TRUE)$max
  if (any(mx > 1.5, na.rm = TRUE)) { cat("already percent (max", max(mx, na.rm = TRUE), "), skipped:", f, "\n"); next }
  if (any(mx > 1.0001, na.rm = TRUE)) stop("unexpected values in ", f)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  r2 <- r * 100
  names(r2) <- names(r)
  terra::time(r2) <- terra::time(r)
  part <- paste0(dest, ".part")
  writeRaster(r2, part, filetype = "GTiff", datatype = "FLT4S", overwrite = TRUE)
  chk <- rast(part)
  if (nlyr(chk) != nlyr(r) || !identical(names(chk), names(r))) { unlink(part); stop("check failed for ", f) }
  stopifnot(file.rename(part, dest))
  cat("converted:", f, "\n")
}
cat("DONE\n")
