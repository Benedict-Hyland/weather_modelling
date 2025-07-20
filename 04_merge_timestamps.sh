#!/usr/bin/env bash
set -euo pipefail

# Watcher script that monitors merged_data for .grib2 files
# When it finds two files that are 6 hours apart from different runs with the same forecast time,
# it extracts those .grib2 files and prints a detection message

# Create directories if they don't exist
mkdir -p ./merged_data
mkdir -p ./timestamp_merged

# Install with: sudo apt install inotify-tools
# Monitors "closed after write" or "moved into" under ./merged_data recursively

declare -A processed_pairs

extract_grib_parts() {
    local __path=$1
    
    # regex breakdown:
    # ^([0-9]{8})_([0-9]{2})_f([0-9]{3})_merged\.grib2$
    # captures: DATE, HOUR, FORECAST from filename like 20250708_18_f000_merged.grib2
    if [[ $__path =~ ^([0-9]{8})_([0-9]{2})_([0-9]{3})_merged\.grib2$ ]]; then
        printf -v "DATE"     '%s' "${BASH_REMATCH[1]}"
        printf -v "HOUR"     '%s' "${BASH_REMATCH[2]}"
        printf -v "FORECAST" '%s' "${BASH_REMATCH[3]}"
        return 0
    else
        return 1
    fi
}

calculate_hour_difference() {
    local hour1=$1
    local hour2=$2
    local diff=$((hour1 - hour2))
    
    # Handle negative differences and wrap around 24-hour clock
    if [[ $diff -lt 0 ]]; then
        diff=$((diff + 24))
    fi
    
    echo $diff
}

find_matching_pairs() {
    local current_date="$1"
    local current_hour="$2"
    local current_forecast="$3"
    local current_file="$4"
    
    # Look for files with the same date and forecast but different hours
    for file in ./merged_data/*_merged.grib2; do
        if [[ -f "$file" && "$file" != "$current_file" ]]; then
            filename=$(basename "$file")
            if extract_grib_parts "$filename"; then
                # Check if same date and forecast but different hour
                if [[ "$DATE" == "$current_date" && "$FORECAST" == "$current_forecast" && "$HOUR" != "$current_hour" ]]; then
                    # Calculate hour difference
                    hour_diff=$(calculate_hour_difference "$current_hour" "$HOUR")
                    
                    # Check if exactly 6 hours apart
                    if [[ $hour_diff -eq 6 ]]; then
                        # Create a unique pair key (always put earlier hour first)
                        local earlier_hour=$(( HOUR < current_hour ? HOUR : current_hour ))
                        local later_hour=$(( HOUR > current_hour ? HOUR : current_hour ))
                        local pair_key="${current_date}_${earlier_hour}_${later_hour}_f${current_forecast}"
                        
                        # Check if we've already processed this pair
                        if [[ -z "${processed_pairs[$pair_key]:-}" ]]; then
                            processed_pairs[$pair_key]=1
                            
                            local earlier_file="./merged_data/${current_date}_${earlier_hour}_f${current_forecast}_merged.grib2"
                            local later_file="./merged_data/${current_date}_${later_hour}_f${current_forecast}_merged.grib2"
                            
                            echo "Found matching pair: ${current_date}_${earlier_hour}_f${current_forecast} and ${current_date}_${later_hour}_f${current_forecast} (6 hours apart)"
                            
                            # Extract the .grib2 files (for now just copy them to timestamp_merged directory)
                            cp "$earlier_file" "./timestamp_merged/${current_date}_${earlier_hour}_f${current_forecast}_merged.grib2"
                            cp "$later_file" "./timestamp_merged/${current_date}_${later_hour}_f${current_forecast}_merged.grib2"
                            
                            echo "Extracted files: ${current_date}_${earlier_hour}_f${current_forecast}_merged.grib2 and ${current_date}_${later_hour}_f${current_forecast}_merged.grib2"
                        fi
                    fi
                fi
            fi
        fi
    done
}

process_existing_files() {
    echo "Processing existing files in ./merged_data..."
    for file in ./merged_data/*_merged.grib2; do
        if [[ -f "$file" ]]; then
            filename=$(basename "$file")
            if extract_grib_parts "$filename"; then
                find_matching_pairs "$DATE" "$HOUR" "$FORECAST" "$file"
            fi
        fi
    done
}

echo "Starting watcher for timestamp merging..."
echo "Monitoring ./merged_data for .grib2 files..."

# Process existing files first
process_existing_files

# Watch for new files
inotifywait -m -r -e close_write,moved_to --format '%w%f' ./merged_data \
| while read -r fullpath; do
    # Extract just the filename
    filename=$(basename "$fullpath")
    echo "New file detected: $filename"
    
    if extract_grib_parts "$filename"; then
        echo "Parsed: date=$DATE, hour=$HOUR, forecast=f$FORECAST"
        
        # Look for matching pairs
        find_matching_pairs "$DATE" "$HOUR" "$FORECAST" "$fullpath"
    else
        echo "File $filename does not match expected pattern - skipping"
    fi
done