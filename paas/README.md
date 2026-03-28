# DevSecOps PaaS – Local Development

This project provides a DevSecOps PaaS control plane on top of your Kubernetes cluster.

It orchestrates:
- Jenkins (CI/CD pipelines)
- Harbor (container registry)
- ArgoCD (GitOps deployments)
- Trivy & SonarQube (security & quality)
- Cosign & OPA Gatekeeper (image signing & policy)
- Prometheus & Grafana (monitoring)

## Prerequisites

- Kubernetes cluster (kubeadm or similar)
- Node.js 20+
- A running instance of:
  - Jenkins (with API token)
  - Harbor
  - ArgoCD
  - Prometheus (for cluster metrics)
  - PostgreSQL (for the PaaS database)

## Required environment variables

Export the following before running the platform:

```bash
export DATABASE_URL="postgresql://user:pass@host:5432/paas"

export JENKINS_URL="https://jenkins.example.com"
export JENKINS_USER="jenkins-user"
export JENKINS_TOKEN="jenkins-api-token"

export HARBOR_URL="https://harbor.example.com"
export HARBOR_USERNAME="harbor-user"
export HARBOR_PASSWORD="harbor-password"

export ARGOCD_URL="https://argocd.example.com"
export ARGOCD_TOKEN="argocd-api-token"

export PROMETHEUS_URL="http://prometheus.kube-system.svc:9090"

export GITOPS_REPO_URL="git@github.com:ORG/gitops-repo.git"
export GITOPS_BRANCH="main"
```

Additional (optional) variables:

- `HARBOR_TEST_PROJECT` – Harbor project used for health checks (default: `library`)
- `ARGOCD_TEST_APP` – ArgoCD Application name used for health checks
- `KUBECONFIG` – path to kubeconfig when not running in-cluster

## One‑command dev bootstrap

From the `paas` directory:

```bash
cd paas
./scripts/dev.sh
```

The script will:

1. **Verify environment variables** – checks all required variables and exits with an error if any are missing.
2. **Install backend dependencies** – runs `npm install` in `backend-next`.
3. **Run backend Prisma migrations** – runs `npm run prisma:generate` and `npm run prisma:migrate`.
4. **Start backend** – runs `npm run dev` on port `4000`.
5. **Install frontend dependencies** – runs `npm install` in `frontend` and ensures `.env` exists.
6. **Start frontend** – runs `npm run dev` on port `3000`.
7. **Run health checks** – calls:
   - `/api/health`
   - `/api/jenkins/test`
   - `/api/harbor/test`
   - `/api/argocd/test`
   - `/api/kubernetes/test`
8. **Run integration tests** – executes `npm run verify-all` in `backend-next`.

If any health check or test fails, the script prints a clear error and stops both backend and frontend processes.

When everything is healthy you will see:

- Backend running at `http://localhost:4000`
- Frontend running at `http://localhost:3000`

Log in to the UI, create a project, and trigger pipelines to exercise the full DevSecOps flow.

# DevSecOps PaaS

This workspace contains a Next.js frontend and a Next.js-based backend scaffold (`paas/backend-next`) that implements the required REST APIs and JWT auth as a starting point.

Key folders:
- `paas/frontend` — Next.js (App Router) frontend (existing)
- `paas/backend-next` — Next.js API backend scaffold (this change)
- `helm-charts` — helm chart templates (existing)
- `k8s-manifests` — kubernetes manifests (existing)
- `terraform` — terraform skeleton for AWS (existing)

Local quickstart (requires Docker):

```bash
docker-compose up --build
```

Backend API endpoints (examples):
- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/project` (create)
- `GET /api/project` (list)
- `POST /api/build/{projectId}`
- `POST /api/deploy/{projectId}`
- `POST /api/rollback/{projectId}`
- `GET /api/security/{projectId}`
- `GET /api/metrics/{projectId}`

Next steps:
- Replace in-memory DB with persistent DB + Prisma
- Implement integration services (Jenkins/Harbor/ArgoCD/Sonar/Trivy/Cosign/OPA)
- Add Helm chart templates and k8s manifests for the backend
- Add CI/CD Jenkinsfile template and pipeline steps
