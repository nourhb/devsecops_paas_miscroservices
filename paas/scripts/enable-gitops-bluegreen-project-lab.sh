#!/usr/bin/env bash
# Add deploymentStrategy: BlueGreen to one project's GitOps values.yaml
set -euo pipefail

PROJECT="${1:?usage: enable-gitops-bluegreen-project-lab.sh <projectName> [activeSlot]}"
ACTIVE="${2:-blue}"
GITOPS="${GITOPS:-${HOME}/gitops}"
VALUES="${GITOPS}/apps/${PROJECT}/values.yaml"

[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

python3 - "${VALUES}" "${ACTIVE}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.stderr.write("pip3 install pyyaml\n")
    raise
path, active = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
doc["deploymentStrategy"] = "BlueGreen"
doc["activeSlot"] = active if active in ("blue", "green") else "blue"
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK: {path} deploymentStrategy=BlueGreen activeSlot={doc['activeSlot']}")
PY

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${SCRIPT_DIR}/push-gitops-lab.sh" "chore(${PROJECT}): enable blue-green deployment"
