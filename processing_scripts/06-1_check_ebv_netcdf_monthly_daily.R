# Checks the monthly_1km and daily_10km EBV netCDFs against the source tifs ----------
#
# For every cube (region x monthly_1km/daily_10km):
#   1. structure: the expected variables are the metrics of the cube (no missing, no extra ones);
#      the time axis equals the dates of all result tifs (1008 monthly / 30681 daily time steps)
#   2. spatial: extent and resolution of the cube equal those of the tif
#   3. content, for the checked years, all variables and a selection of layers:
#        - the cube layer is read back (as array) and compared with the tif layer:
#          number of NA cells and the sorted value distribution (max. absolute difference)
#        - EMPTY tif layers (excluded days) must be empty (all NA) in the cube as well
#      Positions of cells are NOT compared cell by cell (array orientation differs from terra;
#      ebv_read(type = "r") returned NA for cells with value 0 with terra 1.9.50 / GDAL 3.10.3).
#      Use a machine with a working terra/GDAL for a spatial spot check.
#
# Run it with Rscript, ideally as a SLURM job (reading the 1 km cubes is slow).
# Output: <out_dir>/ebv_check_monthly_daily_findings.csv and a summary on the screen.

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

methods   <- c("monthly_1km", "daily_10km")
variables <- c("prec", "tas", "tasmin", "tasmax", "rsds", "hurs")   # expected metrics of every cube
all_years <- 1941:2024

# Years compared layer by layer: first, last, every 10th and years with excluded days / recomputed years.
# Use `check_years <- all_years` for a complete (slow) comparison.
special_years <- c(1952, 1954, 1979, 1992, 1989, 2007, 1945, 1949, 1955, 1956, 1965, 1966, 1972, 1980, 1981, 1985, 1993, 1998, 1999, 2008, 2020, 2022)   # hurs/rsds/tas* days excluded; add recomputed years here
check_years   <- sort(unique(c(1941, 2024, seq(1945, 2020, by = 10), special_years)))

# daily cubes: every n-th day of a year is compared (plus all empty days); 1 = every day
daily_every <- 30
tol <- 1e-3   # allowed absolute difference (values are stored as float)

region_folder_names <- c(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds"
)


# helpers ---------------------------------------------------------------------

findings <- list()
add <- function(chunk, check, detail, variable = NA_character_, year = NA_integer_, layer = NA_integer_) {
  findings[[length(findings) + 1]] <<- data.table(chunk = chunk, check = check, variable = variable,
                                                  year = year, layer = layer, detail = detail)
}
var_code_of <- function(metric_names) sub("\\).*", "", sub(".*\\(", "", metric_names))


# loop over cubes -------------------------------------------------------------

