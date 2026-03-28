# Technology Integration Matrix

This document maps each technology to its role in the DevSecOps PaaS and where it is configured or used.

| Technology | Role in platform | Integration point | Config / reference |
|------------|------------------|-------------------|--------------------|
| **Jenkins** | CI/CD orchestrator; runs pipeline (build, test, scan, push, deploy trigger) | PaaS API triggers jobs; developers do not access Jenkins UI | `jenkins/Jenkinsfile.pipeline`, Groovy pipelines |
| **Harbor** | Private container registry; stores Docker images | Jenkins pushes images after Trivy/Cosign; K8s pulls via imagePullSecrets | `docs/HARBOR_SECURITY_WORKFLOW.md` |
| **SonarQube** | Static code analysis (SAST), code quality | Jenkins runs SonarScanner; quality gate can fail build | Jenkinsfile stage "SonarQube Analysis" |
| **Artifactory** | Artifact repository; stores build outputs (JAR, npm, etc.) | Jenkins publishes via JFrog CLI / Artifactory plugin | `docs/ARTIFACTORY_INTEGRATION.md` |
| **JFrog CLI** | Publish/download artifacts to/from Artifactory | Used in Jenkins pipeline (e.g. `jfrog rt upload`) | Jenkins agent image or install step |
| **Argo CD** | GitOps; deploys from Git to Kubernetes | Jenkins updates GitOps repo; Argo CD syncs cluster | `docs/ARGOCD_GITOPS_WORKFLOW.md`, Application CR |
| **Dependency Track** | SCA; tracks vulns from SBOM (e.g. CycloneDX) | Jenkins uploads SBOM; policy can fail build | Jenkinsfile "Dependency Check" / SBOM upload |
| **Kubernetes** | Runtime for applications and platform services | Containerd runtime; workloads deployed via Argo CD | Ingress, Gatekeeper, namespaces |
| **Grafana** | Dashboards for metrics and logs | Datasource: Prometheus; per-project dashboards; linked from PaaS UI | `docs/MONITORING_ARCHITECTURE.md` |
| **Prometheus** | Metrics collection (cluster + app) | Scrapes K8s and app /metrics; Grafana queries it | Helm: kube-prometheus-stack |
| **Dependency Check** | OWASP; scans dependencies for CVEs | Jenkins runs dependency-check; report or SBOM to Dependency Track | Jenkinsfile stage, CLI or plugin |
| **HAProxy** | Load balancer (optional: in front of ingress or for TCP) | Can sit in front of Nginx Ingress or expose K8s NodePort/LB | Terraform / AWS ELB or HAProxy VM |
| **Nginx Ingress Controller** | Kubernetes Ingress; HTTP(S) routing | Exposes apps and PaaS UI; TLS termination | `k8s-manifests/ingress/`, Helm: ingress-nginx |
| **OPA Gatekeeper** | Policy enforcement in K8s (e.g. signed images) | Admission control; blocks non-compliant workloads | `k8s-manifests/gatekeeper/` |
| **Helm** | Package K8s manifests; templating | Charts for apps; Argo CD deploys from Git (Helm) | `helm-charts/paas-app/`, GitOps repo |
| **Trivy** | Container image vulnerability scan | Jenkins runs trivy image before push to Harbor | Jenkinsfile "Trivy Scan" |
| **Cosign** | Sign/verify container images | Jenkins signs after push; Gatekeeper can enforce signed only | `docs/HARBOR_SECURITY_WORKFLOW.md` |
| **Docker** | Build container images in pipeline | Jenkins uses Docker daemon or Docker-in-Docker to build images | Jenkinsfile "Docker Build", agent with Docker |
| **Containerd** | Container runtime on Kubernetes nodes | K8s uses containerd (not Docker) at runtime; same images | Kubelet config, node setup |
| **Spring Boot** | Java backend application stack | Build: Maven/Gradle; JAR published to Artifactory; Dockerfile for image | Sample Jenkinsfile stages for Java |
| **Angular** | Frontend application stack | Build: npm/ng build; artifacts to Artifactory; Dockerfile or Nginx image | Sample Jenkinsfile stages for Angular |
| **Terraform** | Infrastructure as Code (cloud + K8s infra) | Provisions AWS (VPC, EKS, etc.); optional: Nginx Ingress LB | `terraform/`, AWS modules |
| **Groovy** | Jenkins pipeline DSL | Jenkinsfile written in Groovy (Declarative or Scripted) | `jenkins/Jenkinsfile.pipeline` |
| **AWS** | Cloud provider | VPC, EKS, EC2, ELB, S3 (state), IAM; Terraform manages | `terraform/`, EKS/EC2 modules |

---

## Data flow (all technologies)

```
Developer (Git push)
    → Git (GitLab/GitHub)
    → Webhook → PaaS (Next.js)
    → Jenkins (Groovy pipeline)
        → Build: Maven/Gradle (Spring Boot) or npm (Angular)
        → JFrog CLI → Artifactory (JAR/npm artifacts)
        → SonarQube (SAST)
        → Dependency Check → SBOM → Dependency Track (SCA)
        → Docker build → Trivy → Harbor (push) → Cosign (sign)
        → Helm package → GitOps repo (or ChartMuseum)
    → Argo CD (sync from Git)
    → Kubernetes (containerd runtime)
        → Nginx Ingress Controller (HTTPS)
        → HAProxy (optional, in front)
        → OPA Gatekeeper (admission)
    → Prometheus (metrics) → Grafana (dashboards)
```

Infrastructure: **Terraform** on **AWS** (EKS, VPC, etc.).
