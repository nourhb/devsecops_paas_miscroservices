import { env } from "@/server/config/env";
import { sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { gitopsChartShortNameForProject } from "@/server/gitops/gitops-blue-green";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { integrationFetch } from "@/server/http/integration-fetch";

function parseIpv4HostFromUrl(raw: string): string {
    const value = raw.trim();
    if (!value) {
        return "";
    }
    try {
        const host = new URL(value).hostname;
        return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) ? host : "";
    }
    catch {
        return "";
    }
}

export function resolveLabNodeIp(): string {
    return env.APPS_PUBLIC_LAB_NODE_IP.trim()
        || env.NODE_IP.trim()
        || parseIpv4HostFromUrl(env.APP_BASE_URL)
        || parseIpv4HostFromUrl(env.JENKINS_BASE_URL);
}

export function resolveLabIngressHttpPort(): string {
    return env.APPS_PUBLIC_INGRESS_HTTP_PORT.trim().replace(/^:/, "") || "30659";
}
export function appSubdomainFromProjectName(projectName: string): string {
    return (projectName
        .toLowerCase()
        .replace(/[^a-z0-9-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "") || "app");
}
export function buildAppPublicUrl(projectName: string): string {
    const template = env.APPS_PUBLIC_URL_TEMPLATE.trim();
    const subdomain = appSubdomainFromProjectName(projectName);
    if (template) {
        return template
            .replace(/\{\{projectName\}\}/gi, projectName)
            .replace(/\{\{subdomain\}\}/gi, subdomain)
            .replace(/\{\{labNodeIp\}\}/gi, resolveLabNodeIp());
    }
    const labIp = resolveLabNodeIp();
    if (labIp) {
        const port = resolveLabIngressHttpPort();
        const portSuffix = port ? `:${port}` : "";
        return `http://${subdomain}.${labIp}.nip.io${portSuffix}`;
    }
    let scheme = env.APPS_PUBLIC_URL_SCHEME.trim().toLowerCase() || "https";
    scheme = scheme.replace(/:$/, "").replace(/\/$/, "");
    const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
    return `${scheme}://${subdomain}.${domain}`;
}
export function buildAppIngressHost(projectName: string): string {
    const labIp = resolveLabNodeIp();
    const subdomain = appSubdomainFromProjectName(projectName);
    if (labIp) {
        return `${subdomain}.${labIp}.nip.io`;
    }
    const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
    return `${subdomain}.${domain}`;
}
export function isSyntheticLocalAppUrl(url: string | null | undefined): boolean {
    const raw = (url ?? "").trim();
    if (!raw) {
        return false;
    }
    try {
        const host = new URL(raw).hostname.toLowerCase();
        return host.endsWith(".local") || host === "localhost" || host.endsWith(".localhost");
    }
    catch {
        return false;
    }
}

export function resolveAppUrlForClient(projectName: string, storedUrl: string | null | undefined): string {
    const canonical = buildAppPublicUrl(projectName);
    const stored = (storedUrl ?? "").trim();
    if (allowSimulation() || resolveLabNodeIp()) {
        return canonical;
    }
    if (stored && isSyntheticLocalAppUrl(stored)) {
        return canonical;
    }
    return stored || canonical;
}

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
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
                if (method === "GET") {
                    const body = await response.text().catch(() => "");
                    if (/Application error: a client-side exception has occurred/i.test(body)) {
                        lastError = "client_side_exception";
                        continue;
                    }
                    if (/Template parse errors:/i.test(body)) {
                        lastError = "angular_template_error";
                        continue;
                    }
                }
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

export async function probeAppUrlLiveQuick(url: string): Promise<{
    reachable: boolean;
    statusCode: number | null;
}> {
    const trimmed = url.trim();
    if (!trimmed) {
        return { reachable: false, statusCode: null };
    }
    const ms = env.APPS_REACHABILITY_TIMEOUT_MS;
    for (const method of ["HEAD", "GET"] as const) {
        try {
            const response = await fetch(trimmed, {
                method,
                redirect: "follow",
                signal: AbortSignal.timeout(ms)
            });
            if (response.status >= 200 && response.status < 400) {
                return { reachable: true, statusCode: response.status };
            }
        }
        catch {
        }
    }
    return { reachable: false, statusCode: null };
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
