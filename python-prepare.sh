#!/usr/bin/env bash
# Requirements: bash, wget, curl, coreutils, AWS CLI (v2+), Python 3.x, gdas_utility.py

###############################################################################
# Config — edit these
###############################################################################

BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/"
STATE_FILE="${HOME}/latest_gfs.txt"

# ntfy topics
NTFY_NEW_RUN="https://ntfy.sh/gfs_latest_file"
NTFY_DATA_ARRIVED="https://ntfy.sh/gfs_latest_data"
NTFY_S3_DOWNLOADED="https://ntfy.sh/gfs_downloaded_s3"

STORAGE_MODE="${STORAGE_MODE:-s3}"

S3_BUCKET="graphcast-gfs-forecasts"
S3_PREFIX="gfs-raw-test"
S3_NC_PREFIX="nc-to-model"

LOCAL_OUTPUT_DIR="${LOCAL_OUTPUT_DIR:-./outputs}"
LOCAL_DOWNLOAD_DIR="${LOCAL_DOWNLOAD_DIR:-./downloads}"

PYTHON_SCRIPT_PATH="${PYTHON_SCRIPT_PATH:-../graphcast/NCEP/gdas_utility.py}"
PRESSURE_LEVELS="${PRESSURE_LEVELS:-13}"
PROCESSING_METHOD="${PROCESSING_METHOD:-wgrib2}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-yes}"

# Polling interval (seconds)
INTERVAL=60
FORECASTS=(f000 f001 f002 f003 f004 f005 f006 f007 f008 f009 f010 f011)

S3_MAX_RETRIES=5
S3_EXTRA_ARGS=(--no-progress)

###############################################################################
###############################################################################

# Only consider hours 00, 06, 12, 18
latest_gfs() {
  local dates d hours h
  dates=$(wget -qO- "$BASE" | grep -Eo 'gfs\.[0-9]{8}/' | sort -r) || return 1
  for d in $dates; do
    hours=$(wget -qO- "${BASE}${d}" | grep -Eo '(00|06|12|18)/' | tr -d '/' | sort -n)
    h=$(echo "$hours" | tail -1)
    if [[ -n "$h" ]]; then
      printf "%s%s%02d/\n" "$BASE" "$d" "$h"
      return 0
    fi
  done
  return 1
}

http_status() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}\n" -L --retry 3 --connect-timeout 10 "$url"
}

