# CHELSA climate data pipeline for BMIP

Processing of the CHELSA V2.1 daily global climate data (1941–2024) into regional products for the BMIP regions (Australia, Europe, USA, Finland), including quality control and the creation of the EBV netCDF cubes.

## Disclaimer

After the first draft of the pipeline and scripts, the scripts were optimized (runtime/memory) and the pipeline restructured with the help of AI and checks were included on the go (Claude, Sonnet 5.5). Additionally, AI was used to summarize the workflow and generate this README.md as well as INFO_netCDF_data.md.

------------------------------------------------------------------------

## 1. Products

| Product (`method`) | Content | Resolution | Time axis |
|------------------|------------------|------------------|------------------|
| `monthly_1km` | monthly mean (tas, tasmin, tasmax, rsds, hurs) or sum (prec) | 1 km | 12 layers per year |
| `daily_10km` | daily values | 10 km (average of 1 km) | 365/366 layers per year |
| `annual_bioclim_1km` | 19 bioclimatic variables (`bio1`…`bio19`) from the monthly prec/tasmin/tasmax | 1 km | 1 file per year |
| `annual_bioclim_10km` | the same, 1 km averaged to 10 km (`gdalwarp`, average) | 10 km | 1 file per year |

Variables: `prec`, `tas`, `tasmin`, `tasmax`, `rsds`, `hurs`. Years: 1941–2024. Regions use the folder names `Australian_reptiles_mammals`, `European_aquatic_invert`, `Finnish_plants`, `US_birds`. The "Australia" region is a small oval in NE Queensland, not the whole continent. Each region has its own mask (`mask_files/`) and cells outside the mask are NA.

Result layout (`<BMIP>` = the project directory, called `transfer_dir` in the scripts):

```         
<BMIP>/GEOBON_results/<region folder>/envdat/clim/monthly_1km/<variable>/<year>.tif
<BMIP>/GEOBON_results/<region folder>/envdat/clim/daily_10km/<variable>/<year>.tif
<BMIP>/GEOBON_results/<region folder>/envdat/clim/annual_bioclim_1km/<year>.tif
<BMIP>/GEOBON_results/<region folder>/envdat/clim/annual_bioclim_10km/<year>.tif
<BMIP>/GEOBON_uploading/{json_files,nc_files,logs}      # EBV netCDF cubes
<BMIP>/processing_scripts/                              # all scripts, logs/, array_prep_*/, qc_*/
```

Every layer carries its date (`terra::time`); the daily files must have exactly 365/366 layers so that all days stay aligned.

------------------------------------------------------------------------

## 2. Scripts

All scripts are in `processing_scripts/`. Paths are currently set at the top of the scripts (`transfer_dir`, `scratch_root`, the cluster paths in the `submit_*.sh` files, mail addresses) and have to be adapted for another cluster. The `*_potsdam.sh` submit script shows the Apptainer variant.

### 2.1 Climate variables (monthly_1km + daily_10km)

| Script | Purpose |
|------------------------------------|------------------------------------|
| `00_prepare_year_tasks.R` (`submit_00_prepare_year.sh`) | Creates the task table (one row = one variable × one year), the mask metadata and `config.rds` with all parameters (variables, years, plausible ranges, QC thresholds). **Rerun it after every parameter change**, otherwise the tasks use the old config. |
| `01_process_year_task.R` (`submit_01_year_array.sh`) | One SLURM array task = one variable × one year for all regions: downloads the daily files to scratch, tests each file, computes `monthly_1km` and `daily_10km`, writes the yearly files as `.part`, checks and renames them, deletes the raw files, writes the QC tables. Optional second argument/`TEST_OUT_DIR`: **test mode**, everything is written to the test folder and existing results are never touched. |
| `chelsa_pipeline_functions.R` | Shared functions, mainly `fetch_and_check()` (download, size, checksum, value range, constant file, implausible maximum). |
| `convert_hurs_to_percent.R` | One-off: converts existing hurs result files from a fraction (0–1) to percent; input is not modified, output goes to a separate folder. |
| `summarize_year_qc.R` | Collects the QC tables of all tasks into `flagged_days.csv` and `months_not_regular.csv` (the documentation of flagged days and incomplete months). |

