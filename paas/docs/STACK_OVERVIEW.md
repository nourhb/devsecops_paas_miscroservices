# Stack Overview

## Build and delivery

| Component | Role |
|-----------|------|
| PaaS API | receives project actions, plans builds, and orchestrates deployments |
| BuildPlanner | maps repositories to managed build profiles |
| Jenkins | compatibility backend for existing enterprise jobs |
| Tekton | Kubernetes-native build backend using `PipelineRun` resources |
| Harbor | artifact registry for produced images |
| GitOps repo | stores desired deployment state |
| Argo CD | synchronizes GitOps state into Kubernetes |

## Security and policy

| Component | Role |
|-----------|------|
| SonarQube | static analysis and quality gates |
| Dependency-Track | SBOM and dependency risk signals |
| Trivy | image and filesystem vulnerability scanning |
| Cosign | image signing |
| OPA Gatekeeper | runtime admission policy |

## Runtime and operations

| Component | Role |
|-----------|------|
| Kubernetes | runs workloads and build infrastructure |
| containerd | container runtime on cluster nodes |
| NGINX Ingress | traffic entry for applications |
| Prometheus | metrics collection |
| Grafana | dashboards and visualization |

## Platform flow

1. Git push or user action reaches the PaaS API.
2. `BuildPlanner` selects a profile and build mode.
3. The selected backend runs the build:
   - Jenkins for backward compatibility
   - Tekton for Kubernetes-native execution
4. Harbor stores the produced artifact.
5. The PaaS promotes the artifact through the GitOps repository.
6. Argo CD syncs the target state to Kubernetes.
7. Prometheus and Grafana expose runtime health.
