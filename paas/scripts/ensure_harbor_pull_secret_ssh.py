"""Create docker-registry secret `harbor-regcred` in devsecops-paas (reads HARBOR_* from paas/frontend/.env)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

import paramiko

REPO = Path(__file__).resolve().parents[1]
ENV = REPO / "frontend" / ".env"

SSH_HOST = "192.168.56.129"
SSH_USER = "master"


def parse_env(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip().strip("'").strip('"')
        out[k.strip()] = v
    return out


def main() -> int:
    ssh_pw = __import__("os").environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
    if not ssh_pw:
        print("Set ARGOCD_REFRESH_SSH_PASSWORD for SSH to the cluster node.", file=sys.stderr)
        return 1
    if not ENV.is_file():
        print(f"Missing {ENV}", file=sys.stderr)
        return 1
    env = parse_env(ENV.read_text(encoding="utf-8"))
    reg = env.get("HARBOR_BASE_URL", "").replace("https://", "").replace("http://", "").rstrip("/")
    user = env.get("HARBOR_USERNAME", "admin")
    pw = env.get("HARBOR_PASSWORD", "")
    if not reg or not pw:
        print("HARBOR_BASE_URL / HARBOR_PASSWORD missing in .env", file=sys.stderr)
        return 1

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SSH_HOST, username=SSH_USER, password=ssh_pw, timeout=30)
    try:
        # Escape for remote shell: password may contain special chars
        def shq(s: str) -> str:
            return "'" + s.replace("'", "'\"'\"'") + "'"

        cmds = [
            "kubectl -n devsecops-paas delete secret harbor-regcred --ignore-not-found",
            (
                "kubectl -n devsecops-paas create secret docker-registry harbor-regcred "
                f"--docker-server={shq(reg)} --docker-username={shq(user)} "
                f"--docker-password={shq(pw)}"
            ),
        ]
        for cmd in cmds:
            _, stdout, stderr = ssh.exec_command(cmd)
            out = stdout.read().decode() + stderr.read().decode()
            if out.strip():
                print(out.rstrip())
        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    raise SystemExit(main())
