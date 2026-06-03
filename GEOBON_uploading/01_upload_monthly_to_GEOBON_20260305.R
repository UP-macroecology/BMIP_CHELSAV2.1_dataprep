#SINGLE FOLDER VERSION
# path.to.send = "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/outputs/2_2_CHELSA/Europe/rsds/Equare_1km/"
# 
# files.to.send = list.files(path.to.send)
# 
# target.dir = "s3://eco-code/BMIP_data/Europe/envdat/clim/monthly_1979_2016_1km/rsds/"
# 
# for(i in files.to.send){
#   string.to.system = paste0(c(
#     "s5cmd cp ",
#     paste(path.to.send,i,sep="")," ",
#     paste(target.dir,i,sep="")
#   ), collapse = "")
#   ### send string to system or singularity container ------
#   system(string.to.system)
# }

#FOR FULL MONTHLY VARIABLES
##sudo mount -t cifs -o user=rohering //nas-2-p-sn-01.ibb.uni-potsdam.de/daten$/AG26/Transfer/Hauer_BMIP_data/outputs/2_2_CHELSA /mnt/local_chelsa02/
library(tidyverse)

# CHELSA monthly -----------
##path.to.root = "/mnt/local_chelsa02/Europe"  #for local testing

# path.to.root = "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/outputs/2_2_CHELSA/Europe"
# 
# all.monthly.vars = list.dirs(path.to.root)
# all.monthly.vars = all.monthly.vars[grep("Equare_1km",all.monthly.vars)]
# 
# 
# target.dir = "s3://eco-code/BMIP_data/Europe/envdat/clim/monthly_1979_2016_1km/"
# 
# for(path.to.send in all.monthly.vars){
#   current.var = str_split(path.to.send,"/")[[1]][which(str_split(path.to.send,"/")[[1]]%in%c("pr","rsds","tas","tasmax","tasmin"))]
#   files.to.send = list.files(path.to.send)
#   for(i in files.to.send){
#     string.to.system = paste0(c(
#       "s5cmd sync ",
#       paste(path.to.send,"/",i,sep="")," ",
#       paste(target.dir,current.var,"/",i,sep="")
#     ), collapse = "")
#     ### send string to system or singularity container ------
#     system(string.to.system)
#   }
# }

# BIOCLIM annual -----------
#path.to.root = "/mnt/local_chelsa02/Europe"  #for local testing
path.to.root = "/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/outputs/2_3_BIOCLIM/Europe/bioclims_1km/"


target.dir = "s3://eco-code/BMIP_data/Europe/envdat/clim/annual_bioclim_1979_2016_1km/"

  files.to.send = list.files(path.to.root)
  for(i in files.to.send){
    string.to.system = paste0(c(
      "s5cmd sync ",
      paste(path.to.root,"/",i,sep="")," ",
      paste(target.dir,i,sep="")
    ), collapse = "")
    ### send string to system or singularity container ------
    system(string.to.system)
  }
}