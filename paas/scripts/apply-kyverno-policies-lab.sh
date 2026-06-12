#!/usr/bin/env bash
# Wait for Kyverno webhooks, render cosign policy, apply cluster policies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${SCRIPT_DIR}/ensure-kyverno-lab.sh"
