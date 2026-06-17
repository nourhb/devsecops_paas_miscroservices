#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="${1:-}"

if [[ -z "${BUNDLE}" || ! -f "${BUNDLE}" ]]; then
  echo "ERROR: missing bundled stages file" >&2
  exit 1
fi
if ! grep -qF 'paas-deploy-stages-bundled-helpers+stages-20260617' "${BUNDLE}"; then
  echo "ERROR: bundled stages missing install marker" >&2
  exit 1
fi
if ! grep -qF 'def coerceHarborHostForCosign' "${BUNDLE}"; then
  echo "ERROR: bundled stages missing helper defs (coerceHarborHostForCosign)" >&2
  exit 1
fi
if grep -qE 'runPaasDeploy|def runPaasDeploy' "${BUNDLE}"; then
  echo "ERROR: bundled stages must not contain runPaasDeploy wrapper" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${BUNDLE}"; then
  echo "ERROR: bundled stages missing Step 12" >&2
  exit 1
fi
for fn in coerceHarborHostForCosign paasStepWarn harborForceNodePortPush writeNginxPaasDefaultConf; do
  if ! grep -qF "def ${fn}" "${BUNDLE}"; then
    echo "ERROR: bundled stages missing helper def ${fn}" >&2
    exit 1
  fi
done
echo "OK: bundled stages (helpers+Steps 1-12)"
