# ============================================================================= #
## Result check, step 3 (optional): which layers changed between two result folders?
#
# Usage:  Rscript 01-3_compare_result_stats.R <stats_dir_new> <stats_dir_old> <out_dir>
# Both stats folders are produced by 01-1_check_results_stats.R (new = test_task, old = GEOBON_results
# BEFORE copying). Layers are matched by region, method, variable, year and layer index.
# Expected: differences only for the updated years/variables (files_to_update, reprocess list).
# ============================================================================= #
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly = TRUE)
rd <- function(d) rbindlist(lapply(list.files(d, "^layers_.*\\.csv$", full.names = TRUE), fread,
                                   colClasses = list(character = c("name", "time"))), fill = TRUE)
new <- rd(args[1]); old <- rd(args[2]); dir.create(args[3], showWarnings = FALSE, recursive = TRUE)
key <- c("region", "method", "variable", "year", "layer")
j <- merge(new[, c(key, "mean", "n_na_masked", "n_na"), with = FALSE],
           old[, c(key, "mean", "n_na_masked", "n_na"), with = FALSE], by = key, suffixes = c("_new", "_old"))
j[, `:=`(d_mean = mean_new - mean_old, d_na = n_na_masked_new - n_na_masked_old)]
per_file <- j[, .(n_layers = .N, n_changed = sum(abs(d_mean) > 1e-4 | d_na != 0, na.rm = TRUE),
                  max_abs_d_mean = max(abs(d_mean), na.rm = TRUE), max_abs_d_na = max(abs(d_na), na.rm = TRUE)),
              by = .(region, method, variable, year)]
fwrite(per_file[order(-n_changed)], file.path(args[3], "changes_per_file.csv"))
fwrite(per_file[n_changed > 0, .(n_files = .N, n_layers_changed = sum(n_changed)), by = .(variable, year)][order(variable, year)],
       file.path(args[3], "changes_per_variable_year.csv"))
only_new <- fsetdiff(unique(new[, ..key][, layer := NULL]), unique(old[, ..key][, layer := NULL]))
cat("Files compared:", nrow(per_file), "| with changes:", sum(per_file$n_changed > 0), "\n")
cat("Files only in the new results (not in the old):", nrow(only_new), "\n")
cat("Output in:", args[3], "\n")
