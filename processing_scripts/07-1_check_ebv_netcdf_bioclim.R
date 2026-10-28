# Checks the bioclim EBV netCDFs against the source tifs in GEOBON_results ----------
#
# For every cube (region x annual_bioclim_1km/10km):
#   1. structure: number of metrics (19), time axis (all years, one step per year),
#      metric codes bio1..bio19
#   2. spatial: extent and resolution of the cube equal those of the tif
#   3. content: for the checked years and every bio layer, the cube values are read back
#      (as array) and compared with the tif: number of NA cells and the sorted value
#      distribution (max. absolute difference). Positions of cells are NOT compared cell by
#      cell - use ebv_read(type = "r") and a spot check on a machine with a working terra/GDAL.
#
# Run it with Rscript (or interactively). Output: <out_dir>/ebv_check_*.csv and a summary.
# Reading is the slow part - by default only a subset of years is compared (see check_years).

library(ebvcube)
library(terra)
library(data.table)

# settings ------------------------------------------------------------------

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
setwd(transfer_dir)

nc_dir      <- "GEOBON_uploading/nc_files"
results_dir <- "GEOBON_results"
out_dir     <- "GEOBON_uploading/nc_check"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

methods <- c("annual_bioclim_1km", "annual_bioclim_10km")
all_years <- 1941:2024

# years that are compared value by value: first, last, every 10th and the recomputed years.
# Use `check_years <- all_years` for a complete (slow) comparison.
recomputed_years <- c()   # <- add the 19 recomputed years here
check_years <- sort(unique(c(1941, 2024, seq(1945, 2020, by = 10), recomputed_years)))

tol <- 1e-3   # allowed absolute difference (values are stored as float)

region_folder_names <- c(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)


# helpers ---------------------------------------------------------------------

findings <- list()
add <- function(chunk, check, detail, year = NA, bio = NA) {
  findings[[length(findings) + 1]] <<- data.table(chunk = chunk, check = check, year = year,
                                                  bio = bio, detail = detail)
}
bio_of <- function(x) suppressWarnings(as.integer(gsub("\\D", "", x)))


# loop over cubes -------------------------------------------------------------

for (reg in names(region_folder_names)) for (m in methods) {
  chunk <- paste(reg, m, sep = "-")
  nc <- file.path(nc_dir, paste0(chunk, ".nc"))
  cat("\n==", chunk, "\n")

  if (!file.exists(nc)) { add(chunk, "missing_nc", nc); next }

  tif_dir <- file.path(results_dir, region_folder_names[[reg]], "envdat", "clim", m)
  tif_of  <- function(y) file.path(tif_dir, paste0(y, ".tif"))
  missing_tif <- all_years[!file.exists(tif_of(all_years))]
  if (length(missing_tif)) add(chunk, "missing_tif", paste(missing_tif, collapse = ","))

  # 1. structure -------------------------------------------------------------
  dc <- ebv_datacubepaths(nc, verbose = FALSE)
  dc$var_code <- sub("\\).*", "", sub(".*\\(", "", dc$metric_names))
  dc$bio_num  <- bio_of(dc$var_code)
  if (nrow(dc) != 19 || !setequal(dc$bio_num, 1:19)) {
    add(chunk, "metrics", paste("codes in cube:", paste(dc$var_code, collapse = ",")))
  }

  dates <- as.Date(as.character(ebv_properties(nc, verbose = FALSE)@temporal$dates))
  cube_years <- as.integer(format(dates, "%Y"))
  if (!identical(sort(cube_years), all_years)) {
    add(chunk, "time_axis", paste0("cube years: ", min(cube_years), "-", max(cube_years),
                                   " (n=", length(cube_years), "), expected ", length(all_years)))
  }

  # 2. spatial ---------------------------------------------------------------
  ref_year <- intersect(all_years, check_years)[1]
  ref <- rast(tif_of(ref_year))
  d0  <- ebv_read(nc, dc$datacubepaths[1], entity = 1, timestep = 1, type = "r", verbose = FALSE)
  if (!isTRUE(all.equal(as.vector(ext(d0)), as.vector(ext(ref)), tolerance = 1e-6)) ||
      !isTRUE(all.equal(res(d0), res(ref), tolerance = 1e-6))) {
    add(chunk, "geometry", paste("cube ext:", paste(round(as.vector(ext(d0)), 3), collapse = " "),
                                 "| tif ext:", paste(round(as.vector(ext(ref)), 3), collapse = " ")))
  }

  # 3. content ---------------------------------------------------------------
  for (yr in intersect(check_years, all_years)) {
    ts <- which(cube_years == yr)
    if (length(ts) != 1 || !file.exists(tif_of(yr))) next
    r <- rast(tif_of(yr))
    bn <- bio_of(names(r))

    for (lyr in seq_len(nlyr(r))) {
      row <- which(dc$bio_num == bn[lyr])
      if (length(row) != 1) { add(chunk, "no_metric", names(r)[lyr], yr, bn[lyr]); next }

      # read as ARRAY (rhdf5), not as SpatRaster: type = "r" returned NA for cells with value 0
      # on the cluster (terra 1.9.50 / GDAL 3.10.3), although the file contains the zeros.
      # The array orientation differs from terra, so values are compared sorted (counts of NA
      # and the complete value distribution), not cell by cell.
      a <- as.vector(ebv_read(nc, dc$datacubepaths[row], entity = 1, timestep = ts,
                              type = "a", verbose = FALSE))
      a[!is.na(a) & abs(a) > 1e30] <- NA   # fill value -> NA
      b <- values(r[[lyr]], mat = FALSE)

      n_na_diff <- abs(sum(is.na(a)) - sum(is.na(b)))
      sa <- sort(a[!is.na(a)]); sb <- sort(b[!is.na(b)])
      mx <- if (length(sa) == length(sb) && length(sa) > 0) max(abs(sa - sb)) else NA_real_

      if (length(a) != length(b)) {
        add(chunk, "ncell", paste(length(a), "vs", length(b)), yr, bn[lyr])
      } else if (all(is.na(a)) && !all(is.na(b))) {
        add(chunk, "cube_empty", "cube layer is all NA, tif has values", yr, bn[lyr])
      } else if (n_na_diff > 0) {
        add(chunk, "na_pattern", paste("number of NA cells differs by", n_na_diff), yr, bn[lyr])
      } else if (!is.na(mx) && mx > tol) {
        add(chunk, "values", paste("max abs diff", signif(mx, 3)), yr, bn[lyr])
      }
    }
    cat("  year", yr, "compared\n")
  }
}


# result ----------------------------------------------------------------------

res <- if (length(findings)) rbindlist(findings) else
  data.table(chunk = character(), check = character(), year = integer(), bio = integer(), detail = character())
fwrite(res, file.path(out_dir, "ebv_check_findings.csv"))

cat("\n===== SUMMARY =====\n")
if (nrow(res) == 0) {
  cat("No findings: structure, geometry and compared layers match the tifs.\n")
} else {
  print(res[, .N, by = .(chunk, check)][order(chunk, check)])
  cat("Details:", file.path(out_dir, "ebv_check_findings.csv"), "\n")
}
cat("Years compared:", paste(check_years, collapse = ", "), "\n")
