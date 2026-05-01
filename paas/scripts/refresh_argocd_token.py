"""
One-off / lab: read Argo admin password from cluster (SSH), POST /api/v1/session,
and update paas/frontend/.env ARGOCD_AUTH_TOKEN.

Requires: paramiko, SSH access to the node that runs kubectl.
Set env: ARGOCD_REFRESH_SSH_HOST, ARGOCD_REFRESH_SSH_USER, ARGOCD_REFRESH_SSH_PASSWORD
or edit defaults below.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import paramiko

REPO_ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = REPO_ROOT / "frontend" / ".env"

# Override via environment (no secrets in repo).
SSH_HOST = os.environ.get("ARGOCD_REFRESH_SSH_HOST", "192.168.56.129")
SSH_USER = os.environ.get("ARGOCD_REFRESH_SSH_USER", "master")
SSH_PASSWORD = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")

ARGO_BASE = os.environ.get("ARGOCD_BASE_URL", "http://192.168.56.129:32176").rstrip("/")


def _read_admin_password() -> str:
    if not SSH_PASSWORD:
        print(
            "Set ARGOCD_REFRESH_SSH_PASSWORD (SSH to the node that runs kubectl).",
            file=sys.stderr,
        )
        sys.exit(1)
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SSH_HOST, username=SSH_USER, password=SSH_PASSWORD, timeout=25)
    try:
        # Decode on the remote host (Linux) to avoid PowerShell/base64 issues.
        cmd = (
            "kubectl -n argocd get secret argocd-initial-admin-secret "
            "-o jsonpath='{.data.password}' | base64 -d"
        )
        _, stdout, stderr = ssh.exec_command(cmd)
        out = stdout.read().decode("utf-8", "ignore").strip()
        err = stderr.read().decode("utf-8", "ignore").strip()
        if err:
            print(err, file=sys.stderr)
        return out
    finally:
        ssh.close()


def _create_admin_api_token(session_jwt: str) -> str | None:
    """POST /api/v1/account/admin/token — requires a valid session JWT."""
    token_id = "paas-%d" % int(time.time())
    body = json.dumps({"id": token_id, "expiresIn": 31536000}).encode()
    req = urllib.request.Request(
        f"{ARGO_BASE}/api/v1/account/admin/token",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {session_jwt}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            out = json.loads(r.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", "ignore")[:800]
        if e.code == 500 and "apiKey capability" in err_body:
            # Default `admin` is login-only; session JWT is still valid for API calls.
            return None
        print("Create admin API token failed:", e.code, err_body, file=sys.stderr)
        return None
    except Exception as e:
        print("Create admin API token failed:", e, file=sys.stderr)
        return None
    t = out.get("token")
    return t if isinstance(t, str) and t else None


def main() -> int:
    adm = _read_admin_password()
    if not adm:
        print("Could not read admin password from cluster.", file=sys.stderr)
        return 1

    data = json.dumps({"username": "admin", "password": adm}).encode()
    req = urllib.request.Request(
        f"{ARGO_BASE}/api/v1/session",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.loads(r.read())
    session_jwt = body.get("token")
    if not session_jwt:
        print("Session response:", body, file=sys.stderr)
        return 1

    # Prefer a long-lived API key for `admin` (sub claim `admin:apiKey`); session JWTs expire sooner.
    api_token = _create_admin_api_token(session_jwt)
    token = api_token or session_jwt

    if not ENV_FILE.is_file():
        print(f"Missing {ENV_FILE}", file=sys.stderr)
        return 1

    text = ENV_FILE.read_text(encoding="utf-8")
    if not re.search(r"^ARGOCD_AUTH_TOKEN=.*$", text, re.M):
        print("ARGOCD_AUTH_TOKEN line not found in .env", file=sys.stderr)
        return 1

    new_line = "ARGOCD_AUTH_TOKEN=" + token
    text2 = re.sub(r"^ARGOCD_AUTH_TOKEN=.*$", new_line, text, count=1, flags=re.M)

    ENV_FILE.write_text(text2, encoding="utf-8")
    kind = "api" if api_token else "session"
    print("OK: ARGOCD_AUTH_TOKEN refreshed kind=%s len=%s" % (kind, len(token)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
