#!/usr/bin/env bash
# gfs-watch.sh — watch NOMADS for newest eligible GFS run (0.25°), notify via ntfy,
# upload subselected GRIBs to S3, then merge defined pairs into NetCDF and upload them too.
# Requirements: bash, wget, curl, coreutils, AWS CLI (v2+), wgrib2
# nohup ./gfs-watch.sh > ./watchers.log 2>&1 &

###############################################################################
# Config — edit these
###############################################################################
# Filtered GRIBs to fetch/upload (unchanged)
FORECASTS=(f000 f001 f002 f003 f004 f005 f006 f007 f008 f009 f010 f011)

# Pairs to merge -> NetCDF outputs forecast_1..forecast_6
# Index order maps to N in forecast_{N}.nc
MERGE_SETS=(
  "f000 f006"  # forecast_1
  "f001 f007"  # forecast_2
  "f002 f008"  # forecast_3
  "f003 f009"  # forecast_4
  "f004 f010"  # forecast_5
  "f005 f011"  # forecast_6
)

BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/"
STATE_FILE="${HOME}/latest_gfs.txt"

# ntfy topics
NTFY_NEW_RUN="https://ntfy.sh/gfs_latest_file"
NTFY_DATA_ARRIVED="https://ntfy.sh/gfs_latest_data"
NTFY_S3_DOWNLOADED="https://ntfy.sh/gfs_downloaded_s3" # will also be used for NetCDF notice

# S3 destinations
S3_BUCKET="graphcast-gfs-forecasts"
S3_PREFIX="gfs-raw-test"        # for filtered GRIBs
S3_NC_PREFIX="nc-to-model" # for merged NetCDFs

# Upload settings
S3_MAX_RETRIES=5
S3_EXTRA_ARGS=(--no-progress)

# Polling interval (seconds)
INTERVAL=60

# NetCDF Version
NETCDF_OUT="nc3"

###############################################################################
# Helpers
###############################################################################
# Only consider hours 00, 06, 12, 18
latest_gfs() {
  local dates d hours h
  dates=$(wget -qO- "$BASE" | grep -Eo 'gfs\.[0-9]{8}/' | sort -r) || return 1
  for d in $dates; do
    hours=$(wget -qO- "${BASE}${d}" | grep -Eo '(00|06|12|18)/' | tr -d '/' | sort -n)
    h=$(echo "$hours" | tail -1)
    if [[ -n "$h" ]]; then
      printf "%s%s%02d/\n" "$BASE" "$d" "$h"
      return 0
    fi
  done
  return 1
}

http_status() {
  local url="$1"
  wget --spider -S "$url" 2>&1 \
    | awk 'match($0,/^  HTTP\/[0-9.]+ ([0-9]{3})/,m){code=m[1]} END{print code?code:000}'
}

# Check ALL requested forecast files exist (HTTP 200) under raw atmos/ paths
test_all_forecasts() {
  local run_url="$1" hh atmos f raw raw_status ok=1
  [[ -z "$run_url" ]] && return 2
  hh=$(echo "$run_url" | awk -F'/' '{print $(NF-1)}'); printf -v hh "%02d" "$hh"
  atmos="${run_url}atmos/"
  for f in "${FORECASTS[@]}"; do
    raw="${atmos}gfs.t${hh}z.pgrb2.0p25.${f}"
    raw_status=$(http_status "$raw")
    echo "Check: $raw -> $raw_status"
    if [[ "$raw_status" != "200" ]]; then ok=0; fi
  done
  [[ $ok -eq 1 ]]
}

run_id_from_url() {
  local url="$1" ymd hh
  ymd=$(echo "$url" | sed -n 's#.*/gfs\.\([0-9]\{8\}\)/[0-9]\{2\}/$#\1#p')
  hh=$(echo "$url"  | awk -F'/' '{print $(NF-1)}')
  printf "%s%02d\n" "$ymd" "$hh"
}

notify_ntfy() {
  local topic="$1" msg="$2"
  curl -s -S -o /dev/null -w "%{http_code}" -H "Title: GFS Watcher" -d "$(date) $msg" "$topic" || echo 000
}

read_last_id() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  sed -n 's/^RUN_ID=\(.*\)$/\1/p' "$STATE_FILE" | tail -1
}

