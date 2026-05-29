#!/usr/bin/env python3
"""Create Jenkins job paas-deploy from Jenkinsfile.paas-deploy. Run on lab master."""
from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
DEFAULT_JENKINSFILE = REPO_ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy"

CRANE_MARKERS = (
    "crane-next16-202605-j48300-split",
    "crane-next16-202605-j48300",
    "crane-next16-202605",
)
STALE_CRANE_RE = "version.split('.').map(Number);process.exit((v[0]||0)>=16"


def assert_jenkinsfile_crane_fix(groovy: str, path: Path) -> None:
    if not any(m in groovy for m in CRANE_MARKERS):
        print(
            f"ERROR: {path} missing one of {CRANE_MARKERS} (Step 6 still breaks Next.js 16 with --no-lint).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh",
            file=sys.stderr,
        )
        sys.exit(1)
    if STALE_CRANE_RE in groovy and "foreground cmd; JENKINS-48300" not in groovy:
        print(
            f"ERROR: {path} has obsolete Step 6 next build logic.\n"
            "  git pull origin main",
            file=sys.stderr,
        )
        sys.exit(1)


MINIMAL_GROOVY = """node('built-in') {
  stage('PaaS placeholder') {
    echo 'paas-deploy created ??? run full sync or replace script from Jenkinsfile.paas-deploy'
  }
}
"""


# In-cluster URLs from docker-compose.env break host-side API calls (DNS fails on VM).
_HOST_ENV_SKIP = frozenset({"JENKINS_BASE_URL", "JENKINS_URL", "JENKINS_PROBE_URL"})


def load_env_file(path: Path, *, skip_keys: frozenset[str] = _HOST_ENV_SKIP) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in skip_keys or not key or key in os.environ:
            continue
        os.environ[key] = val


def esc_xml(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_cdata(t: str) -> str:
    return t.replace("]]>", "]]]]><![CDATA[>")


CPS_FLOW_DEFINITION = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
CDATA_SCRIPT_BLOCK = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW_DEFINITION)}"[^>]*>\s*<script>\s*<!\[CDATA\[)'
    r"([\s\S]*?)"
    r"(\]\]>\s*</script>)",
    re.IGNORECASE,
)


def merge_groovy_into_existing_config_xml(existing_xml: str, groovy: str) -> str:
    """Replace only the Pipeline script CDATA — keeps Jenkins job parameters/plugins intact."""
    inner = esc_cdata(groovy)
    m = CDATA_SCRIPT_BLOCK.search(existing_xml)
    if m:
        return existing_xml[: m.start(2)] + inner + existing_xml[m.end(2) :]
    return build_xml(groovy, minimal_params=False).decode("utf-8")


def build_xml(groovy: str, minimal_params: bool) -> bytes:
    if minimal_params:
        params = [
            ("GIT_URL", ""),
            ("BRANCH", "main"),
            ("IMAGE_NAME", ""),
            ("PROJECT_ID", ""),
            ("JENKINS_AGENT_LABEL", ""),
        ]
    else:
        params = [
            ("JENKINS_AGENT_LABEL", ""),
            ("GIT_URL", ""),
            ("BRANCH", "main"),
            ("IMAGE_NAME", ""),
            ("PROJECT_ID", ""),
            ("GIT_CREDENTIALS_ID", ""),
            ("HARBOR_REGISTRY", ""),
            ("HARBOR_USERNAME", ""),
            ("HARBOR_PASSWORD", ""),
            ("JENKINS_PAAS_FAST_PIPELINE", "false"),
        ]
    pxml = "\n".join(
        "      <hudson.model.StringParameterDefinition>"
        f"<name>{esc_xml(n)}</name>"
        f"<description></description>"
        f"<defaultValue>{esc_xml(d)}</defaultValue>"
        f"<trim>true</trim>"
        "</hudson.model.StringParameterDefinition>"
        for n, d in params
    )
    inner = esc_cdata(groovy)
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<flow-definition plugin="workflow-job">\n'
        "  <description>paas-deploy (create_jenkins_paas_deploy_job.py)</description>\n"
        "  <keepDependencies>false</keepDependencies>\n"
        "  <properties>\n"
        "    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>\n"
        "      <abortPrevious>false</abortPrevious>\n"
        "    </org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>\n"
        "    <hudson.model.ParametersDefinitionProperty>\n"
        "      <parameterDefinitions>\n"
        f"{pxml}\n"
        "      </parameterDefinitions>\n"
        "    </hudson.model.ParametersDefinitionProperty>\n"
        "  </properties>\n"
        '  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">\n'
        f"    <script><![CDATA[{inner}]]></script>\n"
        "    <sandbox>true</sandbox>\n"
        "  </definition>\n"
        "  <triggers/>\n"
        "  <disabled>false</disabled>\n"
        "</flow-definition>\n"
    )
    return xml.encode("utf-8")


class JenkinsClient:
    def __init__(self, base: str, user: str, token: str) -> None:
        self.base = base.rstrip("/")
        self.auth = base64.b64encode(f"{user}:{token}".encode()).decode()
        self.cj = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cj))

    def call(
        self,
        path: str,
        method: str = "GET",
        data: bytes | None = None,
        extra: dict[str, str] | None = None,
    ) -> tuple[int, str]:
        headers = {"Authorization": f"Basic {self.auth}"}
        if data is not None:
            headers["Content-Type"] = "application/xml; charset=UTF-8"
        if extra:
            headers.update(extra)
        url = f"{self.base}{path}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self.opener.open(req, timeout=300) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def crumb_headers(self) -> dict[str, str]:
        code, body = self.call("/crumbIssuer/api/json")
        if code != 200:
            return {}
        j = json.loads(body)
        return {j["crumbRequestField"]: j["crumb"]}


