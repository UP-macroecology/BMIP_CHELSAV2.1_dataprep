library(terra)
library(gdalUtilities)
library(dismo)
library(doParallel)
library(foreach)
library(tidyverse)

# ==============================================================================
# BMIP - Processing Climate Data  

# Aim:            Calculating annual bioclimatic variables at 10km spatial resolution
# Input Data:     Annual Bioclim at 1km spat. res
# Pre-processing: Script "2_3_1_BIOCLIM_1.R"
# Regions:        For all BMIP regions: USA, Australia, Finnland and Europe.
# Resolution:     10 km 
# ==============================================================================


# 1 SET UP ---------------------------------------------------------------------

## directories -------
## general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
# transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
# transfer_dir <- "//mnt/local_chelsa02" testing on Linux local mount

## specify input directories
mask_dir <- file.path(transfer_dir, "mask_files") 
file_dir <- file.path(transfer_dir, "GEOBON_results") # splits into regions next

## general output directory
out_dir <- file.path(transfer_dir, "GEOBON_results") # it diversifies later in loop


## Define variables --------
resolution  <- 10   # 10km spatial resolution
regions     <- c("Australia", "Europe", "USA", "Finland")
method_name <- "annual_bioclim_10km" # the method used in this script
n_cores     <- 15 # number of cores to be used
# var_names   <- c("prec", "tasmin","tasmax") # only those needed for bioclim calc. -> using "prec" now
# clim_method <- "monthly_1km" # previous method used to process climate data

## match region folder names
region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds" 
)

## CRS Information --------
# define the Equal Area CRS used per region
equare_crs <- data.frame(Australia = "EPSG:9473",
                         Europe    = "EPSG:3035",
                         USA       = "ESRI:102003", 
                         Finland   = "EPSG:3035")

## List mask files  --------
# only filter for resolution, region filtering in loop
mask_files <- list.files(file.path(mask_dir), 
                         pattern = paste0(
                           #".*", region, # which region
                           ".*", resolution, # spatial resolution
                           "km\\.tif$"), full.names = TRUE)

# only select the LAEA masks
mask_files <- mask_files[-grep("EPSG4326", mask_files)]


# list all files ------------------------------
all_files <- list.files(file.path(file_dir), pattern = ".tif", 
                        full.names = TRUE, recursive = T)