yyyy_mm_dd_from_runid() {
  local rid="$1"; printf "%s-%s-%s\n" "${rid:0:4}" "${rid:4:2}" "${rid:6:2}"
}
hour_from_runid() {
  local rid="$1"; printf "%s\n" "${rid:8:2}"
}

# Build NOMADS filter URL for a given run + forecast code (f000, f006, …)
build_filter_url() {
  local rid="$1" fcode="$2"
  local y="${rid:0:4}" m="${rid:4:2}" d="${rid:6:2}" h="${rid:8:2}"
  local file="gfs.t${h}z.pgrb2.0p25.${fcode}"
  local dir_enc="%2Fgfs.${y}${m}${d}%2F${h}%2Fatmos"
  local params
  params=$(
    cat <<'EOF' | tr -d '\n'
&lev_1000_mb=on&lev_100_mb=on&lev_10_m_above_ground=on&lev_150_mb=on
&lev_200_mb=on&lev_250_mb=on&lev_2_m_above_ground=on&lev_300_mb=on
&lev_400_mb=on&lev_500_mb=on&lev_50_mb=on&lev_600_mb=on&lev_700_mb=on
&lev_850_mb=on&lev_925_mb=on&lev_surface=on
&var_HGT=on&var_LAND=on&var_PRMSL=on&var_SPFH=on&var_TMP=on&var_UGRD=on&var_VGRD=on&var_VVEL=on
EOF
  )
  echo "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl?file=${file}${params}&dir=${dir_enc}"
}

# Stream URL -> S3 with retries (no local temp files)
_stream_to_s3() {
  local src_url="$1" dst_uri="$2" attempt=1
  while (( attempt <= S3_MAX_RETRIES )); do
    echo "Uploading (attempt ${attempt}/${S3_MAX_RETRIES}): $src_url -> $dst_uri"
    if curl -fSL "$src_url" | aws s3 cp - "$dst_uri" "${S3_EXTRA_ARGS[@]}"; then
      echo "Upload OK: $dst_uri"
      return 0
    fi
    echo "Upload failed (attempt $attempt). Retrying in 10s…"
    sleep 10
    ((attempt++))
  done
  echo "ERROR: Upload failed after ${S3_MAX_RETRIES} attempts: $dst_uri"
  return 1
}

# Upload ALL requested forecasts; returns 0 only if ALL succeed.
# Echos a newline-separated list of "f### s3://bucket/key" on success (for state file).
download_all_to_s3() {
  local rid="$1"   # YYYYMMDDHH
  local dstr h base_prefix f filter_url dst_uri
  dstr=$(yyyy_mm_dd_from_runid "$rid")
  h=$(hour_from_runid "$rid")
  if [[ -n "$S3_PREFIX" ]]; then
    base_prefix="${S3_PREFIX}/${dstr}/${h}"
  else
    base_prefix="${dstr}/${h}"
  fi

  local uploaded=()
  for f in "${FORECASTS[@]}"; do
    filter_url=$(build_filter_url "$rid" "$f")
    dst_uri="s3://${S3_BUCKET}/${base_prefix}/gfs.t${h}z.pgrb2.0p25.${f}"
    echo "Filter URL ${f}: $filter_url"
    if _stream_to_s3 "$filter_url" "$dst_uri"; then
      uploaded+=("${f} ${dst_uri}")
    else
      echo "ERROR: Upload failed for ${f} -> ${dst_uri}"
      return 1
    fi
  done

  printf "%s\n" "${uploaded[@]}"
  return 0
}