### 2.2 Bioclims

| Script | Purpose |
|------------------------------------|------------------------------------|
| `02_prepare_bioclim_1km_tasks.R` (`submit_02_prepare_bioclim.sh`) | Task table of all region × year combinations for the 1 km bioclims. Optional: `force_years`, test output folder, input override (to use recomputed monthly files). |
| `03_process_bioclim_1km_task.R` (`submit_03_bioclim_array.sh`) | One task = one region × year: reads the monthly prec/tasmin/tasmax, converts Kelvin to °C, computes the 19 bioclims with `predicts::bcvars`. |
| `04_prepare_bioclim_10km_tasks.R` (`submit_04_prepare_bioclim_10km.sh`), `05_process_bioclim_10km_tasks.R` (`submit_05_bioclim_10km_array.sh`) | 10 km bioclims = `gdalwarp` average of the 1 km bioclims. The result is written as `.part` and renamed after the checks. |

The bioclims of a year depend on **all 12 months of that year** (`monthly_1km`). After a year of `prec`, `tasmin` or `tasmax` has been recomputed, its bioclims (1 km, then 10 km) must be recomputed too.

### 2.3 Check scripts

| Script | Purpose |
|------------------------------------|------------------------------------|
| `01-1_check_results_stats.R` (`submit_check_results_stats.sh`) | Step 1 of the result check: reads every file once (SLURM array, chunks) and writes per-file/per-layer statistics (`files_*.csv`, `layers_*.csv`). Only `monthly_1km` and `daily_10km`. |
| `01-2_check_results_summary.R` | Step 2: all checks from the statistics (see §4). Optionally merges the statistics of an older state (files that were not recomputed). |
| `01-3_compare_result_stats.R` | Step 3 (optional): which layers changed between two result folders? Expected: only the updated variables/years. |
| `05-1_check_bioclims.R` | Checks the bioclim files (1 km and 10 km) for chosen years, see §4. |
| `06-1_check_ebv_netcdf_monthly_daily.R` | Checks the monthly_1km/daily_10km netCDF cubes against the source tifs (metrics, time axis, geometry, values, empty days). |
| `07-1_check_ebv_netcdf_bioclim.R` | Checks the bioclim netCDF cubes against the source tifs. |

### 2.4 EBV netCDF cubes

| Script | Purpose |
|------------------------------------|------------------------------------|
| `06_create_monthly-daily-ebvcube_netCDF-files.R` | One cube per region × method (`monthly_1km`, `daily_10km`), one metric per variable. |
| `07_create_bioclims-ebvcube_netCDF-files.R` | One cube per region × bioclim method, one metric per `bio` variable, one time step per year. |

| `08_upload_to_GEOBON_server.R` \| Uploads the finished cubes to the GEOBON S3 bucket with `s5cmd cp` (dry run by default, see §6). \|

Both `06_` and `07_` create the cubes from scratch (`ebv_add_data` does not overwrite existing time steps). Existing `.nc` files are moved to `GEOBON_uploading/nc_files_old_<timestamp>/` first. The metadata come from `GEOBON_uploading/json_files/<region>-<method>.json` (exact file name). Both check each tif before it is added (layer count, dates, layer names). `testing <- TRUE` builds one cube for two years into `nc_files_test`.

------------------------------------------------------------------------

## 3. Workflow and order

Everything runs as SLURM jobs on the HPC. Run the steps from `processing_scripts/` (`cd <BMIP>/processing_scripts`). Make sure to adapt file paths at the beginning of each script + SLURM settings before running the scripts.

