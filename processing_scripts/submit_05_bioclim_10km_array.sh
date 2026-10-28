#!/bin/bash
#SBATCH --job-name=bioclim10km
#SBATCH --array=1-76%5
#SBATCH --mail-type=ALL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/08_2_bioclim10km_%A_%a.out
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/08_2_bioclim10km_%A_%a.err
#SBATCH --nodes=1
#SBATCH --nodelist=ecoc9,ecoc9z
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=50gb
#SBATCH --time=08:00:00

# One array task = one region x year (row in tasks_todo.rds of array_prep_bioclim10km).
#
# PLACEHOLDERS: --array=1-76 must equal the number of rows printed by 08_1
# ("Tasks still to process: N"; 76 = 19 years x 4 regions). --mem, --time and the
# throttle (%5) are estimates: run 1-2 tasks first (--array=1-2) and check
#   sacct -j <JOBID> --format=JobID,Elapsed,MaxRSS,State
# Europe/USA need clearly more memory than Finland/Australia.
#
# The task needs the gdalwarp command (gdalUtilities calls it) and writes temporary
# files to the folder set as tmp_dir in 08_2_process_single_task_bioclim_10km.R.
# Selected tasks only (reruns): sbatch --array=5,17,23 submit_08_2_bioclim_10km_array.sh

which gdalwarp > /dev/null || { echo "ERROR: gdalwarp not found" >&2; exit 1; }

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/08_2_process_single_task_bioclim_10km.R
