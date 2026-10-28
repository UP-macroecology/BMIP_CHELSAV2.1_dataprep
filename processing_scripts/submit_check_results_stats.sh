#!/bin/bash
#SBATCH --job-name=check_results
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/check_results_%A_%a.out
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/check_results_%A_%a.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=48gb
#SBATCH --time=06:00:00
#SBATCH --array=1-40%10
# Usage (RESULTS_DIR and STATS_DIR are required):
#   sbatch --export=ALL,RESULTS_DIR=/import/ecoc9/data-zurell/reeg/test_task,STATS_DIR=/import/ecoc9/data-zurell/reeg/test_task_stats submit_check_results_stats.sh
# The number of chunks must equal the array size (here 40). --mem/--time are placeholders.
# Quick trial: sbatch --array=1 ... (only chunk 1 of 40) and look at the output first.
: "${RESULTS_DIR:?set RESULTS_DIR}"
: "${STATS_DIR:?set STATS_DIR}"
# The file list must be created once BEFORE the array starts (all tasks must use the same list):
#   mkdir -p $STATS_DIR; find $RESULTS_DIR -name '*.tif' | sort > $STATS_DIR/filelist.txt
[ -f "$STATS_DIR/filelist.txt" ] || { echo "ERROR: $STATS_DIR/filelist.txt missing - create it first (see above)" >&2; exit 1; }
N_CHUNKS=${N_CHUNKS:-40}
stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/01-1_check_results_stats.R \
  "$RESULTS_DIR" "$STATS_DIR" "$SLURM_ARRAY_TASK_ID" "$N_CHUNKS"
