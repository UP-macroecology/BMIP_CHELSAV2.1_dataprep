library(terra)
# library(raster)
# library(dismo)
library(tidyverse)
library(doParallel)
library(foreach)
library(predicts)

# ==============================================================================
# BMIP - Processing Climate Data  

# Aim:            Calculating annual bioclimatic variables using the 
#                 R package dismo.
# Input Data:     Monthly mean precipitation, minimum and maximum 
#                 temperature values derived from CHELSA daily variables 
# Pre-processing: Script "2_2_CHELSA_MONTHLY_1.R"
# Regions:        For all BMIP regions: USA, Australia, Finnland and Europe.
# Resolution:     1 km 
# ==============================================================================

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
out_dir <- file.path(transfer_dir, "GEOBON_results") # it diversifies later in loop



## Define variables --------
# resolution <- 1   # 1km spatial resolution
regions <- c("Australia", "Europe", "USA", "Finland")
method_name <- "annual_bioclim_1km" # the method used in this script
clim_method <- "monthly_1km" # previous method used to process climate data
n_cores <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK")) # number of cores to be used
var_names <- c("prec", "tasmin","tasmax") # only those needed for bioclim calc. -> using "prec" now

## match region folder names
region_folder_names <- data.frame(
  Australia = "Australian_reptiles_mammals",
  Europe    = "European_aquatic_invert",
  Finland   = "Finnish_plants",
  USA       = "US_birds" 
)


##--------------- TESTING SETUP ---------
testing <- TRUE

if (testing) {
  cat("\nTEST MODE ------------------------------")
  #out_dir <- "/import/ecoc9z/data-zurell/hauer/BMIP/testing/" # it diversifies later in loop
  out_dir <- "/home/josh/Dokumente/HiWi/MacroEco/BMIP/bioclim-testing/" # it diversifies later in loop
  regions <- "Australia"
  n_cores <- 3
}

# print overview in console
cat("\nDirectories ------\n")
cat("Working Dir:", file_dir,"\n")
cat("Output Dir:", out_dir, "\n")
cat("\nDefined variables ------\n")
cat("Variables:", var_names,"\n")
cat("Regions:", regions, "\n")
cat("Cores:", n_cores,"\n")

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


# filter for input clim files -------
df_clim_files <- df_all_files %>% 
  filter(method %in% clim_method,     # "monthly_1km"
         variable %in% var_names) %>% # "prec", "tasmin", "tasmax"
  mutate(clim_file_exists = TRUE)

cat("\nAll available climate files.....")
print(df_clim_files %>% 
        filter(clim_file_exists == TRUE) %>%
        group_by(region, method, variable) %>%
        reframe(n.files = length(file)))

# filter for already processed output files ------
df_processed <- df_all_files %>% 
  filter(method %in% method_name) %>% # "annual_bioclim_1km"
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


#  Filter data to send to workers for Calculations --------------------
# only use those years~region combination, where all three variables are complete
df_complete_years <- df_clim_files %>%
  group_by(region, year) %>%
  filter(n_distinct(variable) == length(var_names)) %>%  
  ungroup()

cat(paste("\nPrec, tasmin and tasmax complete for",
          length(unique(df_complete_years$year)), "years.\n"))

# filter for years that have not been processed already
df_years_to_process <- df_complete_years %>%
  filter(!paste(region, year) %in% paste(df_processed$region, df_processed$year))

cat(paste("\nBioclim calculations missing for",
          length(unique(df_years_to_process$year)), "years.\n"))

# stop  workflow, if there are no years to process
if (nrow(df_years_to_process) == 0) stop("...No years to process!...")

# group all year~region combinations for all 3 variables
df_years_to_process_grouped <- df_years_to_process %>%
  arrange(region, year) %>%
  group_by(region, year) %>%
  summarise(
    n_vars = n(),
    .groups = "drop"
  )



## split grouped df in even chunks to be send to the workers -----
l <- nrow(df_years_to_process_grouped)  # total rows in df_years_to_process_grouped
x <- round(l / n_cores)      # chunk size per worker
from <- seq(1, l, x)         # start indices
to <- lead(from) - 1         # end indices
idx_df <- data.frame(from, to)
# Fix last chunk to include remaining rows
idx_df$to[n_cores] <- l
# Remove extra row if created
if(nrow(idx_df) > n_cores) {idx_df <- idx_df[-(n_cores+1), ]}

# create a list of chunks with year~region combination
chunks <- lapply(1:n_cores, function(j) {
  from_j <- idx_df$from[j]
  to_j <- idx_df$to[j]
  df_years_to_process_grouped[from_j:to_j, c("region", "year")]
})


# BIOCLIM Calculation -----------
# no conversion factor for pr needed, as we have mm/day averaged in mm/month
# in previous scripts

