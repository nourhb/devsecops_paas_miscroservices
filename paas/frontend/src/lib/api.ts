import apiClient from "@/lib/api-client";
import type { ActionResponse, ArgoCdStatus, ArtifactListResponse, ArtifactRecord, AuthResponse, AuthSessionResponse, AuthStatusResponse, ContainerImageRecord, AppReachabilityResponse, DependencyTrackMetricsResponse, DeployPipelineReadinessResponse, DashboardOverviewResponse, DeploymentPollResponse, DeploymentSummary, RecentDeploymentsListResponse, LoginRequest, Project, CreateProjectResponse, ProjectRequest, RegisterRequest, RepositoryLanguageDetectionResponse, RuntimeMetrics, SecurityMetrics, PlatformIntegrationsResponse, PlatformToolingResponse, ProjectMonitoringSnapshot, UpdateProfileRequest, UpdateProfileResponse } from "@/types";
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
export interface KubernetesPodRecord {
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
export interface KubernetesServiceRecord {
    name: string;
    namespace: string;
    type: string;
    clusterIP: string;
    externalIP: string;
    ports: string[];
    selector: string;
    createdAt: string;
}
export interface KubernetesDeploymentRecord {
    name: string;
    namespace: string;
    ready: string;
    replicas: number;
    available: number;
    updated: number;
    strategy: string;
    createdAt: string;
}
export interface KubernetesPodsResponse {
    configured: boolean;
    error: string;
    summary: {
        total: number;
        running: number;
        pending: number;
        failed: number;
    };
    pods: KubernetesPodRecord[];
}
export interface KubernetesServicesResponse {
    configured: boolean;
    error: string;
    summary: {
        total: number;
        nodePort: number;
        loadBalancer: number;
        clusterIP: number;
    };
    services: KubernetesServiceRecord[];
}
export interface KubernetesDeploymentsResponse {
    configured: boolean;
    error: string;
    summary: {
        total: number;
        healthy: number;
        nodes: number;
    };
    deployments: KubernetesDeploymentRecord[];
}
export interface KubernetesPodLogsResponse {
    namespace: string;
    podName: string;
    container: string;
    logs: string;
}
export interface JenkinsPipelineStageRow {
    name: string;
    status: string;
    durationMs: number | null;
}
export interface JenkinsPipelineStagesResponse {
    configured: boolean;
    skipped?: boolean;
    reason?: string;
    error?: string;
    jobUrlPath: string;
    displayJobName: string;
    buildNumber: number | null;
    building: boolean;
    result: string | null;
    runStatus: string | null;
    stages: JenkinsPipelineStageRow[];
    buildUrl: string | null;
}
export interface KubernetesNamespaceRecord {
    name: string;
    phase: string;
    createdAt: string;
}
export interface KubernetesNamespacesResponse {
    configured: boolean;
    error: string;
    summary: {
        total: number;
        active: number;
        terminating: number;
    };
    namespaces: KubernetesNamespaceRecord[];
}
export const authApi = {
    login: async (payload: LoginRequest) => {
        const { data } = await apiClient.post<AuthResponse>("/api/auth/login", payload);
        return data;
    },
    session: async () => {
        const { data } = await apiClient.get<AuthSessionResponse>("/api/auth/session");
        return data;
    },
    logout: async () => {
        await apiClient.post("/api/auth/logout");
    },
    register: async (payload: RegisterRequest) => {
        const { data } = await apiClient.post<AuthStatusResponse>("/api/auth/register", payload);
        return data;
    },
    verifyEmail: async (token: string) => {
        const { data } = await apiClient.post<AuthStatusResponse>("/api/auth/verify-email", { token });
        return data;
    },
    resendVerification: async (email: string) => {
        const { data } = await apiClient.post<AuthStatusResponse>("/api/auth/resend-verification", { email });
        return data;
    },
    forgotPassword: async (email: string) => {
        const { data } = await apiClient.post<AuthStatusResponse>("/api/auth/forgot-password", { email });
        return data;
    },
    resetPassword: async (token: string, password: string) => {
        const { data } = await apiClient.post<AuthStatusResponse>("/api/auth/reset-password", { token, password });
        return data;
    },
    updateProfile: async (payload: UpdateProfileRequest) => {
        const { data } = await apiClient.patch<UpdateProfileResponse>("/api/auth/profile", payload);
        return data;
    }
};
export const projectApi = {
    createProject: async (payload: ProjectRequest) => {
        const { data } = await apiClient.post<CreateProjectResponse>("/api/projects", payload);
        return data;
    },
    detectLanguage: async (gitRepositoryUrl: string, branch: string) => {
        const { data } = await apiClient.post<RepositoryLanguageDetectionResponse>("/api/projects/detect-language", {
            gitRepositoryUrl,
            branch
        });
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
        const { data } = await apiClient.delete<{
            deleted: boolean;
        }>(`/api/project/${projectId}`);
        return data;
    },
    listDeployments: async (projectId: string) => {
        const { data } = await apiClient.get<DeploymentSummary[]>(`/api/projects/${projectId}/deployments`);
        return data;
    },
    getAppReachability: async (projectId: string) => {
        const { data } = await apiClient.get<AppReachabilityResponse>(`/api/projects/${projectId}/app-reachability`);
        return data;
    }
};
export const pipelineApi = {
    triggerBuild: async (projectId: string, body?: {
        branch?: string;
        gitCredentialsId?: string;
        dismissPendingGitHubPush?: boolean;
    }) => {
        const hasBody = body && Object.keys(body).length > 0;
        const { data } = hasBody
            ? await apiClient.post<ActionResponse>(`/api/build/${projectId}`, body)
            : await apiClient.post<ActionResponse>(`/api/build/${projectId}`);
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
    },
    listRecentDeployments: async (limit = 20) => {
        const { data } = await apiClient.get<RecentDeploymentsListResponse>(`/api/deployments/recent?limit=${encodeURIComponent(String(limit))}`);
        return data;
    },
    cancelDeployment: async (deploymentId: string) => {
        const { data } = await apiClient.post<ActionResponse>(`/api/deployments/${deploymentId}/cancel`);
        return data;
    }
};
export const metricsApi = {
    getMetrics: async (projectId: string): Promise<RuntimeMetrics> => {
        const { data } = await apiClient.get<RuntimeMetrics>(`/api/metrics/${projectId}`);
        return data;
    }
};
export const monitoringApi = {
    getSnapshot: async (projectId: string) => {
        const { data } = await apiClient.get<ProjectMonitoringSnapshot>(`/api/monitoring/${projectId}`);
        return data;
    }
};
export const securityApi = {
    getSecurity: async (projectId: string): Promise<SecurityMetrics> => {
        const { data } = await apiClient.get<SecurityMetrics>(`/api/security/${projectId}`);
        return data;
    },
    getDependencyTrack: async (projectId: string): Promise<DependencyTrackMetricsResponse> => {
        const { data } = await apiClient.get<DependencyTrackMetricsResponse>(`/api/dependency-track?projectId=${encodeURIComponent(projectId)}`);
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
export const platformApi = {
    getDeployReadiness: async () => {
        const { data } = await apiClient.get<DeployPipelineReadinessResponse>("/api/platform/deploy-readiness");
        return data;
    },
    getIntegrations: async () => {
        const { data } = await apiClient.get<PlatformIntegrationsResponse>("/api/platform/integrations", { timeout: 90000 });
        return data;
    },
    getTooling: async () => {
        const { data } = await apiClient.get<PlatformToolingResponse>("/api/platform/tooling", { timeout: 90000 });
        return data;
    }
};
export const argocdApi = {
    getStatus: async (projectId: string) => {
        const { data } = await apiClient.get<ArgoCdStatus>(`/api/argocd/${projectId}`);
        return data;
    }
};
export const kubernetesApi = {
    getPods: async () => {
        const { data } = await apiClient.get<KubernetesPodsResponse>("/api/k8s/pods");
        return data;
    },
    getServices: async () => {
        const { data } = await apiClient.get<KubernetesServicesResponse>("/api/k8s/services");
        return data;
    },
    getDeployments: async () => {
        const { data } = await apiClient.get<KubernetesDeploymentsResponse>("/api/k8s/deployments");
        return data;
    },
    getNamespaces: async () => {
        const { data } = await apiClient.get<KubernetesNamespacesResponse>("/api/k8s/namespaces");
        return data;
    },
    getPodLogs: async (namespace: string, podName: string, container?: string) => {
        const params = new URLSearchParams({
            namespace,
            podName
        });
        if (container) {
            params.set("container", container);
        }
        const { data } = await apiClient.get<KubernetesPodLogsResponse>(`/api/k8s/pod-logs?${params.toString()}`);
        return data;
    }
};
export const dockerApi = {
    build: async (projectId: string) => {
        const { data } = await apiClient.post<{
            imageRef: string;
            logs: string;
        }>(`/api/docker/${projectId}/build`);
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
export const artifactApi = {
    list: async () => {
        const { data } = await apiClient.get<ArtifactListResponse>("/api/artifacts");
        return data;
    },
    getByName: async (name: string) => {
        const { data } = await apiClient.get<ArtifactRecord>(`/api/artifacts/${encodeURIComponent(name)}`);
        return data;
    }
};
export const jenkinsUi = {
    suggest: (body: Record<string, unknown>) => apiClient.post("/api/helpers/suggest-build", body).then((r) => r.data),
    analyze: (body: Record<string, unknown>) => apiClient.post("/api/helpers/analyze-build-log", body).then((r) => r.data),
    trigger: (jobName: string, parameters: Record<string, string>) => apiClient.post("/api/jenkins/build", { jobName, parameters }).then((r) => r.data),
    builds: (jobName: string, signal?: AbortSignal) => apiClient.get("/api/jenkins/builds", { params: { jobName }, signal }).then((r) => r.data),
    logs: (jobName: string, buildId: string | number, signal?: AbortSignal) => apiClient.get(`/api/jenkins/logs/${encodeURIComponent(String(buildId))}`, {
        params: { jobName },
        signal
    }).then((r) => r.data),
    pipelineStages: async (projectId: string, buildNumber?: number, signal?: AbortSignal) => {
        const params: Record<string, string> = { projectId };
        if (buildNumber != null && Number.isFinite(buildNumber)) {
            params.buildNumber = String(Math.trunc(buildNumber));
        }
        const { data } = await apiClient.get<JenkinsPipelineStagesResponse>("/api/jenkins/pipeline-stages", {
            params,
            signal
        });
        return data;
    }
};
