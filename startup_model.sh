#!/usr/bin/env bash
set -euo pipefail

echo "[startup] Cloning GitHub Repos..."
git clone https://github.com/Benedict-Hyland/graphcast.git /app/graphcast
git --no-pager --git-dir=/app/graphcast/.git log -n 1
git clone https://github.com/Benedict-Hyland/weather_modelling.git /app/weather_modelling
git --no-pager --git-dir=/app/weather_modelling/.git log -n 1

echo "[startup] Running run_model.sh..."
chmod +x /app/weather_modelling/run_model.sh
/app/weather_modelling/run_model.sh 2>&1 | tee -a /var/log/model_watcher.log
