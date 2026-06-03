#!/usr/bin/env python3
"""Trigger paas-deploy on lab Jenkins with session cookie + CSRF crumb (avoids 403)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"

# Reuse Jenkins client from create_jenkins_paas_deploy_job.py
sys.path.insert(0, str(Path(__file__).resolve().parent))
from create_jenkins_paas_deploy_job import (  # noqa: E402
    JenkinsClient,
    lab_jenkins_base_url,
    load_env_file,
)


def sanitize_project_name(name: str) -> str:
    out = "".join(c if c.isalnum() or c in "._-" else "-" for c in name.lower())
    while "--" in out:
        out = out.replace("--", "-")
    return out.strip("-") or "app"


def build_image_name(project_name: str) -> str:
    template = os.environ.get("DEPLOY_IMAGE_NAME_TEMPLATE", "").strip()
    if template:
        harbor_project = os.environ.get("HARBOR_PROJECT", "paas")
        return template.replace("{{projectName}}", project_name).replace("{{harborProject}}", harbor_project)
    harbor_base = os.environ.get("HARBOR_BASE_URL", os.environ.get("HARBOR_REGISTRY", "")).strip()
    harbor_project = os.environ.get("HARBOR_PROJECT", "paas").strip()
    host = harbor_base.replace("https://", "").replace("http://", "").split("/")[0].rstrip("/")
    if host:
        return f"{host}/{harbor_project}/{sanitize_project_name(project_name)}"
    raise SystemExit("ERROR: set HARBOR_BASE_URL or HARBOR_REGISTRY in docker-compose.env")


def postgres_creds() -> tuple[str, str, str, str]:
    """Return (user, password, database, kubectl_target)."""
    ns = os.environ.get("PAAS_NS", "paas")
    target = os.environ.get("POSTGRES_KUBE_TARGET", f"deploy/postgres -n {ns}")
    url = os.environ.get("DATABASE_URL", "").strip()
    user, password, db = "postgres", "root", "paas"
    if url.startswith("postgresql://") or url.startswith("postgres://"):
        parsed = urllib.parse.urlparse(url)
        if parsed.username:
            user = urllib.parse.unquote(parsed.username)
        if parsed.password:
            password = urllib.parse.unquote(parsed.password)
        if parsed.path and parsed.path.strip("/"):
            db = urllib.parse.unquote(parsed.path.lstrip("/").split("?")[0])
    user = os.environ.get("POSTGRES_USER", user)
    password = os.environ.get("POSTGRES_PASSWORD", password)
    db = os.environ.get("POSTGRES_DB", db)
    return user, password, db, target


def fetch_project_from_db(project_id: str) -> tuple[str, str, str, str]:
    """Return (git_url, branch, project_name, git_credentials_id) from PaaS Postgres via kubectl."""
    user, password, db, target = postgres_creds()
    ns = os.environ.get("PAAS_NS", "paas")
    sql = (
        'SELECT "gitRepositoryUrl", branch, "projectName", COALESCE("gitCredentialsId", \'\') FROM "Project" '
        f"WHERE id='{project_id}' LIMIT 1;"
    )
    # Escape single quotes in project_id (uuid has none)
    cmd = [
        "kubectl",
        "exec",
        "-n",
        ns,
        "deploy/postgres",
        "--",
        "env",
        f"PGPASSWORD={password}",
        "psql",
        "-U",
        user,
        "-d",
        db,
        "-t",
        "-A",
        "-F|",
        "-c",
        sql,
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=60).strip()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise SystemExit(f"ERROR: could not read project from Postgres: {e}") from e
    if not out or "|" not in out:
        raise SystemExit(f"ERROR: project not found in DB for id={project_id}")
    parts = [p.strip() for p in out.split("|")]
    if len(parts) < 3:
        raise SystemExit(f"ERROR: incomplete project row: {out!r}")
    git_url, branch, project_name = parts[0], parts[1], parts[2]
    git_creds = parts[3] if len(parts) > 3 else ""
    if not git_url or not project_name:
        raise SystemExit(f"ERROR: incomplete project row: {out!r}")
    return git_url, branch or "main", project_name, git_creds


def main() -> int:
    load_env_file(DEFAULT_ENV)
    base = lab_jenkins_base_url()
    user = os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or ""
    job = os.environ.get("JOB_NAME", "paas-deploy")
    project_id = os.environ.get("PROJECT_ID", "").strip()
    git_url = os.environ.get("GIT_URL", "").strip()
    branch = os.environ.get("BRANCH", "").strip()
    image_name = os.environ.get("IMAGE_NAME", "").strip()

    if not user or not token:
        print("ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN", file=sys.stderr)
        return 1

    git_credentials_id = os.environ.get("GIT_CREDENTIALS_ID", "").strip()
    if project_id and (not git_url or not image_name):
        git_url_db, branch_db, project_name, git_creds_db = fetch_project_from_db(project_id)
        git_url = git_url or git_url_db
        branch = branch_db if not branch else branch
        image_name = image_name or build_image_name(project_name)
        if not git_credentials_id and git_creds_db:
            git_credentials_id = git_creds_db
        print(f"From DB: projectName={project_name} git={git_url} branch={branch} image={image_name}")

    if not project_id or not git_url or not image_name:
        print(
            "Usage: PROJECT_ID=<uuid> python3 paas/scripts/trigger-paas-deploy-lab.py\n"
            "  Optional: GIT_URL=... IMAGE_NAME=... BRANCH=main\n"
            "  Reads project from PaaS Postgres when GIT_URL/IMAGE_NAME omitted.",
            file=sys.stderr,
        )
        return 1

    client = JenkinsClient(base, user, token)
    code, body = client.call(f"/job/{urllib.parse.quote(job)}/lastBuild/api/json")
    baseline = None
    if code == 200:
        try:
            baseline = json.loads(body).get("number")
        except json.JSONDecodeError:
            baseline = None

    fast = (os.environ.get("JENKINS_PAAS_FAST_PIPELINE") or "false").strip().lower()
    params = {
        "GIT_URL": git_url,
        "BRANCH": branch,
        "IMAGE_NAME": image_name,
        "PROJECT_ID": project_id,
        "JENKINS_PAAS_FAST_PIPELINE": "true" if fast in ("1", "true", "yes") else "false",
    }
    if git_credentials_id:
        params["GIT_CREDENTIALS_ID"] = git_credentials_id
    default_git_creds = (os.environ.get("JENKINS_DEPLOY_GIT_CREDENTIALS_ID") or os.environ.get("GIT_CREDENTIALS_ID_DEFAULT") or "").strip()
    if not git_credentials_id and default_git_creds:
        params["GIT_CREDENTIALS_ID"] = default_git_creds
    for key in (
        "SONAR_HOST_URL",
        "SONAR_TOKEN",
        "DEPENDENCY_TRACK_BASE_URL",
        "DEPENDENCY_TRACK_API_KEY",
        "HARBOR_REGISTRY",
        "HARBOR_REGISTRY_PUSH",
        "HARBOR_FORCE_NODEPORT_PUSH",
        "HARBOR_REGISTRY_NGINX_CLUSTER",
        "HARBOR_USERNAME",
        "HARBOR_PASSWORD",
        "COSIGN_PRIVATE_KEY",
        "COSIGN_PASSWORD",
        "COSIGN_ALLOW_INSECURE_REGISTRY",
    ):
        if key == "SONAR_HOST_URL":
            val = (os.environ.get("SONAR_HOST_URL") or os.environ.get("SONAR_BASE_URL") or "").strip()
        else:
            val = (os.environ.get(key) or "").strip()
        if val:
            params[key] = val

    q = urllib.parse.urlencode(params)
    path = f"/job/{urllib.parse.quote(job)}/buildWithParameters?{q}"
    extra = client.crumb_headers()
    code, resp = client.call(path, "POST", extra=extra)
    print(f"POST buildWithParameters -> HTTP {code}")
    if code not in (200, 201, 302):
        print(resp[:2000], file=sys.stderr)
        return 1

    import time

    for _ in range(30):
        time.sleep(2)
        code, body = client.call(f"/job/{urllib.parse.quote(job)}/lastBuild/api/json")
        if code != 200:
            continue
        try:
            last = json.loads(body)
        except json.JSONDecodeError:
            continue
        num = last.get("number")
        if baseline is None or (num and num > baseline):
            print(f"OK: new build #{num} result={last.get('result')} building={last.get('building')}")
            print(f"Console: {base}/job/{job}/{num}/console")
            return 0
    print(f"WARN: trigger accepted but new build number not visible yet (baseline={baseline})")
    print(f"Check: {base}/job/{job}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
