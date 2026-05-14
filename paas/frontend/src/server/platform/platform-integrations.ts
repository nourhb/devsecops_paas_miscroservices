import { env } from "@/server/config/env";
import { isRealConfigured, realValueOrEmpty } from "@/server/config/real-values";
import { getDeployPipelineReadiness } from "@/server/services/deploy-pipeline-readiness";
import type { PlatformIntegrationCategory, PlatformIntegrationsResponse } from "@/types";
function trimUrl(v: string | undefined): string {
    return (v ?? "").trim().replace(/\/+$/, "");
}
function firstNonEmpty(...values: (string | undefined)[]): string {
    for (const v of values) {
        const s = trimUrl(v);
        if (s) {
            return s;
        }
    }
    return "";
}
function deriveGithubOrgBase(gitopsUrl: string): string {
    const raw = trimUrl(gitopsUrl);
    if (!raw) {
        return "";
    }
    try {
        const u = new URL(raw);
        if (u.hostname === "github.com") {
            const parts = u.pathname.split("/").filter(Boolean);
            if (parts.length >= 1) {
                return `${u.origin}/${parts[0]}`;
            }
        }
        return u.origin;
    }
    catch {
        return "";
    }
}
function deriveGithubLink(gitopsUrl: string): string {
    const raw = trimUrl(gitopsUrl);
    if (!raw) {
        return "";
    }
    try {
        const u = new URL(raw);
        if (u.hostname === "github.com") {
            const parts = u.pathname.split("/").filter(Boolean);
            if (parts.length >= 2) {
                return `${u.origin}/${parts[0]}/${parts[1].replace(/\.git$/, "")}`;
            }
        }
        return raw;
    }
    catch {
        return "";
    }
}
function dockerHubProfileUrl(username: string): string {
    const user = realValueOrEmpty(username).trim();
    return user ? `https://hub.docker.com/u/${encodeURIComponent(user)}` : "";
}
function publicEnv(name: string): string {
    return trimUrl(realValueOrEmpty(process.env[name]));
}
function artifactoryPublicOrServer(): string {
    return firstNonEmpty(publicEnv("NEXT_PUBLIC_ARTIFACTORY_URL"), trimUrl(realValueOrEmpty(env.ARTIFACTORY_URL)));
}
function kubeApiServerFromConfig(): string {
    const raw = trimUrl(process.env.KUBE_API_SERVER);
    if (raw) {
        return raw;
    }
    const kubePath = trimUrl(process.env.KUBE_CONFIG_PATH);
    if (!kubePath) {
        return "";
    }
    try {
        const fs = require("node:fs") as typeof import("node:fs");
        const text = fs.readFileSync(kubePath, "utf8");
        const match = text.match(/^\s*server:\s*(\S+)\s*$/m);
        const s = trimUrl(match?.[1]);
        return s;
    }
    catch {
        return "";
    }
}
export function buildPlatformIntegrations(): PlatformIntegrationsResponse {
    const springBackend = trimUrl(realValueOrEmpty(process.env.SPRING_BACKEND_BASE_URL));
    const harborConfigured = isRealConfigured(env.HARBOR_BASE_URL);
    const kubeApiServer = kubeApiServerFromConfig();
    const categories: PlatformIntegrationCategory[] = [
        {
            id: "control-infra",
            title: "Control & infrastructure",
            description: "Kubernetes control plane, ingress, TLS, and pod networking.",
            items: [
                {
                    id: "k8s-control-plane",
                    name: "Kubernetes API & scheduler",
                    description: "Cluster control plane (API server, etcd, scheduler, controller manager).",
                    kind: "external",
                    href: firstNonEmpty(publicEnv("NEXT_PUBLIC_KUBERNETES_DASHBOARD_URL"), publicEnv("NEXT_PUBLIC_K8S_DASHBOARD_URL"), kubeApiServer),
                    configured: Boolean(firstNonEmpty(publicEnv("NEXT_PUBLIC_KUBERNETES_DASHBOARD_URL"), publicEnv("NEXT_PUBLIC_K8S_DASHBOARD_URL"), kubeApiServer)),
                    notes: kubeApiServer
                        ? `API server: ${kubeApiServer}. When KUBERNETES_ENABLED=true, reachability uses the kubeconfig client (not a browser GET to this URL).`
                        : "Optional: Lens / k9s / dashboard URL. The Cluster page lists workloads when the API is connected."
                },
                {
                    id: "cluster-paas-ui",
                    name: "Cluster explorer (this app)",
                    description: "Pods, services, and deployments visible to the platform API.",
                    kind: "internal",
                    href: null,
                    internalPath: "/cluster",
                    configured: env.KUBERNETES_ENABLED === "true" && Boolean(trimUrl(env.KUBE_CONFIG_PATH)),
                    notes: "Requires server-side cluster access to list pods and resources."
                },
                {
                    id: "portainer",
                    name: "Portainer",
                    description: "Docker/Kubernetes UI for clusters and edge agents.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_PORTAINER_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_PORTAINER_URL")),
                    notes: "Often installed in namespace portainer; deep link the UI here."
                },
                {
                    id: "ingress-nginx",
                    name: "Ingress (Traefik / NGINX)",
                    description: "HTTP/S ingress controller (Traefik on k3s, or NGINX Ingress).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_INGRESS_NGINX_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_INGRESS_NGINX_URL")),
                    notes: "Set NEXT_PUBLIC_INGRESS_NGINX_URL to your entrypoint (k3s+Traefik is often http://<node>:30659). From Docker, add INGRESS_NGINX_PROBE_URL or INTEGRATIONS_PROBE_HOST_REMAP (see docker-compose.env.example)."
                },
                {
                    id: "cert-manager",
                    name: "cert-manager",
                    description: "TLS certificates via ACME / CA issuers.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_CERT_MANAGER_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_CERT_MANAGER_UI_URL")),
                    notes: "Often observed via kubectl or Argo CD; set a URL if you expose a UI or doc portal."
                },
                {
                    id: "calico",
                    name: "Calico",
                    description: "CNI / network policy (BGP or VXLAN overlay).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_CALICO_OR_TIGERA_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_CALICO_OR_TIGERA_URL")),
                    notes: "Calico itself has no single dashboard; Tigera / Calico Cloud optional."
                }
            ]
        },
        {
            id: "security-policy",
            title: "Security & policy",
            description: "Admission control, supply-chain signing, and image policy.",
            items: [
                {
                    id: "opa-gatekeeper",
                    name: "OPA Gatekeeper",
                    description: "Kubernetes policy via Gatekeeper CRDs and OPA.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_GATEKEEPER_DASHBOARD_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_GATEKEEPER_DASHBOARD_URL")),
                    notes: env.POLICY_ENGINE === "gatekeeper" ? "POLICY_ENGINE is set to gatekeeper." : undefined
                },
                {
                    id: "opa-server",
                    name: "OPA (Rego evaluation)",
                    description: "Open Policy Agent REST evaluation used by deploy gates.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.OPA_EVAL_URL)) || null,
                    configured: isRealConfigured(env.OPA_EVAL_URL),
                    notes: env.POLICY_ENGINE === "opa" ? "POLICY_ENGINE is set to opa." : undefined
                },
                {
                    id: "kyverno",
                    name: "Kyverno",
                    description: "Kubernetes-native policies (validate, mutate, generate).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_KYVERNO_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_KYVERNO_UI_URL")),
                    notes: env.POLICY_ENGINE === "kyverno" ? "POLICY_ENGINE is set to kyverno." : undefined
                },
                {
                    id: "kubewarden",
                    name: "Kubewarden",
                    description: "Policy-as-code with WebAssembly policies (Kyverno migration path).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_KUBEWARDEN_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_KUBEWARDEN_UI_URL"))
                },
                {
                    id: "cosign",
                    name: "Cosign",
                    description: "Sign and verify OCI images and artifacts (CLI / keyless).",
                    kind: "cli",
                    href: null,
                    configured: Boolean(trimUrl(realValueOrEmpty(env.COSIGN_PUBLIC_KEY)) || trimUrl(realValueOrEmpty(env.COSIGN_PRIVATE_KEY))),
                    notes: `Binary: ${env.COSIGN_BINARY_PATH || "cosign"}. Enforcement: COSIGN_ENFORCE_SIGNED=${env.COSIGN_ENFORCE_SIGNED}.`
                },
                {
                    id: "trivy-policy",
                    name: "Trivy (CI & registry)",
                    description: "Vulnerability and misconfiguration scanning.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.TRIVY_BASE_URL)) || null,
                    configured: isRealConfigured(env.TRIVY_BASE_URL)
                }
            ]
        },
        {
            id: "monitoring",
            title: "Monitoring",
            description: "Metrics, dashboards, and alerting.",
            items: [
                {
                    id: "prometheus",
                    name: "Prometheus",
                    description: "Time-series metrics and PromQL.",
                    kind: "external",
                    href: firstNonEmpty(realValueOrEmpty(env.PROMETHEUS_BASE_URL), publicEnv("NEXT_PUBLIC_PROMETHEUS_URL")),
                    configured: Boolean(firstNonEmpty(realValueOrEmpty(env.PROMETHEUS_BASE_URL), publicEnv("NEXT_PUBLIC_PROMETHEUS_URL")))
                },
                {
                    id: "grafana",
                    name: "Grafana",
                    description: "Dashboards on Prometheus and other data sources.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_GRAFANA_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_GRAFANA_URL"))
                },
                {
                    id: "alertmanager",
                    name: "Alertmanager",
                    description: "Alert routing, silences, and receivers.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_ALERTMANAGER_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_ALERTMANAGER_URL"))
                },
                {
                    id: "pushgateway",
                    name: "Pushgateway",
                    description: "Accept metrics pushed from batch jobs for Prometheus.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_PUSHGATEWAY_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_PUSHGATEWAY_URL"))
                },
                {
                    id: "kube-state-metrics",
                    name: "kube-state-metrics",
                    description: "Kubernetes object metrics consumed by Prometheus / Grafana dashboards.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_KUBE_STATE_METRICS_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_KUBE_STATE_METRICS_URL")),
                    notes: "Usually scraped without a browser UI; set a metrics or docs URL if you expose one."
                },
                {
                    id: "node-exporter",
                    name: "Node exporter",
                    description: "Host hardware and OS metrics for Prometheus.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_NODE_EXPORTER_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_NODE_EXPORTER_UI_URL")),
                    notes: "Typically scraped by Prometheus without a browser UI; link targets or docs if you expose one."
                },
                {
                    id: "kibana",
                    name: "Kibana",
                    description: "Elastic Stack dashboards and Discover.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_KIBANA_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_KIBANA_URL"))
                },
                {
                    id: "elasticsearch",
                    name: "Elasticsearch",
                    description: "Search and analytics engine (logs, APM, security).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_ELASTICSEARCH_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_ELASTICSEARCH_URL"))
                }
            ]
        },
        {
            id: "cicd",
            title: "CI / CD",
            description: "Build, GitOps, and source control.",
            items: [
                {
                    id: "jenkins",
                    name: "Jenkins",
                    description: "Pipeline runs triggered from projects in this app.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.JENKINS_BASE_URL)) || null,
                    configured: isRealConfigured(env.JENKINS_BASE_URL)
                },
                {
                    id: "tekton",
                    name: "Tekton",
                    description: "Kubernetes-native CI when BUILD_BACKEND=tekton.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_TEKTON_DASHBOARD_URL") || null,
                    configured: env.BUILD_BACKEND === "tekton" || Boolean(publicEnv("NEXT_PUBLIC_TEKTON_DASHBOARD_URL")),
                    notes: env.BUILD_BACKEND === "tekton" ? `Namespace ${env.TEKTON_NAMESPACE}` : "Switch BUILD_BACKEND=tekton to use Tekton builds."
                },
                {
                    id: "argocd",
                    name: "Argo CD",
                    description: "Continuous delivery and GitOps sync status per project.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.ARGOCD_BASE_URL)) || null,
                    configured: isRealConfigured(env.ARGOCD_BASE_URL)
                },
                {
                    id: "github",
                    name: "GitHub",
                    description: "Repositories, webhooks, and GitOps commits.",
                    kind: "external",
                    href: firstNonEmpty(deriveGithubLink(realValueOrEmpty(env.GITOPS_REPO_URL)), publicEnv("NEXT_PUBLIC_GITHUB_CONSOLE_URL"), deriveGithubOrgBase(realValueOrEmpty(env.GITOPS_REPO_URL))),
                    configured: Boolean(firstNonEmpty(deriveGithubLink(realValueOrEmpty(env.GITOPS_REPO_URL)), publicEnv("NEXT_PUBLIC_GITHUB_CONSOLE_URL"), deriveGithubOrgBase(realValueOrEmpty(env.GITOPS_REPO_URL)))),
                    notes: trimUrl(realValueOrEmpty(env.GITOPS_REPO_URL)) ? `GitOps repo: ${trimUrl(realValueOrEmpty(env.GITOPS_REPO_URL))}` : "Configure GITOPS_REPO_URL or NEXT_PUBLIC_GITHUB_CONSOLE_URL."
                },
                {
                    id: "gitops-repo",
                    name: "GitOps values (this app)",
                    description: "Helm values path pattern used on deploy.",
                    kind: "cli",
                    href: null,
                    configured: isRealConfigured(env.GITOPS_REPO_URL, env.GITOPS_REPO_TOKEN),
                    notes: `Branch ${env.GITOPS_DEFAULT_BRANCH}; pattern ${env.GITOPS_VALUES_PATH_PATTERN}`
                }
            ]
        },
        {
            id: "registry",
            title: "Registry & repositories",
            description: "Image registries and binary repositories.",
            items: [
                {
                    id: "harbor-dockerhub",
                    name: "Harbor (primary OCI registry)",
                    description: "Harbor, or Docker Hub when HARBOR_BASE_URL targets docker.io / hub.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.HARBOR_BASE_URL)) || null,
                    configured: harborConfigured
                },
                {
                    id: "dockerhub",
                    name: "Docker Hub",
                    description: "Docker Hub namespace used by deploy pipelines.",
                    kind: "external",
                    href: dockerHubProfileUrl(env.DOCKERHUB_USERNAME) || null,
                    configured: Boolean(dockerHubProfileUrl(env.DOCKERHUB_USERNAME))
                },
                {
                    id: "nexus",
                    name: "Sonatype Nexus",
                    description: "Maven/npm/Docker repository manager.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_NEXUS_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_NEXUS_URL"))
                },
                {
                    id: "artifactory",
                    name: "JFrog Artifactory",
                    description: "Universal artifact repository.",
                    kind: "external",
                    href: artifactoryPublicOrServer() || null,
                    configured: Boolean(artifactoryPublicOrServer())
                },
                {
                    id: "artifacts-spring",
                    name: "Artifacts API (Spring)",
                    description: "Optional Spring backend listing for generic artifacts.",
                    kind: "internal",
                    href: null,
                    internalPath: "/artifacts",
                    configured: Boolean(springBackend),
                    notes: springBackend ? `Proxy: ${springBackend}` : "Set SPRING_BACKEND_BASE_URL to enable /artifacts."
                }
            ]
        },
        {
            id: "security-scan",
            title: "Security scanning",
            description: "SAST, DAST, containers, and SBOM analysis.",
            items: [
                {
                    id: "sonarqube",
                    name: "SonarQube",
                    description: "Static analysis and quality gates.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.SONAR_BASE_URL)) || null,
                    configured: isRealConfigured(env.SONAR_BASE_URL)
                },
                {
                    id: "owasp-zap",
                    name: "OWASP ZAP",
                    description: "Dynamic application security testing.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_OWASP_ZAP_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_OWASP_ZAP_URL"))
                },
                {
                    id: "owasp-dependency-check",
                    name: "OWASP Dependency-Check",
                    description: "SCA for vulnerable dependencies (NVD-backed); often run in Jenkins with HTML reports.",
                    kind: "external",
                    href: firstNonEmpty(publicEnv("NEXT_PUBLIC_DEPENDENCY_CHECK_URL"), publicEnv("NEXT_PUBLIC_OWASP_DEPENDENCY_CHECK_URL")) || null,
                    configured: Boolean(firstNonEmpty(publicEnv("NEXT_PUBLIC_DEPENDENCY_CHECK_URL"), publicEnv("NEXT_PUBLIC_OWASP_DEPENDENCY_CHECK_URL")))
                },
                {
                    id: "dockle",
                    name: "Dockle",
                    description: "Container image best-practices checker (often run in CI).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_DOCKLE_REPORT_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_DOCKLE_REPORT_URL")),
                    notes: "Also available as CLI in Jenkins stages."
                },
                {
                    id: "dependency-track",
                    name: "Dependency-Track",
                    description: "Component analysis and vulnerability tracking.",
                    kind: "external",
                    href: trimUrl(realValueOrEmpty(env.DEPENDENCY_TRACK_BASE_URL)) || null,
                    configured: isRealConfigured(env.DEPENDENCY_TRACK_BASE_URL)
                },
                {
                    id: "project-security",
                    name: "Per-project security view",
                    description: "Aggregated signals in this app (open any project).",
                    kind: "internal",
                    href: null,
                    internalPath: "/projects",
                    configured: true,
                    notes: "Trivy, Sonar, Dependency-Track, Cosign, and OPA-style gates are summarized per project."
                }
            ]
        },
        {
            id: "infra",
            title: "Infrastructure as code & secrets",
            description: "Provisioning, load balancing, and secret management.",
            items: [
                {
                    id: "terraform",
                    name: "Terraform",
                    description: "Infrastructure provisioning (modules and state).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_TERRAFORM_CLOUD_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_TERRAFORM_CLOUD_URL")),
                    notes: "CLI runs outside this UI; link HCP Terraform / Enterprise if used."
                },
                {
                    id: "vault",
                    name: "HashiCorp Vault",
                    description: "Secrets, PKI, and dynamic credentials.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_VAULT_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_VAULT_UI_URL"))
                },
                {
                    id: "haproxy",
                    name: "HAProxy",
                    description: "Load balancing and TLS termination stats.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_HAPROXY_STATS_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_HAPROXY_STATS_URL"))
                },
                {
                    id: "edge-iot",
                    name: "Edge / Raspberry Pi",
                    description: "Optional link to edge gateway, Pi fleet, or industrial dashboards outside the primary cluster.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_EDGE_IOT_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_EDGE_IOT_URL"))
                },
                {
                    id: "consul",
                    name: "HashiCorp Consul",
                    description: "Service mesh registry and KV (optional HashiCorp stack).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_CONSUL_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_CONSUL_UI_URL"))
                },
                {
                    id: "nomad",
                    name: "HashiCorp Nomad",
                    description: "Workload orchestrator (optional HashiCorp stack).",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_NOMAD_UI_URL") || null,
                    configured: Boolean(publicEnv("NEXT_PUBLIC_NOMAD_UI_URL"))
                }
            ]
        },
        {
            id: "runtimes",
            title: "Application runtimes & data",
            description: "Stacks this platform templates and deploys.",
            items: [
                {
                    id: "nextjs-ui",
                    name: "Next.js (this control plane)",
                    description: "Current web UI and API routes.",
                    kind: "internal",
                    href: null,
                    internalPath: "/dashboard",
                    configured: true,
                    notes: `APP_BASE_URL=${trimUrl(env.APP_BASE_URL) || "(unset)"}`
                },
                {
                    id: "nodejs-express",
                    name: "Node.js / Express",
                    description: "Build profile: Node services and APIs.",
                    kind: "internal",
                    href: null,
                    internalPath: "/projects/create",
                    configured: true,
                    notes: "Choose language Node when creating a project; pipeline uses the Node build profile."
                },
                {
                    id: "python",
                    name: "Python",
                    description: "Build profile: Python applications and workers.",
                    kind: "internal",
                    href: null,
                    internalPath: "/projects/create",
                    configured: true,
                    notes: "Choose Python when creating a project."
                },
                {
                    id: "java-static",
                    name: "Java & static sites",
                    description: "Additional build profiles supported by templates.",
                    kind: "internal",
                    href: null,
                    internalPath: "/projects/create",
                    configured: true
                },
                {
                    id: "plsql",
                    name: "PL/SQL & Oracle data tier",
                    description: "Use alongside app services; connect via JDBC from your app image.",
                    kind: "external",
                    href: publicEnv("NEXT_PUBLIC_ORACLE_APEX_URL") || publicEnv("NEXT_PUBLIC_DB_ADMIN_URL") || null,
                    configured: Boolean(firstNonEmpty(publicEnv("NEXT_PUBLIC_ORACLE_APEX_URL"), publicEnv("NEXT_PUBLIC_DB_ADMIN_URL"))),
                    notes: "This app uses PostgreSQL for its own data; point PL/SQL consoles or APEX here if you use Oracle in the cluster."
                }
            ]
        }
    ];
    return {
        categories,
        meta: {
            policyEngine: env.POLICY_ENGINE,
            kubernetesEnabled: env.KUBERNETES_ENABLED === "true",
            buildBackend: env.BUILD_BACKEND,
            harborConfigured,
            springBackendConfigured: Boolean(springBackend),
            deployReadiness: getDeployPipelineReadiness()
        }
    };
}
