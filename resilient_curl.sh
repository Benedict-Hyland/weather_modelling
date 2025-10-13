#!/usr/bin/env bash
# Resilient downloader: resumes partial downloads until complete.

# Accept arguments
URL="$1"
OUT="$2"

# Validate arguments
if [ -z "$URL" ] || [ -z "$OUT" ]; then
  echo "Usage: $0 <URL> <OUTPUT_FILE>"
  exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUT")"

while true; do
  echo "Starting (or resuming) download of $URL..."
  
  curl -fSL --retry 9999 --retry-delay 10 --retry-all-errors \
       --continue-at - \
       --speed-limit 200 --speed-time 30 \
       --connect-timeout 15 \
       -o "$OUT" "$URL"
  
  # If curl exits with 0, download finished cleanly
  if [ $? -eq 0 ]; then
    echo "✅ Download completed successfully: $OUT"
    break
  else
    echo "⚠️  Download interrupted, retrying in 15 seconds..."
    sleep 15
  fi
done
