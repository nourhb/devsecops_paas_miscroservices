import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
type ParamDef = readonly [
    name: string,
    defaultValue: string
];
const PARAMETER_DEFINITIONS: ParamDef[] = [
    ["JENKINS_AGENT_LABEL", ""],
    ["GIT_URL", ""],
    ["BRANCH", "main"],
    ["IMAGE_NAME", ""],
    ["PROJECT_ID", ""],
    ["GIT_CREDENTIALS_ID", ""],
    ["KANIKO_IMAGE", "gcr.io/kaniko-project/executor:debug"],
    ["DOCKER_REGISTRY_CREDENTIALS_ID", "harbor-docker"],
    ["DOCKERFILE_PATH", "Dockerfile"],
    ["DOCKER_BUILD_CONTEXT", "."],
    ["FALLBACK_IMAGE", "nginx:stable-alpine"],
    ["DOCKERHUB_USERNAME", ""],
    ["DOCKERHUB_TOKEN", ""],
    ["HARBOR_REGISTRY", ""],
    ["HARBOR_USERNAME", ""],
    ["HARBOR_PASSWORD", ""],
    ["SONAR_HOST_URL", ""],
    ["SONAR_TOKEN", ""],
    ["DEPENDENCY_TRACK_BASE_URL", ""],
    ["DEPENDENCY_TRACK_API_KEY", ""],
    ["NVD_API_KEY", ""],
    ["ZAP_TARGET_URL", ""],
    ["BUILD_PACKAGE_PROXY_URL", ""],
    ["NPM_CONFIG_REGISTRY", ""],
    ["JENKINS_PAAS_NODE_CACHE", ""],
    ["JENKINS_PAAS_NPM_CACHE", ""],
    ["JENKINS_SH_KEEPALIVE", "true"],
    ["JENKINS_PAAS_FAST_PIPELINE", "false"],
    ["JENKINS_NEXT_BUILD_WEBPACK", "false"],
    ["JENKINS_NEXT_PERSIST_CACHE", "true"],
    ["JENKINS_NEXT_BUILD_HEARTBEAT", "true"],
    ["JENKINS_NEXT_BUILD_HEARTBEAT_SEC", "45"],
    ["JENKINS_NPM_PRUNE_BEFORE_CRANE", "true"],
    ["JENKINS_CRANE_STANDALONE_LAYER", "auto"],
    ["ARTIFACTORY_URL", ""],
    ["ARTIFACTORY_REPOSITORY", "libs-release-local"],
    ["ARTIFACTORY_USERNAME", ""],
    ["ARTIFACTORY_PASSWORD", ""],
    ["ARTIFACTORY_ACCESS_TOKEN", ""],
    ["ARTIFACTORY_CREDENTIALS_ID", ""],
    ["COSIGN_CREDENTIALS_ID", ""],
    ["COSIGN_PRIVATE_KEY", ""],
    ["COSIGN_ALLOW_INSECURE_REGISTRY", "true"],
    ["HELM_OCI_PROJECT", "paas"],
    ["HELM_OCI_INSECURE", "false"],
    ["HELM_OCI_PLAIN_HTTP", "false"]
];
function escapeXmlText(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function stringParameterDefinitionXml(paramIndent: string, name: string, defaultValue: string): string {
    const fieldIndent = `${paramIndent}  `;
    return (`${paramIndent}<hudson.model.StringParameterDefinition>\n` +
        `${fieldIndent}<name>${escapeXmlText(name)}</name>\n` +
        `${fieldIndent}<description></description>\n` +
        `${fieldIndent}<defaultValue>${escapeXmlText(defaultValue)}</defaultValue>\n` +
        `${fieldIndent}<trim>true</trim>\n` +
        `${paramIndent}</hudson.model.StringParameterDefinition>`);
}
function parameterPropertyXml(indent: string): string {
    const paramIndent = `${indent}      `;
    const params = PARAMETER_DEFINITIONS.map(([name, defaultValue]) => stringParameterDefinitionXml(paramIndent, name, defaultValue));
    return (`${indent}<hudson.model.ParametersDefinitionProperty>\n` +
        `${indent}  <parameterDefinitions>\n` +
        `${params.join("\n")}\n` +
        `${indent}  </parameterDefinitions>\n` +
        `${indent}</hudson.model.ParametersDefinitionProperty>`);
}
function jobDefinesStringParameter(xml: string, name: string): boolean {
    const token = `<name>${escapeXmlText(name)}</name>`;
    return xml
        .split("<hudson.model.StringParameterDefinition>")
        .some((chunk) => chunk.includes(token));
}
function mergeMissingParameterDefinitions(xml: string): string {
    const closeRe = /\n([\t ]*)<\/parameterDefinitions>/;
    const m = closeRe.exec(xml);
    if (!m) {
        return xml;
    }
    const paramBlockIndent = `${m[1]}  `;
    const missing = PARAMETER_DEFINITIONS.filter(([n]) => !jobDefinesStringParameter(xml, n));
    if (!missing.length) {
        return xml;
    }
    const blocks = missing
        .map(([n, dv]) => stringParameterDefinitionXml(paramBlockIndent, n, dv))
        .join("\n");
    return xml.replace(closeRe, `\n${blocks}\n${m[1]}</parameterDefinitions>`);
}
function ensureParameterizedJobXml(xml: string): string {
    let out = xml;
    if (!out.includes("hudson.model.ParametersDefinitionProperty")) {
        const prop = parameterPropertyXml("    ");
        if (/<properties\s*\/>/.test(out)) {
            out = out.replace(/<properties\s*\/>/, `<properties>\n${prop}\n  </properties>`);
        }
        else if (out.includes("</properties>")) {
            out = out.replace("</properties>", `${prop}\n  </properties>`);
        }
        else {
            out = out.replace("<keepDependencies>false</keepDependencies>", `<keepDependencies>false</keepDependencies>\n  <properties>\n${prop}\n  </properties>`);
        }
    }
    return mergeMissingParameterDefinitions(out);
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
        `  <description>paas-deploy</description>\n` +
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
    let last: {
        status: number;
        body: string;
    } = { status: 0, body: "" };
    for (let attempt = 1; attempt <= JENKINS_BOOT_MAX_ATTEMPTS; attempt++) {
        last = await jenkinsReq(base, "/api/json", { method: "GET" }, authHeader, jar);
        if (last.status === 200) {
            return last;
        }
        if (last.status === 401) {
            throw new IntegrationError(`Jenkins auth failed (401) at ${base}`);
        }
        if (last.status === 403) {
            throw new IntegrationError(`Jenkins forbidden (403) at ${base} — check JENKINS_BASE_URL`);
        }
        if (looksLikeJenkinsStarting(last.status, last.body) && attempt < JENKINS_BOOT_MAX_ATTEMPTS) {
            await sleepMs(JENKINS_BOOT_RETRY_MS);
            continue;
        }
        break;
    }
    const waitedSec = Math.ceil(((JENKINS_BOOT_MAX_ATTEMPTS - 1) * JENKINS_BOOT_RETRY_MS) / 1000);
    if (looksLikeJenkinsStarting(last.status, last.body)) {
        throw new IntegrationError(`Jenkins not ready (${last.status}) after ${waitedSec}s`);
    }
    throw new IntegrationError(`Jenkins unreachable: HTTP ${last.status} at ${base}`);
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
