#!/usr/bin/env python3
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
REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
DEFAULT_JENKINSFILE = REPO_ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy"
DEFAULT_JENKINSFILE_STAGES = REPO_ROOT / "paas" / "jenkins" / "Jenkinsfile.paas-deploy-stages.groovy"
JENKINS_STAGES_REMOTE_PATH = "/var/jenkins_home/paas/paas-deploy-stages.groovy"
DT_STAGES_MARKER = "dt-api-server-svc-20260617"
PAAS_DEPLOY_STAGES_LOAD_MARKER = "paas-deploy-stages-load-20260617"
PAAS_BLUEOCEAN_CLOSURES_MARKER = "paas-blueocean-12closures-20260619"
PAAS_DEPLOY_STAGE_SPECS: list[tuple[int, str]] = [
    (1, "Params validation"),
    (2, "Checkout du code (Git / GitHub)"),
    (3, "Construction de l'application"),
    (4, "Tests SCA (Dependency-Check, CycloneDX, Dependency-Track)"),
    (5, "Tests SAST (SonarQube)"),
    (6, "Création de l'image Docker"),
    (7, "Packaging du chart Helm"),
    (8, "Publication des artefacts (Artifactory)"),
    (9, "Signature de l'image (Cosign)"),
    (10, "DAST (OWASP ZAP baseline)"),
    (11, "Publication charts Helm (OCI → Harbor)"),
    (12, "GitOps (Argo CD) & archivage Jenkins"),
]
TWELVE_STEPS_MARKER = "steps-1-2-3-4-5-6-7-8-9-10-11-12-202602"
LAB_JENKINSFILE_STAGING = Path("/tmp/Jenkinsfile.paas-deploy")
CRANE_MARKERS = (
    "crane-next16-202605-j48300-split",
    "crane-next16-202605-j48300",
    "crane-next16-202605",
)
STALE_CRANE_RE = "version.split('.').map(Number);process.exit((v[0]||0)>=16"
MUTATE_FIX_MARKERS = (
    "monorepo-app-root-20260531",
    "entrypoint=/app/start-paas.sh",
    "[image] crane mutate OK",
)
ENV_SAFE_DOTENV_LOADER_MARKER = "env-safe-dotenv-loader-20260601"
COSIGN_DIGEST_MARKER = "cosign-digest-crane-bin-20260602"
SONAR_STEP5_MARKER = "paas-artifacts/sonar-scanner.log"
SONAR_LOGIN_MARKER = "sonar.login"
SONAR_LOGIN_JENKINSFILE_MARKER = "sonar-scanner-cli6-login-20260607"
MULTI_FRAMEWORK_MARKERS = (
    "multi-framework-20260611",
    "multi-framework-20260610",
)
NGINX_CONF_WRITEFILE_MARKER = "nginx-conf-writefile-20260611"
SCA_FULL_INSTALL_MARKER = "sca-npm-install-full-20260611"
OLD_COSIGN_STEP9_SNIPPET = "digest ref unavailable (crane/triangulate); tag sign only"
BROKEN_MUTATE_SNIPPET = "--cmd=-c"
def read_jenkinsfile_bundle(main_path: Path) -> tuple[str, str, str]:
    main = main_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    return main, "", main
def assert_jenkinsfile_twelve_steps(groovy_bundle: str, jenkinsfile_path: Path) -> None:
    if TWELVE_STEPS_MARKER not in groovy_bundle:
        print(
            f"ERROR: Jenkinsfile bundle missing {TWELVE_STEPS_MARKER}.\n"
            "  git pull origin main",
            file=sys.stderr,
        )
        sys.exit(1)
    for step in range(1, 13):
        token = f'stage("Step {step} —'
        if token not in groovy_bundle:
            print(
                f"ERROR: missing {token} in Jenkinsfile ({jenkinsfile_path}).\n"
                "  git pull && bash paas/scripts/lab.sh jenkins",
                file=sys.stderr,
            )
            sys.exit(1)
def verify_job_script_markers(cfg_xml: str) -> bool:
    if "load paasDeployStagesPath" in cfg_xml or PAAS_DEPLOY_STAGES_LOAD_MARKER in cfg_xml:
        return True
    if "def runPaasDeploy" not in cfg_xml:
        return False
    if NGINX_CONF_WRITEFILE_MARKER not in cfg_xml or "writeNginxPaasDefaultConf" not in cfg_xml:
        return False
    if SCA_FULL_INSTALL_MARKER not in cfg_xml:
        return False
    if "full npm install then cyclonedx-npm" not in cfg_xml:
        return False
    return True
