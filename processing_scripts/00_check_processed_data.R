
## libraries ---------------------------------------------------------------

library(terra)
#library(ncdf4)
#library(gdalUtilities)
library(foreach)
library(doParallel)
library(dplyr)
library(tidyverse)
library(lubridate)

# general transfer directory
#transfer_dir <- "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/" # for cluster 
#transfer_dir <- "//NAS-2-P-SN-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/" # for testing on Windows PC
transfer_dir <- "/mnt/local_chelsa02/Hauer_BMIP_data/" #testing on Linux local mount

## Get overview of missing data:
file_dir <- file.path(transfer_dir, "CHELSA_downloads", "chelsa02", "chelsa", "global", "daily") # from here it's sorted after variables

all_dirs <- list.dirs(transfer_dir)


# check all variables and methods (takes very very long) -----




methods <- c("monthly_1km")
variables <- c("prec","rsds","tas","tasmin","tasmax") # "hurs"
for(i in methods){
monthly_dirs <- all_dirs[grep(i,all_dirs)]
#monthly_dirs < all_dirs[grep("monthly_10km",all_dirs)]

monthly_files <- list.files(monthly_dirs, full.names = TRUE, pattern = "\\.tif$")
#monthly_files <- monthly_files[-grep("pr",monthly_files)]
#monthly_files <- list.files(monthly_dirs,full.names = T)
#monthly_files <- monthly_files[grep("US",monthly_files)]
#monthly_files <- monthly_files[grep(variable,monthly_files)]
#monthly_files <- monthly_files[grep("prec",monthly_files)]

### read and summarise --------------
# This takes long
overview_data <- parallel::mclapply(monthly_files,mc.cores = 4, function(x){
  file = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())]
  var = str_split(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-1]
  res = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-2]
  site =  strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-5]
  
  means = global(rast(x), fun = mean, na.rm = TRUE, maxcell = 1e4)
  nms <- rownames(means)
  parts <- do.call(rbind, strsplit(nms, "_"))
  means <- data.frame(
    variable = parts[, 1],
    date = as.Date(paste(parts[, 4], parts[, 3], parts[, 2], sep = "-")),
    mean = means,
    site = site,
    res = res
  )
  # ggplot(means, aes ( x = date, y = mean))+
  #   geom_point()+
  #   labs(title = paste(site, res, "\n",var,file))
  return(means)
})
overview_data = do.call(rbind,overview_data)
#overview_data = overview_data[-grep("monthly_1km/rsds",overview_data)]

### plot and save ----------
ggplot(data = overview_data, aes(x = year(date), y = mean, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

for(j in variables){
  

ggsave(filename = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/",j,"_monthly_10km_state",Sys.Date(),".png"),
       width = 28, height = 10, units = "cm", dpi = 100)

}

# check single variables and methods -----------

## daily -------------
variable <- "rsds"
all_dirs <- list.dirs(transfer_dir)
daily_dirs <- all_dirs[grep("daily_10km",all_dirs)]
#monthly_dirs < all_dirs[grep("monthly_10km",all_dirs)]

daily_files <- list.files(daily_dirs,full.names = T)
daily_files <- daily_files[-grep("pr",daily_files)]
daily_files <- daily_files[grep(".tif",daily_files)]
#monthly_files <- list.files(monthly_dirs,full.names = T)

### read and summarise --------
## This takes long
overview_data <- lapply(daily_files, function(x){
  file = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())]
  var = str_split(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-1]
  res = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-2]
  site =  strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-5]
  
  means = global(rast(x),mean,na.rm=T) 
  nms <- rownames(means)
  parts <- do.call(rbind, strsplit(nms, "_"))
  means <- data.frame(
    variable = parts[, 1],
    date = as.Date(paste(parts[, 4], parts[, 3], parts[, 2], sep = "-")),
    mean = means,
    site = site,
    res = res
    )
  # ggplot(means, aes ( x = date, y = mean))+
  #   geom_point()+
  #   labs(title = paste(site, res, "\n",var,file))
  return(means)
})

overview_data = do.call(rbind,overview_data)
#overview_data = overview_data[-grep("monthly_1km/rsds",overview_data)]

