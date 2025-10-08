# --- vars you edit ---
CONTAINER_NAME="modeller"
PROCESS_FILE="/var/log/modeller/process.log"
FINISH_KEYWORD="finished"
# ----------------------

# (A) Script that starts an existing container and watches for completion
sudo tee /usr/local/bin/start-and-watch.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-modeller}"
PROCESS_FILE="${PROCESS_FILE:-/var/log/modeller/process.log}"
FINISH_KEYWORD="${FINISH_KEYWORD:-finished}"

# Make sure the log file exists (and its sdirectory)
mkdir -p "$(dirname "$PROCESS_FILE")"
touch "$PROCESS_FILE"

# If container exists, just start it; else, fail noisily (no pulling).
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  # If it’s already running, great; otherwise start it.
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[boot] Starting existing container $CONTAINER_NAME"
    docker start "$CONTAINER_NAME" >/dev/null
  else
    echo "[boot] Container $CONTAINER_NAME is already running"
  fi
else
  echo "[boot] ERROR: Container $CONTAINER_NAME does not exist on disk." >&2
  exit 1
fi

# Wait until the keyword appears in the process file, then stop container and power off
echo "[boot] Watching $PROCESS_FILE for '$FINISH_KEYWORD'..."
while true; do
  if grep -qi -- "$FINISH_KEYWORD" "$PROCESS_FILE"; then
    echo "[boot] Detected '$FINISH_KEYWORD'; stopping container and powering off."
    docker stop "$CONTAINER_NAME" || true
    docker rm   "$CONTAINER_NAME" || true
    /sbin/shutdown -h now
    exit 0
  fi
  sleep 15
done
BASH
sudo chmod +x /usr/local/bin/start-and-watch.sh

# (B) systemd unit that runs the script at boot
sudo tee /etc/systemd/system/modeller-onboot.service >/dev/null <<'UNIT'
[Unit]
Description=Start modeller container at boot and shutdown when finished
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=CONTAINER_NAME=modeller
Environment=PROCESS_FILE=/var/log/modeller/process.log
Environment=FINISH_KEYWORD=finished
ExecStart=/usr/local/bin/start-and-watch.sh
Restart=no

[Install]
WantedBy=multi-user.target
UNIT

# Enable and test
sudo systemctl daemon-reload
sudo systemctl enable modeller-onboot.service
# Optional: test now (it will shut the machine down when finished)
# sudo systemctl start modeller-onboot.service
