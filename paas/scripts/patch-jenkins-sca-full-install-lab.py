#!/usr/bin/env python3
"""Fix Step 4 SCA: replace package-lock-only path with full npm install before cyclonedx."""
from __future__ import annotations

import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
SCA_MARKER = "sca-npm-install-full-20260611"
NGINX_MARKER = "nginx-conf-writefile-20260611"
OLD_SCA_MARKER = "sca-npm-install-nolock-20260611"
CDATA_RE = re.compile(
    r"(<definition\b[^>]*class=\"org\.jenkinsci\.plugins\.workflow\.cps\.CpsFlowDefinition\"[^>]*>\s*<script>\s*<!\[CDATA\[)"
    r"([\s\S]*?)"
    r"(\]\]>\s*</script>)",
    re.IGNORECASE,
)


def load_env(path: Path) -> None:
    if not path.is_file():
        return
    skip = frozenset({"COSIGN_PRIVATE_KEY", "COSIGN_PUBLIC_KEY"})
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in skip or key in os.environ:
            continue
        os.environ[key] = val.strip().strip('"').strip("'")


def jenkins_request(
    base: str, user: str, token: str, path: str, method: str = "GET", body: bytes | None = None
) -> tuple[int, str]:
    url = f"{base.rstrip('/')}{path}"
    req = urllib.request.Request(url, data=body, method=method)
    import base64

    req.add_header("Authorization", f"Basic {base64.b64encode(f'{user}:{token}'.encode()).decode()}")
    if body is not None:
        req.add_header("Content-Type", "application/xml; charset=UTF-8")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def get_crumb(base: str, user: str, token: str) -> dict[str, str]:
    code, body = jenkins_request(base, user, token, "/crumbIssuer/api/json")
    if code != 200:
        return {}
    import json

    data = json.loads(body)
    field = data.get("crumbRequestField", "Jenkins-Crumb")
    crumb = data.get("crumb", "")
    return {field: crumb} if crumb else {}


def patch_script(script: str, full_groovy: str | None) -> tuple[str, str]:
    if SCA_MARKER in script and NGINX_MARKER in script and "writeNginxPaasDefaultConf" in script:
        return script, "already fixed"
    if full_groovy and SCA_MARKER in full_groovy:
        return full_groovy, "replaced with full Jenkinsfile"
    raise SystemExit(
        "ERROR: partial regex patch disabled (it broke Step 6 nginx fix in build #576).\n"
        "  scp paas/jenkins/Jenkinsfile.paas-deploy to lab /tmp/ then:\n"
        "  JENKINSFILE=/tmp/Jenkinsfile.paas-deploy bash paas/scripts/restore-jenkins-paas-deploy-lab.sh"
    )


def main() -> int:
    load_env(DEFAULT_ENV)
    base = (os.environ.get("JENKINS_PROBE_URL") or os.environ.get("JENKINS_BASE_URL") or "http://127.0.0.1:30090").rstrip("/")
    user = os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or ""
    job = os.environ.get("JOB_NAME", "paas-deploy")
    jenkinsfile = Path(os.environ.get("JENKINSFILE", REPO_ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy"))

    if not user or not token:
        print("ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN", file=sys.stderr)
        return 1

    full_groovy: str | None = None
    if jenkinsfile.is_file():
        text = jenkinsfile.read_text(encoding="utf-8")
        if SCA_MARKER in text:
            full_groovy = text.replace("\r\n", "\n")

    cfg_path = f"/job/{urllib.parse.quote(job)}/config.xml"
    code, cfg = jenkins_request(base, user, token, cfg_path)
    if code != 200:
        print(f"ERROR: GET config.xml HTTP {code}", file=sys.stderr)
        return 1

    m = CDATA_RE.search(cfg)
    if not m:
        print("ERROR: could not find Pipeline CDATA in config.xml", file=sys.stderr)
        return 1

    old_script = m.group(2)
    new_script, reason = patch_script(old_script, full_groovy)
    if new_script == old_script:
        print(f"OK: Jenkins job already has SCA full-install fix ({reason})")
        return 0

    new_cfg = cfg[: m.start(2)] + new_script + cfg[m.end(2) :]
    headers = get_crumb(base, user, token)
    url = f"{base}{cfg_path}"
    req = urllib.request.Request(url, data=new_cfg.encode("utf-8"), method="POST")
    import base64

    req.add_header("Authorization", f"Basic {base64.b64encode(f'{user}:{token}'.encode()).decode()}")
    req.add_header("Content-Type", "application/xml; charset=UTF-8")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            post_code = resp.status
            post_body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        post_code = e.code
        post_body = e.read().decode("utf-8", errors="replace")
    print(f"POST config.xml -> {post_code} ({reason})")
    if post_code not in (200, 201, 302):
        print(post_body[:2000], file=sys.stderr)
        return 1

    _, verify = jenkins_request(base, user, token, cfg_path)
    vm = CDATA_RE.search(verify)
    script = vm.group(2) if vm else verify
    if SCA_MARKER not in script and "full npm install then cyclonedx-npm" not in script:
        print("ERROR: verify failed — full Jenkinsfile markers not present after POST", file=sys.stderr)
        return 1

    print("OK: Jenkins paas-deploy restored — trigger Build with Parameters (not Replay)")
    print(f"     Console must show: marker={NGINX_MARKER}")
    print(f"     Console must show: marker={SCA_MARKER}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
