#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
DATA_DIR="./data"

# Required files for each cycle
REQUIRED_FILES=(
    "gfs.t%Zz.pgrb2.0p25.f000"   "gfs.t%Zz.pgrb2b.0p25.f000"
    "gfs.t%Zz.pgrb2.0p25.f001"   "gfs.t%Zz.pgrb2b.0p25.f001"
    "gfs.t%Zz.pgrb2.0p25.f002"   "gfs.t%Zz.pgrb2b.0p25.f002"
    "gfs.t%Zz.pgrb2.0p25.f003"   "gfs.t%Zz.pgrb2b.0p25.f003"
    "gfs.t%Zz.pgrb2.0p25.f004"   "gfs.t%Zz.pgrb2b.0p25.f004"
    "gfs.t%Zz.pgrb2.0p25.f005"   "gfs.t%Zz.pgrb2b.0p25.f005"
    "gfs.t%Zz.pgrb2.0p25.f006"   "gfs.t%Zz.pgrb2b.0p25.f006"
)

mkdir -p "$DATA_DIR"

# --- Function: Find latest cycle date (YYYYMMDD) ---
latest_cycle_date() {
  curl --http1.1 -sL -A "Mozilla/5.0" "$BASE_URL/" \
    | grep -oE 'gfs\.[0-9]{8}/' \
    | sed 's#/##; s/gfs\.//' \
    | sort -u | tail -n 1
}

# --- Function: Find latest subcycle (00,06,12,18) for a given date ---
latest_subcycle() {
  local date=$1
  curl --http1.1 -sL -A "Mozilla/5.0" "$BASE_URL/gfs.${date}/" \
    | grep -oE '[0-9]{2}/' | tr -d '/' \
    | sort -u | tail -n 1
}

# --- Function: Check if a given file is already on disk ---
already_downloaded() {
  local date=$1 hour=$2 filename=$3
  [[ -f "$DATA_DIR/${date}_${hour}/$filename" ]]
}

# --- Function: Download a given cycle (YYYYMMDD + HH) ---
download_cycle() {
  local DATE=$1 HOUR=$2
  local CYCLE_URL="$BASE_URL/gfs.${DATE}/${HOUR}/atmos/"

  echo "🔎 Checking cycle ${DATE}_${HOUR}"
  local html_listing
  html_listing=$(curl --http1.1 -sL -A "Mozilla/5.0" "$CYCLE_URL" | tr -d '\r')

  # extract only the filenames
  local file_list
  file_list=$(printf '%s\n' "$html_listing" \
    | grep -oE 'gfs\.t[0-9]{2}z\.[^"]+' \
    | sort -u)

  local ALL_PRESENT=true
  for tmpl in "${REQUIRED_FILES[@]}"; do
    local filename=${tmpl//%Z/$HOUR}
    if echo "$file_list" | grep -Fx "$filename"; then
      continue
    else
      echo "  ❌ Missing on server: $filename"
      ALL_PRESENT=false
    fi
  done

  if ! $ALL_PRESENT; then
    echo "⏳ Server not ready for ${DATE}_${HOUR}, skipping."
    return
  fi

  echo "✅ Server has all files for ${DATE}_${HOUR}, downloading…"
  local TARGET_DIR="$DATA_DIR/${DATE}_${HOUR}"
  mkdir -p "$TARGET_DIR"

  for tmpl in "${REQUIRED_FILES[@]}"; do
    local filename=${tmpl//%Z/$HOUR}
    if already_downloaded "$DATE" "$HOUR" "$filename"; then
      echo "  ↳ Skipping (already have): $filename"
    else
      echo "  ↳ Downloading: $filename"
      wget -nc -q -P "$TARGET_DIR" "$CYCLE_URL$filename"
    fi
  done

  echo "✅ Done cycle ${DATE}_${HOUR}"
}

# --- MAIN ---
CYCLE_DATE=$(latest_cycle_date)
CYCLE_HOUR=$(latest_subcycle "$CYCLE_DATE")
LATEST="${CYCLE_DATE}${CYCLE_HOUR}"

echo "🌐 Latest cycle: $LATEST"

# I changed this as going forwards I want to download the latest data
# And then predict models on that, giving me 6-12 hours to create models
# Rather than predicting the next 6 hours
# This will be running off the same data but I am further ahead
# Therefore, I will be able to create more models
# After the first 6 hour block, the models will be aligned
# I will just need to use the last predicitons to show the current ones
# It was easier to change 6, 12 hours to 0, 6 hours than update code
# prev‑0h and prev‑6h
PREV1=$(date -u -d "${LATEST:0:8} ${LATEST:8:2} -0 hours" +%Y%m%d%H)
PREV2=$(date -u -d "${LATEST:0:8} ${LATEST:8:2} -6 hours" +%Y%m%d%H)

PREV1_DATE=${PREV1:0:8}; PREV1_HOUR=${PREV1:8:2}
PREV2_DATE=${PREV2:0:8}; PREV2_HOUR=${PREV2:8:2}

echo "📅 Prev cycles: ${PREV1_DATE}_${PREV1_HOUR}, ${PREV2_DATE}_${PREV2_HOUR}"
download_cycle "$PREV1_DATE" "$PREV1_HOUR"
download_cycle "$PREV2_DATE" "$PREV2_HOUR"

echo "✅ All done."