for (reg in names(region_folder_names)) for (m in methods) {
  chunk <- paste(reg, m, sep = "-")
  nc <- file.path(nc_dir, paste0(chunk, ".nc"))
  cat("\n==", chunk, "\n")
  if (!file.exists(nc)) { add(chunk, "missing_nc", nc); next }

  tif_of <- function(v, y) file.path(results_dir, region_folder_names[[reg]], "envdat", "clim", m, v,
                                     paste0(y, ".tif"))

  # 1. structure -------------------------------------------------------------
  dc <- ebv_datacubepaths(nc, verbose = FALSE)
  dc$var_code <- var_code_of(dc$metric_names)
  if (length(setdiff(variables, dc$var_code)))
    add(chunk, "metric_missing", paste(setdiff(variables, dc$var_code), collapse = ","))
  if (length(setdiff(dc$var_code, variables)))
    add(chunk, "metric_unexpected", paste(setdiff(dc$var_code, variables), collapse = ","))
  vars_here <- intersect(variables, dc$var_code)

  # time axis against the dates of the tifs (variable prec as reference, all years)
  cube_dates <- as.character(as.Date(as.character(ebv_properties(nc, verbose = FALSE)@temporal$dates)))
  ref_var <- vars_here[1]
  tif_dates <- unlist(lapply(all_years, function(y) {
    f <- tif_of(ref_var, y)
    if (!file.exists(f)) { add(chunk, "missing_tif", f, ref_var, y); return(character(0)) }
    d <- time(rast(f))
    if (anyNA(d)) { add(chunk, "tif_without_dates", f, ref_var, y); return(character(0)) }
    as.character(as.Date(d))
  }))
  if (anyDuplicated(cube_dates)) add(chunk, "time_axis", "duplicated dates in the cube")
  not_in_cube <- setdiff(tif_dates, cube_dates)
  not_in_tif  <- setdiff(cube_dates, tif_dates)
  if (length(not_in_cube)) add(chunk, "time_axis", paste(length(not_in_cube), "tif dates missing in the cube, first:",
                                                         paste(head(not_in_cube, 3), collapse = ",")))
  if (length(not_in_tif))  add(chunk, "time_axis", paste(length(not_in_tif), "cube dates without tif, first:",
                                                         paste(head(sort(not_in_tif), 3), collapse = ",")))
  if (is.unsorted(as.Date(cube_dates))) add(chunk, "time_axis", "cube dates are not sorted")
  cat("  time steps in the cube:", length(cube_dates), "| tif dates:", length(tif_dates), "\n")

  # 2. spatial ---------------------------------------------------------------
  ref <- rast(tif_of(ref_var, check_years[1]))
  d0  <- ebv_read(nc, dc$datacubepaths[dc$var_code == ref_var], entity = 1, timestep = 1, type = "r", verbose = FALSE)
  if (!isTRUE(all.equal(as.vector(ext(d0)), as.vector(ext(ref)), tolerance = 1e-6)) ||
      !isTRUE(all.equal(res(d0), res(ref), tolerance = 1e-6))) {
    add(chunk, "geometry", paste("cube ext:", paste(round(as.vector(ext(d0)), 3), collapse = " "),
                                 "| tif ext:", paste(round(as.vector(ext(ref)), 3), collapse = " ")))
  }

  # 3. content ---------------------------------------------------------------
  for (v in vars_here) for (yr in check_years) {
    f <- tif_of(v, yr)
    if (!file.exists(f)) next
    r <- rast(f)
    d <- as.character(as.Date(time(r)))
    n_exp <- if (m == "monthly_1km") 12L else as.integer(as.Date(paste0(yr, "-12-31")) - as.Date(paste0(yr, "-01-01"))) + 1L
    if (nlyr(r) != n_exp || anyNA(d)) { add(chunk, "tif_layers", paste(nlyr(r), "layers, expected", n_exp), v, yr); next }

    ts_all <- match(d, cube_dates)
    if (anyNA(ts_all)) { add(chunk, "date_not_in_cube", paste(sum(is.na(ts_all)), "layers"), v, yr); next }

    # layers to compare: all (monthly) / every n-th day (daily) + all empty layers of the tif
    n_valid <- global(r, "notNA")$notNA
    empty   <- which(n_valid == 0)
    sel     <- if (m == "monthly_1km") seq_len(nlyr(r)) else union(seq(1, nlyr(r), by = daily_every), nlyr(r))
    sel     <- sort(union(sel, empty))
    row     <- which(dc$var_code == v)

    for (lyr in sel) {
      a <- as.vector(ebv_read(nc, dc$datacubepaths[row], entity = 1, timestep = ts_all[lyr],
                              type = "a", verbose = FALSE))
      a[!is.na(a) & abs(a) > 1e30] <- NA   # fill value -> NA
      b <- values(r[[lyr]], mat = FALSE)

      if (length(a) != length(b)) { add(chunk, "ncell", paste(length(a), "vs", length(b)), v, yr, lyr); next }
      if (lyr %in% empty) {
        if (!all(is.na(a))) add(chunk, "empty_day_not_empty", paste(d[lyr], ": excluded day has values in the cube"), v, yr, lyr)
        next
      }
      n_na_diff <- abs(sum(is.na(a)) - sum(is.na(b)))
      sa <- sort(a[!is.na(a)]); sb <- sort(b[!is.na(b)])
      mx <- if (length(sa) == length(sb) && length(sa) > 0) max(abs(sa - sb)) else NA_real_
      if (all(is.na(a)))        add(chunk, "cube_empty", paste(d[lyr], ": cube layer is all NA, tif has values"), v, yr, lyr)
      else if (n_na_diff > 0)   add(chunk, "na_count", paste(d[lyr], ": number of NA cells differs by", n_na_diff), v, yr, lyr)
      else if (!is.na(mx) && mx > tol) add(chunk, "values", paste(d[lyr], ": max abs diff", signif(mx, 3)), v, yr, lyr)
    }
    cat("  ", v, yr, ": compared", length(sel), "layers (", length(empty), "empty )\n")
  }
}


# result ----------------------------------------------------------------------

out <- if (length(findings)) rbindlist(findings) else
  data.table(chunk = character(), check = character(), variable = character(), year = integer(),
             layer = integer(), detail = character())
fwrite(out, file.path(out_dir, "ebv_check_monthly_daily_findings.csv"))

cat("\n===== SUMMARY =====\n")
if (nrow(out) == 0) {
  cat("No findings: structure, time axis, geometry and compared layers match the tifs.\n")
} else {
  print(out[, .N, by = .(chunk, check)][order(chunk, check)])
  cat("Details:", file.path(out_dir, "ebv_check_monthly_daily_findings.csv"), "\n")
}
cat("Years compared:", paste(check_years, collapse = ", "), "\n")
