#!/usr/bin/env bash
# Run a 40-timestep (40x6=240h) model workflow
# Latest Changes: 2025-10-10

###############################################################################
# Config (overridable via env)
###############################################################################
PYTHON="${PYTHON:-python3}"
PYTHON_SCRIPT_PATH="${PYTHON_SCRIPT_PATH:-../graphcast/NCEP/run_graphcast.py}"

# GraphCast stats (Google Cloud public bucket)
BASE_STATS_URL="https://storage.googleapis.com/dm_graphcast/graphcast/stats"
BASE_PARAMS_URL="https://storage.googleapis.com/dm_graphcast/graphcast/params"
DIFF_STDEV_NC="diffs_stddev_by_level.nc"
MEAN_NC="mean_by_level.nc"
STDEV_NC="stddev_by_level.nc"
MODEL_OPERATIONAL="GraphCast_operational - ERA5-HRES 1979-2021 - resolution 0.25 - pressure levels 13 - mesh 2to6 - precipitation output only.npz"
MODEL_FULL="GraphCast - ERA5 1979-2017 - resolution 0.25 - pressure levels 37 - mesh 2to6 - precipitation input and output.npz"
MODEL_SMALL="GraphCast_small - ERA5 1979-2015 - resolution 1.0 - pressure levels 13 - mesh 2to5 - precipitation input and output.npz"


# Local dirs
WEIGHTS_DIR="${WEIGHTS_DIR:-/app/data/weights}"
STATS_DIR="$WEIGHTS_DIR/stats"
PARAMS_DIR="$WEIGHTS_DIR/params"
INPUT_DIR="${INPUT_DIR:-/app/data/seeding_data}"
OUTPUT_LOC="${OUTPUT_LOC:-/app/data/ai_models}"
GLOB_EXT="${GLOB_EXT:-*}"   # e.g. "*.nc" or "*.grib2" (default: all files)

# State + logging
STATE_FILE="${STATE_FILE:-$HOME/latest_gfs.txt}"
JOB_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="${LOG_FILE:-/tmp/logs/model_${JOB_ID}.log}"

# S3 upload target (where forecasts will be pushed)
S3_BUCKET="${S3_BUCKET:-blueoctopusforecasting-silver}"
S3_MODEL="${S3_MODEL:-ai}"
S3_DATATYPE="${S3_DATATYPE:-netcdf}"
S3_EXTRA_ARGS=(${S3_EXTRA_ARGS[@]:---no-progress})

# Forecast length (hours or timesteps per your script; default 240 hours)
FORECAST_LENGTH="${FORECAST_LENGTH:-40}"

###############################################################################
# Helpers
###############################################################################
mkdir -p "$(dirname "$LOG_FILE")" "$INPUT_DIR" "$OUTPUT_LOC" "$STATS_DIR" "$PARAMS_DIR"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "FATAL: Missing command: $1"; exit 127; }
}

read_state_value() {
  # usage: read_state_value KEY
  local key="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  awk -F= -v k="^${key}$" '$1 ~ k {print $2; exit}' "$STATE_FILE"
}

set_state_value() {
  # usage: set_state_value KEY VALUE
  local key="$1" val="$2"
  touch "$STATE_FILE"
  # Replace if exists; else append
  if grep -q "^${key}=" "$STATE_FILE"; then
    sed -i.bak -E "s|^(${key}=).*|\1${val}|" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  else
    printf "%s=%s\n" "$key" "$val" >> "$STATE_FILE"
  fi
}

###############################################################################
# 0) Preconditions
###############################################################################
require_cmd "$PYTHON"
require_cmd curl
require_cmd aws

if [[ ! -f "$PYTHON_SCRIPT_PATH" ]]; then
  log "FATAL: Python script not found: $PYTHON_SCRIPT_PATH"
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  log "FATAL: STATE_FILE not found: $STATE_FILE"
  exit 1
fi

ready_flag="$(read_state_value 'ReadyToModel')"
if [[ "$ready_flag" != "True" ]]; then
  log "ReadyToModel is not True (current: '${ready_flag:-<unset>}'). Exiting."
  exit 0
fi

###############################################################################
# 1) Ensure stats exist (download if missing)
###############################################################################
check_stats() {
  if [[ -f "$STATS_DIR/$DIFF_STDEV_NC" && -f "$STATS_DIR/$MEAN_NC" && -f "$STATS_DIR/$STDEV_NC" ]]; then
    log "Stats present in $STATS_DIR"
    return 0
  fi
  return 1
}

