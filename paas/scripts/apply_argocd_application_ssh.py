"""Apply a single Argo CD Application manifest on the cluster via SSH + kubectl stdin."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import paramiko

REPO = Path(__file__).resolve().parents[1]
DEFAULT_APP = REPO / "gitops" / "argocd" / "sanhome-application.yaml"

HOST = os.environ.get("ARGOCD_REFRESH_SSH_HOST", "192.168.56.129")
USER = os.environ.get("ARGOCD_REFRESH_SSH_USER", "master")
PASSWORD = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_APP
    if not path.is_file():
        print(f"Missing file: {path}", file=sys.stderr)
        return 1
    if not PASSWORD:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1
    yaml_text = path.read_text(encoding="utf-8")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=25)
    try:
        stdin, stdout, stderr = ssh.exec_command("kubectl apply -f -")
        stdin.write(yaml_text)
        stdin.channel.shutdown_write()
        out = stdout.read().decode() + stderr.read().decode()
        print(out)
        return 0 if stdout.channel.recv_exit_status() == 0 else 1
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
