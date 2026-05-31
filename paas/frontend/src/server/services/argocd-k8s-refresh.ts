import { env } from "@/server/config/env";
import { getCustomObjectsApi } from "@/server/integrations/kubernetes-client";

type PatchCustomObject = (
    group: string,
    version: string,
    namespace: string,
    plural: string,
    name: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    options?: {
        headers?: Record<string, string>;
    }
) => Promise<unknown>;

function argocdNamespace(): string {
    return (process.env.ARGOCD_NAMESPACE || "argocd").trim() || "argocd";
}

async function patchArgoApplication(appName: string, body: Record<string, unknown>): Promise<void> {
    const api = getCustomObjectsApi();
    if (!api) {
        throw new Error("Kubernetes client unavailable.");
    }
    await (api as unknown as { patchNamespacedCustomObject: PatchCustomObject }).patchNamespacedCustomObject(
        "argoproj.io",
        "v1alpha1",
        argocdNamespace(),
        "applications",
        appName,
        body,
        undefined,
        undefined,
        undefined,
        undefined,
        { headers: { "Content-Type": "application/merge-patch+json" } }
    );
}

/** Hard refresh — does not start a sync operation. */
export async function refreshArgoApplicationViaK8s(appName: string): Promise<{
    ok: boolean;
    logs: string;
}> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return { ok: false, logs: "[argocd-k8s] Kubernetes API disabled." };
    }
    try {
        await patchArgoApplication(appName, {
            metadata: {
                annotations: {
                    "argocd.argoproj.io/refresh": "hard"
                }
            }
        });
        return {
            ok: true,
            logs: `[argocd-k8s] Requested hard refresh for Application "${appName}" in namespace ${argocdNamespace()}.`
        };
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        return { ok: false, logs: `[argocd-k8s] Could not patch Application "${appName}": ${msg}` };
    }
}

/** Trigger Argo CD sync via the Application CR (no argocd CLI / API token required). */
export async function syncArgoApplicationViaK8s(appName: string): Promise<{
    ok: boolean;
    logs: string;
}> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return { ok: false, logs: "[argocd-k8s] Kubernetes API disabled." };
    }
    try {
        await patchArgoApplication(appName, {
            metadata: {
                annotations: {
                    "argocd.argoproj.io/refresh": "hard"
                }
            }
        });
        await patchArgoApplication(appName, {
            operation: {
                initiatedBy: { username: "paas-frontend" },
                sync: {
                    revision: "HEAD",
                    prune: false,
                    syncStrategy: { apply: { force: true } }
                }
            }
        });
        return {
            ok: true,
            logs: `[argocd-k8s] Sync triggered for Application "${appName}" via Kubernetes API.`
        };
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        return { ok: false, logs: `[argocd-k8s] Could not sync Application "${appName}": ${msg}` };
    }
}
