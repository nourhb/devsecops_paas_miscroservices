# DevSecOps PaaS – Technical Architecture Document

## Executive Summary

This document describes the architecture of a **Platform as a Service (PaaS)** that applies **DevSecOps** practices. The platform lets developers **build, deploy, and monitor applications through a user interface** without accessing Jenkins or infrastructure directly. The system behaves as a **black box**: developers push code to Git and use the platform UI; the rest is automated and secure.

**Integrated technologies (24):** Jenkins, Harbor, SonarQube, Artifactory, JFrog CLI, Argo CD, Dependency Track, Kubernetes, Grafana, Prometheus, Dependency Check, HAProxy, Nginx Ingress Controller, OPA Gatekeeper, Helm, Trivy, Cosign, Docker, Containerd, Spring Boot, Angular, Terraform, Groovy, AWS. See [TECHNOLOGY_INTEGRATION_MATRIX.md](./TECHNOLOGY_INTEGRATION_MATRIX.md) and [STACK_OVERVIEW.md](./STACK_OVERVIEW.md).

---

## 1. Full DevSecOps Architecture (Text Diagram)

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              DEVELOPER (Black-box user)                                   │
│  • Push code to Git (GitLab/GitHub)                                                      │
│  • Use PaaS UI: create project, trigger build, deploy, view metrics & security            │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           PAAS CONTROL PLANE (Next.js / API)                             │
│  • Project management  • Pipeline triggers  • Deployment triggers  • Dashboards          │
│  • No direct Jenkins access; all via API                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                          │
          ┌───────────────────────────────┼───────────────────────────────┐
          ▼                               ▼                               ▼
┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
│  Git (GitLab /   │            │  Jenkins         │            │  ArgoCD           │
│  GitHub)         │            │  • Build         │            │  • GitOps sync    │
│  • SCM           │───────────▶│  • Test         │            │  • K8s deploy    │
│  • Webhooks      │            │  • Scan          │            │                  │
│  • Branch strat  │            │  • Docker build  │            │                  │
└──────────────────┘            │  • Helm package  │            └────────┬─────────┘
                                └────────┬─────────┘                     │
                                         │                              │
          ┌──────────────────────────────┼──────────────────────────────┤
          ▼                              ▼                              ▼
┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
│  Artifactory     │            │  Harbor          │            │  Kubernetes      │
│  • Build artifacts│            │  • Images        │            │  • containerd     │
│  • Versioning    │            │  • ChartMuseum   │            │  • Ingress (HTTPS)│
│                  │            │  • Trivy + Cosign │            │  • Workloads      │
└──────────────────┘            └──────────────────┘            └────────┬─────────┘
                                                                         │
          ┌──────────────────────────────────────────────────────────────┤
          ▼                              ▼                               ▼
┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
│  SonarQube       │            │  Dependency-Track │            │  OPA Gatekeeper  │
│  • SAST          │            │  • SCA / SBOM     │            │  • Policy enforce│
│  • Code quality  │            │  • Vuln libs       │            │  • Image signing │
└──────────────────┘            └──────────────────┘            └──────────────────┘
          │
          ▼
