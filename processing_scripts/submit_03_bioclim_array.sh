#!/bin/bash
#SBATCH --job-name=bioclim
#SBATCH --array=1-200%10
#SBATCH --mail-type=BEGIN,END,FAIL,TIME_LIMIT_90
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/05_bioclim_task_%A_%a.out
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/05_bioclim_task_%A_%a.err
#SBATCH --nodelist=ecoc9z,ecoc9
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32gb
#SBATCH --time=03:00:00

# IMPORTANT: --array=1-200 must be adjusted to the actual number of rows in
# tasks_todo.rds. This number is printed by 02_prepare_bioclim_1km_tasks.R
# ("Number of tasks still to process: N"). The %10 limits how many tasks run
# at the same time - change it while running with
# 'scontrol update JobId=<id> ArrayTaskThrottle=<N>' if needed. Adjust --mem
# to the actual raster size per region if necessary (Australia/Europe
# probably need more than Finland).

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/03_process_bioclim_1km_task.R
