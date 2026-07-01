#!/usr/bin/env python3
"""Create paas-deploy Jenkins job via REST (no Jenkinsfile assertions). Verbose for lab debugging."""
from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from jenkins_merge_cps_wrapper import build_wrapper  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parents[2]
ENV_FILE = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
JOB_NAME = os.environ.get("JENKINS_JOB_NAME", "paas-deploy")


def log(msg: str) -> None:
    print(msg, flush=True)


def load_env() -> None:
    if not ENV_FILE.is_file():
        return
    for line in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        if k and k not in os.environ:
            os.environ[k] = v.strip().strip('"')
    if not os.environ.get("JENKINS_USERNAME") and os.environ.get("JENKINS_USER"):
        os.environ["JENKINS_USERNAME"] = os.environ["JENKINS_USER"]
    if not os.environ.get("JENKINS_API_TOKEN") and os.environ.get("JENKINS_TOKEN"):
        os.environ["JENKINS_API_TOKEN"] = os.environ["JENKINS_TOKEN"]


def base_url() -> str:
    for key in ("JENKINS_PROBE_URL", "JENKINS_BASE_URL", "JENKINS_URL"):
        v = (os.environ.get(key) or "").strip().rstrip("/")
        if v:
            return v
    return "http://192.168.56.129:30090"


