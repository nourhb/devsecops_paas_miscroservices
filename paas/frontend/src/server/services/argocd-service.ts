import { env } from "@/server/config/env";
import { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-github-service";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
import type { ArgoCdStatus } from "@/types";
export function argoApplicationName(projectName: string): string {
    return `${env.ARGOCD_APP_PREFIX}-${projectName}`;
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
    const token = env.ARGOCD_AUTH_TOKEN.trim();
    if (!base || !token) {
        return "error";
    }
    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}`;
    try {
        const response = await argocdIntegrationFetch(url, {
            method: "GET",
            headers: { Authorization: `Bearer ${token}` }
        });
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
/**
 * Ensures an Argo CD Application exists (equivalent to `argocd app create` for the GitOps chart path).
 * Idempotent: no-op when the app already exists or auto-create is disabled.
 */
export async function ensureArgoCdApplication(projectName: string, destinationNamespace?: string): Promise<{
    logs: string;
    created: boolean;
}> {
    const appName = argoApplicationName(projectName);
    if (env.ARGOCD_AUTO_CREATE_APPLICATION !== "true") {
        return { logs: `[argocd] Auto-create disabled (ARGOCD_AUTO_CREATE_APPLICATION=false).`, created: false };
    }
    const base = getArgoCdApiBase();
    const token = env.ARGOCD_AUTH_TOKEN.trim();
    if (!base || !token) {
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated ensure for ${appName} (Argo CD not configured).`, created: false };
        }
        throw new IntegrationError("Argo CD is not configured: set ARGOCD_BASE_URL and ARGOCD_AUTH_TOKEN to auto-create Applications.");
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
        response = await argocdIntegrationFetch(createUrl, {
            method: "POST",
            headers: {
                Authorization: `Bearer ${token}`,
                "Content-Type": "application/json"
            },
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
        const chartPath = (body.spec as { source: { path: string } }).source.path;
        const repoUrl = (body.spec as { source: { repoURL: string } }).source.repoURL;
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
    const base = getArgoCdApiBase();
    const token = env.ARGOCD_AUTH_TOKEN.trim();
    const appName = argoApplicationName(projectName);
    if (!base || !token) {
        return {
            health: "Unknown",
            syncStatus: "Unknown",
            appName,
            unreachableReason: "Set ARGOCD_BASE_URL (or ARGOCD_URL) and ARGOCD_AUTH_TOKEN (or ARGOCD_TOKEN) to query Argo CD."
        };
    }
    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}`;
    try {
        const response = await argocdIntegrationFetch(url, {
            method: "GET",
            headers: { Authorization: `Bearer ${token}` }
        });
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
                        `Regenerate the token or grant applications, get (and sync for deploy) on the AppProject. ${errText}`
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
            throw e;
        }
        const msg = formatFetchErrorChain(e);
        if (!allowSimulation()) {
            const tlsHint = env.ARGOCD_TLS_SKIP_VERIFY !== "true" && env.INTEGRATIONS_TLS_SKIP_VERIFY !== "true" && base.startsWith("https:")
                ? " If the server uses a self-signed cert, set ARGOCD_TLS_SKIP_VERIFY=true or INTEGRATIONS_TLS_SKIP_VERIFY=true (lab only)."
                : "";
            throw new IntegrationError(`Argo CD status request failed: ${msg}${tlsHint}`);
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
    const token = env.ARGOCD_AUTH_TOKEN.trim();
    const appName = argoApplicationName(projectName);
    if (!base || !token) {
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated sync for ${appName} (Argo CD not configured).` };
        }
        throw new IntegrationError("Argo CD is not configured: set ARGOCD_BASE_URL and ARGOCD_AUTH_TOKEN (or ARGOCD_URL / ARGOCD_TOKEN).");
    }
    const ensureLogs: string[] = [];
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
    const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}/sync`;
    let response: Response;
    try {
        response = await argocdIntegrationFetch(url, {
            method: "POST",
            headers: {
                Authorization: `Bearer ${token}`,
                "Content-Type": "application/json"
            },
            body: JSON.stringify({ prune: false, dryRun: false })
        });
    }
    catch (e) {
        const msg = formatFetchErrorChain(e);
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated sync for ${appName} (request failed: ${msg})` };
        }
        const tlsHint = env.ARGOCD_TLS_SKIP_VERIFY !== "true" && env.INTEGRATIONS_TLS_SKIP_VERIFY !== "true" && base.startsWith("https:")
            ? " If Argo CD uses a self-signed certificate, set ARGOCD_TLS_SKIP_VERIFY=true or INTEGRATIONS_TLS_SKIP_VERIFY=true (lab only)."
            : "";
        const infraHint = /connect|refused|timeout|ECONNREFUSED/i.test(msg)
            ? " On the cluster, ensure `kubectl get deploy -n argocd argocd-server` shows READY pods and `kubectl get endpoints -n argocd argocd-server` is non-empty; try ARGOCD_BASE_URL with the HTTP NodePort (port 80 mapping) if HTTPS fails."
            : "";
        throw new IntegrationError(`Argo CD sync request failed: ${msg}${tlsHint}${infraHint}`);
    }
    if (!response.ok) {
        const body = await response.text();
        const lenientIntegrations = env.PAAS_STRICT_INTEGRATIONS !== "true";
        if ((response.status === 401 || response.status === 403) && lenientIntegrations) {
            const tail = body.trim() ? body.slice(0, 400) : "";
            return {
                logs: `[argocd] WARN: HTTP ${response.status} on sync for "${appName}" (${url}) — deployment continues (integrations not strict: PAAS_STRICT_INTEGRATIONS=${env.PAAS_STRICT_INTEGRATIONS}). ` +
                    `GitOps already committed Helm values; sync manually in Argo CD or grant this JWT applications, sync on the AppProject (or use an admin token). ${tail}`
            };
        }
        if (allowSimulation() && (response.status === 401 || response.status === 403)) {
            return {
                logs: `[argocd] Simulated sync for ${appName} (HTTP ${response.status} — fix ARGOCD_AUTH_TOKEN for real sync)`
            };
        }
        if (response.status === 404) {
            throw new IntegrationError(`Argo CD application "${appName}" was not found after auto-create. Check GITOPS_REPO_URL, ARGOCD_AUTH_TOKEN RBAC, and that chart path exists in GitOps (ARGOCD_APP_PREFIX="${env.ARGOCD_APP_PREFIX}").`);
        }
        if (response.status === 401) {
            throw new IntegrationError(`Argo CD authentication failed (HTTP 401). ` +
                `Regenerate a JWT (Argo CD UI: generate token, or run \`python paas/scripts/refresh_argocd_token.py\` with ARGOCD_REFRESH_SSH_PASSWORD) and set ARGOCD_AUTH_TOKEN.`);
        }
        if (response.status === 403) {
            const hint = body.trim() ? ` Response: ${body.slice(0, 500)}` : "";
            const labHint = " In lab, either fix Argo CD RBAC for this token, or set PAAS_STRICT_INTEGRATIONS=false in the frontend environment " +
                "(paas/docker-compose.yml already sets it) so deploy can complete after GitOps when only the Argo **API** sync is denied.";
            throw new IntegrationError(`Argo CD denied this request (HTTP 403) for application "${appName}". ` +
                `Check RBAC and that the Application exists and your token may sync it (Argo CD policies / admin token). ` +
                `Expected application name: "${appName}" (ARGOCD_APP_PREFIX="${env.ARGOCD_APP_PREFIX}").` +
                labHint +
                hint);
        }
        throw new IntegrationError(`Argo CD sync failed (${response.status}): ${body.slice(0, 800)}`);
    }
    const syncLine = `[argocd] Sync accepted for ${appName}`;
    return { logs: ensureLogs.length ? `${ensureLogs.join("\n")}\n${syncLine}` : syncLine };
}
