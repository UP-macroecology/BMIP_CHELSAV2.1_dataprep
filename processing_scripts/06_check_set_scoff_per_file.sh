#!/bin/bash

#!/bin/bash
#SBATCH --job-name=setscoff
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-user=hauer@uni-potsdam.de,rohering@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/04_check_set_scoff_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/04_check_set_scoff_error.log
#SBATCH --nodelist=ecoc9z
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=5-00:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=50gb

Rscript  /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/04_check_set_scoff.R --verbose
