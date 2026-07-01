import type { V1Deployment, V1Ingress, V1Service } from "@kubernetes/client-node";
import { buildAppIngressHost } from "@/server/deploy/app-public-url";
import { harborClusterPullImageRef } from "@/server/deploy/deploy-image";
import { helmReleaseName, rollingDeploymentNameCandidates } from "@/server/gitops/gitops-blue-green";
import { gitopsChartShortNameForProject } from "@/server/gitops/gitops-paths";
import {
    getAppsV1Api,
    getCoreV1Api,
    kubernetesAuthenticatedFetch,
    readNamespacedSecretData
} from "@/server/integrations/kubernetes-client";

function kubernetesApiBaseUrl(): string {
    const host = process.env.KUBERNETES_SERVICE_HOST || "";
    const port = process.env.KUBERNETES_SERVICE_PORT || "443";
    return `https://${host}:${port}`;
}

async function deploymentExists(namespace: string, names: string[]): Promise<boolean> {
    const api = getAppsV1Api();
    if (!api) {
        return false;
    }
    for (const name of names) {
        try {
            await api.readNamespacedDeployment(name, namespace);
            return true;
        }
        catch {
            // try next candidate
        }
    }
    return false;
}

function probeSpec(containerPort: number): {
    readiness: Record<string, unknown>;
    liveness: Record<string, unknown>;
} {
    if (containerPort === 80) {
        return {
            readiness: {
                tcpSocket: { port: "http" },
                initialDelaySeconds: 3,
                periodSeconds: 5,
                failureThreshold: 6
            },
            liveness: {
                tcpSocket: { port: "http" },
                initialDelaySeconds: 10,
                periodSeconds: 15,
                failureThreshold: 6
            }
        };
    }
    if (containerPort === 8000) {
        return {
            readiness: {
                httpGet: { path: "/", port: "http" },
                initialDelaySeconds: 30,
                periodSeconds: 10,
                failureThreshold: 12
            },
            liveness: {
                httpGet: { path: "/", port: "http" },
                initialDelaySeconds: 90,
                periodSeconds: 20,
                failureThreshold: 6
            }
        };
    }
    return {
        readiness: {
            httpGet: { path: "/", port: "http" },
            initialDelaySeconds: 5,
            periodSeconds: 10,
            failureThreshold: 6
        },
        liveness: {
            httpGet: { path: "/", port: "http" },
            initialDelaySeconds: 15,
            periodSeconds: 20,
            failureThreshold: 6
        }
    };
}

async function createOrReplaceNamespacedResource(
    collectionPath: string,
    name: string,
    body: unknown,
    createFn?: () => Promise<unknown>,
    replaceFn?: () => Promise<unknown>
): Promise<void> {
    try {
        if (createFn) {
            await createFn();
            return;
        }
        const createResponse = await kubernetesAuthenticatedFetch(`${kubernetesApiBaseUrl()}${collectionPath}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        });
        if (createResponse.ok) {
            return;
        }
        if (createResponse.status !== 409) {
            throw new Error(`HTTP ${createResponse.status}`);
        }
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        if (!/already exists|409/i.test(msg)) {
            throw error;
        }
    }
    if (replaceFn) {
        await replaceFn();
        return;
    }
    const itemPath = `${collectionPath}/${encodeURIComponent(name)}`;
    const replaceResponse = await kubernetesAuthenticatedFetch(`${kubernetesApiBaseUrl()}${itemPath}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    });
    if (!replaceResponse.ok) {
        throw new Error(`Kubernetes PUT ${itemPath} failed: HTTP ${replaceResponse.status}`);
    }
}

/**
 * Lab fallback when Argo CD is not installed: create Deployment + Service + Ingress
 * matching the bundled simple-app Helm chart (values already committed to GitOps).
 */
