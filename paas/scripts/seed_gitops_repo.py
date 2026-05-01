"""
Upload paas/gitops/* to the GitHub repo configured in paas/frontend/.env (GITOPS_*).
Run from repo root: python paas/scripts/seed_gitops_repo.py
"""
from __future__ import annotations

import base64
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_PATH = ROOT / "paas" / "frontend" / ".env"
GITOPS_DIR = ROOT / "paas" / "gitops"


def load_env() -> dict[str, str]:
    text = ENV_PATH.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip("'").strip('"')
    return out


def parse_repo(url: str) -> tuple[str, str]:
    cleaned = url.strip().rstrip("/").replace(".git", "")
    m = re.search(r"github\.com/([\w.-]+)/([\w.-]+)$", cleaned, re.I)
    if not m:
        raise SystemExit(f"GITOPS_REPO_URL must be github.com owner/repo, got: {url[:80]}")
    return m.group(1), m.group(2)


def github_put(
    token: str,
    owner: str,
    repo: str,
    path: str,
    content_bytes: bytes,
    message: str,
    branch: str,
) -> None:
    parts = [urllib.parse.quote(s, safe="") for s in path.split("/") if s]
    api_path = "/".join(parts)
    api_url = f"https://api.github.com/repos/{owner}/{repo}/contents/{api_path}"

    body: dict = {
        "message": message,
        "content": base64.b64encode(content_bytes).decode("ascii"),
        "branch": branch,
    }

    get_req = urllib.request.Request(
        f"{api_url}?ref={urllib.parse.quote(branch)}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(get_req, timeout=30) as resp:
            meta = json.loads(resp.read().decode())
            if meta.get("sha"):
                body["sha"] = meta["sha"]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise

    put_req = urllib.request.Request(
        api_url,
        data=json.dumps(body).encode("utf-8"),
        method="PUT",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(put_req, timeout=60) as resp:
        resp.read()


def main() -> int:
    env = load_env()
    token = env.get("GITOPS_REPO_TOKEN", "")
    repo_url = env.get("GITOPS_REPO_URL", "")
    branch = env.get("GITOPS_DEFAULT_BRANCH", "main")
    if not token or not repo_url:
        print("Missing GITOPS_REPO_TOKEN or GITOPS_REPO_URL in paas/frontend/.env", file=sys.stderr)
        return 1

    owner, repo = parse_repo(repo_url)
    readme = GITOPS_DIR / "README.md"
    if not readme.exists():
        readme.write_text(
            "# GitOps\n\nHelm charts consumed by Argo CD. Pushed from the DevSecOps PaaS repo.\n",
            encoding="utf-8",
        )

    files = sorted(p for p in GITOPS_DIR.rglob("*") if p.is_file())
    if not files:
        print(f"No files under {GITOPS_DIR}", file=sys.stderr)
        return 1

    print(f"Seeding {len(files)} files to {owner}/{repo} branch {branch}...")
    for path in files:
        rel = path.relative_to(GITOPS_DIR).as_posix()
        raw = path.read_bytes()
        msg = f"chore(gitops): add {rel}"
        github_put(token, owner, repo, rel, raw, msg, branch)
        print(f"  OK {rel}")

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