def lab_jenkins_base_url() -> str:
    """Always NodePort on VM host; never docker-compose in-cluster service URL."""
    base = os.environ.get("JENKINS_LAB_LOOPBACK", "http://127.0.0.1:30090").strip()
    return base.rstrip("/")


def wait_for_jenkins_api(base: str, timeout_sec: int = 300) -> bool:
    import time

    deadline = time.time() + timeout_sec
    url = f"{base}/api/json"
    n = 0
    while time.time() < deadline:
        n += 1
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status == 200:
                    print(f"Jenkins API ready ({url}) after {n} attempt(s)")
                    return True
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"waiting for Jenkins ({n}): {e}")
        time.sleep(5)
    print(f"ERROR: Jenkins not reachable at {url} within {timeout_sec}s", file=sys.stderr)
    return False


def main() -> int:
    load_env_file(DEFAULT_ENV)
    base = lab_jenkins_base_url()
    user = os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or ""
    job = os.environ.get("JOB_NAME", "paas-deploy")
    minimal = "--minimal" in sys.argv
    force = "--force" in sys.argv
    force_full = "--force-full" in sys.argv
    jenkinsfile = Path(os.environ.get("JENKINSFILE", str(DEFAULT_JENKINSFILE)))

    if not user or not token:
        print("ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN in docker-compose.env", file=sys.stderr)
        return 1
    if any(x in token for x in ("paste", "YOUR", "REAL_TOKEN")):
        print("ERROR: JENKINS_API_TOKEN looks like a placeholder", file=sys.stderr)
        return 1

    if minimal:
        groovy = MINIMAL_GROOVY
        print("Mode: --minimal (small pipeline; replace later via PaaS sync or UI)")
    else:
        if not jenkinsfile.is_file():
            print(f"ERROR: missing {jenkinsfile}", file=sys.stderr)
            return 1
        groovy = jenkinsfile.read_text(encoding="utf-8").replace("\r\n", "\n")
        if not groovy.strip():
            print("ERROR: empty Jenkinsfile", file=sys.stderr)
            return 1
        assert_jenkinsfile_crane_fix(groovy, jenkinsfile)

    if not wait_for_jenkins_api(base):
        return 1

    client = JenkinsClient(base, user, token)
    code, _ = client.call("/api/json")
    print(f"GET /api/json -> {code}")
    if code != 200:
        return 1

    code, pm_body = client.call("/pluginManager/api/json?depth=1")
    pipeline_markers = ("workflow-job", "workflow-cps", "workflow-aggregator")
    if code == 200 and not any(m in pm_body for m in pipeline_markers):
        print(
            "ERROR: Pipeline plugins not installed "
            f"(need one of: {', '.join(pipeline_markers)}).",
            file=sys.stderr,
        )
        print(
            "Run: bash paas/scripts/install-jenkins-plugins-lab.sh  (wait for 'Pipeline plugins ready')",
            file=sys.stderr,
        )
        return 1

    job_path = f"/job/{urllib.parse.quote(job)}/api/json"
    job_cfg = f"/job/{urllib.parse.quote(job)}/config.xml"
    code, _ = client.call(job_path)
    xml = build_xml(groovy, minimal_params=minimal)

    if code == 200 and not force:
        print(f"Job '{job}' already exists: {base}/job/{job}/")
        print("Re-run with --force to replace Pipeline script from Jenkinsfile.paas-deploy")
        return 0

    if code == 200 and force:
        if force_full:
            mode = "full-document"
            print(f"Updating existing job '{job}' ({len(xml)} bytes, {mode} — params + no concurrent builds)")
        else:
            cfg_code, existing_cfg = client.call(job_cfg)
            if cfg_code == 200 and existing_cfg.strip():
                merged = merge_groovy_into_existing_config_xml(existing_cfg, groovy)
                xml = merged.encode("utf-8")
                mode = "merged-cdata"
            else:
                mode = "full-document"
            print(f"Updating existing job '{job}' ({len(xml)} bytes, {mode})")
        extra = client.crumb_headers()
        if extra:
            print(f"Crumb: {list(extra.keys())[0]}")
        ucode, ubody = client.call(job_cfg, "POST", xml, extra)
        print(f"POST config.xml -> {ucode}")
        if ucode not in (200, 201, 302):
            print(ubody[:2500])
            return 1
        print(f"OK: {base}/job/{job}/")
        return 0

    print(f"POST body size: {len(xml)} bytes")
    extra = client.crumb_headers()
    if extra:
        print(f"Crumb: {list(extra.keys())[0]}")

    code, body = client.call(
        f"/createItem?name={urllib.parse.quote(job)}",
        "POST",
        xml,
        extra,
    )
    print(f"POST /createItem -> {code}")
    if code not in (200, 201, 302):
        print(body[:2500])
        print("\nIf HTTP 500: install Pipeline plugins in Jenkins UI, then retry with --minimal first.")
        return 1

    code, _ = client.call(job_path)
    print(f"Verify job -> {code}")
    print(f"OK: {base}/job/{job}/")
    return 0 if code == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
