# BMIP CHELSA bioclimatic variables ------------------------------------------
#
# Creates EBV cubes (netCDF) for the methods annual_bioclim_1km and annual_bioclim_10km
# with the R package ebvcube (https://github.com/EBVcube/ebvcube).
#
# - One cube per region x method (e.g. "USA-annual_bioclim_10km.nc"), one time step per year,
#   one metric per bioclim variable (bio1 ... bio19).
# - The metadata/structure come from .json files created on the EBV portal, named exactly
#   like the cubes: "<region>-<method>.json".
# - Monthly/daily climate has its own script (06_create_monthly-daily-ebvcube_netCDF-files.R).
#
# Rebuild logic: existing .nc files are MOVED into a backup folder
# (GEOBON_uploading/nc_files_old_<timestamp>) and the cubes are created from scratch,
# because ebv_add_data() does not overwrite existing time steps.

# libraries -----------------------------------------------------------------

library(ebvcube)
library(terra)
library(data.table)
library(purrr)
library(future)
library(furrr)


# settings ------------------------------------------------------------------

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
setwd(transfer_dir)

# TRUE: only the first cube, years 1941-1942, written to GEOBON_uploading/nc_files_test
testing <- FALSE

results_dir <- "GEOBON_results"
json_dir    <- "GEOBON_uploading/json_files"
nc_dir      <- if (testing) "GEOBON_uploading/nc_files_test" else "GEOBON_uploading/nc_files"
log_dir     <- "GEOBON_uploading/logs"

region_folder_names <- c(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)

methods      <- c("annual_bioclim_1km", "annual_bioclim_10km")
filter_years <- if (testing) 1941:1942 else 1941:2024
n_bioclim    <- 19L   # layers per file (bio1 ... bio19)

# fill value from the CF convention for floats (NA in all cubes)
fv <- 9.9692099683868690e+36

run_stamp <- format(Sys.time(), "%Y-%m-%d_%H%M")


# helper functions ----------------------------------------------------------

log_msg <- function(file, ...) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "|", ..., "\n", file = file, append = TRUE)
}

extract_raster_meta <- function(r_file) {
  r <- terra::rast(r_file)
  crs_info <- terra::crs(r, describe = TRUE)

  if (!is.na(crs_info$code) && identical(crs_info$authority, "EPSG")) {
    epsg <- as.numeric(crs_info$code)
  } else {
    name <- sub('.*PROJCRS\\["([^"]+)".*', "\\1", terra::crs(r))
    esri_lookup <- c("USA_Contiguous_Albers_Equal_Area_Conic" = "ESRI:102003")
    if (!name %in% names(esri_lookup)) stop("No EPSG or known ESRI match for CRS: ", name)
    epsg <- esri_lookup[[name]]
  }
  list(extent = terra::ext(r)[1:4], epsg = epsg, resolution = terra::res(r))
}

