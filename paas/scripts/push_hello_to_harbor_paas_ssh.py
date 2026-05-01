"""
SSH: docker login Harbor, copy hello-app to 192.168.56.129:30002/paas/sanhome:latest
(kubectl as regular user; docker via sudo)
"""
from __future__ import annotations

import os
import sys

import paramiko

REG = "192.168.56.129:30002"
DST = f"{REG}/paas/sanhome:latest"
SRC = "gcr.io/google-samples/hello-app:1.0"


def main() -> int:
    ssh_pw = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not ssh_pw:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1

    inner = f"""
set -e
PW=$(kubectl get secret -n harbor harbor-core -o jsonpath='{{.data.HARBOR_ADMIN_PASSWORD}}' | base64 -d)
echo '{ssh_pw}' | sudo -S docker login {REG} -u admin -p "$PW"
echo '{ssh_pw}' | sudo -S docker pull {SRC}
echo '{ssh_pw}' | sudo -S docker tag {SRC} {DST}
echo '{ssh_pw}' | sudo -S docker push {DST}
echo PUSH_OK
"""

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect("192.168.56.129", username="master", password=ssh_pw, timeout=30)
    try:
        stdin, stdout, stderr = ssh.exec_command("bash -s", timeout=600)
        stdin.write(inner)
        stdin.channel.shutdown_write()
        out = stdout.read().decode() + stderr.read().decode()
        print(out[-4000:] if len(out) > 4000 else out)
        return 0 if "PUSH_OK" in out else 1
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
