# Environment variables and credentials (full stack)

Reference for configuring the pipeline and platform with all integrated technologies.

## Jenkins (pipeline)

| Variable / credential | Purpose |
|----------------------|--------|
| `HARBOR_URL`, `HARBOR_USER`, `HARBOR_PASS` (or credentials id `harbor`) | Push images to Harbor |
| `ARTIFACTORY_URL`, `ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN` | JFrog CLI / Artifactory publish |
| `SONAR_HOST_URL`, SonarQube token (credentials id `sonarqube`) | SonarQube analysis |
| `DEPENDENCY_TRACK_URL`, `DEPENDENCY_TRACK_API_KEY` | Dependency Track SBOM upload |
| `GITOPS_REPO_URL`, Git credentials | Update GitOps repo for Argo CD |
| `ARGOCD_SERVER`, `ARGOCD_TOKEN` | Argo CD sync |
| `COSIGN_PRIVATE_KEY` or file credential `cosign-key` | Cosign sign images |
| `APP_TYPE` | `springboot` \| `angular` \| `node` for Jenkinsfile.full-stack |

## Kubernetes / containerd

- **Runtime:** containerd (default on EKS 1.24+). No config needed for OCI images built with Docker.
- **Nginx Ingress Controller:** Install via Helm; TLS via cert-manager or cloud LB.
- **OPA Gatekeeper:** ConstraintTemplates + Constraints in `k8s-manifests/gatekeeper/`.

## AWS (Terraform)

| Variable / resource | Purpose |
|--------------------|--------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (or profile) | Terraform / EKS |
| Terraform backend (e.g. S3 + DynamoDB) | State storage |
| VPC, subnets, EKS cluster, node group | See `terraform/modules/aws-eks/` |

## Monitoring

| Component | Purpose |
|-----------|--------|
| **Prometheus** | Scrape metrics; often installed via Helm (kube-prometheus-stack). |
| **Grafana** | Datasource = Prometheus; dashboards; link from PaaS UI. |

## HAProxy

- Optional; configure to point to Nginx Ingress Controller LoadBalancer (e.g. AWS NLB hostname) or NodePort.
- No env vars in pipeline; infra-only (Terraform / EC2 user_data).
