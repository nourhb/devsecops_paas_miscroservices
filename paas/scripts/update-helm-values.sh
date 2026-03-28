#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="$1"
BUILD_NUMBER="$2"
VALUES_FILE="helm-charts/paas-app/values.yaml"

sed -i "s/tag:.*/tag: \"${BUILD_NUMBER}\"/" "$VALUES_FILE"
echo "Updated ${VALUES_FILE} for ${PROJECT_NAME}:${BUILD_NUMBER}"
