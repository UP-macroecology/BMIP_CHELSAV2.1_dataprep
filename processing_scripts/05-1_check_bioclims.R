# ============================================================================= #
## Check of the recomputed bioclims (annual_bioclim_1km and annual_bioclim_10km)
#
# Usage:  Rscript 05-1_check_bioclims.R        (settings below; run it as a SLURM job, the
#                                         1 km Europe/USA rasters are large)
#
# Checks for every region x year in force_years and both methods:
#   1  missing_files          file does not exist in dir_new
#   2  leftover_part_files    *.part files left behind
#   3  not_recomputed         file is older than newer_than (was not recomputed)
#   4  unreadable_files       file cannot be read
#   5  bad_layer_count        not 19 layers
#   6  bad_layer_names        names differ from the reference names
#   7  bad_geometry           extent/resolution/CRS differs from the mask
#   8  valid_cells_vs_mask    number of valid cells deviates from the mask by more than tol_valid
#   9  range_violations       layer min/max outside the plausible range (ESTIMATES, see below)
#  10  identical_to_old       (optional) every layer is identical to the old file in dir_old,
#                            i.e. the file was NOT really recomputed from the new monthly data
#  11  mean_1km_vs_10km       layer mean of the 10 km file deviates from the 1 km file
#  12  window_recompute       (optional) bcvars() is run again on small windows of the monthly input
#                            files and compared with the stored file: proves that the file
#                            is based on the CURRENT monthly data
# Result: report CSVs + status_by_region_year.csv (ok / problem for every combination).
# UNTESTED - run it once on a single year first (set force_years to one year).
# ============================================================================= #

library(terra)
library(data.table)

## SETTINGS -----------------------------------------------------------------------------------
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
mask_dir     <- file.path(transfer_dir, "mask_files")

dir_new <- "/import/ecoc9/data-zurell/reeg/test_task"       # where the recomputed bioclims are
dir_old <- file.path(transfer_dir, "GEOBON_results")         # previous state; NULL = no comparison
# monthly_1km inputs for the window check, first folder with the file wins
monthly_dirs <- c(dir_new, dir_old)

force_years <- c(1945, 1949, 1955, 1956, 1965, 1966, 1972, 1979, 1980, 1981,
                 1985, 1989, 1993, 1998, 1999, 2007, 2008, 2020, 2022)
regions <- c("Australia", "Europe", "USA", "Finland")
region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)
methods <- c("annual_bioclim_1km", "annual_bioclim_10km")

newer_than      <- as.POSIXct("2026-10-21 00:00:00")   # files must have been written after this
do_compare_old  <- TRUE                                # check 10
do_window_check <- TRUE                                # check 12
n_windows       <- 2                                   # windows per region-year
window_cells    <- 60                                  # half window size in cells (1 km)
tol_window      <- 0.01                                # max abs difference (FLT4S rounding)
tol_valid       <- 0.005                               # relative deviation of the valid cell count
tol_scale       <- 0.005                               # 1 km vs 10 km: share of the layer's range

report_dir <- file.path(dir_new, "check_bioclim_report")
dir.create(report_dir, showWarnings = FALSE, recursive = TRUE)

# Plausible ranges per layer (ESTIMATES, generous; adjust after looking at the report)
ranges <- data.table(layer = 1:19, lo = c(-60, 0, 0, 0, -30, -90, 0, -90, -90, -90, -90,
                                          0, 0, 0, 0, 0, 0, 0, 0),
                     hi = c(40, 40, 100.5, 3500, 60, 40, 100, 50, 50, 50, 50,
                            15000, 4000, 1500, 400, 10000, 4000, 10000, 10000))

## HELPERS ------------------------------------------------------------------------------------
bio_path <- function(dir, region, method, yr) {
  file.path(dir, region_folder_names[[region]], "envdat", "clim", method, paste0(yr, ".tif"))
}
res_of <- function(method) ifelse(grepl("10km", method), "10km", "1km")   # vectorised

find_monthly <- function(region, var, yr) {
  for (d in monthly_dirs[!is.null(monthly_dirs)]) {
    p <- file.path(d, region_folder_names[[region]], "envdat", "clim", "monthly_1km", var, paste0(yr, ".tif"))
    if (file.exists(p)) return(p)
  }
  stop("no monthly_1km file for ", region, " ", var, " ", yr)
}

summary_rows <- list(); findings <- list()
finding <- function(name, dt, note = "") {
  n <- if (is.null(dt)) 0L else nrow(dt)
  f_out <- file.path(report_dir, paste0(name, ".csv"))
  if (file.exists(f_out)) file.remove(f_out)
  if (n > 0) { fwrite(dt, f_out); findings[[name]] <<- dt }
  summary_rows[[length(summary_rows) + 1]] <<- data.table(check = name, n_findings = n, note = note)
  cat(sprintf("%-26s %6d %s\n", name, n, if (n > 0) "<-- see report" else "ok"))
}

