"""SSH: probe Harbor REST API and Docker v2 with admin password from harbor-core."""
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
        _, stdout, _ = ssh.exec_command(
            "kubectl get secret -n harbor harbor-core -o json",
            timeout=30,
        )
        data = json.loads(stdout.read().decode())
        admin_pw = base64.b64decode(data["data"]["HARBOR_ADMIN_PASSWORD"]).decode("utf-8")

        checks = [
            "curl -sk -o /dev/null -w '%{http_code}' -u admin:'PASS' http://192.168.56.129:30002/api/v2.0/projects",
            "curl -sk -o /dev/null -w '%{http_code}' -u admin:'PASS' http://192.168.56.129:30002/v2/",
            "curl -skI -u admin:'PASS' http://192.168.56.129:30002/v2/paas/sanhome/manifests/latest -o /dev/null -w '%{http_code}'",
        ]
        for pat in checks:
            cmd = pat.replace("'PASS'", "'" + admin_pw.replace("'", "'\"'\"'") + "'")
            _, o, e = ssh.exec_command(cmd, timeout=30)
            print(cmd[:80], "->", (o.read() + e.read()).decode().strip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
