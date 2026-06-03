#!/bin/bash

#!/bin/bash
#SBATCH --job-name=10bioclm
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-user=hauer@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/2_3_2_BIOCLIM_regional_annual_10km_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/2_3_2_BIOCLIM_regional_annual_10km_error.log
#SBATCH --nodelist=ecoc9z
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=5-00:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=50gb

Rscript  /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/07_create_missing_annual_bioclims_10km-stacks.R --verbose
