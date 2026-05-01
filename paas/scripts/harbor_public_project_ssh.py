"""SSH: set Harbor project paas metadata public=true (enables anonymous pull token)."""
from __future__ import annotations

import base64
import json
import os
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
        _, o, e = ssh.exec_command(
            "kubectl get secret -n harbor harbor-core -o json",
            timeout=30,
        )
        data = json.loads(o.read().decode())
        admin_pw = base64.b64decode(data["data"]["HARBOR_ADMIN_PASSWORD"]).decode("utf-8")

        # GET project id for "paas"
        import shlex

        a = shlex.quote(f"admin:{admin_pw}")
        _, o2, e2 = ssh.exec_command(
            f"curl -sk -u {a} http://192.168.56.129:30002/api/v2.0/projects?name=paas",
            timeout=30,
        )
        proj_raw = o2.read().decode() + e2.read().decode()
        projects = json.loads(proj_raw.strip())
        if not projects:
            print("project paas not found:", proj_raw[:400], file=sys.stderr)
            return 1
        pid = projects[0]["project_id"]
        print("project_id", pid)

        # PUT metadata public (Harbor 2.x)
        body = json.dumps({"public": True})
        _, o3, e3 = ssh.exec_command(
            f"curl -sk -u {a} -X PUT -H 'Content-Type: application/json' "
            f"-d {shlex.quote(body)} http://192.168.56.129:30002/api/v2.0/projects/{pid}",
            timeout=30,
        )
        out = o3.read().decode() + e3.read().decode()
        if out.strip():
            print(out.rstrip())
        print("done")
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
