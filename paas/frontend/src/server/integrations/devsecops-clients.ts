import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { syncInlinePaasDeployJenkinsJobBeforeTrigger } from "@/server/jenkins/sync-inline-pipeline-job";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { syntheticStagesWhenWfapiUnavailable } from "@/lib/paas-deploy-jenkins-stages";
import { type PipelineStepCheck, parsePipelineVerificationLogs } from "@/server/jenkins/pipeline-step-verification";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import { getArgoApplicationStatus, getArgoCdApiBase, syncArgoApplication } from "@/server/services/argocd-service";
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
export type JenkinsWorkflowStageRow = {
    name: string;
    status: string;
    durationMs: number | null;
};
export type JenkinsWorkflowDescribeResult = {
    configured: boolean;
    error?: string;
    stagesSynthetic?: boolean;
    wfapiHint?: string;
    jobUrlPath: string;
    displayJobName: string;
    buildNumber: number | null;
    building: boolean;
    result: string | null;
    runStatus: string | null;
    stages: JenkinsWorkflowStageRow[];
    jenkinsChecks?: PipelineStepCheck[];
    buildComplete?: {
        result: string;
        image: string;
        project: string;
        build: string;
    } | null;
    artifactImage?: string | null;
};
export interface DockerHubTagInfo {
    name: string;
    lastUpdated: string | null;
}
function jenkinsBaseUrl(): string {
    return env.JENKINS_BASE_URL.replace(/\/$/, "");
}
function jenkinsBrowserBaseUrl(): string {
    const explicit = (env.JENKINS_PROBE_URL || "").trim().replace(/\/+$/, "");
    if (explicit) {
        return explicit;
    }
    const base = jenkinsBaseUrl();
    if (!/\.svc\.cluster\.local/i.test(base)) {
        return base;
    }
    const nodeIp = (env.APPS_PUBLIC_LAB_NODE_IP || "").trim();
    if (nodeIp) {
        return `http://${nodeIp}:30090`;
    }
    return base;
}
function remapJenkinsPublicUrl(url: string | null | undefined): string | null {
    if (!url?.trim()) {
        return null;
    }
    if (!/\.svc\.cluster\.local/i.test(url)) {
        return url.trim();
    }
    try {
        const parsed = new URL(url);
        return `${jenkinsBrowserBaseUrl()}${parsed.pathname}${parsed.search}`;
    }
    catch {
        return url.trim();
    }
}
function jenkinsAuthHeader(): string {
    return `Basic ${Buffer.from(`${env.JENKINS_USERNAME}:${env.JENKINS_API_TOKEN}`).toString("base64")}`;
}
async function fetchJenkinsLastBuildNumber(base: string, jobPath: string, headers: Record<string, string>): Promise<number | null> {
    try {
        const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number`, { headers });
        if (!res.ok) {
            return null;
        }
        const json = (await res.json()) as {
            number?: number;
        };
        return typeof json.number === "number" ? json.number : null;
    }
    catch {
        return null;
    }
}
async function waitForJenkinsBuildNumberAfterTrigger(base: string, jobPath: string, headers: Record<string, string>, baseline: number | null): Promise<number | null> {
    const floor = baseline ?? 0;
    const deadline = Date.now() + 90_000;
    while (Date.now() < deadline) {
        const last = await fetchJenkinsLastBuildNumber(base, jobPath, headers);
        if (last !== null && last > floor) {
            return last;
        }
        await new Promise((r) => setTimeout(r, 2000));
    }
    return null;
}
function usesSharedJenkinsDeployJob(): boolean {
    return Boolean(env.JENKINS_DEPLOY_JOB_NAME.trim());
}
function usesSharedJenkinsBuildJob(): boolean {
    return Boolean(env.JENKINS_BUILD_JOB_NAME.trim());
}
export { usesSharedJenkinsDeployJob };
/** Shared paas-deploy runs one build at a time on the built-in agent — queue parallel UI deploys. */
export function effectiveMaxConcurrentJenkinsDeploys(configured: number): number {
    if (configured > 0) {
        return configured;
    }
    if (usesSharedJenkinsDeployJob()) {
        return 1;
    }
    return 0;
}
async function waitForBuildNumberFromQueueItem(base: string, headers: Record<string, string>, queueLocation: string | null, timeoutMs = 120_000): Promise<number | null> {
    const queueId = parseQueueItemId(queueLocation);
    if (!queueId) {
        return null;
    }
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        try {
            const res = await jenkinsIntegrationFetch(`${base}/queue/item/${queueId}/api/json?tree=cancelled,why,executable[number,url]`, { headers });
            if (res.ok) {
                const payload = (await res.json()) as {
                    cancelled?: boolean;
                    executable?: {
                        number?: number;
                    };
                };
                if (payload.cancelled) {
                    return null;
                }
                if (typeof payload.executable?.number === "number") {
                    return payload.executable.number;
                }
            }
        }
        catch {
        }
        await new Promise((r) => setTimeout(r, 1500));
    }
    return null;
}
function appendSharedJobAgentLabel(q: URLSearchParams): void {
    const param = env.JENKINS_AGENT_LABEL_PARAMETER.trim() || "JENKINS_AGENT_LABEL";
    // Always send the param (even empty) so Jenkins job default "built-in" does not win.
    q.set(param, env.JENKINS_AGENT_LABEL.trim());
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
        COSIGN_PRIVATE_KEY: env.COSIGN_PRIVATE_KEY,
        COSIGN_PASSWORD: process.env.COSIGN_PASSWORD ?? "",
        COSIGN_ALLOW_INSECURE_REGISTRY: process.env.COSIGN_ALLOW_INSECURE_REGISTRY ?? "",
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
    if (env.JENKINS_PAAS_FAST_PIPELINE === "true") {
        q.set("JENKINS_PAAS_FAST_PIPELINE", "true");
    }
    else if (env.JENKINS_PAAS_FAST_PIPELINE === "false") {
        q.set("JENKINS_PAAS_FAST_PIPELINE", "false");
    }
    if (env.JENKINS_SH_KEEPALIVE === "true") {
        q.set("JENKINS_SH_KEEPALIVE", "true");
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
function flattenWorkflowStages(rawStages: unknown, depth = 0): JenkinsWorkflowStageRow[] {
    if (depth > 24 || !Array.isArray(rawStages)) {
        return [];
    }
    const out: JenkinsWorkflowStageRow[] = [];
    for (const item of rawStages) {
        if (!item || typeof item !== "object") {
            continue;
        }
        const node = item as {
            name?: unknown;
            status?: unknown;
            totalDurationMillis?: unknown;
            stages?: unknown;
        };
        const name = typeof node.name === "string" ? node.name.trim() : "";
        const statusRaw = typeof node.status === "string" ? node.status.trim().toUpperCase() : "UNKNOWN";
        const durationMs = typeof node.totalDurationMillis === "number" ? node.totalDurationMillis : null;
        if (name) {
            out.push({
                name,
                status: statusRaw,
                durationMs
            });
        }
        if (Array.isArray(node.stages) && node.stages.length > 0) {
            out.push(...flattenWorkflowStages(node.stages, depth + 1));
        }
    }
    return out;
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
        url: remapJenkinsPublicUrl(row.url ?? null),
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
            const browserBase = jenkinsBrowserBaseUrl();
            const jobPath = jenkinsJobUrlPath(projectName, projectId, "build");
            const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
            const jobUrlFor = (buildNum: number | null) => buildNum != null ? `${browserBase}/${jobPath}/${buildNum}` : `${browserBase}/${jobPath}`;
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
            const baselineBeforeTrigger = await fetchJenkinsLastBuildNumber(base, jobPath, headers);
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
                    jobUrl: jobUrlFor(null)
                };
            }
            const queueLocation = triggerRes.headers.get("location");
            const triggeredAfterMs = Date.now();
            const lastNumber = await this.resolveTriggeredBuildNumber(projectName, projectId, "build", {
                queueLocation,
                baseline: baselineBeforeTrigger,
                expectedProjectUuid: sharedBuildJob ? buildParams.projectUuid : undefined,
                triggeredAfterMs
            });
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
                baselineBeforeTrigger != null ? `[jenkins] Baseline before trigger: #${baselineBeforeTrigger}` : "[jenkins] No prior build",
                lastNumber != null
                    ? `[jenkins] New run #${lastNumber}`
                    : sharedBuildJob
                        ? "[jenkins] New run number not visible yet (monitor will match by PROJECT_ID on shared job)"
                        : "[jenkins] New run number not visible yet (monitor will poll until lastBuild > baseline)",
                consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
            ].join("\n");
            return {
                ok: true,
                buildNumber: lastNumber,
                buildLog: log,
                jobUrl: jobUrlFor(lastNumber)
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
        const browserBase = jenkinsBrowserBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, "deploy");
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        const jobUrlFor = (buildNum: number | null) => buildNum != null ? `${browserBase}/${jobPath}/${buildNum}` : `${browserBase}/${jobPath}`;
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
            const baselineBeforeTrigger = await fetchJenkinsLastBuildNumber(base, jobPath, headers);
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
                    jobUrl: jobUrlFor(null)
                };
            }
            const queueLocation = triggerRes.headers.get("location");
            const triggeredAfterMs = Date.now();
            const lastNumber = await this.resolveTriggeredBuildNumber(projectName, projectId, "deploy", {
                queueLocation,
                baseline: baselineBeforeTrigger,
                expectedProjectUuid: deployParams.projectUuid,
                triggeredAfterMs
            });
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
                baselineBeforeTrigger != null ? `[jenkins] Baseline before trigger: #${baselineBeforeTrigger}` : "[jenkins] No prior build",
                lastNumber != null
                    ? `[jenkins] New run #${lastNumber}`
                    : usesSharedJenkinsDeployJob()
                        ? "[jenkins] New run number not visible yet (monitor will match by PROJECT_ID on shared job)"
                        : "[jenkins] New run number not visible yet (monitor will poll until lastBuild > baseline)",
                consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
            ].join("\n");
            return {
                ok: true,
                buildNumber: lastNumber,
                buildLog: log,
                jobUrl: jobUrlFor(lastNumber)
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
    async resolveTriggeredBuildNumber(projectName: string, projectId: string, kind: JenkinsJobKind, opts: {
        queueLocation: string | null;
        baseline: number | null;
        expectedProjectUuid?: string;
        triggeredAfterMs?: number;
    }): Promise<number | null> {
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
        let buildNum = await waitForBuildNumberFromQueueItem(base, headers, opts.queueLocation);
        if (buildNum != null && opts.expectedProjectUuid) {
            const param = await this.getBuildParameterValue(projectName, projectId, buildNum, env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER, kind);
            if (param !== opts.expectedProjectUuid) {
                buildNum = null;
            }
        }
        if (buildNum == null && opts.expectedProjectUuid) {
            buildNum = await this.findDeployBuildForProject(projectName, opts.expectedProjectUuid, {
                baseline: opts.baseline,
                afterMs: opts.triggeredAfterMs ?? Date.now() - 120_000
            });
        }
        const shared = kind === "deploy" ? usesSharedJenkinsDeployJob() : usesSharedJenkinsBuildJob();
        if (buildNum == null && !shared) {
            buildNum = await waitForJenkinsBuildNumberAfterTrigger(base, jobPath, headers, opts.baseline);
        }
        return buildNum;
    }
    async verifyDeployBuildBelongsToProject(projectName: string, projectId: string, buildNumber: number): Promise<boolean> {
        if (!usesSharedJenkinsDeployJob()) {
            return true;
        }
        const param = await this.resolveDeployBuildProjectId(projectName, projectId, buildNumber, "deploy");
        if (param !== projectId) {
            return false;
        }
        const imageParam = await this.getBuildParameterValue(projectName, projectId, buildNumber, env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER, "deploy");
        if (imageParam?.trim()) {
            const expected = buildDeployImageRepository(projectName).toLowerCase();
            const actual = imageParam.trim().toLowerCase();
            if (actual !== expected && !actual.startsWith(`${expected}:`) && !actual.startsWith(`${expected}@`)) {
                return false;
            }
        }
        return true;
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
    async listRecentBuildSummaries(projectName: string, projectId: string, kind: JenkinsJobKind = "deploy", limit = 25): Promise<Array<{
        number: number;
        building: boolean;
        result: string | null;
        timestamp: number | null;
    }>> {
        if (!this.enabled) {
            return [];
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        const capped = Math.min(Math.max(limit, 1), 40);
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/api/json?tree=builds[number,building,result,timestamp]{0,${capped}}`, { headers });
            if (!res.ok) {
                return [];
            }
            const j = (await res.json()) as {
                builds?: Array<{
                    number?: number;
                    building?: boolean;
                    result?: string | null;
                    timestamp?: number | null;
                }>;
            };
            return (j.builds ?? [])
                .filter((b): b is {
                    number: number;
                    building: boolean;
                    result: string | null;
                    timestamp: number | null;
                } => typeof b.number === "number")
                .map((b) => ({
                    number: b.number,
                    building: Boolean(b.building),
                    result: b.result ?? null,
                    timestamp: typeof b.timestamp === "number" ? b.timestamp : null
                }));
        }
        catch {
            return [];
        }
    }
    async getBuildConsoleHead(projectName: string, projectId: string, buildNumber: number, kind: JenkinsJobKind = "deploy", maxChars = 16_000): Promise<string | null> {
        const text = await this.getBuildConsoleText(projectName, projectId, buildNumber, kind);
        if (!text) {
            return null;
        }
        return text.slice(0, maxChars);
    }
    async resolveDeployBuildProjectId(projectName: string, projectId: string, buildNumber: number, kind: JenkinsJobKind = "deploy"): Promise<string | null> {
        const paramName = env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER;
        const fromParam = await this.getBuildParameterValue(projectName, projectId, buildNumber, paramName, kind);
        if (fromParam) {
            return fromParam;
        }
        const head = await this.getBuildConsoleHead(projectName, projectId, buildNumber, kind);
        if (!head) {
            return null;
        }
        const paramsLine = head.match(/\[params\]\s+project=([^\s]+)/i);
        if (paramsLine?.[1]?.trim()) {
            return paramsLine[1].trim();
        }
        const complete = head.match(/PAAS_BUILD_COMPLETE\s+result=\S+\s+image=\S+\s+project=([^\s]+)/i);
        if (complete?.[1]?.trim()) {
            return complete[1].trim();
        }
        return null;
    }
    async resolveSharedDeployBuildNumber(projectName: string, projectId: string, preferred: number | null, opts?: {
        baseline?: number | null;
        afterMs?: number | null;
    }): Promise<number | null> {
        if (preferred != null && await this.verifyDeployBuildBelongsToProject(projectName, projectId, preferred)) {
            return preferred;
        }
        return this.findDeployBuildForProject(projectName, projectId, {
            baseline: opts?.baseline ?? null,
            afterMs: opts?.afterMs ?? Date.now() - 3_600_000,
            limit: 50
        });
    }
    async getBuildParameterValue(projectName: string, projectId: string, buildNumber: number, parameterName: string, kind: JenkinsJobKind = "deploy"): Promise<string | null> {
        if (!this.enabled) {
            return null;
        }
        const base = jenkinsBaseUrl();
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const headers = { Authorization: jenkinsAuthHeader() };
        try {
            const res = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/api/json?tree=actions[parameters[name,value]]`, { headers });
            if (!res.ok) {
                return null;
            }
            const j = (await res.json()) as {
                actions?: Array<{
                    parameters?: Array<{
                        name?: string;
                        value?: string | number | boolean | null;
                    }>;
                }>;
            };
            for (const action of j.actions ?? []) {
                for (const param of action.parameters ?? []) {
                    if (param.name === parameterName && param.value != null && String(param.value).trim()) {
                        return String(param.value).trim();
                    }
                }
            }
            return null;
        }
        catch {
            return null;
        }
    }
    async findDeployBuildForProject(projectName: string, projectUuid: string, opts: {
        baseline: number | null;
        afterMs?: number | null;
        limit?: number;
    }): Promise<number | null> {
        const afterMs = opts.afterMs ?? null;
        const builds = await this.listRecentBuildSummaries(projectName, projectUuid, "deploy", opts.limit ?? 50);
        let best: number | null = null;
        for (const build of builds) {
            if (opts.baseline != null && build.number <= opts.baseline) {
                continue;
            }
            if (afterMs != null && build.timestamp != null && build.timestamp < afterMs - 120_000) {
                continue;
            }
            const projectParam = await this.resolveDeployBuildProjectId(projectName, projectUuid, build.number, "deploy");
            if (projectParam === projectUuid) {
                if (best === null || build.number > best) {
                    best = build.number;
                }
            }
        }
        return best;
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
                items?: Array<{
                    id?: number;
                    task?: {
                        url?: string;
                    };
                }>;
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
    async getWorkflowStagesForProject(projectName: string, projectId: string, buildNumber?: number | null, kind: JenkinsJobKind = "deploy"): Promise<JenkinsWorkflowDescribeResult & {
        buildUrl: string | null;
    }> {
        const displayJobName = jenkinsJobName(projectName, projectId, kind);
        const jobPath = jenkinsJobUrlPath(projectName, projectId, kind);
        const base = jenkinsBaseUrl();
        const browserBase = jenkinsBrowserBaseUrl();
        const withUrl = (row: JenkinsWorkflowDescribeResult): JenkinsWorkflowDescribeResult & {
            buildUrl: string | null;
        } => ({
            ...row,
            buildUrl: row.buildNumber != null ? `${browserBase}/${jobPath}/${row.buildNumber}` : null
        });
        if (!this.enabled) {
            return withUrl({
                configured: false,
                jobUrlPath: jobPath,
                displayJobName,
                buildNumber: null,
                building: false,
                result: null,
                runStatus: null,
                stages: [],
                error: allowSimulation() ? undefined : "Jenkins is not configured."
            });
        }
        const headers: Record<string, string> = {
            Authorization: jenkinsAuthHeader(),
            Accept: "application/json"
        };
        const crumb = await jenkinsFetchCrumb(base, headers);
        if (crumb) {
            headers[crumb.crumbRequestField] = crumb.crumb;
            if (crumb.cookieHeader) {
                headers.Cookie = crumb.cookieHeader;
            }
        }
        let bn: number | null = typeof buildNumber === "number" && Number.isFinite(buildNumber) ? Math.trunc(buildNumber) : null;
        let building = false;
        let result: string | null = null;
        if (usesSharedJenkinsDeployJob()) {
            const resolved = await this.resolveSharedDeployBuildNumber(projectName, projectId, bn, {
                afterMs: Date.now() - 3_600_000
            });
            if (resolved != null) {
                bn = resolved;
            }
            else if (bn != null) {
                return withUrl({
                    configured: true,
                    jobUrlPath: jobPath,
                    displayJobName,
                    buildNumber: null,
                    building: true,
                    result: null,
                    runStatus: null,
                    stages: syntheticStagesWhenWfapiUnavailable({ configured: true, building: true, result: null }).map(({ name, status, durationMs }) => ({
                        name,
                        status,
                        durationMs
                    })),
                    wfapiHint: `Waiting for Jenkins build for "${projectName}" on shared paas-deploy (build #${bn} belongs to another project).`
                });
            }
            else {
                return withUrl({
                    configured: true,
                    jobUrlPath: jobPath,
                    displayJobName,
                    buildNumber: null,
                    building: true,
                    result: null,
                    runStatus: null,
                    stages: syntheticStagesWhenWfapiUnavailable({ configured: true, building: true, result: null }).map(({ name, status, durationMs }) => ({
                        name,
                        status,
                        durationMs
                    })),
                    wfapiHint: `Waiting for Jenkins to start a build for "${projectName}" on shared paas-deploy.`
                });
            }
        }
        else if (bn == null) {
            const lastRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,building,result`, { headers });
            if (!lastRes.ok) {
                const t = await lastRes.text();
                return withUrl({
                    configured: true,
                    error: lastRes.status === 404
                        ? "Jenkins job or lastBuild not found."
                        : `lastBuild lookup failed (${lastRes.status}): ${t.slice(0, 400)}`,
                    jobUrlPath: jobPath,
                    displayJobName,
                    buildNumber: null,
                    building: false,
                    result: null,
                    runStatus: null,
                    stages: []
                });
            }
            const lastJson = (await lastRes.json()) as {
                number?: number;
                building?: boolean;
                result?: string | null;
            };
            bn = typeof lastJson.number === "number" ? lastJson.number : null;
            building = Boolean(lastJson.building);
            result = lastJson.result ?? null;
            if (bn == null) {
                return withUrl({
                    configured: true,
                    jobUrlPath: jobPath,
                    displayJobName,
                    buildNumber: null,
                    building: false,
                    result: null,
                    runStatus: null,
                    stages: []
                });
            }
        }
        if (bn != null) {
            const metaRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${bn}/api/json?tree=building,result`, { headers });
            if (metaRes.ok) {
                const meta = (await metaRes.json()) as {
                    building?: boolean;
                    result?: string | null;
                };
                building = Boolean(meta.building);
                result = meta.result ?? null;
            }
        }
        if (bn == null) {
            return withUrl({
                configured: true,
                jobUrlPath: jobPath,
                displayJobName,
                buildNumber: null,
                building: false,
                result: null,
                runStatus: null,
                stages: []
            });
        }
        const wfapiFallbackStages = (): JenkinsWorkflowStageRow[] => {
            const rows = syntheticStagesWhenWfapiUnavailable({
                configured: true,
                building,
                result
            });
            return rows.map(({ name, status, durationMs }) => ({
                name,
                status,
                durationMs
            }));
        };
        const wfRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${bn}/wfapi/describe`, { headers });
        if (!wfRes.ok) {
            const text = await wfRes.text();
            const coarseStages = wfapiFallbackStages();
            if (wfRes.status === 404) {
                return withUrl({
                    configured: true,
                    jobUrlPath: jobPath,
                    displayJobName,
                    buildNumber: bn,
                    building,
                    result,
                    runStatus: null,
                    stages: coarseStages,
                    stagesSynthetic: true,
                    wfapiHint: "Per-stage timing is unavailable because Jenkins did not expose wfapi/describe (usually fixed by installing the Pipeline: Stage View plugin). The checklist below reflects build state only, not live stage edges. Open the build in Jenkins for the full graph."
                });
            }
            return withUrl({
                configured: true,
                error: `wfapi/describe failed (${wfRes.status}): ${text.slice(0, 400)}`,
                jobUrlPath: jobPath,
                displayJobName,
                buildNumber: bn,
                building,
                result,
                runStatus: null,
                stages: coarseStages,
                stagesSynthetic: true,
                wfapiHint: "Showing an approximate checklist; stage API returned an error."
            });
        }
        let wf: {
            status?: string;
            stages?: unknown[];
        };
        try {
            wf = (await wfRes.json()) as {
                status?: string;
                stages?: unknown[];
            };
        }
        catch {
            return withUrl({
                configured: true,
                error: "Could not parse wfapi/describe JSON.",
                jobUrlPath: jobPath,
                displayJobName,
                buildNumber: bn,
                building,
                result,
                runStatus: null,
                stages: wfapiFallbackStages(),
                stagesSynthetic: true,
                wfapiHint: "Showing an approximate checklist because the stage API response was not valid JSON."
            });
        }
        const runStatus = typeof wf.status === "string" ? wf.status.trim().toUpperCase() : null;
        const stages = flattenWorkflowStages(wf.stages);
        let jenkinsChecks: PipelineStepCheck[] = [];
        let buildComplete: JenkinsWorkflowDescribeResult["buildComplete"] = null;
        let artifactImage: string | null = null;
        try {
            const consoleRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${bn}/consoleText`, { headers });
            if (consoleRes.ok) {
                const parsed = parsePipelineVerificationLogs(await consoleRes.text());
                jenkinsChecks = parsed.jenkinsChecks;
                buildComplete = parsed.buildComplete;
                artifactImage = parsed.artifactImage;
            }
        }
        catch {
        }
        return withUrl({
            configured: true,
            jobUrlPath: jobPath,
            displayJobName,
            buildNumber: bn,
            building,
            result,
            runStatus,
            stages,
            jenkinsChecks,
            buildComplete,
            artifactImage
        });
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
    private enabled = Boolean(env.SONAR_BASE_URL && env.SONAR_TOKEN);
    async qualityGate(projectKey: string): Promise<{
        status: "PASSED" | "FAILED" | "UNKNOWN";
    }> {
        if (!this.enabled) {
            return { status: "UNKNOWN" };
        }
        const fallbackStatus = projectKey.toLowerCase().includes("fail-sonar") ? "FAILED" : "PASSED";
        if (!allowSimulation()) {
            try {
                const response = await integrationFetch(`${env.SONAR_BASE_URL}/api/qualitygates/project_status?projectKey=${encodeURIComponent(projectKey)}`, {
                    method: "GET",
                    headers: {
                        Authorization: `Basic ${Buffer.from(`${env.SONAR_TOKEN}:`).toString("base64")}`
                    }
                });
                if (response.status === 404) {
                    return { status: "UNKNOWN" };
                }
                if (!response.ok) {
                    const errText = await response.text();
                    throw new IntegrationError(`SonarQube HTTP ${response.status}: ${errText.slice(0, 800)}`);
                }
                const data = (await response.json()) as {
                    projectStatus?: {
                        status?: string;
                    };
                };
                return { status: data.projectStatus?.status === "OK" ? "PASSED" : "FAILED" };
            }
            catch (e) {
                if (e instanceof IntegrationError) {
                    throw e;
                }
                throw new IntegrationError(`SonarQube request failed: ${e instanceof Error ? e.message : String(e)}`);
            }
        }
        return fetchOrFallback("SonarQube", true, `${env.SONAR_BASE_URL}/api/qualitygates/project_status?projectKey=${encodeURIComponent(projectKey)}`, {
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
    private enabled = Boolean(env.DEPENDENCY_TRACK_BASE_URL && env.DEPENDENCY_TRACK_API_KEY);
    private headers() {
        return {
            "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY
        };
    }
    private pickProjectUuidFromList(payload: Array<{
        uuid?: string;
        name?: string;
        tags?: Array<{ name?: string }>;
    }>, projectKey: string): string | null {
        const byTag = payload.find((item) => item.tags?.some((tag) => tag.name?.toLowerCase() === projectKey.toLowerCase()));
        if (byTag?.uuid) {
            return byTag.uuid;
        }
        const exact = payload.find((item) => item.name?.toLowerCase() === projectKey.toLowerCase());
        if (exact?.uuid) {
            return exact.uuid;
        }
        return payload[0]?.uuid ?? null;
    }
    private async resolveProjectUuid(projectKey: string): Promise<string | null> {
        if (!this.enabled) {
            return null;
        }
        const uuidLike = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
        if (uuidLike.test(projectKey)) {
            try {
                const direct = await integrationFetch(`${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/project/${encodeURIComponent(projectKey)}`, {
                    method: "GET",
                    headers: this.headers()
                });
                if (direct.ok) {
                    const payload = (await direct.json()) as {
                        uuid?: string;
                    };
                    return payload.uuid ?? projectKey;
                }
            }
            catch {
            }
        }
        try {
            const allRes = await integrationFetch(`${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/project`, {
                method: "GET",
                headers: this.headers()
            });
            if (allRes.ok) {
                const all = (await allRes.json()) as Array<{
                    uuid?: string;
                    name?: string;
                    tags?: Array<{ name?: string }>;
                }>;
                const fromAll = this.pickProjectUuidFromList(all, projectKey);
                if (fromAll) {
                    return fromAll;
                }
            }
        }
        catch {
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
            tags?: Array<{ name?: string }>;
        }>;
        return this.pickProjectUuidFromList(Array.isArray(payload) ? payload : [], projectKey);
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
        const empty: DependencyTrackProjectMetrics = {
            projectUuid: null,
            projectName: projectKey,
            metrics: { critical: 0, high: 0, medium: 0, low: 0 },
            findings: []
        };
        if (!this.enabled) {
            return empty;
        }
        try {
            const projectUuid = await this.resolveProjectUuid(projectKey);
            if (!projectUuid) {
                return empty;
            }
            const response = await integrationFetch(`${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/project/${encodeURIComponent(projectUuid)}/metrics`, {
                method: "GET",
                headers: this.headers()
            });
            if (!response.ok) {
                return { ...empty, projectUuid, projectName: projectKey };
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
            let findings: DependencyTrackFinding[] = [];
            try {
                findings = await this.findProjectFindings(projectUuid);
            }
            catch {
                findings = [];
            }
            return {
                projectUuid,
                projectName: projectKey,
                metrics: {
                    critical: Number(payload.critical ?? payload.findingsCritical ?? 0),
                    high: Number(payload.high ?? payload.findingsHigh ?? 0),
                    medium: Number(payload.medium ?? payload.findingsMedium ?? 0),
                    low: Number(payload.low ?? payload.findingsLow ?? 0)
                },
                findings
            };
        }
        catch {
            return empty;
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
    async isSigned(imageRef: string, options?: {
        timeoutMs?: number;
    }): Promise<boolean> {
        return verifyImageWithCosign(imageRef, options);
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
    async sync(projectName: string): Promise<{
        status: string;
        logs: string;
    }> {
        const appName = `${env.ARGOCD_APP_PREFIX}-${projectName}`;
        const fallback = {
            status: "SYNCED",
            logs: `[argocd] Synced application ${appName}`
        };
        const configured = Boolean(getArgoCdApiBase() && env.ARGOCD_AUTH_TOKEN.trim());
        if (!configured) {
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
        unreachableReason?: string;
    }> {
        return getArgoApplicationStatus(projectName);
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
            return { ok: true, message: "Docker Hub credentials not set \u2014 registry calls are skipped." };
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
const PROM_DEFAULT_CPU_QUERY = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
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
function prometheusRangeFirstSeries(payload: unknown): {
    ts: number;
    value: number;
}[] {
    const data = payload as {
        data?: {
            result?: Array<{
                values?: Array<[
                    number,
                    string
                ]>;
            }>;
        };
    };
    const values = data.data?.result?.[0]?.values;
    if (!Array.isArray(values)) {
        return [];
    }
    return values.map(([t, v]) => {
        const n = Number.parseFloat(String(v));
        return {
            ts: t * 1000,
            value: Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : 0
        };
    });
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
        if (!this.enabled) {
            return fallback;
        }
        const base = env.PROMETHEUS_BASE_URL.replace(/\/$/, "");
        const cpuQuery = env.PROMETHEUS_QUERY_CPU.trim() || PROM_DEFAULT_CPU_QUERY;
        const memQuery = env.PROMETHEUS_QUERY_MEMORY.trim() || PROM_DEFAULT_MEMORY_QUERY;
        try {
            return await fetchOrFallback("Prometheus", true, `${base}/api/v1/query?query=${encodeURIComponent(cpuQuery)}`, { method: "GET" }, fallback, async (response) => {
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
        catch {
            return fallback;
        }
    }
    async clusterUsageRange(opts: {
        durationSeconds: number;
        stepSeconds: number;
    }): Promise<{
        cpuSeries: {
            ts: number;
            value: number;
        }[];
        memorySeries: {
            ts: number;
            value: number;
        }[];
        error?: string;
    }> {
        if (!this.enabled) {
            return { cpuSeries: [], memorySeries: [] };
        }
        const base = env.PROMETHEUS_BASE_URL.replace(/\/$/, "");
        const cpuQuery = env.PROMETHEUS_QUERY_CPU.trim() || PROM_DEFAULT_CPU_QUERY;
        const memQuery = env.PROMETHEUS_QUERY_MEMORY.trim() || PROM_DEFAULT_MEMORY_QUERY;
        const end = Math.floor(Date.now() / 1000);
        const start = end - opts.durationSeconds;
        const step = Math.max(15, opts.stepSeconds);
        const qCpu = `${base}/api/v1/query_range?query=${encodeURIComponent(cpuQuery)}&start=${start}&end=${end}&step=${step}`;
        const qMem = `${base}/api/v1/query_range?query=${encodeURIComponent(memQuery)}&start=${start}&end=${end}&step=${step}`;
        try {
            const cpuRes = await integrationFetch(qCpu, { method: "GET" });
            if (!cpuRes.ok) {
                const t = await cpuRes.text();
                return {
                    cpuSeries: [],
                    memorySeries: [],
                    error: `Prometheus query_range (CPU) failed (${cpuRes.status}): ${t.slice(0, 400)}`
                };
            }
            const cpuPayload = await cpuRes.json();
            const cpuSeries = prometheusRangeFirstSeries(cpuPayload);
            let memorySeries: {
                ts: number;
                value: number;
            }[] = [];
            try {
                const memRes = await integrationFetch(qMem, { method: "GET" });
                if (memRes.ok) {
                    memorySeries = prometheusRangeFirstSeries(await memRes.json());
                }
            }
            catch {
            }
            return { cpuSeries, memorySeries };
        }
        catch (e) {
            return {
                cpuSeries: [],
                memorySeries: [],
                error: e instanceof Error ? e.message : String(e)
            };
        }
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
/** Latest PAAS_ARTIFACT_IMAGE from Jenkins deploy job console (falls back to DB tag in callers). */
export async function resolveLatestDeployArtifactImage(projectName: string, projectId: string): Promise<string | null> {
    if (!env.JENKINS_BASE_URL || !env.JENKINS_USERNAME || !env.JENKINS_API_TOKEN) {
        return null;
    }
    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId, "deploy");
    const headers = { Authorization: jenkinsAuthHeader() };
    try {
        const lastRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/lastBuild/api/json?tree=number`, { headers });
        if (!lastRes.ok) {
            return null;
        }
        const last = (await lastRes.json()) as {
            number?: number;
        };
        const buildNumber = last.number;
        if (!buildNumber) {
            return null;
        }
        const consoleRes = await jenkinsIntegrationFetch(`${base}/${jobPath}/${buildNumber}/consoleText`, { headers });
        if (!consoleRes.ok) {
            return null;
        }
        const text = await consoleRes.text();
        const tail = text.length > 64000 ? text.slice(-64000) : text;
        return parsePipelineVerificationLogs(tail).artifactImage;
    }
    catch {
        return null;
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
