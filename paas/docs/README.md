# DevSecOps PaaS – Documentation Index

Technical architecture and implementation for the PaaS platform (black box for developers).

## Start here

| Document | Description |
|----------|-------------|
| [DEVSOPS_PAAS_ARCHITECTURE.md](./DEVSOPS_PAAS_ARCHITECTURE.md) | **Main architecture**: diagram, workflow, components, and references to all examples |
| [STACK_OVERVIEW.md](./STACK_OVERVIEW.md) | **24 technologies** in one page: Jenkins, Harbor, SonarQube, Artifactory, JFrog CLI, Argo CD, Dependency Track, Kubernetes, Grafana, Prometheus, Dependency Check, HAProxy, Nginx Ingress, OPA Gatekeeper, Helm, Trivy, Cosign, Docker, Containerd, Spring Boot, Angular, Terraform, Groovy, AWS |
| [TECHNOLOGY_INTEGRATION_MATRIX.md](./TECHNOLOGY_INTEGRATION_MATRIX.md) | Per-technology role, integration point, and config location |
| [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md) | Phased implementation (8 weeks) and success criteria |
| [FOLDER_STRUCTURE.md](./FOLDER_STRUCTURE.md) | Repository folder layout and conventions |

## By topic

| Topic | Document |
|-------|----------|
| Kubernetes Ingress (HTTPS) | See `../k8s-manifests/ingress/ingress-https-example.yaml` |
| Jenkins pipeline | See `../jenkins/Jenkinsfile.pipeline` |
| Harbor, Trivy, Cosign | [HARBOR_SECURITY_WORKFLOW.md](./HARBOR_SECURITY_WORKFLOW.md) |
| ArgoCD / GitOps | [ARGOCD_GITOPS_WORKFLOW.md](./ARGOCD_GITOPS_WORKFLOW.md) |
| Monitoring (Prometheus, Grafana) | [MONITORING_ARCHITECTURE.md](./MONITORING_ARCHITECTURE.md) |
| Security (SAST, SCA, DAST, OPA) | [SECURITY_INTEGRATION.md](./SECURITY_INTEGRATION.md) |
| Git workflow and triggers | [GIT_WORKFLOW_AND_TRIGGERS.md](./GIT_WORKFLOW_AND_TRIGGERS.md) |
| Artifactory | [ARTIFACTORY_INTEGRATION.md](./ARTIFACTORY_INTEGRATION.md) |
| Terraform | See `../terraform/README.md` and `../terraform/environments/dev/` |
| Helm chart (generic app) | See `../helm-charts/paas-app/` |
| OPA Gatekeeper | See `../k8s-manifests/gatekeeper/constraint-signed-images.yaml` |
| Nginx Ingress Controller | See `../k8s-manifests/ingress/`, `../k8s-manifests/ingress/nginx-ingress-helm-values.example.yaml` |
| HAProxy | See `../k8s-manifests/haproxy/README.md` |
| Spring Boot / Angular / JFrog CLI | See `../jenkins/Jenkinsfile.full-stack` (Groovy pipeline) |
| AWS / Terraform / Containerd | See `../terraform/README.md`, `../terraform/modules/aws-eks/README.md` |
