
# BMIP CHELSA Climate Variables and Bioclims ------------------------------

## Script: Creating EBV Cubes in the format "netCDF" 
## based on the R Package ebvcue (https://github.com/EBVcube/ebvcube)

## a .json textfile was created on the EBV portal. 
## this holds information about the ebvcube's metadata and structure. 

## This script creates ebvcubes for Bioclims at 1 and 10 km resolution
## All climate variables need to be handled differently and have their own script





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


start_date <- as.Date("1941-01-01")
end_date   <- as.Date("2024-12-31")

# all the years that are currently under process
all_years <- length(1941:2024) # only needed to print a summary overview

# the methods used - only for daily and monthly
methods <- c(# "daily_10km",          # daily climate values, cropped to region and rasterised at 10 km resolution
             # "monthly_1km"         # monthly mean/sum climate calues, cropped to region and rasterised at 1 km resolution
             "annual_bioclim_1km",  # annual bioclimatic variables, cropped to region at 1 km resolution
             "annual_bioclim_10km" # annual bioclimatic variables, cropped to region at 10 km resolution
)

## set NA as fill value - constant for all cubes
fv <- 9.9692099683868690e+36 # fill value from CF convention for float datatypes: https://docs.unidata.ucar.edu/netcdf-c/current/file_format_specifications.html (See also: https://cfconventions.org/cf-conventions/cf-conventions.html#missing-data)

# runs for a single year, single variable and FINLAND MONTHLY
testing <- TRUE # set to FALSE for full run
one_year_only <- testing



# Setting filters  --------------------------------------------------------

# manually set filters for the data addding

# only those years are included in the ebv_add_data
start_year <- 1941
end_year   <- 2024
filter_years <- start_year:end_year





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
df_all_files$full_path <- all_files

df_all_files <- df_all_files %>% 
  filter(method %in% methods) %>% # "annual_bioclim_1km" and "..10km
  # we drop the last column here, because the file path for bioclims does 
  # not include variables, but we have to rename to fix this. 
  dplyr::select(region_folder, type, sphere, method, variable, full_path) %>% 
  rename(file = variable) %>%   
  # Re-extract year and region information, set processed to TRUE
  mutate(year = as.numeric(gsub("\\.tif$", "", file)),  
         region = names(region_folder_names)[match(region_folder, 
                                                   region_folder_names)])


# Overview 
print(paste0("Current state of all files: "))
print(df_all_files %>% 
        group_by(region, method) %>%
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

cat("Building ebvcubes for: \n")
for (i in names(ebv_chunks)) {
  cat(" -", i, "\n")
}


#  extracting the raster metadata -----------------------------------------

# a helper function
extract.raster.meta <- function(r_file) { # needs a full file path to a raster file
  require(terra, quietly = TRUE)
  
  # read in file as raster
  r <- terra::rast(r_file)
  
  # extract extent as named vector and spatial resolution
  region_ext <- terra::ext(r)[1:4]
  region_res <- terra::res(r)
  
  # extract epsg code from SpatRaster
  crs_info <- terra::crs(r, describe = TRUE)
  
  # if there is an epsg code available use this
  if (!is.na(crs_info$code) && crs_info$authority == "EPSG") {
    region_epsg <- as.numeric(crs_info$code)
  } else {
    # if there is no epsg code available -> check PROJ name
    wkt  <- terra::crs(r)
    name <- sub('.*PROJCRS\\["([^"]+)".*', '\\1', wkt)
    
    # connect ESRI strings to the PROJ names
    esri_lookup <- c(
      "USA_Contiguous_Albers_Equal_Area_Conic" = "ESRI:102003"
    )
    
    # store ESRI string for matching PROJ names only
    if (name %in% names(esri_lookup)) {
      region_epsg <- esri_lookup[[name]]
    } else {
      stop(paste("No EPSG or known ESRI match for CRS:", name))
    }
  }
  
  # return a list of raster metadata
  list(extent = region_ext, epsg = region_epsg, resolution = region_res)
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
if (testing) {
  ebv_chunks <- ebv_chunks[grep("Finland", names(ebv_chunks))] # select finland only, as we don't have more json files at the moment.
  # monthly only
  # ebv_chunks <- ebv_chunks[grep("monthly", names(ebv_chunks))]
  # new_nc_paths <- file.path("/home/josh/Dokumente/HiWi/MacroEco/BMIP/ebvcube", paste0(names(ebv_chunks), ".nc"))
  new_nc_paths <- file.path("GEOBON_uploading", "nc_files", paste0(names(ebv_chunks), ".nc"))
  cat("Testing only for:", names(ebv_chunks), "\nstored under:", new_nc_paths)
}
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
  
  cat("\nCreated new netCDF for:", name, 
      "\nstored under:", new_nc, "\nwith json:", json, "\n")
})


# filter using filter objects ---------------------------------------------

ebv_chunks <- map(ebv_chunks, function(df) {
  df <- df %>% 
    dplyr::filter(year %in% filter_years)
  df
})


# add data to empty netCDF ------------------------------------------------

if (!testing) {
  n_cores <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK"))
  cat("CLUSTER: Parallel processing on", n_cores, "cores\n")
} else {
  n_cores <- 2
  cat("LOCAL: Parallel processing on", n_cores, "cores\n")
}

# start multisession ----
future::plan(multisession, workers = n_cores)



# walk over each chunk ---
iwalk(ebv_chunks, function(df, name) {
  
  # grep the nc file name for that chunk
  new_nc <- grep(name, new_nc_paths, value = TRUE)
  
  # extract metrics
  metrics <- ebv_datacubepaths(new_nc, verbose = FALSE)
  
  # make sure variable names and metrics match, the variable code names are written between () in the metric_names
  metrics$var_code <- sub(".*\\(", "", metrics$metric_names)
  metrics$var_code <- sub("\\)", "", metrics$var_code)
  
  cat("Processing chunk:", name, "with metrics:\n")
  print(metrics)

  ## walk over each row, i.e. year ---
  walk(seq_len(nrow(df)), function(i) {
    cat("Start processing year:", i, "of", nrow(df), "years\n")
    
    # extract tif raster path
    tif <- df$full_path[i]
    yr  <- df$year[i]
    
    # Load in SpatRaster
    r <- terra::rast(tif)
    n_lyr <- terra::nlyr(r)
    
    # extract the layer names -> should be metric names
    layer_names <- names(r)
    
    # explicitly store timestep (same for all bioclims from this tif)
    this_timestep <- yr
    
    # loop over the layers -> like looping over metrics but staying at this timestep ---
    walk(seq_len(n_lyr), function(lyr) {
      # extract row index (metric number) for current variable
      metric_row <- which(metrics$var_code == layer_names[lyr])
      
      cat("Adding data for bioclim:", layer_names[lyr], "in metric", metric_row, "\n",
          "- from tif filepath:", tif,  "\n")
      
      # add the data for each tif file. 
      ebv_add_data(filepath_nc = new_nc, 
                   metric      = metric_row, # we add data for the metric matching the variable
                   entity      = 1,          # no entity set
                   timestep    = this_timestep, # provide dates in ISO format extracted from  tif file
                   data        = tif,        # the data
                   band        = lyr,    # all layers of this tif
                   verbose     = FALSE)
      
      
      if (only_one_year) stop("TEST DONE")
    }) # close loop over raster layers
  }) # close loop over rows/years
}) # close loop over chunk/cube. 

# stop multisession
future::plan(sequential)





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
