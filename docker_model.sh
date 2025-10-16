#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/blueoctopusforecasts:latest"
CONTAINER_NAME="modeller"
ENV_ROLE="model"
LOCAL_LOGS="/home/ec2-user/logs"
LOCAL_STATS="/home/ec2-user/data/stats"
CONTAINER_DIR="/root"
CONTAINER_STATS="/app/data/stats"

mkdir -p "$LOCAL_LOGS"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_LOGS":"$CONTAINER_DIR" \
  -v "$LOCAL_STATS":"$CONTAINER_STATS" \
  -e "STARTUP_MODE"="$ENV_ROLE" \
  "$IMAGE_NAME"