### plot and save -----
ggplot(data = overview_data, aes(x = year(date), y = mean, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

ggsave(filename = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/",variable,"_daily_10km_state",Sys.Date(),".png"),
       width = 28, height = 10, units = "cm", dpi = 100)

## monthly ----------
all_dirs <- list.dirs(transfer_dir)
monthly_dirs <- all_dirs[grep("monthly_1km",all_dirs)]
#monthly_dirs < all_dirs[grep("monthly_10km",all_dirs)]

variable <- "tas"
monthly_files <- list.files(monthly_dirs, full.names = TRUE, pattern = "\\.tif$")
#monthly_files <- monthly_files[-grep("pr",monthly_files)]
#monthly_files <- list.files(monthly_dirs,full.names = T)
#monthly_files <- monthly_files[grep("US",monthly_files)]
monthly_files <- monthly_files[grep(variable,monthly_files)]
#monthly_files <- monthly_files[grep("prec",monthly_files)]

#monthly_files <- monthly_files[-grep("Europe",monthly_files)]
monthly_files <- monthly_files[grep("Australia",monthly_files)]
#monthly_files <- monthly_files[grep("Finnish",monthly_files)]
#monthly_files <- monthly_files[1:4]

### read and summarise --------------
# This takes long
overview_data <- parallel::mclapply(monthly_files,mc.cores = 8, function(x){
  file = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())]
  var = str_split(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-1]
  res = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-2]
  site =  strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-5]
  
  means = global(rast(x), fun = mean, na.rm = TRUE, maxcell = 1e3)
  nms <- rownames(means)
  parts <- do.call(rbind, strsplit(nms, "_"))
  means <- data.frame(
    variable = parts[, 1],
    date = as.Date(paste(parts[, 4], parts[, 3], parts[, 2], sep = "-")),
    mean = means,
    site = site,
    res = res
  )
  # ggplot(means, aes ( x = date, y = mean))+
  #   geom_point()+
  #   labs(title = paste(site, res, "\n",var,file))
  return(means)
})
overview_data = do.call(rbind,overview_data)
#overview_data = overview_data[-grep("monthly_1km/rsds",overview_data)]

### plot and save ----------
ggplot(data = overview_data, aes(x = year(date), 
                                 y = mean, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

ggsave(filename = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/",variable,"_monthly_10km_state",Sys.Date(),".png"),
       width = 28, height = 10, units = "cm", dpi = 100)



# check single year raw data ---------
mask_dir <- file.path(transfer_dir, "mask_files")
yr <- 1941
var <- "prec"
region <- "Europe"
res <- 1

mask_file <- list.files(mask_dir, pattern = region, full.names = T)
mask_file <- mask_file[grep("EPSG4326",mask_file)]
mask_file <- mask_file[grep(paste0(res,"km"),mask_file)]

proj_file <- list.files(mask_dir, pattern = region, full.names = T)
proj_file <- proj_file[grep("buffer",proj_file)]
proj_file <- proj_file[grep(paste0(res,"km"),proj_file)]

yr_fld <- all_dirs[grep(var,all_dirs)]
yr_fld <- yr_fld[grep("CHELSA_downloads",yr_fld)]
yr_fld <- yr_fld[grep(yr,yr_fld)]

year_stack <- rast(list.files(yr_fld,full.names = T)) 
year_mask <- rast(mask_file)
region_year_stack <- crop(year_stack[[1]],year_mask)
#mean.yr <- global(region_year_stack, mean, maxcell = 1e4)
#mean(mean.yr$mean)

year_proj <- rast(proj_file)
year_proj <- terra::project(region_year_stack,year_proj)

plot(year_proj)

# check and correct mask files ---------------

mask_dir <- file.path(transfer_dir, "mask_files")
region <- "Europe"
res <- 10
proji <- "EPSG4326"#"buffer"#"EPSG4326"

mask_file <- list.files(mask_dir, pattern = region, full.names = T)
mask_file <- mask_file[grep(proji,mask_file)]
mask_file <- mask_file[grep(paste0(res,"km"),mask_file)]

yr_mask = rast(mask_file)
plot(yr_mask)
#foo <- ifel(yr_mask < 100000000,0,10) # For Europe EPSG4326
foo <- ifel(yr_mask >=0,1,yr_mask) # For Europe buffer
foo <- ifel(yr_mask > 0,1,yr_mask) # For redoing
plot(foo)

writeRaster(foo, file = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
                               "mask_",region,"_",proji,"_",res,"km_01.tif"),
            overwrite=T)
# 
# fin <- rast( paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
#                     "mask_",region,"_",proji,"_",res,"km_01.tif"))
plot(fin)
scoff(fin)


# mask behaviour testing

# writeRaster(year_mask, file = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
#                                "00_Testmask.tif"),
#             scale  = 0.1,
#             offset = 0,
#             datatype = datatype(year_stack[[1]]),
#             overwrite=T)
# writeRaster(region_year_stack, file = paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
#                                      "00_Testcrop.tif"),
#             scale  = 0.1,
#             offset = 0,
#             datatype = datatype(year_stack[[1]]),
#             overwrite=T)
# 
# year_mask = rast(paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
#                         "00_Testmask2.tif"))
# testcrop = rast(paste0("/home/robert/Documents/00_GitHub_Macro/BMIP_CHELSAV2.1_dataprep/mask_files/",
#                         "00_Testcrop.tif"))
# scoff(year_mask)
