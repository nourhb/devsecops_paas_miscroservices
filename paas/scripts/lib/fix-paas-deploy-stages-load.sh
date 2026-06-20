#!/usr/bin/env bash
# One-shot: CPS-split bundle + Jenkins job wrapper (fixes MethodTooLarge on load).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${SCRIPT_DIR}/break-paas-deploy-loop.sh"
