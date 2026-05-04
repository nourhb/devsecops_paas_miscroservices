"""
Create or update the Jenkins job `paas-deploy` (Pipeline + parameters) via REST API.

Embeds paas/jenkins/Jenkinsfile.paas-deploy as an **inline** scripted pipeline so Jenkins
does **not** clone Git to load the job definition (fixes "Error cloning remote repo 'origin'"
when the job was configured as Pipeline from SCM).

Uses the same JENKINS_* credentials as the PaaS Next.js app (see paas/frontend/.env).

Cluster admin password matches: kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
If the token in .env is a typo (e.g. missing leading characters), API calls return 401.
"""
from __future__ import annotations

import argparse
import base64
import html as html_module
import http.cookiejar
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_PIPELINE = ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy"
JOB_NAME = "paas-deploy"
PARAMETER_DEFINITIONS = [
    (
        "JENKINS_AGENT_LABEL",
        "built-in",
        "Agent label for Kubernetes Pod Template.",
    ),
    ("GIT_URL", "", "Repository clone URL"),
    ("BRANCH", "main", "Git branch"),
    ("IMAGE_NAME", "", "Image without tag (registry/project/app)"),
    ("PROJECT_ID", "", "PaaS project UUID"),
    ("GIT_CREDENTIALS_ID", "", "Jenkins credentialsId for private Git (omit for public)"),
    ("KANIKO_IMAGE", "gcr.io/kaniko-project/executor:debug", "Kaniko executor image"),
    (
        "DOCKER_REGISTRY_CREDENTIALS_ID",
        "harbor-docker",
        "Jenkins credentialsId for docker login when not using HARBOR_* + Kaniko",
    ),
    ("DOCKERFILE_PATH", "Dockerfile", "Dockerfile path relative to repo root"),
    ("DOCKER_BUILD_CONTEXT", ".", "Docker build context relative to repo root"),
    ("FALLBACK_IMAGE", "nginx:stable-alpine", "Image to deploy when Docker is unavailable on this Jenkins node"),
    ("DOCKERHUB_USERNAME", "", "Docker Hub username for dockerless crane pushes"),
    ("DOCKERHUB_TOKEN", "", "Docker Hub token for dockerless crane pushes"),
    ("HARBOR_REGISTRY", "", "Harbor registry host for dockerless crane pushes"),
    ("HARBOR_USERNAME", "", "Harbor username for dockerless crane pushes"),
    ("HARBOR_PASSWORD", "", "Harbor password for dockerless crane pushes"),
    ("SONAR_HOST_URL", "", "SonarQube URL for dockerless Sonar scanner"),
    ("SONAR_TOKEN", "", "SonarQube token for dockerless Sonar scanner"),
    ("DEPENDENCY_TRACK_BASE_URL", "", "Dependency-Track URL for SBOM upload"),
    ("DEPENDENCY_TRACK_API_KEY", "", "Dependency-Track API key for SBOM upload"),
    ("NVD_API_KEY", "", "Optional NVD API key for OWASP Dependency-Check"),
    (
        "ARTIFACTORY_URL",
        "",
        "Optional JFrog Artifactory base URL (e.g. https://host/artifactory) for build bundle upload",
    ),
    (
        "ARTIFACTORY_REPOSITORY",
        "libs-release-local",
        "Generic repository key in Artifactory for uploaded .tgz bundles",
    ),
    (
        "ARTIFACTORY_USERNAME",
        "",
        "Artifactory user (optional if ACCESS_TOKEN or ARTIFACTORY_CREDENTIALS_ID)",
    ),
    ("ARTIFACTORY_PASSWORD", "", "Artifactory password (optional)"),
    ("ARTIFACTORY_ACCESS_TOKEN", "", "Artifactory bearer token (optional)"),
    (
        "ARTIFACTORY_CREDENTIALS_ID",
        "",
        "Optional Jenkins username/password credential id for Artifactory (overrides ARTIFACTORY_* env on agent if set)",
    ),
    (
        "COSIGN_CREDENTIALS_ID",
        "",
        "Optional Jenkins secret file credential id (Cosign private key) for signing IMAGE:BUILD_NUMBER",
    ),
    (
        "HELM_OCI_PROJECT",
        "paas",
        "Harbor project name for OCI Helm charts (helm push oci://HARBOR_REGISTRY/PROJECT)",
    ),
    (
        "HELM_OCI_INSECURE",
        "false",
        "helm registry login --insecure (self-signed TLS)",
    ),
    (
        "HELM_OCI_PLAIN_HTTP",
        "false",
        "helm push --plain-http",
    ),
]


