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

# processed files 
file_dir <- file.path(transfer_dir, "GEOBON_results") # splits into regions next

# original chelsa files
chelsa_dir <- file.path(transfer_dir, "CHELSA_downloads")


# ## general output directory
# out_dir <- file.path(transfer_dir, "processing_extra_out") # it diversifies later in loop

## Set arguments ----
mthds <- c("monthly_1km")
n_cores <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK"))
region_folders_to_process <- c("European_aquatic_invert") #"Australian_reptiles_mammals", "Finnish_plants", "US_birds"
variables_to_process <- c("prec") #"hurs", "prec", "rsds", "tas", "tasmax", "tasmin"

# LIST ALL FILES  ---------------------------------------------------------


## processed files -----------------------------------------------

## list all files
processed_files <- list.files(file.path(file_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)
if(length(grep("tmp",processed_files ))>0){
  processed_files  <- processed_files [-grep("tmp",processed_files )]}

# create a data.frame with all files
df_processed_files <- stringr::str_split(processed_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_processed_files <- df_processed_files[, seq(ncol(df_processed_files) - 5,
                                               ncol(df_processed_files), 1)] 

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



## CHELSA files --------------------------------------------------

# list all files 
chelsa_files <- list.files(file.path(chelsa_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)
chelsa_files <- chelsa_files[-grep("hurs",chelsa_files)]
if(length(grep("tmp",chelsa_files ))>0){
  chelsa_files  <- chelsa_files [-grep("tmp",chelsa_files )]}

# create a data.frame with all files
df_chelsa_files <- stringr::str_split(chelsa_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_chelsa_files <- df_chelsa_files[, seq(ncol(df_chelsa_files) - 2, 
                                         ncol(df_chelsa_files), 1)] 

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

# EXTRACT CHELSA SCOFF per variable --------------------------------------------

# empty list
scoffs_chelsa <- list()

#  extract variable names from chelsa files
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

df_processed_files <- 
  df_processed_files %>% 
  filter(region_folder %in% region_folders_to_process, 
         variable %in% variables_to_process)


# PARALLELIZE --------------------------------------------------------

## split full data in even chunks to be send to the workers -----
l <- dim(df_processed_files)[1] # length of all processed files
x <- round(l/n_cores) # chunk size of tasks send to each worker
from <- seq(1,l,x)
to <- lead(from)-1
idx_df <- data.frame(from,to)
idx_df$to[n_cores] <- l

if (dim(idx_df)[1] > n_cores) {
  idx_df <- idx_df[-(n_cores + 1),]
}

# make cluster
cl <- makeCluster(n_cores)
registerDoParallel(cl)


## start parallel loop ----
foo <- foreach(i = 1:n_cores, 
               .packages = c("terra", "tidyverse"),
               .combine = c) %dopar% {
  
  # make chunk
  df_processed_sub <- df_processed_files %>% 
    slice(idx_df$from[i]:idx_df$to[i])
  
  cat("\nWorker", i, "processing", nrow(df_processed_sub), 
      "files from", nrow(df_processed_files), "total files...\n")


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
    
    file_to_check = rast(file_path_j)
    if(datatype(file_to_check)=="FLT4S" & scoff(file_to_check)[1] == 0.1){
    # create tmp file path
    tmp_path <- gsub(basename(file_path_j), 
                     paste0("tmp_", basename(file_path_j)),
                     file_path_j)
    
    # rename original file into temporary file name
    file.rename(file_path_j, tmp_path)
    
    # read in tmp file
    r_processed <- terra::rast(tmp_path)
    
    # apply scoff from CHELSA
    #terra::scoff(r_processed) <- scoff_j
    
    
    # write back to original file name, but set new scoff
    terra::writeRaster(r_processed, file_path_j, overwrite = TRUE,
                       # expliciltly set scoff values when writing to file again!!
                       scale  = 1, 
                       offset = 0)
    
    # delete temporary file
    file.remove(tmp_path)
    }
    
  } # close loop over files
} # close parallel loop
  
  
  






# # TESTING -----------------------------------------------------------------
# 
# 
# # extract single file path
# file_path_j <- df_processed_files$full_path[1]
# 
# # variable and scoff extraction
# var_j <- df_processed_files$variable[1]
# scoff_j <- scoffs_chelsa[[var_j]]
# 
# # create tmp file
# tmp_path <- gsub(basename(file_path_j), 
#                  paste0("tmp_", basename(file_path_j)),
#                  file_path_j)
# 
# file.rename(file_path_j, tmp_path)
# 
# # read  single file
# r_processed <- terra::rast(tmp_path)
# 
# # see scoff
# scoff(r_processed)[1,]
# 
# # apply scoff chelsa
# scoff(r_processed) <- scoff_j
# 
# 
# # Write new raster to original filename
# writeRaster(
#   r_processed,
#   file_path_j,
#   overwrite = TRUE,
#   scale  = scoff_j[, 1],
#   offset = scoff_j[, 2]
# )
# 
# # Remove backup
# if (file.exists(file_path_j)) {
#   file.remove(tmp_path)
# }
# 
# # Verify file existance and scoff set
# r_new <- rast(file_path_j)
# scoff_new <- scoff(r_new)
# 
# cat("Original file now has scoff:\n")
# print(scoff_new)
# cat("Backup file exists:", file.exists(tmp_path), "\n")
