#!/usr/bin/env bash
set -euo pipefail

# Requirements:
#   sudo apt install inotify-tools
# Monitors “close_write” or “moved_to” under ./data recursively

DATA_DIR="./data"
EXTRACT_DIR="./extraction_data"

# Ensure directories exist
mkdir -p "$DATA_DIR" "$EXTRACT_DIR"

extract_parts() {
  local path="$1"

  # ---- 1) pgrb2b files (e.g. gfs.t00z.pgrb2b.0p25.f005[.grib2]) ----
  if [[ "$path" =~ ^([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.pgrb2b([^/]*)\.f([0-9]{3})(\.grib2)?$ ]]; then
    echo "[DEBUG] PGRB2B File Found: $path"
    DATE="${BASH_REMATCH[1]}"
    HOUR="${BASH_REMATCH[2]}"
    LEVEL="pgrbb"
    FORECAST="${BASH_REMATCH[4]}"
    return 0
  fi

  # ---- 2) pgrb2 files (e.g. gfs.t00z.pgrb2.0p25.f005[.grib2]) ----
  if [[ "$path" =~ ^([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.pgrb2([^/]*)\.f([0-9]{3})(\.grib2)?$ ]]; then
    echo "[DEBUG] PGRB2 File Found: $path"
    DATE="${BASH_REMATCH[1]}"
    HOUR="${BASH_REMATCH[2]}"
    LEVEL="pgrba"
    FORECAST="${BASH_REMATCH[4]}"
    return 0
  fi


  # ---- 3) sfluxgrb files (e.g. gfs.t00z.sfluxgrbf000.grib2) ----
  if [[ "$path" =~ ^([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.(sfluxgrb)f([0-9]{3})(\.grib2)?$ ]]; then
    echo "[DEBUG] SFLUXGRB File Found: $path"
    DATE="${BASH_REMATCH[1]}"
    HOUR="${BASH_REMATCH[2]}"
    LEVEL="sfluxgrb"
    FORECAST="${BASH_REMATCH[4]}"
    return 0
  fi

  return 1
}

# Warn if extract scripts aren’t executable
for script in ./02_extract_pressure.sh ./02_extract_pressure_b.sh ./02_extract_surface.sh; do
  [[ -x "$script" ]] || echo "Warning: $script not found or not +x"
done

echo "[INFO] Watching $DATA_DIR for new files…"

inotifywait -m -r -e close_write,moved_to --format '%w%f' "$DATA_DIR" \
| while read -r fullpath; do
    # strip leading “data/”
    rel="${fullpath#"$DATA_DIR"/}"

    echo "[INFO] New file detected: $rel"

    if ! extract_parts "$rel"; then
      echo "[WARN] Skipping unrecognized: $rel"
      continue
    fi

    echo "[DEBUG] Parsed → DATE=$DATE HOUR=$HOUR LEVEL=$LEVEL FORECAST=$FORECAST"

    input="$DATA_DIR/$rel"
    output="$EXTRACT_DIR/${DATE}_${HOUR}_${FORECAST}_${LEVEL}.grib2"

    case "$LEVEL" in
      pgrba)
        echo "[INFO] Extracting pressure → $output"
        ./02_extract_pressure.sh "$input" "$output"
        ;;
      pgrbb)
        echo "[INFO] Extracting pressure_b → $output"
        ./02_extract_pressure_b.sh "$input" "$output"
        ;;
      sfluxgrb)
        echo "[INFO] Extracting surface → $output"
        ./02_extract_surface.sh "$input" "$output"
        ;;
      *)
        # (should never happen)
        echo "[ERROR] Unknown LEVEL='$LEVEL'"
        ;;
    esac
done
