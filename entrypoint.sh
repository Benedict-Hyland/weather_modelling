#!/usr/bin/env bash
set -euo pipefail


MODE="${STARTUP_MODE:-}"
if [[ -z "$MODE" && $# -gt 0 ]]; then
  MODE="$1"
  shift
fi

if [[ -z "$MODE" ]]; then
  MODE="forecast"
fi

case "$MODE" in
  forecast|model)
    ;;
  *)
    echo "[entrypoint] Unsupported mode '$MODE'. Expected 'forecast' or 'model'." >&2
    exit 1
    ;;

esac

SCRIPT="/app/startup_${MODE}.sh"
if [[ ! -x "$SCRIPT" ]]; then
  echo "[entrypoint] Startup script not found or not executable: $SCRIPT" >&2
  exit 1
fi

echo "[entrypoint] Selected mode '$MODE' -> $SCRIPT"
exec "$SCRIPT" "$@"