if (testing) {
  log_file <- file.path(out_dir, "bioclims_1_output.log")
  cl <- makeCluster(n_cores, outfile = log_file)
} else {
  cl <- makeCluster(n_cores)
}

registerDoParallel(cl)

# paralellize per worker ----------------
foo <- foreach(i = 1:n_cores, .packages = c("terra", "tidyverse", "predicts"), .combine = c) %dopar% {
                 
  # get keys for this chunk
  chunk_key <- chunks[[i]]
  
  # subset df to key and extract file information
  df_years_to_process_sub <- df_years_to_process %>% 
    semi_join(chunk_key, by = c("region", "year"))
  
  ## loop over regions --------
  for(reg in regions) {
    
    if (!reg %in% df_years_to_process_sub$region) {
      cat(reg, "not within this chunk - continue with next region in loop")
      next
    } else {
      cat(paste("\nProcessing", reg, "-------------------------------\n"))
    }
    
    # Create region output directory
    region_out_dir <- file.path(out_dir, region_folder_names[[reg]],  
                                "envdat", "clim", method_name)
    if (!dir.exists(region_out_dir)) {
      dir.create(region_out_dir, recursive = TRUE, showWarnings = FALSE)
    }
    
    # extract years that are being processed
    year_vals <- unique(df_years_to_process_sub$year)
    
    for (yr in year_vals) {
      
      cat(paste("\nWorker", i, "processes year:", yr, "- from", 
                length(year_vals)-which(yr == year_vals), 
                "remaining years to process\n"))
      
      # extract pr, tasmin and tasmax file paths and store in new data.frames
      pr_file <- df_years_to_process_sub %>% 
        filter(region == reg, variable == "prec", year == yr) %>% 
        pull(full_path)
      
      tasmin_file <- df_years_to_process_sub %>% 
        filter(region == reg, variable == "tasmin", year == yr) %>% 
        pull(full_path)
      
      tasmax_file <- df_years_to_process_sub %>% 
        filter(region == reg, variable == "tasmax", year == yr) %>% 
        pull(full_path)
      
      if (length(pr_file) == 0 | 
          length(tasmin_file) == 0 | 
          length(tasmax_file) == 0) {
        cat(paste("\nError: one of the following files is empty: \n 
                  \n- prec file:", pr_file, 
                  "\n- tasmin file:", tasmin_file, 
                  "\n- tasmax file", tasmax_file,"\n"))
        stop("Error: Empty clim file...")
      }
      
      pr_terra <- terra::rast(pr_file)
      tasmin_terra <- terra::rast(tasmin_file)
      tasmax_terra <- terra::rast(tasmax_file)
      
      # Convert temperature from Kelvin to Celsius
      tasmin_terra <- tasmin_terra - 273.15
      tasmax_terra <- tasmax_terra - 273.15
      
      # # Convert SpatRaster objects to RasterStack (for use with dismo::biovars)
      # pr_raster <- raster::stack(pr_terra)    # Stack as RasterStack
      # tasmin_raster <- raster::stack(tasmin_terra) # Stack as RasterStack
      # tasmax_raster <- raster::stack(tasmax_terra) # Stack as RasterStack
      
      # Check if the RasterStacks have 12 monthly layers each
      if (nlyr(pr_terra) != 12 | 
          nlyr(tasmin_terra) != 12 | 
          nlyr(tasmax_terra) != 12) {
        cat(paste("Error: Missing Layers in climate RasterStacks for year: ", yr))
        stop("Error: Missing Layers...")
      }
      
      # Calculate the bioclimatic variables using the dismo::biovars function
      bioclim_terra <- predicts::bcvars(prec = pr_terra, 
                                        tmin = tasmin_terra, 
                                        tmax = tasmax_terra)
      
      
      # # Convert the result to a terra object for saving
      # bioclim_terra <- terra::rast(bioclim_raster)
      
      cat(paste("\nBioclims calculated for year:", yr,  
                "and region:", reg, "--------\n"))
      cat("\nNumber of layers:", terra::nlyr(bioclim_terra), "\n")
      cat("Layer names:", paste(names(bioclim_terra), collapse = ", "), "\n")
      
      
      # Save single year
      writeRaster(bioclim_terra, 
                  filename = file.path(region_out_dir, paste0(yr, ".tif")), 
                  overwrite = TRUE)
      
      # clean workspace
      rm(# pr_raster, tasmin_raster, tasmax_raster, 
         pr_terra, tasmin_terra,  tasmax_terra, 
         pr_file, tasmin_file,  tasmax_file, bioclim_raster, bioclim_terra)
      gc()
    
      if (testing) {stop("STOP TESTING ----")}
    } # close loop over years
  } # close loop over regions
} # close parallelizing over workers
  

 












