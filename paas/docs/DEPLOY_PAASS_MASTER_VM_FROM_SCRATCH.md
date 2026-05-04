# Deploy the PaaS control plane on a Linux master VM (from scratch)

Your VM may already run Docker / Swarm and tools (`install-stack.sh`, `~/.kube`, etc.). This guide assumes **the PaaS source is not on the VM yet** and you want the **Next.js app** + **API** reachable from the cluster/network.

## 1. Prerequisites on the VM

- **Docker Engine** and **Docker Compose v2** (`docker compose version`).
- **Git** (to clone the repo).
- Network: from the VM, you can reach **PostgreSQL**, **Jenkins**, **Argo CD**, and any registry you configure (often `localhost` or the manager IP if services publish ports on the host).

Optional: **Node.js 20+** only if you prefer running Prisma from the host instead of a one-off container (see step 5).

## 2. Put the monorepo on the VM

From `master@master` (or any directory you use for code):

```bash
cd ~
git clone <YOUR_GIT_URL> devsecops_paas_miscroservices
cd devsecops_paas_miscroservices/paas
```

If the repo is private, use SSH keys (`~/.ssh`) or a personal access token with HTTPS.

## 3. PostgreSQL

Pick **one**:

**A — Dedicated Postgres via Compose (simple)**  
The file `paas/docker-compose.yml` already defines `postgres` + `frontend`. You can use it as-is: the app will use the internal service name `postgres` for `DATABASE_URL` inside Compose.

**B — Existing Postgres on the VM / Swarm**  
Create a database and user, for example:

```bash
# Example: if psql is available on the host or in a postgres container
psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE paas;"
```

Then set `DATABASE_URL` in `frontend/.env` to:

`postgresql://USER:PASSWORD@MANAGER_IP_OR_HOSTNAME:5432/paas`

Append if you see Prisma/locale issues:  
`?options=-c%20lc_messages%3DC`  
(as in `docker-compose.yml`).

## 4. Environment file for the PaaS app

```bash
cd ~/devsecops_paas_miscroservices/paas
cp frontend/.env.example frontend/.env
nano frontend/.env   # or vim
```

Set at minimum:

| Variable | Example / note |
|----------|----------------|
| `DATABASE_URL` | Your Postgres URL (see step 3). |
| `JWT_SECRET` | At least 32 random characters. |
| `APP_BASE_URL` | URL users use for the portal, e.g. `http://MANAGER_IP:3000`. |
| `JENKINS_URL` / `JENKINS_BASE_URL` | e.g. `http://MANAGER_IP:30090` if Jenkins publishes `30090`. |
| `JENKINS_USERNAME`, `JENKINS_API_TOKEN` | Jenkins API token for that user. |
| `JENKINS_BUILD_JOB_NAME`, `JENKINS_DEPLOY_JOB_NAME` | e.g. `paas-deploy`. |

Align other URLs with **published ports** on your stack (Sonar, Prometheus, Harbor, Argo CD, Nexus, …). A port map template is in `paas/jenkins/swarm-stack.env.example`.

**Recommended on the VM (no Python in the app container):**

```env
JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false
```

Run the sync script **once** from the repo when you change the Jenkinsfile/job definition:

```bash
cd ~/devsecops_paas_miscroservices
python3 paas/scripts/jenkins_create_paas_deploy_job.py
```

(Use the same Jenkins credentials as in `frontend/.env`.)

**If you do not use Argo CD + GitOps on this install yet:**

```env
PAAS_STRICT_INTEGRATIONS=false
```

Otherwise set real `ARGOCD_*`, `GITOPS_*`, etc. The production Docker image runs with `NODE_ENV=production`; strict checks apply unless you relax them as above.

## 5. Database schema (Prisma)

Apply the schema **once** before or right after the first app start, using the **same** `DATABASE_URL` as in `frontend/.env`.

**Option A — On the VM with Node** (if installed):

```bash
cd ~/devsecops_paas_miscroservices/paas/frontend
export $(grep -v '^#' .env | xargs -d '\n' -I {} echo {} | sed 's/^/export /')  # or set DATABASE_URL manually
npm ci
npx prisma generate
npx prisma db push
```

**Option B — One-off Node container** (no local Node):

```bash
cd ~/devsecops_paas_miscroservices/paas/frontend
docker run --rm -it \
  -v "$PWD:/app" -w /app \
  --env-file .env \
  node:20-bookworm-slim \
  bash -lc "npm ci && npx prisma generate && npx prisma db push"
```

## 6. Build and run with Docker Compose

Compose build context is **`paas/`** (not `frontend/`):

```bash
cd ~/devsecops_paas_miscroservices/paas
docker compose build
docker compose up -d
```

Default published port: **3000** → open `http://MANAGER_IP:3000`.

Logs:

```bash
docker compose logs -f frontend
```

**If you use Compose’s bundled Postgres**, keep the override in `docker-compose.yml` for `DATABASE_URL` inside the `frontend` service, or remove the `postgres` service and point everything at external Postgres only (then adjust `docker-compose.yml` accordingly).

## 7. Firewall / security

- Allow inbound **3000** (or whatever you map) to the VM.
- Do not commit `frontend/.env` with real secrets; back it up securely.
- For production, terminate TLS (reverse proxy, ingress, or Swarm ingress) in front of the app.

## 8. After it runs

- Register / log in (per your auth setup).
- In Jenkins, ensure job `paas-deploy` exists and matches `Jenkinsfile.paas-deploy` (use the Python script in step 4).
- Trigger a build from the UI; if parameters fail, compare env with `paas/jenkins/README.md`.

## Troubleshooting

| Symptom | Direction |
|--------|-----------|
| Container exits immediately | `docker compose logs frontend` — often `prod env: ...` from `env.ts`; set missing vars or `PAAS_STRICT_INTEGRATIONS=false` / real GitOps+Argo. |
| Cannot reach Jenkins from container | Use IP/hostname reachable **from inside the container** (often host gateway or published manager IP, not only `localhost` if Jenkins is on another interface). |
| Prisma errors / missing columns | Re-run `npx prisma db push` with correct `DATABASE_URL`. |

## Relation to your home directory layout

If you already maintain `~/install-stack.sh` and Swarm/Kubernetes YAML next to this repo, treat the PaaS as **another workload**: same Docker host, env pointing at the stack’s published ports. You can later add a **Swarm stack** or **Kubernetes Deployment** that uses an image built from `paas/docker/frontend.Dockerfile` (build context **`paas/`**) and the same environment as `frontend/.env`.
