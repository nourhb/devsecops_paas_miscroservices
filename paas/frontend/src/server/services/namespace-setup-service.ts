import type { V1Secret } from "@kubernetes/client-node";
import { env } from "@/server/config/env";
import { harborDockerConfigSecretData } from "@/server/deploy/harbor-pull-secret";
import { getCoreV1Api } from "@/server/integrations/kubernetes-client";

const HARBOR_PULL_SECRET = "harbor-regcred";

function harborSecretSourceNamespace(): string {
    return (process.env.PAAS_K8S_NAMESPACE || process.env.PAAS_NS || "paas").trim() || "paas";
}

export async function ensureProjectNamespaceReady(namespace: string): Promise<{
    logs: string;
    warnings: string[];
}> {
    const warnings: string[] = [];
    const logs: string[] = [];
    const api = getCoreV1Api();
    if (!api || env.KUBERNETES_ENABLED !== "true") {
        return {
            logs: "[k8s] Kubernetes API unavailable — namespace pull-secret sync skipped (Argo may still create the namespace).",
            warnings
        };
    }
    const ns = namespace.trim();
    if (!ns) {
        return { logs: "[k8s] Empty namespace — skipped.", warnings };
    }
    try {
        await api.readNamespace(ns);
    }
    catch {
        try {
            await api.createNamespace({ metadata: { name: ns } });
            logs.push(`[k8s] Created namespace ${ns}`);
        }
        catch (error) {
            const msg = error instanceof Error ? error.message : String(error);
            warnings.push(`Could not create namespace ${ns}: ${msg}`);
        }
    }
    const sourceNs = harborSecretSourceNamespace();
    let secretData: Record<string, string> | null = null;
    try {
        const { body: sourceSecret } = await api.readNamespacedSecret(HARBOR_PULL_SECRET, sourceNs);
        secretData = sourceSecret.data ?? null;
        if (!secretData) {
            warnings.push(`Harbor pull secret ${HARBOR_PULL_SECRET} in ${sourceNs} has no data.`);
        }
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        warnings.push(`Could not read ${HARBOR_PULL_SECRET} from ${sourceNs}: ${msg}`);
    }
    if (!secretData) {
        secretData = harborDockerConfigSecretData();
        if (secretData) {
            logs.push(`[k8s] Built ${HARBOR_PULL_SECRET} from HARBOR_REGISTRY credentials (namespace copy unavailable).`);
        }
    }
    if (secretData) {
        const copy: V1Secret = {
            metadata: { name: HARBOR_PULL_SECRET, namespace: ns },
            type: "kubernetes.io/dockerconfigjson",
            data: secretData
        };
        try {
            await api.createNamespacedSecret(ns, copy);
            logs.push(`[k8s] Copied ${HARBOR_PULL_SECRET} into namespace ${ns}`);
        }
        catch (createError) {
            const msg = createError instanceof Error ? createError.message : String(createError);
            if (/already exists|409/i.test(msg)) {
                await api.replaceNamespacedSecret(HARBOR_PULL_SECRET, ns, copy);
                logs.push(`[k8s] Updated ${HARBOR_PULL_SECRET} in namespace ${ns}`);
            }
            else {
                warnings.push(`Could not copy ${HARBOR_PULL_SECRET} to ${ns}: ${msg}`);
            }
        }
    }
    else {
        warnings.push(`Harbor pull secret not available — set HARBOR_REGISTRY/HARBOR_USERNAME/HARBOR_PASSWORD or create ${HARBOR_PULL_SECRET} in ${sourceNs}.`);
    }
    return { logs: logs.join("\n") || `[k8s] Namespace ${ns} ready.`, warnings };
}
