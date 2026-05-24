

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