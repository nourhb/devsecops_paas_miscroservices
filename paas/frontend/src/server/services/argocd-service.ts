import { env } from "@/server/config/env";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-github-service";
import { getArgoApplicationStatusViaK8s, refreshArgoApplicationViaK8s, syncArgoApplicationViaK8s } from "@/server/services/argocd-k8s-refresh";

import { allowSimulation } from "@/server/integrations/integration-mode";
import { IntegrationError } from "@/server/http/response";
import { formatFetchErrorChain } from "@/server/http/integration-fetch";
import type { ArgoCdStatus } from "@/types";
export function argoApplicationName(projectName: string): string {
    return `${env.ARGOCD_APP_PREFIX}-${sanitizeDeployImageName(projectName)}`;
}
export function getArgoCdApiBase(): string {
    return env.ARGOCD_BASE_URL.trim().replace(/\/+$/, "");
}
function defaultDestinationNamespace(projectName: string): string {
    return projectName
        .toLowerCase()
        .replace(/[^a-z0-9-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "");
}
function buildArgoApplicationBody(projectName: string, destinationNamespace: string): Record<string, unknown> {
    const appName = argoApplicationName(projectName);
    const repoUrl = env.GITOPS_REPO_URL.trim().replace(/\.git$/i, "");
    if (!repoUrl) {
        throw new IntegrationError("GITOPS_REPO_URL is required to auto-create Argo CD Applications.");
    }
    const chartPath = gitopsHelmChartPathForProject(projectName);
    const destServer = env.ARGOCD_DEST_SERVER.trim() || "https://kubernetes.default.svc";
    return {
        apiVersion: "argoproj.io/v1alpha1",
        kind: "Application",
        metadata: { name: appName },
        spec: {
            project: env.ARGOCD_APP_PROJECT.trim() || "default",
            source: {
                repoURL: repoUrl,
                path: chartPath,
                targetRevision: env.GITOPS_DEFAULT_BRANCH.trim() || "main"
            },
            destination: {
                server: destServer,
                namespace: destinationNamespace
            },
            syncPolicy: {
                automated: { prune: false, selfHeal: true },
                syncOptions: ["CreateNamespace=true"]
            }
        }
    };
}
async function getArgoApplicationHttpStatus(appName: string): Promise<"missing" | "present" | "error"> {
    const base = getArgoCdApiBase();
    if (!base || !(await argoAuthConfigured())) {
        return "error";
    }
    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}`;
    try {
        const response = await argocdFetchWithAuth(url, { method: "GET" });
        if (response.status === 404) {
            return "missing";
        }
        if (response.ok) {
            return "present";
        }
        return "error";
    }
    catch {
        return "error";
    }
}
export async function ensureArgoCdApplication(projectName: string, destinationNamespace?: string): Promise<{
    logs: string;
    created: boolean;
}> {
    const appName = argoApplicationName(projectName);
    if (env.ARGOCD_AUTO_CREATE_APPLICATION !== "true") {
        return { logs: `[argocd] Auto-create disabled (ARGOCD_AUTO_CREATE_APPLICATION=false).`, created: false };
    }
    const base = getArgoCdApiBase();
    if (!(await argoAuthConfigured())) {
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated ensure for ${appName} (Argo CD not configured).`, created: false };
        }
        throw new IntegrationError(`Argo CD is not configured: ${argoAuthMessage()}`);
    }
    const existing = await getArgoApplicationHttpStatus(appName);
    if (existing === "present") {
        return { logs: `[argocd] Application "${appName}" already exists.`, created: false };
    }
    const namespace = (destinationNamespace ?? defaultDestinationNamespace(projectName)).trim() || defaultDestinationNamespace(projectName);
    const body = buildArgoApplicationBody(projectName, namespace);
    const createUrl = `${base}/api/v1/applications`;
    let response: Response;
    try {
        response = await argocdFetchWithAuth(createUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        });
    }
    catch (e) {
        const msg = formatFetchErrorChain(e);
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated create for ${appName} (request failed: ${msg})`, created: false };
        }
        throw new IntegrationError(`Argo CD create application failed: ${msg}`);
    }
    if (response.ok || response.status === 409) {
        const chartPath = (body.spec as {
            source: {
                path: string;
            };
        }).source.path;
        const repoUrl = (body.spec as {
            source: {
                repoURL: string;
            };
        }).source.repoURL;
        const action = response.ok ? "created" : "already exists";
        return {
            created: response.ok,
            logs: `[argocd] Application "${appName}" ${action} (repo=${repoUrl}, path=${chartPath}, namespace=${namespace}).`
        };
    }
    const errBody = (await response.text()).trim().slice(0, 800);
    const lenient = env.PAAS_STRICT_INTEGRATIONS !== "true";
    if ((response.status === 401 || response.status === 403) && lenient) {
        return {
            created: false,
            logs: `[argocd] WARN: could not auto-create "${appName}" (HTTP ${response.status}). Grant applications, create on the AppProject or use an admin token. ${errBody}`
        };
    }
    throw new IntegrationError(`Argo CD create application "${appName}" failed (HTTP ${response.status}): ${errBody || "no body"}`);
}
export async function getArgoApplicationStatus(projectName: string): Promise<ArgoCdStatus> {
    const appName = argoApplicationName(projectName);
    if (env.KUBERNETES_ENABLED === "true") {
        const k8s = await getArgoApplicationStatusViaK8s(appName);
        if (k8s.ok) {
            return {
                health: k8s.health,
                syncStatus: k8s.syncStatus,
                appName
            };
        }
        const hint = k8s.logs.includes("not found")
            ? `Run: bash paas/scripts/lab.sh argocd-apps`
            : `Run: bash paas/scripts/lab.sh argocd-bootstrap`;
        return {
            health: "Unknown",
            syncStatus: "Unknown",
            appName,
            unreachableReason: `${k8s.logs} ${hint}`
        };
    }
    const base = getArgoCdApiBase();
    if (!base || !(await argoAuthConfigured())) {
        return {
            health: "Unknown",
            syncStatus: "Unknown",
            appName,
            unreachableReason: argoAuthMessage()
        };
    }
    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}`;
    try {
        const response = await argocdFetchWithAuth(url, { method: "GET" });
        if (response.status === 404) {
            return {
                health: "Unknown",
                syncStatus: "Unknown",
                appName,
                unreachableReason: `No Argo CD Application named "${appName}". Create it or set ARGOCD_APP_PREFIX (current: "${env.ARGOCD_APP_PREFIX}").`
            };
        }
        if (!response.ok) {
            const errText = (await response.text()).trim().slice(0, 600);
            const lenient = env.PAAS_STRICT_INTEGRATIONS !== "true";
            if ((response.status === 401 || response.status === 403) && lenient) {
                return {
                    health: "Unknown",
                    syncStatus: "Unknown",
                    appName,
                    unreachableReason: `Argo CD returned HTTP ${response.status} for GET ${url}. ` +
                        `Run: bash paas/scripts/lab.sh argocd-bootstrap (sets ARGOCD_PASSWORD and RBAC). ${errText}`
                };
            }
            if (allowSimulation()) {
                return {
                    health: "Unknown",
                    syncStatus: "Unknown",
                    appName,
                    unreachableReason: `Argo CD HTTP ${response.status}: ${errText || "no body"}`
                };
            }
            if (env.PAAS_STRICT_INTEGRATIONS !== "true") {
                return {
                    health: "Unknown",
                    syncStatus: "Unknown",
                    appName,
                    unreachableReason: `Argo CD application status failed (${response.status}): ${errText || "no body"}`
                };
            }
            throw new IntegrationError(`Argo CD application status failed (${response.status}): ${errText || "no body"}`);
        }
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
    }
    catch (e) {
        if (e instanceof IntegrationError) {
            if (env.PAAS_STRICT_INTEGRATIONS !== "true") {
                return {
                    health: "Unknown",
                    syncStatus: "Unknown",
                    appName,
                    unreachableReason: e.message
                };
            }
            throw e;
        }
        const msg = formatFetchErrorChain(e);
        if (env.PAAS_STRICT_INTEGRATIONS === "true" && !allowSimulation()) {
            const tlsNote = env.ARGOCD_TLS_SKIP_VERIFY !== "true" && env.INTEGRATIONS_TLS_SKIP_VERIFY !== "true" && base.startsWith("https:")
                ? " If the server uses a self-signed cert, set ARGOCD_TLS_SKIP_VERIFY=true or INTEGRATIONS_TLS_SKIP_VERIFY=true."
                : "";
            throw new IntegrationError(`Argo CD status request failed: ${msg}${tlsNote}`);
        }
        return {
            health: "Unknown",
            syncStatus: "Unknown",
            appName,
            unreachableReason: msg
        };
    }
}
export async function syncArgoApplication(projectName: string, destinationNamespace?: string): Promise<{
    logs: string;
}> {
    const base = getArgoCdApiBase();
    const appName = argoApplicationName(projectName);
    const ensureLogs: string[] = [];
    const apiConfigured = Boolean(base && await argoAuthConfigured());

    if (apiConfigured) {
        try {
            const ensured = await ensureArgoCdApplication(projectName, destinationNamespace);
            ensureLogs.push(ensured.logs);
        }
        catch (e) {
            const msg = e instanceof Error ? e.message : String(e);
            if (env.PAAS_STRICT_INTEGRATIONS === "true") {
                throw e instanceof IntegrationError ? e : new IntegrationError(msg);
            }
            ensureLogs.push(`[argocd] WARN: ensure application failed: ${msg}`);
        }
    }
    else if (env.KUBERNETES_ENABLED === "true") {
        ensureLogs.push(`[argocd] API auth unavailable — ensure Application "${appName}" exists, then sync via Kubernetes API.`);
    }
    else if (!base || !allowSimulation()) {
        throw new IntegrationError(`Argo CD is not configured: ${argoAuthMessage()}`);
    }
    else {
        return { logs: `[argocd] Simulated sync for ${appName} (Argo CD not configured).` };
    }

    if (env.KUBERNETES_ENABLED === "true") {
        const k8s = await syncArgoApplicationViaK8s(appName);
        if (k8s.ok) {
            const line = k8s.logs;
            return { logs: ensureLogs.length ? `${ensureLogs.join("\n")}\n${line}` : line };
        }
        ensureLogs.push(k8s.logs);
    }

    if (!apiConfigured) {
        if (env.PAAS_STRICT_INTEGRATIONS !== "true") {
            const prefix = ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "";
            return {
                logs: `${prefix}[argocd] WARN: Argo CD API not configured — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false).`
            };
        }
        throw new IntegrationError(`Argo CD sync failed for "${appName}": ${ensureLogs.join(" ")}`);
    }

    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}/sync`;
    let response: Response;
    try {
        response = await argocdFetchWithAuth(url, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ prune: false, dryRun: false })
        });
    }
    catch (e) {
        const msg = formatFetchErrorChain(e);
        const lenientIntegrations = env.PAAS_STRICT_INTEGRATIONS !== "true";
        if (env.KUBERNETES_ENABLED === "true") {
            const k8s = await syncArgoApplicationViaK8s(appName);
            if (k8s.ok) {
                const line = k8s.logs;
                return { logs: ensureLogs.length ? `${ensureLogs.join("\n")}\n${line}` : line };
            }
            ensureLogs.push(k8s.logs);
        }
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated sync for ${appName} (request failed: ${msg})` };
        }
        if (lenientIntegrations) {
            return {
                logs: (ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "") +
                    `[argocd] WARN: sync API unreachable (${msg}) — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false).`
            };
        }
        const tlsNote = env.ARGOCD_TLS_SKIP_VERIFY !== "true" && env.INTEGRATIONS_TLS_SKIP_VERIFY !== "true" && base.startsWith("https:")
            ? " If Argo CD uses a self-signed certificate, set ARGOCD_TLS_SKIP_VERIFY=true or INTEGRATIONS_TLS_SKIP_VERIFY=true."
            : "";
        const infraNote = /connect|refused|timeout|ECONNREFUSED/i.test(msg)
            ? " Ensure argocd-server is reachable and ARGOCD_BASE_URL matches the cluster endpoint."
            : "";
        throw new IntegrationError(`Argo CD sync request failed: ${msg}${tlsNote}${infraNote}`);
    }
    if (!response.ok) {
        const body = await response.text();
        const lenientIntegrations = env.PAAS_STRICT_INTEGRATIONS !== "true";
        if ((response.status === 401 || response.status === 403) && lenientIntegrations) {
            const tail = body.trim() ? body.slice(0, 400) : "";
            const k8sSync = env.KUBERNETES_ENABLED === "true"
                ? await syncArgoApplicationViaK8s(appName)
                : await refreshArgoApplicationViaK8s(appName);
            return {
                logs: `[argocd] WARN: HTTP ${response.status} on sync for "${appName}" (${url}) — trying Kubernetes fallback. ${k8sSync.logs} ` +
                    `Set ARGOCD_PASSWORD for API login or grant this token applications/sync on the AppProject. ${tail}`
            };
        }
        if (allowSimulation() && (response.status === 401 || response.status === 403)) {
            return {
                logs: `[argocd] Simulated sync for ${appName} (HTTP ${response.status} — fix ARGOCD_AUTH_TOKEN for real sync)`
            };
        }
        if (response.status === 404) {
            if (env.PAAS_STRICT_INTEGRATIONS !== "true") {
                return {
                    logs: (ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "") +
                        `[argocd] WARN: Application "${appName}" not found (HTTP 404) — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false).`
                };
            }
            throw new IntegrationError(`Argo CD application "${appName}" was not found after auto-create. Check GITOPS_REPO_URL, ARGOCD_AUTH_TOKEN RBAC, and that chart path exists in GitOps (ARGOCD_APP_PREFIX="${env.ARGOCD_APP_PREFIX}").`);
        }
        if (response.status === 401) {
            if (lenientIntegrations) {
                return {
                    logs: (ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "") +
                        `[argocd] WARN: HTTP 401 on sync for "${appName}" — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false).`
                };
            }
            throw new IntegrationError(`Argo CD authentication failed (HTTP 401). ` +
                `Set ARGOCD_AUTH_TOKEN or ARGOCD_PASSWORD (admin password) in the PaaS frontend environment.`);
        }
        if (response.status === 403) {
            if (lenientIntegrations) {
                return {
                    logs: (ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "") +
                        `[argocd] WARN: HTTP 403 on sync for "${appName}" — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false).`
                };
            }
            const detail = body.trim() ? ` Response: ${body.slice(0, 500)}` : "";
            throw new IntegrationError(`Argo CD denied this request (HTTP 403) for application "${appName}". ` +
                `Check RBAC and that the Application exists and your token may sync it. ` +
                `Expected application name: "${appName}" (ARGOCD_APP_PREFIX="${env.ARGOCD_APP_PREFIX}").` +
                detail);
        }
        if (lenientIntegrations) {
            return {
                logs: (ensureLogs.length ? `${ensureLogs.join("\n")}\n` : "") +
                    `[argocd] WARN: sync failed (HTTP ${response.status}) — continuing with cluster workload wait (PAAS_STRICT_INTEGRATIONS=false). ${body.slice(0, 400)}`
            };
        }
        throw new IntegrationError(`Argo CD sync failed (${response.status}): ${body.slice(0, 800)}`);
    }
    const syncLine = `[argocd] Sync accepted for ${appName}`;
    return { logs: ensureLogs.length ? `${ensureLogs.join("\n")}\n${syncLine}` : syncLine };
}
function argoAuthMessage(): string {
    return "Set ARGOCD_AUTH_TOKEN or ARGOCD_PASSWORD (with ARGOCD_BASE_URL) to query Argo CD.";
}
async function argoAuthConfigured(): Promise<boolean> {
    if (!getArgoCdApiBase()) {
        return false;
    }
    return (await resolveArgoCdAuthHeader()) !== null;
}
function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
export async function waitForArgoApplicationReady(projectName: string, options?: {
    timeoutMs?: number;
    pollMs?: number;
    earlyExit?: () => Promise<boolean>;
}): Promise<{
    logs: string;
    ready: boolean;
}> {
    const timeoutMs = options?.timeoutMs ?? env.PAAS_DEPLOY_WAIT_ARGO_MS;
    const pollMs = options?.pollMs ?? 5000;
    const deadline = Date.now() + timeoutMs;
    const lines: string[] = [];
    while (Date.now() < deadline) {
        if (options?.earlyExit && await options.earlyExit()) {
            lines.push("[argocd] Stopped waiting — application URL is already reachable");
            return { logs: lines.join("\n"), ready: true };
        }
        const status = await getArgoApplicationStatus(projectName);
        const health = String(status.health || "").toLowerCase();
        const sync = String(status.syncStatus || "").toLowerCase();
        if (health === "healthy" && sync === "synced") {
            lines.push(`[argocd] Application ready (health=${status.health}, sync=${status.syncStatus})`);
            return { logs: lines.join("\n"), ready: true };
        }
        if (status.unreachableReason) {
            lines.push(`[argocd] waiting: ${status.unreachableReason}`);
        }
        else {
            lines.push(`[argocd] waiting: health=${status.health} sync=${status.syncStatus}`);
        }
        await sleep(pollMs);
    }
    lines.push(`[argocd] Timed out after ${timeoutMs}ms waiting for Healthy+Synced`);
    return { logs: lines.join("\n"), ready: false };
}

