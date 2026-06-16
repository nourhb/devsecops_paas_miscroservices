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

function inferArgoHealth(status?: {
    health?: { status?: string; message?: string };
    sync?: { status?: string };
    resources?: Array<{ health?: { status?: string } }>;
}): string {
    const explicit = status?.health?.status?.trim();
    if (explicit && explicit !== "Unknown") {
        return explicit;
    }
    const sync = status?.sync?.status?.trim();
    if (sync === "Synced") {
        const resources = status?.resources ?? [];
        if (resources.length === 0 || resources.every((r) => (r.health?.status || "Healthy") === "Healthy")) {
            return "Healthy";
        }
    }
    const message = status?.health?.message?.toLowerCase() ?? "";
    if (message.includes("successfully synced")) {
        return "Healthy";
    }
    return explicit || "Unknown";
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

export async function getArgoApplicationStatusViaK8s(appName: string): Promise<{
    ok: boolean;
    health: string;
    syncStatus: string;
    logs: string;
}> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return { ok: false, health: "Unknown", syncStatus: "Unknown", logs: "[argocd-k8s] Kubernetes API disabled." };
    }
    const api = getCustomObjectsApi();
    if (!api) {
        return { ok: false, health: "Unknown", syncStatus: "Unknown", logs: "[argocd-k8s] Kubernetes client unavailable." };
    }
    const namespace = argocdNamespace();
    try {
        const body = (await (api as unknown as {
            getNamespacedCustomObject: (
                group: string,
                version: string,
                ns: string,
                plural: string,
                name: string
            ) => Promise<unknown>;
        }).getNamespacedCustomObject("argoproj.io", "v1alpha1", namespace, "applications", appName)) as {
            status?: {
                health?: { status?: string; message?: string };
                sync?: { status?: string };
                resources?: Array<{ health?: { status?: string } }>;
            };
        };
        return {
            ok: true,
            health: inferArgoHealth(body.status),
            syncStatus: body.status?.sync?.status ?? "Unknown",
            logs: `[argocd-k8s] Read Application "${appName}" status from namespace ${namespace}.`
        };
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        return { ok: false, health: "Unknown", syncStatus: "Unknown", logs: `[argocd-k8s] Could not read Application "${appName}": ${msg}` };
    }
}

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