## MASKS --------------------------------------------------------------------------------------
masks <- list(); mask_valid <- list()
for (rg in regions) { masks[[rg]] <- list(); mask_valid[[rg]] <- list() }
for (res in c("1km", "10km")) {
  mf <- list.files(mask_dir, pattern = paste0(".*", res, "\\.tif$"), full.names = TRUE)
  mf <- mf[!grepl("EPSG4326", mf)]
  for (rg in regions) {
    f <- grep(rg, mf, value = TRUE)
    if (length(f) != 1) stop("no unique ", res, " mask for ", rg)
    masks[[rg]][[res]] <- terra::rast(f)[[1]]
    mask_valid[[rg]][[res]] <- terra::global(masks[[rg]][[res]], "notNA")$notNA
  }
}

## EXPECTED GRID + FILE LEVEL CHECKS -------------------------------------------------------------
cat("Checking", length(force_years), "years x", length(regions), "regions x", length(methods), "methods\n\n")
grid <- CJ(region = regions, method = methods, year = force_years)
grid[, path := mapply(bio_path, list(dir_new), region, method, year)]
grid[, exists := file.exists(path)]
grid[, mtime := file.mtime(path)]

finding("missing_files", grid[exists == FALSE, .(region, method, year, path)], "expected file not in dir_new")
part <- list.files(dir_new, pattern = "\\.part$", recursive = TRUE, full.names = TRUE)
finding("leftover_part_files", if (length(part)) data.table(path = part) else NULL)
finding("not_recomputed", grid[exists == TRUE & (is.na(mtime) | mtime < newer_than), .(region, method, year, mtime)],
        paste("file older than", format(newer_than)))

# reference layer names from the old state (any year that is not in force_years), else bio1..bio19
ref_names <- setNames(vector("list", length(methods)), methods)
for (me in methods) {
  ref <- NULL
  if (!is.null(dir_old)) {
    cand <- list.files(file.path(dir_old, region_folder_names[[regions[1]]], "envdat", "clim", me),
                       pattern = "\\.tif$", full.names = TRUE)
    cand <- cand[!as.integer(sub("\\.tif$", "", basename(cand))) %in% force_years]
    if (length(cand)) ref <- tryCatch(names(terra::rast(cand[1])), error = function(e) NULL)
  }
  ref_names[[me]] <- if (is.null(ref)) paste0("bio", 1:19) else ref
}

## PER FILE STATISTICS -------------------------------------------------------------------------
file_info <- list(); layer_info <- list()
for (i in which(grid$exists)) {
  rg <- grid$region[i]; me <- grid$method[i]; yr <- grid$year[i]
  cat(sprintf("[%s] %s %s %d\n", format(Sys.time(), "%H:%M:%S"), rg, me, yr)); flush(stdout())
  r <- tryCatch(terra::rast(grid$path[i]), error = function(e) NULL)
  if (is.null(r)) {
    file_info[[length(file_info) + 1]] <- data.table(region = rg, method = me, year = yr, read_ok = FALSE,
      nlyr = NA_integer_, names_ok = NA, geom_ok = NA)
    next
  }
  m <- masks[[rg]][[res_of(me)]]
  file_info[[length(file_info) + 1]] <- data.table(region = rg, method = me, year = yr, read_ok = TRUE,
    nlyr = terra::nlyr(r), names_ok = identical(names(r), ref_names[[me]]),
    geom_ok = isTRUE(terra::compareGeom(r, m, res = TRUE, stopOnError = FALSE)))
  g  <- terra::global(r, c("min", "max", "mean"), na.rm = TRUE)
  nv <- terra::global(r, "notNA")$notNA
  layer_info[[length(layer_info) + 1]] <- data.table(region = rg, method = me, year = yr,
    layer = seq_len(terra::nlyr(r)), name = names(r), min = g$min, max = g$max, mean = g$mean, n_valid = nv)
}
files  <- rbindlist(file_info)
layers <- rbindlist(layer_info)

finding("unreadable_files", files[read_ok == FALSE, .(region, method, year)])
finding("bad_layer_count", files[read_ok == TRUE & nlyr != 19, .(region, method, year, nlyr)])
finding("bad_layer_names", files[read_ok == TRUE & names_ok == FALSE, .(region, method, year)],
        "layer names differ from the reference")
finding("bad_geometry", files[read_ok == TRUE & geom_ok == FALSE, .(region, method, year)],
        "extent / resolution / CRS differs from the mask")

layers[, n_mask := mapply(function(rg, me) mask_valid[[rg]][[res_of(me)]], region, method)]
layers[, rel_dev := (n_valid - n_mask) / n_mask]
finding("valid_cells_vs_mask", layers[abs(rel_dev) > tol_valid, .(region, method, year, layer, name, n_valid, n_mask, rel_dev)],
        "valid cells deviate from the mask (bio15 is NaN where annual precipitation is 0)")

layers <- merge(layers, ranges, by = "layer", all.x = TRUE)
finding("range_violations", layers[is.finite(min) & (min < lo | max > hi), .(region, method, year, layer, name, min, max, lo, hi)],
        "outside the plausible range (estimates)")
finding("all_NA_layers", layers[n_valid == 0, .(region, method, year, layer, name)])

