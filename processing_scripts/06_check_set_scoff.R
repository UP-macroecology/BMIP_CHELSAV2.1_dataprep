library(dplyr)
library(terra)
library(stringr)
library(tidyverse)
library(doParallel)
library(foreach)

# 1 SET UP ---------------------------------------------------------------------

## directories -------
## general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
# transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
# transfer_dir <- "//mnt/local_chelsa02" testing on Linux local mount

## specify input directories
# mask_dir <- file.path(transfer_dir, "mask_files") 
file_dir <- file.path(transfer_dir, "GEOBON_results") # splits into regions next

chelsa_dir <- file.path(transfer_dir, "CHELSA_downloads")


## general output directory
out_dir <- file.path(transfer_dir, "processing_extra_out") # it diversifies later in loop

## Set arguments---
mthds <-c("daily_10km", "monthly_1km")
n_cores <- 15

# PROCESSED FILES -----------------------------------------------------------------------
## list all files
processed_files <- list.files(file.path(file_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)

# create a data.frame with all files
df_processed_files <- stringr::str_split(processed_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_processed_files <- df_processed_files[, seq(ncol(df_processed_files)-5, ncol(df_processed_files), 1)] 

# set column names
names(df_processed_files) <- c("region_folder", "type", "sphere", 
                         "method", "variable","file")

# extract year and region information, store as column
df_processed_files <- df_processed_files %>% 
  mutate(year = gsub(".tif", "", file))

# extract full path information
df_processed_files$full_path <- processed_files

# only keep those methods set in arguments
df_processed_files <- df_processed_files %>% 
  filter(method %in% mthds)



# CHELSA_Files ------------------------------------------------------------------------------

# list all files ------------------------------
chelsa_files <- list.files(file.path(chelsa_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)

# create a data.frame with all files
df_chelsa_files <- stringr::str_split(chelsa_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_chelsa_files <- df_chelsa_files[, seq(ncol(df_chelsa_files)-2, ncol(df_chelsa_files), 1)] 

# set column names
names(df_chelsa_files) <- c("variable", "year", "file_name")

# extract year and region information, store as column
df_chelsa_files <- df_chelsa_files %>% 
  mutate(
    name_parts = stringr::str_split(file_name, "_", simplify = TRUE),
    day = name_parts[, 3],
    month = name_parts[, 4]
  ) %>% 
  select(-name_parts)

# extract full path information
df_chelsa_files$full_path <- chelsa_files

# EXTRACT SCOFF per variable ---------------------------------------------------------------

# CHELSA -----------------
# empty list
scoffs_chelsa <- list()

#  extract variable names from chelsa
chelsa_vars <- unique(df_chelsa_files$variable)

# loop over variable name idents
for (i in seq_along(chelsa_vars)) {
  # extract first .tif file path per variable
  var_file <- df_chelsa_files %>% 
    filter(variable == chelsa_vars[i]) %>% 
    pull(full_path) %>% 
    first()
  
  # read in raster
  r_chelsa_var <- terra::rast(var_file)

  # extract scoff matrix and store in list
  scoffs_chelsa[[i]] <- scoff(r_chelsa_var)
  
  # set list entry name
  names(scoffs_chelsa)[[i]] <- chelsa_vars[i]
} # close loop over variables



# PARALLELIZE --------------------------------------------------------
## split full data in even chunks to be send to the workers -----
l <- dim(df_processed_files)[1] # length of all processed files
x <- round(l/n_cores) # chunk size of tasks send to each worker
from <- seq(1,l,x)
to <- lead(from)-1
idx_df <- data.frame(from,to)
idx_df$to[n_cores] <- l

if(dim(idx_df)[1] > n_cores)idx_df <- idx_df[-(n_cores+1),]


cl <- makeCluster(n_cores)
registerDoParallel(cl)

# idx_df

# start parallel loop
foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse"),.combine = c) %dopar% {
  
  # make chunk
  df_processed_sub <- df_processed_files %>% 
    slice(idx_df$from[i]:idx_df$to[i])
  
  cat("\nWorker", i, "processing", nrow(df_processed_sub), "files from", nrow(df_processed_files), "total files...\n")


  # loop  over each row in df_processed_sub
  for (j in seq_len(nrow(df_processed_sub))) {
    
    # extract variable name and full_path info
    var_j <- df_processed_sub$variable[j]
    file_path_j   <- df_processed_sub$full_path[j]
    
    # find matching CHELSA scoff by variable
    scoff_j <- scoffs_chelsa[[var_j]]
    
    if (is.null(scoff_j)) {
      cat("Worker", i, ": no CHELSA scoff for variable '", var_j,
          "'; skipping file: ", basename(file_path_j), "\n")
      next
    }
    
    # read in file
    r_processed <- terra::rast(file_path_j)
    
    # apply scoff from CHELSA
    terra::scoff(r_processed) <- scoff_j
    
    # write back to same file
    terra::writeRaster(r_processed, file_path_j, overwrite = TRUE,
                       # expliciltly set scoff values when writing to file again!!
                       scale  = scoff_j[, 1], 
                       offset = scoff_j[, 2])
  } # close loop over files
} # close parallel loop
  
  
  






# EXTRA -----
# # processed files -----------
# # empty list
# scoffs_processed <- list()
# 
# # extract variable and method names of processed files
# processed_vars <- unique(df_processed_files$variable)
# processed_mthds <- unique(df_processed_files$method)
# 
# # loop over methods
# for (i in seq_along(processed_mthds)) {
#   # filter for all files of that method
#   df_mthd_files <- df_processed_files %>% 
#     filter(method == processed_mthds[i]) 
#   
#   # create empty sublist
#   sublist <- list()
#   
#   # loop over variables in that method
#   for (j in seq_along(processed_vars)) {
#     # extract first .tif file  of variable~method combinations
#     var_file <- df_mthd_files %>% 
#       filter(variable == processed_vars[j]) %>% 
#       pull(full_path) %>% 
#       first()
#     
#     # read in raster
#     r_processed_var <- terra::rast(var_file)
#     
#     # extract scoff matrix and store in sublist
#     sublist[[j]] <- terra::scoff(r_processed_var[[1]])
#   
#     # set sublist name to variable name
#     names(sublist)[[j]] <- processed_vars[j]
#   } # close loop  over variables
#   
#   # add scoff matrix to final list of processed files
#   scoffs_processed[[i]] <- sublist
#   # set method as name of final list
#   names(scoffs_processed)[[i]] <- processed_mthds[i]
# } # close loop over methods













