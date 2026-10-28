# Uploads the finished EBV netCDF cubes to the GEOBON S3 bucket with s5cmd ----------------
#
# Run it only after the checks 06-1 / 07-1 are clean.
# s5cmd cp OVERWRITES existing objects with the same key. Use dry_run <- TRUE first (only prints what
# would be copied), no_clobber <- TRUE skips objects that already exist in the bucket.
# Needs s5cmd (and the S3 credentials/endpoint configured for s5cmd) on the machine where this runs.

# settings ---------------------------------------------------------------------

nc_dir <- "T:/Hauer_BMIP_data/GEOBON_uploading/nc_files"      # local cubes (T: = mounted share)
bucket <- "s3://eco-code/BMIP_data"

dry_run    <- TRUE     # TRUE = only list what would be uploaded
no_clobber <- FALSE    # TRUE = do not replace objects that already exist

regions <- c("Europe", "Australia", "Finland", "USA")          # which regions to upload
methods <- c("monthly_1km", "daily_10km", "annual_bioclim_1km", "annual_bioclim_10km")

# folder name of each region in the bucket (as used in the previous upload)
target_folder <- c(Europe = "Europe", Australia = "Australia", USA = "US_birds", Finland = "Finnish_plants")


# upload -----------------------------------------------------------------------

if (Sys.which("s5cmd") == "") stop("s5cmd not found on the PATH")

jobs <- expand.grid(region = regions, method = methods, stringsAsFactors = FALSE)
jobs$file   <- file.path(nc_dir, paste0(jobs$region, "-", jobs$method, ".nc"))
jobs$target <- paste0(bucket, "/", target_folder[jobs$region], "/envdat/clim/")

missing <- jobs$file[!file.exists(jobs$file)]
if (length(missing)) stop("cube(s) not found:\n", paste(missing, collapse = "\n"))

for (i in seq_len(nrow(jobs))) {
  args <- c(if (dry_run) "--dry-run", "cp", if (no_clobber) "--no-clobber", jobs$file[i], jobs$target[i])
  cat("s5cmd", paste(args, collapse = " "), "\n")
  status <- system2("s5cmd", args)
  if (status != 0) stop("upload failed for ", jobs$file[i], " (exit status ", status, ")")
}
cat(if (dry_run) "Dry run finished - nothing uploaded.\n" else "Upload finished.\n")