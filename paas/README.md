# PaaS platform

```
paas/
├── frontend/         Next.js UI and API
├── jenkins/          Jenkinsfile.paas-deploy
├── gitops/           Helm chart bootstrap (simple-app)
├── k8s-manifests/
│   ├── hosted/       PaaS platform Deployment (production)
│   ├── lab/          Postgres, RBAC (cluster bootstrap)
│   └── kyverno/      Image signing policies
└── scripts/          Local VM lab only (not used in hosted production)
    ├── lab.sh        Operator entry point (lab VM only)
    ├── dev.sh        Local frontend dev
    └── lib/          Internal lab helpers (not run directly)
```

### Frontend layout (`paas/frontend/src/`)

```
src/
├── app/              Next.js routes and API handlers
│   ├── (auth)/       Login, register, password reset
│   ├── (dashboard)/  Projects, pipeline, deployments, security, monitoring
│   └── api/          REST API (projects, deploy, jenkins, k8s, webhooks)
├── components/       React UI (build, dashboard, pipeline, layout, ui)
├── hooks/            Client hooks (auth, routing)
├── lib/              Client API client, auth, shared labels
├── server/           Server-only domain logic
│   ├── auth/         Sessions, mail, guards
│   ├── build/        Build planner, Jenkins/Tekton backends, metadata
│   ├── deploy/       Images, Harbor, reachability
│   ├── gitops/       Chart bootstrap, GitHub commits
│   ├── help/         Pipeline help catalog and service
│   ├── jenkins/      Jenkinsfile sync, step verification
│   ├── projects/     Project CRUD, secrets, languages
│   ├── security/     Cosign, policy gate, JWT
│   └── services/     Deployments, Argo CD, dashboard, cluster deploy
└── types/            Shared TypeScript types
```

## Hosted production (no shell scripts)

Everything runs from the UI and CI/CD:

| What | How |
|------|-----|
| **Deploy user apps** | PaaS UI → Jenkins build → GitOps commit → Argo CD sync (automatic) |
| **Deploy PaaS UI** | Push to `main` → GitHub Actions builds image → rolls out to cluster |
| **Database schema** | CI runs `prisma db push` Job in-cluster before frontend rollout |
| **Config / secrets** | Kubernetes Secret `paas-frontend-env` (from your env file once) |

### One-time cluster bootstrap

**Existing lab VM** (you already have `deployment/frontend` + `frontend-service` on port 30100): skip `hosted/` — use `bash paas/scripts/lab.sh start` after reboot.

**New production cluster** (greenfield):

```bash
kubectl apply -f paas/k8s-manifests/lab/
kubectl apply -f paas/k8s-manifests/kyverno/
kubectl apply -f paas/k8s-manifests/hosted/
kubectl create secret generic paas-frontend-env \
  --from-env-file=paas/frontend/docker-compose.env \
  -n paas
```

Set `DATABASE_URL` in that secret to `postgresql://postgres:…@postgres.paas.svc.cluster.local:5432/paas`.

If `kubectl create secret` fails with duplicate keys, regenerate a deduped env file:

```bash
cd paas/frontend && npm run env:compose
kubectl create secret generic paas-frontend-env \
  --from-env-file=docker-compose.env -n paas --dry-run=client -o yaml | kubectl apply -f -
```

### GitHub Actions secrets

| Secret | Purpose |
|--------|---------|
| `PAAS_REGISTRY` | e.g. `harbor.example.com/paas` |
| `PAAS_REGISTRY_USER` | Registry username |
| `PAAS_REGISTRY_PASSWORD` | Registry password |
| `KUBE_CONFIG` | Base64-encoded kubeconfig for deploy |

Workflow: `.github/workflows/paas-hosting.yml` — runs on every push to `main` under `paas/`.

### Production env flags

In `paas-frontend-env` secret:

- `KUBERNETES_ENABLED=true`
- `PAAS_STRICT_INTEGRATIONS=true`
- `JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=true` (syncs Jenkinsfile from embedded copy — no manual script)
- `GITOPS_REPO_URL`, `GITOPS_REPO_TOKEN`, `ARGOCD_*`, `HARBOR_*`, `JENKINS_*`

User project deploys need no SSH and no `lab.sh` — promotion is handled by `cluster-deploy-service` and `jenkins-deployment-reconcile`.

## Local development

```bash
cd paas/frontend && npm install && npm run dev
```

Or `bash paas/scripts/dev.sh` on a dev machine.

## Local VM lab (optional)

`paas/scripts/lab.sh` is the **only** operator entry point for the VirtualBox k3s lab. Everything under `paas/scripts/lib/` is internal plumbing. Not required for hosted production.

| Command | Purpose |
|---------|---------|
| `lab.sh start` | Recover after VM reboot (postgres, env, frontend, harbor, kyverno) |
| `lab.sh env` | Sync `docker-compose.env` → `paas-frontend-env` secret |
| `lab.sh jenkins` | Push Jenkinsfile to Jenkins + rebuild frontend |
| `lab.sh frontend` | Rebuild and roll out frontend image only |
| `lab.sh health` | Quick API / postgres / UI check |
| `lab.sh harbor` | Recover Harbor registry (502 / crane push failures) |
| `lab.sh bootstrap` | Harbor mirrors + Kyverno cosign + require-non-root |
| `lab.sh heal <p> <b>` | Manual GitOps fix (hosted: use UI deploy instead) |

## Env file

Edit `paas/frontend/.env`, then:

```bash
cd paas/frontend && npm run env:compose
kubectl create secret generic paas-frontend-env \
  --from-env-file=docker-compose.env -n paas --dry-run=client -o yaml | kubectl apply -f -
```
