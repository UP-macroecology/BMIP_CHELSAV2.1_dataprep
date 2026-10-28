# ============================================================================= #
## 5. One SLURM array task = ONE variable x ONE year (all regions)
#
# Usage:  Rscript 01_process_year_task.R <task_id> [test_out_dir]
#   With test_out_dir the task runs in TEST MODE: results and QC tables are
#   written there only; existing files in out_dir are never modified (they are
#   at most read, e.g. for partial months).
#   (task_id = SLURM_ARRAY_TASK_ID + TASK_OFFSET, computed by the submit script)
#
# Workflow
#   1. Download the daily files of the year (or of the selected months)
#      temporarily to scratch and test each one right away (size, checksum,
#      value range, NA fraction) -> fetch_and_check(). Suspicious days are
#      flagged and skipped by the task (replaces skip_files.rds).
#   2. Per month and region:
#        monthly_1km : crop -> project(average) -> mask -> sum (prec) / mean
#        daily_10km  : crop -> project(average) -> mask; flagged days get an
#                      EMPTY (NA) layer so that all days stay correctly aligned
#                      (365/366 layers)
#      The calculation itself is taken from 05_process_single_task_* and
#      05_process_single_daily10km_task.R, respectively.
#   3. Write the yearly files as .part, check them, then rename.
#   4. Delete the raw data (also on errors), write the QC tables.
#
# Results: <out_dir>/<region folder>/envdat/clim/{monthly_1km,daily_10km}/<var>/<year>.tif
# The methods (monthly_1km / daily_10km) come from the `methods` column of the task table.
# Partial months (files_to_update): only these months/layers are replaced, the
# rest of the existing yearly file is kept.
# ============================================================================= #

suppressPackageStartupMessages({
  library(terra)
  library(data.table)
  library(parallel)
})

args    <- commandArgs(trailingOnly = TRUE)
task_id <- as.integer(args[1])

transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
fun_file     <- file.path(transfer_dir, "processing_scripts", "chelsa_pipeline_functions.R")
task_dir     <- file.path(transfer_dir, "processing_scripts", "array_prep_year")
source(fun_file)

tasks             <- readRDS(file.path(task_dir, "tasks_todo.rds"))
region_masks_meta <- readRDS(file.path(task_dir, "region_masks_meta.rds"))
cfg               <- readRDS(file.path(task_dir, "config.rds"))

if (is.na(task_id) || task_id < 1 || task_id > nrow(tasks)) {
  stop("Invalid task_id (", task_id, ") for ", nrow(tasks), " tasks.")
}

# Test mode: cfg_in = real result folders (READ only), cfg = output target (WRITE)
cfg_in   <- cfg
test_dir <- if (length(args) >= 2 && nzchar(args[2])) args[2] else NA_character_
test_mode <- !is.na(test_dir)
if (test_mode) {
  dir.create(test_dir, recursive = TRUE, showWarnings = FALSE)
  test_dir <- normalizePath(test_dir)
  real_dir <- normalizePath(cfg_in$out_dir, mustWork = FALSE)
  if (startsWith(paste0(test_dir, "/"), paste0(real_dir, "/"))) {
    stop("test_out_dir must not be the real out_dir or a subfolder of it: ", test_dir)
  }
  cfg$out_dir <- test_dir
  cfg$qc_dir  <- file.path(test_dir, "qc")
  dir.create(cfg$qc_dir, recursive = TRUE, showWarnings = FALSE)
}

var_name <- tasks$variable[task_id]
yr       <- as.integer(tasks$year[task_id])
months   <- parse_months(tasks$months[task_id])
methods  <- if ("methods" %in% names(tasks)) strsplit(tasks$methods[task_id], ",")[[1]] else c("monthly_1km", "daily_10km")
do_monthly <- "monthly_1km" %in% methods
do_daily   <- "daily_10km"  %in% methods

log_msg <- function(msg) {
  cat(sprintf("[%s] Task %d (%s / %d): %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"), task_id, var_name, yr, msg))
  flush(stdout())
}

