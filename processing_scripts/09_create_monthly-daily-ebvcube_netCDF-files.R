
# BMIP CHELSA Climate Variables and Bioclims ------------------------------

## Script: Creating EBV Cubes in the format "netCDF" 
## based on the R Package ebvcue (https://github.com/EBVcube/ebvcube)

## a .json textfile was created on the EBV portal. 
## this holds information about the ebvcube's metadata and structure. 

## This script only does that for methods monthly and daily
## All bioclim variables need to be handled differently and have their own script





# libraries ---------------------------------------------------------------

library(ebvcube)
library(terra)
library(tidyverse)
library(stringr)


# directories -------------------------------------------------------------

# this is were all data lies at the moment
transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/"
setwd(transfer_dir)


# fixed objects/parameters -------------------------------------------------

# the specific names of the region folders, needed for file loading and saving
region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds" 
)

# all the years that are currently under process
all_years <- length(1941:2024) # only needed to print a summary overview

# the methods used - only for daily and monthly
methods <- c("daily_10km",          # daily climate values, cropped to region and rasterised at 10 km resolution
             "monthly_1km"         # monthly mean/sum climate calues, cropped to region and rasterised at 1 km resolution
             # "annual_bioclim_1km",  # annual bioclimatic variables, cropped to region at 1 km resolution
             # "annual_bioclim_10km" # annual bioclimatic variables, cropped to region at 10 km resolution
)

## set NA as fill value - constant for all cubes
fv <- NA






# -------------------------------------------------------------------------

# list all created .tif iles  ---------------------------------------------

# lists all files after processing using the methods above
all_files <- list.files(path = "GEOBON_results/", recursive = TRUE, full.names = TRUE)

# make data.frame for easier access and better overview
df_all_files <- stringr::str_split(all_files, "/", simplify = TRUE) %>% 
  data.frame() %>% 
  as_tibble() 

df_all_files <- df_all_files[, seq(ncol(df_all_files) - 5, ncol(df_all_files),1)]
names(df_all_files) <- c("region_folder", "type", "sphere", "method", "variable", "file")
df_all_files$year <- as.numeric(gsub("*.tif", "", df_all_files$file))
df_all_files$region = names(region_folder_names)[match(df_all_files$region_folder,region_folder_names)]
df_all_files$full_path <- all_files

# remove the variable 'pr' from the df -  we are only using 'prec' 
df_all_files <- df_all_files %>% 
  dplyr::filter(variable != "pr", 
                method %in% methods)

# Overview 
print(paste0("Current state of all files: "))
print(df_all_files %>% 
        group_by(region, method, variable) %>%
        reframe(n.files = length(file), 
                prop.processed = round(n.files/all_years, 2)),
      n = nrow(df_all_files))



# Split df into chunks that go into an ebvcube ----------------------------
### there should be cubes per region x method combination

ebv_chunks <- split(df_all_files, 
                    list(df_all_files$region, df_all_files$method))
names(ebv_chunks) <- gsub("\\.", "-", names(ebv_chunks))

# only select chunks with data
ebv_chunks <- ebv_chunks[sapply(ebv_chunks, nrow) > 0]




#  extracting the raster metadata -----------------------------------------

# using a function
extract.raster.meta <- function(r_file) {  # needs a full file path to a raster file
  require(terra, quietly = TRUE)
  require(dplyr, quietly = TRUE)
  
  # read in file as raster
  r <- terra::rast(r_file) 
  
  # extract extent as named vector
  region_ext <- terra::ext(r)[1:4]           
  
  # extract epsg code from SpatRaster
  region_epsg <- terra::crs(r, describe = TRUE) %>% # extract crs information 
    dplyr::select(code) %>%                         # only slect epsg code
    as.numeric()                             # transfrom to numeric
  
  # extract spatial resolution
  region_res <- terra::res(r)
  
  # combine into list and return
  raster_metadata <- list(
    extent     = region_ext, 
    epsg       = region_epsg, 
    resolution = region_res
  )
  return(raster_metadata)
} # end function 

# and extracting the data into a list element per chunk
raster_metadata <- map(ebv_chunks, function(df) {
  file <- df$full_path[1] # within a chunk the raster metadata are all the same, so only one file per chunk is needed
  meta <- extract.raster.meta(r_file = file)
  return(meta)
}) %>% 
  set_names(names(ebv_chunks))



# setup objects for the creation of an empty netCDF --------------------------

## locate .json file 
### easiest is to make sure the .json files are named exactly as names(ebv_chunks)
### I only managed that by hand now...
json_files <- list.files("GEOBON_uploading/json_files", 
                         pattern = ".json",
                         full.names = TRUE) 

## file path to new netCDF files
new_nc_paths <- file.path("GEOBON_uploading", "nc_files", 
                          paste0(names(ebv_chunks), ".nc")) # make matching names with the ebv_chunks list




# create empty netCDF -----------------------------------------------------

