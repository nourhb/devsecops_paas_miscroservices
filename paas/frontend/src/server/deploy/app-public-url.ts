import { env } from "@/server/config/env";
import { allowSimulation } from "@/server/integrations/integration-mode";

/** Lab VM IP for nip.io URLs (`http://{app}.{ip}.nip.io:30659/`). */
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
