#!/bin/bash
#SBATCH --job-name=synEurMo
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-user=rohering@uni-potsdam.de,schifferle1@uni-potsdam.de
#SBATCH --output=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/GEOBON_uploading/logs/Trans-Geobon_Europe1997-2016.log
#SBATCH --error=/mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/GEOBON_uploading/logs/Trans-Geobon_Europe1997-2016_error.log
#SBATCH --nodelist=ecoc9z
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=5-00:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2gb

export AWS_ACCESS_KEY_ID='5d67b64d306c47ac85706569a1a91cd8' \
export AWS_SECRET_ACCESS_KEY='c1ff5f01f1ff4cfab3e28c82747b92f9' \
export S3_ENDPOINT_URL='https://object-arbutus.cloud.computecanada.ca' \

Rscript  /mnt/ibb_share/zurell_transfer/Hauer_BMIP_data/GEOBON_uploading/01_upload_monthly_to_GEOBON_20260305.R --verbose