#!/usr/bin/env bash
# One-shot: install boot service + kubeconfig + start recover now.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "=============================================="
echo " lab-boot-fix — VM auto-start + recover now"
echo "=============================================="
echo "NOTE: use lab-boot-enable.sh directly if lab.sh boot-enable is missing"
echo ""

exec bash "${SCRIPT_DIR}/lab-boot-enable.sh"
