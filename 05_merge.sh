#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 3 ]; then
  echo "Usage: $0 <input_1.grib2> <input_2.grib2> <input_3.grib2>"
  echo "Example: $0 extracted_pressures.grib2 extracted_pressures_2.grib2 extracted_surface.grib2"
  exit 1
fi


