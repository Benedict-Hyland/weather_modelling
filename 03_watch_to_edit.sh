#!/usr/bin/env bash
set -euo pipefail

EXTRACT_DIR="./extraction_data"
OUTPUT_FILE="$EXTRACT_DIR/to_edit.txt"
FINISHED_FILE="$EXTRACT_DIR/finished_edits.txt"
PROCESS_SCRIPT="./04_zarr.py"

mkdir -p "$EXTRACT_DIR"
touch "$OUTPUT_FILE" "$FINISHED_FILE"

echo "[INFO] Watching $OUTPUT_FILE for new lines…"

# Function to safely remove a specific line from a file
remove_line_from_file() {
  local line="$1"
  local file="$2"
  tmpfile=$(mktemp)
  grep -Fxv -- "$line" "$file" > "$tmpfile" || true
  mv "$tmpfile" "$file"
}

# Process new lines in a controlled loop
tail -n0 -F "$OUTPUT_FILE" | while read -r line; do
  [[ -z "$line" ]] && continue

  echo "[INFO] Detected new line: $line"

  # Parse: e.g. "20250720_06_f004, 20250720_00_f004"
  previous_line=$(echo "$line" | cut -d',' -f1 | xargs)
  current_line=$(echo "$line" | cut -d',' -f2 | xargs)

  echo "[INFO] Running: $PROCESS_SCRIPT $current_line $previous_line"
  if uv run "$PROCESS_SCRIPT" "$current_line" "$previous_line"; then
      echo "[SUCCESS] Finished processing → $current_line"

      # Append to finished_edits.txt
      echo "$line" >> "$FINISHED_FILE"

      # Remove it from to_edit.txt so it won't re-run
      remove_line_from_file "$line" "$OUTPUT_FILE"
      echo "[INFO] Moved processed line to $FINISHED_FILE"
  else
      echo "[ERROR] Processing failed for: $line"
      echo "[WARN] Leaving it in $OUTPUT_FILE for retry"
  fi
done