## --- testing
ebv_chunks <- ebv_chunks[grep("Finland", names(ebv_chunks))] # select finland only, as we don't have more json files at the moment.
# monthly only
ebv_chunks <- ebv_chunks[grep("monthly", names(ebv_chunks))]
#---

# create the new netCDF files at the path locations set up above
iwalk(ebv_chunks, function(df, name) {
  # extract metadata, and entity information for chunk
  meta <- raster_metadata[[name]]
  
  # get json file name and new netCDF file path
  json <- grep(name, json_files, value = TRUE)
  new_nc <- grep(name, new_nc_paths, value = TRUE)
  
  # create the netCDF
  ebv_create(jsonpath = json, 
             outputpath = new_nc, 
             entities = "None", # we use no entities
             fillvalue = fv,
             epsg = meta$epsg, 
             extent = meta$extent, 
             resolution = meta$resolution,
             overwrite = TRUE, verbose = FALSE)
})



# add data to empty netCDF ------------------------------------------------

## testing --
one_month_only <- TRUE
## ---



# walk over each chunk ---
iwalk(ebv_chunks, function(df, name) {
  
  # grep the nc file name for that chunk
  new_nc <- grep(name, new_nc_paths, value = TRUE)
  
  # extract metrics
  metrics <- ebv_datacubepaths(new_nc, verbose = FALSE)
  
  # make sure variable names and metrics match, the variable code names are written between () in the metric_names
  metrics$var_code <- sub(".*\\(", "", metrics$metric_names)
  metrics$var_code <- sub("\\)", "", metrics$var_code)
  
  message(paste("Processing chunk:", name, "with metrics:"))
  print(metrics)

  
  # extract variable names within the current chunk
  variables <- unique(df$variable)
  
  
  ## walk over each variable ---
  walk(variables, function(v) {
    message(paste("Start processing variable:", v))
    
    # extract row index (metric number) for current variable
    metric_row <- which(metrics$var_code == v)
    
    # extract the full path info of tif files, filter for current variable before.
    tif_paths <- df %>% 
      dplyr::filter(variable == v) %>% 
      pull(full_path)
    
    tif_counter <- 1
    
    ## walk over tif files ---
    walk(tif_paths, function(tif) {
      
      # read in a the tif file
      r <- terra::rast(tif)
      
      # extract dates for this tif
      tif_dates <- as.Date(terra::time(r))
      
      # extract the number of layers for this tif
      n_lyr <- terra::nlyr(r)
      
      cat("Adding data for year:", tif_counter, "from", length(tif_paths), "total years\n",
          "- filepath:", tif,  "\n")
      
      # # match entity dates with the tif dates for a unique identifier and correct timestep
      # step_id <- match(tif_dates, chunk_entities)
      
      if (anyNA(tif_dates) || length(tif_dates) != n_lyr) {
        stop("Layer-Date invalid for: ", tif)
      }
      
      # add the data for each tif file. 
      ebv_add_data(filepath_nc = new_nc, 
                   metric      = metric_row, # we add data for the metric matching the variable
                   entity      = 1,          # no entity set
                   timestep    = as.character(tif_dates), # provide dates in ISO format extracted from  tif file
                   data        = tif,        # the data
                   band        = 1:n_lyr,    # all layers of this tif
                   verbose     = FALSE)

      
      tif_counter <-  tif_counter + 1 # update counter
      
      if (one_month_only) stop("TEST DONE")
    }) # close loop over tifs. 
  }) # close loop over variables
}) # close loop over chunk/cube. 






# # # Testing --------------------
# new_nc <- grep(names(ebv_chunks), new_nc_paths, value = TRUE)
# 
# # general properties
# ebv_props <- ebv_properties(new_nc, verbose = FALSE)
# ebv_props@general$entity_names
# ebv_props@spatial
# ebv_props@temporal$dates
# 
# # which cubes within netcdf exist
# datacubes <- ebv_datacubepaths(new_nc, verbose = FALSE)
# datacubes
# 
# #single datacube properties
# dc_props <- ebv_properties(new_nc, datacubes[4, 1], verbose = FALSE)
# dc_props
# dc_props@metric
# dc_props@ebv_cube
# 
# 
# 
# # return the first month from finland monthly 1 km as SpatRaster from the EBV Datacube for variable prec
# d <- ebv_read(new_nc, # the path to the netCDF file
#               datacubes[4, 1], # selecting cube 4 from the EBV netCDF ( = prec)
#               entity = 1,
#               timestep = 1, type = "r") # this is the first timestep (month 1, year 1941)
# summary(d)
# 
# # same SpatRaster after processing read directly from tif file
# r <- terra::rast("GEOBON_results/Finnish_plants/envdat/clim/monthly_1km/prec/1941.tif")
# minmax(r[[1]])
# 
# 
# # plotting
# ebv_map(new_nc, datacubes[4, 1], entity = 1, timestep = 1, verbose = FALSE)
