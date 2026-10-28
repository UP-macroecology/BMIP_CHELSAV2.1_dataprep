#!/bin/bash
#SBATCH --job-name=chelsa_year
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=jreeg@uni-potsdam.de
#SBATCH --output=/work/jreeg/BMIP_chelsa/processing_scripts/logs/year_%A_%a_output.log
#SBATCH --error=/work/jreeg/BMIP_chelsa/processing_scripts/logs/year_%A_%a_error.log
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=150gb
#SBATCH --time=24:00:00
#SBATCH --array=1-84%5
# ---------------------------------------------------------------------------
# One array task = one variable x one year (row in tasks_todo.rds), run inside
# the Apptainer container with R + terra.
#
# BEFORE THE FIRST SUBMIT:
#   mkdir -p /work/jreeg/BMIP_chelsa/processing_scripts/logs   (SLURM does not create it)
#   --array must match the number of rows in tasks_todo.rds (84 = one variable,
#   1941-2024). The values for --mem, --time, --cpus-per-task and the throttle (%5)
#   are PLACEHOLDERS: test with --array=1-2 first and check
#     sacct -j <JOBID> --format=JobID,Elapsed,MaxRSS,State
#   hurs: ~240 MB per daily file -> ~88 GB of raw data per task in the scratch area.
#
# Single / selected tasks:  sbatch --array=5,17,23 submit_01_year_array_potsdam.sh
# More than 1000 tasks:     sbatch --export=ALL,TASK_OFFSET=1000 --array=1-<rest>%5 ...
# Test mode (writes nothing into the real results folder):
#   sbatch --export=ALL,TEST_OUT_DIR=/work/jreeg/BMIP_chelsa/test_task --array=1 submit_01_year_array_potsdam.sh
# ---------------------------------------------------------------------------

SIF=/work/jreeg/rstudio_4.5_terra.sif
BASE=/work/jreeg/BMIP_chelsa                      # scratch + data + scripts
SCRIPT=${BASE}/processing_scripts/01_process_year_task.R

# module load apptainer     # only if apptainer is not on the PATH of the compute nodes

TASK_OFFSET=${TASK_OFFSET:-0}
TASK_ID=$((SLURM_ARRAY_TASK_ID + TASK_OFFSET))

# Proxy (wget in fetch_and_check() reads these variables)
export http_proxy=http://proxy2.uni-potsdam.de:3128
export https_proxy=http://proxy2.uni-potsdam.de:3128

# R library of the container setup (same as in the RStudio session script)
export R_LIBS_USER=${HOME}/R/rocker-rstudio/4.5.2
export R_LIBS=''
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}

# Temporary directory in the scratch area (terra writes large temporary files)
export TMPDIR=${BASE}/tmp_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Node: $(hostname) | Task: ${TASK_ID} | TMPDIR: ${TMPDIR}"
df -h "$BASE" | tail -1

# Pre-flight checks inside the container: tools needed by fetch_and_check() + server reachable
apptainer exec --bind "${BASE}" "${SIF}" bash -c 'which wget gdalinfo Rscript' || {
  echo "ERROR: wget/gdalinfo/Rscript missing in the container" >&2; exit 1; }
apptainer exec --bind "${BASE}" "${SIF}" \
  wget -q --spider --timeout=30 --tries=1 https://os.unil.cloud.switch.ch/chelsa02/ || {
  echo "ERROR: CHELSA server not reachable from this node (proxy?)" >&2; exit 1; }

apptainer exec \
  --bind "${BASE}" --bind "${TMPDIR}:/tmp" \
  "${SIF}" \
  stdbuf -oL -eL Rscript "${SCRIPT}" "${TASK_ID}" "${TEST_OUT_DIR:-}"
