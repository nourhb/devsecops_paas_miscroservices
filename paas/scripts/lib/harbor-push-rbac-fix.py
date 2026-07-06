#!/usr/bin/env python3
# Lab helper script for harbor push rbac fix
"""Fix Harbor registry push RBAC: ensure paas project + push scope in token (actions must include push)."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
ENV_FILE = REPO_ROOT / "paas/frontend/docker-compose.env"
DOT_ENV = REPO_ROOT / "paas/frontend/.env"

NODE_IP = os.environ.get("NODE_IP", "192.168.56.129")
HARBOR_PORT = os.environ.get("HARBOR_NODEPORT", "30002")
HARBOR_HOST = f"harbor.{NODE_IP}.nip.io"
REGISTRY = f"{HARBOR_HOST}:{HARBOR_PORT}"
PROJECT = os.environ.get("HARBOR_PROJECT", "paas")
FALLBACK_PROJECT = os.environ.get("HARBOR_FALLBACK_PROJECT", "library")
PROBE_APP = os.environ.get("HARBOR_PROBE_APP", "simple-app")
ROBOT_NAME = os.environ.get("HARBOR_ROBOT_NAME", "paas-jenkins")
HARBOR_NS = os.environ.get("HARBOR_NS", "harbor")


def log(msg: str) -> None:
    print(msg, flush=True)


def probe_repo(project: str) -> str:
    return f"{project}/{PROBE_APP}"


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
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def list_projects(base: str, user: str, password: str) -> list[dict]:
    code, body = api_call(base, user, password, "/api/v2.0/projects?page_size=100")
    if code != 200:
        log(f"WARN: list projects HTTP {code} body={body[:200]!r}")
        return []
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return []
    if isinstance(parsed, list):
        return parsed
    return list(parsed.get("items") or [])


def delete_project(base: str, user: str, password: str, project: str) -> bool:
    deleted = False
    for proj in list_projects(base, user, password):
        name = (proj.get("name") or "").lower()
        if name != project.lower():
            continue
        pid = proj.get("project_id")
        for target in (str(pid) if pid is not None else None, project):
            if not target:
                continue
            code, body = api_call(base, user, password, f"/api/v2.0/projects/{target}", "DELETE")
            if code in (200, 202, 404):
                log(f"OK: deleted project {project} via id/name={target} HTTP {code}")
                deleted = True
                break
            log(f"WARN: delete project {target} HTTP {code} body={body[:160]!r}")
    if not deleted:
        for target in (project,):
            code, body = api_call(base, user, password, f"/api/v2.0/projects/{target}", "DELETE")
            if code in (200, 202, 404):
                log(f"OK: deleted project {project} by name HTTP {code}")
                deleted = True
            elif code not in (404, 500):
                log(f"WARN: delete by name HTTP {code} body={body[:160]!r}")
    return deleted


def restart_harbor_core() -> None:
    if not shutil_which("kubectl"):
        return
    db_heal = SCRIPT_DIR / "lab-harbor-db-heal.sh"
    if db_heal.is_file():
        log("==> heal Harbor database before restarting core")
        subprocess.run(["bash", str(db_heal)], check=False)
        return
    log("==> restart Harbor core/registry/nginx (recover from API 500)")
    for deploy in ("harbor-core", "harbor-registry", "harbor-nginx"):
        subprocess.run(
            ["kubectl", "rollout", "restart", f"deployment/{deploy}", "-n", HARBOR_NS],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    for deploy in ("harbor-core", "harbor-registry", "harbor-nginx"):
        subprocess.run(
            ["kubectl", "rollout", "status", f"deployment/{deploy}", "-n", HARBOR_NS, "--timeout=300s"],
            check=False,
        )
    time.sleep(8)


def shutil_which(cmd: str) -> bool:
    from shutil import which
    return which(cmd) is not None


def create_project(base: str, user: str, password: str, project: str) -> bool:
    for payload in (
        {"project_name": project, "metadata": {"public": "true"}, "storage_limit": -1},
        {"project_name": project, "metadata": {"public": "true"}},
        {"project_name": project, "public": True},
        {"project_name": project},
    ):
        code, body = api_call(base, user, password, "/api/v2.0/projects", "POST", payload)
        if code in (201, 409):
            log(f"OK: project {project} created HTTP {code}")
            return True
        if "already exists" in body.lower() or "conflict" in body.lower():
            log(f"OK: project {project} already exists")
            return True
        log(f"WARN: create {project} HTTP {code} body={body[:180]!r}")
    code, _ = api_call(base, user, password, f"/api/v2.0/projects/{project}")
    if code == 200:
        return True
    for proj in list_projects(base, user, password):
        if (proj.get("name") or "").lower() == project.lower():
            log(f"OK: project {project} visible in list (project_id={proj.get('project_id')})")
            return True
    return False


def ensure_project(base: str, user: str, password: str, project: str) -> bool:
    code, body = api_call(base, user, password, f"/api/v2.0/projects/{project}")
    if code == 200:
        log(f"OK: project {project} exists ({base})")
        return True
    if code == 404:
        log(f"==> project {project} missing (HTTP 404) — create")
        return create_project(base, user, password, project)
    if code == 500:
        log(f"WARN: GET project {project} HTTP 500 — likely corrupt; delete + recreate")
        log(f"  body={body[:180]!r}")
        delete_project(base, user, password, project)
        time.sleep(3)
        if create_project(base, user, password, project):
            return True
        restart_harbor_core()
        delete_project(base, user, password, project)
        time.sleep(3)
        if create_project(base, user, password, project):
            return True
    log(f"==> create project {project} at {base} (GET was HTTP {code})")
    if create_project(base, user, password, project):
        return True
    restart_harbor_core()
    return create_project(base, user, password, project)


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


def ensure_admin_member(base: str, user: str, password: str, project: str) -> None:
    for role_id in (1, 4, 2):
        code, body = api_call(
            base,
            user,
            password,
            f"/api/v2.0/projects/{project}/members",
            "POST",
            {"role_id": role_id, "member_user": {"username": user}},
        )
        if code in (201, 409):
            log(f"OK: admin member on {project} role_id={role_id} HTTP {code}")
            return
        if "already" in body.lower() or code == 409:
            log(f"OK: admin already member of {project}")
            return
    log(f"WARN: could not add admin to project {project}")


def ensure_robot(base: str, admin_user: str, admin_pass: str, project: str) -> tuple[str, str] | None:
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
                "namespace": project,
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
    log(f"OK: robot {username} created for project {project}")
    return username, secret


def patch_env(path: Path, username: str, password: str, project: str) -> None:
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
        "HARBOR_PROJECT": project,
        "HELM_OCI_PROJECT": project,
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
    log(f"OK: patched {path} (project={project})")


def pick_base(admin_user: str, admin_pass: str) -> str:
    for base in (f"http://{NODE_IP}:{HARBOR_PORT}", f"http://{REGISTRY}"):
        code, _ = api_call(base, admin_user, admin_pass, "/api/v2.0/systeminfo")
        if code == 200:
            return base
    return f"http://{NODE_IP}:{HARBOR_PORT}"


def resolve_push_creds(
    base: str, admin_user: str, admin_pass: str, project: str, repo: str
) -> tuple[str, str, list[str]] | None:
    ensure_admin_member(base, admin_user, admin_pass, project)
    actions = token_actions(base, admin_user, admin_pass, repo)
    log(f"[check] admin token actions for {repo}: {actions!r}")
    if "push" in actions:
        return admin_user, admin_pass, actions
    log("==> admin token lacks push — creating project robot account for CI push")
    robot = ensure_robot(base, admin_user, admin_pass, project)
    if not robot:
        return None
    push_user, push_pass = robot
    actions = token_actions(base, push_user, push_pass, repo)
    log(f"[check] robot token actions for {repo}: {actions!r}")
    if "push" not in actions:
        return None
    return push_user, push_pass, actions


def api_projects_ok(base: str, user: str, password: str) -> bool:
    code, _ = api_call(base, user, password, "/api/v2.0/projects?page_size=1")
    return code == 200


def main() -> int:
    global PROJECT
    admin_user, admin_pass = read_admin_password()
    base = pick_base(admin_user, admin_pass)
    log(f"==> Harbor API base={base}")

    if not api_projects_ok(base, admin_user, admin_pass):
        log("ERROR: Harbor API /projects not healthy — run: bash paas/scripts/lib/lab-harbor-db-heal.sh")
        log("  (harbor-core logs showing harbor-database connection refused = Postgres down)")
        return 1

    project = PROJECT
    repo = probe_repo(project)
    if not ensure_project(base, admin_user, admin_pass, project):
        log(f"WARN: could not ensure project {project} — trying fallback {FALLBACK_PROJECT}")
        if FALLBACK_PROJECT != project and ensure_project(base, admin_user, admin_pass, FALLBACK_PROJECT):
            project = FALLBACK_PROJECT
            repo = probe_repo(project)
            PROJECT = project
            log(f"==> using fallback Harbor project {project} (update PaaS image path to {project}/{PROBE_APP})")
        else:
            log("ERROR: could not ensure any Harbor project for push")
            return 1

    creds = resolve_push_creds(base, admin_user, admin_pass, project, repo)
    if not creds and project != FALLBACK_PROJECT:
        log(f"WARN: no push on {repo} — retry with {FALLBACK_PROJECT}")
        if ensure_project(base, admin_user, admin_pass, FALLBACK_PROJECT):
            project = FALLBACK_PROJECT
            repo = probe_repo(project)
            creds = resolve_push_creds(base, admin_user, admin_pass, project, repo)

    if not creds:
        log("ERROR: Harbor token still lacks push after project + robot fix")
        log("  Manual: kubectl logs -n harbor deploy/harbor-core --tail=80")
        return 1

    push_user, push_pass, actions = creds
    patch_env(ENV_FILE, push_user, push_pass, project)
    if DOT_ENV.is_file() or ENV_FILE.is_file():
        patch_env(DOT_ENV, push_user, push_pass, project)

    sync = SCRIPT_DIR / "sync-harbor-jenkins-job-params.py"
    if sync.is_file():
        os.environ["HARBOR_USERNAME"] = push_user
        os.environ["HARBOR_PASSWORD"] = push_pass
        os.environ["HARBOR_REGISTRY"] = REGISTRY
        os.environ["HARBOR_PROJECT"] = project
        os.environ["HELM_OCI_PROJECT"] = project
        subprocess.run([sys.executable, str(sync)], check=False)

    log(f"OK: Harbor push creds ready user={push_user} project={project} repo={repo} actions={actions}")
    if project != os.environ.get("HARBOR_PROJECT", "paas") and project == FALLBACK_PROJECT:
        log(f"NOTE: redeploy from PaaS so IMAGE_NAME uses /{project}/ not /paas/")
    log("Next: bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh && bash paas/scripts/lab.sh env-quick")
    return 0


if __name__ == "__main__":
    sys.exit(main())
