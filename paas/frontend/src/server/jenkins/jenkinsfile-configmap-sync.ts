import fs from "fs";
import * as k8s from "@kubernetes/client-node";
import { env } from "@/server/config/env";
import { getCoreV1Api } from "@/server/integrations/kubernetes-client";
import {
    jenkinsfileHasMultiFrameworkMarker,
    jenkinsfileHasNginxConfWritefileFix,
    readResolvedJenkinsfileGroovy
} from "@/server/jenkins/jenkinsfile-source";

const CONFIGMAP_NAME = "paas-jenkinsfile";
const CONFIGMAP_KEY = "Jenkinsfile.paas-deploy";
const CONFIGMAP_NAMESPACE = "paas";

/** Keep the mounted ConfigMap aligned with the image-embedded Jenkinsfile (ConfigMap mount hides image COPY). */
export async function syncJenkinsfileConfigMapFromEmbeddedIfNeeded(): Promise<string> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return "[jenkinsfile-cm] Skipped (KUBERNETES_ENABLED!=true).";
    }
    const core = getCoreV1Api();
    if (!core) {
        return "[jenkinsfile-cm] Skipped (no Kubernetes client).";
    }
    const resolved = readResolvedJenkinsfileGroovy();
    if (!resolved) {
        return "[jenkinsfile-cm] Skipped (Jenkinsfile not found on disk).";
    }
    if (!jenkinsfileHasMultiFrameworkMarker(resolved.groovy)) {
        return `[jenkinsfile-cm] Skipped (source missing multi-framework marker — rebuild frontend image).`;
    }
    if (!jenkinsfileHasNginxConfWritefileFix(resolved.groovy)) {
        return `[jenkinsfile-cm] Skipped (source missing nginx-conf-writefile-20260611 — SPA/Angular Step 6 uri fix; rebuild frontend image).`;
    }
    const ns = CONFIGMAP_NAMESPACE;
    const embeddedPath = `${process.cwd()}/paas-jenkinsfile-embedded/paas/jenkins/Jenkinsfile.paas-deploy`;
    let existing = "";
    try {
        const cm = await core.readNamespacedConfigMap(CONFIGMAP_NAME, ns);
        existing = cm.body.data?.[CONFIGMAP_KEY] ?? "";
    }
    catch (err: unknown) {
        const status = (err as { statusCode?: number }).statusCode;
        if (status !== 404) {
            return `[jenkinsfile-cm] WARN: read ConfigMap/${CONFIGMAP_NAME} failed (${String(status ?? err)}).`;
        }
    }
    if (existing === resolved.groovy) {
        return `[jenkinsfile-cm] OK — ConfigMap/${CONFIGMAP_NAME} already matches embedded Jenkinsfile.`;
    }
    const body: k8s.V1ConfigMap = {
        metadata: { name: CONFIGMAP_NAME, namespace: ns },
        data: { [CONFIGMAP_KEY]: resolved.groovy }
    };
    try {
        if (existing) {
            await core.replaceNamespacedConfigMap(CONFIGMAP_NAME, ns, body);
        }
        else {
            await core.createNamespacedConfigMap(ns, body);
        }
    }
    catch (err: unknown) {
        return `[jenkinsfile-cm] WARN: patch ConfigMap failed (${String(err)}). Mount may still serve stale pipeline until deploy-paas-frontend-k8s.sh runs.`;
    }
    if (fs.existsSync(embeddedPath)) {
        return `[jenkinsfile-cm] Updated ConfigMap/${CONFIGMAP_NAME} in ${ns} from embedded Jenkinsfile (multi-framework).`;
    }
    return `[jenkinsfile-cm] Updated ConfigMap/${CONFIGMAP_NAME} in ${ns} from ${resolved.source}.`;
}
