/**
 * Create or update the shared Jenkins deploy job (inline Pipeline XML) via REST — TypeScript port of
 * the former paas/scripts/jenkins_create_paas_deploy_job.py (no Python / subprocess).
 */
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";

type ParamDef = readonly [name: string, defaultValue: string, description: string];

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

/** Match Python html.escape default (ampersand, lt, gt). */
function escapeXmlText(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function parameterPropertyXml(indent: string): string {
    const paramIndent = `${indent}      `;
    const params = PARAMETER_DEFINITIONS.map(([name, defaultValue, description]) => {
        return (
            `${paramIndent}<hudson.model.StringParameterDefinition>\n` +
            `${paramIndent}  <name>${escapeXmlText(name)}</name>\n` +
            `${paramIndent}  <description>${escapeXmlText(description)}</description>\n` +
            `${paramIndent}  <defaultValue>${escapeXmlText(defaultValue)}</defaultValue>\n` +
            `${paramIndent}  <trim>true</trim>\n` +
            `${paramIndent}</hudson.model.StringParameterDefinition>`
        );
    });
    return (
        `${indent}<hudson.model.ParametersDefinitionProperty>\n` +
        `${indent}  <parameterDefinitions>\n` +
        `${params.join("\n")}\n` +
        `${indent}  </parameterDefinitions>\n` +
        `${indent}</hudson.model.ParametersDefinitionProperty>`
    );
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
    return xml.replace(
        "<keepDependencies>false</keepDependencies>",
        `<keepDependencies>false</keepDependencies>\n  <properties>\n${prop}\n  </properties>`
    );
}

function escapeCdata(s: string): string {
    return s.replace(/]]>/g, "]]]]><![CDATA[>");
}

const CPS_FLOW_DEFINITION = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition";
const CDATA_SCRIPT_BLOCK = new RegExp(
    `(<definition\\b[^>]*class="${CPS_FLOW_DEFINITION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^>]*>\\s*<script>\\s*<!\\[CDATA\\[)([\\s\\S]*?)(\\]\\]>\\s*</script>)`,
    "i"
);
const DEFINITION_BLOCK = /<definition\b[^>]*>[\s\S]*?<\/definition>/i;

function definitionXmlFragment(groovyScript: string): string {
    const inner = escapeCdata(groovyScript);
    return (
        `<definition class="${CPS_FLOW_DEFINITION}" plugin="workflow-cps">\n` +
        `    <script><![CDATA[${inner}]]></script>\n` +
        `    <sandbox>true</sandbox>\n` +
        `  </definition>`
    );
}

