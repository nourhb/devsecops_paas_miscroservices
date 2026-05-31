import { env } from "@/server/config/env";
import { sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-paths";
import { integrationFetch } from "@/server/http/integration-fetch";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Helm Service name = {release}-{chart}; per-project charts use apps/{project}, not apps/simple-app. */
function gitopsChartShortNameForProject(projectName: string): string {
    const chartPath = gitopsHelmChartPathForProject(projectName).replace(/\\/g, "/").replace(/\/$/, "");
    return chartPath.split("/").filter(Boolean).pop() ?? "simple-app";
}

export function buildInClusterAppServiceUrl(projectName: string, namespace: string): string {
    const prefix = env.ARGOCD_APP_PREFIX.trim() || "paas";
    const release = `${prefix}-${sanitizeDeployImageName(projectName)}`;
    const chart = gitopsChartShortNameForProject(projectName);
    const ns = namespace.trim();
    return `http://${release}-${chart}.${ns}.svc.cluster.local`;
}

async function probeSingleUrl(url: string, perAttemptMs: number): Promise<{
    ok: boolean;
    statusCode: number | null;
    error: string;
}> {
    let lastStatus: number | null = null;
    let lastError = "unreachable";
    for (const method of ["GET", "HEAD"] as const) {
        try {
            const response = await integrationFetch(url, {
                method,
                redirect: "follow",
                cache: "no-store"
            }, { timeoutMs: perAttemptMs, bypassHostRemap: url.includes(".svc.cluster.local") });
            lastStatus = response.status;
            if (response.status >= 200 && response.status < 400) {
                return { ok: true, statusCode: response.status, error: "" };
            }
            if (response.status === 404) {
                lastError = "ingress_pending";
            }
            else if (response.status === 502 || response.status === 503) {
                lastError = "upstream_not_ready";
            }
            else {
                lastError = `http_${response.status}`;
            }
        }
        catch (error) {
            lastError = error instanceof Error ? error.message : String(error);
        }
    }
    return { ok: false, statusCode: lastStatus, error: lastError };
}

export async function probeAppUrlReachability(url: string, options?: {
    timeoutMs?: number;
    maxAttempts?: number;
    delayMs?: number;
    namespace?: string;
    projectName?: string;
}): Promise<{
    reachable: boolean;
    statusCode: number | null;
    error?: string;
    via?: "public" | "in_cluster";
}> {
    const trimmed = url.trim();
    if (!trimmed) {
        return { reachable: false, statusCode: null, error: "empty_url" };
    }
    const maxAttempts = Math.max(1, options?.maxAttempts ?? 24);
    const delayMs = Math.max(1000, options?.delayMs ?? env.PAAS_DEPLOY_HTTP_POLL_MS);
    const perAttemptMs = Math.max(3000, options?.timeoutMs ?? env.APPS_REACHABILITY_TIMEOUT_MS);
    const inClusterUrl = options?.namespace && options?.projectName && env.KUBERNETES_ENABLED === "true"
        ? buildInClusterAppServiceUrl(options.projectName, options.namespace)
        : null;
    let lastStatus: number | null = null;
    let lastError = "unreachable";
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const pub = await probeSingleUrl(trimmed, perAttemptMs);
        if (pub.ok) {
            return { reachable: true, statusCode: pub.statusCode, via: "public" };
        }
        lastStatus = pub.statusCode;
        lastError = pub.error;
        if (inClusterUrl) {
            const internal = await probeSingleUrl(inClusterUrl, perAttemptMs);
            if (internal.ok) {
                return { reachable: true, statusCode: internal.statusCode, via: "in_cluster" };
            }
        }
        const retryable = lastError === "ingress_pending" || lastError === "upstream_not_ready" || /timed out|fetch failed|ECONNREFUSED|ENOTFOUND/i.test(lastError);
        if (!retryable && attempt >= 3) {
            break;
        }
        if (attempt < maxAttempts) {
            await sleep(delayMs);
        }
    }
    return { reachable: false, statusCode: lastStatus, error: lastError };
}