1.  **Prepare.** Set the parameters in `00_prepare_year_tasks.R` (variables, years, `force`, `sel_methods`, or `mode = "files_to_update"`) and run `sbatch submit_00_prepare_year.sh`. It prints the number of tasks.
2.  **Compute.** `sbatch --array=1-<n_tasks>%<parallel> submit_01_year_array.sh`. For a trial or recomputation use the test mode: `sbatch --export=ALL,TEST_OUT_DIR=<test_dir> --array=<ids> submit_01_year_array.sh`. Failed tasks: `sacct -j <jobid>` and the `.err/.out` files in `logs/`; resubmit only those IDs.
3.  **Result check** (see §4) on the test folder:
    1.  wait until no job is running (`squeue -u $USER`),
    2.  create a **fresh** stats folder with a **fixed file list**: `mkdir <stats>; find <results_dir> -name '*.tif' | sort > <stats>/filelist.txt`,
    3.  `sbatch --export=ALL,RESULTS_DIR=<results_dir>,STATS_DIR=<stats> submit_check_results_stats.sh` (array size = `N_CHUNKS`, default 40),
    4.  `Rscript summarize_year_qc.R <qc_dir>`,
    5.  `CHECK_VARS=prec,tas,tasmin,tasmax,rsds,hurs Rscript 01-2_check_results_summary.R <results_dir> <stats> <qc_dir> "" <old_stats>` (the empty fourth argument is `newer_than`; `<old_stats>` = statistics of the existing GEOBON_results for files that were not recomputed).
4.  **Copy** the verified results to `GEOBON_results` (see §6 for the rsync details), always with a backup.
5.  **Bioclims.** `submit_02_prepare_bioclim.sh` → `submit_03_bioclim_array.sh` (1 km) → `submit_04_prepare_bioclim_10km.sh` → `submit_05_bioclim_10km_array.sh` (10 km) → `05-1_check_bioclims.R` → copy.
6.  **netCDF cubes.** Only when all files in `GEOBON_results` are final: `06_…R` and `07_…R` (SLURM job, the number of cores is read from `SLURM_CPUS_PER_TASK`) → `06-1_check_ebv_netcdf_monthly_daily.R` → `07-1_check_ebv_netcdf_bioclim.R`.
7.  **Upload.** `08_upload_to_GEOBON_server.R`: first with `dry_run <- TRUE`, then for real. `s5cmd cp` overwrites existing files in the bucket without asking. You need to connect to the bucket first (see GEOBON organization for guideline)
8.  **Cleanup.** Raw downloads are deleted by the tasks. Keep the QC lists (`flagged_days.csv`, `months_not_regular.csv`) as documentation.

------------------------------------------------------------------------

## 4. Quality control: what is checked and when

### 4.1 During the computation (per daily file, in `01_process_year_task.R`)

| Check | Flag (`reason`) |
|------------------------------------|------------------------------------|
| download did not work after 3 tries | `download_failed` |
| file size / checksum differs from the server | `size_mismatch`, `checksum_error` |
| file cannot be read, all NA | `read_error`, `all_NA` |
| values outside the plausible range (`ranges` in `00_prepare_year_tasks.R`: temperature 180–345 K, rsds 0–1000) | `out_of_range` |
| NA fraction clearly above the median of the other days of the task (`max_na_excess` = 0.01) | `too_many_NA` |
| all values identical (max == min) | `constant_file` |
| global maximum below a minimum (`min_global_max`, rsds: 50 W/m²) | `implausible_max` |
| global mean below `ratio × median` of the task (`min_mean_ratio`, rsds: 0.3) | `implausible_low_mean` |

Flagged days become **empty (NA) layers** in `daily_10km` so that the days stay aligned, and are left out of the monthly values. If more than 20 % of the days of a task are flagged (`max_flagged_fraction`), the task aborts (server problem). The QC tables are `qc_days_<variable>_<year>.csv` and `qc_months_<variable>_<year>.csv`.

Monthly rules: temperature, rsds and hurs months are computed from the remaining days (`computed_from_remaining_days`); `NA_no_valid_day` if no day is left. A **prec** month with missing days is set to NA (`prec_incomplete_month_action = "NA"`), because it is a sum.

### 4.2 After the computation: `01-2_check_results_summary.R`

Run it on every new or changed set of results **before** copying to `GEOBON_results`.

