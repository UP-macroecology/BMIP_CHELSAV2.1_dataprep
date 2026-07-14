library(tidyverse)

# Define paths ----------

## make local mounts if necessary, e.g.:
##sudo mount -t cifs -o user=rohering //nas-2-p-sn-01.ibb.uni-potsdam.de/daten$/AG26/Transfer /mnt/local_chelsa02/

## Path to root folder of downloaded CHELSA files
#path.to.root = "/mnt/local_chelsa02/Hauer_BMIP_data/CHELSA_downloads/downloading_new_data/"  #for local testing
#path.to.root = "/mnt/local_chelsa02/CHELSA_downloads/" # for local testing
path.to.root = "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/CHELSA_downloads/"

## Path where to download to
target.dir = "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/CHELSA_downloads/"

## Path where to download from
online.location = "https://os.unil.cloud.switch.ch/chelsa02/"

setwd(path.to.root)

#Start while-loop ------
## to check if new files, that have not been downloaded yet, appeared at the online.location
## running until all files exist
missing.files = c("a", "b", "c") # a non-empty place holder

while (length(missing.files) != 0) {
  ## ensuring that the script does not run all the time
  if (hour(Sys.time()) %in% c(6, 8, 10, 12, 14, 16, 20)) {
    # check and download non-downloaded files ---------
    ## check current files -------
    current.files = list.files("chelsa02/", recursive = T) #../chelsa02/ for local testing
    
    current.table.foo = strsplit(current.files, "/") %>% unlist()
    
    ### create overview of current data
    current.data = data.frame(
      model = current.table.foo[base::seq(from = 1,
                                          to = length(current.table.foo),
                                          by = 6)],
      geo = current.table.foo[base::seq(from = 2,
                                        to = length(current.table.foo),
                                        by = 6)],
      time = current.table.foo[base::seq(from = 3,
                                         to = length(current.table.foo),
                                         by = 6)],
      variable = current.table.foo[base::seq(from = 4,
                                             to = length(current.table.foo),
                                             by = 6)],
      year = current.table.foo[base::seq(from = 5,
                                         to = length(current.table.foo),
                                         by = 6)],
      file = current.table.foo[base::seq(from = 6,
                                         to = length(current.table.foo),
                                         by = 6)]
    ) %>%
      arrange(model, geo, time, variable, year, file)
    
    ### a summary of the current data
    state.current.data = current.data %>%
      group_by(model, geo, time, variable, year) %>%
      reframe(n.current.files = n())
    
    ## create list of all expected files -------
    file.dates = c(seq(
      from = as.POSIXct("1941-01-01", tz = "UTC"),
      to = as.POSIXct("2024-12-31", tz = "UTC"), #We stop in 2024 since data for 2025 does not cover the whole year
      by = 3600 * 24
    ))
    file.ext = "V.2.1.tif"
    all.vars = c(unique(state.current.data$variable), "hurs", "prec", "rsds") %>%
      unique()
    
    all.files = lapply(all.vars, function(x)
      paste(
        current.data$model[1],
        "/",
        current.data$geo[1],
        "/",
        current.data$time[1],
        "/",
        x,
        "/",
        as.character(year(file.dates)),
        "/",
        "CHELSA",
        "_",
        x,
        "_",
        as.character(file.dates %>% format("%d_%m_%Y")),
        "_",
        file.ext,
        sep = ""
      )) %>% unlist()
    
    all.table.foo = strsplit(all.files, "/") %>% unlist()
    
    ### an object with the full list of expected files
    all.data = data.frame(
      model = all.table.foo[seq(from = 1,
                                to = length(all.table.foo),
                                by = 6)],
      geo = all.table.foo[seq(from = 2,
                              to = length(all.table.foo),
                              by = 6)],
      time = all.table.foo[seq(from = 3,
                               to = length(all.table.foo),
                               by = 6)],
      variable = all.table.foo[seq(from = 4,
                                   to = length(all.table.foo),
                                   by = 6)],
      year = all.table.foo[seq(from = 5,
                               to = length(all.table.foo),
                               by = 6)],
      file = all.table.foo[seq(from = 6,
                               to = length(all.table.foo),
                               by = 6)]
    ) %>%
      arrange(model, geo, time, variable, year, file)
    
    
    ### if files need to be excluded:
    #years.not.in.pr = c(1941:1979,2020:2025)
    #years.not.in.prec = c(1979:2020)

    # non.existing.files = c(
    #   all.data$file[all.data$variable == "pr" &
    #                       all.data$year %in% years.not.in.pr],
    #   all.data$file[all.data$variable == "prec" &
    #                   all.data$year %in% years.not.in.prec])
    #
    # all.files = all.files[which(!all.data$file%in%non.existing.files)]
    
    ### a summary of the expected data
    state.all.data = all.data %>%
      #filter(!file %in% non.existing.files) %>%
      group_by(model, geo, time, variable, year) %>%
      reframe(n.all.files = n())
    
    ## compare and identifiy missing files -------
    print(Sys.time())
    current.overview = state.all.data %>%
      left_join(state.current.data) %>%
      mutate(n.current.files = replace_na(n.current.files, 0)) %>%
      mutate(prop.downloaded = n.current.files / n.all.files) %>%
      #filter(prop.downloaded < 1) %>%
      group_by(variable) %>%
      reframe(
        n.incomplete.years = length(year[which(prop.downloaded < 1)]),
        prop.downloaded.files = sum(prop.downloaded) / n(),
        n.files = sum(n.current.files)
      ) %>%
      print(n = 100)
    
    ## downloaded files which are expected but missing 
    missing.files = all.files[which(!all.files %in% current.files)]
    print(paste0("Files which are missing (without pr and without 2025):", missing.files[-grep("/pr/",missing.files)]))
    
    ## send download request for missing files -----------
    for (i in missing.files) {
      #missing.files[length(missing.files)-5100] # for testing (! will run for long times, needs to be stopped)
      string.to.system = paste0(
        c(
          "wget --no-verbose --no-host-directories --force-directories -P ",
          target.dir,
          " ",
          paste(online.location, i, sep = "") #missing.files[x]
        ),
        collapse = ""
      )
      ### send string to system or singularity container ------
      system(string.to.system)
    }
  }
  #missing.files = all.files[which(!current.files %in% current.files)] #only for testing
}