def build_node_body() -> str:
    stage_lines = "\n".join(
        f'  stage("Step {num} — {title}") {{ paas.runPaasStep{num:02d}() }}'
        for num, title in PAAS_DEPLOY_STAGE_SPECS
    )
    return f"""  if (!fileExists(paasDeployStagesPath)) {{
    error("Missing ${{paasDeployStagesPath}} — run: bash paas/scripts/lab.sh jenkins")
  }}
  def stagesText = readFile(paasDeployStagesPath)
  if (!stagesText.contains('{PAAS_BLUEOCEAN_CLOSURES_MARKER}') || !stagesText.contains('def runPaasStep12 = {{')) {{
    error("Stale ${{paasDeployStagesPath}} (missing {PAAS_BLUEOCEAN_CLOSURES_MARKER}) — run: bash paas/scripts/lab.sh jenkins-stages")
  }}
  if (!stagesText.contains('return this')) {{
    error("Stale ${{paasDeployStagesPath}} (missing return this) — run: bash paas/scripts/lab.sh jenkins-stages")
  }}
  if (!stagesText.contains('{DT_STAGES_MARKER}')) {{
    error("Stale ${{paasDeployStagesPath}} (missing {DT_STAGES_MARKER}) — run: bash paas/scripts/lab.sh jenkins")
  }}
  def paas = load paasDeployStagesPath
  paas.paasDeployInit()
{stage_lines}"""