-   **Completeness and format:** `missing_files` (grid of region × method × variable × year 1941:2024), `unreadable_files`, `bad_layer_count` (12 or 365/366), `bad_names_or_dates` (layer names/dates must match the calendar), `bad_geometry`, `bad_crs`.
-   **Values:** `na_deviations` (NA cells outside the mask), `range_violations`, `non_finite_values`, `constant_layers`, maxima per variable and method for a visual check.
-   **Consistency with the QC:** `empty_daily_not_flagged`, `flagged_but_layer_not_empty`, `empty_monthly_not_in_qc`, `qc_na_month_not_empty`, `empty_daily_not_in_all_regions`, `prec_month_vs_empty_days`.
-   **Plausibility of the data themselves:** `temp_order_violations` (tasmin ≤ tas ≤ tasmax), `monthly_vs_daily_mismatch`, `monthly_outliers` (robust z-score of regional monthly means), `daily_jumps` (day-to-day change of the regional mean), `size_outliers`, `leftover_part_files`.

Each finding with a count \> 0 writes a CSV into the output folder. Findings need an interpretation: some are properties of the source data (§5).

### 4.3 Bioclims: `05-1_check_bioclims.R`

Per region × year and method: missing files, leftover `.part` files, files older than the recomputation, unreadable files, layer count (19) and names, geometry against the mask, number of valid cells against the mask, plausible value ranges, equal means of the 1 km and 10 km files, files that are identical to the old ones, and a recomputation of the bioclims from the monthly files as a window check.

### 4.4 netCDF: `07-1_check_ebv_netcdf_bioclim.R` and `06-1_check_ebv_netcdf_monthly_daily.R`

Structure (19 metrics for bioclims, 6 metrics for monthly/daily, time axis; the empty 2025 step is accepted), geometry, and a value comparison with the tifs for selected years.

------------------------------------------------------------------------

## 5. Conspicuous days and files and how they were handled

### 5.1 Flagged days (excluded, empty layer in `daily_10km`)

Numbers from `excluded_days_list.csv` (years 1941–2024; 120 days in total, the same days are empty in all four regions):

| Variable | Reason | Days |
|------------------------|------------------------|------------------------|
| rsds | `constant_file` + `implausible_max` | 19 |
| rsds | `implausible_max` | 10 |
| rsds | `implausible_low_mean` | 5 |
| rsds | `out_of_range` | 3 |
| rsds | `checksum_error` | 2 |
| tasmax | `too_many_NA` | 12 |
| tasmax | `out_of_range` | 1 |
| tasmin | `too_many_NA` | 2 |
| tasmin | `out_of_range` | 1 |
| tas | `out_of_range` | 1 |
| hurs | `download_failed` | 61 (26 of them in 1979) |
| prec, tasmax, tasmin | `download_failed` | 95 each, **all in 2025** – not part of the results and not in `excluded_days_list.csv` |

-   **rsds:** 39 days with a constant value (0/1), a tiny global mean or an implausible maximum are source-data errors. Handling: flagged, empty layer, month computed from the remaining days (31 rsds months). rsds was recomputed completely with these checks.
-   **hurs:** 61 days were missing on the server (1979: 26 days in all regions). One hurs month has no valid day (April 2007 missing on server, `NA_no_valid_day`, NA in all regions). March 1979 has 12 flagged days out of 31 and is computed from the remaining 19 days.
-   **hurs, implausible days:** the regional means dropped to ≈ 5 % in all four regions on 1952-07-31, 1954-11-24 and 1989-01-27 (neighbouring days 50–70 %). These are source errors. Handling: `min_mean_ratio$hurs = 0.3`; hurs 1952, 1954 and 1989 were recomputed, the three days are flagged and empty in `daily_10km` (hurs has 64 empty days: 61 not available – 1979: 26, April 2007: 30, 2019: 5 – and 3 implausible).
-   **prec 2025:** the 95 failed days are at the end of 2025 (about from 27 September); the source data of 2025 are incomplete. 2025 is only a prepared, **empty** time step in the netCDF cubes.

### 5.2 Not changed (properties of the source data or real events)

-   **Extreme precipitation:** monthly prec of NE Queensland in August 1998 and November 2010 (z ≈ 8) are real events.
-   **`temp_order_violations` (15):** tas, tasmin and tasmax are separate CHELSA products; occasional violations of tasmin ≤ tas ≤ tasmax are a property of the source data and were not corrected.
-   **`daily_jumps`:** the rsds jumps in Finland (≈ ±100 W/m² day to day) are natural variability of a small region. tasmin Europe 1957-03-17, tasmin USA 1950-01-25 and tasmax USA 2022-02-12 were looked at and accepted.
-   **Date errors in old files:** an old tasmin 1999 file had 366 layers (duplicated day) and tasmin 1972 had an empty day only in Australia. Both were recomputed; prec 2024 USA `daily_10km` too.

