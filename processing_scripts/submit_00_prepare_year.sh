#!/bin/bash
#SBATCH --job-name=prep_year_tasks
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/00_prepare_year_tasks_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/00_prepare_year_tasks_error.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclude=ecoc9j
#SBATCH --cpus-per-task=1
#SBATCH --mem=8gb
#SBATCH --time=01:00:00

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/00_prepare_year_tasks.R