┌──────────────────┐            ┌──────────────────┐
│  OWASP ZAP       │            │  Prometheus +    │
│  • DAST          │            │  Grafana         │
│  • Post-deploy   │            │  • Cluster + app │
└──────────────────┘            └──────────────────┘
```

**Data flow (simplified):** Git → Webhook → Jenkins → Build/Test/Scan → Artifactory + Harbor (signed images + charts) → GitOps repo → ArgoCD → Kubernetes. Monitoring and security (SonarQube, Dependency-Track, ZAP, OPA) are integrated at the appropriate pipeline and cluster stages.

---

## 2. Complete Platform Workflow

### 2.1 Developer workflow (black box)

1. **Developer** creates/selects a project in the **PaaS UI** and connects a Git repository (GitLab/GitHub).
2. **Developer** pushes code to the configured branch (e.g. `main`).
3. **Webhook** (or polling) notifies the **PaaS control plane**; the control plane triggers the **Jenkins** pipeline (via API; developer does not see Jenkins).
4. **Pipeline** runs: checkout → dependency/SAST (SonarQube, Dependency-Check/Track) → build → Docker build → Trivy scan → Cosign sign → push to **Harbor** → Helm package → push chart to **ChartMuseum** / GitOps repo → update **GitOps** manifests.
5. **ArgoCD** syncs from the GitOps repo and deploys to **Kubernetes**.
6. **Developer** sees status, logs, and **Grafana** dashboards in the PaaS UI; **OWASP ZAP** (DAST) can run post-deploy; **OPA Gatekeeper** enforces policies (e.g. signed images only).

### 2.2 Pipeline stages (high level)

| Stage            | Tools / Actions |
|------------------|------------------|
| Source           | Git (GitLab/GitHub), webhook → PaaS → Jenkins |
| Build            | Jenkins, build tool (e.g. Maven/npm) |
| Artifacts        | Artifactory (build outputs, versioned) |
| SAST / Quality   | SonarQube |
| Dependencies     | Dependency-Check, Dependency-Track (SBOM, vuln scan) |
| Container        | Docker build, Trivy scan, Cosign sign |
| Registry         | Harbor (images), ChartMuseum (Helm charts) |
| Package          | Helm chart build and versioning |
| GitOps           | Commit to GitOps repo (manifests + Helm values) |
| Deploy           | ArgoCD sync → Kubernetes |
| Runtime security | OPA Gatekeeper |
| DAST             | OWASP ZAP (after app is exposed) |
| Monitoring       | Prometheus + Grafana, dashboards per project |

---

## 3. Folder Structure for the Platform

```
paas/
├── docs/
│   ├── DEVSOPS_PAAS_ARCHITECTURE.md    # This document
│   ├── FOLDER_STRUCTURE.md             # Detailed folder map
│   └── SECURITY_INTEGRATION.md         # Security touchpoints
├── backend-next/                        # PaaS control plane (API + UI)
│   ├── src/
│   │   ├── app/                        # Next.js App Router, API routes
│   │   └── lib/                        # Services (Jenkins, Harbor, ArgoCD, etc.)
│   ├── Dockerfile
│   └── Jenkinsfile                     # If control plane is also built via pipeline
├── frontend/                           # Optional separate UI (or part of backend-next)
├── gitops/                             # GitOps repo content (or reference)
│   ├── apps/
│   │   ├── sample-app/
│   │   │   ├── Chart.yaml
│   │   │   ├── values.yaml
│   │   │   └── templates/
│   │   └── <project-name>/
│   └── charts/
├── helm-charts/                        # Shared / template Helm charts
│   └── paas-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── jenkins/
│   ├── Jenkinsfile.pipeline            # Main pipeline (build, scan, push, deploy)
│   ├── Jenkinsfile.lib                 # Shared library (optional)
│   └── jobs/                           # Job DSL or configs (optional)
├── k8s-manifests/                      # Base K8s manifests (ingress, gatekeeper, etc.)
│   ├── ingress/
│   ├── gatekeeper/
│   └── namespaces.yaml
├── terraform/                           # Infrastructure as Code
│   ├── modules/
│   │   ├── kubernetes/
│   │   ├── networking/
│   │   └── monitoring/
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── main.tf
├── monitoring/
│   ├── prometheus/
│   ├── grafana/
│   │   └── dashboards/
│   └── alerts/
├── scripts/                            # Automation (bootstrap, post-deploy)
├── .env.example
├── docker-compose.yml                  # Local dev (optional)
└── README.md
```

---

## 4. Component-by-Component Architecture

### 4.1 Kubernetes cluster

- **Role:** Run all application workloads; expose them via Ingress with HTTPS.
- **Runtime:** containerd.
- **Structure:** Control plane (API server, etcd, scheduler, controller-manager); worker nodes for workloads; system components (Ingress controller, Prometheus, ArgoCD, etc.) in dedicated namespaces.
- **Ingress:** Single or multiple Ingress controllers (e.g. NGINX); TLS termination at Ingress; routing by host/path to Services.

See **Section 5** for an example Ingress configuration.

---

### 4.2 Docker image management (Harbor)

- **Harbor:** Private registry for Docker images; projects per team/app; replication and retention policies.
- **ChartMuseum:** Integrated or adjacent for Helm chart storage; Jenkins pushes charts here or to a GitOps repo.
- **Trivy:** Scan images in the pipeline (e.g. in Jenkins); fail or warn on critical/high CVEs.
- **Cosign:** Sign images after push; store signatures in Harbor (OCI artifact) or separate registry.

**Image workflow:** Build → Trivy scan → Push to Harbor → Cosign sign → (optional) verify in cluster via OPA.

**Example commands:** See **Section 6**.

---

### 4.3 CI/CD (Jenkins)

- **Role:** Execute the pipeline; triggered by PaaS API (no direct Jenkins access for developers).
- **Stages:** Checkout → Install deps → Unit tests → SonarQube → Dependency-Check → Docker build → Trivy → Push to Harbor → Cosign sign → Build Helm chart → Push chart / update GitOps repo → Trigger ArgoCD sync (or let ArgoCD auto-sync).
- **Secrets:** Stored in Jenkins credentials (Harbor, Git, Artifactory, Cosign keys, etc.).

See **Section 7** for an example Jenkinsfile.

---

### 4.4 Source code management (GitLab / GitHub)

- **Git workflow:** Main branch (e.g. `main`) for production; optional `develop` and feature branches; tags for releases.
- **Pipeline trigger:** Webhook from Git to PaaS; PaaS starts the corresponding Jenkins job. Alternatively, Jenkins discovers branches via SCM and runs on push.
- **Branch strategy:** Build and deploy from `main` (or a release branch); feature branches can run build + test only.

---

### 4.5 Artifact management (Artifactory)

- **Role:** Store build artifacts (JARs, npm packages, etc.); versioned and promoted.
- **Integration:** Jenkins publishes artifacts to Artifactory after build; later stages or other jobs can pull by version. Version comes from Git tag or build number.

---

### 4.6 Deployment management (ArgoCD)

- **GitOps:** Desired state in Git (GitOps repo); ArgoCD reconciles the cluster with that state.
- **Flow:** Jenkins (or PaaS) updates the GitOps repo (e.g. image tag in `values.yaml`); ArgoCD detects the change and applies manifests (including Helm).
- **Benefits:** Audit trail, rollback via Git, same process for all envs.

See **Section 8** for ArgoCD workflow and example.

---

### 4.7 Dependency analysis (Dependency-Track / Dependency-Check)

- **Dependency-Check:** Run in Jenkins (CLI or plugin); produces a report (e.g. CVE list).
- **Dependency-Track:** Consume SBOM (e.g. CycloneDX) from the pipeline; track vulns over time; optionally fail the build on policy violation.
- **Place in pipeline:** After dependency resolution, before or parallel to build; SBOM generation can be part of the build step.

---

### 4.8 Cluster monitoring (Prometheus + Grafana)

- **Prometheus:** Scrape cluster metrics (nodes, pods, services) and app metrics (if exposed).
- **Grafana:** Dashboards for cluster health and per-project/app views; datasource = Prometheus.
- **Placement:** Prometheus and Grafana in a dedicated namespace; optionally provisioned by Terraform or Helm.

See **Section 9** for monitoring architecture and dashboard ideas.

---

### 4.9 Static code analysis (SonarQube)

- **Integration:** Jenkins runs SonarScanner (or equivalent) after build; sends analysis to SonarQube server; quality gate can fail the build.
- **Place in pipeline:** After compile, before container build.

---

### 4.10 Application packaging (Docker + Helm)

- **Docker:** Multi-stage Dockerfile in app repo; Jenkins builds and pushes to Harbor.
- **Helm:** Chart per app (or shared template); `values.yaml` holds image tag, replicas, env; chart stored in ChartMuseum or in GitOps repo.

See **Section 10** for Helm chart structure and packaging workflow.

---

### 4.11 Security and penetration testing (OWASP ZAP, OPA Gatekeeper)

- **OWASP ZAP:** DAST; run in pipeline against a deployed staging URL (after ArgoCD deploy) or as a separate post-deploy job; report stored or sent to security dashboard.
- **OPA Gatekeeper:** Policies (e.g. “only signed images”, “no latest tag”) enforced at admission; ConstraintTemplates + Constraints; blocks non-compliant workloads.

See **Section 11** for integration points.

---

### 4.12 Infrastructure provisioning (Cloud + Terraform)

- **Cloud:** AWS / Azure / GCP for VMs, networking, load balancers, and (optionally) managed Kubernetes.
- **Terraform:** Modules for VPC, subnets, security groups, node groups (or EKS/AKS/GKE), and optionally Ingress controller, cert-manager, Prometheus/Grafana.
- **Kubernetes nodes:** Created via Terraform (e.g. node pools / worker groups); join cluster or use managed control plane.

See **Section 12** for Terraform layout and examples.

---

## 5. Example Configuration Files (Reference)

| Component | Location | Description |
|-----------|----------|-------------|
| Kubernetes Ingress (HTTPS) | `k8s-manifests/ingress/ingress-https-example.yaml` | NGINX Ingress with TLS; app and PaaS exposure |
| Jenkins pipeline | `jenkins/Jenkinsfile.pipeline` | Full pipeline: build, SonarQube, Dependency-Check, Docker, Trivy, Harbor, Cosign, Helm, GitOps, ArgoCD, ZAP |
| OPA Gatekeeper | `k8s-manifests/gatekeeper/constraint-signed-images.yaml` | ConstraintTemplate + Constraint for signed images |
| Helm chart (generic app) | `helm-charts/paas-app/` | Chart.yaml, values.yaml, templates (Deployment, Service, Ingress) |
| Terraform (skeleton) | `terraform/environments/dev/main.tf.example`, `terraform/README.md` | Module layout and dev environment example |
| Harbor / Trivy / Cosign | `docs/HARBOR_SECURITY_WORKFLOW.md` | Commands and workflow |
| ArgoCD / GitOps | `docs/ARGOCD_GITOPS_WORKFLOW.md` | Workflow and Application example |
| Monitoring | `docs/MONITORING_ARCHITECTURE.md` | Prometheus + Grafana architecture and dashboards |
| Security integration | `docs/SECURITY_INTEGRATION.md` | SAST, SCA, Trivy, Cosign, Gatekeeper, ZAP |
| Git workflow & triggers | `docs/GIT_WORKFLOW_AND_TRIGGERS.md` | Branch strategy and webhook → PaaS → Jenkins |
| Artifactory | `docs/ARTIFACTORY_INTEGRATION.md` | Publish artifacts from Jenkins |
| Implementation plan | `docs/IMPLEMENTATION_PLAN.md` | Phased rollout (8 weeks) |
| Folder structure | `docs/FOLDER_STRUCTURE.md` | Full directory map and conventions |

---

## 6. CI/CD Pipeline Design (Summary)

- **Trigger:** Git webhook → PaaS API → Jenkins job (no direct Jenkins access).
- **Stages (in order):** Checkout → Build → Publish to Artifactory (optional) → SonarQube → Dependency-Check / Dependency-Track → Docker build → Trivy → Push to Harbor → Cosign sign → Helm package → Update GitOps repo → ArgoCD sync → DAST (OWASP ZAP, optional).
- **Secrets:** Stored in Jenkins credentials and Kubernetes secrets; never in code.
- **Failure handling:** Any stage can fail the build; quality gates (SonarQube, Trivy severity) configurable.

---

*End of main architecture document. All referenced docs and example configs are in the repository under the paths above.*
