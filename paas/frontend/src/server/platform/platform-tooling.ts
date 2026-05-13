import { env } from "@/server/config/env";
import { getCoreV1Api, getCustomObjectsApi, isKubernetesConfigured } from "@/server/integrations/kubernetes-client";
import type { PlatformToolGroup } from "@/types";
type ToolTone = "success" | "warning" | "danger" | "outline";
function toneFromPods(running: number, total: number): ToolTone {
    if (total === 0) {
        return "outline";
    }
    if (running === total) {
        return "success";
    }
    if (running > 0) {
        return "warning";
    }
    return "danger";
}
function configuredUrl(value: string | undefined): boolean {
    return Boolean(value?.trim());
}
function urlBackedTool(name: string, pods: {
    total: number;
    running: number;
}, url: string | undefined, label: string) {
    if (pods.total > 0) {
        return tool(name, `${pods.running}/${pods.total} pods running`, toneFromPods(pods.running, pods.total));
    }
    if (configuredUrl(url)) {
        return tool(name, `${label} configured`, "success");
    }
    return tool(name, "No URL configured and pods not detected", "outline");
}
function readItems(value: unknown): unknown[] {
    if (!value || typeof value !== "object") {
        return [];
    }
    const body = "body" in value ? (value as {
        body?: unknown;
    }).body : value;
    if (!body || typeof body !== "object" || !("items" in body)) {
        return [];
    }
    const items = (body as {
        items?: unknown;
    }).items;
    return Array.isArray(items) ? items : [];
}
async function namespacePods(namespace: string): Promise<{
    total: number;
    running: number;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return { total: 0, running: 0 };
    }
    try {
        const response = await (api as any).listNamespacedPod(namespace);
        const items = readItems(response) as Array<{
            status?: {
                phase?: string;
            };
        }>;
        return {
            total: items.length,
            running: items.filter((pod) => pod.status?.phase === "Running").length
        };
    }
    catch {
        return { total: 0, running: 0 };
    }
}
/** Pods whose name matches CNI / networking daemons (Calico, Canal, Tigera agents). */
async function namespacePodsMatchingName(namespace: string, pattern: RegExp): Promise<{
    total: number;
    running: number;
}> {
    const api = getCoreV1Api();
    if (!api) {
        return { total: 0, running: 0 };
    }
    try {
        const response = await (api as any).listNamespacedPod(namespace);
        const items = readItems(response) as Array<{
            metadata?: {
                name?: string;
            };
            status?: {
                phase?: string;
            };
        }>;
        const filtered = items.filter((pod) => pattern.test(pod.metadata?.name || ""));
        return {
            total: filtered.length,
            running: filtered.filter((pod) => pod.status?.phase === "Running").length
        };
    }
    catch {
        return { total: 0, running: 0 };
    }
}
async function countClusterObjects(group: string, version: string, plural: string): Promise<number> {
    const api = getCustomObjectsApi();
    if (!api) {
        return 0;
    }
    try {
        const response = await (api as any).listClusterCustomObject(group, version, plural);
        return readItems(response).length;
    }
    catch {
        return 0;
    }
}
async function countCrdsContaining(value: string): Promise<number> {
    const api = getCustomObjectsApi();
    if (!api) {
        return 0;
    }
    try {
        const response = await (api as any).listClusterCustomObject("apiextensions.k8s.io", "v1", "customresourcedefinitions");
        return (readItems(response) as Array<{
            metadata?: {
                name?: string;
            };
        }>)
            .filter((crd) => crd.metadata?.name?.includes(value)).length;
    }
    catch {
        return 0;
    }
}
function tool(name: string, detail: string, tone: ToolTone = "outline") {
    return { name, detail, tone };
}
export async function getPlatformTooling(): Promise<{
    groups: PlatformToolGroup[];
}> {
    const calicoAgentPattern = /calico|tigera|canal/i;
    const [ingress, certManager, calicoWorkload, monitoring, jenkins, argocd, dependencyTrack, sonarqube, nexus, vault, kubewarden, kyvernoPolicies, gatekeeperCrds, certs, calicoPolicies, kubeStateMetrics, portainerNs] = await Promise.all([
        namespacePods("ingress-nginx"),
        namespacePods("cert-manager"),
        namespacePodsMatchingName("kube-system", calicoAgentPattern),
        namespacePods("monitoring"),
        namespacePods("jenkins"),
        namespacePods("argocd"),
        namespacePods("dependency-track"),
        namespacePods("sonarqube"),
        namespacePods("nexus"),
        namespacePods("vault"),
        namespacePods("kubewarden"),
        countClusterObjects("kyverno.io", "v1", "clusterpolicies"),
        countCrdsContaining("gatekeeper.sh"),
        countClusterObjects("cert-manager.io", "v1", "certificates"),
        countClusterObjects("projectcalico.org", "v3", "networkpolicies"),
        namespacePodsMatchingName("monitoring", /kube-state-metrics/i),
        namespacePods("portainer")
    ]);
    const policyActive = kyvernoPolicies > 0 || gatekeeperCrds > 0 || kubewarden.running > 0;
    const sonarConfigured = configuredUrl(env.SONAR_BASE_URL) || sonarqube.total > 0;
    const scaSbomConfigured =
        configuredUrl(env.DEPENDENCY_TRACK_BASE_URL) ||
        dependencyTrack.total > 0 ||
        configuredUrl(env.TRIVY_BASE_URL);
    const cosignConfigured = Boolean(env.COSIGN_PUBLIC_KEY?.trim() || env.COSIGN_PRIVATE_KEY?.trim());
    const harborConfigured = configuredUrl(env.HARBOR_BASE_URL);
    const artifactoryConfigured = configuredUrl(process.env.NEXT_PUBLIC_ARTIFACTORY_URL) || configuredUrl(env.ARTIFACTORY_URL);
    const zapUrlConfigured = configuredUrl(process.env.NEXT_PUBLIC_OWASP_ZAP_URL);
    const dependencyCheckConfigured =
        configuredUrl(process.env.NEXT_PUBLIC_DEPENDENCY_CHECK_URL) || configuredUrl(process.env.NEXT_PUBLIC_OWASP_DEPENDENCY_CHECK_URL);
    const terraformConfigured = configuredUrl(process.env.NEXT_PUBLIC_TERRAFORM_CLOUD_URL);
    const haproxyConfigured = configuredUrl(process.env.NEXT_PUBLIC_HAPROXY_STATS_URL);
    const kibanaConfigured = configuredUrl(process.env.NEXT_PUBLIC_KIBANA_URL);
    const elasticsearchConfigured = configuredUrl(process.env.NEXT_PUBLIC_ELASTICSEARCH_URL);
    const k8sClientReady = isKubernetesConfigured();
    const edgeIotConfigured = configuredUrl(process.env.NEXT_PUBLIC_EDGE_IOT_URL);
    return {
        groups: [
            {
                title: "Unified delivery and progressive DevSecOps",
                items: [
                    tool(
                        "Static analysis (SAST)",
                        sonarConfigured
                            ? "SonarQube URL or workload detected; pipelines can enforce quality gates."
                            : "Configure SONAR_* and Jenkins stages to run SAST on every build.",
                        sonarConfigured ? "success" : "outline",
                    ),
                    tool(
                        "Vulnerabilities and SBOM",
                        scaSbomConfigured
                            ? "Dependency-Track or Trivy configured; CI can publish CycloneDX and gate on findings."
                            : "Add Dependency-Track and/or TRIVY_BASE_URL; enable SCA and SBOM steps in Jenkins.",
                        scaSbomConfigured ? "success" : "outline",
                    ),
                    tool(
                        "Image signing",
                        cosignConfigured
                            ? "Cosign keys configured for signing and verification in CI and on the cluster."
                            : "Set COSIGN_PUBLIC_KEY (and signing material in CI) to sign and verify release images.",
                        cosignConfigured ? "success" : "outline",
                    ),
                    tool(
                        "Kubernetes security policy",
                        policyActive
                            ? "Kyverno, Gatekeeper CRDs, or Kubewarden pods detected—policy applies at admission."
                            : "Deploy Kyverno, Gatekeeper, or Kubewarden so guardrails are enforced cluster-wide.",
                        policyActive ? "success" : "outline",
                    ),
                ],
            },
            {
                title: "Control & infra",
                items: [
                    tool(
                        "Kubernetes control plane",
                        k8sClientReady
                            ? "Kube client active — workloads reflect live API, etcd, scheduler, and controller-manager health at the data plane."
                            : env.KUBERNETES_ENABLED === "true"
                              ? "KUBERNETES_ENABLED but kubeconfig missing or invalid — fix KUBE_CONFIG_PATH / API access."
                              : "Enable KUBERNETES_ENABLED and mount kubeconfig for live API telemetry.",
                        k8sClientReady ? "success" : "outline",
                    ),
                    tool("Ingress NGINX", `${ingress.running}/${ingress.total} pods running`, toneFromPods(ingress.running, ingress.total)),
                    tool("cert-manager", `${certManager.running}/${certManager.total} pods running · ${certs} certificates`, toneFromPods(certManager.running, certManager.total)),
                    tool(
                        "Calico (CNI)",
                        calicoWorkload.total > 0
                            ? `${calicoWorkload.running}/${calicoWorkload.total} networking pods · ${calicoPolicies} Calico NetworkPolicies`
                            : calicoPolicies > 0
                              ? `No calico/tigera pods matched in kube-system · ${calicoPolicies} NetworkPolicies (CRD)`
                              : "No Calico-style pods or policies detected",
                        calicoWorkload.total > 0 || calicoPolicies > 0 ? "success" : "outline",
                    ),
                ],
            },
            {
                title: "Security & policy",
                items: [
                    tool("Kyverno", `${kyvernoPolicies} cluster policies`, kyvernoPolicies > 0 ? "success" : "outline"),
                    tool("OPA/Gatekeeper", `${gatekeeperCrds} CRDs installed`, gatekeeperCrds > 0 ? "success" : "outline"),
                    tool("Kubewarden", `${kubewarden.running}/${kubewarden.total} pods running`, toneFromPods(kubewarden.running, kubewarden.total)),
                    tool("Cosign", env.COSIGN_PUBLIC_KEY || env.COSIGN_PRIVATE_KEY ? "Verification keys configured for image signature checks." : "No signing key configured", env.COSIGN_PUBLIC_KEY || env.COSIGN_PRIVATE_KEY ? "success" : "outline"),
                    tool("Trivy", env.TRIVY_BASE_URL ? "Scanner endpoint configured for image/security checks." : "No Trivy endpoint configured", env.TRIVY_BASE_URL ? "success" : "outline")
                ]
            },
            {
                title: "Monitoring",
                items: [
                    urlBackedTool("Prometheus stack", monitoring, env.PROMETHEUS_BASE_URL || process.env.NEXT_PUBLIC_PROMETHEUS_URL, "Prometheus URL"),
                    tool("Grafana", process.env.NEXT_PUBLIC_GRAFANA_URL ? "Dashboard link available from the app." : "No Grafana URL configured", process.env.NEXT_PUBLIC_GRAFANA_URL ? "success" : "outline"),
                    tool("Alertmanager", process.env.NEXT_PUBLIC_ALERTMANAGER_URL ? "Alertmanager link configured." : "No Alertmanager URL configured", process.env.NEXT_PUBLIC_ALERTMANAGER_URL ? "success" : "outline"),
                    tool(
                        "Kube-state-metrics",
                        kubeStateMetrics.total > 0
                            ? `${kubeStateMetrics.running}/${kubeStateMetrics.total} pods matching kube-state-metrics in monitoring`
                            : configuredUrl(process.env.NEXT_PUBLIC_KUBE_STATE_METRICS_URL)
                              ? "Public metrics/docs URL configured; workloads not matched in monitoring namespace."
                              : "Deploy kube-state-metrics in monitoring or set NEXT_PUBLIC_KUBE_STATE_METRICS_URL.",
                        kubeStateMetrics.total > 0 || configuredUrl(process.env.NEXT_PUBLIC_KUBE_STATE_METRICS_URL) ? "success" : "outline",
                    ),
                    tool("Node exporter", monitoring.total > 0 ? "Exporter workloads often live in the monitoring namespace with Prom scrape configs." : "No workloads in monitoring namespace — set Prom scrape or node-exporter NodePort", monitoring.total > 0 ? "success" : "outline"),
                    tool("Pushgateway", process.env.NEXT_PUBLIC_PUSHGATEWAY_URL ? "Pushgateway link configured for build/batch metrics." : "No Pushgateway URL configured", process.env.NEXT_PUBLIC_PUSHGATEWAY_URL ? "success" : "outline"),
                    tool(
                        "Elastic Stack",
                        kibanaConfigured || elasticsearchConfigured
                            ? `Kibana / Elasticsearch URLs configured (${[kibanaConfigured && "Kibana", elasticsearchConfigured && "Elasticsearch"].filter(Boolean).join(", ")}).`
                            : "Set NEXT_PUBLIC_KIBANA_URL or NEXT_PUBLIC_ELASTICSEARCH_URL for deep links.",
                        kibanaConfigured || elasticsearchConfigured ? "success" : "outline",
                    ),
                ],
            },
            {
                title: "CI/CD & repositories",
                items: [
                    urlBackedTool("Jenkins", jenkins, env.JENKINS_BASE_URL, "Jenkins URL"),
                    urlBackedTool("Argo CD", argocd, env.ARGOCD_BASE_URL, "Argo CD URL"),
                    tool("GitHub", env.GITOPS_REPO_URL ? "GitOps repository configured." : "No GitOps repository configured", env.GITOPS_REPO_URL ? "success" : "outline"),
                    tool("Docker Hub", env.DOCKERHUB_USERNAME ? `Namespace ${env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME}` : "No Docker Hub namespace configured", env.DOCKERHUB_USERNAME ? "success" : "outline"),
                    tool(
                        "Harbor",
                        harborConfigured ? `Registry URL configured (${env.HARBOR_BASE_URL.replace(/\/$/, "")}).` : "Set HARBOR_BASE_URL for image push metadata.",
                        harborConfigured ? "success" : "outline",
                    ),
                    urlBackedTool("Nexus", nexus, process.env.NEXT_PUBLIC_NEXUS_URL, "Nexus URL"),
                    tool(
                        "JFrog Artifactory",
                        artifactoryConfigured ? "Artifactory link or ARTIFACTORY_URL present." : "Set NEXT_PUBLIC_ARTIFACTORY_URL or ARTIFACTORY_URL.",
                        artifactoryConfigured ? "success" : "outline",
                    ),
                ],
            },
            {
                title: "Security scanning & infra",
                items: [
                    urlBackedTool("SonarQube", sonarqube, env.SONAR_BASE_URL, "SonarQube URL"),
                    urlBackedTool("Dependency-Track", dependencyTrack, env.DEPENDENCY_TRACK_BASE_URL, "Dependency-Track URL"),
                    tool(
                        "OWASP ZAP",
                        zapUrlConfigured ? "ZAP UI / proxy URL configured for DAST links." : "Set NEXT_PUBLIC_OWASP_ZAP_URL or run ZAP from Jenkins with reports.",
                        zapUrlConfigured ? "success" : "outline",
                    ),
                    tool(
                        "OWASP Dependency-Check",
                        dependencyCheckConfigured
                            ? "Dependency-Check UI or report portal URL configured."
                            : "Set NEXT_PUBLIC_DEPENDENCY_CHECK_URL (or NEXT_PUBLIC_OWASP_DEPENDENCY_CHECK_URL) for links.",
                        dependencyCheckConfigured ? "success" : "outline",
                    ),
                    urlBackedTool("Vault", vault, process.env.NEXT_PUBLIC_VAULT_UI_URL, "Vault URL"),
                    tool(
                        "Terraform",
                        terraformConfigured ? "Terraform Cloud / Enterprise URL configured." : "Set NEXT_PUBLIC_TERRAFORM_CLOUD_URL for IaC portal link.",
                        terraformConfigured ? "success" : "outline",
                    ),
                    tool(
                        "HAProxy",
                        haproxyConfigured ? "HAProxy stats or admin URL configured." : "Set NEXT_PUBLIC_HAPROXY_STATS_URL.",
                        haproxyConfigured ? "success" : "outline",
                    ),
                    urlBackedTool("Portainer", portainerNs, process.env.NEXT_PUBLIC_PORTAINER_URL, "Portainer URL"),
                    tool(
                        "Edge / Raspberry Pi fleet",
                        edgeIotConfigured
                            ? "Optional edge or device dashboard URL configured."
                            : "Set NEXT_PUBLIC_EDGE_IOT_URL for Pi / IoT gateway consoles.",
                        edgeIotConfigured ? "success" : "outline",
                    ),
                ],
            },
        ],
    };
}