export async function ensureRollingWorkloadManifests(
    namespace: string,
    projectName: string,
    imageRef: string,
    containerPort: number
): Promise<{ applied: boolean; deploymentName: string; logs: string[] }> {
    const logs: string[] = [];
    const candidates = rollingDeploymentNameCandidates(projectName);
    if (await deploymentExists(namespace, candidates)) {
        return { applied: false, deploymentName: candidates[0] ?? "", logs };
    }
    const release = helmReleaseName(projectName);
    const chartName = gitopsChartShortNameForProject(projectName);
    const deploymentName = release;
    const image = harborClusterPullImageRef(imageRef);
    const probes = probeSpec(containerPort);
    const hasPullSecret = Boolean(await readNamespacedSecretData(namespace, "harbor-regcred"));
    const deployment: V1Deployment = {
        apiVersion: "apps/v1",
        kind: "Deployment",
        metadata: {
            name: deploymentName,
            namespace,
            labels: {
                "app.kubernetes.io/name": chartName,
                "app.kubernetes.io/instance": release
            }
        },
        spec: {
            replicas: 1,
            selector: {
                matchLabels: {
                    "app.kubernetes.io/name": chartName,
                    "app.kubernetes.io/instance": release
                }
            },
            template: {
                metadata: {
                    labels: {
                        "app.kubernetes.io/name": chartName,
                        "app.kubernetes.io/instance": release
                    }
                },
                spec: {
                    ...(hasPullSecret ? { imagePullSecrets: [{ name: "harbor-regcred" }] } : {}),
                    securityContext: {
                        runAsNonRoot: true,
                        runAsUser: 1000,
                        fsGroup: 1000
                    },
                    containers: [{
                        name: chartName,
                        image,
                        imagePullPolicy: "IfNotPresent",
                        securityContext: {
                            readOnlyRootFilesystem: false,
                            runAsNonRoot: true,
                            allowPrivilegeEscalation: false
                        },
                        ports: [{ name: "http", containerPort, protocol: "TCP" }],
                        env: [
                            { name: "HOSTNAME", value: "0.0.0.0" },
                            { name: "PORT", value: String(containerPort) }
                        ],
                        readinessProbe: probes.readiness as never,
                        livenessProbe: probes.liveness as never,
                        resources: {
                            limits: { cpu: "200m", memory: "256Mi" },
                            requests: { cpu: "25m", memory: "64Mi" }
                        }
                    }]
                }
            }
        }
    };
    const service: V1Service = {
        apiVersion: "v1",
        kind: "Service",
        metadata: {
            name: deploymentName,
            namespace,
            labels: {
                "app.kubernetes.io/name": chartName,
                "app.kubernetes.io/instance": release
            }
        },
        spec: {
            type: "ClusterIP",
            selector: {
                "app.kubernetes.io/name": chartName,
                "app.kubernetes.io/instance": release
            },
            ports: [{ port: 80, targetPort: "http", protocol: "TCP", name: "http" }]
        }
    };
    const ingressHost = buildAppIngressHost(projectName);
    const ingress: V1Ingress = {
        apiVersion: "networking.k8s.io/v1",
        kind: "Ingress",
        metadata: {
            name: deploymentName,
            namespace,
            labels: {
                "app.kubernetes.io/name": chartName,
                "app.kubernetes.io/instance": release
            }
        },
        spec: {
            ingressClassName: "traefik",
            rules: [{
                host: ingressHost,
                http: {
                    paths: [{
                        path: "/",
                        pathType: "Prefix",
                        backend: {
                            service: {
                                name: deploymentName,
                                port: { number: 80 }
                            }
                        }
                    }]
                }
            }]
        }
    };
    const appsApi = getAppsV1Api();
    const coreApi = getCoreV1Api();
    const nsPath = encodeURIComponent(namespace);
    try {
        await createOrReplaceNamespacedResource(
            `/apis/apps/v1/namespaces/${nsPath}/deployments`,
            deploymentName,
            deployment,
            appsApi ? () => appsApi.createNamespacedDeployment(namespace, deployment) : undefined,
            appsApi ? () => appsApi.replaceNamespacedDeployment(deploymentName, namespace, deployment) : undefined
        );
        logs.push(`[deploy] created Deployment/${deploymentName} image=${image}`);
        await createOrReplaceNamespacedResource(
            `/api/v1/namespaces/${nsPath}/services`,
            deploymentName,
            service,
            coreApi ? () => coreApi.createNamespacedService(namespace, service) : undefined,
            coreApi ? () => coreApi.replaceNamespacedService(deploymentName, namespace, service) : undefined
        );
        logs.push(`[deploy] created Service/${deploymentName}`);
        await createOrReplaceNamespacedResource(
            `/apis/networking.k8s.io/v1/namespaces/${nsPath}/ingresses`,
            deploymentName,
            ingress
        );
        logs.push(`[deploy] created Ingress/${deploymentName} host=${ingressHost}`);
        return { applied: true, deploymentName, logs };
    }
    catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        logs.push(`[deploy] direct manifest apply failed: ${msg}`);
        return { applied: false, deploymentName, logs };
    }
}
