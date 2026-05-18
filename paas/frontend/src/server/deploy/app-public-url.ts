import { env } from "@/server/config/env";
import { allowSimulation } from "@/server/integrations/integration-mode";
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
            .replace(/\{\{labNodeIp\}\}/gi, env.APPS_PUBLIC_LAB_NODE_IP.trim());
    }
    const labIp = env.APPS_PUBLIC_LAB_NODE_IP.trim();
    if (labIp) {
        const port = env.APPS_PUBLIC_INGRESS_HTTP_PORT.trim().replace(/^:/, "");
        const portSuffix = port ? `:${port}` : "";
        return `http://${subdomain}.${labIp}.nip.io${portSuffix}`;
    }
    let scheme = env.APPS_PUBLIC_URL_SCHEME.trim().toLowerCase() || "https";
    scheme = scheme.replace(/:$/, "").replace(/\/$/, "");
    const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
    return `${scheme}://${subdomain}.${domain}`;
}
export function buildAppIngressHost(projectName: string): string {
    const labIp = env.APPS_PUBLIC_LAB_NODE_IP.trim();
    const subdomain = appSubdomainFromProjectName(projectName);
    if (labIp) {
        return `${subdomain}.${labIp}.nip.io`;
    }
    const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
    return `${subdomain}.${domain}`;
}
export function resolveAppUrlForClient(projectName: string, storedUrl: string | null | undefined): string {
    const stored = (storedUrl ?? "").trim();
    if (allowSimulation()) {
        return buildAppPublicUrl(projectName);
    }
    return stored || buildAppPublicUrl(projectName);
}
