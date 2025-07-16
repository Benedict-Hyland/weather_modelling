#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 2 ]; then
  echo "Usage: $0 <input.grib2> <output.grib2>"
  exit 1
fi

INPUT_FILE="$1"
extract_parts $INPUT_FILE

OUTPUT_FILE="${DATE}_${HOUR}_${FORECAST}_${LEVEL}

# === CONFIGURATION ===
levels=(1000 975 950 925 900 850 800 750 700 650 600 \
        550 500 450 400 350 300 250 200 150 100 70 \
        50 30 20 10 7 5 3 2 1)

vars=("TMP" "UGRD" "VGRD" "HGT" "SPFH" "VVEL")

# Join into regex
level_regex=$(IFS=\|; echo "${levels[*]}")
vars_regex=$(IFS=\|; echo "${vars[*]}")

# Final match pattern
match_pattern=":(${vars_regex}):(${level_regex}) mb:"

echo "Extracting variables from $INPUT_FILE → $OUTPUT_FILE"
echo "Match pattern: $match_pattern"

# Run wgrib2
wgrib2 "$INPUT_FILE" -match "$match_pattern" -grib "$OUTPUT_FILE"

echo "Done! Extracted fields saved to $OUTPUT_FILE"