def parameter_property_xml(indent: str = "  ") -> str:
    param_indent = indent + "      "
    params = []
    for name, default, description in PARAMETER_DEFINITIONS:
        params.append(
            f"{param_indent}<hudson.model.StringParameterDefinition>\n"
            f"{param_indent}  <name>{html_module.escape(name)}</name>\n"
            f"{param_indent}  <description>{html_module.escape(description)}</description>\n"
            f"{param_indent}  <defaultValue>{html_module.escape(default)}</defaultValue>\n"
            f"{param_indent}  <trim>true</trim>\n"
            f"{param_indent}</hudson.model.StringParameterDefinition>"
        )
    return (
        f"{indent}<hudson.model.ParametersDefinitionProperty>\n"
        f"{indent}  <parameterDefinitions>\n"
        + "\n".join(params)
        + f"\n{indent}  </parameterDefinitions>\n"
        f"{indent}</hudson.model.ParametersDefinitionProperty>"
    )


def ensure_parameterized_job_xml(xml: str) -> str:
    """Ensure Jenkins accepts /buildWithParameters before the first run."""
    if "hudson.model.ParametersDefinitionProperty" in xml:
        return xml
    prop = parameter_property_xml("    ")
    if re.search(r"<properties\s*/>", xml):
        return re.sub(r"<properties\s*/>", f"<properties>\n{prop}\n  </properties>", xml, count=1)
    if "</properties>" in xml:
        return xml.replace("</properties>", f"{prop}\n  </properties>", 1)
    return xml.replace("<keepDependencies>false</keepDependencies>", "<keepDependencies>false</keepDependencies>\n  <properties>\n" + prop + "\n  </properties>", 1)


def escape_cdata(s: str) -> str:
    """Avoid breaking ]]></script><![CDATA[...]]> when embedding Groovy in XML CDATA."""
    return s.replace("]]>", "]]]]><![CDATA[>")


