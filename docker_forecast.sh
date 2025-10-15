#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/blueoctopus:v1.1.1"
CONTAINER_NAME="forecaster"
ENV_ROLE="forecast"
LOCAL_DIR="/home/ec2-user/logs"
CONTAINER_DIR="/root"

mkdir -p "$LOCAL_DIR"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_DIR":"$CONTAINER_DIR" \
  -e "STARTUP_MODE"="$ENV_ROLE" \
  "$IMAGE_NAME"