check_params() {
  if [[ -d "$PARAMS_DIR" ]]; then
    # Check if there is at least one non-directory file inside
    if find "$PARAMS_DIR" -mindepth 1 -type f -print -quit | grep -q .; then
      log "Parameter folder exists and contains files: $PARAMS_DIR"
      return 0
    else
      log "Parameter folder exists but is empty: $PARAMS_DIR"
      return 1
    fi
  else
    log "Parameter folder does not exist: $PARAMS_DIR"
    return 1
  fi
}


download_stats() {
  log "Downloading GraphCast stats into $STATS_DIR ..."
  local -a files=("$DIFF_STDEV_NC" "$MEAN_NC" "$STDEV_NC")
  for f in "${files[@]}"; do
    local url="${BASE_STATS_URL}/${f}"
    log "GET $url"
    if ! curl -fSL --retry 10 --retry-delay 3 -C - -o "$STATS_DIR/$f" "$url"; then
      log "FATAL: Failed to download $f"
      return 1
    fi
  done
  return 0
}

download_params() {
  log "Downloading GraphCast params into $PARAMS_DIR ..."
  mkdir -p "$PARAMS_DIR"

  local -a files=("$MODEL_OPERATIONAL" "$MODEL_FULL" "$MODEL_SMALL")
  for f in "${files[@]}"; do
    local url="${BASE_PARAMS_URL%/}/$f"
    log "GET $url"
    if ! curl -fSL --retry 10 --retry-delay 3 -C - -o "$PARAMS_DIR/$f" "$url"; then
      log "FATAL: Failed to download: $f"
      return 1
    fi
  done
  return 0
}


if ! check_stats; then
  download_stats || exit 2
  check_stats || { log "FATAL: Stats still missing after download"; exit 2; }
fi

if ! check_params; then
  download_params || exit 2
  check_params || { log "FATAL: Params still missing after download"; exit 2; }
fi

###############################################################################
# 2) Pull input data from stored S3 path in STATE_FILE
###############################################################################
get_data() {
  # Try several possible keys the state might have
  local stored_path
  stored_path="$(awk -F= '/^(STORED|STORED_PATH|S3_STORED_PATH)=/{print $2; exit}' "$STATE_FILE")"
  final_path="${stored_path%/}/merged_forecasts"
  if [[ -z "$final_path" ]]; then
    log "FATAL: No stored path (STORED=...) found in $STATE_FILE"
    return 1
  fi
  log "Syncing seed data from $final_path -> $INPUT_DIR"
  aws s3 sync "$final_path" "$INPUT_DIR" "${S3_EXTRA_ARGS[@]}"
}

get_data || exit 3

# Confirm there are files to process
shopt -s nullglob
mapfile -t INPUT_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name "$GLOB_EXT" | sort)
total_files="${#INPUT_FILES[@]}"
if (( total_files == 0 )); then
  log "FATAL: No input files found in $INPUT_DIR matching '$GLOB_EXT'"
  exit 4
fi
log "Discovered $total_files input file(s) to process."

###############################################################################
# 3) Run forecast per file, count successes
###############################################################################
success_count=0
run_forecast() {
  local in="$1"
  local cmd=(
    "$PYTHON" "$PYTHON_SCRIPT_PATH"
    --input "$in"
    --output "$OUTPUT_LOC"
    --weights "$WEIGHTS_DIR"
    --length "$FORECAST_LENGTH"
  )

  log "Running: ${cmd[*]}"
  if "${cmd[@]}"; then
    log "SUCCESS: $in"
    return 0
  else
    log "FAIL: $in"
    return 1
  fi
}

for f in "${INPUT_FILES[@]}"; do
  if run_forecast "$f"; then
    ((success_count++))
  fi
done

log "Run summary: success=$success_count / total=$total_files"

if (( success_count != total_files )); then
  log "ERROR: Not all forecasts succeeded. Leaving ReadyToModel as '${ready_flag}'."
  exit 5
fi

###############################################################################
# 4) All succeeded → mark ReadyToModel=Done, then upload forecasts to S3
###############################################################################
set_state_value "ReadyToModel" "Done"
log "STATE_FILE updated: ReadyToModel=Done"

UPLOAD_PREFIX="s3://${S3_BUCKET}/${S3_MODEL}/${S3_DATATYPE}/${JOB_ID}/"
log "Uploading forecasts: $OUTPUT_LOC -> $UPLOAD_PREFIX"
if ! aws s3 sync "$OUTPUT_LOC/" "$UPLOAD_PREFIX" "${S3_EXTRA_ARGS[@]}"; then
  log "FATAL: aws s3 sync failed."
  exit 6
fi

log "Upload complete. Job ${JOB_ID} finished."
exit 0
