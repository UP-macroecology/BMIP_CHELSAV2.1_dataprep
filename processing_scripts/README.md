# FINAL EXPLANATION TO PROCESSING SCRIPTS

The processing of daily climate variables from CHELSA to bioclims is done in this order. 

## START:  Script `01_check_download_missing_CHELSA2.1.-files.R`

 - this script checks for any missing CHELSA V2.1 files in the folder CHELSA_downloads 
 - attempts to download those files for the provided variables
 - prints overview every few hours in .log file of download history
 
## Script: `02_check_corrupt_CHELSA-files.R`

 - check file size of the CHELSA downloads.
 - delete files that are small. 
 - *the deleting is currently commented out*


## Script: `03_check_delete_DAILY-MONTHLY.R`

 - delete all years and already processed files, that had corrupt daily CHELSA files. 
 - Information about those years is stored in .rds object from script **02** 
 
  **!!!! RE-RUN THE SCRIPT 01 FOR DOWNLOADING AGAIN AFTER THAT !!!**
  **AND RE_RUN SCRIPT 02 AND 03 AGAIN BUT THEN CONTINUE WITH THE NEXT SCRIPTS AND DO NOT DOWNLOAD AGAIN FOR SOME TIME**
  
## Script: `04_create_missing_daily_10km-stacks.R` and `05_create_missing_monthly_1km-stacks.R`

 - can be run now, they create yearly stacks with resampled and cropped SpatRasters for the four GEOBON regions. 
 - stored in GEOBON_results
 - will only do those years that are missing (have not been processed yet)
 
## Script: `06_check_set_scoff.R`

 - **!! RUN NOW BEFORE BIOCLIM SCRIPTS!!**
 - this takes the scale and offset factor of the original CHELSA file per variable to overcome potential terra errors in such meta data 
 - sets the scoff of each processed file to this original scoff

 
## Script: `07_create_missing_annual_bioclims_10km-stacks.R` and `08_create_missing_annual_bioclims_1km-stacks.R`

 - final scripts, they calculate Bioclims for 1 and 10km spat resolution
 
**DONE**
