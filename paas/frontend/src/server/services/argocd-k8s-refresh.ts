import { env } from "@/server/config/env";
import { getCustomObjectsApi } from "@/server/integrations/kubernetes-client";

export async function refreshArgoApplicationViaK8s(appName: string): Promise<{
    ok: boolean;
    logs: string;
}> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return { ok: false, logs: "[argocd-k8s] Kubernetes API disabled." };
    }
    const api = getCustomObjectsApi();
    if (!api) {
        return { ok: false, logs: "[argocd-k8s] Kubernetes client unavailable." };
    }
    const namespace = (process.env.ARGOCD_NAMESPACE || "argocd").trim() || "argocd";
    const patch = {
        metadata: {
            annotations: {
                "argocd.argoproj.io/refresh": "hard"
            }
        }
    };
    try {
        await (api as unknown as {
            patchNamespacedCustomObject: (
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
        }).patchNamespacedCustomObject("argoproj.io", "v1alpha1", namespace, "applications", appName, patch, undefined, undefined, undefined, undefined, {
            headers: { "Content-Type": "application/merge-patch+json" }
        });
        return {
            ok: true,
            logs: `[argocd-k8s] Requested hard refresh for Application "${appName}" in namespace ${namespace}.`
        };
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        return { ok: false, logs: `[argocd-k8s] Could not patch Application "${appName}": ${msg}` };
    }
}
