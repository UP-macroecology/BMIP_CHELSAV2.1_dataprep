#!/bin/bash

#!/bin/bash
#SBATCH --job-name=mnthStacks
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-user=rohering@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/2_2_CHELSA_regional_monthly_stacks.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/2_2_CHELSA_regional_monthly_stacks_error.log
#SBATCH --nodelist=ecoc9z
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=5-00:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=50gb

Rscript  /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/2_2_CHELSA_MONTHLY_1.R --verbose
