import apiClient from "@/lib/api-client";
import type {
  ActionResponse,
  ArgoCdStatus,
  AuthResponse,
  ContainerImageRecord,
  AppReachabilityResponse,
  DashboardOverviewResponse,
  DeploymentPollResponse,
  DeploymentSummary,
  LoginRequest,
  Project,
  ProjectRequest,
  RegisterRequest,
  RuntimeMetrics,
  SecurityMetrics
} from "@/types";

export interface DashboardMetrics {
  cluster: {
    nodeCount: number;
    cpuUsagePercent: number;
    memoryUsagePercent: number;
  };
  pipelines: {
    id: string;
    projectId: string;
    status: string;
    buildNumber: number | null;
    createdAt: string;
  }[];
  deployments: {
    runningPods: number;
    failedPods: number;
    lastDeploymentTime: string | null;
  };
  security: {
    trivyVulnerabilities: string;
    sonarQualityGate: string | null;
    signedImages: number;
    unsignedImages: number;
  };
}

export const authApi = {
  login: async (payload: LoginRequest) => {
    const { data } = await apiClient.post<AuthResponse>("/api/auth/login", payload);
    return data;
  },
  register: async (payload: RegisterRequest) => {
    const { data } = await apiClient.post<AuthResponse>("/api/auth/register", payload);
    return data;
  }
};

export const projectApi = {
  createProject: async (payload: ProjectRequest) => {
    const { data } = await apiClient.post<Project>("/api/projects", payload);
    return data;
  },
  getProjects: async () => {
    const { data } = await apiClient.get<Project[]>("/api/projects");
    return data;
  },
  getProject: async (projectId: string) => {
    const { data } = await apiClient.get<Project>(`/api/project/${projectId}`);
    return data;
  },
  updateProject: async (projectId: string, payload: Partial<ProjectRequest>) => {
    const { data } = await apiClient.patch<Project>(`/api/project/${projectId}`, payload);
    return data;
  },
  deleteProject: async (projectId: string) => {
    const { data } = await apiClient.delete<{ deleted: boolean }>(`/api/project/${projectId}`);
    return data;
  },
  listDeployments: async (projectId: string) => {
    const { data } = await apiClient.get<DeploymentSummary[]>(`/api/projects/${projectId}/deployments`);
    return data;
  },
  getAppReachability: async (projectId: string) => {
    const { data } = await apiClient.get<AppReachabilityResponse>(
      `/api/projects/${projectId}/app-reachability`
    );
    return data;
  }
};

export const pipelineApi = {
  triggerBuild: async (projectId: string) => {
    const { data } = await apiClient.post<ActionResponse>(`/api/build/${projectId}`);
    return data;
  },
  deploy: async (projectId: string) => {
    const { data } = await apiClient.post<ActionResponse>(`/api/deploy/${projectId}`);
    return data;
  },
  rollback: async (projectId: string) => {
    const { data } = await apiClient.post<ActionResponse>(`/api/rollback/${projectId}`);
    return data;
  },
  getStatus: async (projectId: string) => {
    const { data } = await apiClient.get(`/api/status/${projectId}`);
    return data;
  },
  getDeployment: async (deploymentId: string) => {
    const { data } = await apiClient.get<DeploymentPollResponse>(`/api/deployments/${deploymentId}`);
    return data;
  }
};

export const metricsApi = {
  getMetrics: async (projectId: string): Promise<RuntimeMetrics> => {
    const { data } = await apiClient.get<RuntimeMetrics>(`/api/metrics/${projectId}`);
    return data;
  }
};

export const securityApi = {
  getSecurity: async (projectId: string): Promise<SecurityMetrics> => {
    const { data } = await apiClient.get<SecurityMetrics>(`/api/security/${projectId}`);
    return data;
  }
};

export const dashboardMetricsApi = {
  get: async () => {
    const { data } = await apiClient.get<DashboardMetrics>("/api/metrics");
    return data;
  }
};

export const dashboardOverviewApi = {
  get: async () => {
    const { data } = await apiClient.get<DashboardOverviewResponse>("/api/dashboard/overview");
    return data;
  }
};

export const argocdApi = {
  getStatus: async (projectId: string) => {
    const { data } = await apiClient.get<ArgoCdStatus>(`/api/argocd/${projectId}`);
    return data;
  }
};

export const dockerApi = {
  build: async (projectId: string) => {
    const { data } = await apiClient.post<{ imageRef: string; logs: string }>(
      `/api/docker/${projectId}/build`
    );
    return data;
  },
  push: async (projectId: string) => {
    const { data } = await apiClient.post<{
      imageRef: string;
      digest: string;
      logs: string;
      registryAuthOk: boolean;
    }>(`/api/docker/${projectId}/push`);
    return data;
  },
  history: async (projectId: string) => {
    const { data } = await apiClient.get<ContainerImageRecord[]>(`/api/docker/${projectId}/history`);
    return data;
  }
};
