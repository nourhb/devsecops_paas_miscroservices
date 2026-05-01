"""SSH: create Harbor project `paas` (public) if missing."""
from __future__ import annotations

import base64
import json
import os
import shlex
import sys

import paramiko


def main() -> int:
    pw_ssh = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not pw_ssh:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect("192.168.56.129", username="master", password=pw_ssh, timeout=30)
    try:
        _, o, _ = ssh.exec_command(
            "kubectl get secret -n harbor harbor-core -o json",
            timeout=30,
        )
        data = json.loads(o.read().decode())
        admin_pw = base64.b64decode(data["data"]["HARBOR_ADMIN_PASSWORD"]).decode("utf-8")
        a = shlex.quote(f"admin:{admin_pw}")

        _, o2, _ = ssh.exec_command(
            f"curl -sk -u {a} 'http://192.168.56.129:30002/api/v2.0/projects?page=1&page_size=100'",
            timeout=30,
        )
        projects = json.loads(o2.read().decode())
        names = {p["name"] for p in projects}
        if "paas" in names:
            print("project paas already exists")
            return 0

        body = json.dumps(
            {
                "project_name": "paas",
                "public": True,
                "metadata": {"public": "true"},
            }
        )
        _, o3, e3 = ssh.exec_command(
            f"curl -sk -u {a} -X POST -H 'Content-Type: application/json' "
            f"-d {shlex.quote(body)} http://192.168.56.129:30002/api/v2.0/projects",
            timeout=30,
        )
        out = o3.read().decode() + e3.read().decode()
        print(out.strip() or "created (empty body ok)")
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
