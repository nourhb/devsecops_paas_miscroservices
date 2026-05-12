import * as k8s from "@kubernetes/client-node";
import type { V1Pod } from "@kubernetes/client-node";
import fs from "node:fs";
import { env } from "@/server/config/env";
let coreApi: k8s.CoreV1Api | null | undefined;
let customObjectsApi: k8s.CustomObjectsApi | null | undefined;
let appsApi: k8s.AppsV1Api | null | undefined;
let kubeConfig: k8s.KubeConfig | null | undefined;
let kubeConfigCacheKey: string | undefined;
function applyKubeTlsOverrides(kc: k8s.KubeConfig): void {
    if (env.KUBE_TLS_SKIP_VERIFY !== "true") {
        return;
    }
    const clusters = (kc as unknown as {
        clusters?: Array<{
            skipTLSVerify?: boolean;
            caData?: string;
            caFile?: string;
        }>;
    }).clusters;
    if (!clusters?.length) {
        return;
    }
    for (const cluster of clusters) {
        cluster.skipTLSVerify = true;
        cluster.caData = "";
        cluster.caFile = "";
    }
}
function getKubeConfigCacheKey(): string {
    if (env.KUBERNETES_ENABLED !== "true") {
        return "disabled";
    }
    const kubePath = env.KUBE_CONFIG_PATH?.trim();
    if (!kubePath) {
        return process.env.KUBERNETES_SERVICE_HOST ? "in-cluster" : "default";
    }
    try {
        const stat = fs.statSync(kubePath);
        return `${kubePath}:${stat.mtimeMs}:${stat.size}`;
    }
    catch {
        return `${kubePath}:missing`;
    }
}
function clearKubeApiClients(): void {
    coreApi = undefined;
    customObjectsApi = undefined;
    appsApi = undefined;
}
function getKubeConfig(): k8s.KubeConfig | null {
    const cacheKey = getKubeConfigCacheKey();
    if (kubeConfig !== undefined && kubeConfigCacheKey === cacheKey) {
        return kubeConfig;
    }
    clearKubeApiClients();
    kubeConfigCacheKey = cacheKey;
    if (env.KUBERNETES_ENABLED !== "true") {
        kubeConfig = null;
        return null;
    }
    try {
        const kc = new k8s.KubeConfig();
        if (env.KUBE_CONFIG_PATH?.trim()) {
            kc.loadFromFile(env.KUBE_CONFIG_PATH.trim());
        }
        else if (process.env.KUBERNETES_SERVICE_HOST) {
            kc.loadFromCluster();
        }
        else {
            kc.loadFromDefault();
        }
        applyKubeTlsOverrides(kc);
        kubeConfig = kc;
        return kubeConfig;
    }
    catch {
        kubeConfig = null;
        return null;
    }
}
export function getCoreV1Api(): k8s.CoreV1Api | null {
    if (coreApi !== undefined) {
        return coreApi;
    }
    const kc = getKubeConfig();
    if (!kc) {
        coreApi = null;
        return null;
    }
    coreApi = kc.makeApiClient(k8s.CoreV1Api);
    return coreApi;
}
export function getCustomObjectsApi(): k8s.CustomObjectsApi | null {
    if (customObjectsApi !== undefined) {
        return customObjectsApi;
    }
    const kc = getKubeConfig();
    if (!kc) {
        customObjectsApi = null;
        return null;
    }
    customObjectsApi = kc.makeApiClient(k8s.CustomObjectsApi);
    return customObjectsApi;
}
export function getAppsV1Api(): k8s.AppsV1Api | null {
    if (appsApi !== undefined) {
        return appsApi;
    }
    const kc = getKubeConfig();
    if (!kc) {
        appsApi = null;
        return null;
    }
    appsApi = kc.makeApiClient(k8s.AppsV1Api);
    return appsApi;
}
function podBucket(pod: V1Pod): "running" | "failed" | "pending" | "succeeded" | "other" {
    const phase = pod.status?.phase;
    if (phase === "Running") {
        const ready = pod.status?.conditions?.find((c) => c.type === "Ready")?.status === "True";
        return ready ? "running" : "pending";
    }
    if (phase === "Failed") {
        return "failed";
    }
    if (phase === "Pending") {
        return "pending";
    }
    if (phase === "Succeeded") {
        return "succeeded";
    }
    return "other";
}
export interface NamespacePodSummary {
    running: number;
    failed: number;
    pending: number;
    succeeded: number;
    other: number;
    total: number;
    error?: string;
}
export interface ClusterPodRecord {
    name: string;
    namespace: string;
    containers: string[];
    status: string;
    health: string;
    healthReason: string;
    ready: string;
    restarts: number;
    nodeName: string;
    podIP: string;
    createdAt: string;
}
export interface ClusterServiceRecord {
    name: string;
    namespace: string;
    type: string;
    clusterIP: string;
    externalIP: string;
    ports: string[];
    selector: string;
    createdAt: string;
}
export interface ClusterDeploymentRecord {
    name: string;
    namespace: string;
    ready: string;
    replicas: number;
    available: number;
    updated: number;
    strategy: string;
    createdAt: string;
}
export interface ClusterNamespaceRecord {
    name: string;
    phase: string;
    createdAt: string;
}
function readBody<T>(response: unknown): T {
    if (response && typeof response === "object" && "body" in (response as Record<string, unknown>)) {
        return (response as {
            body: T;
        }).body;
    }
    return response as T;
}
function kubernetesErrorMessage(error: unknown): string {
    const e = error as {
        message?: string;
        statusCode?: number;
        response?: {
            status?: number;
            statusCode?: number;
            body?: unknown;
            data?: unknown;
        };
        body?: unknown;
    };
    const status = e.statusCode ?? e.response?.statusCode ?? e.response?.status;
    const body = e.body ?? e.response?.body ?? e.response?.data;
    const bodyMessage = body && typeof body === "object" && "message" in (body as Record<string, unknown>)
        ? String((body as {
            message?: unknown;
        }).message ?? "")
        : "";
    if (status === 401) {
        return "Kubernetes API unauthorized.";
    }
    if (status === 403) {
        return "Kubernetes API forbidden.";
    }
    if (status) {
        return bodyMessage ? `Kubernetes API returned HTTP ${status}: ${bodyMessage}` : `Kubernetes API returned HTTP ${status}.`;
    }
    return e.message || String(error);
}
function formatPodReady(pod: V1Pod): string {
    const statuses = pod.status?.containerStatuses ?? [];
    const ready = statuses.filter((status) => status.ready).length;
    const total = statuses.length;
    return `${ready}/${total}`;
}
function getPodContainers(pod: V1Pod): string[] {
    const names = [
        ...(pod.spec?.initContainers ?? []),
        ...(pod.spec?.containers ?? [])
    ]
        .map((container) => container.name)
        .filter(Boolean);
    return [...new Set(names)];
}
function getPodHealth(pod: V1Pod): {
    health: string;
    healthReason: string;
} {
    const containerStatuses = pod.status?.containerStatuses ?? [];
    for (const containerStatus of containerStatuses) {
        const waitingReason = containerStatus.state?.waiting?.reason?.trim();
        const terminatedReason = containerStatus.state?.terminated?.reason?.trim();
        if (waitingReason) {
            return {
                health: waitingReason,
                healthReason: containerStatus.state?.waiting?.message?.trim() || waitingReason
            };
        }
        if (terminatedReason) {
            return {
                health: terminatedReason,
                healthReason: containerStatus.state?.terminated?.message?.trim() || terminatedReason
            };
        }
    }
    const readyCondition = pod.status?.conditions?.find((condition) => condition.type === "Ready");
    if (pod.metadata?.deletionTimestamp) {
        return {
            health: "Terminating",
            healthReason: "Pod is being terminated."
        };
    }
    if (pod.status?.phase === "Running" && readyCondition?.status === "True") {
        return {
            health: "Healthy",
            healthReason: "Pod is running and ready."
        };
    }
    if (pod.status?.phase === "Running") {
        return {
            health: "NotReady",
            healthReason: "Pod is running but not ready yet."
        };
    }
    if (pod.status?.phase === "Pending") {
        return {
            health: "Pending",
            healthReason: "Pod is waiting for scheduling or image pull."
        };
    }
    if (pod.status?.phase === "Failed") {
        return {
            health: "Failed",
            healthReason: "Pod has entered the Failed phase."
        };
    }
    if (pod.status?.phase === "Succeeded") {
        return {
            health: "Succeeded",
            healthReason: "Pod completed successfully."
        };
    }
    return {
        health: "Unknown",
        healthReason: "No detailed pod health reason was returned."
    };
}
function sumPodRestarts(pod: V1Pod): number {
    const statuses = pod.status?.containerStatuses ?? [];
    return statuses.reduce((total, status) => total + (status.restartCount ?? 0), 0);
}
function normalizeServicePorts(ports: Array<{
    port?: number;
    protocol?: string;
    targetPort?: string | number;
}> | undefined): string[] {
    return (ports ?? []).map((port) => {
        const target = port.targetPort ?? "";
        const protocol = port.protocol ?? "TCP";
        return `${port.port ?? "-"}:${target || "-"} (${protocol})`;
    });
}
function normalizeSelector(selector?: Record<string, string>): string {
    return Object.entries(selector ?? {})
        .map(([key, value]) => `${key}=${value}`)
        .join(", ");
}
function normalizeExternalIps(service: {
    spec?: {
        externalIPs?: string[];
    };
    status?: {
        loadBalancer?: {
            ingress?: Array<{
                ip?: string;
                hostname?: string;
            }>;
        };
    };
}): string {
    const explicitIps = service.spec?.externalIPs ?? [];
    if (explicitIps.length) {
        return explicitIps.join(", ");
    }
    const ingress = service.status?.loadBalancer?.ingress ?? [];
    const values = ingress.map((item) => item.ip || item.hostname || "").filter(Boolean);
    return values.join(", ") || "-";
}
export async function getNamespacePodSummary(namespace: string): Promise<NamespacePodSummary> {
    const api = getCoreV1Api();
    if (!api) {
        return {
            running: 0,
            failed: 0,
            pending: 0,
            succeeded: 0,
            other: 0,
            total: 0,
            error: "Kubernetes API not configured."
        };
    }
    try {
        const { body } = await api.listNamespacedPod(namespace);
        const items = body.items ?? [];
        const counts = { running: 0, failed: 0, pending: 0, succeeded: 0, other: 0 };
        for (const pod of items) {
            const b = podBucket(pod);
            counts[b] += 1;
        }
        return {
            ...counts,
            total: items.length
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            running: 0,
            failed: 0,
            pending: 0,
            succeeded: 0,
            other: 0,
            total: 0,
            error: message
        };
    }
}
export async function listNamespacePods(namespace: string): Promise<{
    configured: boolean;
    items: ClusterPodRecord[];
    error?: string;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return {
            configured: false,
            items: [],
            error: "Kubernetes API not configured."
        };
    }
    const ns = namespace.trim();
    if (!ns) {
        return {
            configured: true,
            items: [],
            error: "Project namespace is empty."
        };
    }
    try {
        const { body } = await api.listNamespacedPod(ns);
        const items = (body.items ?? []).map((pod) => {
            const health = getPodHealth(pod);
            return {
                name: pod.metadata?.name ?? "",
                namespace: pod.metadata?.namespace ?? ns,
                containers: getPodContainers(pod),
                status: pod.status?.phase ?? "Unknown",
                health: health.health,
                healthReason: health.healthReason,
                ready: formatPodReady(pod),
                restarts: sumPodRestarts(pod),
                nodeName: pod.spec?.nodeName ?? "-",
                podIP: pod.status?.podIP ?? "-",
                createdAt: pod.metadata?.creationTimestamp?.toISOString?.() ?? ""
            };
        });
        return {
            configured: true,
            items
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            configured: true,
            items: [],
            error: message
        };
    }
}
export async function listClusterPods(): Promise<{
    configured: boolean;
    items: ClusterPodRecord[];
    error?: string;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return {
            configured: false,
            items: [],
            error: "Kubernetes API not configured."
        };
    }
    try {
        const response = await (api as any).listPodForAllNamespaces();
        const body = readBody<{
            items?: V1Pod[];
        }>(response);
        const items = (body.items ?? []).map((pod) => {
            const health = getPodHealth(pod);
            return {
                name: pod.metadata?.name ?? "",
                namespace: pod.metadata?.namespace ?? "default",
                containers: getPodContainers(pod),
                status: pod.status?.phase ?? "Unknown",
                health: health.health,
                healthReason: health.healthReason,
                ready: formatPodReady(pod),
                restarts: sumPodRestarts(pod),
                nodeName: pod.spec?.nodeName ?? "-",
                podIP: pod.status?.podIP ?? "-",
                createdAt: pod.metadata?.creationTimestamp?.toISOString?.() ?? ""
            };
        });
        return {
            configured: true,
            items
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            configured: true,
            items: [],
            error: message
        };
    }
}
export async function listClusterServices(): Promise<{
    configured: boolean;
    items: ClusterServiceRecord[];
    error?: string;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return {
            configured: false,
            items: [],
            error: "Kubernetes API not configured."
        };
    }
    try {
        const response = await (api as any).listServiceForAllNamespaces();
        const body = readBody<{
            items?: Array<{
                metadata?: {
                    name?: string;
                    namespace?: string;
                    creationTimestamp?: Date;
                };
                spec?: {
                    type?: string;
                    clusterIP?: string;
                    ports?: Array<{
                        port?: number;
                        protocol?: string;
                        targetPort?: string | number;
                    }>;
                    selector?: Record<string, string>;
                    externalIPs?: string[];
                };
                status?: {
                    loadBalancer?: {
                        ingress?: Array<{
                            ip?: string;
                            hostname?: string;
                        }>;
                    };
                };
            }>;
        }>(response);
        const items = (body.items ?? []).map((service) => ({
            name: service.metadata?.name ?? "",
            namespace: service.metadata?.namespace ?? "default",
            type: service.spec?.type ?? "ClusterIP",
            clusterIP: service.spec?.clusterIP ?? "-",
            externalIP: normalizeExternalIps(service),
            ports: normalizeServicePorts(service.spec?.ports),
            selector: normalizeSelector(service.spec?.selector),
            createdAt: service.metadata?.creationTimestamp?.toISOString?.() ?? ""
        }));
        return {
            configured: true,
            items
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            configured: true,
            items: [],
            error: message
        };
    }
}
export async function listClusterDeployments(): Promise<{
    configured: boolean;
    items: ClusterDeploymentRecord[];
    error?: string;
}> {
    const api = getAppsV1Api();
    if (!api) {
        return {
            configured: false,
            items: [],
            error: "Kubernetes API not configured."
        };
    }
    try {
        const response = await (api as any).listDeploymentForAllNamespaces();
        const body = readBody<{
            items?: Array<{
                metadata?: {
                    name?: string;
                    namespace?: string;
                    creationTimestamp?: Date;
                };
                spec?: {
                    replicas?: number;
                    strategy?: {
                        type?: string;
                    };
                };
                status?: {
                    readyReplicas?: number;
                    replicas?: number;
                    availableReplicas?: number;
                    updatedReplicas?: number;
                };
            }>;
        }>(response);
        const items = (body.items ?? []).map((deployment) => ({
            name: deployment.metadata?.name ?? "",
            namespace: deployment.metadata?.namespace ?? "default",
            ready: `${deployment.status?.readyReplicas ?? 0}/${deployment.spec?.replicas ?? deployment.status?.replicas ?? 0}`,
            replicas: deployment.spec?.replicas ?? deployment.status?.replicas ?? 0,
            available: deployment.status?.availableReplicas ?? 0,
            updated: deployment.status?.updatedReplicas ?? 0,
            strategy: deployment.spec?.strategy?.type ?? "RollingUpdate",
            createdAt: deployment.metadata?.creationTimestamp?.toISOString?.() ?? ""
        }));
        return {
            configured: true,
            items
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            configured: true,
            items: [],
            error: message
        };
    }
}
export async function getClusterNodeCount(): Promise<number | null> {
    const api = getCoreV1Api();
    if (!api) {
        return null;
    }
    try {
        const { body } = await api.listNode();
        return body.items?.length ?? 0;
    }
    catch {
        return null;
    }
}
export async function listClusterNamespaces(): Promise<{
    configured: boolean;
    items: ClusterNamespaceRecord[];
    error?: string;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return {
            configured: false,
            items: [],
            error: "Kubernetes API not configured."
        };
    }
    try {
        const response = await (api as any).listNamespace();
        const body = readBody<{
            items?: Array<{
                metadata?: {
                    name?: string;
                    creationTimestamp?: Date;
                };
                status?: {
                    phase?: string;
                };
            }>;
        }>(response);
        const items = (body.items ?? [])
            .map((ns) => ({
            name: ns.metadata?.name ?? "",
            phase: ns.status?.phase ?? "Unknown",
            createdAt: ns.metadata?.creationTimestamp?.toISOString?.() ?? ""
        }))
            .filter((row) => Boolean(row.name))
            .sort((a, b) => a.name.localeCompare(b.name));
        return {
            configured: true,
            items
        };
    }
    catch (e) {
        const message = kubernetesErrorMessage(e);
        return {
            configured: true,
            items: [],
            error: message
        };
    }
}
export async function aggregatePodCountsAcrossNamespaces(namespaces: string[]): Promise<{
    runningPods: number;
    failedPods: number;
    errors: string[];
}> {
    const unique = [...new Set(namespaces.map((n) => n.trim()).filter(Boolean))];
    let runningPods = 0;
    let failedPods = 0;
    const errors: string[] = [];
    for (const ns of unique) {
        const s = await getNamespacePodSummary(ns);
        runningPods += s.running;
        failedPods += s.failed;
        if (s.error) {
            errors.push(`${ns}: ${s.error}`);
        }
    }
    return { runningPods, failedPods, errors };
}
export function isKubernetesConfigured(): boolean {
    return getCoreV1Api() !== null;
}
export async function listPodsByLabel(namespace: string, labelSelector: string): Promise<V1Pod[]> {
    const api = getCoreV1Api();
    if (!api) {
        return [];
    }
    try {
        const { body } = await api.listNamespacedPod(namespace, undefined, undefined, undefined, undefined, labelSelector);
        return body.items ?? [];
    }
    catch {
        return [];
    }
}
export async function readPodLog(namespace: string, podName: string, container?: string): Promise<string | null> {
    const api = getCoreV1Api();
    if (!api) {
        return null;
    }
    try {
        const response = await (api as any).readNamespacedPodLog(podName, namespace, container || undefined, false, undefined, undefined, undefined, false, undefined, 500, true);
        return response.body ?? null;
    }
    catch (error) {
        return `Could not load logs: ${kubernetesErrorMessage(error)}`;
    }
}
export async function getKyvernoPolicyStatus(policyNames: string[]): Promise<{
    configured: boolean;
    enforcedPolicies: string[];
}> {
    const api = getCustomObjectsApi();
    if (!api) {
        return {
            configured: false,
            enforcedPolicies: []
        };
    }
    try {
        const response = await api.listClusterCustomObject("kyverno.io", "v1", "clusterpolicies");
        const items = ((response.body as {
            items?: Array<{
                metadata?: {
                    name?: string;
                };
                spec?: {
                    validationFailureAction?: string;
                };
            }>;
        }).items ?? []);
        const enforcedPolicies = items
            .filter((item) => policyNames.includes(item.metadata?.name || "") && item.spec?.validationFailureAction === "Enforce")
            .map((item) => item.metadata?.name || "")
            .filter(Boolean);
        return {
            configured: true,
            enforcedPolicies
        };
    }
    catch {
        return {
            configured: true,
            enforcedPolicies: []
        };
    }
}
