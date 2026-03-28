import { KubeConfig, AppsV1Api, CoreV1Api } from "@kubernetes/client-node";

export interface DeploymentStatus {
  name: string;
  namespace: string;
  availableReplicas: number;
  desiredReplicas: number;
  ready: boolean;
}

export interface PodSummary {
  name: string;
  namespace: string;
  phase: string;
  nodeName?: string;
}

let appsClient: AppsV1Api | null = null;
let coreClient: CoreV1Api | null = null;

function ensureClients() {
  if (appsClient && coreClient) return;

  const kc = new KubeConfig();
  if (process.env.KUBECONFIG) {
    kc.loadFromFile(process.env.KUBECONFIG);
  } else {
    try {
      kc.loadFromCluster();
    } catch {
      kc.loadFromDefault();
    }
  }

  appsClient = kc.makeApiClient(AppsV1Api);
  coreClient = kc.makeApiClient(CoreV1Api);
}

export async function getDeploymentStatus(
  name: string,
  namespace: string,
): Promise<DeploymentStatus> {
  ensureClients();

  const resp = await appsClient!.readNamespacedDeployment(name, namespace);
  const dep = resp.body;
  const status = dep.status ?? {};

  const available = status.availableReplicas ?? 0;
  const desired = status.replicas ?? 0;

  return {
    name,
    namespace,
    availableReplicas: available,
    desiredReplicas: desired,
    ready: available > 0 && available === desired,
  };
}

export async function listPodsForDeployment(
  deploymentName: string,
  namespace: string,
): Promise<PodSummary[]> {
  ensureClients();

  const sel = `app=${deploymentName}`;
  const resp = await coreClient!.listNamespacedPod(
    namespace,
    undefined,
    undefined,
    undefined,
    undefined,
    sel,
  );

  return resp.body.items.map((pod: any) => ({
    name: pod.metadata?.name ?? "",
    namespace: pod.metadata?.namespace ?? namespace,
    phase: pod.status?.phase ?? "Unknown",
    nodeName: pod.spec?.nodeName,
  }));
}

export async function getPodLogs(
  podName: string,
  namespace: string,
  container?: string,
): Promise<string> {
  ensureClients();

  const resp = await coreClient!.readNamespacedPodLog(
    podName,
    namespace,
    container,
    false, // follow
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
  );
  return resp.body ?? "";
}

export async function getNodeCount(): Promise<number> {
  ensureClients();
  const resp = await coreClient!.listNode();
  return resp.body.items.length;
}