let cachedSessionToken: string | null = null;
let cachedSessionExpiresAt = 0;

function configuredPassword(): string {
    return env.ARGOCD_PASSWORD.trim();
}

function configuredUsername(): string {
    return env.ARGOCD_USERNAME.trim() || "admin";
}

export function clearArgoCdSessionCache(): void {
    cachedSessionToken = null;
    cachedSessionExpiresAt = 0;
}

async function loginForSessionToken(): Promise<string | null> {
    const base = getArgoCdApiBase();
    const password = configuredPassword();
    if (!base || !password) {
        return null;
    }
    const response = await argocdIntegrationFetch(`${base}/api/v1/session`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            username: configuredUsername(),
            password
        })
    });
    if (!response.ok) {
        return null;
    }
    const payload = (await response.json()) as {
        token?: string;
    };
    const token = payload.token?.trim();
    if (!token) {
        return null;
    }
    cachedSessionToken = token;
    cachedSessionExpiresAt = Date.now() + 25 * 60_000;
    return token;
}

export async function resolveArgoCdAuthToken(): Promise<string | null> {
    if (configuredPassword()) {
        if (cachedSessionToken && Date.now() < cachedSessionExpiresAt) {
            return cachedSessionToken;
        }
        const sessionToken = await loginForSessionToken();
        if (sessionToken) {
            return sessionToken;
        }
    }
    const staticToken = env.ARGOCD_AUTH_TOKEN.trim();
    if (staticToken) {
        return staticToken;
    }
    if (cachedSessionToken && Date.now() < cachedSessionExpiresAt) {
        return cachedSessionToken;
    }
    return loginForSessionToken();
}

export async function resolveArgoCdAuthHeader(): Promise<Record<string, string> | null> {
    let token = await resolveArgoCdAuthToken();
    if (!token) {
        return null;
    }
    return { Authorization: `Bearer ${token}` };
}

export async function argocdFetchWithAuth(url: string, init: RequestInit = {}): Promise<Response> {
    const baseHeaders = await resolveArgoCdAuthHeader();
    if (!baseHeaders) {
        throw new Error("Argo CD auth is not configured");
    }
    const mergedHeaders = {
        ...baseHeaders,
        ...(init.headers as Record<string, string> | undefined)
    };
    let response = await argocdIntegrationFetch(url, { ...init, headers: mergedHeaders });
    if (response.status !== 401 && response.status !== 403) {
        return response;
    }
    clearArgoCdSessionCache();
    const sessionToken = await loginForSessionToken();
    if (!sessionToken) {
        return response;
    }
    response = await argocdIntegrationFetch(url, {
        ...init,
        headers: {
            Authorization: `Bearer ${sessionToken}`,
            ...(init.headers as Record<string, string> | undefined)
        }
    });
    return response;
}