test_forecast_availability() {
  local run_url="$1" hh atmos raw raw_status ok=1
  [[ -z "$run_url" ]] && return 2

  hh="${run_url%/}"; hh="${hh##*/}"; printf -v hh "%02d" "$hh"
  atmos="${run_url}atmos/"

  local forecasts=("${FORECASTS[@]}")
  if (( ${#forecasts[@]} == 0 )); then
    forecasts=(f000 f011) # minimal readiness check
  fi

  for f in "${forecasts[@]}"; do
    raw="${atmos}gfs.t${hh}z.pgrb2.0p25.${f}"
    raw_status="$(http_status "$raw")"
    echo "Check: $raw -> $raw_status"
    if [[ "$raw_status" != "200" ]]; then ok=0; fi
  done
  [[ $ok -eq 1 ]]
}


run_id_from_url() {
  local url="$1" ymd hh
  ymd=$(echo "$url" | sed -n 's#.*/gfs\.\([0-9]\{8\}\)/[0-9]\{2\}/$#\1#p')
  hh=$(echo "$url"  | awk -F'/' '{print $(NF-1)}')
  printf "%s%02d\n" "$ymd" "$hh"
}

notify_ntfy() {
  local topic="$1" msg="$2"
  curl -s -S -o /dev/null -w "%{http_code}" -H "Title: GFS Python Watcher" -d "$(date) $msg" "$topic" || echo 000
}

read_last_id() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  sed -n 's/^RUN_ID=\(.*\)$/\1/p' "$STATE_FILE" | tail -1
}

yyyy_mm_dd_from_runid() {
  local rid="$1"; printf "%s-%s-%s\n" "${rid:0:4}" "${rid:4:2}" "${rid:6:2}"
}

hour_from_runid() {
  local rid="$1"; printf "%s\n" "${rid:8:2}"
}

###############################################################################
###############################################################################
process_with_python() {
  local rid="$1"  # YYYYMMDDHH
  local start_date="$rid"
  local end_date="$rid"  # Same date for single run processing
  
  echo "Processing GFS data for $rid using Python utility..."
  
  local python_cmd="python $PYTHON_SCRIPT_PATH $start_date $end_date"
  python_cmd="$python_cmd --level $PRESSURE_LEVELS"
  python_cmd="$python_cmd --source nomads"
  python_cmd="$python_cmd -m $PROCESSING_METHOD"
  python_cmd="$python_cmd --pair true"
  python_cmd="$python_cmd --keep $KEEP_DOWNLOADS"
  
  if [[ "$STORAGE_MODE" == "s3" ]]; then
    python_cmd="$python_cmd --output s3://${S3_BUCKET}/${S3_NC_PREFIX}"
    python_cmd="$python_cmd --download s3://${S3_BUCKET}/${S3_PREFIX}"
  else
    mkdir -p "$LOCAL_OUTPUT_DIR" "$LOCAL_DOWNLOAD_DIR"
    python_cmd="$python_cmd --output $LOCAL_OUTPUT_DIR"
    python_cmd="$python_cmd --download $LOCAL_DOWNLOAD_DIR"
  fi
  
  echo "Executing: $python_cmd"
  
  if eval "$python_cmd"; then
    echo "Python processing completed successfully for $rid"
    return 0
  else
    echo "ERROR: Python processing failed for $rid"
    return 1
  fi
}

# upload_to_s3_if_needed() {
#   local rid="$1"
  
#   if [[ "$STORAGE_MODE" == "s3" ]]; then
#     echo "Data already processed directly to S3"
#     return 0
#   else
#     echo "Local storage mode - no S3 upload needed"
#     return 0
#   fi
# }

write_state_after_processing() {
  local run_url="$1" rid="$2"
  {
    echo "RUN_ID=${rid}"
    echo "RUN_URL=${run_url}"
    echo "STORAGE_MODE=${STORAGE_MODE}"
    echo "PYTHON_PROCESSED=true"
    echo "UPDATED_AT=$(date -Is)"
  } > "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

###############################################################################
# Main loop
###############################################################################
echo "Starting GFS Python watcher. State: $STATE_FILE"
echo "Eligible hours: 00, 06, 12, 18"
echo "Storage mode: $STORAGE_MODE"
if [[ "$STORAGE_MODE" == "s3" ]]; then
  echo "S3 bucket: s3://${S3_BUCKET}/${S3_NC_PREFIX}"
else
  echo "Local output: $LOCAL_OUTPUT_DIR"
  echo "Local downloads: $LOCAL_DOWNLOAD_DIR"
fi
echo "Python script: $PYTHON_SCRIPT_PATH"
echo "Pressure levels: $PRESSURE_LEVELS"
echo "Processing method: $PROCESSING_METHOD"
echo "Interval: ${INTERVAL}s"
echo

while true; do
  run_url=$(latest_gfs) || { echo "Failed to get latest eligible run."; sleep "$INTERVAL"; continue; }

  rid=$(run_id_from_url "$run_url")
  last_id=$(read_last_id)

  if [[ "$rid" != "$last_id" && -n "$rid" ]]; then
    echo "Newer eligible run detected: $rid (prev: ${last_id:-none})"

    notify_ntfy "$NTFY_NEW_RUN" "New GFS run (eligible hour): $rid
$run_url" >/dev/null 2>&1 || true

    if test_forecast_availability "$run_url"; then
      echo "Required forecast files are present."
    else
      echo "Waiting for required forecast files to arrive (poll ${INTERVAL}s)…"
      while true; do
        sleep "$INTERVAL"
        echo "Rechecking ${rid}…"
        if test_forecast_availability "$run_url"; then
          echo "Required forecast files arrived for $rid."
          break
        fi
      done
    fi

    notify_ntfy "$NTFY_DATA_ARRIVED" "GFS data available for $rid
Run: $run_url
Processing with Python utility..." >/dev/null 2>&1 || true

    if process_with_python "$rid"; then
      echo "Python processing completed successfully."
      write_state_after_processing "$run_url" "$rid"
      echo "State updated: $STATE_FILE"
      
      if [[ "$STORAGE_MODE" == "s3" ]]; then
        notify_ntfy "$NTFY_S3_DOWNLOADED" "Python processed data uploaded to S3 for $rid" >/dev/null 2>&1 || true
      else
        notify_ntfy "$NTFY_S3_DOWNLOADED" "Python processed data saved locally for $rid" >/dev/null 2>&1 || true
      fi
    else
      echo "ERROR: Python processing failed for $rid."
      notify_ntfy "$NTFY_S3_DOWNLOADED" "Python processing FAILED for $rid" >/dev/null 2>&1 || true
      continue
    fi

  else
    sleep "$INTERVAL"
  fi
done
