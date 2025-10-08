#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/forecaster:v1.0.1a"
CONTAINER_NAME="forecaster"
LOCAL_DIR="/home/ec2-user/logs"
CONTAINER_DIR="/root"

mkdir -p "$LOCAL_DIR"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_DIR":"$CONTAINER_DIR" \
  "$IMAGE_NAME"
