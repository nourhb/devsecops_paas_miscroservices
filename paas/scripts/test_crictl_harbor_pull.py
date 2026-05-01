"""SSH: test Harbor pull with admin password from harbor-core (crictl)."""
from __future__ import annotations

import base64
import json
import os
import shlex
import sys

import paramiko

SSH_HOST = "192.168.56.129"
SSH_USER = "master"


def main() -> int:
    pw = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not pw:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SSH_HOST, username=SSH_USER, password=pw, timeout=30)
    try:
        _, stdout, stderr = ssh.exec_command(
            "kubectl get secret -n harbor harbor-core -o json",
            timeout=30,
        )
        raw = stdout.read().decode()
        if not raw.strip():
            print(stderr.read().decode(), file=sys.stderr)
            return 1
        data = json.loads(raw)
        admin_pw = base64.b64decode(data["data"]["HARBOR_ADMIN_PASSWORD"]).decode("utf-8")

        creds = f"admin:{admin_pw}"
        q = shlex.quote(creds)
        # Lab VM: sudo password often matches SSH password
        spw = shlex.quote(pw)
        _, o2, e2 = ssh.exec_command(
            f"echo {spw} | sudo -S crictl pull --creds {q} "
            f"192.168.56.129:30002/paas/sanhome:latest 2>&1 | tail -15",
            timeout=180,
        )
        out = o2.read().decode() + e2.read().decode()
        print(out.strip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
