#!/usr/bin/env bash
# Fix gunicorn 19.x + Python 3.12 crash on existing crane images (no Jenkins rebuild required).
patch_python_deploy_lab() {
  local ns="$1"
  local port="${2:-8000}"
  [[ -n "${ns}" ]] || return 1

  python3 - "${ns}" "${port}" <<'PY'
import json, subprocess, sys

ns, port = sys.argv[1:3]
start = (
    "pip install -q --root-user-action=ignore 'gunicorn>=22' 'flask>=2' 2>/dev/null || true; "
    "cd /app && exec python3 -m gunicorn -b 0.0.0.0:" + port + " main:app"
)
out = subprocess.check_output(["kubectl", "get", "deploy", "-n", ns, "-o", "json"], text=True)
data = json.loads(out)
for dep in data.get("items", []):
    name = dep.get("metadata", {}).get("name", "")
    if name.endswith("-blue") or name.endswith("-green"):
        continue
    containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or []
    if not containers:
        continue
    containers[0]["command"] = ["/bin/sh", "-c"]
    containers[0]["args"] = [start]
    patch = json.dumps({"spec": dep["spec"]})
    subprocess.run(
        ["kubectl", "patch", "deployment", name, "-n", ns, "--type", "merge", "-p", patch],
        check=False,
    )
    print(f"  python start override on deployment/{name}")
PY
}
