import * as k8s from "@kubernetes/client-node";
import type { V1Pod } from "@kubernetes/client-node";
import { env } from "@/server/config/env";

let coreApi: k8s.CoreV1Api | null | undefined;

function getCoreV1Api(): k8s.CoreV1Api | null {
  if (coreApi !== undefined) {
    return coreApi;
  }

  if (env.KUBERNETES_ENABLED !== "true") {
    coreApi = null;
    return null;
  }

  try {
    const kc = new k8s.KubeConfig();
    if (env.KUBE_CONFIG_PATH?.trim()) {
      kc.loadFromFile(env.KUBE_CONFIG_PATH.trim());
    } else if (process.env.KUBERNETES_SERVICE_HOST) {
      kc.loadFromCluster();
    } else {
      kc.loadFromDefault();
    }
    coreApi = kc.makeApiClient(k8s.CoreV1Api);
    return coreApi;
  } catch {
    coreApi = null;
    return null;
  }
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
      error: "Kubernetes API not configured (set KUBERNETES_ENABLED=true and a valid kubeconfig)."
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
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
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

export async function getClusterNodeCount(): Promise<number | null> {
  const api = getCoreV1Api();
  if (!api) {
    return null;
  }
  try {
    const { body } = await api.listNode();
    return body.items?.length ?? 0;
  } catch {
    return null;
  }
}

/** Aggregate pod counts across distinct namespaces (e.g. all PaaS projects). */
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
