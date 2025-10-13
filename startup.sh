#!/usr/bin/env bash
set -euo pipefail

echo "[startup] Cloning GitHub Repos..."
git clone https://github.com/Benedict-Hyland/graphcast.git /app/graphcast
git clone https://github.com/Benedict-Hyland/weather_modelling.git /app/weather_modelling

echo "[startup] Running python-prepare.sh..."
chmod +x /app/weather_modelling/python-prepare.sh
/app/weather_modelling/python-prepare.sh 2>&1 | tee -a /var/log/watcher.log
