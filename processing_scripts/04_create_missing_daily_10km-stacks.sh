#!/bin/bash

#!/bin/bash
#SBATCH --job-name=dayStacks
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-user=rohering@uni-potsdam.de,hauer@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/04_create_missing_daily_10km-stacks_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/04_create_missing_daily_10km-stacks_error.log
#SBATCH --nodelist=ecoc9z
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=5-00:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=200gb	

Rscript  /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/04_create_missing_daily_10km-stacks.R --verbose
