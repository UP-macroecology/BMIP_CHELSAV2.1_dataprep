
# ============================================================================= #
## 2. Processing climate data 

# Goal:
# Process climate CHELSA data of 6 variables: tasmax, tasmin, tas, pr, rsds and hurs
# The processing involves re-projection of the data to Equal area projection 
# and cropping it to the extent of the earlier created masks of the respective 
# region. 

# Data: CHELSA V2.1 (https://www.chelsa-climate.org/datasets/chelsa_daily)
# -> daily variables at 30 arcsec resolution 
# prec:   total precipitation without bias correction, kg m^-2 s^-1
# rsds:   surface down-welling short wave radiation, W m-2
# tasmin: minimum near-surface temperature, K
# tasmax: maximum near-surface temperature, K
# tas:    mean near-surface temperature, K
# hurs:   rel. humidity, percent

# This Script: 
# Calculates monthly sum (prec only) and averages (all except prec) at 1km 
# spatial resolution for each region in LAEA Projection. 
# ============================================================================= # 




# -------------------------------------------------------------------------

# 1 SET UP ---------------------------------------------------------------------


## libraries ---------------------------------------------------------------

library(terra)
#library(ncdf4)
#library(gdalUtilities)
library(foreach)
library(doParallel)
library(tidyverse)
library(dplyr)
library(lubridate)

## RUN ALL YEARS: YES OR NO ------------------------------------------------
# this will re-calculate all monthly raster stacks for all years and variables and regions --> TAKES LONGER
# if set to FASLE it will only calculate missing years per variable and region. 
run_for_all_years <- FALSE # set to FALSE for missing years only!

## Exclude specific variable -----------
var.to.exclude = NULL
var.to.exclude = c("hurs","pr") # outcomment to keep all downloaded varr or list vars to exclude



## parameters --------------------------------------------------------------

resolution <- 1   # determines monthly calculations (1km spatial resolution)
regions <- c("Australia", "Europe", "USA", "Finland")
method_name <- "monthly_1km"
n_cores <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK"))  # number of cores to be used
# all years in workflow
all_years <- 1941:2024

# ## CRS Information
# # define the Equal Area CRS used per region 
# equare_crs <- data.frame(Australia = "EPSG:9473",
#                          Europe    = "EPSG:3035", 
#                          USA       = "ESRI:102003")


## directories -------------------------------------------------------------

# general transfer directory
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
#transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
#transfer_dir <- "//mnt/local_chelsa02" testing on Linux local mount

# specify input directories
mask_dir <- file.path(transfer_dir, "mask_files")
file_dir <- file.path(transfer_dir, "CHELSA_downloads", "chelsa02", "chelsa", "global", "daily") # from here it's sorted after variables

# general output directory
out_dir <- file.path(transfer_dir, "GEOBON_results") # it diversifies later in loop

region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds" 
)


# -------------------------------------------------------------------------

# 2. FILE LISTING ---------------------------------------------------------


## list all CHELSA daily files after download ------------------------------

all_files <- list.files(file.path(file_dir), pattern = ".tif", full.names = TRUE, recursive = T)

# simplify names
names(all_files) <- gsub("_V.2.1.tif", "", basename(all_files))

