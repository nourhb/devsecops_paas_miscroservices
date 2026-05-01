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
            .replace(/\{\{subdomain\}\}/gi, subdomain);
    }
    let scheme = env.APPS_PUBLIC_URL_SCHEME.trim().toLowerCase() || "https";
    scheme = scheme.replace(/:$/, "").replace(/\/$/, "");
    const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
    return `${scheme}://${subdomain}.${domain}`;
}
export function resolveAppUrlForClient(projectName: string, storedUrl: string | null | undefined): string {
    const stored = (storedUrl ?? "").trim();
    if (allowSimulation()) {
        return buildAppPublicUrl(projectName);
    }
    return stored || buildAppPublicUrl(projectName);
}
