# PaaS Platform – Folder Structure

This document details the folder layout for the DevSecOps PaaS and where each type of configuration lives.

## Root layout

```
paas/
├── docs/                    # Architecture and design
├── frontend/                # PaaS control plane (Next.js App Router + Route Handlers API)
├── frontend/                # Optional standalone UI
├── gitops/                  # GitOps repo content (apps + base)
├── helm-charts/             # Reusable Helm charts
├── jenkins/                 # Pipeline definitions and shared libs
├── k8s-manifests/           # Kubernetes base manifests
├── terraform/               # Infrastructure as Code
├── monitoring/              # Prometheus/Grafana configs
├── scripts/                 # Automation scripts
└── test-app/                # Sample app for pipeline validation
```

## Directory purposes

| Path | Purpose |
|------|--------|
| `docs/` | Architecture docs, security integration, runbooks |
| `frontend/` | Next.js app & API: onboarding, pipelines, deployments, metrics, integrations |
| `gitops/` | GitOps repo: per-app Helm values and base manifests; ArgoCD points here |
| `gitops/apps/<app>/` | One folder per app: `Chart.yaml`, `values.yaml`, `templates/` |
| `helm-charts/` | Shared Helm chart templates (e.g. generic web app chart) |
| `jenkins/` | Main Jenkinsfile, shared library, job configs |
| `k8s-manifests/` | Ingress, Gatekeeper, cert-manager, namespaces |
| `terraform/` | Cloud and Kubernetes provisioning (modules + environments) |
| `monitoring/` | Prometheus rules, Grafana dashboards (JSON), alerting |
| `scripts/` | Bootstrap, post-deploy, certificate, or cleanup scripts |
| `test-app/` | Minimal app + Dockerfile + Jenkinsfile for E2E testing |

## File naming conventions

- **Terraform:** `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` per module/env
- **Helm:** `Chart.yaml`, `values.yaml`, `values-<env>.yaml`; templates in `templates/`
- **K8s:** `<resource-kind>-<name>.yaml` (e.g. `ingress-main.yaml`)
- **Jenkins:** `Jenkinsfile` or `Jenkinsfile.<pipeline-name>`

## Integration points

- **PaaS API** reads from: Git (via webhook), Jenkins (trigger/status), ArgoCD (sync/status), Harbor (tags), Prometheus/Grafana (metrics/links).
- **Jenkins** reads from: Git (source), Artifactory (artifacts), SonarQube/Dependency-Track (reports); writes to Harbor, GitOps repo, Artifactory.
- **ArgoCD** reads only from the GitOps repo and applies to the cluster.