def build_job_config_xml(groovy_script: str) -> bytes:
    inner = escape_cdata(groovy_script)
    # XML 1.0 — some Jenkins/Java stacks mishandle 1.1 for config POST.
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Inline pipeline from Jenkinsfile.paas-deploy (no SCM). Updated by paas/scripts/jenkins_create_paas_deploy_job.py</description>
  <keepDependencies>false</keepDependencies>
  <properties>
{parameter_property_xml("    ")}
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[{inner}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
"""
    return ensure_parameterized_job_xml(xml).encode("utf-8")


# Jenkins-exported inline pipeline: Groovy inside CDATA under CpsFlowDefinition.
_CPS_FLOW_DEFINITION = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
_CDATA_SCRIPT_BLOCK = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(_CPS_FLOW_DEFINITION)}"[^>]*>\s*<script>\s*<!\[CDATA\[)([\s\S]*?)(\]\]>\s*</script>)',
    re.IGNORECASE,
)
# First top-level <definition>...</definition> (Pipeline-from-SCM uses CpsScmFlowDefinition — no CDATA script).
_DEFINITION_BLOCK = re.compile(r"<definition\b[^>]*>[\s\S]*?</definition>", re.DOTALL)


def _definition_xml_fragment(groovy_script: str) -> str:
    inner = escape_cdata(groovy_script)
    return (
        f'<definition class="{_CPS_FLOW_DEFINITION}" plugin="workflow-cps">\n'
        f"    <script><![CDATA[{inner}]]></script>\n"
        "    <sandbox>true</sandbox>\n"
        "  </definition>"
    )


def prepare_updated_job_config_xml(existing_xml: str | None, groovy_script: str) -> tuple[bytes, str]:
    """
    Build POST body while preserving Jenkins-side metadata when possible.

    1. Inline pipeline: replace only CDATA script (keeps plugin attrs on <definition>).
    2. Pipeline-from-SCM / other: replace the whole first <definition>...</definition> with inline CpsFlowDefinition.
    3. Fallback: minimal generated <flow-definition> document.

    Returns (xml_bytes, mode) where mode is merged-cdata | replaced-definition | full-document.
    """
    if not existing_xml or not existing_xml.strip():
        return build_job_config_xml(groovy_script), "full-document"

    existing_xml = existing_xml.lstrip("\ufeff")

    inner = escape_cdata(groovy_script)
    m = _CDATA_SCRIPT_BLOCK.search(existing_xml)
    if m:
        merged = existing_xml[: m.start(2)] + inner + existing_xml[m.end(2) :]
        return ensure_parameterized_job_xml(merged).encode("utf-8"), "merged-cdata"

    if "<flow-definition" in existing_xml:
        dm = _DEFINITION_BLOCK.search(existing_xml)
        if dm:
            merged = existing_xml[: dm.start()] + _definition_xml_fragment(groovy_script) + existing_xml[dm.end() :]
            return ensure_parameterized_job_xml(merged).encode("utf-8"), "replaced-definition"

    return build_job_config_xml(groovy_script), "full-document"


def validate_config_xml_wellformed(xml_bytes: bytes) -> None:
    """Raise ValueError if Jenkins config bytes are not parseable XML."""
    ET.fromstring(xml_bytes)


def extract_html_error_hint(body: str, max_len: int = 1200) -> str:
    """Pull a short hint from Jenkins HTML error pages (full stack is often in <pre>)."""
    for pattern in (
        r"<h1[^>]*>\s*([^<]+)",
        r'id="error-description"[^>]*>\s*([\s\S]*?)</div>',
        r"<pre[^>]*>\s*([\s\S]{0,2500}?)</pre>",
        r"<title>\s*([^<]+)",
    ):
        m = re.search(pattern, body, re.I | re.DOTALL)
        if m:
            text = html_module.unescape(re.sub(r"<[^>]+>", " ", m.group(1)))
            text = " ".join(text.split())
            if text:
                return text[:max_len]
    return ""


def resolve_env_file(explicit: pathlib.Path | None) -> pathlib.Path:
    if explicit is not None:
        return explicit.resolve()
    env_override = os.environ.get("PAAS_JENKINS_ENV_FILE", "").strip()
    if env_override:
        return pathlib.Path(env_override).expanduser().resolve()
    for candidate in (ROOT / "paas" / "frontend" / ".env", ROOT / "paas" / ".env"):
        if candidate.is_file():
            return candidate
    return ROOT / "paas" / "frontend" / ".env"


def load_env(env_path: pathlib.Path) -> dict[str, str]:
    text = env_path.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip("'").strip('"')
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Push inline paas-deploy Jenkins job - run once before PaaS deploy, again after Jenkinsfile.paas-deploy changes.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Prerequisite (standalone step before deploy from the PaaS UI):
  1. Fill JENKINS_BASE_URL, JENKINS_USERNAME, JENKINS_API_TOKEN (same as the Next.js app).
  2. Run this script from the repo root; exit code 0 means Jenkins has the latest pipeline.
  3. Then triggers from the app use job """ + JOB_NAME + """ with buildWithParameters.

Env file search order (unless --env-file or PAAS_JENKINS_ENV_FILE):
  paas/frontend/.env  then  paas/.env

Examples:
  python paas/scripts/jenkins_create_paas_deploy_job.py
  python paas/scripts/jenkins_create_paas_deploy_job.py --dry-run
  python paas/scripts/jenkins_create_paas_deploy_job.py --env-file paas/.env
""",
    )
    parser.add_argument(
        "--jenkinsfile",
        type=pathlib.Path,
        default=DEFAULT_PIPELINE,
        help=f"Path to declarative Jenkinsfile (default: {DEFAULT_PIPELINE})",
    )
    parser.add_argument("--job-name", default=JOB_NAME, help=f"Jenkins job name (default {JOB_NAME})")
    parser.add_argument(
        "--env-file",
        type=pathlib.Path,
        default=None,
        help="Env file with JENKINS_* (default: auto-detect paas/frontend/.env or paas/.env)",
    )
    parser.add_argument(
        "--write-xml",
        type=pathlib.Path,
        metavar="PATH",
        help="Also write generated config.xml to PATH (for debugging)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only generate XML (implies --write-xml default path); do not call Jenkins",
    )
    parser.add_argument(
        "--force-full-config",
        action="store_true",
        help="Always POST minimal generated config.xml (do not merge into existing job XML). "
        "Use if merge succeeds but you intentionally want a full replace.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print whether config was merged from GET config.xml and validation notes.",
    )
    args = parser.parse_args()

    env_file = resolve_env_file(args.env_file)

    jf = args.jenkinsfile.resolve()
    if not jf.is_file():
        print("Missing pipeline file:", jf, file=sys.stderr)
        return 1

    groovy = jf.read_text(encoding="utf-8").lstrip("\ufeff").replace("\r\n", "\n")
    xml_bytes = build_job_config_xml(groovy)

    out_path = args.write_xml
    if args.dry_run and out_path is None:
        out_path = ROOT / "paas" / "jenkins" / "paas-deploy-job.generated.xml"
    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(xml_bytes)
        print("Wrote", out_path)

    if args.dry_run:
        print("Dry run: Jenkins was not contacted.")
        print("Next: run without --dry-run when .env is ready, then deploy from PaaS.")
        return 0

    if not env_file.is_file():
        print(
            f"Missing env file: {env_file}\n"
            "Create paas/frontend/.env (or paas/.env) with JENKINS_BASE_URL, JENKINS_USERNAME, JENKINS_API_TOKEN,\n"
            "or pass --env-file PATH",
            file=sys.stderr,
        )
        return 1

    env = load_env(env_file)
    base = (env.get("JENKINS_BASE_URL") or env.get("JENKINS_URL") or "").rstrip("/")
    user = env.get("JENKINS_USERNAME") or env.get("JENKINS_USER") or ""
    token = env.get("JENKINS_API_TOKEN") or env.get("JENKINS_TOKEN") or ""
    if not base or not user or not token:
        print(
            f"Need JENKINS_BASE_URL, JENKINS_USERNAME, JENKINS_API_TOKEN in {env_file}\n"
            "(or JENKINS_URL / JENKINS_USER / JENKINS_TOKEN). Copy from paas/frontend/.env.example.",
            file=sys.stderr,
        )
        return 1

    print(f"Using env file: {env_file}")
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    base_headers: dict[str, str] = {"Authorization": f"Basic {auth}"}

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    def open_req(url: str, method: str = "GET", data: bytes | None = None, extra: dict[str, str] | None = None) -> tuple[int, str]:
        h = {**base_headers, **(extra or {})}
        r = urllib.request.Request(url, method=method, data=data, headers=h)
        try:
            resp = opener.open(r, timeout=120)
            return resp.status, resp.read().decode("utf-8", "ignore")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "ignore")

    code, crumb_body = open_req(f"{base}/crumbIssuer/api/json")
    post_headers: dict[str, str] = {}
    if code == 200:
        try:
            c = json.loads(crumb_body)
            field = c.get("crumbRequestField", "Jenkins-Crumb")
            if c.get("crumb"):
                post_headers[field] = c["crumb"]
        except json.JSONDecodeError:
            pass

    job_name = args.job_name.strip()
    code, _ = open_req(f"{base}/job/{job_name}/api/json")
    if code == 200:
        payload = xml_bytes
        update_mode = "full-document"
        update_mode = "full-document"
        if not args.force_full_config:
            gc, existing_body = open_req(f"{base}/job/{job_name}/config.xml", method="GET")
            if gc == 200 and existing_body.strip():
                payload, update_mode = prepare_updated_job_config_xml(existing_body, groovy)
                if args.verbose:
                    print(f"Config source: {update_mode} (from GET config.xml)", file=sys.stderr)
            elif args.verbose:
                print(f"GET config.xml HTTP {gc}: using full generated XML", file=sys.stderr)

        try:
            validate_config_xml_wellformed(payload)
        except ET.ParseError as e:
            print(f"Generated invalid XML: {e}", file=sys.stderr)
            return 1

        code2, body2 = open_req(
            f"{base}/job/{job_name}/config.xml",
            method="POST",
            data=payload,
            extra={**post_headers, "Content-Type": "application/xml; charset=UTF-8"},
        )
        if code2 in (200, 201):
            how = {
                "merged-cdata": "merged script into existing job XML",
                "replaced-definition": "replaced <definition> with inline pipeline (was SCM or non-CDATA)",
                "full-document": "replaced job config with generated flow-definition",
            }.get(update_mode, update_mode)
            print(
                f"Updated Jenkins job {job_name!r} at {base}/job/{job_name}/ (HTTP {code2}) — {how}; pipeline from {jf.name}"
            )
            print_ok_message(base, job_name)
            return 0
        hint = extract_html_error_hint(body2)
        print(f"Job exists but config update failed HTTP {code2}:", file=sys.stderr)
        if hint:
            print(f"Jenkins message (hint): {hint}", file=sys.stderr)
        print(body2[:4000], file=sys.stderr)
        print(
            "\nIf this was HTTP 500: open Jenkins → Manage Jenkins → System Log, or controller pod logs, "
            "for the Java stack trace. Common fixes: merge mode (default), Script Approval, "
            "or POST body limits on a reverse proxy.",
            file=sys.stderr,
        )
        return 1

    create_url = f"{base}/createItem?name={job_name}"
    code, body = open_req(
        create_url,
        method="POST",
        data=xml_bytes,
        extra={**post_headers, "Content-Type": "application/xml; charset=UTF-8"},
    )
    if code in (200, 201, 302):
        print(f"Created Jenkins job {job_name!r} at {base}/job/{job_name}/ (HTTP {code}) — inline pipeline from {jf.name}")
        print_ok_message(base, job_name)
        return 0
    if code == 401:
        print(
            "HTTP 401: Wrong password or API token. Compare with cluster secret:\n"
            "  kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d",
            file=sys.stderr,
        )
    print(f"Failed HTTP {code}:\n{body[:6000]}", file=sys.stderr)
    return 1


def print_ok_message(base: str, job_name: str) -> None:
    print("")
    print("--- OK: Jenkins is aligned with Jenkinsfile.paas-deploy ---")
    print("You can deploy from the PaaS app now (same JENKINS_* as this script).")
    print(f"Re-run this script after any edit to paas/jenkins/Jenkinsfile.paas-deploy")
    print(f"Job URL: {base}/job/{job_name}/")


if __name__ == "__main__":
    raise SystemExit(main())
