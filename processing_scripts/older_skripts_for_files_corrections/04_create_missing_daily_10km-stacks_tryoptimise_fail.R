
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
# Projects daily values at 10km spatial resolution for each region in LAEA Projection. 
# ============================================================================= # 



# -------------------------------------------------------------------------

# 1 SET UP ---------------------------------------------------------------------


## libraries ---------------------------------------------------------------

library(terra)
#library(ncdf4)
#library(gdalUtilities)
library(foreach)
library(doParallel)
library(dplyr)
library(tidyverse)
library(lubridate)


## parameters --------------------------------------------------------------

resolution <- 10    # determines daily (10km resolution) calculations
regions <- c("Australia", "Europe", "USA", "Finland")
method_name <- "daily_10km" # which processing methods (daily, monthly, bioclim...)
n_cores <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK"))  # number of cores to be used
all_years <- 1941:2024

## Exclude specific variable -----------
var.to.exclude = NULL
var.to.exclude = c("hurs","pr") # outcomment to keep all downloaded varr or list vars to exclude

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

### CRS Information --------
# # define the Equal Area CRS used per region 
# equare_crs <- data.frame(Australia = "EPSG:9473",
#                          Europe    = "EPSG:3035", 
#                          USA       = "ESRI:102003")




# -------------------------------------------------------------------------

# 2. FILE LISTING ---------------------------------------------------------


## list all CHELSA daily files after download ------------------------------

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
  arrange(variable,year)%>%
  filter(!variable%in%var.to.exclude)

# overview of variables and completely downloaded years of raw data
complete_data <- year_summary %>% 
  group_by(variable, complete) %>%
  reframe(n_years = n())
  
print(paste0("Tempdir is: ", tempdir()))
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

### create a mask at chelsa-data crs per region -----------------------------

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



## list already Processed Data  ----------------------------------------------

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




# -------------------------------------------------------------------------
### Identify variable year combinations that need to be processed

expected_full_files = year_summary %>% 
  expand(year,variable,region = regions, method = c("daily_10km","monthly_1km")) %>%
  mutate(year = as.numeric(year))%>%
  left_join(year_summary%>%mutate(year = as.numeric(year))) %>% 
  left_join(df_processed%>%mutate(year = as.numeric(year)))

missing_files = expected_full_files %>% 
  filter(is.na(processed),
         method == method_name,
         complete == T) %>%
  arrange(year, variable, region)


# 3. Set Up Parallel Processing -------------------------------------------

## split full data in even chunks to be send to the workers ---------------
l <- dim(missing_files %>%
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

print( missing_files %>%
         filter(complete == T) %>% print(n=300))

# -------------------------------------------------------------------------

# 4. Start Parallel Processing ---------------------------------------------

## start parallel processing loop ------------------------------------------
cfun <- function(a, b) NULL
foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse") , .combine = 'cfun'
               ) %dopar% {

#terra::terraOptions(threads = 1)

    missing_files_sub <- missing_files %>%
    filter(complete == T) %>%
    slice(idx_df$from[i]:idx_df$to[i])
    
    #slice(idx_df$from[i]:idx_df$from[i]+1)
    years_to_process <- unique(missing_files_sub$year)
    cat(length(years_to_process), 
        " years are completely downloaded and need to be processed on this core.\n")
    
    #cat(length(all_years) - length(years_to_process) - length(which(processed_years$year %in% all_years)), "are not completely downloaded and won't be processed.\n")
    
### loop over years ---------------------------------------------------
for (yr in years_to_process) {
  ## loop over variables -------------------------------------------------
  for (var_name in unique(missing_files_sub$variable)) {
    cat("\nProcessing", var_name, "-----------------------\n")
      
      print(paste("\n",var_name, "- Year:", yr, 
                  "from", length(years_to_process)-which(yr == years_to_process), 
                  "remaining years to process"))
      
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

### loop over regions ------------------------------------------------
  for (region in unique(missing_files_sub$region)) {
    terraOptions(todisk = TRUE)
    # load region specific mask file
    mask_file_laea <- region_masks_meta[[region]]$mask_laea_file 
    mask_file_4326 <- region_masks_meta[[region]]$mask_4326_file
    mask_laea <- terra::rast(mask_file_laea) # read in mask at equal area
    mask_4326 <- terra::rast(mask_file_4326)  
  
# read in mask at wgs84
      
      # Create region output directory
      region_out_dir <- file.path(out_dir, region_folder_names[[region]],  
                                  "envdat", "clim", "daily_10km", var_name)
      if (!dir.exists(region_out_dir)) {dir.create(region_out_dir, 
                                                   recursive = TRUE, 
                                                   showWarnings = FALSE)}
      
      # check for only completely downloaded years
      # complete_years <- missing_files_sub %>%
      #   filter(variable == var_name,
      #          complete == T) 
      # 
      # region_text <- region
      # 
      # # extract all already processed years
      # processed_years <- df_processed %>% 
      #   filter(method == method_name,
      #          region == region_text,
      #          variable == var_name)
      # 
      # ### remove region-variable-year-combination which exist already
      # years_to_process <- complete_years$year[which(!complete_years$year %in% 
      #                                                 processed_years$year)]
      
      
        
        #define gain or scale factor of the mask to be same as in the original files
        #scoff(mask_laea) <- scoff(yearly_stack[[1]]) 
        
        yearly_stack_crp <- terra::crop(yearly_stack, mask_4326, 
                                    filename = tempfile(fileext = ".tif"),
                                    overwrite = TRUE
                                    )
        rm(yearly_stack)
        # Process: project + mask + write
        yearly_eq <- terra::project(yearly_stack_crp, mask_laea, method = "average",
                                    filename = tempfile(fileext = ".tif"), 
                                    overwrite = TRUE
                                    )
        rm(yearly_stack_crp) 
        
        # yearly_masked <- terra::mask(yearly_eq, mask_laea, 
        #                              filename = tempfile(fileext = ".tif", tmpdir = "temp"), overwrite = TRUE)
        # rm(yearly_eq)
        # gc()
        
        
        # Output filename: YEAR.tif
        out_name <- paste0(yr, ".tif")
        out_file <- file.path(region_out_dir, out_name)
        
        
        # Write yearly stack
        yearly_mask = terra::mask(yearly_eq, mask_laea,
                      filename = tempfile(fileext = ".tif"), 
                    overwrite = TRUE)
        
        terra::writeRaster(yearly_mask, out_file, 
                           datatype = "FLT4S",
                           overwrite = T)
        cat("Saved yearly stack:", basename(out_file), "\n")
        
        # Memory cleanup
        rm(yearly_mask, times)
        tmpFiles(remove = T)
        gc()
        
      } # close loop over regions
      
      rm(mask_laea, mask_4326)
      gc()
      
    } # close loop over variables
    
  } # close loop over complete years
} #close parallel loop

stopImplicitCluster()


