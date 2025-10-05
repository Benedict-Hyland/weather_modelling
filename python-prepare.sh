#!/usr/bin/env bash
# Requirements: bash, wget, curl, coreutils, AWS CLI (v2+), Python 3.x, gdas_utility.py

# Latest Changes: 05/10/2025

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

S3_BUCKET="blueoctopusdata-forecasting-bronze"
S3_MODEL="gfs"
S3_DATATYPE_RAW="grib"
S3_DATATYPE_NC="netcdf"
# ${S3_PROJECT}/# S3_PREFIX="gfs-raw-test"
# S3_NC_PREFIX="nc-to-model"

LOCAL_OUTPUT_DIR="${LOCAL_OUTPUT_DIR:-./outputs}"
LOCAL_DOWNLOAD_DIR="${LOCAL_DOWNLOAD_DIR:-./downloads}"

PYTHON_SCRIPT_PATH="${PYTHON_SCRIPT_PATH:-../graphcast/NCEP/gdas_utility.py}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-yes}"

# Polling interval (seconds)
INTERVAL=60
FORECASTS=(f000 f001 f002 f003 f004 f005 f006 f007 f008 f009 f010 f011)

S3_MAX_RETRIES=5
S3_EXTRA_ARGS=(--no-progress)

declare -a MISSING_FORECAST_ITEMS=()
MISSING_FORECAST_HASH=""

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

  MISSING_FORECAST_ITEMS=()
  MISSING_FORECAST_HASH=""

  for f in "${forecasts[@]}"; do
    raw="${atmos}gfs.t${hh}z.pgrb2.0p25.${f}"
    raw_status="$(http_status "$raw")"
    if [[ "$raw_status" != "200" ]]; then
      ok=0
      local file_name="${raw##*/}"
      MISSING_FORECAST_ITEMS+=("${file_name} (HTTP ${raw_status})")
    fi
  done
  if [[ $ok -eq 1 ]]; then
    return 0
  fi

  if (( ${#MISSING_FORECAST_ITEMS[@]} > 0 )); then
    MISSING_FORECAST_HASH="$(printf '%s|' "${MISSING_FORECAST_ITEMS[@]}")"
  fi
  return 1
}

join_by() {
  local IFS="$1"
  shift
  printf '%s\n' "$*"
}

report_missing_forecasts() {
  local rid="$1" context="$2" extra="$3"
  local count=${#MISSING_FORECAST_ITEMS[@]}

  if (( count == 0 )); then
    echo "${context} for ${rid}: all required forecast files are available."
    return
  fi

  local summary
  summary="$(join_by ', ' "${MISSING_FORECAST_ITEMS[@]}")"

  if [[ -n "$extra" ]]; then
    echo "${context} for ${rid}: missing ${count} forecast files (${extra}) -> ${summary}"
  else
    echo "${context} for ${rid}: missing ${count} forecast files -> ${summary}"
  fi
}


wait_for_forecasts() {
  local rid="$1" run_url="$2"

  report_missing_forecasts "$rid" "Initial status"

  local wait_start
  wait_start=$(date +%s)
  local last_log_ts="$wait_start"
  local last_missing_hash="$MISSING_FORECAST_HASH"

  while true; do
    sleep "$INTERVAL"

    if test_forecast_availability "$run_url"; then
      local waited
      waited=$(( $(date +%s) - wait_start ))
      local waited_min=$(( waited / 60 ))
      local waited_sec=$(( waited % 60 ))
      if (( waited_min > 0 )); then
        echo "Required forecast files arrived for $rid after ${waited_min}m ${waited_sec}s."
      else
        echo "Required forecast files arrived for $rid after ${waited_sec}s."
      fi
      return 0
    fi

    local now
    now=$(date +%s)

    if [[ "$MISSING_FORECAST_HASH" != "$last_missing_hash" ]]; then
      report_missing_forecasts "$rid" "Updated status"
      last_missing_hash="$MISSING_FORECAST_HASH"
      last_log_ts="$now"
      continue
    fi

    if (( now - last_log_ts >= 300 )); then
      local elapsed_minutes=$(( (now - wait_start) / 60 ))
      if (( elapsed_minutes > 0 )); then
        report_missing_forecasts "$rid" "Still waiting" "${elapsed_minutes}m elapsed"
      else
        report_missing_forecasts "$rid" "Still waiting" "<1m elapsed"
      fi
      last_log_ts="$now"
    fi
  done
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
  local rid="$1"
  local start_date="$rid"

  echo "Processing GFS data for $rid using Python utility..."

  day="${rid:0:8}"
  run="${rid:8:2}"

  # Per-run working dirs to avoid clashes & make cleanup simple
  local work_root="${LOCAL_WORK_ROOT:-/tmp/gfs-work}/${day}/${run}"
  local local_out="${work_root}/outputs"
  local local_dl="${work_root}/downloads"
  mkdir -p "$local_out" "$local_dl"

  local python_cmd="python $PYTHON_SCRIPT_PATH $day"
  python_cmd="$python_cmd --run $run"
  python_cmd="$python_cmd --output $local_out"
  python_cmd="$python_cmd --download $local_dl"
  python_cmd="$python_cmd --pair true"

  echo "Executing: $python_cmd"
  if eval "$python_cmd"; then
    echo "Python processing completed successfully for $rid"

    if [[ "$STORAGE_MODE" == "s3" ]]; then
      # Upload outputs (NetCDFs)
      s3_bucket_loc=s3://${S3_BUCKET}/${S3_MODEL}/${S3_DATATYPE_NC}/${day}/${run}/
      aws s3 sync "$local_out/" "${s3_bucket_loc}" \
        --only-show-errors "${S3_EXTRA_ARGS[@]}" || {
          echo "ERROR: failed to upload outputs to ${s3_bucket_loc}"
          return 1
        }

      # (Optional) upload downloaded GRIBs too
      if [[ "${UPLOAD_RAW_TO_S3:-no}" == "yes" ]]; then
        s3_bucket_loc=s3://${S3_BUCKET}/${S3_MODEL}/${S3_DATATYPE_RAW}/${day}/${run}
        aws s3 sync "$local_dl/" "${s3_bucket_loc}" \
          --only-show-errors "${S3_EXTRA_ARGS[@]}" || {
            echo "ERROR: failed to upload downloads to ${s3_bucket_loc}"
            return 1
          }
      fi

      # (Optional) cleanup local after successful upload
      if [[ "${CLEANUP_LOCAL_AFTER_S3:-yes}" == "yes" ]]; then
        rm -rf "$work_root"
      fi
    fi
    return 0
  else
    echo "ERROR: Python processing failed for $rid"
    return 1
  fi
}

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
      wait_for_forecasts "$rid" "$run_url"
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
