#!/usr/bin/env python3
"""Create Jenkins job paas-deploy from Jenkinsfile.paas-deploy. Run on lab master."""
from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
DEFAULT_JENKINSFILE = REPO_ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy"

MINIMAL_GROOVY = """node('built-in') {
  stage('PaaS placeholder') {
    echo 'paas-deploy created — run full sync or replace script from Jenkinsfile.paas-deploy'
  }
}
"""


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key and key not in os.environ:
            os.environ[key] = val


def esc_xml(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_cdata(t: str) -> str:
    return t.replace("]]>", "]]]]><![CDATA[>")


def build_xml(groovy: str, minimal_params: bool) -> bytes:
    if minimal_params:
        params = [
            ("GIT_URL", ""),
            ("BRANCH", "main"),
            ("IMAGE_NAME", ""),
            ("PROJECT_ID", ""),
            ("JENKINS_AGENT_LABEL", "built-in"),
        ]
    else:
        params = [
            ("JENKINS_AGENT_LABEL", "built-in"),
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
    """On the VM host, cluster DNS (jenkins-service.cicd.svc...) does not resolve — use NodePort."""
    explicit = (
        os.environ.get("JENKINS_BASE_URL")
        or os.environ.get("JENKINS_URL")
        or ""
    ).strip()
    if explicit and ".svc.cluster.local" not in explicit:
        return explicit.rstrip("/")
    loopback = os.environ.get("JENKINS_LAB_LOOPBACK", "http://127.0.0.1:30090").strip()
    if explicit and ".svc.cluster.local" in explicit:
        print(
            f"Note: host-side script — using {loopback} (not in-cluster {explicit})",
            file=sys.stderr,
        )
    return loopback.rstrip("/")


def main() -> int:
    load_env_file(DEFAULT_ENV)
    base = lab_jenkins_base_url()
    user = os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or ""
    job = os.environ.get("JOB_NAME", "paas-deploy")
    minimal = "--minimal" in sys.argv
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

    client = JenkinsClient(base, user, token)
    code, _ = client.call("/api/json")
    print(f"GET /api/json -> {code}")
    if code != 200:
        return 1

    code, pm_body = client.call("/pluginManager/api/json?depth=1")
    if code == 200 and "workflow-job" not in pm_body:
        print(
            "ERROR: Pipeline plugins not installed (workflow-job missing).",
            file=sys.stderr,
        )
        print(
            "Run: bash paas/scripts/install-jenkins-plugins-lab.sh",
            file=sys.stderr,
        )
        return 1

    job_path = f"/job/{urllib.parse.quote(job)}/api/json"
    code, _ = client.call(job_path)
    if code == 200:
        print(f"Job '{job}' already exists: {base}/job/{job}/")
        return 0

    xml = build_xml(groovy, minimal_params=minimal)
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
