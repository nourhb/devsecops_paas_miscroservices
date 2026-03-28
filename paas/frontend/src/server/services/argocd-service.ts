import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";

export function argoApplicationName(projectName: string): string {
  return `${env.ARGOCD_APP_PREFIX}-${projectName}`;
}

/**
 * POST /api/v1/applications/{app}/sync — uses ARGOCD_BASE_URL + ARGOCD_AUTH_TOKEN
 * (aliases ARGOCD_URL / ARGOCD_TOKEN are resolved in env.ts).
 */
export async function syncArgoApplication(projectName: string): Promise<{ logs: string }> {
  const base = env.ARGOCD_BASE_URL.replace(/\/$/, "");
  const token = env.ARGOCD_AUTH_TOKEN.trim();
  const appName = argoApplicationName(projectName);

  if (!base || !token) {
    if (allowSimulation()) {
      return { logs: `[argocd] Simulated sync for ${appName} (Argo CD not configured).` };
    }
    throw new IntegrationError(
      "Argo CD is not configured: set ARGOCD_BASE_URL and ARGOCD_AUTH_TOKEN (or ARGOCD_URL / ARGOCD_TOKEN)."
    );
  }

  const url = `${base}/api/v1/applications/${encodeURIComponent(appName)}/sync`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json"
    }
  });

  if (!response.ok) {
    const body = await response.text();
    throw new IntegrationError(`Argo CD sync failed (${response.status}): ${body.slice(0, 800)}`);
  }

  return { logs: `[argocd] Sync accepted for ${appName}` };
}