def esc_xml(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_cdata(t: str) -> str:
    return t.replace("]]>", "]]]]><![CDATA[>")


def build_job_xml(groovy: str) -> bytes:
    params = [
        ("GIT_URL", ""),
        ("BRANCH", "main"),
        ("IMAGE_NAME", ""),
        ("PROJECT_ID", ""),
        ("JENKINS_AGENT_LABEL", ""),
        ("SONAR_HOST_URL", os.environ.get("SONAR_BASE_URL", "")),
        ("SONAR_TOKEN", os.environ.get("SONAR_TOKEN", "")),
        ("HARBOR_REGISTRY", os.environ.get("HARBOR_REGISTRY", "")),
        ("HARBOR_USERNAME", os.environ.get("HARBOR_USERNAME", "")),
        ("HARBOR_PASSWORD", os.environ.get("HARBOR_PASSWORD", "")),
    ]
    pxml = "\n".join(
        f'      <hudson.model.StringParameterDefinition>'
        f'<name>{esc_xml(n)}</name><description></description>'
        f'<defaultValue>{esc_xml(d)}</defaultValue><trim>true</trim>'
        f"</hudson.model.StringParameterDefinition>"
        for n, d in params
    )
    inner = esc_cdata(groovy)
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<flow-definition plugin="workflow-job">\n'
        "  <description>paas-deploy (create-paas-deploy-job-api.py)</description>\n"
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


class Client:
    def __init__(self, base: str, user: str, token: str) -> None:
        self.base = base.rstrip("/")
        auth = base64.b64encode(f"{user}:{token}".encode()).decode()
        self.headers = {"Authorization": f"Basic {auth}"}
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(
        self,
        path: str,
        method: str = "GET",
        data: bytes | None = None,
        content_type: str = "application/xml; charset=UTF-8",
    ) -> tuple[int, str]:
        h = dict(self.headers)
        if data is not None:
            h["Content-Type"] = content_type
        req = urllib.request.Request(f"{self.base}{path}", data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=120) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def crumb(self) -> dict[str, str]:
        code, body = self.call("/crumbIssuer/api/json")
        if code != 200:
            return {}
        j = json.loads(body)
        return {j["crumbRequestField"]: j["crumb"]}


PIPELINE_PLUGIN_MARKERS = ("workflow-job", "workflow-cps")
PIPELINE_PLUGINS_INSTALL = (
    "workflow-aggregator",
    "git",
    "credentials-binding",
    "pipeline-utility-steps",
    "timestamper",
)


def pipeline_plugins_ready(client: Client) -> bool:
    code, body = client.call("/pluginManager/api/json?depth=1")
    if code != 200:
        return False
    active = {p.get("shortName") for p in json.loads(body).get("plugins", []) if p.get("active")}
    return all(p in active for p in PIPELINE_PLUGIN_MARKERS)


def install_pipeline_plugins(client: Client) -> bool:
    if pipeline_plugins_ready(client):
        log("Pipeline plugins already active (workflow-job, workflow-cps)")
        return True

    log("Installing workflow-aggregator (+ git, credentials-binding) via pluginManager API…")
    xml = "<jenkins>" + "".join(f'<install plugin="{p}@latest" />' for p in PIPELINE_PLUGINS_INSTALL) + "</jenkins>"
    extra = client.crumb()
    h = dict(client.headers)
    h["Content-Type"] = "text/xml; charset=UTF-8"
    h.update(extra)
    req = urllib.request.Request(
        f"{client.base}/pluginManager/installNecessaryPlugins",
        data=xml.encode("utf-8"),
        method="POST",
        headers=h,
    )
    try:
        with client.opener.open(req, timeout=300) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
        log(e.read().decode("utf-8", "replace")[:1500])
    log(f"POST installNecessaryPlugins -> {code}")
    if code not in (200, 201, 302):
        return False

    deadline = time.time() + 900
    while time.time() < deadline:
        if pipeline_plugins_ready(client):
            log("Pipeline plugins active")
            break
        time.sleep(10)
    else:
        log("ERROR: timeout waiting for workflow plugins")
        return False

    extra = client.crumb()
    h = dict(client.headers)
    h["Content-Type"] = "application/x-www-form-urlencoded"
    h.update(extra)
    req = urllib.request.Request(
        f"{client.base}/safeRestart",
        data=b"",
        method="POST",
        headers=h,
    )
    try:
        with client.opener.open(req, timeout=60) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
    log(f"POST safeRestart -> {code}")
    for n in range(60):
        time.sleep(10)
        api_code, _ = client.call("/api/json")
        if api_code == 200 and pipeline_plugins_ready(client):
            log(f"Jenkins API ready after plugin restart ({(n + 1) * 10}s)")
            return True
    log("ERROR: Jenkins did not come back with pipeline plugins")
    return False


def ensure_pipeline_plugins(client: Client) -> bool:
    if pipeline_plugins_ready(client):
        return True
    return install_pipeline_plugins(client)


def create_or_update_job(client: Client, groovy: str) -> tuple[int, str]:
    job_path = f"/job/{urllib.parse.quote(JOB_NAME)}"
    xml = build_job_xml(groovy)
    extra = client.crumb()

    code, _ = client.call(f"{job_path}/api/json")
    if code == 200:
        log("Job exists — POST config.xml")
        h = dict(client.headers)
        h["Content-Type"] = "application/xml; charset=UTF-8"
        h.update(extra)
        req = urllib.request.Request(
            f"{client.base}{job_path}/config.xml",
            data=xml,
            method="POST",
            headers=h,
        )
        try:
            with client.opener.open(req, timeout=120) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    log(f"Creating job {JOB_NAME!r}")
    h = dict(client.headers)
    h["Content-Type"] = "application/xml; charset=UTF-8"
    h.update(extra)
    req = urllib.request.Request(
        f"{client.base}/createItem?name={urllib.parse.quote(JOB_NAME)}",
        data=xml,
        method="POST",
        headers=h,
    )
    try:
        with client.opener.open(req, timeout=120) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main() -> int:
    log("create-paas-deploy-job-api.py starting")
    load_env()
    base = base_url()
    user = (os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or "").strip()
    token = (os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or "").strip()
    log(f"Jenkins URL: {base}")
    log(f"User: {user!r} token_len={len(token)}")
    if not user or not token:
        log("ERROR: export JENKINS_USERNAME and JENKINS_API_TOKEN")
        return 1

    client = Client(base, user, token)
    code, _ = client.call("/api/json")
    log(f"GET /api/json -> {code}")
    if code != 200:
        return 1

    job_path = f"/job/{urllib.parse.quote(JOB_NAME)}"
    code, _ = client.call(f"{job_path}/api/json")
    log(f"GET {job_path}/api/json -> {code}")

    if not ensure_pipeline_plugins(client):
        log("ERROR: workflow plugins missing — open Jenkins → Manage Plugins → workflow-aggregator")
        return 1

    groovy = build_wrapper()
    log(f"Job XML size: {len(build_job_xml(groovy))} bytes")

    extra = client.crumb()
    if extra:
        log(f"Crumb: {list(extra.keys())[0]}")

    ccode, cbody = create_or_update_job(client, groovy)
    log(f"POST create/update -> {ccode}")
    if ccode not in (200, 201, 302) and ccode == 500:
        log("HTTP 500 — retrying after pipeline plugin install")
        if install_pipeline_plugins(client):
            ccode, cbody = create_or_update_job(client, groovy)
            log(f"POST create/update (retry) -> {ccode}")
    if ccode not in (200, 201, 302):
        log(cbody[:2000])
        if ccode == 500:
            log("If HTTP 500 persists: open Jenkins plugin manager and install workflow-aggregator manually")
        return 1

    vcode, _ = client.call(f"{job_path}/api/json")
    log(f"Verify {job_path}/api/json -> {vcode}")
    if vcode == 200:
        log(f"OK: {base}{job_path}/")
        return 0
    log("FAIL: job not visible after create")
    return 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--plugins-only":
        load_env()
        base = base_url()
        user = (os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or "").strip()
        token = (os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or "").strip()
        if not user or not token:
            raise SystemExit("export JENKINS_USERNAME and JENKINS_API_TOKEN")
        client = Client(base, user, token)
        raise SystemExit(0 if ensure_pipeline_plugins(client) else 1)
    raise SystemExit(main())
