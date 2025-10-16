#/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="hiddenbenedict/blueoctopusforecasts:latest"
CONTAINER_NAME="modeller"
ENV_ROLE="model"
LOCAL_LOGS="/home/ec2-user/logs"
LOCAL_WEIGHTS="/home/ec2-user/data/weights"
CONTAINER_DIR="/root"
CONTAINER_WEIGHTS="/app/data/weights"

mkdir -p "$LOCAL_LOGS"
mkdir -p "$LOCAL_WEIGHTS"

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$LOCAL_LOGS":"$CONTAINER_DIR" \
  -v "$LOCAL_WEIGHTS":"$CONTAINER_WEIGHTS" \
  -e "STARTUP_MODE"="$ENV_ROLE" \
  "$IMAGE_NAME"
