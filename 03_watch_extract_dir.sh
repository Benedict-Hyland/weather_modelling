#!/usr/bin/env bash
set -euo pipefail

# Install with: sudo apt install inotify-tools
# Monitors “closed after write” or “moved into” under ./data recursively

inotifywait -m -r -e close_write,moved_to --format '%w%f' ./extraction_data \
| while read -r fullpath; do
    # strip off everything up to and including “data/”
    rel=${fullpath#*data/}
    echo "New file ready: data/$rel"

    extract_parts $rel
    output_file="${DATE}_${HOUR}_${FORECAST}_${LEVEL}.grib2"

    # If all level files exist for the date, hour and forecast then merge them using merge.sh
    

  done

extract_parts() {
  local __path=$1

  # regex breakdown:
  #  ^data/([0-9]{8})_([0-9]{2})/        → capture YYYYMMDD and HH
  #  gfs\.t[0-9]{2}z\.                  → literal "gfs.tHHz."
  #  (pgrb2b|pgrb2|sfluxgrb)             → capture one of the three types
  #  [^/]*                               → any extra (e.g. ".0p25")
  #  \.f([0-9]{3})                       → capture the 3‑digit period
  #  (?:\.grib2)?$                       → optional ".grib2" at end
  if [[ $__path =~ ^([0-9]{8})_([0-9]{2})_f([0-9]{3})_((pgrb2b|pgrb2|sfluxgrb))(?:\.grib2)?$ ]]; then
    # assign by name
    printf -v "DATE"   '%s' "${BASH_REMATCH[1]}"
    printf -v "HOUR"   '%s' "${BASH_REMATCH[2]}"
    printf -v "FORECAST" 'f%s' "${BASH_REMATCH[3]}"
    printf -v "LEVEL"   '%s' "${BASH_REMATCH[4]}"
    return 0
  else
    return 1
  fi
}