# Merge a QC table into an existing CSV (rows with the same key are replaced)
write_qc <- function(new, path, key) {
  if (file.exists(path)) {
    # Read text columns as character: fread would turn "date" into IDate, which does
    # not match the character column of the new table (rbind error)
    hdr <- names(fread(path, nrows = 0))
    old <- fread(path, colClasses = list(character = intersect(
      c("file", "date", "reason", "last_modified", "etag"), hdr)))
    old <- old[!(old[[key]] %in% new[[key]])]
    new <- rbind(old, new, fill = TRUE)
  }
  fwrite(new[order(new[[key]])], path)
}

# All work happens inside a function because on.exit() (cleanup of the scratch
# directory, also after errors) only works inside functions.
run_task <- function() {

  terraOptions(progress = 0)

  # Fixed directory name (no job ID) so that a restarted task can resume (see done markers below)
  work_dir <- file.path(cfg$scratch_root, sprintf("task_%s_%d%s", var_name, yr, if (test_mode) "_test" else ""))
  raw_dir  <- file.path(work_dir, "raw")
  res_dir  <- file.path(work_dir, "results")   # intermediate monthly files only
  for (d in c(raw_dir, res_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  # Raw data is ALWAYS deleted. After an ERROR the work directory with the finished monthly
  # intermediate files is kept (resume on the next start) and only deleted after success.
  # For a fresh start delete the folder by hand.
  ok <- FALSE
  on.exit({
    unlink(raw_dir, recursive = TRUE, force = TRUE)
    if (ok) unlink(work_dir, recursive = TRUE, force = TRUE)
    else message("Task failed - intermediate results kept in: ", work_dir)
  }, add = TRUE)

  if (test_mode) log_msg(paste("TEST MODE: writing to", test_dir, "- existing files in", cfg_in$out_dir, "are only read"))
  log_msg(sprintf("Started. Months: %s | Methods: %s | Scratch: %s", months_to_string(months), paste(methods, collapse = "+"), work_dir))

  all_days <- seq(as.Date(sprintf("%d-01-01", yr)), as.Date(sprintf("%d-12-31", yr)), by = "day")
  n_days_year <- length(all_days)
  day_month   <- as.integer(format(all_days, "%m"))

  ## -- Partial months only if the existing yearly files are consistent ---------
  if (!identical(months, 1:12)) {
    full_needed <- FALSE
    for (r in cfg$regions) {
      for (meth in methods) {
        f <- out_path(cfg_in, r, meth, var_name, yr)   # existing file (read only)
        expected <- if (meth == "monthly_1km") 12L else n_days_year
        n <- if (file.exists(f)) tryCatch(terra::nlyr(terra::rast(f)), error = function(e) NA_integer_) else NA_integer_
        if (is.na(n) || n != expected) {
          log_msg(sprintf("Existing file missing/inconsistent (%s %s: %s layers, expected %d) -> computing all 12 months",
                          r, meth, n, expected))
          full_needed <- TRUE
        }
      }
    }
    if (full_needed) months <- 1:12
  }
  full_year <- identical(months, 1:12)

  # Resume support: after each finished month a marker file is written into res_dir.
  # A restarted task skips these months (no download, no computation).
  done_marker <- function(m) file.path(res_dir, sprintf("month_%02d_%s.done", m, paste(methods, collapse = "+")))
  months_todo <- months[!file.exists(vapply(months, done_marker, ""))]
  if (length(months_todo) < length(months)) {
    log_msg(sprintf("RESUME: months already done: %s", months_to_string(setdiff(months, months_todo))))
  }

  ## -- Table of days -------------------------------------------------------------
  dt <- data.table(date = all_days[day_month %in% months_todo])
  dt[, `:=`(mnum = as.integer(format(date, "%m")),
            dd = format(date, "%d"), mm = format(date, "%m"))]
  dt[, file := sprintf("CHELSA_%s_%s_%s_%d_V.2.1.tif", var_name, dd, mm, yr)]
  dt[, url  := paste0(cfg$base_url, "chelsa/global/daily/", var_name, "/", yr, "/", file)]
  dt[, dest := file.path(raw_dir, file)]

  if (length(months_todo) > 0) {   # skipped if all months are already done

  ## -- 1. Download + test (parallel) ---------------------------------------------
  n_workers <- max(1L, min(cfg$max_parallel_downloads,
                           as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1"))))
  log_msg(sprintf("Downloading and testing %d daily files (%d in parallel)", nrow(dt), n_workers))

  worker_fun <- function(i, urls, dests, var, cfg) fetch_and_check(urls[i], dests[i], var, cfg)
  environment(worker_fun) <- globalenv()   # do not serialize large objects along with the function

  run_sequential <- function() {
    lapply(seq_len(nrow(dt)), worker_fun, urls = dt$url, dests = dt$dest, var = var_name, cfg = cfg)
  }

  chk <- NULL
  if (n_workers > 1) {
    # Worker output goes to worker_<var>_<year>.log (for debugging if a worker crashes)
    worker_log <- file.path(cfg$qc_dir, sprintf("worker_%s_%d.log", var_name, yr))
    chk <- tryCatch({
      cl <- makeCluster(n_workers, outfile = worker_log)
      on.exit(try(stopCluster(cl), silent = TRUE), add = TRUE)
      invisible(clusterCall(cl, function(f) { source(f); invisible(NULL) }, fun_file))
      res <- parLapplyLB(cl, seq_len(nrow(dt)), worker_fun,
                         urls = dt$url, dests = dt$dest, var = var_name, cfg = cfg)
      stopCluster(cl)
      res
    }, error = function(e) {
      log_msg(paste("Parallel processing failed:", conditionMessage(e),
                    "- details in", worker_log, "- continuing sequentially"))
      NULL
    })
  }
  if (is.null(chk)) chk <- run_sequential()
  chk <- rbindlist(chk, fill = TRUE)
  dt  <- cbind(dt, chk[, setdiff(names(chk), c("file", "dest")), with = FALSE])

  # NA fraction relative to the other days (the ocean is always NA, see cfg$max_na_excess)
  na_ref <- stats::median(dt[status == "ok", na_fraction], na.rm = TRUE)
  too_na <- dt$status == "ok" & is.finite(dt$na_fraction) & dt$na_fraction > na_ref + cfg$max_na_excess
  if (any(too_na)) {
    dt[too_na, `:=`(status = "flagged", reason = "too_many_NA")]
    unlink(dt$dest[too_na])
  }
  # Global mean clearly below the other days of the task (broken days inside the value range)
  ratio <- cfg$min_mean_ratio[[var_name]]
  if (!is.null(ratio)) {
    mean_ref <- stats::median(dt[status == "ok", mean_val], na.rm = TRUE)
    low_mean <- dt$status == "ok" & is.finite(dt$mean_val) & dt$mean_val < ratio * mean_ref
    if (any(low_mean)) {
      dt[low_mean, `:=`(status = "flagged", reason = "implausible_low_mean")]
      unlink(dt$dest[low_mean])
    }
  }
  dt[, good := status == "ok"]

  # Save QC immediately (even if the task aborts afterwards)
  qc_days <- copy(dt)[, .(file, date = as.character(date), month = mnum, variable = var_name, year = yr,
                          status, reason, attempts, size, content_length, last_modified, etag,
                          nodata_header, min_val, max_val, mean_val, na_fraction)]
  write_qc(qc_days, file.path(cfg$qc_dir, sprintf("qc_days_%s_%d.csv", var_name, yr)), "file")

  n_flag <- sum(!dt$good)
  log_msg(sprintf("Test finished: %d ok, %d flagged", sum(dt$good), n_flag))
  if (n_flag > 0) {
    print(dt[good == FALSE, .(file, reason)])
  }
  if (n_flag / nrow(dt) > cfg$max_flagged_fraction) {
    stop(sprintf("%.0f %% of the days flagged (limit %.0f %%) - probably a server/network problem, aborting.",
                 100 * n_flag / nrow(dt), 100 * cfg$max_flagged_fraction))
  }

  # NoData value: taken from the file headers (all files must agree)
  nd_vals <- unique(stats::na.omit(dt[good == TRUE, nodata_header]))
  if (length(nd_vals) > 1) {
    stop("Different NoData values in the headers: ", paste(nd_vals, collapse = ", "),
         " - please check (see qc_days_*.csv).")
  }
  nd_use <- if (length(nd_vals) == 1) nd_vals else cfg$raw_nodata_value
  log_msg(sprintf("NoData value (raw): %s", nd_use))

  ## -- Monthly quality (mainly prec: missing days distort the sum) ---------------
  qc_months <- dt[, .(n_days = .N, n_flagged = sum(!good), n_good = sum(good)), by = .(month = mnum)]
  qc_months[, `:=`(variable = var_name, year = yr)]
  qc_months[, monthly_action := fifelse(n_good == 0, "NA_no_valid_day",
                                fifelse(n_flagged > 0 & var_name == "prec" &
                                          cfg$prec_incomplete_month_action == "NA", "NA_prec_incomplete",
                                fifelse(n_flagged > 0, "computed_from_remaining_days", "ok")))]
  write_qc(qc_months, file.path(cfg$qc_dir, sprintf("qc_months_%s_%d.csv", var_name, yr)), "month")
  if (any(qc_months$n_good == 0)) log_msg("WARNING: at least one month without a valid day")

  ## -- 2. Computation per month and region ---------------------------------------
  for (m in months_todo) {

    sub    <- dt[mnum == m]
    good_f <- sub[good == TRUE, dest]
    n_good <- length(good_f)
    n_bad  <- nrow(sub) - n_good
    act    <- qc_months[month == m, monthly_action]
    log_msg(sprintf("Month %d: %d days, %d flagged (%s)", m, nrow(sub), n_bad, act))

    stk <- NULL
    if (n_good > 0) {
      stk <- terra::rast(good_f)
      terra::NAflag(stk) <- nd_use     # set on the RAW value, once for the whole stack
      vf <- cfg$value_factor[[var_name]]
      if (!is.null(vf)) stk <- stk * vf   # e.g. hurs: 0-1 -> percent (see 00_prepare_year_tasks.R)
    }

    for (region in cfg$regions) {

      m1  <- region_masks_meta[[region]][["1km"]]
      m10 <- region_masks_meta[[region]][["10km"]]

      ## monthly_1km -------------------------------------------------------------
      if (do_monthly) {
      mask1 <- terra::rast(m1$laea)
      if (act %in% c("NA_no_valid_day", "NA_prec_incomplete")) {
        month_final <- terra::init(terra::rast(mask1), NA)
      } else {
        crp <- terra::crop(stk, terra::rast(m1$e4326))
        eq  <- terra::project(crp, mask1, method = "average")
        msk <- terra::mask(eq, mask1)
        if (var_name %in% c("pr", "prec")) {
          month_final <- sum(msk, na.rm = TRUE)
        } else {
          month_final <- mean(msk, na.rm = TRUE)
        }
        rm(crp, eq, msk)
      }
      names(month_final) <- sprintf("%s_01_%02d_%d", var_name, m, yr)
      terra::time(month_final) <- as.Date(sprintf("%d-%02d-01", yr, m))
      terra::writeRaster(month_final, file.path(res_dir, sprintf("%s_monthly_%02d.tif", region, m)),
                         datatype = "FLT4S", overwrite = TRUE)
      rm(month_final, mask1)
      }

      ## daily_10km ----------------------------------------------------------------
      if (do_daily) {
      mask10 <- terra::rast(m10$laea)
      empty  <- terra::init(terra::rast(mask10), NA)
      if (n_good > 0) {
        crp <- terra::crop(stk, terra::rast(m10$e4326))
        eq  <- terra::project(crp, mask10, method = "average")
        msk <- terra::mask(eq, mask10)
        rm(crp, eq)
      }
      # flagged days receive an empty layer so that the days stay aligned
      lay <- vector("list", nrow(sub))
      k <- 0L
      for (i in seq_len(nrow(sub))) {
        if (sub$good[i]) { k <- k + 1L; lay[[i]] <- msk[[k]] } else lay[[i]] <- empty
      }
      daily_m <- terra::rast(lay)
      names(daily_m) <- sprintf("%s_%s_%s_%d", var_name, sub$dd, sub$mm, yr)
      terra::time(daily_m) <- sub$date
      terra::writeRaster(daily_m, file.path(res_dir, sprintf("%s_daily_%02d.tif", region, m)),
                         datatype = "FLT4S", overwrite = TRUE)
      rm(daily_m, lay, empty, mask10)
      if (exists("msk")) rm(msk)
      }
      gc()
    }

    rm(stk); gc()
    terra::tmpFiles(remove = TRUE)
    unlink(sub$dest)                     # delete the raw data of this month right away
    file.create(done_marker(m))          # month finished (resume marker)
    log_msg(sprintf("Month %d done", m))
  }

  }   # end of if (length(months_todo) > 0)

  ## -- 3. Assemble yearly files (.part -> check -> rename) -----------------------
  write_year_file <- function(layers, out_file, expected_n) {
    dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)
    part <- paste0(out_file, ".part")
    r <- layers   # is already a SpatRaster; terra::rast() on a SpatRaster would only copy the geometry without values
    terra::writeRaster(r, part, filetype = "GTiff", datatype = "FLT4S", overwrite = TRUE)
    n <- tryCatch(terra::nlyr(terra::rast(part)), error = function(e) NA_integer_)
    if (!file.exists(part) || file.size(part) == 0 || is.na(n) || n != expected_n) {
      unlink(part)
      stop("Output file is faulty (", n, " layers, expected ", expected_n, "): ", out_file)
    }
    if (!file.rename(part, out_file)) stop("file.rename failed: ", out_file)
    invisible(out_file)
  }

  for (region in cfg$regions) {

    ## monthly_1km
    if (do_monthly) {
    f_m <- out_path(cfg, region, "monthly_1km", var_name, yr)
    ex  <- if (!full_year) terra::rast(out_path(cfg_in, region, "monthly_1km", var_name, yr)) else NULL   # existing file (read only)
    lay <- lapply(1:12, function(mm) {
      if (mm %in% months) terra::rast(file.path(res_dir, sprintf("%s_monthly_%02d.tif", region, mm)))
      else ex[[mm]]
    })
    r_m <- terra::rast(lay)
    names(r_m) <- sprintf("%s_01_%02d_%d", var_name, 1:12, yr)
    terra::time(r_m) <- as.Date(sprintf("%d-%02d-01", yr, 1:12))
    write_year_file(r_m, f_m, 12L)
    rm(ex, lay, r_m)
    }

    ## daily_10km
    if (do_daily) {
    f_d <- out_path(cfg, region, "daily_10km", var_name, yr)
    ex  <- if (!full_year) terra::rast(out_path(cfg_in, region, "daily_10km", var_name, yr)) else NULL   # existing file (read only)
    lay <- lapply(1:12, function(mm) {
      if (mm %in% months) terra::rast(file.path(res_dir, sprintf("%s_daily_%02d.tif", region, mm)))
      else ex[[which(day_month == mm)]]
    })
    r_d <- terra::rast(lay)
    names(r_d) <- sprintf("%s_%s_%s_%d", var_name, format(all_days, "%d"), format(all_days, "%m"), yr)
    terra::time(r_d) <- all_days
    write_year_file(r_d, f_d, n_days_year)
    rm(ex, lay, r_d)
    }
    gc()

    log_msg(sprintf("Region %s written (%s)", region, paste(methods, collapse = " + ")))
  }

  ok <- TRUE
  log_msg("Task completed")
  invisible(TRUE)
}

run_task()
