import { env } from "@/server/config/env";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
export function argoApplicationName(projectName: string): string {
    return `${env.ARGOCD_APP_PREFIX}-${projectName}`;
}
export async function syncArgoApplication(projectName: string): Promise<{
    logs: string;
}> {
    const base = env.ARGOCD_BASE_URL.replace(/\/$/, "");
    const token = env.ARGOCD_AUTH_TOKEN.trim();
    const appName = argoApplicationName(projectName);
    if (!base || !token) {
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated sync for ${appName} (Argo CD not configured).` };
        }
        throw new IntegrationError("Argo CD is not configured: set ARGOCD_BASE_URL and ARGOCD_AUTH_TOKEN (or ARGOCD_URL / ARGOCD_TOKEN).");
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
            body: "{}"
        });
    }
    catch (e) {
        const msg = formatFetchErrorChain(e);
        if (allowSimulation()) {
            return { logs: `[argocd] Simulated sync for ${appName} (request failed: ${msg})` };
        }
        const tlsHint = env.ARGOCD_TLS_SKIP_VERIFY !== "true" && env.ARGOCD_BASE_URL.startsWith("https:")
            ? " If Argo CD uses a self-signed certificate, set ARGOCD_TLS_SKIP_VERIFY=true (lab only)."
            : "";
        const infraHint = /connect|refused|timeout|ECONNREFUSED/i.test(msg)
            ? " On the cluster, ensure `kubectl get deploy -n argocd argocd-server` shows READY pods and `kubectl get endpoints -n argocd argocd-server` is non-empty; try ARGOCD_BASE_URL with the HTTP NodePort (port 80 mapping) if HTTPS fails."
            : "";
        throw new IntegrationError(`Argo CD sync request failed: ${msg}${tlsHint}${infraHint}`);
    }
    if (!response.ok) {
        const body = await response.text();
        if (allowSimulation() && (response.status === 401 || response.status === 403)) {
            return {
                logs: `[argocd] Simulated sync for ${appName} (HTTP ${response.status} — fix ARGOCD_AUTH_TOKEN for real sync)`
            };
        }
        if (response.status === 404) {
            throw new IntegrationError(`Argo CD application "${appName}" was not found. Create it in Argo CD or adjust ARGOCD_APP_PREFIX (current prefix: "${env.ARGOCD_APP_PREFIX}").`);
        }
        if (response.status === 401) {
            throw new IntegrationError(`Argo CD authentication failed (HTTP 401). ` +
                `Regenerate a JWT (Argo CD UI: generate token, or run \`python paas/scripts/refresh_argocd_token.py\` with ARGOCD_REFRESH_SSH_PASSWORD) and set ARGOCD_AUTH_TOKEN.`);
        }
        if (response.status === 403) {
            const hint = body.trim() ? ` Response: ${body.slice(0, 500)}` : "";
            throw new IntegrationError(
                `Argo CD denied this request (HTTP 403) for application "${appName}". ` +
                    `The bearer token must be allowed to **sync** this app (Argo CD RBAC / AppProject policies), or use an admin API token. ` +
                    `Confirm the Application exists and matches ARGOCD_APP_PREFIX="${env.ARGOCD_APP_PREFIX}" (expected name: "${appName}").` +
                    hint
            );
        }
        throw new IntegrationError(`Argo CD sync failed (${response.status}): ${body.slice(0, 800)}`);
    }
    return { logs: `[argocd] Sync accepted for ${appName}` };
}
