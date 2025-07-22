#!/usr/bin/env bash
set -euo pipefail

# Watcher script that monitors extraction_data for pgrba, pgrbb, sfluxgrb files
# When all three files with matching date/hour/forecast are present, merges them into a single GRIB file

# Create directories if they don't exist
mkdir -p ./extraction_data
mkdir -p ./merged_data

# Install with: sudo apt install inotify-tools
# Monitors "closed after write" or "moved into" under ./extraction_data recursively

declare -A file_sets

extract_parts() {
  local __path=$1

  # regex breakdown:
  #  ^([0-9]{8})_([0-9]{2})_([0-9]{3})_((pgrba|pgrbb|sfluxgrb))(?:\.grib2)?$ 
  #  captures: DATE, HOUR, FORECAST, LEVEL_TYPE
  # output="$EXTRACT_DIR/${DATE}_${HOUR}_${FORECAST}_${LEVEL}.grib2"
  if [[ $__path =~ ^([0-9]{8})_([0-9]{2})_([0-9]{3})_((pgrba|pgrbb|sfluxgrb))(\.grib2)?$ ]]; then
    # assign by name
    printf -v "DATE"     '%s' "${BASH_REMATCH[1]}"
    printf -v "HOUR"     '%s' "${BASH_REMATCH[2]}"
    printf -v "FORECAST" '%s' "${BASH_REMATCH[3]}"
    printf -v "LEVEL"    '%s' "${BASH_REMATCH[4]}"
    return 0
  else
    return 1
  fi
}

check_and_process_complete_set() {
  local date_hour_forecast="$1"
  local extraction_dir="./extraction_data"
  
  # Check if all three required files exist
  local pgrba_file="${extraction_dir}/${date_hour_forecast}_pgrba.grib2"
  local pgrbb_file="${extraction_dir}/${date_hour_forecast}_pgrbb.grib2"
  local sfluxgrb_file="${extraction_dir}/${date_hour_forecast}_sfluxgrb.grib2"
  
  if [[ -f "$pgrba_file" && -f "$pgrbb_file" && -f "$sfluxgrb_file" ]]; then
    echo "Complete set found for $date_hour_forecast - processing..."
    
    local merged_file="./merged_data/${date_hour_forecast}_merged.grib2"
    
    # Skip if already processed
    if [[ -f "$merged_file" ]]; then
      echo "Already processed: $merged_file exists"
      return 0
    fi
    
    echo "Merging files with wgrib2..."
    # Use wgrib2 to merge the three files
    cat "$pgrba_file" "$pgrbb_file" "$sfluxgrb_file" > "$merged_file"
    
    if [[ $? -eq 0 ]]; then
      echo "Successfully merged to: $merged_file"
    else
      echo "Error: Failed to merge grib files for $date_hour_forecast"
    fi
  fi
}

echo "Starting watcher for GRIB file merging..."
echo "Monitoring ./extraction_data for pgrba, pgrbb, sfluxgrb files..."

inotifywait -m -r -e close_write,moved_to --format '%w%f' ./extraction_data \
| while read -r fullpath; do
    # Extract just the filename
    filename=$(basename "$fullpath")
    echo "New file detected: $filename"
    
    if extract_parts "$filename"; then
        date_hour_forecast="${DATE}_${HOUR}_${FORECAST}"
        echo "Parsed: date=$DATE, hour=$HOUR, forecast=$FORECAST, level=$LEVEL"
        
        # Check if we now have a complete set
        check_and_process_complete_set "$date_hour_forecast"
    else
        echo "File $filename does not match expected pattern - skipping"
    fi
done
