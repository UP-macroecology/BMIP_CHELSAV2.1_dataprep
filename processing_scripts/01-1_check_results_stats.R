# ============================================================================= #
## Result check, step 1: per-layer statistics of all monthly_1km / daily_10km files
#
# Usage:  Rscript 01-1_check_results_stats.R <results_dir> <stats_dir> <chunk_id> <n_chunks>
#   results_dir : folder that contains <region folder>/envdat/clim/<method>/<var>/<year>.tif
#                 (e.g. the test_task folder, or the old GEOBON_results for a comparison)
#   stats_dir   : output folder for the statistics (CSV files)
#   chunk_id, n_chunks : the file list is split into n_chunks parts (use as a SLURM array;
#                 for a quick trial use e.g. chunk 1 of 200)
#
# IMPORTANT: if <stats_dir>/filelist.txt exists, the files are taken from it. Create it ONCE
# before starting the array:  find <results_dir> -name '*.tif' | sort > <stats_dir>/filelist.txt
# Without it every array task lists the folder itself; if files are added/removed while the
# array runs (e.g. a task still writing results), the chunks shift and some files are
# processed twice and others not at all.
#
# For every file one row (files_<chunk>.csv: size, mtime, layer count, extent, resolution,
# CRS, read errors) and for every layer one row (layers_<chunk>.csv: number of NA cells, min,
# max, mean). For monthly_1km the statistics (min/max/mean/n_na_masked) are computed AFTER
# applying the region mask, because the monthly sum of prec is 0 (not NA) outside the mask;
# n_na is always the raw NA count of the file.
# Step 2 (01-2_check_results_summary.R) works only on these CSV files.
# ============================================================================= #

suppressPackageStartupMessages({
  library(terra)
  library(data.table)
})

args        <- commandArgs(trailingOnly = TRUE)
results_dir <- args[1]
stats_dir   <- args[2]
chunk_id    <- as.integer(args[3])
n_chunks    <- as.integer(args[4])
stopifnot(dir.exists(results_dir), !is.na(chunk_id), !is.na(n_chunks), chunk_id >= 1, chunk_id <= n_chunks)
dir.create(stats_dir, recursive = TRUE, showWarnings = FALSE)

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
task_dir     <- file.path(transfer_dir, "processing_scripts", "array_prep_year")
cfg  <- readRDS(file.path(task_dir, "config.rds"))
meta <- readRDS(file.path(task_dir, "region_masks_meta.rds"))
folder_to_region <- unlist(cfg$region_folder_names)    # named vector: region -> folder name

## -- file list of this chunk ---------------------------------------------------
fl <- file.path(stats_dir, "filelist.txt")
files <- if (file.exists(fl)) readLines(fl) else
  list.files(results_dir, pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)
files <- files[nzchar(files)]
p <- strsplit(files, "/")
info <- data.table(
  path   = files,
  year   = as.integer(sub("\\.tif$", "", vapply(p, function(x) x[length(x)], ""))),
  var    = vapply(p, function(x) x[length(x) - 1], ""),
  method = vapply(p, function(x) x[length(x) - 2], ""),
  folder = vapply(p, function(x) x[length(x) - 5], "")
)
info[, region := names(folder_to_region)[match(folder, folder_to_region)]]
info <- info[method %in% c("monthly_1km", "daily_10km") & !is.na(region) & !is.na(year)]
setorder(info, region, method, var, year)
info <- info[((seq_len(.N) - 1) %% n_chunks) == (chunk_id - 1)]
cat(sprintf("Chunk %d/%d: %d files\n", chunk_id, n_chunks, nrow(info)))

mask_cache <- new.env()
get_mask <- function(region, method) {
  key <- paste(region, method)
  if (is.null(mask_cache[[key]])) {
    res_name <- if (method == "monthly_1km") "1km" else "10km"
    mask_cache[[key]] <- terra::rast(meta[[region]][[res_name]]$laea)
  }
  mask_cache[[key]]
}

process_file <- function(f, region, method, var, yr) {
  fi <- list(path = f, region = region, method = method, variable = var, year = yr,
             size = file.size(f), mtime = format(file.mtime(f), "%Y-%m-%d %H:%M:%S"),
             read_ok = FALSE, error = NA_character_, nlyr = NA_integer_, ncell = NA_real_,
             xmin = NA_real_, xmax = NA_real_, ymin = NA_real_, ymax = NA_real_,
             resx = NA_real_, resy = NA_real_, crs = NA_character_, geom_matches_mask = NA)
  ly <- NULL
  tryCatch({
    r <- terra::rast(f)
    fi$nlyr <- terra::nlyr(r); fi$ncell <- terra::ncell(r)
    e <- as.vector(terra::ext(r))
    fi$xmin <- e[["xmin"]]; fi$xmax <- e[["xmax"]]; fi$ymin <- e[["ymin"]]; fi$ymax <- e[["ymax"]]
    fi$resx <- terra::res(r)[1]; fi$resy <- terra::res(r)[2]
    fi$crs  <- terra::crs(r, proj = TRUE)

    m <- get_mask(region, method)
    geom_ok <- terra::compareGeom(r, m, stopOnError = FALSE, crs = FALSE)
    fi$geom_matches_mask <- isTRUE(geom_ok)

    nm <- names(r)
    tm <- as.character(terra::time(r))
    if (length(tm) != length(nm)) tm <- rep(NA_character_, length(nm))
    n_na_raw <- terra::global(r, "isNA")[[1]]

    if (method == "monthly_1km" && isTRUE(geom_ok)) {
      rr <- terra::mask(r, m)          # statistics only inside the region mask
      n_na_masked <- terra::global(rr, "isNA")[[1]]
    } else {
      rr <- r
      n_na_masked <- n_na_raw
    }
    st <- terra::global(rr, c("min", "max", "mean"), na.rm = TRUE)

    ly <- data.table(region = region, method = method, variable = var, year = yr,
                     layer = seq_len(terra::nlyr(r)), name = nm, time = tm,
                     n_na = n_na_raw, n_na_masked = n_na_masked,
                     min = st$min, max = st$max, mean = st$mean)
    fi$read_ok <- TRUE
  }, error = function(e) fi$error <<- conditionMessage(e))
  list(file = as.data.table(fi), layers = ly)
}

out <- vector("list", nrow(info))
for (i in seq_len(nrow(info))) {
  out[[i]] <- process_file(info$path[i], info$region[i], info$method[i], info$var[i], info$year[i])
  if (i %% 10 == 0) { cat(sprintf("[%s] %d/%d\n", format(Sys.time(), "%H:%M:%S"), i, nrow(info))); flush(stdout()) }
  if (i %% 25 == 0) { terra::tmpFiles(remove = TRUE); gc() }
}

fwrite(rbindlist(lapply(out, `[[`, "file"), fill = TRUE),
       file.path(stats_dir, sprintf("files_%04d.csv", chunk_id)))
fwrite(rbindlist(lapply(out, `[[`, "layers"), fill = TRUE),
       file.path(stats_dir, sprintf("layers_%04d.csv", chunk_id)))
cat("Done.\n")
