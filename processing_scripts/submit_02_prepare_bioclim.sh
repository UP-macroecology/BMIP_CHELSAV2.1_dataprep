#!/bin/bash
#SBATCH --job-name=prep_bioclim_tasks
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/02_prepare_bioclim_1km_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/02_prepare_bioclim_1km_error.log
#SBATCH --exclude=ecoc9j
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16gb
#SBATCH --time=02:00:00

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/02_prepare_bioclim_1km_tasks.R
