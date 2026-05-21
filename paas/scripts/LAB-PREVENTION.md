# Lab prevention checklist

What broke in your session and how to avoid it next time.

## Root causes (short)

| Symptom | Cause | Prevention |
|--------|--------|------------|
| `Can't reach postgres.paas.svc.cluster.local` | No Postgres **in `paas`**, or wrong `DATABASE_URL` on the pod | Always deploy Postgres in `paas`; sync env to the deployment |
| `relation "User" does not exist` | New/empty Postgres, schema never applied | Run `push-paas-schema-lab.sh` after any new Postgres volume |
| `docker-compose.env` edited but UI unchanged | K8s pod uses **Secret/envFrom**, not the file on disk | Run `sync-paas-frontend-env-k8s.sh` after env changes |
| Cluster page **“Kubernetes API not configured”** | `KUBERNETES_ENABLED` not in frontend pod, or no RBAC | `bash paas/scripts/enable-paas-kubernetes-lab.sh` |
| **Jenkins sync ECONNREFUSED 192.168.56.129:30090** | PaaS runs in k8s; NodePort on VM IP not reachable from pod | `JENKINS_BASE_URL=http://jenkins-service.cicd.svc.cluster.local:8080` then sync env |
| simple-app `next start` / no `.next` | Jenkins **crane** image without `next build` | Use fixed Jenkinsfile; or `LOCAL_BUILD=1` for manual deploy |
| **`npx next build --no-lint` / unknown option** on Next 16 | Jenkins **inline job script** never updated (not Git creds — checkout already OK with `creds=no`). Common after **new/empty Jenkins** (k3s restart, emptyDir) + stale PaaS sync | **`bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh`** until verify OK → new build shows `crane-next16-202605`. Optional Git cred: `setup-jenkins-git-credential-lab.sh` (private repos only) |
| Harbor `502` / connection refused | Registry/nginx down or OOM on master | Check Harbor before push; avoid scaling everything up at once |
| `kubectl` TLS timeout | Master **RAM** saturated or API stuck (CoreDNS crash loop) | `bash paas/scripts/recover-k3s-api-lab.sh` |
| **Tekton PipelineRun creation failed** | `BUILD_BACKEND=tekton` but Tekton/RBAC not installed | `BUILD_BACKEND=jenkins` + `bash paas/scripts/fix-paas-build-trigger-lab.sh` |
| **Open in Jenkins → DNS_PROBE on `*.svc.cluster.local`** | UI link used in-cluster URL | Set `JENKINS_PROBE_URL=http://192.168.56.129:30090`; open Jenkins in browser at NodePort only |

## After **every** `systemctl restart k3s` (prevents login DB errors)

k3s restart stops/reorders pods. The UI then shows:

`Can't reach database server at postgres.paas.svc.cluster.local:5432`

**Always run on the master after k3s restart** (2–5 min):

```bash
cd ~/devsecops_paas_miscroservices
bash paas/scripts/recover-paas-after-k3s-restart.sh
```

Or full bootstrap if Postgres was never deployed:

```bash
bash paas/scripts/bootstrap-paas-lab.sh
```

**Before a demo or login**, quick check:

```bash
bash paas/scripts/check-paas-lab-health.sh
```

## After cluster restart or new Postgres volume

Same as above; full bootstrap:

```bash
cd ~/devsecops_paas_miscroservices
bash paas/scripts/bootstrap-paas-lab.sh
```

This runs: Postgres in `paas` → Prisma `db push` → sync `docker-compose.env` to `deployment/frontend`.

## After changing `paas/frontend/docker-compose.env`

```bash
bash paas/scripts/sync-paas-frontend-env-k8s.sh
kubectl rollout restart deployment/frontend -n paas
```

Or at minimum:

```bash
kubectl set env deployment/frontend -n paas \
  DATABASE_URL='postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC'
```

## Jenkins data (PVC vs emptyDir)

| Setup | File | Survives pod restart? |
|--------|------|------------------------|
| **Persistent (preferred)** | `k8s-manifests/lab/jenkins-cicd-pvc.yaml` | Yes — jobs, plugins, users in `jenkins-pvc` |
| **Emergency (RAM/disk-pressure)** | `k8s-manifests/lab/jenkins-cicd-emptydir.yaml` | **No** — empty UI after every rollout |

Earlier lab Jenkins used **`jenkins-pvc`** in namespace **`cicd`** (often on **worker2**). Recovery switched to **emptyDir on master** so Jenkins would start; that **does not restore** old jobs unless the PVC/PV still exists.