# create a data.frame with all files
df_all_files <- stringr::str_split(all_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

# select necessary columns only
df_all_files <- df_all_files[,seq(ncol(df_all_files)-5,ncol(df_all_files),1)] 

# set column names
names(df_all_files) <- c("region_folder", "type", "sphere", 
                         "method", "variable","file")

# extract year and region information, store as column
df_all_files$year <- as.numeric(gsub("\\.tif$", "", df_all_files$file))
df_all_files$region <- names(region_folder_names)[match(df_all_files$region_folder,
                                                        region_folder_names)]
# extract full path information
df_all_files$full_path <- all_files  



# filter for available annual bioclims at 1km resolution ------
df_bioclims_1 <- df_all_files %>% 
  filter(method %in% "annual_bioclim_1km") %>% # "annual_bioclim_1km"
  # we drop the last column here, because the file path for bioclims does 
  # not include variables, but we have to rename to fix this. 
  dplyr::select(region_folder, type, sphere, method, variable, full_path) %>% 
  rename(file = variable) %>%   
  # Re-extract year and region information, set processed to TRUE
  mutate(year = as.numeric(gsub("\\.tif$", "", file)),  
         region = names(region_folder_names)[match(region_folder, 
                                                   region_folder_names)],
         bioclims_1_exist = TRUE)

cat("\nAll available 1km bioclim files.....")
print(df_bioclims_1 %>% 
        filter(bioclims_1_exist == TRUE) %>%
        group_by(region, method) %>%
        reframe(n.files = length(file)))



# filter for already processed output files ------
df_processed <- df_all_files %>% 
  filter(method %in% method_name) %>% # "annual_bioclim_10km"
  # we drop the last column here, because the file path for bioclims does 
  # not include variables, but we have to rename to fix this. 
  dplyr::select(region_folder, type, sphere, method, variable, full_path) %>% 
  rename(file = variable) %>%   
  # Re-extract year and region information, set processed to TRUE
  mutate(year = as.numeric(gsub("\\.tif$", "", file)),  
         region = names(region_folder_names)[match(region_folder, 
                                                   region_folder_names)],
         processed = TRUE)

cat("\nAll processed bioclim files.....")
print(df_processed %>% 
        filter(processed == TRUE) %>%
        group_by(region, method) %>%
        reframe(n.files = length(file)))


# Filter data to send to workers for Calculations --------------------
# filter for years that have not been processed already
df_years_to_process <- df_bioclims_1 %>%
  filter(!year %in% df_processed$year)

cat(paste("\nBioclim calculations at 10km missing for",
          length(unique(df_years_to_process$year)), "years.\n"))

# stop  workflow, if there are no years to process
if (nrow(df_years_to_process) == 0) stop("...No years to process!...")



## split grouped df in even chunks to be send to the workers -----
l <- nrow(df_years_to_process)  # total rows in df_years_to_process
x <- round(l / n_cores)      # chunk size per worker
from <- seq(1, l, x)         # start indices
to <- lead(from) - 1         # end indices
idx_df <- data.frame(from, to)
# Fix last chunk to include remaining rows
idx_df$to[n_cores] <- l
# Remove extra row if created
if(nrow(idx_df) > n_cores) {idx_df <- idx_df[-(n_cores+1), ]}


# create a list of chunks with tasks per worker
chunks <- lapply(1:n_cores, function(j) {
  from_j <- idx_df$from[j]
  to_j <- idx_df$to[j]
  df_years_to_process[from_j:to_j]
})


# make cluster
cl <- makeCluster(n_cores)
registerDoParallel(cl)


# start parallel processing -----------
foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse", "gdalUtilities"), .combine = combine) %dopar% {
  
  # subset to chunk i for worker i
  df_years_to_process_sub <- chunks[[i]]
  
  # loop over each row in subset -> i.e. single task
  for (j in 1:nrow(df_years_to_process_sub)) {
    
    # extract row values as task
    task <- df_years_to_process_sub[j, , drop = FALSE]
    
    # extract region, year and file path information
    reg  <- task$region
    yr   <- task$year
    file <- task$full_path
    
    cat(paste("\nWorker", i, "is processing", reg, "- year", yr, "-----------------------\n"))
    
    # Create region output directory
    region_out_dir <- file.path(out_dir, region_folder_names[[reg]], "envdat", "clim", method_name)
    if (!dir.exists(region_out_dir)) {
      dir.create(region_out_dir, recursive = TRUE, showWarnings = FALSE)
    }
    
    # load region specific mask file
    mask_file <- grep(reg, mask_files, value = TRUE) 
    mask_r <- terra::rast(mask_file) # read in mask
    extent_mask <- ext(mask_r)
    xmin_mask <- xmin(extent_mask)
    ymin_mask <- ymin(extent_mask)
    xmax_mask <- xmax(extent_mask)
    ymax_mask <- ymax(extent_mask)
    
    # create output file name
    output_file <- file.path(region_out_dir, paste0(yr, ".tif"))
    
    # Run gdalwarp for upscaling
    gdalwarp(
      srcfile = file,
      dstfile = output_file,
      overwrite = TRUE,
      tr = c(10000, 10000),
      r = "average",
      t_srs = equare_crs[[reg]],
      te = c(xmin_mask, ymin_mask, xmax_mask, ymax_mask)
    )
    
    cat("\nSaved:", output_file, "\n")
  } # close loop over tasks (rows) per worker
} # close parallel loop


