#!/usr/bin/env bash
# Print PaaS project UUID by projectName (for trigger-paas-deploy-lab.py).
set -euo pipefail
NAME="${1:?usage: get-project-id-lab.sh <projectName>}"
PAAS_NS="${PAAS_NS:-paas}"
ID="$(kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT id FROM \"Project\" WHERE \"projectName\" = '${NAME}' AND \"deletedAt\" IS NULL LIMIT 1;" 2>/dev/null | tr -d ' \r\n')"
if [[ -z "${ID}" ]]; then
  echo "ERROR: no project named ${NAME}" >&2
  exit 1
fi
echo "${ID}"