### 5.3 Units and value ranges

-   Temperature in **Kelvin** for `tas`, `tasmin`, `tasmax` (monthly and daily; the bioclims are in °C), prec in kg m-2 day-1 (monthly sum), rsds in W/m², hurs in percent (0–100). The raw hurs files declare `variable_unit=percent` but carry a scale factor of 0.001, so `terra` returns 0–1. The pipeline therefore multiplies hurs by 100 right after reading (`value_factor` in `00_prepare_year_tasks.R`, applied in `fetch_and_check()` and `01_process_year_task.R`); `ranges$hurs` is 0–100. Result files computed before this change are fractions and are converted once with `convert_hurs_to_percent.R` (skips files that are already percent).
-   The NoData value of the raw files is 65535.

------------------------------------------------------------------------

## 6. Practical notes

-   **Statistics for the result check.** Always create `<stats>/filelist.txt` first and use a **fresh** folder. If the file list changes while the array runs (a task is still writing), chunks overlap and files are counted twice. The summary stops with a message on duplicates. Make sure the cluster has the current versions of `01-1_check_results_stats.R` and `submit_check_results_stats.sh`.
-   **Old statistics.** The summary takes files that were not recomputed from `<old_stats>`. All `files_*.csv` and `layers_*.csv` in that folder are read; their keys (region, method, variable, year) must be unique.
-   **Copying to the share.** Check first with a dry run (`-n`): `rsync -avmn --inplace --backup --backup-dir=<backup outside GEOBON_results> --include='*/' --include='**/<variable>/*.tif' --exclude='*' <test_dir>/ <GEOBON_results>/`. `--inplace` avoids rename errors on the mounted share. With `--backup` the old file is copied, which is slow for large files; faster is to `mv` the files of the dry-run list into the backup folder first and run `rsync --inplace` without `--backup`. Put backup folders outside `GEOBON_results`: the netCDF scripts skip paths with `backup` or `_to_delete`, but the listing should stay clean. Large files (Europe/USA 1 km: ≈ 0.4–0.9 GB per year) take long over the mount; run in `tmux`.
-   **Upload.** `s5cmd cp` replaces an existing object with the same key; `--no-clobber` skips existing objects, `--dry-run` only lists. The target prefix per region is set in `08_upload_to_GEOBON_server.R` (it differs from the local region folder names for Europe and Australia).
-   **Test mode** for everything that recomputes existing files: results go to a test folder, the existing results are untouched, and they are copied only after the checks.
-   **Shell variables** (`$S`, `$H`, `$BK`) are lost in a new session. Check them with `echo` before a command that uses them.
-   **Deleting raw data.** Raw CHELSA downloads are deleted by the tasks. Larger raw archives: first save a file list or manifest, move them to `_to_delete/`, and delete them only after the results are verified and copied.

### Software versions (known problems)

-   R 4.5.1; ebvcube 0.5.3; rhdf5 2.54.1. terra 1.9.50 with GDAL 3.10.3 (cluster) and terra 1.8.60 with GDAL 3.11.0 (local).
-   **Reading zeros:** on the cluster, `ebv_read(..., type = "r")` returned NA for cells with value 0 although the netCDF contains the zeros (`type = "a"` gives them correctly). The cause was not clarified. The cubes themselves were verified, so do not use `type = "r"` on that terra/GDAL version for checks; `07-1_check_ebv_netcdf_bioclim.R` reads arrays.
-   Cubes created from the JSON files have the time axis defined there (currently up to 2025, one empty time step).

------------------------------------------------------------------------

## 7. Open items

-   Add the 2025 data once the source data are complete (the cubes already contain the empty 2025 time step).
-   Paths and mail addresses are deliberately set at the top of the scripts / `submit_*.sh` files, so that users look through the scripts before running them.
