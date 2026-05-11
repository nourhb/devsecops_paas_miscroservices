import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
type ParamDef = readonly [
    name: string,
    defaultValue: string,
    description: string
];
const PARAMETER_DEFINITIONS: ParamDef[] = [
    ["JENKINS_AGENT_LABEL", "built-in", "Agent label for Kubernetes Pod Template."],
    ["GIT_URL", "", "Repository clone URL"],
    ["BRANCH", "main", "Git branch"],
    ["IMAGE_NAME", "", "Image without tag (registry/project/app)"],
    ["PROJECT_ID", "", "PaaS project UUID"],
    ["GIT_CREDENTIALS_ID", "", "Jenkins credentialsId for private Git (omit for public)"],
    ["KANIKO_IMAGE", "gcr.io/kaniko-project/executor:debug", "Kaniko executor image"],
    ["DOCKER_REGISTRY_CREDENTIALS_ID", "harbor-docker", "Jenkins credentialsId for docker login when not using HARBOR_* + Kaniko"],
    ["DOCKERFILE_PATH", "Dockerfile", "Dockerfile path relative to repo root"],
    ["DOCKER_BUILD_CONTEXT", ".", "Docker build context relative to repo root"],
    ["FALLBACK_IMAGE", "nginx:stable-alpine", "Image to deploy when Docker is unavailable on this Jenkins node"],
    ["DOCKERHUB_USERNAME", "", "Docker Hub username for dockerless crane pushes"],
    ["DOCKERHUB_TOKEN", "", "Docker Hub token for dockerless crane pushes"],
    ["HARBOR_REGISTRY", "", "Harbor registry host for dockerless crane pushes"],
    ["HARBOR_USERNAME", "", "Harbor username for dockerless crane pushes"],
    ["HARBOR_PASSWORD", "", "Harbor password for dockerless crane pushes"],
    ["SONAR_HOST_URL", "", "SonarQube URL for dockerless Sonar scanner"],
    ["SONAR_TOKEN", "", "SonarQube token for dockerless Sonar scanner"],
    ["DEPENDENCY_TRACK_BASE_URL", "", "Dependency-Track URL for SBOM upload"],
    ["DEPENDENCY_TRACK_API_KEY", "", "Dependency-Track API key for SBOM upload"],
    ["NVD_API_KEY", "", "Optional NVD API key for OWASP Dependency-Check"],
    ["ZAP_TARGET_URL", "", "Optional DAST target URL for OWASP ZAP baseline (e.g. http://your-app:8080); empty skips stage"],
    ["BUILD_PACKAGE_PROXY_URL", "", "HTTP(S) proxy for npm on the Jenkins agent (e.g. http://proxy.internal:8080); empty = direct"],
    ["NPM_CONFIG_REGISTRY", "", "npm registry for Jenkins npm ci (e.g. https://registry.npmjs.org/ or Verdaccio mirror); empty = npm default"],
    ["JENKINS_PAAS_NODE_CACHE", "", "Directory root for cached portable Node (default: JENKINS_HOME/.jenkins-paas-cache/node); survives clean workspace"],
    ["JENKINS_PAAS_NPM_CACHE", "", "Persistent npm cache dir (default: JENKINS_HOME/.jenkins-paas-cache/npm)"],
    ["JENKINS_SH_KEEPALIVE", "false", "true = background npm + heartbeat (can break durable-task after Jenkins restart); keep false unless a proxy drops idle logs"],
    ["JENKINS_NEXT_BUILD_WEBPACK", "false", "Next 16+: use true only if you need webpack (slow cold builds). Default Turbopack. Next 15: false disables --webpack."],
    ["JENKINS_NEXT_PERSIST_CACHE", "true", "Persist .next/cache under JENKINS_HOME (per PROJECT_ID); set false to disable symlink cache"],
    ["JENKINS_NEXT_BUILD_HEARTBEAT", "true", "Periodic stdout during long quiet steps: npx next build + crane image push (reduces Jenkins durable-task exit -2); false disables"],
    ["JENKINS_NEXT_BUILD_HEARTBEAT_SEC", "45", "Seconds between heartbeat log lines (next build + crane push)"],
    ["ARTIFACTORY_URL", "", "Optional JFrog Artifactory base URL (e.g. https://host/artifactory) for build bundle upload"],
    ["ARTIFACTORY_REPOSITORY", "libs-release-local", "Generic repository key in Artifactory for uploaded .tgz bundles"],
    ["ARTIFACTORY_USERNAME", "", "Artifactory user (optional if ACCESS_TOKEN or ARTIFACTORY_CREDENTIALS_ID)"],
    ["ARTIFACTORY_PASSWORD", "", "Artifactory password (optional)"],
    ["ARTIFACTORY_ACCESS_TOKEN", "", "Artifactory bearer token (optional)"],
    ["ARTIFACTORY_CREDENTIALS_ID", "", "Optional Jenkins username/password credential id for Artifactory (overrides ARTIFACTORY_* env on agent if set)"],
    ["COSIGN_CREDENTIALS_ID", "", "Optional Jenkins secret file credential id (Cosign private key) for signing IMAGE:BUILD_NUMBER"],
    ["HELM_OCI_PROJECT", "paas", "Harbor project name for OCI Helm charts (helm push oci://HARBOR_REGISTRY/PROJECT)"],
    ["HELM_OCI_INSECURE", "false", "helm registry login --insecure (self-signed TLS)"],
    ["HELM_OCI_PLAIN_HTTP", "false", "helm push --plain-http"]
];
function escapeXmlText(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function parameterPropertyXml(indent: string): string {
    const paramIndent = `${indent}      `;
    const params = PARAMETER_DEFINITIONS.map(([name, defaultValue, description]) => {
        return (`${paramIndent}<hudson.model.StringParameterDefinition>\n` +
            `${paramIndent}  <name>${escapeXmlText(name)}</name>\n` +
            `${paramIndent}  <description>${escapeXmlText(description)}</description>\n` +
            `${paramIndent}  <defaultValue>${escapeXmlText(defaultValue)}</defaultValue>\n` +
            `${paramIndent}  <trim>true</trim>\n` +
            `${paramIndent}</hudson.model.StringParameterDefinition>`);
    });
    return (`${indent}<hudson.model.ParametersDefinitionProperty>\n` +
        `${indent}  <parameterDefinitions>\n` +
        `${params.join("\n")}\n` +
        `${indent}  </parameterDefinitions>\n` +
        `${indent}</hudson.model.ParametersDefinitionProperty>`);
}
function ensureParameterizedJobXml(xml: string): string {
    if (xml.includes("hudson.model.ParametersDefinitionProperty")) {
        return xml;
    }
    const prop = parameterPropertyXml("    ");
    if (/<properties\s*\/>/.test(xml)) {
        return xml.replace(/<properties\s*\/>/, `<properties>\n${prop}\n  </properties>`);
    }
    if (xml.includes("</properties>")) {
        return xml.replace("</properties>", `${prop}\n  </properties>`);
    }
    return xml.replace("<keepDependencies>false</keepDependencies>", `<keepDependencies>false</keepDependencies>\n  <properties>\n${prop}\n  </properties>`);
}
function escapeCdata(s: string): string {
    return s.replace(/]]>/g, "]]]]><![CDATA[>");
}
const CPS_FLOW_DEFINITION = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition";
const CDATA_SCRIPT_BLOCK = new RegExp(`(<definition\\b[^>]*class="${CPS_FLOW_DEFINITION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^>]*>\\s*<script>\\s*<!\\[CDATA\\[)([\\s\\S]*?)(\\]\\]>\\s*</script>)`, "i");
const DEFINITION_BLOCK = /<definition\b[^>]*>[\s\S]*?<\/definition>/i;
function definitionXmlFragment(groovyScript: string): string {
    const inner = escapeCdata(groovyScript);
    return (`<definition class="${CPS_FLOW_DEFINITION}" plugin="workflow-cps">\n` +
        `    <script><![CDATA[${inner}]]></script>\n` +
        `    <sandbox>true</sandbox>\n` +
        `  </definition>`);
}
function buildPaasDeployJobConfigXml(groovyScript: string): Buffer {
    const inner = escapeCdata(groovyScript);
    const xml = `<?xml version="1.0" encoding="UTF-8"?>\n` +
        `<flow-definition plugin="workflow-job">\n` +
        `  <description>Inline pipeline from Jenkinsfile.paas-deploy (no SCM). Updated by PaaS (inline-paas-deploy-job-sync.ts)</description>\n` +
        `  <keepDependencies>false</keepDependencies>\n` +
        `  <properties>\n` +
        `${parameterPropertyXml("    ")}\n` +
        `  </properties>\n` +
        `  <definition class="${CPS_FLOW_DEFINITION}" plugin="workflow-cps">\n` +
        `    <script><![CDATA[${inner}]]></script>\n` +
        `    <sandbox>true</sandbox>\n` +
        `  </definition>\n` +
        `  <triggers/>\n` +
        `  <disabled>false</disabled>\n` +
        `</flow-definition>\n`;
    return Buffer.from(ensureParameterizedJobXml(xml), "utf-8");
}
function prepareUpdatedJobConfigXml(existingXml: string | null | undefined, groovyScript: string): {
    payload: Buffer;
    mode: "merged-cdata" | "replaced-definition" | "full-document";
} {
    if (!existingXml?.trim()) {
        return { payload: buildPaasDeployJobConfigXml(groovyScript), mode: "full-document" };
    }
    let xml = existingXml.replace(/^\uFEFF/, "");
    const inner = escapeCdata(groovyScript);
    const m = CDATA_SCRIPT_BLOCK.exec(xml);
    if (m) {
        const merged = xml.slice(0, m.index + m[1].length) + inner + xml.slice(m.index + m[1].length + m[2].length);
        return { payload: Buffer.from(ensureParameterizedJobXml(merged), "utf-8"), mode: "merged-cdata" };
    }
    if (xml.includes("<flow-definition")) {
        const dm = DEFINITION_BLOCK.exec(xml);
        if (dm) {
            const merged = xml.slice(0, dm.index) + definitionXmlFragment(groovyScript) + xml.slice(dm.index + dm[0].length);
            return { payload: Buffer.from(ensureParameterizedJobXml(merged), "utf-8"), mode: "replaced-definition" };
        }
    }
    return { payload: buildPaasDeployJobConfigXml(groovyScript), mode: "full-document" };
}
function extractCookieHeader(response: Response): string | null {
    const h = response.headers as Headers & {
        getSetCookie?: () => string[];
    };
    if (typeof h.getSetCookie === "function") {
        const parts = h.getSetCookie();
        if (parts?.length) {
            return parts
                .map((line) => line.split(";")[0]?.trim())
                .filter(Boolean)
                .join("; ");
        }
    }
    const setCookie = response.headers.get("set-cookie");
    if (!setCookie) {
        return null;
    }
    return setCookie
        .split(/,(?=[^;]+=[^;])/i)
        .map((line) => line.split(";")[0]?.trim())
        .filter(Boolean)
        .join("; ");
}
function mergeCookieHeader(existing: string | null, incoming: string | null): string | null {
    const map = new Map<string, string>();
    const ingest = (chunk: string | null) => {
        if (!chunk?.trim()) {
            return;
        }
        for (const part of chunk.split(";")) {
            const t = part.trim();
            const eq = t.indexOf("=");
            if (eq <= 0) {
                continue;
            }
            const name = t.slice(0, eq).trim();
            const value = t.slice(eq + 1).trim();
            if (name) {
                map.set(name, value);
            }
        }
    };
    ingest(existing);
    ingest(incoming);
    if (!map.size) {
        return existing?.trim() || null;
    }
    return Array.from(map.entries())
        .map(([k, v]) => `${k}=${v}`)
        .join("; ");
}
type CookieJar = {
    cookie: string | null;
};
async function fetchJenkinsCrumb(base: string, authHeader: string, jar: CookieJar): Promise<{
    field: string;
    value: string;
} | null> {
    const headers = new Headers({ Authorization: authHeader });
    if (jar.cookie) {
        headers.set("Cookie", jar.cookie);
    }
    const res = await integrationFetch(`${base}/crumbIssuer/api/json`, { headers }, env.JENKINS_HTTP_TIMEOUT_MS);
    const newCookies = extractCookieHeader(res);
    if (newCookies) {
        jar.cookie = mergeCookieHeader(jar.cookie, newCookies);
    }
    if (!res.ok) {
        return null;
    }
    try {
        const data = (await res.json()) as {
            crumb?: string;
            crumbRequestField?: string;
        };
        if (data.crumb && data.crumbRequestField) {
            return { field: data.crumbRequestField, value: data.crumb };
        }
    }
    catch {
    }
    return null;
}
function extractHtmlErrorHint(body: string, maxLen = 1200): string {
    const patterns = [
        /<h1[^>]*>\s*([^<]+)/i,
        /id="error-description"[^>]*>\s*([\s\S]*?)<\/div>/i,
        /<pre[^>]*>\s*([\s\S]{0,2500}?)<\/pre>/i,
        /<title>\s*([^<]+)/i
    ];
    for (const re of patterns) {
        const m = re.exec(body);
        if (m?.[1]) {
            const text = m[1]
                .replace(/<[^>]+>/g, " ")
                .replace(/\s+/g, " ")
                .trim();
            if (text) {
                return text.slice(0, maxLen);
            }
        }
    }
    return "";
}
function jenkinsAuthHeader(): string {
    const user = env.JENKINS_USERNAME.trim();
    const token = env.JENKINS_API_TOKEN.trim();
    return `Basic ${Buffer.from(`${user}:${token}`, "utf-8").toString("base64")}`;
}
/** Jenkins serves HTTP 503 + "Starting Jenkins" HTML while the controller is still booting. */
const JENKINS_BOOT_MAX_ATTEMPTS = 15;
const JENKINS_BOOT_RETRY_MS = 4000;
function sleepMs(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
function looksLikeJenkinsStarting(status: number, body: string): boolean {
    if (status === 502 || status === 503 || status === 504) {
        return true;
    }
    const head = body.slice(0, 4000).toLowerCase();
    return head.includes("starting jenkins") || head.includes("app-jenkins-booting");
}
async function waitForJenkinsApiJson(base: string, authHeader: string, jar: CookieJar): Promise<{
    status: number;
    body: string;
}> {
    let last: { status: number; body: string } = { status: 0, body: "" };
    for (let attempt = 1; attempt <= JENKINS_BOOT_MAX_ATTEMPTS; attempt++) {
        last = await jenkinsReq(base, "/api/json", { method: "GET" }, authHeader, jar);
        if (last.status === 200) {
            return last;
        }
        if (last.status === 401) {
            throw new IntegrationError(`Jenkins rejected these credentials against ${base} (GET /api/json → HTTP 401). ` +
                `Fix JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN in frontend/docker-compose.env (no duplicate keys; last line wins). ` +
                `JENKINS_API_TOKEN must be a Jenkins **user API token** (Your name → Configure → API Token), not your login password. Regenerate the token if it was rotated. ` +
                `From the VM host, verify: curl -sS -u 'USER:TOKEN' '${base}/api/json' → 200. ` +
                `From inside the app container: docker compose exec frontend wget -qO- --user='USER' --password='TOKEN' '${base}/api/json' | head -c 200`);
        }
        if (last.status === 403) {
            throw new IntegrationError(`Jenkins returned HTTP 403 for GET ${base}/api/json. This usually means the URL host does not match Jenkins' configured root URL ` +
                `(Manage Jenkins → System → Jenkins URL). Use that exact URL in JENKINS_BASE_URL — not http://172.18.0.1:PORT when Jenkins is published as http://YOUR_VM_IP:PORT. ` +
                `Verify from the container with the same URL: docker compose exec frontend wget -S -O- --user='…' --password='…' '${base}/api/json'`);
        }
        if (looksLikeJenkinsStarting(last.status, last.body) && attempt < JENKINS_BOOT_MAX_ATTEMPTS) {
            await sleepMs(JENKINS_BOOT_RETRY_MS);
            continue;
        }
        break;
    }
    const waitedSec = Math.ceil(((JENKINS_BOOT_MAX_ATTEMPTS - 1) * JENKINS_BOOT_RETRY_MS) / 1000);
    if (looksLikeJenkinsStarting(last.status, last.body)) {
        throw new IntegrationError(
            `Jenkins is still starting or unavailable: GET ${base}/api/json stayed at HTTP ${last.status} after ${JENKINS_BOOT_MAX_ATTEMPTS} attempts (~${waitedSec}s). ` +
                `Wait until the Jenkins UI shows the dashboard (not the "Starting Jenkins" page), then sync or deploy again. ` +
                `If Jenkins is behind Docker or K8s, ensure the controller/pod is ready: kubectl get pods -n jenkins (or your namespace). ` +
                `Body preview: ${last.body.slice(0, 400)}`
        );
    }
    throw new IntegrationError(`Jenkins URL misconfigured or unreachable: GET ${base}/api/json returned HTTP ${last.status}. Body: ${last.body.slice(0, 500)}`);
}
async function jenkinsReq(base: string, pathname: string, init: RequestInit, authHeader: string, jar: CookieJar, postCrumb?: {
    field: string;
    value: string;
}): Promise<{
    status: number;
    body: string;
}> {
    const headers = new Headers(init.headers as HeadersInit | undefined);
    headers.set("Authorization", authHeader);
    if (jar.cookie) {
        headers.set("Cookie", jar.cookie);
    }
    if (postCrumb) {
        headers.set(postCrumb.field, postCrumb.value);
    }
    const res = await integrationFetch(`${base}${pathname}`, { ...init, headers }, env.JENKINS_HTTP_TIMEOUT_MS);
    const newCookies = extractCookieHeader(res);
    if (newCookies) {
        jar.cookie = mergeCookieHeader(jar.cookie, newCookies);
    }
    const body = await res.text();
    return { status: res.status, body };
}
export type SyncInlinePaasDeployJobOptions = {
    jobName: string;
    groovyScript: string;
    jenkinsfileLabel: string;
    forceFullConfig?: boolean;
    verbose?: boolean;
};
export async function syncInlinePaasDeployJobToJenkins(opts: SyncInlinePaasDeployJobOptions): Promise<string> {
    const base = env.JENKINS_BASE_URL.replace(/\/+$/, "");
    const user = env.JENKINS_USERNAME.trim();
    const token = env.JENKINS_API_TOKEN.trim();
    if (!base || !user || !token) {
        throw new IntegrationError("Jenkins inline job sync needs JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (e.g. paas/frontend/docker-compose.env).");
    }
    const authHeader = jenkinsAuthHeader();
    const jar: CookieJar = { cookie: null };
    await waitForJenkinsApiJson(base, authHeader, jar);
    const crumbInfo = await fetchJenkinsCrumb(base, authHeader, jar);
    const jobName = opts.jobName.trim();
    const lines: string[] = [];
    const postCrumb = crumbInfo ?? undefined;
    const { status: existsCode } = await jenkinsReq(base, `/job/${encodeURIComponent(jobName)}/api/json`, { method: "GET" }, authHeader, jar);
    if (existsCode === 200) {
        let payload = buildPaasDeployJobConfigXml(opts.groovyScript);
        let updateMode: "merged-cdata" | "replaced-definition" | "full-document" = "full-document";
        if (!opts.forceFullConfig) {
            const { status: gc, body: existingBody } = await jenkinsReq(base, `/job/${encodeURIComponent(jobName)}/config.xml`, { method: "GET" }, authHeader, jar);
            if (gc === 200 && existingBody.trim()) {
                const prep = prepareUpdatedJobConfigXml(existingBody, opts.groovyScript);
                payload = prep.payload;
                updateMode = prep.mode;
                if (opts.verbose) {
                    lines.push(`Config source: ${updateMode} (from GET config.xml)`);
                }
            }
            else if (opts.verbose) {
                lines.push(`GET config.xml HTTP ${gc}: using full generated XML`);
            }
        }
        const { status: code2, body: body2 } = await jenkinsReq(base, `/job/${encodeURIComponent(jobName)}/config.xml`, {
            method: "POST",
            body: payload.toString("utf-8"),
            redirect: "manual",
            headers: { "Content-Type": "application/xml; charset=UTF-8" }
        }, authHeader, jar, postCrumb);
        if (code2 === 200 || code2 === 201) {
            const how: Record<string, string> = {
                "merged-cdata": "merged script into existing job XML",
                "replaced-definition": "replaced <definition> with inline pipeline (was SCM or non-CDATA)",
                "full-document": "replaced job config with generated flow-definition"
            };
            lines.push(`Updated Jenkins job '${jobName}' at ${base}/job/${jobName}/ (HTTP ${code2}) — ${how[updateMode] ?? updateMode}; pipeline from ${opts.jenkinsfileLabel}`);
            lines.push("");
            lines.push("--- OK: Jenkins is aligned with Jenkinsfile.paas-deploy ---");
            lines.push("You can deploy from the PaaS app (same JENKINS_* as this sync).");
            lines.push(`Job URL: ${base}/job/${jobName}/`);
            return lines.join("\n");
        }
        const hint = extractHtmlErrorHint(body2);
        let msg = `Job exists but config update failed HTTP ${code2}`;
        if (hint) {
            msg += `: ${hint}`;
        }
        msg += `\n${body2.slice(0, 4000)}`;
        msg +=
            "\n\nIf this was HTTP 500: open Jenkins \u2192 Manage Jenkins \u2192 System Log, or controller pod logs, " +
                "for the Java stack trace.";
        throw new IntegrationError(msg);
    }
    const createUrl = `/createItem?name=${encodeURIComponent(jobName)}`;
    const { status: createCode, body: createBody } = await jenkinsReq(base, createUrl, {
        method: "POST",
        body: buildPaasDeployJobConfigXml(opts.groovyScript).toString("utf-8"),
        redirect: "manual",
        headers: { "Content-Type": "application/xml; charset=UTF-8" }
    }, authHeader, jar, postCrumb);
    if (createCode === 200 || createCode === 201 || createCode === 302) {
        lines.push(`Created Jenkins job '${jobName}' at ${base}/job/${jobName}/ (HTTP ${createCode}) — inline pipeline from ${opts.jenkinsfileLabel}`);
        lines.push("");
        lines.push("--- OK: Jenkins is aligned with Jenkinsfile.paas-deploy ---");
        lines.push("You can deploy from the PaaS app (same JENKINS_* as this sync).");
        lines.push(`Job URL: ${base}/job/${jobName}/`);
        return lines.join("\n");
    }
    if (createCode === 401) {
        throw new IntegrationError("HTTP 401 on /createItem. If GET /api/json succeeded, Jenkins often needs the same browser session cookie with the CSRF crumb for POSTs. " +
            "This build sends Cookie + crumb accumulated from /api/json and /crumbIssuer; rebuild the frontend image with the latest sync. " +
            "Otherwise verify Overall/Create permission for the Jenkins user. " +
            "Also compare password/API token with: kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d\n" +
            "JENKINS_* live in frontend/docker-compose.env. Verify: docker compose exec frontend env | grep JENKINS\n" +
            `Failed HTTP ${createCode}:\n${createBody.slice(0, 6000)}`);
    }
    throw new IntegrationError(`Failed HTTP ${createCode}:\n${createBody.slice(0, 6000)}`);
}
