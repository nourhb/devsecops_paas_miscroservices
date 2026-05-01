"""Patch Harbor EXT_ENDPOINT to match IP:NodePort used for docker pull; restart harbor-core."""
from __future__ import annotations

import json
import os
import sys

import paramiko

NEW = "http://192.168.56.129:30002"


def bash_single_quote(s: str) -> str:
    """Quote for remote bash (POSIX)."""
    return "'" + s.replace("'", "'\"'\"'") + "'"


def main() -> int:
    pw = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not pw:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect("192.168.56.129", username="master", password=pw, timeout=30)
    try:
        patch_arg = bash_single_quote(json.dumps({"data": {"EXT_ENDPOINT": NEW}}))
        cmds = [
            f"kubectl patch cm -n harbor harbor-core --type merge -p {patch_arg}",
            "kubectl rollout restart deploy -n harbor harbor-core",
            "kubectl rollout status deploy -n harbor harbor-core --timeout=180s",
        ]
        for cmd in cmds:
            _, o, e = ssh.exec_command(cmd, timeout=200)
            out = (o.read() + e.read()).decode()
            if out.strip():
                print(out.rstrip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
