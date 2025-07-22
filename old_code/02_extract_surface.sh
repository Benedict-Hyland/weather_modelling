#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 2 ]; then
  echo "Usage: $0 <input.grib2> <output.grib2>"
  echo "Example: $0 gfs.t06z.sfluxgrbf000.grib2 surface_subset.grb2"
  exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"

# Final wgrib2 match regex
match_pattern=":(TMP:2 m above ground|UGRD:10 m above ground|VGRD:10 m above ground):"

echo "Extracting variables from $INPUT_FILE → $OUTPUT_FILE"
echo "Match pattern: $match_pattern"

# Extract those fields
wgrib2 "$INPUT_FILE" -match "$match_pattern" -grib "$OUTPUT_FILE"

echo "✅ Done! Extracted filtered fields → $OUTPUT_FILE"