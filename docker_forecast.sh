#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/blueoctopusforecasts:latest"
CONTAINER_NAME="forecaster"
ENV_ROLE="forecast"
LOCAL_LOGS="/home/ec2-user/logs"
CONTAINER_DIR="/root"

mkdir -p "$LOCAL_LOGS"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_LOGS":"$CONTAINER_DIR" \
  -e "STARTUP_MODE"="$ENV_ROLE" \
  "$IMAGE_NAME"
