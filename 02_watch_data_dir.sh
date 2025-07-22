#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="./data"
EXTRACT_DIR="./extraction_data"
OUTPUT_FILE="$EXTRACT_DIR/to_edit.txt"

mkdir -p "$DATA_DIR" "$EXTRACT_DIR"
touch "$OUTPUT_FILE"

# Cache to track arrivals
declare -A seen

# Helper: subtract 6 hours from YYYYMMDD_HH and return new YYYYMMDD_HH
subtract_6h() {
  local datetime="$1"  # YYYYMMDD_HH
  local date_part="${datetime%_*}"  # YYYYMMDD
  local hour_part="${datetime#*_}"  # HH

  # Build full timestamp in a safe format
  local formatted_date="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${hour_part}:00:00"

  # Subtract 6h using GNU date
  local new_time
  new_time=$(date -u -d "$formatted_date -6 hours" +%Y%m%d_%H)

  echo "$new_time"
}

extract_parts() {
  local path="$1"

  # ---- 1) pgrb2b files ----
  if [[ "$path" =~ ^([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.pgrb2b[^/]*\.f([0-9]{3})(\.grib2)?$ ]]; then
    DATE="${BASH_REMATCH[1]}"
    HOUR="${BASH_REMATCH[2]}"
    LEVEL="b"
    FORECAST="${BASH_REMATCH[3]}"
    cp "$DATA_DIR/$path" "$EXTRACT_DIR/${DATE}_${HOUR}_${FORECAST}_pgrbb.grib2"
    return 0
  fi

  # ---- 2) pgrb2 files ----
  if [[ "$path" =~ ^([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.pgrb2[^/]*\.f([0-9]{3})(\.grib2)?$ ]]; then
    DATE="${BASH_REMATCH[1]}"
    HOUR="${BASH_REMATCH[2]}"
    LEVEL="a"
    FORECAST="${BASH_REMATCH[3]}"
    cp "$DATA_DIR/$path" "$EXTRACT_DIR/${DATE}_${HOUR}_${FORECAST}_pgrba.grib2"
    return 0
  fi

  return 1
}

echo "[INFO] Watching $DATA_DIR for new files…"

inotifywait -m -r -e close_write,moved_to --format '%w%f' "$DATA_DIR" |
while read -r fullpath; do
  rel="${fullpath#"$DATA_DIR"/}"

  echo "[INFO] New file detected: $rel"

  if ! extract_parts "$rel"; then
    echo "[WARN] Skipping unrecognized: $rel"
    continue
  fi

  key="${DATE}_${HOUR}_${FORECAST}"

  echo "[DEBUG] Parsed → DATE=$DATE HOUR=$HOUR LEVEL=$LEVEL FORECAST=$FORECAST"

  # Mark this level as seen
  seen_key="$key:$LEVEL"
  seen["$seen_key"]=1

  # Check if BOTH a+b exist
  if [[ -n "${seen["$key:a"]:-}" && -n "${seen["$key:b"]:-}" ]]; then
    echo "[INFO] Both pgrb2 & pgrb2b found for $key"

    current_line="${DATE}_${HOUR}_f${FORECAST}"
    six_hours_before=$(subtract_6h "${DATE}_${HOUR}")
    previous_line="${six_hours_before}_f${FORECAST}"

    echo "${current_line}, ${previous_line}" | tee -a "$OUTPUT_FILE"

    # Optional: remove from cache to avoid duplicate triggers
    unset seen["$key:a"]
    unset seen["$key:b"]
  fi
done
