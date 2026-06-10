#!/usr/bin/env bash
# Mount a sane nginx server block over broken repo nginx.conf baked into crane images.
patch_nginx_deploy_lab() {
  local ns="$1"
  local cm="paas-nginx-override"
  [[ -n "${ns}" ]] || return 1

  kubectl create configmap "${cm}" -n "${ns}" --dry-run=client -o yaml \
    --from-literal=default.conf='server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}' | kubectl apply -f - >/dev/null

  python3 - "${ns}" "${cm}" <<'PY'
import json, subprocess, sys

ns, cm = sys.argv[1:3]
out = subprocess.check_output(
    ["kubectl", "get", "deploy", "-n", ns, "-o", "json"], text=True
)
data = json.loads(out)
for dep in data.get("items", []):
    name = dep.get("metadata", {}).get("name", "")
    if name.endswith("-blue") or name.endswith("-green"):
        continue
    spec = dep.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
    volumes = spec.setdefault("volumes", [])
    if not any(v.get("name") == "paas-nginx-conf" for v in volumes):
        volumes.append({"name": "paas-nginx-conf", "configMap": {"name": cm}})
    containers = spec.get("containers") or []
    if not containers:
        continue
    mounts = containers[0].setdefault("volumeMounts", [])
    if not any(m.get("name") == "paas-nginx-conf" for m in mounts):
        mounts.append({
            "name": "paas-nginx-conf",
            "mountPath": "/etc/nginx/conf.d/default.conf",
            "subPath": "default.conf",
        })
    # crane mutate used a single CMD string → docker-entrypoint exec fails with "nginx -g daemon off;: not found"
    containers[0]["command"] = ["nginx"]
    containers[0]["args"] = ["-g", "daemon off;"]
    patch = json.dumps({"spec": dep["spec"]})
    subprocess.run(
        ["kubectl", "patch", "deployment", name, "-n", ns, "--type", "merge", "-p", patch],
        check=False,
    )
    print(f"  nginx override mounted on deployment/{name}")
PY
}
