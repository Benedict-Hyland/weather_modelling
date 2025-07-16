#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 1 ]; then
  echo "Usage: $0 <input.grib2>"
  echo "Example: $0 extracted_pressures.grib2"
  exit 1
fi

INPUT_FILE="$1"
BASE_FILE="${INPUT_FILE%.grib2}"
OUTPUT_FILE="${BASE_FILE}.nc"

echo "Converting ${INPUT_FILE} to ${OUTPUT_FILE}"
cdo -f nc copy $INPUT_FILE $OUTPUT_FILE