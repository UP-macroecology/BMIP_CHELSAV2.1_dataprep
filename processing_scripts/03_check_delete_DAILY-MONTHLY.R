library(dplyr)
library(stringr)
library(tidyverse)


# 1 SET UP ---------------------------------------------------------------------

## directories -------
## general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
# transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
# transfer_dir <- "//mnt/local_chelsa02" testing on Linux local mount

## specify input directories
# mask_dir <- file.path(transfer_dir, "mask_files") 
file_dir <- file.path(transfer_dir, "GEOBON_results") # splits into regions next

## general output directory
out_dir <- file.path(transfer_dir, "processing_extra_out") # it diversifies later in loop



# list all files ------------------------------
all_files <- list.files(file.path(file_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)

# create a data.frame with all files
df_all_files <- stringr::str_split(all_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_all_files <- df_all_files[, seq(ncol(df_all_files)-5, ncol(df_all_files), 1)] 

# set column names
names(df_all_files) <- c("region_folder", "type", "sphere", 
                         "method", "variable","file")

# extract year and region information, store as column
df_all_files <- df_all_files %>% 
  mutate(year = gsub(".tif", "", file))

# extract full path information
df_all_files$full_path <- all_files

# SELECT FILES TO DELETE -----------------------

# the methods we are interested in
# unique(df_all_files$method)  # if all methods should be checked or to check for names
methods <- c("daily_10km", "monthly_1km") 

# retrieve information about deleted initial chelsa files
df_deleted_chelsa <- readRDS(file.path(out_dir, "corrupt_chelsa_files.rds"))

# extract distinct combinations of year~variable that have been deleted in script 02
df_year_vars_to_delete <- df_deleted_chelsa %>% 
  distinct(variable, year)

# join with all files and keep only the variable/year pairs that exist in deleted_chelsa
df_files_to_delete <- df_all_files %>%
  inner_join(df_year_vars_to_delete, by = c("variable", "year")) %>%
  filter(method %in% methods)

# extract the file paths (per region, method, variable, year)
df_files_to_delete %>% 
  select(region_folder, method, variable, year, full_path)

# store object 
saveRDS(df_files_to_delete, file.path(out_dir, "corrupt_monthly-daily_files.rds"))


# overview of bad files
overview <- df_files_to_delete %>% 
  count(variable, region_folder, method, name = "n_corrupt_files")

overview_list <- df_all_files %>% 
  count(variable, region_folder, method, name = "total_files") %>% 
  left_join(overview, by = c("variable", "region_folder", "method")) %>% 
  group_by(variable) %>% 
  group_split() %>% 
  set_names(unique(df_all_files$variable))

# Log-File -----------------------
cat("=== MONTHLY DAILY INVENTORY LOG ===\n")
cat("All files:", nrow(df_all_files), "\n")
cat("\nFILES TO DELETE:", nrow(df_files_to_delete), "\n\n")

# variables
for(var_name in names(overview_list)) {
  d <- overview_list[[var_name]]
  # keep only rows where n_small_files ≠ total_files
  d_filt <- d %>% 
    filter(n_corrupt_files != total_files)
  
  if (nrow(d_filt) > 0) {
    cat("=== VARIABLE:", var_name, "===\n")
    print(d_filt, n = Inf)
    cat("\n")
  }
  # else skip: no “incomplete” years for this var
}
cat("\n=========================================\n")


# DELETE FILES ------------------------

files_to_delete <- df_files_to_delete$full_path

if (length(files_to_delete) > 0) {
  cat("Deleting", length(files_to_delete), "files\n")
  file.remove(files_to_delete)
} else {
  cat("No files to delete\n")
}
