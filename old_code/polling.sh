#!/usr/bin/env bash
# gfs-watch.sh — watch NOMADS for newest GFS run (0.25°) and notify via ntfy
# Requirements: bash, wget, awk, sed, coreutils, curl

###############################################################################
# Config — set these to your preference
###############################################################################
BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/"
STATE_FILE="latest_gfs.txt"

# ntfy topics (can be the same or different)
NTFY_NEW_RUN="https://ntfy.sh/gfs_fresh_arrival"        # when a newer run directory appears
NTFY_DATA_ARRIVED="https://ntfy.sh/gfs_arrived_topics"   # when f000 & f006 are 200

# Polling interval (seconds)
INTERVAL=120

###############################################################################
# Helpers (wget only; no curl except for ntfy)
###############################################################################
latest_gfs() {
  # Prints the latest run URL like:
  # https://.../gfs.YYYYMMDD/HH/
  local d h
  d=$(wget -qO- "$BASE" \
      | grep -Eo 'gfs\.[0-9]{8}/' \
      | sort \
      | tail -1) || return 1

  h=$(wget -qO- "${BASE}${d}" \
      | grep -Eo '([01][0-9]|2[0-3])/' \
      | tr -d '/' \
      | sort -n \
      | tail -1) || return 1

  printf "%s%s%02d/\n" "$BASE" "$d" "$h"
}

http_status() {
  # Prints HTTP status code for a URL
  local url="$1"
  wget --spider -S "$url" 2>&1 \
    | awk 'match($0,/^  HTTP\/[0-9.]+ ([0-9]{3})/,m){code=m[1]} END{print code?code:000}'
}

# Returns 0 if both f000 and f006 exist (HTTP 200), else 1.
test_runs() {
  local url="$1" hh atmos f000 f006 s1 s2
  [[ -z "$url" ]] && return 2

  # hh is the penultimate path segment
  hh=$(echo "$url" | awk -F'/' '{print $(NF-1)}')
  printf -v hh "%02d" "$hh"

  atmos="${url}atmos/"
  f000="${atmos}gfs.t${hh}z.pgrb2.0p25.f000"
  f006="${atmos}gfs.t${hh}z.pgrb2.0p25.f006"

  s1=$(http_status "$f000")
  s2=$(http_status "$f006")

  echo "Check: $f000 -> $s1"
  echo "Check: $f006 -> $s2"

  [[ "$s1" == "200" && "$s2" == "200" ]]
}

run_id_from_url() {
  # Converts run URL to run ID like YYYYMMDDHH
  # Example: .../gfs.20250819/06/  -> 2025081906
  local url="$1" ymd hh
  ymd=$(echo "$url" | sed -n 's#.*/gfs\.\([0-9]\{8\}\)/[0-9]\{2\}/$#\1#p')
  hh=$(echo "$url"  | awk -F'/' '{print $(NF-1)}')
  printf "%s%02d\n" "$ymd" "$hh"
}

notify_ntfy() {
  # $1: ntfy topic URL, $2: message (body)
  local topic="$1" msg="$2"
  curl -s -S -H "Title: GFS Watcher" -d "$msg" "$topic" >/dev/null || true
}

write_state() {
  # Overwrites STATE_FILE with details for the run
  # $1: run URL, $2: f000 URL, $3: f006 URL
  local url="$1" f000="$2" f006="$3" id
  id=$(run_id_from_url "$url")
  {
    echo "RUN_ID=${id}"
    echo "RUN_URL=${url}"
    echo "F000=${f000}"
    echo "F006=${f006}"
    echo "UPDATED_AT=$(date -Is)"
  } > "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

read_last_id() {
  # Echo last RUN_ID from STATE_FILE, or empty if none
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  sed -n 's/^RUN_ID=\(.*\)$/\1/p' "$STATE_FILE" | tail -1
}

###############################################################################
# Main loop
###############################################################################
echo "Starting GFS watcher. State file: $STATE_FILE"
echo "New-run ntfy:    $NTFY_NEW_RUN"
echo "Arrived ntfy:    $NTFY_DATA_ARRIVED"
echo "Interval:        ${INTERVAL}s"
echo

# Never exit on transient failures; just log and continue.
while true; do
  echo "---- $(date -Is) ----"
  # Discover latest run URL
  run_url=$(latest_gfs) || {
    echo "Failed to get latest run (network?)."
    sleep "$INTERVAL"; continue;
  }
  echo "Latest run URL: $run_url"

  # Compute IDs and expected files
  run_id=$(run_id_from_url "$run_url")
  hh=$(echo "$run_url" | awk -F'/' '{print $(NF-1)}')
  printf -v hh "%02d" "$hh"
  atmos="${run_url}atmos/"
  f000="${atmos}gfs.t${hh}z.pgrb2.0p25.f000"
  f006="${atmos}gfs.t${hh}z.pgrb2.0p25.f006"

  # Compare with state
  last_id=$(read_last_id)
  if [[ "$run_id" != "$last_id" && -n "$run_id" ]]; then
    echo "Newer run detected: $run_id (prev: ${last_id:-none})"
    notify_ntfy "$NTFY_NEW_RUN" "New GFS run detected: $run_id
$run_url"

    # Poll until both files are 200
    if test_runs "$run_url"; then
      echo "Both files present immediately."
    else
      echo "Waiting for files to arrive (polling every ${INTERVAL}s)…"
      # Keep polling the SAME run until both show up
      while true; do
        sleep "$INTERVAL"
        echo "Rechecking ${run_id}…"
        if test_runs "$run_url"; then
          echo "Files arrived for $run_id."
          break
        fi
      done
    fi

    # Write/overwrite state and notify arrival
    write_state "$run_url" "$f000" "$f006"
    notify_ntfy "$NTFY_DATA_ARRIVED" "GFS data arrived for $run_id
f000: $f000
f006: $f006"

  else
    echo "No newer run (current: ${run_id})."
    # Optional: also verify availability if you started mid-run
    # test_runs "$run_url" >/dev/null
    sleep "$INTERVAL"
  fi
done