# Write/overwrite state AFTER all uploads succeed
write_state_after_uploads() {
  local run_url="$1" rid="$2" s3_lines="$3"
  {
    echo "RUN_ID=${rid}"
    echo "RUN_URL=${run_url}"
    echo "FORECASTS=$(IFS=,; echo "${FORECASTS[*]}")"
    echo "S3_COUNT=$(printf "%s\n" "$s3_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local f uri
      f=$(echo "$line" | awk '{print $1}')
      uri=$(echo "$line" | awk '{print $2}')
      echo "S3_${f}=${uri}"
    done <<< "$s3_lines"
    echo "UPDATED_AT=$(date -Is)"
  } > "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

###############################################################################
# New: Merge filtered pairs -> NetCDF and upload to S3
###############################################################################
_download_with_retries() {
  local url="$1" out="$2" attempt=1
  while (( attempt <= S3_MAX_RETRIES )); do
    echo "Downloading (attempt ${attempt}/${S3_MAX_RETRIES}): $url -> $out"
    if curl -fSL "$url" -o "$out"; then
      return 0
    fi
    echo "Download failed (attempt $attempt). Retrying in 10s…"
    sleep 10
    ((attempt++))
  done
  return 1
}

_upload_file_to_s3() {
  local path="$1" dst_uri="$2" attempt=1
  while (( attempt <= S3_MAX_RETRIES )); do
    echo "S3 upload (attempt ${attempt}/${S3_MAX_RETRIES}): $path -> $dst_uri"
    if aws s3 cp "$path" "$dst_uri" "${S3_EXTRA_ARGS[@]}"; then
      echo "Upload OK: $dst_uri"
      return 0
    fi
    echo "Upload failed (attempt $attempt). Retrying in 10s…"
    sleep 10
    ((attempt++))
  done
  echo "ERROR: Upload failed after ${S3_MAX_RETRIES} attempts: $dst_uri"
  return 1
}

merge_and_upload_netcdf() {
  local rid="$1"  # YYYYMMDDHH
  local tmpdir
  tmpdir=$(mktemp -d) || { echo "ERROR: mktemp failed"; return 1; }
  echo "Working in temp dir: $tmpdir"

  local h dstr nc_s3_prefix ncflag
  dstr=$(yyyy_mm_dd_from_runid "$rid")
  h=$(hour_from_runid "$rid")
  nc_s3_prefix="s3://${S3_BUCKET}/${S3_NC_PREFIX}"
  # choose wgrib2 flag for netcdf flavor
  if [[ "$NETCDF_OUT" == "nc4" ]]; then ncflag="-nc4"; else ncflag="-nc3"; fi

  local i=1
  for pair in "${MERGE_SETS[@]}"; do
    local fA fB
    read -r fA fB <<< "$pair"

    local urlA urlB fileA fileB merged_grb merged_scaled out_nc
    urlA=$(build_filter_url "$rid" "$fA")
    urlB=$(build_filter_url "$rid" "$fB")
    fileA="${tmpdir}/${fA}.grb2"
    fileB="${tmpdir}/${fB}.grb2"
    merged_grb="${tmpdir}/merged_${i}.grb2"
    merged_scaled="${tmpdir}/merged_${i}_scaled.grb2"
    out_nc="${tmpdir}/forecast_${i}.nc"

    echo "Preparing forecast_${i}: ${fA} + ${fB}"
    if ! _download_with_retries "$urlA" "$fileA"; then
      echo "ERROR: Failed to download $fA"; rm -rf "$tmpdir"; return 1
    fi
    if ! _download_with_retries "$urlB" "$fileB"; then
      echo "ERROR: Failed to download $fB"; rm -rf "$tmpdir"; return 1
    fi

    # Merge the two GRIBs (append messages)
    if ! wgrib2 "$fileA" -grib_out "$merged_grb" >/dev/null 2>&1; then
      echo "ERROR: wgrib2 failed writing initial GRIB for $fA"; rm -rf "$tmpdir"; return 1
    fi
    if ! wgrib2 "$fileB" -append -grib_out "$merged_grb" >/dev/null 2>&1; then
      echo "ERROR: wgrib2 failed appending GRIB for $fB"; rm -rf "$tmpdir"; return 1
    fi

    # --- HGT unit transform (multiply by 9.80665) ---
    # We write *all* messages: first write HGT (scaled), then append the non-HGT.
    # This uses Version 1 IF blocks (-if/-not_if with -grib_out/-append).
    if ! wgrib2 "$merged_grb" \
      -if ":HGT:" -rpn "const,9.80665,*" -grib_out "$merged_scaled" \
      -not_if ":HGT:" -append -grib_out "$merged_scaled" >/dev/null 2>&1; then
      echo "WARNING: HGT scaling skipped for forecast_${i} (no HGT or transform failed)"
      cp "$merged_grb" "$merged_scaled"
    fi

    # Convert to requested NetCDF flavor (stores valid times on the time axis)
    if ! wgrib2 "$merged_scaled" $ncflag -netcdf "$out_nc" >/dev/null 2>&1; then
      echo "ERROR: wgrib2 -netcdf failed for forecast_${i}"; rm -rf "$tmpdir"; return 1
    fi

    # Upload to S3 as nc_to_model/forecast_{i}.nc (intentionally fixed name)
    local dst="${nc_s3_prefix}/forecast_${i}.nc"
    if ! _upload_file_to_s3 "$out_nc" "$dst"; then
      echo "ERROR: Failed to upload $out_nc to $dst"; rm -rf "$tmpdir"; return 1
    fi
    echo "Uploaded: ${dst}"
    ((i++))
  done

  rm -rf "$tmpdir"
  return 0
}

###############################################################################
# Main loop
###############################################################################
echo "Starting GFS watcher. State: $STATE_FILE"
echo "Eligible hours: 00, 06, 12, 18"
echo "Forecasts: ${FORECASTS[*]}"
echo "S3 bucket (GRIB):  s3://${S3_BUCKET}/${S3_PREFIX}"
echo "S3 bucket (NetCDF): s3://${S3_BUCKET}/${S3_NC_PREFIX}"
echo "Interval:   ${INTERVAL}s"
echo

while true; do
  run_url=$(latest_gfs) || { echo "Failed to get latest eligible run."; sleep "$INTERVAL"; continue; }

  rid=$(run_id_from_url "$run_url")
  last_id=$(read_last_id)

  if [[ "$rid" != "$last_id" && -n "$rid" ]]; then
    echo "Newer eligible run detected: $rid (prev: ${last_id:-none})"

    notify_ntfy "$NTFY_NEW_RUN" "New GFS run (eligible hour): $rid
$run_url" >/dev/null 2>&1 || true

    if test_all_forecasts "$run_url"; then
      echo "All requested files are present."
    else
      echo "Waiting for ALL requested files to arrive (poll ${INTERVAL}s)…"
      while true; do
        sleep "$INTERVAL"
        echo "Rechecking ${rid}…"
        if test_all_forecasts "$run_url"; then
          echo "All requested files arrived for $rid."
          break
        fi
      done
    fi

    notify_ntfy "$NTFY_DATA_ARRIVED" "GFS data available for $rid
Run: $run_url
Forecasts: ${FORECASTS[*]}" >/dev/null 2>&1 || true

    if [[ -z "$S3_BUCKET" ]]; then
      echo "WARNING: S3_BUCKET is unset; skipping uploads and state update."
    else
      # 1) Upload filtered GRIBs to S3 (raw)
      s3_map=$(download_all_to_s3 "$rid")  # echoes lines "f### s3://..."
      if [[ $? -eq 0 ]]; then
        echo "All GRIB uploads succeeded. Updating state file…"
        write_state_after_uploads "$run_url" "$rid" "$s3_map"
        echo "State updated: $STATE_FILE"
        notify_ntfy "$NTFY_S3_DOWNLOADED" "All Data Downloaded To S3 For $rid" >/dev/null 2>&1 || true
      else
        echo "ERROR: One or more GRIB uploads failed. State NOT updated."
        notify_ntfy "$NTFY_S3_DOWNLOADED" "S3 Download Failed! $rid Failed to Upload" >/dev/null 2>&1 || true
        # still attempt NetCDF? Safer to skip if raw failed
        continue
      fi

      # 2) Build & upload merged NetCDFs (forecast_1..forecast_6)
      echo "Merging forecast pairs into NetCDF and uploading…"
      if merge_and_upload_netcdf "$rid"; then
        echo "All NetCDF merges & uploads completed."
        notify_ntfy "$NTFY_S3_DOWNLOADED" "NetCDF Merged files uploaded!" >/dev/null 2>&1 || true
      else
        echo "ERROR: NetCDF merge/upload failed for $rid."
        notify_ntfy "$NTFY_S3_DOWNLOADED" "NetCDF merge/upload FAILED for $rid" >/dev/null 2>&1 || true
      fi
    fi

  else
    sleep "$INTERVAL"
  fi
done
