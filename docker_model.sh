#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/blueoctopus:v1.1.1"
CONTAINER_NAME="modeller"
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
