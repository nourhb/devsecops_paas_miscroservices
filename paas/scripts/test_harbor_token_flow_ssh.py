"""SSH: Harbor token + manifest GET (bash + jq on node)."""
from __future__ import annotations

import os
import sys

import paramiko

BASH = r"""
set -e
PW=$(kubectl get secret -n harbor harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)
TOK=$(curl -sk -u "admin:${PW}" \
  "http://192.168.56.129:30002/service/token?service=harbor-registry&scope=repository:paas/sanhome:pull" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOK}" \
  "http://192.168.56.129:30002/v2/paas/sanhome/manifests/latest"
echo
"""


def main() -> int:
    pw = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not pw:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD", file=sys.stderr)
        return 1
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect("192.168.56.129", username="master", password=pw, timeout=30)
    try:
        stdin, stdout, stderr = ssh.exec_command("bash -s", timeout=60)
        stdin.write(BASH)
        stdin.channel.shutdown_write()
        print((stdout.read() + stderr.read()).decode().strip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
