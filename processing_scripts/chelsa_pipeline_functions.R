# ============================================================================= #
## Shared functions of the variable x year pipeline
#
# Sourced by 00_prepare_year_tasks.R and 01_process_year_task.R (and by the
# PSOCK workers of a task).
#
#  - parse_months() / months_to_string() : month specifications ("1-3,7") <-> vector
#  - out_path()                          : path of a result file
#  - fetch_and_check()                   : download ONE daily file + test it
#                                          (file size, checksum, value range).
#                                          Suspicious files are flagged and
#                                          skipped by the task. This replaces
#                                          the former skip_files.rds.
# ============================================================================= #

parse_months <- function(x) {
  # "1-12", "3,4,7" or "1-3,7" -> sorted integer vector
  parts <- strsplit(gsub("\\s", "", as.character(x)), ",")[[1]]
  out <- unlist(lapply(parts, function(p) {
    if (grepl("-", p)) {
      ab <- as.integer(strsplit(p, "-")[[1]])
      seq(ab[1], ab[2])
    } else {
      as.integer(p)
    }
  }))
  sort(unique(out))
}

months_to_string <- function(m) paste(sort(unique(as.integer(m))), collapse = ",")

out_path <- function(cfg, region, method, var, yr) {
  file.path(cfg$out_dir, cfg$region_folder_names[[region]],
            "envdat", "clim", method, var, paste0(yr, ".tif"))
}


# ----------------------------------------------------------------------------- #
# Download one daily file + test it
#
# Returns a list with status ("ok" / "flagged"), reason and summary values.
# Reasons for flagging (several are joined with "+"):
#   download_failed, size_mismatch  : download failed / incomplete
#   checksum_error                  : gdalinfo -checksum reports an error
#   read_error                      : terra cannot read the file
#   all_NA                          : no valid pixels
#   out_of_range                    : min/max outside cfg$ranges[[var]]
#   constant_file                   : max == min (the whole global file has ONE value)
#   implausible_max                 : global maximum below cfg$min_global_max[[var]]
#                                     (e.g. rsds: a day without any sunlit area is impossible)
#   too_many_NA                     : (set in the task) NA fraction clearly above
#                                     the median of the days of the task
#   implausible_low_mean            : (set in the task) global mean below
#                                     cfg$min_mean_ratio[[var]] x median of the days of the task
# Flagged files are deleted, good files stay in dest.
# ----------------------------------------------------------------------------- #
fetch_and_check <- function(url, dest, var, cfg) {

  res <- list(file = basename(dest), dest = dest, status = "ok",
              reason = NA_character_, attempts = 0L,
              size = NA_real_, content_length = NA_real_,
              last_modified = NA_character_, etag = NA_character_,
              nodata_header = NA_real_,
              min_val = NA_real_, max_val = NA_real_, mean_val = NA_real_, na_fraction = NA_real_)

  last_hdr <- function(hdr, key) {
    l <- grep(paste0("^\\s*", key, ":"), hdr, ignore.case = TRUE, value = TRUE)
    if (length(l) == 0) return(NA_character_)
    trimws(sub(paste0("^\\s*", key, ":\\s*"), "", l[length(l)], ignore.case = TRUE))
  }

  flag <- function(res, reason) {
    res$status <- "flagged"
    res$reason <- reason
    if (file.exists(res$dest)) unlink(res$dest)
    res
  }

  ## 1. Download with retries; compare file size with Content-Length ----------
  ok <- FALSE
  dl_reason <- "download_failed"
  for (attempt in seq_len(cfg$download_tries)) {
    res$attempts <- attempt
    if (file.exists(dest)) unlink(dest)

    out <- suppressWarnings(system2(
      "wget", c("-S", "-q", "--timeout=120", "--tries=1",
                "-O", shQuote(dest), shQuote(url)),
      stdout = TRUE, stderr = TRUE))
    st <- attr(out, "status")
    if (is.null(st)) st <- 0L

    cl <- suppressWarnings(as.numeric(last_hdr(out, "Content-Length")))
    res$content_length <- cl
    res$last_modified  <- last_hdr(out, "Last-Modified")
    res$etag           <- last_hdr(out, "ETag")
    sz <- if (file.exists(dest)) file.size(dest) else NA_real_
    res$size <- sz

    if (st == 0 && !is.na(sz) && sz > 0) {
      if (is.na(cl) || sz == cl) {
        ok <- TRUE
        break
      }
      dl_reason <- "size_mismatch"
    } else {
      dl_reason <- "download_failed"
    }
    Sys.sleep(5 * attempt)
  }
  if (!ok) return(flag(res, dl_reason))

  ## 2. Checksum (detects decompression errors such as rsds 15.12.1990) -------
  gd <- suppressWarnings(system2("gdalinfo", c(shQuote(dest), "-checksum"),
                                 stdout = TRUE, stderr = TRUE))
  if (any(grepl("ERROR|Error", gd)) || !any(grepl("Checksum=", gd))) {
    return(flag(res, "checksum_error"))
  }

  ## 3. Value range and NA fraction (NoData fix applied to the RAW value) -----
  # Read the NoData value from the GDAL header of the file; only if there is
  # none, fall back to the default from the configuration (65535).
  nd_line <- grep("NoData Value=", gd, value = TRUE)
  nd_hdr <- if (length(nd_line) > 0) {
    suppressWarnings(as.numeric(sub(".*NoData Value=\\s*", "", nd_line[1])))
  } else NA_real_
  res$nodata_header <- nd_hdr
  nd_use <- if (is.finite(nd_hdr)) nd_hdr else cfg$raw_nodata_value

  chk <- tryCatch({
    r <- terra::rast(dest)
    terra::NAflag(r) <- nd_use
    vf <- cfg$value_factor[[var]]            # e.g. hurs: 0-1 -> percent
    if (!is.null(vf)) r <- r * vf
    rng <- terra::global(r, "range", na.rm = TRUE)
    nn  <- terra::global(r, "notNA")
    mn  <- terra::global(r, "mean", na.rm = TRUE)
    list(min = rng$min[1], max = rng$max[1], mean = mn$mean[1],
         na_frac = 1 - nn$notNA[1] / terra::ncell(r))
  }, error = function(e) NULL)

  if (is.null(chk)) return(flag(res, "read_error"))

  res$min_val     <- chk$min
  res$max_val     <- chk$max
  res$mean_val    <- chk$mean
  res$na_fraction <- chk$na_frac

  reasons <- character(0)
  if (!is.finite(chk$min) || !is.finite(chk$max)) {
    reasons <- c(reasons, "all_NA")
  } else {
    rg <- cfg$ranges[[var]]
    if (!is.null(rg) && (chk$min < rg[1] || chk$max > rg[2])) {
      reasons <- c(reasons, "out_of_range")
    }
    # A file with a single value for the whole globe is broken (real fields vary)
    if (chk$max == chk$min) reasons <- c(reasons, "constant_file")
    mx <- cfg$min_global_max[[var]]
    if (!is.null(mx) && chk$max < mx) reasons <- c(reasons, "implausible_max")
  }
  # The NA fraction is only returned here. CHELSA files are NoData over the
  # oceans, so a high NA fraction is normal. The comparison (too much NA
  # relative to the other days of the task) is done in 01_process_year_task.R.

  if (length(reasons) > 0) return(flag(res, paste(reasons, collapse = "+")))

  res
}