**Check if old data is recoverable** (on master):

```bash
bash paas/scripts/jenkins-restore-data-lab.sh
```

If `jenkins-pvc` still exists → `kubectl apply -f paas/k8s-manifests/lab/jenkins-cicd-pvc.yaml`.  
If PVC was deleted but a PV is **Released** → disk may remain under `/var/lib/rancher/k3s/storage/` (often on **worker2**); rebind or copy into a new PVC (advanced).  
If both gone → recreate `paas-deploy` with `create_jenkins_paas_deploy_job.py`, do not expect old build history.

**Do not** use `recover-k3s-memory-lab.sh` to delete `jenkins-pvc` if you want to keep Jenkins state.

## Jenkins / simple-app pipeline

1. Set **`JENKINS_PAAS_FAST_PIPELINE=false`** for Next.js repos (fast mode skips `next build` but crane does not run Dockerfile).
2. After SUCCESS build `NNN`, deploy with a **number** (not `NNN` placeholder):

   ```bash
   export GITHUB_TOKEN=ghp_...
   bash paas/scripts/final-deploy-simple-app-lab.sh NNN
   ```

3. If image has no `.next`, rebuild locally:

   ```bash
   LOCAL_BUILD=1 PUSH_TO_HARBOR=1 bash paas/scripts/fix-simple-app-imagepull-lab.sh NNN
   ```

4. GitOps push: use a valid PAT, not password login:

   ```bash
   export GITHUB_TOKEN=ghp_...
   bash paas/scripts/fix-gitops-simple-app-lab.sh NNN
   ```

## Files to keep correct on the VM

Copy from example once:

```bash
cp paas/frontend/docker-compose.env.k8s.example paas/frontend/docker-compose.env
# edit secrets (JWT, Jenkins, Harbor, SMTP, GITHUB_TOKEN)
```

Required for k8s:

- `DATABASE_URL=...@postgres.paas.svc.cluster.local:5432/paas...`
- `APP_BASE_URL=http://192.168.56.129:30100`
- `APPS_PUBLIC_LAB_NODE_IP=192.168.56.129`

## Do not use for production DB/schema

- `kubectl exec deploy/frontend -- npx prisma db push` — production image has no `prisma/schema.prisma`
- `npm` on the master host — Node 12 is too old; use Docker `paas-db-push` image
- `docker compose run db-push` without `-e DATABASE_URL` and `--network host` — hits compose service `postgres:5432`, not cluster DB

## `kubectl`: TLS handshake timeout

Host internet can work while the API is down. Do **not** rely on `fix-jenkins-dns-lab.sh` until `kubectl get nodes` succeeds.

```bash
bash paas/scripts/recover-k3s-api-lab.sh
```

This restarts k3s, waits for the API, restarts CoreDNS, patches Jenkins DNS, and runs `push-paas-schema-lab.sh`.

## Jenkins: `Could not resolve host: github.com`

The Jenkins pod cannot reach the internet (broken cluster DNS or no egress).

```bash
# On master
bash paas/scripts/fix-jenkins-dns-lab.sh
```

Also verify from host: `curl -I https://github.com`. If host fails, fix VM networking/DNS first, then `sudo systemctl restart k3s` and restart CoreDNS pods in `kube-system`.

## Quick health check

```bash
kubectl get pods -n paas | grep -E 'postgres|frontend'
kubectl exec -n paas deploy/postgres -- pg_isready -U postgres -d paas
kubectl exec -n paas deploy/frontend -- printenv DATABASE_URL
kubectl exec -n paas deploy/postgres -- psql -U postgres -d paas -c '\dt' | grep User
curl -sS -o /dev/null -w 'PaaS %{http_code}\n' http://192.168.56.129:30100/login
```

## Recovery scripts (reference)

| Script | When |
|--------|------|
| `check-paas-lab-health.sh` | Before login/demo — fails fast if DB/env broken |
| `recover-paas-after-k3s-restart.sh` | **After k3s restart** — Postgres + env (main prevention) |
| `bootstrap-paas-lab.sh` | First time / new Postgres volume / full reset |
| `deploy-paas-postgres-lab.sh` | DB only |
| `push-paas-schema-lab.sh` | Tables only |
| `sync-paas-frontend-env-k8s.sh` | Env file → pod (rejects wrong DATABASE_URL) |
| `recover-paas-lab.sh` | Frontend image + Jenkins hint |
| `final-deploy-simple-app-lab.sh` | App deploy after Jenkins build |
