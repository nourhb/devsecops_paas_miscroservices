#!/usr/bin/env python3
"""Fix Harbor registry push RBAC: ensure paas project + push scope in token (actions must include push)."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
ENV_FILE = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
DOT_ENV = REPO_ROOT / "paas" / "frontend" / ".env"

NODE_IP = os.environ.get("NODE_IP", "192.168.56.129")
HARBOR_PORT = os.environ.get("HARBOR_NODEPORT", "30002")
HARBOR_HOST = f"harbor.{NODE_IP}.nip.io"
REGISTRY = f"{HARBOR_HOST}:{HARBOR_PORT}"
PROJECT = os.environ.get("HARBOR_PROJECT", "paas")
PROBE_REPO = f"{PROJECT}/simple-app"
ROBOT_NAME = os.environ.get("HARBOR_ROBOT_NAME", "paas-jenkins")
HARBOR_NS = os.environ.get("HARBOR_NS", "harbor")


def log(msg: str) -> None:
    print(msg, flush=True)


def b64url_json(part: str) -> dict:
    part += "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part))


def read_admin_password() -> tuple[str, str]:
    user = os.environ.get("HARBOR_USER", "admin")
    password = os.environ.get("HARBOR_PASS", "Harbor12345")
    try:
        out = subprocess.check_output(
            [
                "kubectl", "get", "secret", "-n", HARBOR_NS, "harbor-core",
                "-o", "jsonpath={.data.HARBOR_ADMIN_PASSWORD}",
            ],
            stderr=subprocess.DEVNULL,
            text=False,
        )
        if out.strip():
            password = base64.b64decode(out).decode("utf-8", errors="replace")
            log(f"OK: admin password from harbor-core secret ({len(password)} chars)")
    except (subprocess.CalledProcessError, FileNotFoundError):
        log("WARN: using admin password from env/default")
    return user, password


def api_call(base: str, user: str, password: str, path: str, method: str = "GET", body: dict | None = None) -> tuple[int, str]:
    url = f"{base.rstrip('/')}{path}"
    data = None
    headers = {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def token_actions(base: str, user: str, password: str, repo: str) -> list[str]:
    scope = f"repository:{repo}:pull,push"
    url = f"{base.rstrip('/')}/service/token?service=harbor-registry&scope={urllib.request.quote(scope, safe='')}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        log(f"WARN: token HTTP {e.code} from {base} repo={repo}: {e.read()[:200]!r}")
        return []
    tok = body.get("token") or ""
    if tok.count(".") < 2:
        return []
    try:
        claims = b64url_json(tok.split(".")[1])
    except (json.JSONDecodeError, ValueError):
        return []
    for acc in claims.get("access") or []:
        if acc.get("name") == repo:
            return list(acc.get("actions") or [])
    return []


def ensure_project(base: str, user: str, password: str) -> bool:
    code, _ = api_call(base, user, password, f"/api/v2.0/projects/{PROJECT}")
    if code == 200:
        log(f"OK: project {PROJECT} exists ({base})")
        return True
    log(f"==> create project {PROJECT} at {base} (GET was HTTP {code})")
    for payload in (
        {"project_name": PROJECT, "metadata": {"public": "true"}},
        {"project_name": PROJECT, "public": True},
    ):
        code, body = api_call(base, user, password, "/api/v2.0/projects", "POST", payload)
        if code in (201, 409):
            log(f"OK: project {PROJECT} created/conflict HTTP {code}")
            return True
        if "already exists" in body.lower() or "conflict" in body.lower():
            log(f"OK: project {PROJECT} already exists")
            return True
        log(f"WARN: create project HTTP {code} body={body[:160]!r}")
    code, _ = api_call(base, user, password, f"/api/v2.0/projects/{PROJECT}")
    if code == 200:
        return True
    return False


def ensure_admin_member(base: str, user: str, password: str) -> None:
    for role_id in (1, 4, 2):
        code, body = api_call(
            base,
            user,
            password,
            f"/api/v2.0/projects/{PROJECT}/members",
            "POST",
            {"role_id": role_id, "member_user": {"username": user}},
        )
        if code in (201, 409):
            log(f"OK: admin member on {PROJECT} role_id={role_id} HTTP {code}")
            return
        if "already" in body.lower() or code == 409:
            log(f"OK: admin already member of {PROJECT}")
            return
    log(f"WARN: could not add admin to project {PROJECT}")


def ensure_robot(base: str, admin_user: str, admin_pass: str) -> tuple[str, str] | None:
    code, body = api_call(base, admin_user, admin_pass, "/api/v2.0/robots?page_size=100")
    if code == 200:
        try:
            parsed = json.loads(body)
            items = parsed if isinstance(parsed, list) else parsed.get("items") or []
            for rob in items:
                name = rob.get("name") or ""
                if ROBOT_NAME in name or name.endswith(f"+{ROBOT_NAME}"):
                    rid = rob.get("id")
                    if rid is not None:
                        api_call(base, admin_user, admin_pass, f"/api/v2.0/robots/{rid}", "DELETE")
                        log(f"==> deleted stale robot id={rid} name={name}")
        except json.JSONDecodeError:
            pass

    payload = {
        "name": ROBOT_NAME,
        "duration": -1,
        "level": "project",
        "disable": False,
        "permissions": [
            {
                "namespace": PROJECT,
                "kind": "project",
                "access": [
                    {"resource": "repository", "action": "push"},
                    {"resource": "repository", "action": "pull"},
                    {"resource": "artifact", "action": "read"},
                    {"resource": "artifact", "action": "list"},
                ],
            }
        ],
    }
    code, body = api_call(base, admin_user, admin_pass, "/api/v2.0/robots", "POST", payload)
    if code not in (200, 201):
        log(f"ERROR: create robot HTTP {code} body={body[:300]!r}")
        return None
    try:
        rob = json.loads(body)
    except json.JSONDecodeError:
        log(f"ERROR: robot response not JSON: {body[:200]!r}")
        return None
    username = rob.get("name") or ""
    secret = rob.get("secret") or ""
    if not username or not secret:
        log(f"ERROR: robot missing name/secret: {body[:300]!r}")
        return None
    log(f"OK: robot {username} created for project {PROJECT}")
    return username, secret


def patch_env(path: Path, username: str, password: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    lines = text.splitlines()
    updates = {
        "HARBOR_USERNAME": username,
        "HARBOR_PASSWORD": password,
        "HARBOR_USER": username,
        "HARBOR_PASS": password,
        "HARBOR_REGISTRY": REGISTRY,
        "HARBOR_BASE_URL": f"http://{REGISTRY}",
    }
    out: list[str] = []
    seen = set()
    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            key = line.split("=", 1)[0].strip()
            if key in updates:
                out.append(f"{key}={updates[key]}")
                seen.add(key)
                continue
        out.append(line)
    for key, val in updates.items():
        if key not in seen:
            out.append(f"{key}={val}")
    path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    log(f"OK: patched {path}")


def pick_base(admin_user: str, admin_pass: str) -> str:
    for base in (f"http://{NODE_IP}:{HARBOR_PORT}", f"http://{REGISTRY}"):
        code, _ = api_call(base, admin_user, admin_pass, "/api/v2.0/systeminfo")
        if code == 200:
            return base
    return f"http://{NODE_IP}:{HARBOR_PORT}"


def main() -> int:
    admin_user, admin_pass = read_admin_password()
    base = pick_base(admin_user, admin_pass)
    log(f"==> Harbor API base={base}")

    if not ensure_project(base, admin_user, admin_pass):
        log("ERROR: could not ensure Harbor project paas")
        return 1

    ensure_admin_member(base, admin_user, admin_pass)

    push_user, push_pass = admin_user, admin_pass
    actions = token_actions(base, admin_user, admin_pass, PROBE_REPO)
    log(f"[check] admin token actions for {PROBE_REPO}: {actions!r}")
    if "push" not in actions:
        log("==> admin token lacks push — creating project robot account for CI push")
        robot = ensure_robot(base, admin_user, admin_pass)
        if not robot:
            return 1
        push_user, push_pass = robot
        actions = token_actions(base, push_user, push_pass, PROBE_REPO)
        log(f"[check] robot token actions for {PROBE_REPO}: {actions!r}")
        if "push" not in actions:
            log("ERROR: robot token still lacks push — Harbor RBAC misconfigured")
            return 1

    patch_env(ENV_FILE, push_user, push_pass)
    if DOT_ENV.is_file() or ENV_FILE.is_file():
        patch_env(DOT_ENV, push_user, push_pass)

    sync = SCRIPT_DIR / "sync-harbor-jenkins-job-params.py"
    if sync.is_file():
        os.environ["HARBOR_USERNAME"] = push_user
        os.environ["HARBOR_PASSWORD"] = push_pass
        os.environ["HARBOR_REGISTRY"] = REGISTRY
        subprocess.run([sys.executable, str(sync)], check=False)

    log(f"OK: Harbor push creds ready user={push_user} registry={REGISTRY}")
    log("Next: bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh && bash paas/scripts/lab.sh env-quick")
    return 0


if __name__ == "__main__":
    sys.exit(main())