move_to_backup <- function(path, backup_dir) {
  dir.create(backup_dir, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(backup_dir, basename(path))
  if (!file.rename(path, target)) {
    stopifnot(file.copy(path, target))
    unlink(path)
  }
  invisible(target)
}


# list the result files -------------------------------------------------------
# layout: <results_dir>/<region_folder>/envdat/clim/<method>/<year>.tif

tifs <- list.files(results_dir, pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)
tifs <- tifs[!grepl("backup|_to_delete", tifs)]

files <- data.table(full_path = tifs)
files[, `:=`(
  year          = suppressWarnings(as.integer(sub("\\.tif$", "", basename(full_path)))),
  method        = basename(dirname(full_path)),
  region_folder = basename(dirname(dirname(dirname(dirname(full_path)))))
)]
files[, region := names(region_folder_names)[match(region_folder, region_folder_names)]]
files <- files[!is.na(region) & !is.na(year) & method %in% methods & year %in% filter_years]

stopifnot(nrow(files) > 0)
if (anyDuplicated(files, by = c("region", "method", "year")) > 0) {
  stop("Some region/method/year combinations exist more than once: ",
       paste(head(files[duplicated(files, by = c("region", "method", "year")), full_path]), collapse = ", "))
}

overview <- files[, .(n_files = .N), by = .(region, method)][order(region, method)]
overview[, complete := n_files == length(filter_years)]
print(overview)
if (!all(overview$complete)) warning("Not all region/method combinations have all years!")

files[, chunk := paste(region, method, sep = "-")]
setorder(files, chunk, year)
ebv_chunks <- split(files, by = "chunk", keep.by = FALSE)
if (testing) ebv_chunks <- ebv_chunks[1]

cat("Building ebvcubes for:\n", paste(" -", names(ebv_chunks), collapse = "\n"), "\n")


# create empty netCDFs ------------------------------------------------------------

dir.create(nc_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
nc_backup_dir <- file.path(dirname(nc_dir), paste0("nc_files_old_", run_stamp))

json_files <- list.files(json_dir, pattern = "\\.json$", full.names = TRUE)
nc_paths   <- setNames(file.path(nc_dir, paste0(names(ebv_chunks), ".nc")), names(ebv_chunks))

for (name in names(ebv_chunks)) {
  json <- json_files[basename(json_files) == paste0(name, ".json")]
  if (length(json) != 1) stop("Expected exactly one json file named ", name, ".json in ", json_dir)

  if (file.exists(nc_paths[[name]])) {
    move_to_backup(nc_paths[[name]], nc_backup_dir)
    cat("Old netCDF moved to", nc_backup_dir, ":", basename(nc_paths[[name]]), "\n")
  }

  meta <- extract_raster_meta(ebv_chunks[[name]]$full_path[1])
  ebv_create(jsonpath = json, outputpath = nc_paths[[name]],
             entities = "None",
             fillvalue = fv,
             epsg = meta$epsg, extent = meta$extent, resolution = meta$resolution,
             prec = "float", overwrite = FALSE, verbose = FALSE)
  cat("Created:", nc_paths[[name]], "| json:", json, "\n")
}


# add the data (parallel over cubes) ------------------------------------------

n_cores <- suppressWarnings(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK")))
if (is.na(n_cores)) n_cores <- 2L
n_cores <- min(n_cores, length(ebv_chunks))
cat("Parallel processing on", n_cores, "cores\n")
future::plan(multisession, workers = n_cores)

future_iwalk(ebv_chunks, function(df, name) {

  logfile <- file.path(log_dir, paste0(name, "_", run_stamp, ".log"))
  new_nc  <- nc_paths[[name]]

  tryCatch({
    # metrics: variable code is written in () in the metric name (e.g. "bio1")
    metrics <- ebv_datacubepaths(new_nc, verbose = FALSE)
    metrics$var_code  <- sub("\\).*", "", sub(".*\\(", "", metrics$metric_names))
    metrics$bio_num   <- suppressWarnings(as.integer(gsub("\\D", "", metrics$var_code)))
    metrics$metric_no <- suppressWarnings(as.integer(sub(".*metric_(\\d+)/.*", "\\1", metrics$datacubepaths)))

    if (anyNA(metrics$bio_num) || anyDuplicated(metrics$bio_num) ||
        anyNA(metrics$metric_no) || anyDuplicated(metrics$metric_no)) {
      stop("cannot map metric codes to bio numbers in ", name, ": ",
           paste(metrics$var_code, collapse = ", "))
    }
    log_msg(logfile, "Chunk", name, "- metrics:", paste(metrics$var_code, collapse = ", "))

    # time axis of the cube (one step per year)
    cube_dates <- as.character(ebv_properties(new_nc, verbose = FALSE)@temporal$dates)

    for (i in seq_len(nrow(df))) {
      tif <- df$full_path[i]
      yr  <- df$year[i]
      log_msg(logfile, "Start year", yr, "(", i, "of", nrow(df), ") -", tif)

      r <- terra::rast(tif)
      layer_names <- names(r)
      bio_nums <- suppressWarnings(as.integer(gsub("\\D", "", layer_names)))
      if (terra::nlyr(r) != n_bioclim || anyNA(bio_nums) || anyDuplicated(bio_nums)) {
        stop("unexpected layers in ", tif, ": ", paste(layer_names, collapse = ", "))
      }

      this_timestep <- which(format(as.Date(cube_dates), "%Y") == as.character(yr))
      if (length(this_timestep) != 1) {
        stop("year ", yr, " not found on the time axis of ", name,
             " (range ", min(cube_dates), " to ", max(cube_dates), ")")
      }

      for (lyr in seq_len(terra::nlyr(r))) {
        metric_row <- which(metrics$bio_num == bio_nums[lyr])
        if (length(metric_row) != 1) {
          stop("no unique metric for layer '", layer_names[lyr], "' in ", name)
        }
        ebv_add_data(filepath_nc = new_nc,
                     metric   = metrics$metric_no[metric_row],
                     entity   = 1,
                     timestep = this_timestep,
                     data     = tif,
                     band     = lyr,
                     verbose  = FALSE)
      }
      log_msg(logfile, "Done year", yr)
    }
    log_msg(logfile, "Done chunk:", name)
  }, error = function(e) {
    log_msg(logfile, "ERROR:", conditionMessage(e))
    stop(e)
  })
}, .options = furrr_options(packages = c("ebvcube", "terra"), seed = NULL, scheduling = Inf))

future::plan(sequential)
cat("FINISHED BIOCLIM NETCDF CREATION\n")


# quick check (run by hand) -----------------------------------------------------
# nc <- nc_paths[[1]]
# dc <- ebv_datacubepaths(nc, verbose = FALSE); dc
# ebv_properties(nc, verbose = FALSE)@temporal$dates
# d <- ebv_read(nc, dc[1, 1], entity = 1, timestep = 1, type = "r")
# r <- terra::rast(ebv_chunks[[1]]$full_path[1]); global(d, "mean", na.rm = TRUE); global(r[[1]], "mean", na.rm = TRUE)
