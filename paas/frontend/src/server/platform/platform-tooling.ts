import { env } from "@/server/config/env";
import { getCoreV1Api, getCustomObjectsApi } from "@/server/integrations/kubernetes-client";
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
    const [ingress, certManager, calico, monitoring, jenkins, argocd, dependencyTrack, sonarqube, nexus, vault, kubewarden, kyvernoPolicies, gatekeeperCrds, certs, calicoPolicies, vaultPods] = await Promise.all([
        namespacePods("ingress-nginx"),
        namespacePods("cert-manager"),
        namespacePods("kube-system"),
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
        namespacePods("vault")
    ]);
    return {
        groups: [
            {
                title: "Control & infra",
                items: [
                    tool("Kubernetes API", env.KUBERNETES_ENABLED === "true" ? "Cluster API enabled for live pods, services, deployments, and logs." : "Disabled", env.KUBERNETES_ENABLED === "true" ? "success" : "outline"),
                    tool("Ingress NGINX", `${ingress.running}/${ingress.total} pods running`, toneFromPods(ingress.running, ingress.total)),
                    tool("cert-manager", `${certManager.running}/${certManager.total} pods running · ${certs} certificates`, toneFromPods(certManager.running, certManager.total)),
                    tool("Calico", `${calico.running}/${calico.total} kube-system pods running · ${calicoPolicies} policies`, toneFromPods(calico.running, calico.total))
                ]
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
                    tool("Node exporter", monitoring.total > 0 ? "Node exporter metrics are scraped through Prometheus." : "Not detected", monitoring.total > 0 ? "success" : "outline"),
                    tool("Pushgateway", process.env.NEXT_PUBLIC_PUSHGATEWAY_URL ? "Pushgateway link configured for build/batch metrics." : "No Pushgateway URL configured", process.env.NEXT_PUBLIC_PUSHGATEWAY_URL ? "success" : "outline")
                ]
            },
            {
                title: "CI/CD & repositories",
                items: [
                    urlBackedTool("Jenkins", jenkins, env.JENKINS_BASE_URL, "Jenkins URL"),
                    urlBackedTool("Argo CD", argocd, env.ARGOCD_BASE_URL, "Argo CD URL"),
                    tool("GitHub", env.GITOPS_REPO_URL ? "GitOps repository configured." : "No GitOps repository configured", env.GITOPS_REPO_URL ? "success" : "outline"),
                    tool("Docker Hub", env.DOCKERHUB_USERNAME ? `Namespace ${env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME}` : "No Docker Hub namespace configured", env.DOCKERHUB_USERNAME ? "success" : "outline"),
                    urlBackedTool("Nexus", nexus, process.env.NEXT_PUBLIC_NEXUS_URL, "Nexus URL")
                ]
            },
            {
                title: "Security scanning & infra",
                items: [
                    urlBackedTool("SonarQube", sonarqube, env.SONAR_BASE_URL, "SonarQube URL"),
                    urlBackedTool("Dependency-Track", dependencyTrack, env.DEPENDENCY_TRACK_BASE_URL, "Dependency-Track URL"),
                    tool("OWASP ZAP", "Usable when Jenkins runs ZAP Docker and stores reports.", "outline"),
                    tool("Dependency-Check", "Usable through Jenkins archived SCA reports.", "outline"),
                    urlBackedTool("Vault", vaultPods, process.env.NEXT_PUBLIC_VAULT_UI_URL, "Vault URL"),
                    tool("Terraform / HAProxy / HashiCorp", "Show only when reports or URLs are configured in the app.", "outline")
                ]
            }
        ]
    };
}
