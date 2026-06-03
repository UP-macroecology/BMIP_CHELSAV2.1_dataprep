library(terra)
#library(ncdf4)
#library(gdalUtilities)
library(foreach)
library(doParallel)
library(dplyr)
library(tidyverse)
library(lubridate)



# ============================================================================= #

## 2. Processing climate data 

# Goal:
# Process climate CHELSA data of 5 variables: tasmax, tasmin, tas, pr, rsds.
# The processing involves reprojecting the data to Equal area projection and cropping it to 
# the extent of the earlier created masks of the respective region in 10 km and 1 km resolutions. 
# Climate data with daily entries were aggregated to monthly data in 1 km resolution by calculating the averages. 
# Daily data is saved in 10 km resolution.

# Data: CHELSA 
# -> variables 30 arcsec resolution 
# orog: surface altitude, m  
# pr: total precipitation, kg m^-2 s^-1
# rsds: surface down-welling short wave radiation, xxx
# tasmin, tasmax, tas: daily min, max, ave temp, K

# ============================================================================= # 


# 1 SET UP ---------------------------------------------------------------------

## Define variables --------
resolution <- 10    # determines daily (10km resolution) calculations
regions <- c("Australia", "Europe", "USA", "Finland")
method_name <- "daily_10km" # which processing methods (daily, monthly, bioclim...)
n_cores <- 10 # number of cores to be used

## Input directories -------- 

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

### CRS Information --------
# # define the Equal Area CRS used per region 
# equare_crs <- data.frame(Australia = "EPSG:9473",
#                          Europe    = "EPSG:3035", 
#                          USA       = "ESRI:102003")



## List mask files  --------
# only filter for resolution, region filtering in loop
mask_files <- list.files(file.path(mask_dir), 
                         pattern = paste0(
                           #".*", region, # which region
                           ".*", resolution, # spatial resolution
                           "km\\.tif$"), full.names = TRUE)




## Extract complete years ----------
all_years <- 1941:2025

# list all available
all_files <- list.files(file.path(file_dir), pattern = ".tif$", full.names = TRUE, recursive = T)

# simplify names
names(all_files) <- gsub("_V.2.1.tif", "", basename(all_files))

# extract file info and store in df
df <- stringr::str_split(names(all_files), "_", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble()

# change names of df
colnames(df) <- c("model", "variable", "day", "month", "year")

# add file.path information to df for each file
df <- df %>% 
  dplyr::mutate(dir = all_files)

# add date per file in date format
df <- df %>%
  mutate(date = as.POSIXct(paste(df$day, df$month, df$year, sep="-"), 
                           tz="UTC", format="%d-%m-%Y"),
         year = as.numeric(year)) 

# summary df
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
  arrange(variable,year)

# overview of variables and completely downloaded years of raw data
complete_data <- year_summary %>% 
  group_by(variable, complete) %>%
  reframe(n_years = n())
  
print(complete_data)

## check for already processed data

processed_files <-  list.files(file.path(out_dir), pattern = ".tif", full.names = TRUE, recursive = T)
df_processed <- stringr::str_split(processed_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

df_processed <- df_processed[,seq(ncol(df_processed)-5,ncol(df_processed),1)]
names(df_processed) <- c("region_folder", "type", "sphere", "method", "variable","file")
df_processed$year <- as.numeric(gsub("*.tif", "", df_processed$file))
df_processed$region = names(region_folder_names)[match(df_processed$region_folder,region_folder_names)]
df_processed$processed = T

print("Current state of processed files: ")
print(df_processed %>% 
        filter(processed == T) %>%
        group_by(region,method, variable) %>%
        reframe(n.files = length(file)))

# Parallize ---------
## split full data in even chunks to be send to the workers -----
l <- dim(year_summary %>%
           filter(complete == T))[1] # length of year ~ variable combinations of completly downloaded data
x <- round(l/n_cores) # chunk size of tasks send to each worker
from <- seq(1,l,x)
to <- lead(from)-1
idx_df <- data.frame(from,to)
idx_df$to[n_cores] <- l

if(dim(idx_df)[1] > n_cores)idx_df <- idx_df[-(n_cores+1),]


cl <- makeCluster(n_cores)
registerDoParallel(cl)

idx_df

foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse"), .combine = c) %dopar% {
  
  year_summary_sub <- year_summary %>%
    filter(complete == T) %>%
    slice(idx_df$from[i]:idx_df$to[i])
  

# Process complete years only ---------
## loop over variables -------
for(var_name in unique(year_summary_sub$variable)){
  
### loop over regions --------
for (region in regions) {
  
  cat("\nProcessing", var_name, "for" ,region, "-------------------------------\n")
  
  # load region specific mask file
  mask_file <- grep(region, mask_files, value = TRUE) 
  mask_r <- terra::rast(mask_file) # read in mask
  
  # Create region output directory
  region_out_dir <- file.path(out_dir, region_folder_names[[region]],  "envdat", "clim", "daily_10km", var_name)
  if (!dir.exists(region_out_dir)) {dir.create(region_out_dir, recursive = TRUE, showWarnings = FALSE)}

  ### loop over complete years -----
  complete_years <- year_summary_sub %>%
    filter(variable == var_name,
           complete == T) 
  
  region_text <- region
  processed_years <- df_processed %>% 
    filter(method == method_name,
           region == region_text,
           variable == var_name)
  
  ### remove region-variable-year-combination which exist already
  years_to_process <- complete_years$year[which(!complete_years$year %in% 
                                                  processed_years$year)]
  cat(length(years_to_process), " years are completely downloaded and need to be processed on this core.\n")
  #cat(length(all_years) - length(years_to_process) - length(which(processed_years$year %in% all_years)), "are not completely downloaded and won't be processed.\n")

  
  for (yr in years_to_process) {
    
    print(paste("\n",var_name, "- Year:", yr, "from", length(years_to_process)-which(yr == years_to_process), "remaining years to process"))
    # Filter files
    year_data <- df %>% 
      filter(year == yr,
             variable == var_name) %>%
      arrange(date) %>%  # Chronological order
      mutate(layer_name = paste0(variable, "_", day, "_", month, "_", year))
    
    year_files <- year_data$dir
    layer_names <- year_data$layer_name
    
    # Stack YEARLY files
    yearly_stack <- terra::rast(year_files)
    
    names(yearly_stack) <- layer_names
    times <- as.Date(gsub(paste0(var_name,"_"), "",names(yearly_stack)), format = "%d_%m_%Y")
    terra::time(yearly_stack) <- times
    
    #define gain or scale factor of the mask to be same as in the original files
    scoff(mask_r) <- scoff(yearly_stack[[1]]) # changed = to <- assignment
    
    # Process: project + mask + write
    yearly_eq <- terra::project(yearly_stack, mask_r, method = "average")
    yearly_masked <- terra::mask(yearly_eq, mask_r)
    
    
    # Output filename: YEAR.tif
    out_name <- paste0(yr, ".tif")
    out_file <- file.path(region_out_dir, out_name)
    
    
    # Write yearly stack
    terra::writeRaster(yearly_masked, out_file, overwrite = T)
    cat("Saved yearly stack:", basename(out_file), "\n")
    
    # Memory cleanup
    rm(yearly_stack, yearly_eq, yearly_masked, times)
    gc()
    
  } # close loop over complete years
  
 } # close loop over regions

} # close loop over variables
} #close parallel loop
stopImplicitCluster()


