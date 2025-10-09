#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/forecaster:v1.0.1a"
CONTAINER_NAME="forecaster"
LOCAL_DIR="/home/ec2-user/logs"
LOCAL_STATS="/home/ec2-user/data/stats"
CONTAINER_DIR="/root"
CONTAINER_STATS="/app/data/stats"

mkdir -p "$LOCAL_DIR"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_DIR":"$CONTAINER_DIR" \
  -v "$LOCAL_STATS":"$CONTAINER_STATS" \
  "$IMAGE_NAME"
