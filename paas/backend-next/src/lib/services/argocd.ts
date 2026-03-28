import axios from "axios";

export interface ArgoCdAppSpec {
  name: string;
  project: string;
  repoUrl: string;
  targetRevision: string;
  path: string;
  namespace: string;
}

export interface ArgoCdAppStatus {
  name: string;
  syncStatus: "Synced" | "OutOfSync" | "Unknown";
  healthStatus:
    | "Healthy"
    | "Degraded"
    | "Missing"
    | "Progressing"
    | "Suspended"
    | "Unknown";
  lastSyncedAt?: string;
}

function getArgoClient() {
  const baseUrl = process.env.ARGOCD_URL;
  const token = process.env.ARGOCD_TOKEN;

  if (!baseUrl || !token) {
    throw new Error("ArgoCD configuration missing (ARGOCD_URL/TOKEN).");
  }

  return axios.create({
    baseURL: baseUrl.replace(/\/+$/, ""),
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
  });
}

export async function upsertApplication(
  spec: ArgoCdAppSpec,
): Promise<ArgoCdAppStatus> {
  const client = getArgoClient();

  const body = {
    metadata: {
      name: spec.name,
      namespace: "argocd",
    },
    spec: {
      project: spec.project,
      source: {
        repoURL: spec.repoUrl,
        targetRevision: spec.targetRevision,
        path: spec.path,
      },
      destination: {
        server: "https://kubernetes.default.svc",
        namespace: spec.namespace,
      },
      syncPolicy: {
        automated: {
          prune: true,
          selfHeal: true,
        },
      },
    },
  };

  try {
    await client.get(`/api/v1/applications/${spec.name}`);
    await client.put(`/api/v1/applications/${spec.name}`, body);
  } catch {
    await client.post("/api/v1/applications", body);
  }

  return getApplicationStatus(spec.name);
}

export async function syncApplication(
  appName: string,
): Promise<ArgoCdAppStatus> {
  const client = getArgoClient();
  await client.post(`/api/v1/applications/${appName}/sync`, {});
  return getApplicationStatus(appName);
}

export async function getApplicationStatus(
  appName: string,
): Promise<ArgoCdAppStatus> {
  const client = getArgoClient();
  const { data } = await client.get(`/api/v1/applications/${appName}`);

  const sync = data.status?.sync?.status as
    | "Synced"
    | "OutOfSync"
    | undefined;
  const health = data.status?.health?.status as
    | "Healthy"
    | "Degraded"
    | "Missing"
    | "Progressing"
    | "Suspended"
    | undefined;

  return {
    name: data.metadata?.name ?? appName,
    syncStatus: sync ?? "Unknown",
    healthStatus: health ?? "Unknown",
    lastSyncedAt: data.status?.reconciledAt,
  };
}

export async function deleteApplication(appName: string): Promise<void> {
  const client = getArgoClient();
  try {
    await client.delete(`/api/v1/applications/${appName}`);
  } catch {
    // ignore not found
  }
}

