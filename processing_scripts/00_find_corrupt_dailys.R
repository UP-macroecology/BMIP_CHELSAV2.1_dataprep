
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
transfer_dir <- "/mnt/local_chelsa02/Hauer_BMIP_data/" testing on Linux local mount

## Get overview of missing data:
file_dir <- file.path(transfer_dir, "CHELSA_downloads", "chelsa02", "chelsa", "global", "daily") # from here it's sorted after variables

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

foo = year_summary%>%filter(complete == F, variable !="hurs", year != 2025) 

missing_files = NULL
for(i in 1:dim(foo)[1]){
  expected_dates = seq(as.Date(paste0(foo$year[i],"-01-01")),as.Date(paste0(foo$year[i],"-12-01")),by="days")
  expected_dates = as.POSIXct(expected_dates,tz="UTC")
  missing = expected_dates[which(!expected_dates %in% df$date[df$year == foo$year[i] & df$variable == foo$variable[i]])]
  to_bind = data.frame(year = rep(foo$year[i], times = length(missing)),
                       variable = rep(foo$variable[i], times = length(missing)),
                       date.missing = missing)
  missing_files = rbind(missing_files,to_bind)
}


# specify files to check 
## daily ----------
all_dirs <- list.dirs(transfer_dir)
daily_dirs <- all_dirs[grep("daily_10km",all_dirs)]
#monthly_dirs < all_dirs[grep("monthly_10km",all_dirs)]

daily_files <- list.files(daily_dirs,full.names = T)
daily_files <- daily_files[-grep("pr",daily_files)]
daily_files <- daily_files[grep(".tif",daily_files)]
#monthly_files <- list.files(monthly_dirs,full.names = T)


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

ggplot(data = overview_data, aes(x = year(date), y = mean, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

## monthly ----------
all_dirs <- list.dirs(transfer_dir)
monthly_dirs <- all_dirs[grep("monthly_1km",all_dirs)]
#monthly_dirs < all_dirs[grep("monthly_10km",all_dirs)]

monthly_files <- list.files(monthly_dirs, full.names = TRUE, pattern = "\\.tif$")
#monthly_files <- monthly_files[-grep("pr",monthly_files)]
#monthly_files <- list.files(monthly_dirs,full.names = T)
#monthly_files <- monthly_files[grep("US",monthly_files)]
#monthly_files <- monthly_files[grep("rsds",monthly_files)]
monthly_files <- monthly_files[grep("prec",monthly_files)]


## This takes long

overview_data <- parallel::mclapply(monthly_files,mc.cores = 8, function(x){
  file = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())]
  var = str_split(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-1]
  res = strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-2]
  site =  strsplit(x, "/")[[1]][length(strsplit(x, "/")%>%unlist())-5]
  
  means = global(rast(x), fun = mean, na.rm = TRUE, maxcell = 1e5)
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
overview_data=overview_data[-grep("monthly_1km/prec",overview_data)]

ggplot(data = overview_data, aes(x = year(date), y = mean, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

rsds_data = overview_data %>% 
  filter(variable == "rsds") %>%
  mutate(mean.corrected = ifelse(mean>1000,mean/10,mean))

ggplot(data = rsds_data, aes(x = year(date), y = mean.corrected, group = year(date)))+
  facet_grid(variable~site,scales = "free_y")+
  geom_boxplot()

###
