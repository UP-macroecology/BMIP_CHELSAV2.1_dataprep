# BMIP_CHELSAV2.1_dataprep
This repository is to download and process CHELSA V2.1 data
to be used in the BMIP initiative. 
It contains the process of downloading, resampling and cropping 
CHELSA climate files for 5 variables. From these bioclimatic variables will be calculated. 
All of which will be put in netCDF-files which will be uploaded to the GEOBON-Server

**Variables:**

- pr and prec: precipitation 
- rsds: surface radiation
- tas, tasmin and tasmax: temperature values

Those are downloaded from: https://www.chelsa-climate.org/datasets/chelsa_daily
as global daily `.tif` files at 30s spatial resolution for the years 1941-2024.

**Areas of interest:**

Europe, Finland, USA, and Australia

## Folder structure

- **mask_files:** contains all masks at 1km and 10km spatial resolution for each area as `.tif`

- **CHELSA_downloads::** global daily climate data from CHELSA server -> presently used

- **processing_scripts:** All R and shell scripts necessary for processing the CHELSA climate data

- **processing_extra_out:** additional folder with some extra, not important outputs or for script testing.

- **GEOBON_results:** Here, the outputs of the processing scripts are stored, the folder structure is the same as on the GEOBON server. 

- **GEOBON_uploading:** scripts for uploading the final files to the GEOBON server -> *CURRENTLY WRONG SETUP*
