# BMIP CHELSA climate variables ---------------------------------------------
#
# Creates EBV cubes (netCDF) for the climate methods monthly_1km and daily_10km
# with the R package ebvcube (https://github.com/EBVcube/ebvcube).
#
# - One cube per region x method (e.g. "USA-monthly_1km.nc").
# - The metadata/structure come from .json files created on the EBV portal. The files
#   must be named exactly like the cubes: "<region>-<method>.json".
# - Bioclims have their own script (07_create_bioclims-ebvcube_netCDF-files.R).
#
# Rebuild logic: existing .nc files are MOVED into a backup folder
# (GEOBON_uploading/nc_files_old_<timestamp>) and the cubes are created from scratch,
# because ebv_add_data() does not overwrite existing time steps.
#
# Run on the cluster with SLURM (one cube per core, max. one core per cube is used).

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

# folder names of the regions
region_folder_names <- c(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)

methods     <- c("monthly_1km", "daily_10km")
filter_vars <- c("prec", "tas", "tasmin", "tasmax", "rsds", "hurs")   
filter_years <- if (testing) 1941:1942 else 1941:2024

# fill value from the CF convention for floats (NA in all cubes)
fv <- 9.9692099683868690e+36

run_stamp <- format(Sys.time(), "%Y-%m-%d_%H%M")


# helper functions ----------------------------------------------------------

log_msg <- function(file, ...) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "|", ..., "\n", file = file, append = TRUE)
}

# number of layers a result file must have
expected_layers <- function(method, year) {
  if (grepl("^monthly", method)) return(12L)
  as.integer(as.Date(paste0(year, "-12-31")) - as.Date(paste0(year, "-01-01"))) + 1L
}

# extent, resolution and EPSG code of a raster file
extract_raster_meta <- function(r_file) {
  r <- terra::rast(r_file)
  crs_info <- terra::crs(r, describe = TRUE)

  if (!is.na(crs_info$code) && identical(crs_info$authority, "EPSG")) {
    epsg <- as.numeric(crs_info$code)
  } else {
    # no EPSG code -> look up the projection name
    name <- sub('.*PROJCRS\\["([^"]+)".*', "\\1", terra::crs(r))
    esri_lookup <- c("USA_Contiguous_Albers_Equal_Area_Conic" = "ESRI:102003")
    if (!name %in% names(esri_lookup)) stop("No EPSG or known ESRI match for CRS: ", name)
    epsg <- esri_lookup[[name]]
  }
  list(extent = terra::ext(r)[1:4], epsg = epsg, resolution = terra::res(r))
}

# move a file to a backup folder (copy + delete if renaming fails, e.g. across file systems)
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
# layout: <results_dir>/<region_folder>/envdat/clim/<method>/<variable>/<year>.tif

tifs <- list.files(results_dir, pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)
tifs <- tifs[!grepl("backup|_to_delete", tifs)]

files <- data.table(full_path = tifs)
files[, `:=`(
  year          = suppressWarnings(as.integer(sub("\\.tif$", "", basename(full_path)))),
  variable      = basename(dirname(full_path)),
  method        = basename(dirname(dirname(full_path))),
  region_folder = basename(dirname(dirname(dirname(dirname(dirname(full_path))))))
)]
files[, region := names(region_folder_names)[match(region_folder, region_folder_names)]]
files <- files[!is.na(region) & !is.na(year) &
                 method %in% methods & variable %in% filter_vars & year %in% filter_years]

stopifnot(nrow(files) > 0)
if (anyDuplicated(files, by = c("region", "method", "variable", "year")) > 0) {
  stop("Some region/method/variable/year combinations exist more than once: ",
       paste(head(files[duplicated(files, by = c("region", "method", "variable", "year")), full_path]), collapse = ", "))
}

overview <- files[, .(n_files = .N), by = .(region, method, variable)][order(region, method, variable)]
overview[, complete := n_files == length(filter_years)]
print(overview, nrows = nrow(overview))
if (!all(overview$complete)) warning("Not all region/method/variable combinations have all years!")

# chunks: one cube per region x method
files[, chunk := paste(region, method, sep = "-")]
setorder(files, chunk, variable, year)
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
             entities = "None",            # no entities used
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
    # metrics of the cube; the variable code is written in () in the metric name
    metrics <- ebv_datacubepaths(new_nc, verbose = FALSE)
    metrics$var_code  <- sub("\\).*", "", sub(".*\\(", "", metrics$metric_names))
    metrics$metric_no <- suppressWarnings(as.integer(sub(".*metric_(\\d+)/.*", "\\1", metrics$datacubepaths)))
    metrics$metric_no[is.na(metrics$metric_no)] <- which(is.na(metrics$metric_no))  # fallback: row number

    log_msg(logfile, "Chunk", name, "- metrics:", paste(metrics$var_code, collapse = ", "))

    for (v in unique(df$variable)) {
      metric_row <- which(metrics$var_code == v)
      if (length(metric_row) != 1) stop("no unique metric for variable ", v, " in ", name)

      sub <- df[df$variable == v, ]
      log_msg(logfile, "Start variable:", v, "-", nrow(sub), "years")

      for (k in seq_len(nrow(sub))) {
        tif <- sub$full_path[k]
        yr  <- sub$year[k]

        r <- terra::rast(tif)
        d <- as.Date(terra::time(r))

        # layers must have valid, unique dates inside the file's year and the right count
        if (anyNA(d) || length(d) != terra::nlyr(r) || anyDuplicated(d) ||
            terra::nlyr(r) != expected_layers(sub$method[k], yr) ||
            any(format(d, "%Y") != as.character(yr))) {
          stop("Layer/date check failed for ", tif)
        }

        ebv_add_data(filepath_nc = new_nc,
                     metric   = metrics$metric_no[metric_row],
                     entity   = 1,
                     timestep = as.character(d),     # ISO dates from the tif
                     data     = tif,
                     band     = seq_len(terra::nlyr(r)),
                     verbose  = FALSE)
        log_msg(logfile, v, yr, "added")
      }
      log_msg(logfile, "Done variable:", v)
    }
    log_msg(logfile, "Done chunk:", name)
  }, error = function(e) {
    log_msg(logfile, "ERROR:", conditionMessage(e))
    stop(e)
  })
}, .options = furrr_options(packages = c("ebvcube", "terra"), seed = NULL, scheduling = Inf))

future::plan(sequential)
cat("FINISHED MONTHLY/DAILY NETCDF CREATION\n")


# quick check (run by hand) -----------------------------------------------------
# nc <- nc_paths[[1]]
# dc <- ebv_datacubepaths(nc, verbose = FALSE); dc
# ebv_properties(nc, verbose = FALSE)@temporal$dates
# d <- ebv_read(nc, dc[1, 1], entity = 1, timestep = 1, type = "r")
# r <- terra::rast(ebv_chunks[[1]]$full_path[1]); global(d, "mean", na.rm = TRUE); global(r[[1]], "mean", na.rm = TRUE)
