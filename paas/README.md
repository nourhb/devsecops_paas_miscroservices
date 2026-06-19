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
| `lab.sh frontend-stop` | Scale frontend to 0 + pause (stop an active pod storm) |
| `lab.sh frontend-force` | RS cleanup + pin recovery image on master |
| `lab.sh frontend-safety` | Recreate strategy + master pin (storm prevention) |
| `lab.sh harden` | **Run once** — frontend safety, db-repair, install auto-heal cron |
| `lab.sh watchdog` | Auto-heal disk / Kyverno / postgres / pod storms (cron every 10 min) |
| `lab.sh guard` | Full check: images, Prometheus, stale pods, health (cron every 6 h) |
| `lab.sh emergency` | Kyverno unblock + disk + postgres + frontend heal |
| `lab.sh disk-emergency` | Free disk safely (no `docker prune -af`) |
| `lab.sh harbor` | Recover Harbor registry (502 / crane push failures) |
| `lab.sh bootstrap` | Harbor mirrors + Kyverno cosign + require-non-root |
| `lab.sh heal <p> <b>` | Manual GitOps fix (hosted: use UI deploy instead) |

### Outage prevention (lab VM)

Run **once** after any recovery or fresh clone:

```bash
cd ~/devsecops_paas_miscroservices
git pull
bash paas/scripts/lab.sh harden
```

This installs:

- **Frontend safety** — `Recreate` (not `RollingUpdate`), pin on **master**, `imagePullPolicy: Never` for local `paas-frontend:*` images, `revisionHistoryLimit: 0`
- **Watchdog cron** (every 10 min) — stops frontend pod storms (>3 pods), disk pressure cleanup, Kyverno webhook guard, auto `db-repair` when Postgres is unreachable
- **Guard cron** (every 6 h) — safe image prune, Prometheus recover, full health check

**Why the pod storm happened:** watchdog/guard used to *remove* the master `nodeSelector` and switch `Never` → `IfNotPresent`, so Kubernetes scheduled frontend on worker1 where the image does not exist. `RollingUpdate` + repeated failures created hundreds of pods.

**If frontend pods are exploding on worker1:**

```bash
bash paas/scripts/lab.sh frontend-stop    # scale to 0, pause, delete RS/pods
bash paas/scripts/lab.sh frontend-force   # single pod on master with recovery image
bash paas/scripts/lab.sh harden           # after git pull — installs safety + cron
```

**Do not** run `FORCE_FRONTEND_REBUILD=true bash paas/scripts/lab.sh frontend` during a storm — wait until only 0–1 frontend pods exist.

**Never run on a full disk:**

| Command | Why |
|---------|-----|
| `docker system prune -af` | Deletes images tags deployments still reference |
| `monitoring-disk` (full) when disk ≥88% | Can pull images and make disk worse — use `disk-emergency` or `monitoring-disk quick` |
| `crictl rmi --prune` without `lab-safe-image-prune` | May remove `paas-frontend` from containerd |
| `PAAS_UNPIN_FRONTEND=1` or manual `nodeSelector: null` on frontend | Schedules UI on worker nodes without the local image → storm |

**If UI shows "Database is still starting":**

```bash
bash paas/scripts/lab.sh db-repair
bash paas/scripts/lab.sh health
```

Logs: `/var/log/paas-lab-watchdog.log`, `/var/log/paas-lab-guard.log`

## Env file

Edit `paas/frontend/.env`, then:

```bash
cd paas/frontend && npm run env:compose
kubectl create secret generic paas-frontend-env \
  --from-env-file=docker-compose.env -n paas --dry-run=client -o yaml | kubectl apply -f -
```
