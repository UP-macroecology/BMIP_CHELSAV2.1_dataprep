#!/bin/bash
#SBATCH --job-name=prep_bioclim10km
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/08_1_prepare_bioclim10km_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/08_1_prepare_bioclim10km_error.log
#SBATCH --exclude=ecoc9j
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16gb
#SBATCH --time=01:00:00

# Runs ONCE. Prints "Tasks still to process: N" - use N for --array in
# submit_08_2_bioclim_10km_array.sh. Settings (run_for_all_years, force_years, test_out_dir,
# source_dir) are in 08_1_prepare_tasks_bioclim_10km.R.

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/04_prepare_bioclim_10km_tasks.R
