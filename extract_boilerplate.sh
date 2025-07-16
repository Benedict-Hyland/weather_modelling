#!/usr/bin/env bash

# Shared boilerplate for extraction scripts

parse_args() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 <input_file>"
        exit 1
    fi
    input_file="$1"
}

extract_timestep() {
    if [[ "$input_file" =~ (f[0-9]{3}) ]]; then
        timestep="${BASH_REMATCH[1]}"
    else
        echo "Could not extract timestep (f###) from filename: $input_file"
        exit 2
    fi
}

extract_tstr() {
    if [[ "$input_file" =~ (t[0-9]{2}) ]]; then
        tstr="${BASH_REMATCH[1]}"
    else
        echo "Could not extract t## from filename: $input_file"
        exit 3
    fi
}

setup_log_and_outdir() {
    current_date=$(date +"%d_%m_%Y")
    log_file="${current_date}-${tstr}.log"
    outdir="./processed_data/$current_date/$timestep"
    mkdir -p "$outdir"
}

log_msg() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
} 