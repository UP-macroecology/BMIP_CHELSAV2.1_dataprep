library(dplyr)
library(stringr)
library(tidyverse)
library(data.table)


# 1 SET UP ---------------------------------------------------------------------
  
  ## directories -------
## general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
# transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
# transfer_dir <- "//mnt/local_chelsa02" testing on Linux local mount

## specify input directories
# mask_dir <- file.path(transfer_dir, "mask_files") 
file_dir <- file.path(transfer_dir, "CHELSA_downloads") # splits into regions next

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
df_all_files <- df_all_files[, seq(ncol(df_all_files)-2, ncol(df_all_files), 1)] 

# set column names
names(df_all_files) <- c("variable", "year", "file_name")

# extract year and region information, store as column
df_all_files <- df_all_files %>% 
  mutate(
    name_parts = stringr::str_split(file_name, "_", simplify = TRUE),
    day = name_parts[, 3],
    month = name_parts[, 4]
    ) %>% 
  select(-name_parts)

# extract full path information
df_all_files$full_path <- all_files

# extract file size
df_all_files$file_size <- file.size(all_files)


# define thresholds per variable
thresh_mb <- tibble(
  variable = c("pr", "prec", "rsds", "tas", "tasmax", "tasmin"),
  #thresh   = c(70, 70, 325, 135, 135, 135) # initial
  thresh   = c(70, 50, 250, 100, 100, 100) # after single file check-ups
)

# assign correct threshold to each file
df_all_files <- df_all_files %>%
  left_join(thresh_mb, by = "variable") %>%
  mutate(thresh_bytes = thresh * 1e6)

# define "bad" files (per variable threshold)
df_small_files <- df_all_files %>%
  filter(file_size < thresh_bytes) %>%
  select(variable, year, file_name, full_path, file_size)

# save as object
saveRDS(df_small_files, file = file.path(out_dir, "corrupt_chelsa_files.rds"))

# save as table
df_all_files %>%
  filter(file_size < thresh_bytes) %>%
  mutate(file_size_MB = file_size/1e6)%>%
  select(variable, year, file_name, file_size_MB) %>%
fwrite(file = file.path(out_dir, "corrupt_chelsa_files.txt"), sep = "\t")

# overview of bad files
overview <- df_small_files %>% 
  count(variable, year, name = "n_small_files")

overview_list <- df_all_files %>% 
  count(variable, year, name = "total_files") %>% 
  left_join(overview, by = c("variable", "year")) %>% 
  group_by(variable) %>% 
  group_split() %>% 
  set_names(unique(df_all_files$variable))



# Log-File -----------------------
cat("=== CHELSA DOWNLOADS FILE INVENTORY LOG ===\n")
cat("All files:", nrow(df_all_files), "\n")
cat("\nBAD FILES:", nrow(df_small_files), "\n\n")

# variables
for(var_name in names(overview_list)) {
  d <- overview_list[[var_name]]
  # keep only rows where n_small_files ≠ total_files
  d_filt <- d %>% 
    filter(n_small_files != total_files)
  
  if (nrow(d_filt) > 0) {
    cat("=== VARIABLE:", var_name, "===\n")
    print(d_filt, n = Inf)
    cat("\n")
  }
  # else skip: no “incomplete” years for this var
}
cat("\n=========================================\n")


# DELETE FILES ------------------------

files_to_delete <- df_small_files$full_path

if (length(files_to_delete) > 0) {
  cat("Deleting", length(files_to_delete), "files\n")
  file.remove(files_to_delete)
} else {
  cat("No files to delete\n")
}