def build_load_wrapper() -> str:
    body = build_node_body()
    return f"""def paasDeployStagesPath = '{JENKINS_STAGES_REMOTE_PATH}'
println '[paas-jenkinsfile] marker={PAAS_DEPLOY_STAGES_LOAD_MARKER} ({PAAS_BLUEOCEAN_CLOSURES_MARKER} — 12 Blue Ocean stages via closures)'
def agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
if (!agentLabel || agentLabel == 'built-in') {{
  println "[paas] node: default Built-In Node (agentLabel=${{agentLabel ?: 'empty'}})"
  node {{
{body}
  }}
}} else {{
  println "[paas] node: agentLabel=${{agentLabel}}"
  node(agentLabel) {{
{body}
  }}
}}
"""
def assert_jenkinsfile_crane_fix(groovy: str, path: Path) -> None:
    if not any(m in groovy for m in CRANE_MARKERS):
        print(
            f"ERROR: {path} missing one of {CRANE_MARKERS} (Step 6 still breaks Next.js 16 with --no-lint).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
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
def assert_jenkinsfile_env_loader_fix(groovy: str, path: Path) -> None:
    if ENV_SAFE_DOTENV_LOADER_MARKER not in groovy:
        print(
            f"ERROR: {path} missing {ENV_SAFE_DOTENV_LOADER_MARKER} "
            "(build fails when EMAIL_PASS has spaces — old . ./.env loader).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if '. ./.env' in groovy and 'Do not use ". ./.env"' not in groovy:
        print(
            f"ERROR: {path} still sources . ./.env directly.\n"
            "  git pull and re-sync Jenkins job",
            file=sys.stderr,
        )
        sys.exit(1)
def assert_jenkinsfile_cosign_digest_fix(groovy: str, path: Path) -> None:
    if COSIGN_DIGEST_MARKER not in groovy:
        print(
            f"ERROR: {path} missing {COSIGN_DIGEST_MARKER} "
            "(Step 9 must sign digest for Kyverno).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if OLD_COSIGN_STEP9_SNIPPET in groovy and "cosignSignImageShellSnippet" not in groovy:
        print(
            f"ERROR: {path} still has OLD tag-only cosign Step 9.\n"
            "  git pull origin main",
            file=sys.stderr,
        )
        sys.exit(1)
def assert_jenkinsfile_sonar_step5_fix(groovy: str, path: Path) -> None:
    if SONAR_STEP5_MARKER not in groovy:
        print(
            f"ERROR: {path} missing {SONAR_STEP5_MARKER} "
            "(Step 5 needs JAVA_HOME + returnStatus + scanner log).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if "LOG=/tmp/sonar-scanner" in groovy:
        print(
            f"ERROR: {path} still uses /tmp sonar log + returnStdout pattern.\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if SONAR_LOGIN_MARKER not in groovy or SONAR_LOGIN_JENKINSFILE_MARKER not in groovy:
        print(
            f"ERROR: {path} missing SonarScanner CLI 6 auth ({SONAR_LOGIN_MARKER} / {SONAR_LOGIN_JENKINSFILE_MARKER}).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
def assert_jenkinsfile_nginx_conf_fix(groovy: str, path: Path) -> None:
    if NGINX_CONF_WRITEFILE_MARKER not in groovy:
        print(
            f"ERROR: {path} missing {NGINX_CONF_WRITEFILE_MARKER} "
            "(SPA/Angular Step 6 fails: MissingPropertyException: uri in Groovy GString).\n"
            "  git pull\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if "writeNginxPaasDefaultConf" not in groovy:
        print(
            f"ERROR: {path} missing writeNginxPaasDefaultConf helper.\n"
            "  git pull and re-sync Jenkins job",
            file=sys.stderr,
        )
        sys.exit(1)
def assert_jenkinsfile_multi_framework_fix(groovy: str, path: Path) -> None:
    if not any(m in groovy for m in MULTI_FRAMEWORK_MARKERS):
        print(
            f"ERROR: {path} missing one of {MULTI_FRAMEWORK_MARKERS} "
            "(legacy Angular/Python need Node16 defer Step3 + crane runtime stack).\n"
            "  git pull\n"
            "  python3 paas/scripts/lib/create_jenkins_paas_deploy_job.py --force --force-full",
            file=sys.stderr,
        )
        sys.exit(1)
    if "shouldDeferAngularBuildToStep6" not in groovy or "resolveCraneRuntimeStack" not in groovy:
        print(
            f"ERROR: {path} has multi-framework marker but missing defer/crane helpers.\n"
            "  git pull and re-sync Jenkins job",
            file=sys.stderr,
        )
        sys.exit(1)
def assert_jenkinsfile_mutate_fix(groovy: str, path: Path) -> None:
    if BROKEN_MUTATE_SNIPPET in groovy and 'require("./package.json")' in groovy:
        print(
            f"ERROR: {path} still has broken crane mutate (--cmd=-c with nested quotes).\n"
            "  git pull origin main\n"
            "  bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        sys.exit(1)
    if "mutate runs as a separate pipeline sh step" in groovy:
        print(
            f"ERROR: {path} has obsolete split Step 6 mutate (monorepo paths break).\n"
            "  git pull origin main",
            file=sys.stderr,
        )
        sys.exit(1)
    if not any(m in groovy for m in MUTATE_FIX_MARKERS):
        print(
            f"ERROR: {path} missing Step 6 mutate fix ({', '.join(MUTATE_FIX_MARKERS[:2])}).\n"
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
_HOST_ENV_SKIP = frozenset({"JENKINS_BASE_URL", "JENKINS_URL", "JENKINS_PROBE_URL"})
def parse_compose_env_value(raw: str) -> str:
    val = raw.strip()
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        inner = val[1:-1]
        return inner.replace("\\\\", "\\").replace("\\n", "\n").replace("\\$", "$")
    return val
def read_compose_env_value(key: str, path: Path = DEFAULT_ENV) -> str:
    if not path.is_file():
        return ""
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, val = line.partition("=")
        if k.strip() == key:
            return parse_compose_env_value(val)
    return ""
def load_env_file(path: Path, *, skip_keys: frozenset[str] = _HOST_ENV_SKIP) -> None:
    if not path.is_file():
        return
    parsed: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if not key or key in skip_keys:
            continue
        parsed[key] = parse_compose_env_value(val)
    for key, val in parsed.items():
        if key not in os.environ:
            os.environ[key] = val
    if not os.environ.get("JENKINS_USERNAME") and parsed.get("JENKINS_USER"):
        os.environ["JENKINS_USERNAME"] = parsed["JENKINS_USER"]
    if not os.environ.get("JENKINS_API_TOKEN") and parsed.get("JENKINS_TOKEN"):
        os.environ["JENKINS_API_TOKEN"] = parsed["JENKINS_TOKEN"]
def esc_xml(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
def esc_cdata(t: str) -> str:
    return t.replace("]]>", "]]]]><![CDATA[>")
FORCE_ENV_PARAM_DEFAULTS: frozenset[str] = frozenset(
    {
        "SONAR_HOST_URL",
        "SONAR_TOKEN",
        "DEPENDENCY_TRACK_BASE_URL",
        "DEPENDENCY_TRACK_API_KEY",
        "JENKINS_DEPENDENCY_TRACK_BASE_URL",
    }
)
ENV_PARAM_DEFAULTS: dict[str, str] = {
    "HARBOR_REGISTRY": "HARBOR_REGISTRY",
    "HARBOR_REGISTRY_PUSH": "HARBOR_REGISTRY_PUSH",
    "HARBOR_FORCE_NODEPORT_PUSH": "HARBOR_FORCE_NODEPORT_PUSH",
    "HARBOR_REGISTRY_NGINX_CLUSTER": "HARBOR_REGISTRY_NGINX_CLUSTER",
    "HARBOR_USERNAME": "HARBOR_USERNAME",
    "HARBOR_PASSWORD": "HARBOR_PASSWORD",
    "DOCKERHUB_USERNAME": "DOCKERHUB_USERNAME",
    "DOCKERHUB_TOKEN": "DOCKERHUB_TOKEN",
    "SONAR_HOST_URL": "SONAR_BASE_URL",
    "SONAR_TOKEN": "SONAR_TOKEN",
    "DEPENDENCY_TRACK_BASE_URL": "DEPENDENCY_TRACK_BASE_URL",
    "DEPENDENCY_TRACK_API_KEY": "DEPENDENCY_TRACK_API_KEY",
    "JENKINS_DEPENDENCY_TRACK_BASE_URL": "JENKINS_DEPENDENCY_TRACK_BASE_URL",
    "NVD_API_KEY": "NVD_API_KEY",
    "ZAP_TARGET_URL": "ZAP_TARGET_URL",
    "BUILD_PACKAGE_PROXY_URL": "BUILD_PACKAGE_PROXY_URL",
    "NPM_CONFIG_REGISTRY": "BUILD_NPM_REGISTRY",
    "COSIGN_PRIVATE_KEY": "COSIGN_PRIVATE_KEY",
    "COSIGN_PASSWORD": "COSIGN_PASSWORD",
    "HELM_OCI_PROJECT": "HELM_OCI_PROJECT",
}
FULL_PARAMETER_DEFINITIONS: list[tuple[str, str]] = [
    ("JENKINS_AGENT_LABEL", ""),
    ("GIT_URL", ""),
    ("BRANCH", "main"),
    ("IMAGE_NAME", ""),
    ("PROJECT_ID", ""),
    ("GIT_CREDENTIALS_ID", ""),
    ("KANIKO_IMAGE", "gcr.io/kaniko-project/executor:debug"),
    ("DOCKER_REGISTRY_CREDENTIALS_ID", "harbor-docker"),
    ("DOCKERFILE_PATH", "Dockerfile"),
    ("DOCKER_BUILD_CONTEXT", "."),
    ("FALLBACK_IMAGE", "nginx:stable-alpine"),
    ("DOCKERHUB_USERNAME", ""),
    ("DOCKERHUB_TOKEN", ""),
    ("HARBOR_REGISTRY", ""),
    ("HARBOR_REGISTRY_PUSH", ""),
    ("HARBOR_FORCE_NODEPORT_PUSH", "true"),
    ("HARBOR_REGISTRY_NGINX_CLUSTER", ""),
    ("HARBOR_USERNAME", ""),
    ("HARBOR_PASSWORD", ""),
    ("SONAR_HOST_URL", ""),
    ("SONAR_TOKEN", ""),
    ("DEPENDENCY_TRACK_BASE_URL", ""),
    ("DEPENDENCY_TRACK_API_KEY", ""),
    ("JENKINS_DEPENDENCY_TRACK_BASE_URL", ""),
    ("NVD_API_KEY", ""),
    ("ZAP_TARGET_URL", ""),
    ("BUILD_PACKAGE_PROXY_URL", ""),
    ("NPM_CONFIG_REGISTRY", ""),
    ("JENKINS_PAAS_NODE_CACHE", ""),
    ("JENKINS_PAAS_NPM_CACHE", ""),
    ("JENKINS_SH_KEEPALIVE", "true"),
    ("JENKINS_PAAS_FAST_PIPELINE", "false"),
    ("PROJECT_BUILD_ENV_B64", ""),
    ("JENKINS_NEXT_BUILD_WEBPACK", "false"),
    ("JENKINS_NEXT_PERSIST_CACHE", "true"),
    ("JENKINS_NEXT_BUILD_HEARTBEAT", "true"),
    ("JENKINS_NEXT_BUILD_HEARTBEAT_SEC", "45"),
    ("JENKINS_NPM_PRUNE_BEFORE_CRANE", "true"),
    ("JENKINS_CRANE_STANDALONE_LAYER", "auto"),
    ("ARTIFACTORY_URL", ""),
    ("ARTIFACTORY_REPOSITORY", "libs-release-local"),
    ("ARTIFACTORY_USERNAME", ""),
    ("ARTIFACTORY_PASSWORD", ""),
    ("ARTIFACTORY_ACCESS_TOKEN", ""),
    ("ARTIFACTORY_CREDENTIALS_ID", ""),
    ("COSIGN_CREDENTIALS_ID", ""),
    ("COSIGN_PRIVATE_KEY", ""),
    ("COSIGN_PASSWORD", ""),
    ("COSIGN_ALLOW_INSECURE_REGISTRY", "true"),
    ("HELM_OCI_PROJECT", "paas"),
    ("HELM_OCI_INSECURE", "false"),
    ("HELM_OCI_PLAIN_HTTP", "false"),
]
def resolve_param_default(name: str, fallback: str) -> str:
    env_key = ENV_PARAM_DEFAULTS.get(name, name)
    val = (os.environ.get(env_key) or os.environ.get(name) or "").strip()
    if not val:
        return fallback
    if "\n" in val:
        return val.replace("\\", "\\\\").replace("\n", "\\n")
    return val
def param_block_xml(name: str, default_value: str, indent: str = "      ") -> str:
    return (
        f"{indent}<hudson.model.StringParameterDefinition>"
        f"<name>{esc_xml(name)}</name>"
        f"<description></description>"
        f"<defaultValue>{esc_xml(default_value)}</defaultValue>"
        f"<trim>true</trim>"
        f"</hudson.model.StringParameterDefinition>"
    )
def job_defines_string_parameter(xml: str, name: str) -> bool:
    token = f"<name>{esc_xml(name)}</name>"
    return token in xml
def merge_missing_parameter_definitions(existing_xml: str) -> str:
    if "hudson.model.ParametersDefinitionProperty" not in existing_xml:
        blocks = "\n".join(
            param_block_xml(n, resolve_param_default(n, d), "        ")
            for n, d in FULL_PARAMETER_DEFINITIONS
        )
        prop = (
            "    <hudson.model.ParametersDefinitionProperty>\n"
            "      <parameterDefinitions>\n"
            f"{blocks}\n"
            "      </parameterDefinitions>\n"
            "    </hudson.model.ParametersDefinitionProperty>"
        )
        if re.search(r"<properties\s*/>", existing_xml):
            print(f"Adding ParametersDefinitionProperty with {len(FULL_PARAMETER_DEFINITIONS)} parameter(s)")
            return re.sub(r"<properties\s*/>", f"<properties>\n{prop}\n  </properties>", existing_xml, count=1)
        if "</properties>" in existing_xml:
            print(f"Adding ParametersDefinitionProperty with {len(FULL_PARAMETER_DEFINITIONS)} parameter(s)")
            return existing_xml.replace("</properties>", f"{prop}\n  </properties>", 1)
        print("WARN: job config has no <properties> block — cannot inject parameters automatically")
        return existing_xml
    close_re = re.compile(r"\n([\t ]*)</parameterDefinitions>")
    m = close_re.search(existing_xml)
    if not m:
        return existing_xml
    param_indent = f"{m.group(1)}  "
    missing = [
        (n, resolve_param_default(n, d))
        for n, d in FULL_PARAMETER_DEFINITIONS
        if not job_defines_string_parameter(existing_xml, n)
    ]
    if not missing:
        return existing_xml
    blocks = "\n".join(param_block_xml(n, d, param_indent) for n, d in missing)
    print(f"Adding {len(missing)} missing job parameter(s): {', '.join(n for n, _ in missing[:8])}{'…' if len(missing) > 8 else ''}")
    return existing_xml[: m.start()] + f"\n{blocks}\n{m.group(1)}</parameterDefinitions>" + existing_xml[m.end() :]
def force_job_parameter_default(existing_xml: str, param_name: str, value: str) -> str:
    name_token = f"<name>{esc_xml(param_name)}</name>"
    pattern = re.compile(
        rf"(<hudson\.model\.StringParameterDefinition>[\s\S]*?{re.escape(name_token)}[\s\S]*?"
        rf"<defaultValue>)([\s\S]*?)(</defaultValue>)",
        re.IGNORECASE,
    )
    m = pattern.search(existing_xml)
    if not m:
        return existing_xml
    current = m.group(2).strip()
    if current == esc_xml(value):
        return existing_xml
    return existing_xml[: m.start(2)] + esc_xml(value) + existing_xml[m.end(2) :]
def ensure_job_parameters(existing_xml: str) -> str:
    out = merge_missing_parameter_definitions(existing_xml)
    out = merge_env_param_defaults(out)
    out = force_job_parameter_default(out, "JENKINS_PAAS_FAST_PIPELINE", "false")
    if concurrent_builds_enabled():
        out = strip_disable_concurrent_builds(out)
    return out
def merge_env_param_defaults(existing_xml: str) -> str:
    out = existing_xml
    for param_name, env_key in ENV_PARAM_DEFAULTS.items():
        val = (os.environ.get(env_key) or os.environ.get(param_name) or "").strip()
        if not val:
            continue
        name_token = f"<name>{esc_xml(param_name)}</name>"
        pattern = re.compile(
            rf"(<hudson\.model\.StringParameterDefinition>[\s\S]*?{re.escape(name_token)}[\s\S]*?"
            rf"<defaultValue>)([\s\S]*?)(</defaultValue>)",
            re.IGNORECASE,
        )
        m = pattern.search(out)
        if not m:
            continue
        current = m.group(2).strip()
        if current:
            continue
        out = out[: m.start(2)] + esc_xml(val) + out[m.end(2) :]
    return out
def merge_env_param_defaults_force(
    existing_xml: str,
    force_names: frozenset[str] | None = None,
) -> str:
    out = existing_xml
    for param_name in force_names or FORCE_ENV_PARAM_DEFAULTS:
        env_key = ENV_PARAM_DEFAULTS.get(param_name, param_name)
        val = (os.environ.get(env_key) or os.environ.get(param_name) or "").strip()
        if not val and param_name == "JENKINS_DEPENDENCY_TRACK_BASE_URL":
            val = "http://dtrack-dependency-track-api-server.dependency-track.svc.cluster.local:8080"
        if not val:
            continue
        out = force_job_parameter_default(out, param_name, val)
    return out
def resolve_jenkinsfile_path() -> Path:
    explicit = (os.environ.get("JENKINSFILE") or "").strip()
    if explicit:
        return Path(explicit)
    if LAB_JENKINSFILE_STAGING.is_file():
        text = LAB_JENKINSFILE_STAGING.read_text(encoding="utf-8")
        if NGINX_CONF_WRITEFILE_MARKER in text:
            print(
                f"NOTE: using staged Jenkinsfile {LAB_JENKINSFILE_STAGING} "
                f"({len(text)} bytes, has {NGINX_CONF_WRITEFILE_MARKER})"
            )
            return LAB_JENKINSFILE_STAGING
    return DEFAULT_JENKINSFILE
def refuse_stale_groovy_overwrite(existing_xml: str, groovy: str) -> None:
    if not existing_xml.strip():
        return
    for marker in (
        NGINX_CONF_WRITEFILE_MARKER,
        SCA_FULL_INSTALL_MARKER,
        "sca-sanitize-package-name-20260612",
    ):
        if marker in existing_xml and marker not in groovy:
            print(
                f"ERROR: refusing to overwrite Jenkins job — source Jenkinsfile is STALE "
                f"(job has {marker!r}, file does not).\n"
                "  JENKINSFILE=/tmp/Jenkinsfile.paas-deploy "
                "bash paas/scripts/lab.sh jenkins\n"
                "  Or: JENKINSFILE=/tmp/Jenkinsfile.paas-deploy python3 paas/scripts/lib/create_jenkins_paas_deploy_job.py --force --force-full",
                file=sys.stderr,
            )
            sys.exit(1)
CPS_FLOW_DEFINITION = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
CDATA_SCRIPT_BLOCK = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW_DEFINITION)}"[^>]*>\s*<script>\s*<!\[CDATA\[)'
    r"([\s\S]*?)"
    r"(\]\]>\s*</script>)",
    re.IGNORECASE,
)
def existing_config_needs_full_push(existing_xml: str, groovy: str) -> bool:
    if any(m in groovy for m in MULTI_FRAMEWORK_MARKERS):
        if not any(m in existing_xml for m in MULTI_FRAMEWORK_MARKERS):
            return True
    checks = (
        (NGINX_CONF_WRITEFILE_MARKER, ("writeNginxPaasDefaultConf",)),
        (ENV_SAFE_DOTENV_LOADER_MARKER, ("paasSourceBuildEnvShellSnippet", "env-decode-node-20260601")),
        (SONAR_LOGIN_JENKINSFILE_MARKER, (SONAR_LOGIN_MARKER, "printf 'sonar.login")),
        (COSIGN_DIGEST_MARKER, ()),
        (SONAR_STEP5_MARKER, ()),
        (SCA_FULL_INSTALL_MARKER, ("full npm install then cyclonedx-npm",)),
    )
    for primary, fallbacks in checks:
        if primary not in groovy:
            continue
        if primary in existing_xml:
            continue
        if any(f in existing_xml for f in fallbacks):
            continue
        return True
    return False
def merge_groovy_into_existing_config_xml(existing_xml: str, groovy: str) -> str:
    inner = esc_cdata(groovy)
    m = CDATA_SCRIPT_BLOCK.search(existing_xml)
    if m:
        return existing_xml[: m.start(2)] + inner + existing_xml[m.end(2) :]
    return build_xml(groovy, minimal_params=False).decode("utf-8")
def concurrent_builds_enabled() -> bool:
    raw = (os.environ.get("JENKINS_PAAS_CONCURRENT_BUILDS") or "true").strip().lower()
    return raw not in ("false", "0", "no", "off")
def disable_concurrent_block_xml() -> str:
    return (
        "    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>\n"
        "      <abortPrevious>false</abortPrevious>\n"
        "    </org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>\n"
    )
def strip_disable_concurrent_builds(xml: str) -> str:
    return re.sub(
        r"\s*<org\.jenkinsci\.plugins\.workflow\.job\.properties\.DisableConcurrentBuildsJobProperty>[\s\S]*?</org\.jenkinsci\.plugins\.workflow\.job\.properties\.DisableConcurrentBuildsJobProperty>\s*",
        "\n",
        xml,
        count=1,
    )
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
        params = [(n, resolve_param_default(n, d)) for n, d in FULL_PARAMETER_DEFINITIONS]
    pxml = "\n".join(param_block_xml(n, d) for n, d in params)
    inner = esc_cdata(groovy)
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<flow-definition plugin="workflow-job">\n'
        "  <description>paas-deploy (create_jenkins_paas_deploy_job.py)</description>\n"
        "  <keepDependencies>false</keepDependencies>\n"
        "  <properties>\n"
        + (disable_concurrent_block_xml() if not concurrent_builds_enabled() else "")
        + "    <hudson.model.ParametersDefinitionProperty>\n"
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
    for key in ("JENKINS_PROBE_URL", "JENKINS_LAB_LOOPBACK", "JENKINS_BASE_URL"):
        base = (os.environ.get(key) or read_compose_env_value(key) or "").strip().rstrip("/")
        if base and "jenkins-service" not in base and "svc.cluster.local" not in base:
            return base
    return "http://127.0.0.1:30090"
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
    params_only = "--params-only" in sys.argv
    force = "--force" in sys.argv or "--force-full" in sys.argv
    force_full = "--force-full" in sys.argv
    jenkinsfile = resolve_jenkinsfile_path()
    if not user or not token:
        print("ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN in docker-compose.env or paas-frontend-env secret", file=sys.stderr)
        print("  Fix: add to paas/frontend/.env then npm run env:compose && bash paas/scripts/lab.sh env", file=sys.stderr)
        print("  Or: kubectl get secret paas-frontend-env -n paas -o jsonpath='{.data.JENKINS_USERNAME}' | base64 -d", file=sys.stderr)
        return 1
    if any(x in token for x in ("paste", "YOUR", "REAL_TOKEN")):
        print("ERROR: JENKINS_API_TOKEN looks like a placeholder", file=sys.stderr)
        return 1
    if not wait_for_jenkins_api(base):
        return 1
    client = JenkinsClient(base, user, token)
    code, _ = client.call("/api/json")
    print(f"GET /api/json -> {code}")
    if code != 200:
        return 1
    job_path = f"/job/{urllib.parse.quote(job)}/api/json"
    job_cfg = f"/job/{urllib.parse.quote(job)}/config.xml"
    if params_only:
        cfg_code, existing_cfg = client.call(job_cfg)
        if cfg_code != 200 or not existing_cfg.strip():
            print(f"ERROR: job '{job}' not found — create it first with --force --force-full", file=sys.stderr)
            return 1
        merged = ensure_job_parameters(existing_cfg)
        merged = merge_env_param_defaults(merged)
        merged = merge_env_param_defaults_force(merged)
        xml = merged.encode("utf-8")
        print(
            f"Updating job '{job}' parameter defaults only ({len(xml)} bytes) — Pipeline script unchanged"
        )
        extra = client.crumb_headers()
        if extra:
            print(f"Crumb: {list(extra.keys())[0]}")
        ucode, ubody = client.call(job_cfg, "POST", xml, extra)
        print(f"POST config.xml -> {ucode}")
        if ucode not in (200, 201, 302):
            print(ubody[:2500])
            return 1
        verify_code, verify_cfg = client.call(job_cfg)
        if verify_code == 200:
            if not verify_job_script_markers(verify_cfg):
                print(
                    f"WARN: job script missing {NGINX_CONF_WRITEFILE_MARKER} — "
                    "run bash paas/scripts/lab.sh jenkins before deploying",
                    file=sys.stderr,
                )
            for name in FORCE_ENV_PARAM_DEFAULTS:
                if job_defines_string_parameter(verify_cfg, name):
                    print(f"OK: job parameter {name} defined")
        print(f"OK: {base}/job/{job}/")
        return 0
    if minimal:
        groovy = MINIMAL_GROOVY
        groovy_bundle = MINIMAL_GROOVY
        print("Mode: --minimal (small pipeline; replace later via PaaS sync or UI)")
    else:
        if not jenkinsfile.is_file():
            print(f"ERROR: missing {jenkinsfile}", file=sys.stderr)
            return 1
        groovy_main, _, groovy_bundle = read_jenkinsfile_bundle(jenkinsfile)
        if not groovy_main.strip():
            print("ERROR: empty Jenkinsfile", file=sys.stderr)
            return 1
        if "def runPaasDeploy" not in groovy_main:
            print("ERROR: Jenkinsfile missing def runPaasDeploy", file=sys.stderr)
            return 1
        assert_jenkinsfile_twelve_steps(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_crane_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_mutate_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_env_loader_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_cosign_digest_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_sonar_step5_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_multi_framework_fix(groovy_bundle, jenkinsfile)
        assert_jenkinsfile_nginx_conf_fix(groovy_bundle, jenkinsfile)
        groovy = build_load_wrapper()
    groovy_bundle_check = groovy_bundle if not minimal else groovy
    code, pm_body = client.call("/pluginManager/api/json?depth=1")
    pipeline_markers = ("workflow-job", "workflow-cps", "workflow-aggregator")
    if code == 200 and not any(m in pm_body for m in pipeline_markers):
        print(
            "ERROR: Pipeline plugins not installed "
            f"(need one of: {', '.join(pipeline_markers)}).",
            file=sys.stderr,
        )
        print(
            "Run: bash paas/scripts/lab.sh jenkins",
            file=sys.stderr,
        )
        return 1
    code, _ = client.call(job_path)
    xml = build_xml(groovy, minimal_params=minimal)
    if code == 200 and not force:
        print(f"Job '{job}' already exists: {base}/job/{job}/")
        print("Re-run with --force to replace Pipeline script from Jenkinsfile.paas-deploy")
        return 0
    if code == 200 and force:
        cfg_code, existing_cfg = client.call(job_cfg)
        if cfg_code == 200 and existing_cfg.strip():
            refuse_stale_groovy_overwrite(existing_cfg, groovy_bundle_check)
        if force_full:
            mode = "full-document"
            print(f"Updating existing job '{job}' ({len(xml)} bytes, {mode} — params + no concurrent builds)")
        else:
            if (
                cfg_code == 200
                and existing_cfg.strip()
                and not existing_config_needs_full_push(existing_cfg, groovy_bundle_check)
            ):
                merged = merge_groovy_into_existing_config_xml(existing_cfg, groovy)
                merged = ensure_job_parameters(merged)
                xml = merged.encode("utf-8")
                mode = "merged-cdata"
            else:
                if cfg_code == 200 and existing_cfg.strip():
                    print(
                        "NOTE: using full-document (merged job missing required markers — "
                        "use --force-full to avoid this check)",
                        file=sys.stderr,
                    )
                xml = build_xml(groovy, minimal_params=minimal)
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
        verify_code, verify_cfg = client.call(job_cfg)
        if verify_code == 200:
            if not verify_job_script_markers(verify_cfg):
                print(
                    "ERROR: POST succeeded but job script still missing required markers "
                    f"(def runPaasDeploy + {NGINX_CONF_WRITEFILE_MARKER} + {SCA_FULL_INSTALL_MARKER}).\n"
                    "  JENKINSFILE=/path/to/Jenkinsfile.paas-deploy bash paas/scripts/lab.sh jenkins",
                    file=sys.stderr,
                )
                return 1
            if "load paasDeployStagesPath" in verify_cfg or PAAS_DEPLOY_STAGES_LOAD_MARKER in verify_cfg:
                print(f"OK: job script loads stages via {JENKINS_STAGES_REMOTE_PATH}")
            else:
                print(f"OK: job script is monolithic (def runPaasDeploy + Steps 1-12)")
            for name in (
                "SONAR_HOST_URL",
                "SONAR_TOKEN",
                "DEPENDENCY_TRACK_BASE_URL",
                "DEPENDENCY_TRACK_API_KEY",
                "JENKINS_DEPENDENCY_TRACK_BASE_URL",
            ):
                if job_defines_string_parameter(verify_cfg, name):
                    print(f"OK: job parameter {name} defined")
                else:
                    print(f"WARN: job parameter {name} still missing — re-run with --force-full", file=sys.stderr)
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
