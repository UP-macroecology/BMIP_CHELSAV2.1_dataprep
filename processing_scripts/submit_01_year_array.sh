#!/bin/bash
#SBATCH --job-name=chelsa_year
#SBATCH --mail-type=ALL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/year_%A_%a_output.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/logs/year_%A_%a_error.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=95gb
#SBATCH --time=48:00:00
#SBATCH --exclude=ecoc9j
#SBATCH --array=1-1000%10
# ---------------------------------------------------------------------------
# One array task = one variable x one year (row in tasks_todo.rds).
#
# PLACEHOLDERS: adjust --mem, --time, --cpus-per-task and the throttle (%10)
# only after a test run with 1-2 tasks (e.g. --array=1-2), based on
#   sacct -j <JOBID> --format=JobID,Elapsed,MaxRSS,State
# --exclude=ecoc9j is an ASSUMPTION (only ecoc9/ecoc9z have the scratch space
# and internet access) - check the node names with `sinfo -N`.
#
# MaxArraySize = 1001: for more than 1000 tasks use an offset, e.g.
#   sbatch --export=ALL,TASK_OFFSET=1000 --array=1-<remainder>%10 submit_01_year_array.sh
# Only selected tasks (e.g. reruns): sbatch --array=5,17,23 ...
# ---------------------------------------------------------------------------

# Test mode (writes NOTHING into GEOBON_results): sbatch --export=ALL,TEST_OUT_DIR=/path/to/testfolder --array=1 submit_01_year_array.sh
TASK_OFFSET=${TASK_OFFSET:-0}
TASK_ID=$((SLURM_ARRAY_TASK_ID + TASK_OFFSET))

SCRATCH=/import/ecoc9/data-zurell/reeg
export TMPDIR=${SCRATCH}/tmp_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Node: $(hostname) | Task: ${TASK_ID} | TMPDIR: ${TMPDIR}"
df -h "$SCRATCH" | tail -1

stdbuf -oL -eL Rscript /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/processing_scripts/01_process_year_task.R "${TASK_ID}" "${TEST_OUT_DIR:-}"