function buildPaasDeployJobConfigXml(groovyScript: string): Buffer {
    const inner = escapeCdata(groovyScript);
    const xml =
        `<?xml version="1.0" encoding="UTF-8"?>\n` +
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

function prepareUpdatedJobConfigXml(
    existingXml: string | null | undefined,
    groovyScript: string
): { payload: Buffer; mode: "merged-cdata" | "replaced-definition" | "full-document" } {
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
    const h = response.headers as Headers & { getSetCookie?: () => string[] };
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
    const firstCookie = setCookie.split(";")[0]?.trim();
    return firstCookie || null;
}

async function fetchJenkinsCrumb(
    base: string,
    authHeader: string
): Promise<{ field: string; value: string; cookie: string | null } | null> {
    const res = await integrationFetch(
        `${base}/crumbIssuer/api/json`,
        { headers: { Authorization: authHeader } },
        env.JENKINS_HTTP_TIMEOUT_MS
    );
    if (!res.ok) {
        return null;
    }
    try {
        const data = (await res.json()) as { crumb?: string; crumbRequestField?: string };
        if (data.crumb && data.crumbRequestField) {
            return { field: data.crumbRequestField, value: data.crumb, cookie: extractCookieHeader(res) };
        }
    } catch {
        /* ignore */
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
    return `Basic ${Buffer.from(`${env.JENKINS_USERNAME}:${env.JENKINS_API_TOKEN}`).toString("base64")}`;
}

async function jenkinsReq(
    base: string,
    pathname: string,
    init: RequestInit,
    authHeader: string,
    postExtras?: { crumb: { field: string; value: string }; cookie: string | null }
): Promise<{ status: number; body: string }> {
    const headers = new Headers(init.headers as HeadersInit | undefined);
    headers.set("Authorization", authHeader);
    if (postExtras?.cookie) {
        headers.set("Cookie", postExtras.cookie);
    }
    if (postExtras?.crumb) {
        headers.set(postExtras.crumb.field, postExtras.crumb.value);
    }
    const res = await integrationFetch(`${base}${pathname}`, { ...init, headers }, env.JENKINS_HTTP_TIMEOUT_MS);
    const body = await res.text();
    return { status: res.status, body };
}

export type SyncInlinePaasDeployJobOptions = {
    jobName: string;
    groovyScript: string;
    jenkinsfileLabel: string;
    /** Minimal generated XML only (no merge into existing job XML). */
    forceFullConfig?: boolean;
    verbose?: boolean;
};

/**
 * POST inline pipeline job XML to Jenkins (create or update). Uses `env` Jenkins URL, user, and API token.
 */
export async function syncInlinePaasDeployJobToJenkins(opts: SyncInlinePaasDeployJobOptions): Promise<string> {
    const base = env.JENKINS_BASE_URL.replace(/\/+$/, "");
    const user = env.JENKINS_USERNAME.trim();
    const token = env.JENKINS_API_TOKEN.trim();
    if (!base || !user || !token) {
        throw new IntegrationError(
            "Jenkins inline job sync needs JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (e.g. paas/frontend/docker-compose.env)."
        );
    }

    const authHeader = jenkinsAuthHeader();

    const crumbInfo = await fetchJenkinsCrumb(base, authHeader);
    const postCrumb = crumbInfo ? { field: crumbInfo.field, value: crumbInfo.value } : undefined;
    const postCookie = crumbInfo?.cookie ?? null;
    const postExtra = postCrumb ? { crumb: postCrumb, cookie: postCookie } : undefined;

    const jobName = opts.jobName.trim();
    const lines: string[] = [];

    const { status: existsCode } = await jenkinsReq(base, `/job/${encodeURIComponent(jobName)}/api/json`, { method: "GET" }, authHeader);

    if (existsCode === 200) {
        let payload = buildPaasDeployJobConfigXml(opts.groovyScript);
        let updateMode: "merged-cdata" | "replaced-definition" | "full-document" = "full-document";
        if (!opts.forceFullConfig) {
            const { status: gc, body: existingBody } = await jenkinsReq(
                base,
                `/job/${encodeURIComponent(jobName)}/config.xml`,
                { method: "GET" },
                authHeader
            );
            if (gc === 200 && existingBody.trim()) {
                const prep = prepareUpdatedJobConfigXml(existingBody, opts.groovyScript);
                payload = prep.payload;
                updateMode = prep.mode;
                if (opts.verbose) {
                    lines.push(`Config source: ${updateMode} (from GET config.xml)`);
                }
            } else if (opts.verbose) {
                lines.push(`GET config.xml HTTP ${gc}: using full generated XML`);
            }
        }

        const { status: code2, body: body2 } = await jenkinsReq(
            base,
            `/job/${encodeURIComponent(jobName)}/config.xml`,
            {
                method: "POST",
                body: payload.toString("utf-8"),
                redirect: "manual",
                headers: { "Content-Type": "application/xml; charset=UTF-8" }
            },
            authHeader,
            postExtra
        );

        if (code2 === 200 || code2 === 201) {
            const how: Record<string, string> = {
                "merged-cdata": "merged script into existing job XML",
                "replaced-definition": "replaced <definition> with inline pipeline (was SCM or non-CDATA)",
                "full-document": "replaced job config with generated flow-definition"
            };
            lines.push(
                `Updated Jenkins job '${jobName}' at ${base}/job/${jobName}/ (HTTP ${code2}) — ${how[updateMode] ?? updateMode}; pipeline from ${opts.jenkinsfileLabel}`
            );
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
            "\n\nIf this was HTTP 500: open Jenkins → Manage Jenkins → System Log, or controller pod logs, " +
            "for the Java stack trace.";
        throw new IntegrationError(msg);
    }

    const createUrl = `/createItem?name=${encodeURIComponent(jobName)}`;
    const { status: createCode, body: createBody } = await jenkinsReq(
        base,
        createUrl,
        {
            method: "POST",
            body: buildPaasDeployJobConfigXml(opts.groovyScript).toString("utf-8"),
            redirect: "manual",
            headers: { "Content-Type": "application/xml; charset=UTF-8" }
        },
        authHeader,
        postExtra
    );

    if (createCode === 200 || createCode === 201 || createCode === 302) {
        lines.push(
            `Created Jenkins job '${jobName}' at ${base}/job/${jobName}/ (HTTP ${createCode}) — inline pipeline from ${opts.jenkinsfileLabel}`
        );
        lines.push("");
        lines.push("--- OK: Jenkins is aligned with Jenkinsfile.paas-deploy ---");
        lines.push("You can deploy from the PaaS app (same JENKINS_* as this sync).");
        lines.push(`Job URL: ${base}/job/${jobName}/`);
        return lines.join("\n");
    }

    if (createCode === 401) {
        throw new IntegrationError(
            "HTTP 401: Wrong password or API token. Compare with cluster secret:\n" +
                "  kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d\n" +
                "Under Docker Compose, set JENKINS_BASE_URL / JENKINS_USERNAME / JENKINS_API_TOKEN in paas/frontend/docker-compose.env.\n" +
                "Verify: docker compose exec frontend env | grep JENKINS\n" +
                `Failed HTTP ${createCode}:\n${createBody.slice(0, 6000)}`
        );
    }

    throw new IntegrationError(`Failed HTTP ${createCode}:\n${createBody.slice(0, 6000)}`);
}
