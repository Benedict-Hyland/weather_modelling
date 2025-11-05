#!/usr/bin/env bash
set -euo pipefail

echo "[startup] Cloning GitHub Repos..."
git clone https://github.com/Benedict-Hyland/graphcast.git /app/graphcast
git --no-pager --git-dir=/app/graphcast/.git log -n 1
git clone https://github.com/Benedict-Hyland/weather_modelling.git /app/weather_modelling
git --no-pager --git-dir=/app/weather_modelling/.git log -n 1

echo "[startup] Running python-prepare.sh..."
chmod +x /app/weather_modelling/python-prepare.sh
# Ensure CWD so ../graphcast resolves to /app/graphcast, not /graphcast
cd /app/weather_modelling
# Force the Python watcher to use the freshly cloned graphcast copy
export PYTHON_SCRIPT_PATH="/app/graphcast/NCEP/gdas_utility.py"
./python-prepare.sh 2>&1 | tee -a /var/log/forecast_watcher.log
