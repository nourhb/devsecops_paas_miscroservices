import { env } from "@/server/config/env";
import { syncInlinePaasDeployJenkinsJobBeforeTrigger } from "@/server/jenkins/sync-inline-pipeline-job";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import { syncArgoApplication } from "@/server/services/argocd-service";
import { verifyImageWithCosign } from "@/server/security/cosign-verify";
import { evaluateOpaImagePolicy } from "@/server/security/opa-eval";
export type JenkinsBuildResult = {
    ok: boolean;
    buildNumber: number | null;
    buildLog: string;
    jobUrl?: string;
};
export type JenkinsProgressiveLogResult = {
    text: string;
    nextStart: number;
    moreData: boolean;
};
export type JenkinsDashboardBuild = {
    id: string;
    number: number;
    status: "QUEUED" | "RUNNING" | "SUCCESS" | "FAILED";
    building: boolean;
    result: string | null;
    url: string | null;
    timestamp: string | null;
    durationMs: number | null;
};
export interface DockerHubTagInfo {
    name: string;
    lastUpdated: string | null;
}
function jenkinsBaseUrl(): string {
    return env.JENKINS_BASE_URL.replace(/\/$/, "");
}
function jenkinsAuthHeader(): string {
    return `Basic ${Buffer.from(`${env.JENKINS_USERNAME}:${env.JENKINS_API_TOKEN}`).toString("base64")}`;
}
function appendSharedJobAgentLabel(q: URLSearchParams): void {
    const label = env.JENKINS_AGENT_LABEL.trim();
    if (!label) {
        return;
    }
    const param = env.JENKINS_AGENT_LABEL_PARAMETER.trim() || "JENKINS_AGENT_LABEL";
    q.set(param, label);
}
function appendRegistryParameters(q: URLSearchParams): void {
    const values: Record<string, string> = {
        DOCKERHUB_USERNAME: env.DOCKERHUB_USERNAME,
        DOCKERHUB_TOKEN: env.DOCKERHUB_TOKEN,
        HARBOR_REGISTRY: env.HARBOR_REGISTRY,
        HARBOR_USERNAME: env.HARBOR_USERNAME,
        HARBOR_PASSWORD: env.HARBOR_PASSWORD,
        SONAR_HOST_URL: env.SONAR_BASE_URL,
        SONAR_TOKEN: env.SONAR_TOKEN,
        DEPENDENCY_TRACK_BASE_URL: env.DEPENDENCY_TRACK_BASE_URL,
        DEPENDENCY_TRACK_API_KEY: env.DEPENDENCY_TRACK_API_KEY,
        BUILD_PACKAGE_PROXY_URL: env.BUILD_PACKAGE_PROXY_URL,
        NPM_CONFIG_REGISTRY: env.BUILD_NPM_REGISTRY,
        ARTIFACTORY_URL: env.ARTIFACTORY_URL,
        ARTIFACTORY_REPOSITORY: env.ARTIFACTORY_REPOSITORY,
        ARTIFACTORY_USERNAME: env.ARTIFACTORY_USERNAME,
        ARTIFACTORY_PASSWORD: env.ARTIFACTORY_PASSWORD,
        ARTIFACTORY_ACCESS_TOKEN: env.ARTIFACTORY_ACCESS_TOKEN,
        ARTIFACTORY_CREDENTIALS_ID: env.ARTIFACTORY_CREDENTIALS_ID,
        COSIGN_CREDENTIALS_ID: env.COSIGN_CREDENTIALS_ID,
        HELM_OCI_PROJECT: env.HELM_OCI_PROJECT,
        NVD_API_KEY: env.NVD_API_KEY,
        ZAP_TARGET_URL: env.ZAP_TARGET_URL
    };
    for (const [key, value] of Object.entries(values)) {
        const normalized = value.trim();
        if (normalized) {
            q.set(key, normalized);
        }
    }
    if (env.HELM_OCI_INSECURE === "true") {
        q.set("HELM_OCI_INSECURE", "true");
    }
    if (env.HELM_OCI_PLAIN_HTTP === "true") {
        q.set("HELM_OCI_PLAIN_HTTP", "true");
    }
}
function redactJenkinsUrl(url: string): string {
    try {
        const u = new URL(url);
        for (const key of [...u.searchParams.keys()]) {
            if (/TOKEN|PASSWORD|PASS|SECRET|API_KEY|NVD_API/i.test(key)) {
                u.searchParams.set(key, "REDACTED");
            }
        }
        return u.toString();
    }
    catch {
        return url.replace(/((?:TOKEN|PASSWORD|PASS|SECRET|API_KEY)[^=&]*=)[^&\s]+/gi, "$1REDACTED");
    }
}
function jenkinsIntegrationFetch(url: string, init?: RequestInit): Promise<Response> {
    return integrationFetch(url, init ?? {}, env.JENKINS_HTTP_TIMEOUT_MS);
}
function describeJenkinsFetchFailure(error: unknown): string {
    if (!(error instanceof Error)) {
        return String(error);
    }
    const cause = "cause" in error && error.cause instanceof Error ? error.cause.message : "";
    return cause ? `${error.message} (${cause})` : error.message;
}
export type JenkinsJobKind = "build" | "deploy";
export function resolveJenkinsJobNameForProject(projectName: string, projectId: string, kind: JenkinsJobKind = "build"): string {
    return jenkinsJobName(projectName, projectId, kind);
}
function projectScopedJenkinsJobName(projectName: string, projectId: string): string {
    if (env.JENKINS_JOB_NAME_SOURCE === "uuid") {
        return projectId;
    }
    const safe = projectName
        .replace(/[^a-zA-Z0-9._-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "") || "project";
    return safe;
}
function jenkinsJobName(projectName: string, projectId: string, kind: JenkinsJobKind = "build"): string {
    const buildOverride = env.JENKINS_BUILD_JOB_NAME.trim();
    const deployOverride = env.JENKINS_DEPLOY_JOB_NAME.trim();
    if (kind === "build" && buildOverride) {
        return buildOverride;
    }
    if (kind === "deploy" && deployOverride) {
        return deployOverride;
    }
    return projectScopedJenkinsJobName(projectName, projectId);
}
function jenkinsFolderSegments(): string[] {
    const folder = env.JENKINS_JOB_FOLDER?.trim();
    return folder ? folder.split("/").filter(Boolean) : [];
}
function jenkinsJobPathSegments(extra: string[]): string {
    return [...jenkinsFolderSegments(), ...extra].map((s) => `job/${encodeURIComponent(s)}`).join("/");
}
function jenkinsJobUrlPath(projectName: string, projectId: string, kind: JenkinsJobKind = "build"): string {
    return jenkinsJobPathSegments([jenkinsJobName(projectName, projectId, kind)]);
}
function dashboardJenkinsJobPath(jobName: string): string {
    return jenkinsJobPathSegments(jobName.split("/").filter(Boolean));
}
function parseQueueItemId(location: string | null): string | null {
    if (!location) {
        return null;
    }
    const match = location.match(/\/queue\/item\/(\d+)\/?$/);
    return match?.[1] ?? null;
}
function dashboardBuildStatus(result: string | null, building: boolean): "QUEUED" | "RUNNING" | "SUCCESS" | "FAILED" {
    if (building) {
        return "RUNNING";
    }
    if (result === null) {
        return "QUEUED";
    }
    if (result === "SUCCESS") {
        return "SUCCESS";
    }
    return "FAILED";
}
function mapDashboardBuild(row: {
    id?: string | number;
    number?: number;
    result?: string | null;
    building?: boolean;
    url?: string | null;
    timestamp?: number | null;
    duration?: number | null;
}): JenkinsDashboardBuild | null {
    if (typeof row.number !== "number") {
        return null;
    }
    const building = Boolean(row.building);
    const result = row.result ?? null;
    return {
        id: String(row.id ?? row.number),
        number: row.number,
        status: dashboardBuildStatus(result, building),
        building,
        result,
        url: row.url ?? null,
        timestamp: typeof row.timestamp === "number" ? new Date(row.timestamp).toISOString() : null,
        durationMs: typeof row.duration === "number" ? row.duration : null
    };
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
    const firstCookie = setCookie.split(";")[0]?.trim();
    return firstCookie || null;
}
async function jenkinsFetchCrumb(base: string, headers: Record<string, string>): Promise<{
    crumb: string;
    crumbRequestField: string;
    cookieHeader: string | null;
} | null> {
    try {
        const response = await jenkinsIntegrationFetch(`${base}/crumbIssuer/api/json`, { headers });
        if (!response.ok) {
            return null;
        }
        const data = (await response.json()) as {
            crumb?: string;
            crumbRequestField?: string;
        };
        if (data.crumb && data.crumbRequestField) {
            return {
                crumb: data.crumb,
                crumbRequestField: data.crumbRequestField,
                cookieHeader: extractCookieHeader(response)
            };
        }
    }
    catch {
    }
    return null;
}
export interface SeverityBreakdown {
  critical: number;
  high: number;
  medium: number;
  low: number;
}
export interface DependencyTrackFinding {
    title: string;
    severity: "CRITICAL" | "HIGH" | "MEDIUM" | "LOW";
    component: string | null;
    vulnerabilityId: string | null;
    recommendation: string | null;
}
export interface DependencyTrackProjectMetrics {
    projectUuid: string | null;
    projectName: string;
    metrics: SeverityBreakdown;
    findings: DependencyTrackFinding[];
}
function hash(input: string): number {
  return Array.from(input).reduce((acc, char) => acc + char.charCodeAt(0), 0);
}
function seeded(input: string, max: number): number {
  return hash(input) % (max + 1);
}
type IntegrationFetchFn = (url: string, init?: RequestInit) => Promise<Response>;
async function fetchOrFallback<T>(serviceLabel: string, enabled: boolean, url: string, init: RequestInit, fallback: T, parser?: (response: Response) => Promise<T>, fetchImpl: IntegrationFetchFn = integrationFetch): Promise<T> {
    if (!enabled) {
        return fallback;
    }
  try {
        const response = await fetchImpl(url, init);
    if (!response.ok) {
            const errText = await response.text();
            if (!allowSimulation()) {
                throw new IntegrationError(`${serviceLabel} HTTP ${response.status}: ${errText.slice(0, 800)}`);
            }
      return fallback;
    }
    if (parser) {
      return parser(response);
    }
    return (await response.json()) as T;
    }
    catch (e) {
        if (e instanceof IntegrationError) {
            throw e;
        }
        if (!allowSimulation()) {
            throw new IntegrationError(`${serviceLabel} request failed: ${e instanceof Error ? e.message : String(e)}`);
        }
    return fallback;
  }
}
export class JenkinsClient {
    private enabled = Boolean(env.JENKINS_BASE_URL && env.JENKINS_USERNAME && env.JENKINS_API_TOKEN);
  async createPipeline(projectName: string) {
        if (!this.enabled) {
            return { created: true as const };
        }
        const sharedBuildJob = env.JENKINS_BUILD_JOB_NAME.trim();
        if (sharedBuildJob) {
            return { created: true as const };
        }
        const base = jenkinsBaseUrl();
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        try {
            const crumb = await jenkinsFetchCrumb(base, headers);
            if (crumb) {
                headers[crumb.crumbRequestField] = crumb.crumb;
                if (crumb.cookieHeader) {
                    headers.Cookie = crumb.cookieHeader;
                }
            }
            const url = `${base}/createItem?name=${encodeURIComponent(projectName)}`;
            const response = await jenkinsIntegrationFetch(url, { method: "POST", headers });
            if (!response.ok && response.status !== 302) {
                const text = await response.text();
                if (allowSimulation()) {
                    return { created: true as const };
                }
                throw new IntegrationError(`Jenkins createItem failed (${response.status}): ${text.slice(0, 800)}`);
            }
            return { created: true as const };
        }
        catch (e) {
            if (e instanceof IntegrationError) {
                throw e;
            }
            const detail = describeJenkinsFetchFailure(e);
            if (allowSimulation()) {
                return { created: true as const };
            }
            throw new IntegrationError(`Jenkins createPipeline failed (${detail}). Check JENKINS_BASE_URL from this host, or set DEVSECOPS_ALLOW_SIMULATION=true for local demo.`);
        }
    }
    async triggerBuild(projectName: string, projectId: string, buildParams: {
        branch: string;
        gitUrl: string;
        gitCredentialsId?: string | null;
        imageName: string;
        projectUuid: string;
    }): Promise<JenkinsBuildResult> {
        const simulated: JenkinsBuildResult = {
            ok: true,
            buildNumber: Math.floor(Date.now() / 1000) % 1000000,
            buildLog: `[jenkins] Simulated build for job "${jenkinsJobName(projectName, projectId, "build")}" branch ${buildParams.branch}`
        };
        if (!this.enabled) {
            if (!allowSimulation()) {
                throw new IntegrationError("Jenkins is required in production: set JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (or JENKINS_URL / JENKINS_USER / JENKINS_TOKEN).");
            }
            return simulated;
        }
        try {
            const base = jenkinsBaseUrl();
            const jobPath = jenkinsJobUrlPath(projectName, projectId, "build");
            const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
            const crumb = await jenkinsFetchCrumb(base, headers);
            if (crumb) {
                headers[crumb.crumbRequestField] = crumb.crumb;
                if (crumb.cookieHeader) {
                    headers.Cookie = crumb.cookieHeader;
                }
            }
            const useSimple = env.JENKINS_USE_SIMPLE_BUILD === "true";
            const sharedBuildJob = env.JENKINS_BUILD_JOB_NAME.trim();
            const triggerUrl = (() => {
                if (useSimple) {
                    return `${base}/${jobPath}/build`;
                }
                const q = new URLSearchParams();
                q.set(env.JENKINS_BRANCH_PARAMETER, buildParams.branch);
                if (sharedBuildJob) {
                    q.set(env.JENKINS_DEPLOY_GIT_URL_PARAMETER, buildParams.gitUrl);
                    q.set(env.JENKINS_DEPLOY_BRANCH_PARAMETER, buildParams.branch);
                    q.set(env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER, buildParams.imageName);
                    q.set(env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER, buildParams.projectUuid);
                    q.set(env.JENKINS_DEPLOY_GIT_CREDENTIALS_ID_PARAMETER, (buildParams.gitCredentialsId ?? "").trim());
                    appendSharedJobAgentLabel(q);
                    appendRegistryParameters(q);
                }
                return `${base}/${jobPath}/buildWithParameters?${q.toString()}`;
            })();
            const triggerRes = await jenkinsIntegrationFetch(triggerUrl, { method: "POST", headers });
            if (!triggerRes.ok) {
                const errBody = await triggerRes.text();
                if (allowSimulation()) {
                    return simulated;
                }
                return {
                    ok: false,
                    buildNumber: null,
                    buildLog: `[jenkins] POST ${redactJenkinsUrl(triggerUrl)}\nHTTP ${triggerRes.status}\n${errBody.slice(0, 12000)}`,
                    jobUrl: `${base}/${jobPath}`
                };
            }
            await new Promise((r) => setTimeout(r, 1500));
            let lastNumber: number | null = null;
            try {
                const lastRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,result,url`, {
                    headers
                });
                if (lastRes.ok) {
                    const json = (await lastRes.json()) as {
                        number?: number;
                    };
                    if (typeof json.number === "number") {
                        lastNumber = json.number;
                    }
                }
            }
            catch {
            }
            let consoleTail = "";
            if (lastNumber != null) {
                try {
                    const consoleRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${lastNumber}/consoleText`, { headers });
                    if (consoleRes.ok) {
                        const text = await consoleRes.text();
                        consoleTail = text.length > 24000 ? text.slice(-24000) : text;
                    }
                }
                catch {
                }
            }
            const log = [
                `[jenkins] Triggered: ${redactJenkinsUrl(triggerUrl)}`,
                `[jenkins] HTTP ${triggerRes.status}`,
                lastNumber != null ? `[jenkins] Last build #${lastNumber}` : "[jenkins] No lastBuild yet",
                consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
            ].join("\n");
            return {
                ok: true,
                buildNumber: lastNumber,
                buildLog: log,
                jobUrl: `${base}/${jobPath}`
            };
        }
        catch (e) {
            if (e instanceof IntegrationError) {
                throw e;
            }
            const detail = describeJenkinsFetchFailure(e);
            if (allowSimulation()) {
                return simulated;
            }
            throw new IntegrationError(`Jenkins build trigger failed (${detail}). Check JENKINS_BASE_URL from this host, or set DEVSECOPS_ALLOW_SIMULATION=true for local demo.`);
        }
    }
    async triggerDeployJob(projectName: string, projectId: string, deployParams: {
        gitUrl: string;
        branch: string;
        gitCredentialsId?: string | null;
        imageName: string;
        projectUuid: string;
    }): Promise<JenkinsBuildResult> {
        const simulated: JenkinsBuildResult = {
            ok: true,
            buildNumber: Math.floor(Date.now() / 1000) % 1000000,
            buildLog: `[jenkins] Simulated deploy job "${jenkinsJobName(projectName, projectId, "deploy")}"`
        };
        if (!this.enabled) {
            if (!allowSimulation()) {
                throw new IntegrationError("Jenkins is required in production: set JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (or JENKINS_URL / JENKINS_USER / JENKINS_TOKEN).");
            }
            return simulated;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, "deploy");
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        try {
            const crumb = await jenkinsFetchCrumb(base, headers);
            if (crumb) {
                headers[crumb.crumbRequestField] = crumb.crumb;
                if (crumb.cookieHeader) {
                    headers.Cookie = crumb.cookieHeader;
                }
            }
            const q = new URLSearchParams();
            q.set(env.JENKINS_DEPLOY_GIT_URL_PARAMETER, deployParams.gitUrl);
            q.set(env.JENKINS_DEPLOY_BRANCH_PARAMETER, deployParams.branch);
            q.set(env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER, deployParams.imageName);
            q.set(env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER, deployParams.projectUuid);
            q.set(env.JENKINS_DEPLOY_GIT_CREDENTIALS_ID_PARAMETER, (deployParams.gitCredentialsId ?? "").trim());
            appendSharedJobAgentLabel(q);
            appendRegistryParameters(q);
            const triggerUrl = `${base}/${jobPath}/buildWithParameters?${q.toString()}`;
            const triggerRes = await jenkinsIntegrationFetch(triggerUrl, { method: "POST", headers });
            if (!triggerRes.ok) {
                const errBody = await triggerRes.text();
                if (allowSimulation()) {
                    return simulated;
                }
                return {
                    ok: false,
                    buildNumber: null,
                    buildLog: `[jenkins] POST ${redactJenkinsUrl(triggerUrl)}\nHTTP ${triggerRes.status}\n${errBody.slice(0, 12000)}`,
                    jobUrl: `${base}/${jobPath}`
                };
            }
            await new Promise((r) => setTimeout(r, 1500));
            let lastNumber: number | null = null;
            try {
                const lastRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,result,url`, {
                    headers
                });
                if (lastRes.ok) {
                    const json = (await lastRes.json()) as {
                        number?: number;
                    };
                    if (typeof json.number === "number") {
                        lastNumber = json.number;
                    }
                }
            }
            catch {
            }
            let consoleTail = "";
            if (lastNumber != null) {
                try {
                    const consoleRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${lastNumber}/consoleText`, { headers });
                    if (consoleRes.ok) {
                        const text = await consoleRes.text();
                        consoleTail = text.length > 24000 ? text.slice(-24000) : text;
                    }
                }
                catch {
                }
            }
            const log = [
                `[jenkins] Deploy trigger: ${redactJenkinsUrl(triggerUrl)}`,
                `[jenkins] HTTP ${triggerRes.status}`,
                lastNumber != null ? `[jenkins] Last build #${lastNumber}` : "[jenkins] No lastBuild yet",
                consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
            ].join("\n");
            return {
                ok: true,
                buildNumber: lastNumber,
                buildLog: log,
                jobUrl: `${base}/${jobPath}`
            };
        }
        catch (e) {
            if (e instanceof IntegrationError) {
                throw e;
            }
            const detail = describeJenkinsFetchFailure(e);
            if (allowSimulation()) {
                return simulated;
            }
            throw new IntegrationError(`Jenkins deploy trigger failed (${detail}). Check JENKINS_BASE_URL from this host, or set DEVSECOPS_ALLOW_SIMULATION=true for local demo.`);
        }
    }
    async getLastBuildSummary(projectName: string, projectId: string, kind: JenkinsJobKind = "build"): Promise<{
        number: number;
        building: boolean;
        result: string | null;
    } | null> {
        if (!this.enabled) {
            return null;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,building,result`, {
                headers
            });
            if (!res.ok) {
                return null;
            }
            const j = (await res.json()) as {
                number?: number;
                building?: boolean;
                result?: string | null;
            };
            if (typeof j.number !== "number") {
                return null;
            }
            return {
                number: j.number,
                building: Boolean(j.building),
                result: j.result ?? null
            };
        }
        catch {
            return null;
        }
    }
    async getBuildApiJson(projectName: string, projectId: string, buildNumber: number, kind: JenkinsJobKind = "build"): Promise<{
        number: number;
        building: boolean;
        result: string | null;
    } | null> {
        if (!this.enabled) {
            return null;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/api/json?tree=number,result,building`, { headers });
            if (!res.ok) {
                return null;
            }
            const j = (await res.json()) as {
                number?: number;
                building?: boolean;
                result?: string | null;
            };
            if (typeof j.number !== "number") {
                return null;
            }
            return {
                number: j.number,
                building: Boolean(j.building),
                result: j.result ?? null
            };
        }
        catch {
            return null;
        }
    }
    /** Stop a running build (#N). Uses POST .../stop with CSRF crumb. */
    async stopBuild(projectName: string, projectId: string, buildNumber: number, kind: JenkinsJobKind = "deploy"): Promise<{
        ok: boolean;
        detail: string;
    }> {
        if (!this.enabled) {
            if (allowSimulation()) {
                return { ok: true, detail: "simulated" };
            }
            return { ok: false, detail: "Jenkins is not configured." };
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        try {
            const crumb = await jenkinsFetchCrumb(base, headers);
            if (crumb) {
                headers[crumb.crumbRequestField] = crumb.crumb;
                if (crumb.cookieHeader) {
                    headers.Cookie = crumb.cookieHeader;
                }
            }
            const url = `${base}/${jobPath}/${buildNumber}/stop`;
            const res = await jenkinsIntegrationFetch(url, { method: "POST", headers });
            const detail = (await res.text()).slice(0, 1200);
            if (res.ok || res.status === 302 || res.status === 303) {
                return { ok: true, detail };
            }
            if (res.status === 404) {
                return { ok: true, detail: "Build not found (may have already finished)." };
            }
            return { ok: false, detail: `HTTP ${res.status}: ${detail}` };
        }
        catch (e) {
            return { ok: false, detail: e instanceof Error ? e.message : String(e) };
        }
    }
    /**
     * Cancel queued (not yet assigned a build #) runs for this job.
     * POST /queue/item/:id/cancelQueue for each queue item whose task URL matches the job.
     */
    async cancelQueuedPipelineItems(projectName: string, projectId: string, kind: JenkinsJobKind = "deploy"): Promise<{
        cancelled: number;
        detail: string;
    }> {
        if (!this.enabled) {
            if (allowSimulation()) {
                return { cancelled: 1, detail: "simulated" };
            }
            return { cancelled: 0, detail: "Jenkins is not configured." };
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const jobPrefix = `${base}/${jobPath}`.replace(/\/$/, "");
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        try {
            const crumb = await jenkinsFetchCrumb(base, headers);
            if (crumb) {
                headers[crumb.crumbRequestField] = crumb.crumb;
                if (crumb.cookieHeader) {
                    headers.Cookie = crumb.cookieHeader;
                }
            }
            const qRes = await jenkinsIntegrationFetch(`${base}/queue/api/json?tree=items[id,task[url]]`, { headers });
            if (!qRes.ok) {
                return { cancelled: 0, detail: `queue/api/json HTTP ${qRes.status}` };
            }
            const payload = (await qRes.json()) as {
                items?: Array<{ id?: number; task?: { url?: string } }>;
            };
            let cancelled = 0;
            for (const item of payload.items ?? []) {
                const id = item.id;
                const taskUrl = item.task?.url?.replace(/\/$/, "") ?? "";
                if (typeof id !== "number" || !taskUrl) {
                    continue;
                }
                if (taskUrl === jobPrefix || taskUrl.startsWith(`${jobPrefix}/`)) {
                    const cRes = await jenkinsIntegrationFetch(`${base}/queue/item/${id}/cancelQueue`, { method: "POST", headers });
                    if (cRes.ok || cRes.status === 302 || cRes.status === 303) {
                        cancelled += 1;
                    }
                }
            }
            return { cancelled, detail: cancelled ? `Cancelled ${cancelled} queued run(s).` : "No matching queued items." };
        }
        catch (e) {
            return { cancelled: 0, detail: e instanceof Error ? e.message : String(e) };
        }
    }
    async getBuildConsoleText(projectName: string, projectId: string, buildNumber: number, kind: JenkinsJobKind = "build"): Promise<string | null> {
        if (!this.enabled) {
            return null;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/consoleText`, { headers });
            if (!res.ok) {
                return null;
            }
            return await res.text();
        }
        catch {
            return null;
        }
    }
    async getBuildConsoleProgressiveText(projectName: string, projectId: string, buildNumber: number, start: number, kind: JenkinsJobKind = "build"): Promise<JenkinsProgressiveLogResult | null> {
        if (!this.enabled) {
            return null;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/logText/progressiveText?start=${encodeURIComponent(String(start))}`, { headers });
            if (!res.ok) {
                return null;
            }
            const text = await res.text();
            const nextStartRaw = res.headers.get("X-Text-Size");
            const moreDataRaw = res.headers.get("X-More-Data");
            const nextStartParsed = nextStartRaw ? Number(nextStartRaw) : NaN;
            return {
                text,
                nextStart: Number.isFinite(nextStartParsed) ? nextStartParsed : start + text.length,
                moreData: moreDataRaw === "true"
            };
        }
        catch {
            return null;
        }
    }
    async triggerDashboardBuild(jobName: string, params: Record<string, string>): Promise<{
        accepted: boolean;
        jobName: string;
        queueId: string | null;
        buildNumber: number | null;
        jobUrl: string | null;
    }> {
        if (!this.enabled) {
            if (!allowSimulation()) {
                throw new IntegrationError("Jenkins is required in production: set JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN.");
            }
            return {
                accepted: true,
                jobName,
                queueId: `sim-${Date.now()}`,
                buildNumber: Math.floor(Date.now() / 1000) % 1000000,
                jobUrl: null
            };
        }
        await syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName);
        const base = jenkinsBaseUrl();
        const jobPath = dashboardJenkinsJobPath(jobName);
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        const crumb = await jenkinsFetchCrumb(base, headers);
        if (crumb) {
            headers[crumb.crumbRequestField] = crumb.crumb;
            if (crumb.cookieHeader) {
                headers.Cookie = crumb.cookieHeader;
            }
        }
        const query = new URLSearchParams();
        for (const [key, value] of Object.entries(params)) {
            const normalized = String(value ?? "").trim();
            if (!normalized) {
                continue;
            }
            query.set(key, normalized);
        }
        const triggerUrl = query.size > 0
            ? `${base}/${jobPath}/buildWithParameters?${query.toString()}`
            : `${base}/${jobPath}/build`;
        const response = await jenkinsIntegrationFetch(triggerUrl, { method: "POST", headers });
        if (!response.ok) {
            const detail = await response.text();
            throw new IntegrationError(`Jenkins build trigger failed (${response.status})`, {
                details: detail.slice(0, 1200)
            });
        }
        const queueLocation = response.headers.get("location");
        const queueId = parseQueueItemId(queueLocation);
        let buildNumber: number | null = null;
        if (queueId) {
            for (let attempt = 0; attempt < 8; attempt += 1) {
                try {
                    const queueResponse = await jenkinsIntegrationFetch(`${base}/queue/item/${queueId}/api/json?tree=cancelled,why,executable[number,url]`, { headers });
                    if (queueResponse.ok) {
                        const queuePayload = (await queueResponse.json()) as {
                            executable?: {
                                number?: number;
                            };
                        };
                        if (typeof queuePayload.executable?.number === "number") {
                            buildNumber = queuePayload.executable.number;
                            break;
                        }
                    }
                }
                catch {
                }
                await new Promise((resolve) => setTimeout(resolve, 1000));
            }
        }
        return {
            accepted: true,
            jobName,
            queueId,
      buildNumber,
            jobUrl: `${base}/${jobPath}`
        };
    }
    async listDashboardBuilds(jobName: string, limit = 20): Promise<JenkinsDashboardBuild[]> {
        if (!this.enabled) {
            return [];
        }
        const base = jenkinsBaseUrl();
        const jobPath = dashboardJenkinsJobPath(jobName);
        const headers = { Authorization: jenkinsAuthHeader() };
        const response = await jenkinsIntegrationFetch(`${base}/${jobPath}/api/json?tree=builds[number,id,result,building,url,timestamp,duration]`, { headers });
        if (!response.ok) {
            const detail = await response.text();
            throw new IntegrationError(`Jenkins builds lookup failed (${response.status})`, {
                details: detail.slice(0, 1200)
            });
        }
        const payload = (await response.json()) as {
            builds?: Array<{
                id?: string | number;
                number?: number;
                result?: string | null;
                building?: boolean;
                url?: string | null;
                timestamp?: number | null;
                duration?: number | null;
            }>;
        };
        return (payload.builds ?? [])
            .map(mapDashboardBuild)
            .filter((row): row is JenkinsDashboardBuild => row !== null)
            .sort((a, b) => b.number - a.number)
            .slice(0, limit);
    }
    async getDashboardBuildLogs(jobName: string, buildId: string): Promise<{
        id: string;
        logs: string;
    }> {
        if (!this.enabled) {
            return {
                id: buildId,
                logs: allowSimulation()
                    ? `[simulation] Logs for ${jobName} #${buildId}`
                    : ""
            };
        }
        const buildNumber = Number.parseInt(buildId, 10);
        if (!Number.isFinite(buildNumber)) {
            throw new IntegrationError("Invalid Jenkins build id.");
        }
        const base = jenkinsBaseUrl();
        const jobPath = dashboardJenkinsJobPath(jobName);
        const headers = { Authorization: jenkinsAuthHeader() };
        const response = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/consoleText`, { headers });
        if (!response.ok) {
            const detail = await response.text();
            throw new IntegrationError(`Jenkins log lookup failed (${response.status})`, {
                details: detail.slice(0, 1200)
            });
        }
        return {
            id: buildId,
            logs: await response.text()
        };
    }
}
export class SonarQubeClient {
  private enabled = Boolean(env.SONAR_BASE_URL);
    async qualityGate(projectKey: string): Promise<{
        status: "PASSED" | "FAILED";
    }> {
    const fallbackStatus = projectKey.toLowerCase().includes("fail-sonar") ? "FAILED" : "PASSED";
        return fetchOrFallback("SonarQube", this.enabled, `${env.SONAR_BASE_URL}/api/qualitygates/project_status?projectKey=${encodeURIComponent(projectKey)}`, {
        method: "GET",
        headers: {
          Authorization: `Basic ${Buffer.from(`${env.SONAR_TOKEN}:`).toString("base64")}`
        }
        }, { status: fallbackStatus }, async (response) => {
            const data = (await response.json()) as {
                projectStatus?: {
                    status?: string;
                };
            };
        return { status: data.projectStatus?.status === "OK" ? "PASSED" : "FAILED" };
        });
  }
}
export class DependencyTrackClient {
  private enabled = Boolean(env.DEPENDENCY_TRACK_BASE_URL);
    private headers() {
        return {
            "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY
        };
    }
    private async resolveProjectUuid(projectKey: string): Promise<string | null> {
        if (!this.enabled) {
            return null;
        }
        const response = await integrationFetch(`${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/project?name=${encodeURIComponent(projectKey)}`, {
            method: "GET",
            headers: this.headers()
        });
        if (!response.ok) {
            return null;
        }
        const payload = (await response.json()) as Array<{
            uuid?: string;
            name?: string;
        }>;
        const project = Array.isArray(payload)
            ? payload.find((item) => item.name?.toLowerCase() === projectKey.toLowerCase()) || payload[0]
            : null;
        return project?.uuid ?? null;
    }
    private async findProjectFindings(projectKey: string): Promise<DependencyTrackFinding[]> {
        const fallback: DependencyTrackFinding[] = projectKey.toLowerCase().includes("log4j")
            ? [
                {
                    title: "Critical vulnerability found in log4j",
                    severity: "CRITICAL",
                    component: "log4j",
                    vulnerabilityId: "CVE-simulated-log4j",
                    recommendation: "Upgrade log4j to a patched version and redeploy."
                }
            ]
            : [];
        return fetchOrFallback("Dependency-Track findings", this.enabled, `${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/finding/project/${encodeURIComponent(projectKey)}`, {
            method: "GET",
            headers: this.headers()
        }, fallback, async (response) => {
            const rows = (await response.json()) as Array<{
                severity?: string;
                vulnerability?: {
                    vulnId?: string;
                    title?: string;
                    description?: string;
                };
                component?: {
                    name?: string;
                };
            }>;
            const findings = (Array.isArray(rows) ? rows : [])
                .map((row): DependencyTrackFinding | null => {
                const severity = String(row.severity || "").toUpperCase();
                if (!["CRITICAL", "HIGH", "MEDIUM", "LOW"].includes(severity)) {
                    return null;
                }
                return {
                    title: row.vulnerability?.title || row.vulnerability?.vulnId || "Dependency vulnerability",
                    severity: severity as DependencyTrackFinding["severity"],
                    component: row.component?.name ?? null,
                    vulnerabilityId: row.vulnerability?.vulnId ?? null,
                    recommendation: row.vulnerability?.description
                        ? row.vulnerability.description.slice(0, 180)
                        : null
                };
            })
                .filter((row): row is DependencyTrackFinding => row !== null);
            return findings.slice(0, 5);
        });
    }
  async vulnerabilities(projectKey: string): Promise<SeverityBreakdown> {
    const fallback: SeverityBreakdown = {
      critical: seeded(projectKey + "-critical", 1),
      high: seeded(projectKey + "-high", 3),
      medium: seeded(projectKey + "-medium", 6),
      low: seeded(projectKey + "-low", 10)
    };
        return fetchOrFallback("Dependency-Track", this.enabled, `${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/finding/project/${encodeURIComponent(projectKey)}`, {
        method: "GET",
            headers: this.headers()
        }, fallback, async (response) => {
            const rows = (await response.json()) as {
                severity?: string;
            }[];
            const list = Array.isArray(rows) ? rows : [];
            const out: SeverityBreakdown = { critical: 0, high: 0, medium: 0, low: 0 };
            for (const row of list) {
                const s = (row.severity || "").toUpperCase();
                if (s === "CRITICAL") {
                    out.critical += 1;
                }
                else if (s === "HIGH") {
                    out.high += 1;
                }
                else if (s === "MEDIUM") {
                    out.medium += 1;
                }
                else if (s === "LOW") {
                    out.low += 1;
                }
            }
            return out;
        });
    }
    async projectMetrics(projectKey: string): Promise<DependencyTrackProjectMetrics> {
        const fallbackMetrics = await this.vulnerabilities(projectKey);
        const fallbackFindings = await this.findProjectFindings(projectKey);
        if (!this.enabled) {
            return {
                projectUuid: null,
                projectName: projectKey,
                metrics: fallbackMetrics,
                findings: fallbackFindings
            };
        }
        try {
            const projectUuid = await this.resolveProjectUuid(projectKey);
            if (!projectUuid) {
                return {
                    projectUuid: null,
                    projectName: projectKey,
                    metrics: fallbackMetrics,
                    findings: fallbackFindings
                };
            }
            const response = await integrationFetch(`${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/project/${encodeURIComponent(projectUuid)}/metrics`, {
                method: "GET",
                headers: this.headers()
            });
            if (!response.ok) {
                return {
                    projectUuid,
                    projectName: projectKey,
                    metrics: fallbackMetrics,
                    findings: fallbackFindings
                };
            }
            const payload = (await response.json()) as {
                critical?: number;
                high?: number;
                medium?: number;
                low?: number;
                findingsCritical?: number;
                findingsHigh?: number;
                findingsMedium?: number;
                findingsLow?: number;
            };
            return {
                projectUuid,
                projectName: projectKey,
                metrics: {
                    critical: Number(payload.critical ?? payload.findingsCritical ?? fallbackMetrics.critical),
                    high: Number(payload.high ?? payload.findingsHigh ?? fallbackMetrics.high),
                    medium: Number(payload.medium ?? payload.findingsMedium ?? fallbackMetrics.medium),
                    low: Number(payload.low ?? payload.findingsLow ?? fallbackMetrics.low)
                },
                findings: fallbackFindings
            };
        }
        catch {
            return {
                projectUuid: null,
                projectName: projectKey,
                metrics: fallbackMetrics,
                findings: fallbackFindings
            };
        }
    }
}
export class TrivyClient {
  private enabled = Boolean(env.TRIVY_BASE_URL);
  async scan(imageRef: string): Promise<SeverityBreakdown> {
    const critical = imageRef.toLowerCase().includes("critical") ? 1 : 0;
    const fallback: SeverityBreakdown = {
      critical,
      high: seeded(imageRef + "-high", 2),
      medium: seeded(imageRef + "-medium", 4),
      low: seeded(imageRef + "-low", 8)
    };
        return fetchOrFallback("Trivy", this.enabled, `${env.TRIVY_BASE_URL}/scan`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
                ...(env.TRIVY_AUTH_TOKEN ? { Authorization: `Bearer ${env.TRIVY_AUTH_TOKEN}` } : {})
        },
        body: JSON.stringify({ image: imageRef })
        }, fallback, async (response) => {
            const data = (await response.json()) as {
                Results?: {
                    Vulnerabilities?: {
                        Severity?: string;
                    }[];
                }[];
            };
            const out: SeverityBreakdown = { critical: 0, high: 0, medium: 0, low: 0 };
            const results = data.Results ?? [];
            for (const r of results) {
                for (const v of r.Vulnerabilities ?? []) {
                    const s = (v.Severity || "").toUpperCase();
                    if (s === "CRITICAL") {
                        out.critical += 1;
                    }
                    else if (s === "HIGH") {
                        out.high += 1;
                    }
                    else if (s === "MEDIUM") {
                        out.medium += 1;
                    }
                    else if (s === "LOW") {
                        out.low += 1;
                    }
                }
            }
            return out;
        });
    }
}
export class CosignClient {
  async isSigned(imageRef: string): Promise<boolean> {
        return verifyImageWithCosign(imageRef);
    }
}
export class OpaClient {
  async isAllowed(imageRef: string, signed: boolean): Promise<boolean> {
        return evaluateOpaImagePolicy(imageRef, signed);
    }
}
export class HarborClient {
  private enabled = Boolean(env.HARBOR_BASE_URL);
    async pushImage(imageRef: string): Promise<{
        pushed: boolean;
        imageRef: string;
    }> {
        return fetchOrFallback("Harbor", this.enabled, `${env.HARBOR_BASE_URL}/api/v2.0/projects/${encodeURIComponent(env.HARBOR_PROJECT)}/repositories`, {
        method: "GET",
        headers: {
          Authorization: `Basic ${Buffer.from(`${env.HARBOR_USERNAME}:${env.HARBOR_PASSWORD}`).toString("base64")}`
        }
        }, { pushed: true, imageRef }, async () => ({ pushed: true, imageRef }));
  }
}
export class ArgoCdClient {
  private enabled = Boolean(env.ARGOCD_BASE_URL);
    async sync(projectName: string): Promise<{
        status: string;
        logs: string;
    }> {
    const appName = `${env.ARGOCD_APP_PREFIX}-${projectName}`;
    const fallback = {
      status: "SYNCED",
      logs: `[argocd] Synced application ${appName}`
    };
        if (!this.enabled) {
            return fetchOrFallback("Argo CD sync", false, "", {}, fallback, async () => fallback);
        }
        try {
            const { logs } = await syncArgoApplication(projectName);
            return { status: "SYNCED", logs };
        }
        catch (e) {
            if (!allowSimulation()) {
                throw e;
            }
            return fallback;
        }
    }
    async applicationStatus(projectName: string): Promise<{
        health: string;
        syncStatus: string;
        appName: string;
    }> {
        const appName = `${env.ARGOCD_APP_PREFIX}-${projectName}`;
        const fallback = { health: "Healthy", syncStatus: "Synced", appName };
        return fetchOrFallback("Argo CD", this.enabled, `${env.ARGOCD_BASE_URL}/api/v1/applications/${encodeURIComponent(appName)}`, {
            method: "GET",
            headers: {
                Authorization: `Bearer ${env.ARGOCD_AUTH_TOKEN}`
            }
        }, fallback, async (response) => {
            const data = (await response.json()) as {
                status?: {
                    health?: {
                        status?: string;
                    };
                    sync?: {
                        status?: string;
                    };
                };
            };
            return {
                health: data.status?.health?.status ?? "Unknown",
                syncStatus: data.status?.sync?.status ?? "Unknown",
                appName
            };
        }, argocdIntegrationFetch);
    }
}
export class DockerHubClient {
    private enabled = Boolean(env.DOCKERHUB_USERNAME && env.DOCKERHUB_TOKEN);
    private jwtCache: {
        token: string;
        expiresAt: number;
    } | null = null;
    private async getJwt(): Promise<string | null> {
        if (!this.enabled) {
            return null;
        }
        const now = Date.now();
        if (this.jwtCache && this.jwtCache.expiresAt > now + 60000) {
            return this.jwtCache.token;
        }
        try {
            const response = await fetch("https://hub.docker.com/v2/users/login/", {
        method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    username: env.DOCKERHUB_USERNAME,
                    password: env.DOCKERHUB_TOKEN
                })
            });
            if (!response.ok) {
                this.jwtCache = null;
                return null;
            }
            const data = (await response.json()) as {
                token?: string;
            };
            if (!data.token) {
                return null;
            }
            this.jwtCache = { token: data.token, expiresAt: now + 23 * 60 * 60 * 1000 };
            return data.token;
        }
        catch {
            this.jwtCache = null;
            return null;
        }
    }
    async verifyCredentials(): Promise<{
        ok: boolean;
        message: string;
    }> {
        if (!this.enabled) {
            return { ok: true, message: "Docker Hub credentials not set — registry calls are skipped." };
        }
        const token = await this.getJwt();
        if (!token) {
            return { ok: false, message: "Docker Hub authentication failed (check username / access token)." };
        }
        return { ok: true, message: "Docker Hub JWT obtained successfully." };
    }
    async listRepositoryTags(namespace: string, repository: string): Promise<DockerHubTagInfo[]> {
        const token = await this.getJwt();
        if (!token) {
            return [];
        }
        const url = `https://hub.docker.com/v2/repositories/${encodeURIComponent(namespace)}/${encodeURIComponent(repository)}/tags?page_size=40`;
        try {
            const response = await fetch(url, {
                headers: { Authorization: `JWT ${token}` }
            });
            if (!response.ok) {
                return [];
            }
            const data = (await response.json()) as {
                results?: {
                    name: string;
                    last_updated?: string | null;
                }[];
            };
            return (data.results ?? []).map((row) => ({
                name: row.name,
                lastUpdated: row.last_updated ?? null
            }));
        }
        catch {
            return [];
        }
    }
    async getRepositoryMeta(namespace: string, repository: string): Promise<{
        description: string | null;
        pullCount: number;
    } | null> {
        const token = await this.getJwt();
        if (!token) {
            return null;
        }
        const url = `https://hub.docker.com/v2/repositories/${encodeURIComponent(namespace)}/${encodeURIComponent(repository)}`;
        try {
            const response = await fetch(url, {
                headers: { Authorization: `JWT ${token}` }
            });
            if (!response.ok) {
                return null;
            }
            const data = (await response.json()) as {
                description?: string | null;
                pull_count?: number;
            };
            return {
                description: data.description ?? null,
                pullCount: data.pull_count ?? 0
            };
        }
        catch {
            return null;
        }
    }
}
const PROM_DEFAULT_CPU_QUERY = '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))';
const PROM_DEFAULT_MEMORY_QUERY = "100 * (1 - (avg(node_memory_MemAvailable_bytes) / avg(node_memory_MemTotal_bytes)))";
function prometheusInstantScalar(payload: unknown): number | null {
    const data = payload as {
        data?: {
            result?: {
                value?: [
                    number,
                    string
                ];
            }[];
        };
    };
    const raw = data.data?.result?.[0]?.value?.[1];
    if (raw === undefined) {
        return null;
    }
    const n = Number.parseFloat(String(raw));
    if (!Number.isFinite(n)) {
        return null;
    }
    return Math.min(100, Math.max(0, n));
}
export class PrometheusClient {
  private enabled = Boolean(env.PROMETHEUS_BASE_URL);
    async clusterUsage(projectId: string): Promise<{
        cpu: number;
        ram: number;
    }> {
    const fallback = {
      cpu: 30 + seeded(projectId + "-cpu", 60),
      ram: 35 + seeded(projectId + "-ram", 55)
    };
        const base = env.PROMETHEUS_BASE_URL.replace(/\/$/, "");
        const cpuQuery = env.PROMETHEUS_QUERY_CPU.trim() || PROM_DEFAULT_CPU_QUERY;
        const memQuery = env.PROMETHEUS_QUERY_MEMORY.trim() || PROM_DEFAULT_MEMORY_QUERY;
        return fetchOrFallback("Prometheus", this.enabled, `${base}/api/v1/query?query=${encodeURIComponent(cpuQuery)}`, { method: "GET" }, fallback, async (response) => {
            const cpuPayload = await response.json();
            const cpu = prometheusInstantScalar(cpuPayload) ?? fallback.cpu;
            let ram = fallback.ram;
            try {
                const memRes = await fetch(`${base}/api/v1/query?query=${encodeURIComponent(memQuery)}`, { method: "GET" });
                if (memRes.ok) {
                    ram = prometheusInstantScalar(await memRes.json()) ?? fallback.ram;
                }
            }
            catch {
                ram = fallback.ram;
            }
            return { cpu, ram };
        });
    }
}
export class GitOpsClient {
    async commitHelmValues(projectName: string, imageTag: string): Promise<{
        committed: boolean;
        ref: string;
    }> {
        return commitHelmValuesGitHub(projectName, imageTag);
    }
}
export const jenkinsClient = new JenkinsClient();
export const sonarQubeClient = new SonarQubeClient();
export const dependencyTrackClient = new DependencyTrackClient();
export const trivyClient = new TrivyClient();
export const cosignClient = new CosignClient();
export const opaClient = new OpaClient();
export const harborClient = new HarborClient();
export const argoCdClient = new ArgoCdClient();
export const prometheusClient = new PrometheusClient();
export const gitOpsClient = new GitOpsClient();
export const dockerHubClient = new DockerHubClient();