# extract file info and store in df
df <- stringr::str_split(names(all_files), "_", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble()

# change names of df
names(df) <- c("model", "variable", "day", "month", "year")

# add file.path information to df for each file
df <- df %>% 
  dplyr::mutate(dir = all_files)

# add date per file in date format
df <- df %>%
  mutate(date = as.POSIXct(paste(df$day, df$month, df$year, sep = "-"), 
                           tz = "UTC", format = "%d-%m-%Y")) 

## create a summary data.frame from all CHELSA files ----------------------
year_summary <- df %>%
  group_by(year, variable) %>%
  reframe(n_files = n()) %>%      # number of files/days per year
  mutate(
    expected_days = as.numeric(difftime(  # how many days has each year (includes leap years)
      ymd(paste(year, "12-31")), 
      ymd(paste(year, "01-01")), 
      units = "days"
    )) + 1,
    complete = n_files == expected_days
  ) %>%
  arrange(variable,year) %>%
  filter(!variable%in%var.to.exclude)


# overview of variables and completely downloaded years of raw data
complete_data <- year_summary %>% 
  group_by(variable, complete) %>%
  reframe(n_years = n())

print("Overview of complete CHELSA data")
print(complete_data)


## list mask files at LAEA -------------------------------------------------

# only filter for resolution, region filtering in loop
mask_files <- list.files(file.path(mask_dir), 
                         pattern = paste0(
                           ".*",
                           resolution, # spatial resolution
                           "km\\.tif$"), full.names = TRUE)

# seperate into equal area masks and wgs84 masks
mask_laea_files <- mask_files[-grep("EPSG4326", mask_files)]
mask_4326_files <- mask_files[grep("EPSG4326", mask_files)]

## create a mask at chelsa-data crs per region -----------------------------

# empty list to store all mask specific metadata per region
region_masks_meta <- list()

# only run this if they do not exist yet
if (length(mask_4326_files) != 4) {
  print(paste("Making new masks at WGS 84"))
  
  # load a single chelsa file
  r_chelsa <- terra::rast(df$dir[1])
  
  # extract crs and resolution of CHELSA file -> constant for all variables and days
  chelsa_crs <- terra::crs(r_chelsa) # is WGS84 epsg:4326
  chelsa_res <- terra::res(r_chelsa)
  rm(r_chelsa) # remove SpatRaster
  
  # loop over regions
  for (region in regions) {
    print(region)
    # get the file path for LAEA-projected mask of region
    mask_laea_file <- grep(region, mask_laea_files, value = TRUE)
    
    # safety
    if (length(mask_laea_file) != 1) {
      stop("No uniqe mask for region: ", region)
    }
    
    # read in this mask 
    mask_r <- terra::rast(mask_laea_file)
    
    # convert mask to chelsa crs and extract the extent
    mask_chelsa_crs <- terra::project(mask_r, chelsa_crs)
    
    # store mask with chelsa crs in mask_dir
    mask_4326_file <- file.path(mask_dir, paste0("mask_", region, "_EPSG4326_", resolution, "km.tif"))
    terra::writeRaster(mask_chelsa_crs, mask_4326_file, overwrite = TRUE)
    
    
    region_masks_meta[[region]] <- list(
      mask_laea_file = mask_laea_file, # the path to the region mask_file in LAEA Proj
      mask_4326_file = mask_4326_file # file path to mask in EPSG 4326
    )
    rm(mask_r, mask_chelsa_crs)
  } # close loop over regions
  
} else {
  print(paste("Masks are created - storing paths in masks meta list"))
  # loop over regions
  for (region in regions) {
    print(region)
    # select only the files for that region
    mask_laea_file <- mask_laea_files[grep(region, mask_laea_files)]
    mask_4326_file <- mask_4326_files[grep(region, mask_4326_files)]
    
    # add masks meta to list
    region_masks_meta[[region]] <- list(
      mask_laea_file = mask_laea_file, # the path to the region mask_file in LAEA Proj
      mask_4326_file = mask_4326_file # file path to mask in EPSG 4326
    )
  } # close loop over regions
} # close if else conditions
rm(mask_files, mask_laea_files, mask_4326_files)


## list all processed year stacks for method monthly_1km -------------------

processed_files <-  list.files(file.path(out_dir), pattern = ".tif", full.names = TRUE, recursive = T)

df_processed <- stringr::str_split(processed_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

df_processed <- df_processed[, seq(ncol(df_processed) - 5, ncol(df_processed), 1)]
names(df_processed) <- c("region_folder", "type", "sphere", "method", "variable","file")
df_processed$year <- as.numeric(gsub("*.tif", "", df_processed$file))
df_processed$region = names(region_folder_names)[match(df_processed$region_folder, region_folder_names)]
df_processed$processed = T


# empty the processed df if all years should be re-calculated --> see at the TOP
if (run_for_all_years) {
  df_processed <- df_processed[0,]
  print(paste0("Processing all yearly stacks"))
} else {
  print(paste0("Processing only missing files - Already processed years/files:"))
  print(df_processed %>% 
          filter(processed == T, method == "monthly_1km") %>%
          group_by(region, method, variable) %>%
          reframe(n.files = length(file), 
                  prop.processed = round(n.files/length(all_years), 2)), 
        n = nrow(df_processed))
}





# -------------------------------------------------------------------------

# 3. Set Up Parallel Processing -------------------------------------------
if(!is.null(var.to.exclude)){
  year_summary = year_summary %>% filter(!variable %in% var.to.exclude)
}

## split full data in even chunks to be send to the workers -----
l <- dim(year_summary %>%
  filter(complete == T))[1] # length of year ~ variable combinations of completely downloaded data
x <- round(l/n_cores) # chunk size of tasks send to each worker
from <- seq(1,l,x)
to <- lead(from) - 1
idx_df <- data.frame(from,to)
idx_df$to[n_cores] <- l

if (dim(idx_df)[1] > n_cores) idx_df <- idx_df[-(n_cores + 1), ]

## make cluster
cl <- makeCluster(n_cores)
registerDoParallel(cl)

### in between memory clean
rm(all_files, processed_files)
gc()

idx_df



# -------------------------------------------------------------------------

# 4. Start Parallel Processing ---------------------------------------------

## start parallel processing loop ------------------------------------------
foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse"), .combine = combine) %dopar% {
  
  year_summary_sub <- year_summary %>%
    filter(complete == T) %>%
    slice(idx_df$from[i]:idx_df$to[i])
  

  ## loop over variables -----------------------------------------------------
  for (var_name in unique(year_summary_sub$variable)) {
    
    ### loop over regions ----------------------------------------------------
    for (region in regions) {
      
      cat(paste("\nProcessing", var_name, "for" ,region, "----------------\n"))
      
      # load region specific mask file
      mask_file_laea <- region_masks_meta[[region]]$mask_laea_file 
      mask_file_4326 <- region_masks_meta[[region]]$mask_4326_file
      mask_laea <- terra::rast(mask_file_laea) # read in mask at equal area
      mask_4326 <- terra::rast(mask_file_4326) # read in mask at wgs84
      
      # Create region output directory
      region_out_dir <- file.path(out_dir, region_folder_names[[region]],  
                                  "envdat", "clim", "monthly_1km", var_name)
      if (!dir.exists(region_out_dir)) {dir.create(region_out_dir, 
                                                   recursive = TRUE, 
                                                   showWarnings = FALSE)}
      
      
      ### filter for complete years - all days present in CHELSA daily global files -----
      complete_years <- year_summary_sub %>%
        filter(variable == var_name,
               complete == T) 
      
      region_text <- region
      
      ### filtered for processed years for region, variable and method of that loop
      processed_years <- df_processed %>% 
        filter(method == method_name,
               region == region_text,
               variable == var_name)
      
      ### remove region-variable-year-combination which exist already
      years_to_process <- complete_years$year[which(!complete_years$year %in% 
                                                      processed_years$year)]
      
      # jump to next region if no more years are to be processed
      if (length(years_to_process) == 0) {
        cat("No more years to process for", region, "and", var_name, "---\n")
        next # skip
      } else {
        cat(paste(length(years_to_process), 
                  "years are completely downloaded and will be processed on worker", 
                  i,".\n"))
      }
      
      # cat(length(all_years) - (length(years_to_process) + length(which(processed_years$year %in% all_years))), "years are not completely downloaded and won't be processed.\n")
      
      ### loop over years ----------------------------------------------------
      for (yr in years_to_process) { ## loop over years
        
        cat(paste("\nworker: ", i,"processes",var_name, 
                  "- Year:", yr, "from", 
                  length(years_to_process) - which(yr == years_to_process), 
                  "remaining years to process"))
        
        yearly_stack <- list()
        
        #### loop over months ------------------------------------------------
        for (m in 1:12) { ## loop over months
          

          # filter for this month only - taken from full CHELSA global daily df
          month_data <- df %>% 
            filter(year(date) == yr, 
                   month(date) == m,
                   variable == var_name) %>% 
            arrange(date) 
          
          month_files <- month_data$dir
          
          # monthly stacking 
          month_stack <- terra::rast(month_files)
          
          #define gain or scale factor of the mask to be same as in the original files
          scoff(mask_laea) <- scoff(month_stack[[1]]) # changed = to <- assignment
          
          # crop the global daily stack to region mask first 
          month_stack <- terra::crop(month_stack, mask_4326)
          
          # projection and masking and averaging 
          month_eq <- terra::project(month_stack, mask_laea, method = "average")
          month_mask <- terra::mask(month_eq, mask_laea)
          
          # calculate monthly sum (precipitation) or mean (temp. and radiation)
          if (var_name %in% c("pr", "prec")) {
            cat("Calculate monthly sums for variable", var_name, "\n")
            month_final <- sum(month_mask,  na.rm = TRUE)
          } else {
            cat("Calculate monthly mean for variable", var_name, "\n")
            month_final <- mean(month_mask, na.rm = TRUE)
          }
          
        
          # rename and put into yearly stack
          names(month_final) <- paste0(var_name, "_01_", sprintf("%02d", m), "_", yr)
          times <- as.Date(gsub(paste0(var_name,"_"), "",names(month_final)), format = "%d_%m_%Y")
          terra::time(month_final) <- times
          
          yearly_stack[[m]] <- month_final
          
          
          rm(month_data, month_files, month_stack, month_eq, month_final)
          gc()
          
        } # end loop over months
        
        # combine into yearly_stack
        yearly_stack <- terra::rast(yearly_stack)
        
        
        # Output filename: YEAR.tif
        out_name <- paste0(yr, ".tif")
        out_file <- file.path(region_out_dir, out_name)
        
        # save raster stack per year
        terra::writeRaster(yearly_stack, out_file, overwrite = TRUE)
        cat("Saved yearly stack:", basename(out_file), "\n")
        
        # Memory cleanup                                        
        rm(yearly_stack)
        gc()
        
      } # close loop over complete years
      
      rm(mask_laea, mask_4326, mask_file_4326, mask_file_laea, 
         complete_years, processed_years, years_to_process)
      gc()
    } # close loop over regions
    gc()
  } # close loop over variables
  gc()
}  # close parallelisation

stopImplicitCluster()