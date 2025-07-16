#!/usr/bin/env bash

# === ARGUMENTS ===
if [ $# -ne 1 ]; then
  echo "Usage: $0 <input.grib2>"
  exit 1
fi

extract_parts() {
  local __path=$1

  # regex breakdown:
  #  ^data/([0-9]{8})_([0-9]{2})/        → capture YYYYMMDD and HH
  #  gfs\.t[0-9]{2}z\.                  → literal "gfs.tHHz."
  #  (pgrb2b|pgrb2|sfluxgrb)             → capture one of the three types
  #  [^/]*                               → any extra (e.g. ".0p25")
  #  \.f([0-9]{3})                       → capture the 3‑digit period
  #  (?:\.grib2)?$                       → optional ".grib2" at end
  if [[ $__path =~ ^data/([0-9]{8})_([0-9]{2})/gfs\.t[0-9]{2}z\.((pgrb2b|pgrb2|sfluxgrb))[^/]*\.f([0-9]{3})(?:\.grib2)?$ ]]; then
    # assign by name
    printf -v "DATE"   '%s' "${BASH_REMATCH[1]}"
    printf -v "HOUR"   '%s' "${BASH_REMATCH[2]}"
    printf -v "LEVEL"   '%s' "${BASH_REMATCH[3]}"
    printf -v "FORECAST" 'f%s' "${BASH_REMATCH[4]}"
    return 0
  else
    return 1
  fi
}


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
