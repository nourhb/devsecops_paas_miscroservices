# PaaS platform

```
paas/
├── scripts/          Lab operations (entry: lab.sh)
├── frontend/         Next.js UI and API
│   ├── src/app/      Routes and API handlers
│   ├── src/components/
│   ├── src/lib/      Client helpers
│   ├── src/server/   Backend services
│   ├── prisma/       Database schema
│   └── scripts/      Build and env helpers
├── jenkins/          Jenkinsfile.paas-deploy
├── gitops/           Helm chart bootstrap (simple-app)
└── k8s-manifests/    Postgres, RBAC, Kyverno policies
```

## Daily lab

```bash
bash paas/scripts/lab.sh start
bash paas/scripts/lab.sh health
bash paas/scripts/lab.sh env
bash paas/scripts/lab.sh jenkins
bash paas/scripts/lab.sh heal <project> <build> [port]
```

Local frontend: `bash paas/scripts/dev.sh`

## Scripts layout

You only run **`lab.sh`** (one entry point). Everything else is called automatically.

| You run | Purpose |
|---------|---------|
| `lab.sh start` | After VM reboot — Postgres, frontend, Harbor/Kyverno bootstrap |
| `lab.sh health` | Quick check frontend + Postgres |
| `lab.sh env` | Push `docker-compose.env` into the frontend pod |
| `lab.sh jenkins` | Sync Jenkinsfile to Jenkins + rebuild frontend image |
| `lab.sh frontend` | Rebuild frontend image only (UI code changes) |
| `lab.sh heal <p> <b> [port]` | Fix a project deploy (GitOps + Argo + rollout) |
| `lab.sh deploy <p> <b> [port]` | git pull + Kyverno + cosign + heal |
| `lab.sh ultimate <p> <b> [port]` | Full repair when lab is broken, then heal |
| `lab.sh repair <slug> [tag]` | Rebuild broken GitOps Helm chart for one app |
| `lab.sh fix-gitops` | Reset `~/gitops` to `origin/main` |
| `lab.sh bootstrap` | Harbor HTTP + cosign realm + Kyverno (no reboot) |
| `dev.sh` | Local Next.js on your laptop (not the cluster) |

Internal helpers (28 files) — do not run by hand unless debugging:

- **Recover chain:** `recover-paas-after-k3s-restart.sh`, `deploy-paas-postgres-lab.sh`, `wait-for-postgres-lab.sh`, `push-paas-schema-lab.sh`, `fix-paas-kyverno-workloads-lab.sh`
- **Harbor/Kyverno:** `platform-bootstrap-lab.sh`, `normalize-harbor-env-lab.sh`, `configure-k3s-harbor-http-lab.sh`, `recover-harbor-registry-lab.sh`, `fix-harbor-cosign-realm-lab.sh`, `apply-kyverno-cosign-lab.sh`, `ensure-harbor-nipio-cosign-lab.sh`
- **GitOps:** `gitops-lab-lib.sh`, `push-gitops-lab.sh`, `repair-gitops-app-lab.sh`, `fix-gitops-repo-lab.sh`, `heal-project-deploy-lab.sh`, `ultimate-project-deploy-lab.sh`
- **Jenkins/UI:** `sync-jenkins-pipeline-from-repo.sh`, `resolve-jenkinsfile-lab.sh`, `create_jenkins_paas_deploy_job.py`, `verify-jenkins-paas-deploy-job-lab.sh`, `sync-paas-jenkinsfile-configmap-k8s.sh`, `rebuild-paas-frontend-lab.sh`, `sync-paas-frontend-env-k8s.sh`, `check-paas-lab-health.sh`

Removed as unused: `heal-paas-frontend-lab.sh` (same as `lab.sh start` + `lab.sh frontend`).

## One-time cluster setup

```bash
kubectl apply -f paas/k8s-manifests/lab/
kubectl apply -f paas/k8s-manifests/kyverno/
```

## Env

Edit `paas/frontend/.env`, then:

```bash
cd paas/frontend && npm run env:compose
bash paas/scripts/lab.sh env
```
