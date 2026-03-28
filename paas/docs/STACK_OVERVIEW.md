# Full stack overview – 24 technologies

Single-page overview of how every technology is integrated.

---

## CI/CD and build

| Tech | Role |
|------|------|
| **Jenkins** | Runs the pipeline (Groovy); triggered by PaaS API. |
| **Groovy** | Language of Jenkinsfile (Declarative/Scripted pipeline). |
| **Docker** | Builds container images inside the pipeline. |
| **Helm** | Packages Kubernetes manifests; Argo CD deploys from Git (Helm charts). |
| **JFrog CLI** | Publishes build artifacts to Artifactory from Jenkins. |
| **Artifactory** | Stores JAR (Spring Boot), npm (Angular), and other versioned artifacts. |

## Security and quality

| Tech | Role |
|------|------|
| **SonarQube** | SAST and code quality; Jenkins runs SonarScanner (Maven plugin or npx). |
| **Dependency Check** | OWASP; scans dependencies for CVEs; Jenkins runs CLI. |
| **Dependency Track** | Consumes SBOM (CycloneDX); Jenkins uploads after build. |
| **Trivy** | Scans container images in pipeline before push to Harbor. |
| **Cosign** | Signs images after push; OPA Gatekeeper can enforce signed-only. |
| **OPA Gatekeeper** | Kubernetes admission; enforces policies (e.g. signed images, no latest tag). |

## Registry and runtime

| Tech | Role |
|------|------|
| **Harbor** | Private container registry; images pushed from Jenkins. |
| **Kubernetes** | Runs all workloads; GitOps via Argo CD. |
| **Containerd** | Container runtime on K8s nodes (e.g. EKS 1.24+); runs same images as Docker. |

## Deployment and ingress

| Tech | Role |
|------|------|
| **Argo CD** | GitOps; syncs Git repo (Helm values) to Kubernetes. |
| **Nginx Ingress Controller** | Kubernetes Ingress; HTTP(S) routing and TLS. |
| **HAProxy** | Optional LB in front of Nginx Ingress (e.g. on AWS in front of NLB). |

## Monitoring

| Tech | Role |
|------|------|
| **Prometheus** | Scrapes metrics (cluster + app); stores time series. |
| **Grafana** | Dashboards; datasource Prometheus; linked from PaaS UI. |

## Application stacks

| Tech | Role |
|------|------|
| **Spring Boot** | Java backend; Maven/Gradle in Jenkins; JAR to Artifactory; Dockerfile for image. |
| **Angular** | Frontend; npm build in Jenkins; artifacts to Artifactory; Dockerfile (e.g. Nginx) for image. |

## Infrastructure

| Tech | Role |
|------|------|
| **Terraform** | IaC; provisions AWS (VPC, EKS, nodes, optional LB/HAProxy). |
| **AWS** | Cloud provider; EKS, EC2, VPC, ELB, S3 (Terraform state), IAM. |

---

## Pipeline flow (all tech in order)

1. **Git** push → webhook → **PaaS** → **Jenkins** (Groovy).
2. **Jenkins**: Checkout → **Spring Boot** (Maven) or **Angular**/Node (npm) build → **JFrog CLI** → **Artifactory**.
3. **SonarQube** (SAST) → **Dependency Check** (OWASP) → SBOM to **Dependency Track**.
4. **Docker** build → **Trivy** → push to **Harbor** → **Cosign** sign.
5. **Helm** package → update GitOps repo → **Argo CD** sync → **Kubernetes** (containerd).
6. **Nginx Ingress Controller** (and optionally **HAProxy**) expose apps; **OPA Gatekeeper** enforces policy.
7. **Prometheus** scrapes → **Grafana** dashboards.

Infrastructure: **Terraform** on **AWS** (EKS, VPC, nodes).
