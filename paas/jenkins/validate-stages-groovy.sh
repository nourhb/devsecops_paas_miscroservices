#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGES="${1:-${SCRIPT_DIR}/Jenkinsfile.paas-deploy-stages.groovy}"

if [[ ! -f "${STAGES}" ]]; then
  echo "ERROR: missing ${STAGES}" >&2
  exit 1
fi
if grep -qE 'runPaasDeploy|def runPaasDeploy' "${STAGES}"; then
  echo "ERROR: stages file must not contain runPaasDeploy wrapper" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${STAGES}"; then
  echo "ERROR: stages file missing Step 12" >&2
  exit 1
fi
open="$(grep -o '{' "${STAGES}" | wc -l | tr -d ' ')"
close="$(grep -o '}' "${STAGES}" | wc -l | tr -d ' ')"
if [[ "${open}" != "${close}" ]]; then
  echo "ERROR: brace mismatch in ${STAGES} ({=${open} }=${close})" >&2
  exit 1
fi
tail_line="$(tail -1 "${STAGES}")"
if [[ "${tail_line}" == "}" && "$(tail -2 "${STAGES}" | head -1)" == "}" ]]; then
  echo "ERROR: stages file ends with extra closing brace" >&2
  exit 1
fi
echo "OK: ${STAGES} ({=${open} }=${close})"
