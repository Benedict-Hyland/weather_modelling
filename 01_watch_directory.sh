#!/usr/bin/env bash
set -euo pipefail

# Install with: sudo apt install inotify-tools
# Monitors “closed after write” or “moved into” under ./data recursively

inotifywait -m -r -e close_write,moved_to --format '%w%f' ./data \
| while read -r fullpath; do
    # strip off everything up to and including “data/”
    rel=${fullpath#*data/}
    echo "New file ready: data/$rel"
  done
