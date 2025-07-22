#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 2 ]; then
  echo "Usage: $0 <input.grib2> <output.grib2>"
  exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"

# === CONFIGURATION ===
levels=(875 825 775 225 175 125)

vars=("TMP" "UGRD" "VGRD" "HGT" "VVEL")

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