## 1 km vs 10 km ------------------------------------------------------------------------------
w <- dcast(layers[, .(region, year, layer, name, method = res_of(method), mean, lo, hi)],
           region + year + layer + name + lo + hi ~ method, value.var = "mean")
if (all(c("1km", "10km") %in% names(w))) {
  finding("mean_1km_vs_10km", w[is.finite(`1km`) & is.finite(`10km`) &
            abs(`1km` - `10km`) > tol_scale * (hi - lo),
            .(region, year, layer, name, mean_1km = `1km`, mean_10km = `10km`)],
          "layer means of 1 km and 10 km differ more than expected")
}

## COMPARISON WITH THE OLD FILES ---------------------------------------------------------------
if (do_compare_old && !is.null(dir_old)) {
  cmp <- list()
  for (i in which(grid$exists)) {
    rg <- grid$region[i]; me <- grid$method[i]; yr <- grid$year[i]
    p_old <- bio_path(dir_old, rg, me, yr)
    if (!file.exists(p_old)) next
    rn <- terra::rast(grid$path[i]); ro <- terra::rast(p_old)
    if (!isTRUE(terra::compareGeom(rn, ro, res = TRUE, stopOnError = FALSE))) next
    d <- terra::global(abs(rn - ro), c("max", "mean"), na.rm = TRUE)
    cmp[[length(cmp) + 1]] <- data.table(region = rg, method = me, year = yr, layer = seq_len(nrow(d)),
                                         max_abs_diff = d$max, mean_abs_diff = d$mean)
  }
  cmp <- rbindlist(cmp)
  if (nrow(cmp) > 0) {
    fwrite(cmp, file.path(report_dir, "changes_vs_old.csv"))
    finding("identical_to_old", cmp[, .(max_diff = max(max_abs_diff, na.rm = TRUE)), by = .(region, method, year)][max_diff == 0],
            "file identical to the old one: not recomputed from new monthly data?")
  }
}

## WINDOW RECOMPUTE ---------------------------------------------------------------------------
if (do_window_check) {
  wres <- list()
  for (rg in regions) for (yr in force_years) {
    p_bio <- bio_path(dir_new, rg, "annual_bioclim_1km", yr)
    if (!file.exists(p_bio)) next
    res <- tryCatch({
      bio <- terra::rast(p_bio)
      pr  <- terra::rast(find_monthly(rg, "prec", yr))
      tmn <- terra::rast(find_monthly(rg, "tasmin", yr))
      tmx <- terra::rast(find_monthly(rg, "tasmax", yr))
      set.seed(yr)
      for (k in seq_len(n_windows)) {
        s  <- terra::spatSample(masks[[rg]][["1km"]], 1, method = "random", na.rm = TRUE, cells = TRUE)
        xy <- terra::xyFromCell(bio, s[1, "cell"])
        hf <- window_cells * terra::res(bio)[1]
        e  <- terra::ext(xy[1] - hf, xy[1] + hf, xy[2] - hf, xy[2] + hf)
        bc <- predicts::bcvars(prec = terra::crop(pr, e),
                               tmin = terra::crop(tmn, e) - 273.15,
                               tmax = terra::crop(tmx, e) - 273.15)
        rf <- terra::crop(bio, e)
        dm <- terra::global(abs(bc - rf), "max", na.rm = TRUE)$max
        nm <- terra::global(is.na(bc) != is.na(rf), "sum", na.rm = TRUE)$sum
        wres[[length(wres) + 1]] <- data.table(region = rg, year = yr, window = k, layer = seq_along(dm),
                                               max_abs_diff = dm, na_mismatch = nm,
                                               x = xy[1], y = xy[2])
      }
    }, error = function(e) {
      wres[[length(wres) + 1]] <<- data.table(region = rg, year = yr, window = NA_integer_, layer = NA_integer_,
                                              max_abs_diff = Inf, na_mismatch = NA_real_, x = NA_real_, y = NA_real_)
      NULL
    })
  }
  wres <- rbindlist(wres, fill = TRUE)
  if (nrow(wres) > 0) {
    fwrite(wres, file.path(report_dir, "window_recompute_all.csv"))
    finding("window_recompute", wres[max_abs_diff > tol_window | (!is.na(na_mismatch) & na_mismatch > 0)],
            "bcvars() on the current monthly data differs from the stored file")
  }
}

## STATUS PER REGION x YEAR -------------------------------------------------------------------
keys <- rbindlist(lapply(findings, function(d) if (all(c("region", "year") %in% names(d))) unique(d[, .(region, year)])),
                  fill = TRUE)
status <- CJ(region = regions, year = force_years)
status[, problem := paste(region, year) %in% paste(keys$region, keys$year)]
fwrite(status, file.path(report_dir, "status_by_region_year.csv"))
fwrite(rbindlist(summary_rows), file.path(report_dir, "check_summary.csv"))

cat("\n", sum(!status$problem), "of", nrow(status), "region-year combinations without findings\n")
if (any(status$problem)) { cat("With findings:\n"); print(status[problem == TRUE]) }
cat("Report files in:", report_dir, "\n")
