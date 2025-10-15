# !/usr/bin/env bash
# Script used to run a 40 timestep (40x6=240 hour) model
# Latest Changes: 10/10/2025
# python run_graphcast.py --input /input/filename/with/path --output /path/to/output --weights /path/to/weights --length forecast_length

PYTHON_SCRIPT_PATH="${PYTHON_SCRIPT_PATH:-../graphcast/NCEP/run_graphcast.py}"
BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/"

S3_BUCKET="blueoctopusdata-forecasting-silver"
S3_MODEL="ai"
S3_DATATYPE="netcdf"
S3_EXTRA_ARGS=(--no-progress)

DIFF_STDEV_NC="diffs_stddev_by_level.nc"
MEAN_NC="mean_by_level.nc"
STDEV_NC="stddev_by_level.nc"
BASE_URL="https://storage.googleapis.com/dm_graphcast/graphcast/stats/"

STATS_DIR="/app/data/stats"
INPUT_DIR="/app/data/seeding_data"
OUTPUT_LOC="/app/data/ai_models"

JOB_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG_FILE="/tmp/logs/model_${JOB_ID}.log"

STATE_FILE="${HOME}/latest_gfs.txt"

get_data() {
  stored_path=$(grep '^STORED=' "$STATE_FILE" | cut -d= -f2)
  if [[ -n "$stored_path" ]]; then
    echo "Syncing from $stored_path ..."
    aws s3 sync "$stored_path" "$iNPUT_DIR"
  else
    echo "No stored path found in $STATE_FILE"
  fi
}

# Step 1: Check if the stats directory has the data
check_stats() {
  if [[ -d "$STATS_DIR" && -f "$STATS_DIR/$DIFF_STDEV_NC" && -f "$STATS_DIR/$MEAN_NC" && -f "$STATS_DIR/$STDEV_NC"]]; then
    echo "Stats files exist."
  else
    echo "Missing stat files..."
    download_stats()
  fi
}

# Step 2: Download the necessary stats data
download_stats() {
  mkdir -p "$STATS_DIR"

  curl -fsS -L -C - -o "$STATS_DIR/diffs_stddev_by_level.nc" $DIFF_STEDV_NC
  curl -fsS -L -C - -o "$STATS_DIR/mean_by_level.nc" $MEAN_NC
  curl -fsS -L -C - -o "$STATS_DIR/stddev_by_level.nc" $STDEV_NC
  echo "Downloaded $DIFF_STEDV_NC"
  echo "Downloaded $MEAN_NC"
  echo "Downloaded $STDEV_NC"
}

# Step 3: Run the forecast for each forecast file
run_forecast() {
  local input="$1"
  local forecast_length="$2"

  mkdir -p "$OUTPUT_LOC"

  local python_cmd="python $PYTHON_SCRIPT_PATH"
  python_cmd="$python_cmd --input $input"
  python_cmd="$python_cmd --output $OUTPUT_LOC"
  python_cmd="$python_cmd --weights $STATS_DIR"
  python_cmd="$python_cmd --length $forecast_length"

  echo ""
  echo "$python_cmd"
  echo ""

  if eval "$python_cmd"; then
    echo "Python processing completed successfully for $input"
  else
    echo "FAILED PYTHON RUN for $input"
  fi
}

 
# =====================================================
# MAIN PROGRAM
# =====================================================
#

echo "Started Running Modeller..."

run_url=$(latest_gfs)
if [[ -z "$run_url" ]]; then
  echo "Failed to get latest eligible run URL."
  ((ATTEMPT++))
  sleep "$INTERVAL"
  continue
fi

rid=$(run_id_from_url "$run_url")
day="${rid:0:8}"
run="${rid:8:2}"
LOG_DIR="/tmp/logs/${day}/${run}"
JOB_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOCAL_LOG_FILE="${LOG_DIR}/model_${JOB_ID}.log"
S3_LOG_PATH="s3://${S3_BUCKET}/logs/${day}/${run}/model_${JOB_ID}.log"
mkdir -p "$LOG_DIR"
exec >> >(tee -a "$LOCAL_LOG_FILE") 2>&1

trap ' write_log_to_s3 "$LOCAL_LOG_FILE" "$S3_LOG_PATH" "$rid"' EXIT

work_dir="/app/data/${day}/${run}"
local_out="${work_dir}/outputs"

echo "==============================================================="
echo "Log start for AI Modeller run $rid"
echo "Started at $(date -Is)"
echo "Local log: $LOCAL_LOG_FILE"
echo "S3 log target: $S3_LOG_PATH"
echo "==============================================================="

check_stats

for file in /app/data/*.grib2; do
  [[ -f "$file" ]] || continue
  echo "Uploading $file to S3..."
  aws s3 cp "$file" s3://mybucket/data/
done