"""Recreate harbor-regcred using admin password from the harbor-core secret (cluster is source of truth)."""
from __future__ import annotations

import base64
import json
import sys

import paramiko

SSH_HOST = "192.168.56.129"
SSH_USER = "master"
NS = "devsecops-paas"


def main() -> int:
    pw = __import__("os").environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
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
        raw = stdout.read().decode() + stderr.read().decode()
        if "HARBOR_ADMIN_PASSWORD" not in raw:
            print(raw[:800], file=sys.stderr)
            return 1
        data = json.loads(raw)
        b64 = data["data"].get("HARBOR_ADMIN_PASSWORD") or data["data"].get("ADMIN_PASSWORD")
        if not b64:
            print("No admin password key in harbor-core secret", file=sys.stderr)
            return 1
        admin_pw = base64.b64decode(b64).decode("utf-8")

        def shq(s: str) -> str:
            return "'" + s.replace("'", "'\"'\"'") + "'"

        reg = "192.168.56.129:30002"
        cmds = [
            f"kubectl -n {NS} delete secret harbor-regcred --ignore-not-found",
            (
                f"kubectl -n {NS} create secret docker-registry harbor-regcred "
                f"--docker-server={shq(reg)} --docker-username=admin "
                f"--docker-password={shq(admin_pw)}"
            ),
        ]
        for cmd in cmds:
            _, o2, e2 = ssh.exec_command(cmd, timeout=30)
            out = o2.read().decode() + e2.read().decode()
            if out.strip():
                print(out.rstrip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
