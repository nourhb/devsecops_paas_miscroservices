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

Then set `DATABASE_URL` in `frontend/docker-compose.env` (and in `frontend/.env` if you run Prisma from the host—see step 5) to:

`postgresql://USER:PASSWORD@MANAGER_IP_OR_HOSTNAME:5432/paas`

Append if you see Prisma/locale issues:  
`?options=-c%20lc_messages%3DC`  
(as in `docker-compose.yml`).

## 4. Environment file for the PaaS app

`paas/docker-compose.yml` loads **`frontend/docker-compose.env`** (not `frontend/.env`). If you see errors like `failed to read .../frontend/.env`, your tree is **out of date**; run `git pull` so Compose uses `docker-compose.env` instead.

Compose’s `env_file` parser accepts only **one line per variable**. Multi-line Cosign PEM blocks break it (`unexpected character "/" in variable name`).

**Option A — generate from your single `frontend/.env` (copy/paste friendly):**

```bash
cd ~/devsecops_paas_miscroservices/paas/frontend
node scripts/flatten-env-for-compose.mjs   # reads .env, writes docker-compose.env (no npm install required)
cd .. && docker compose up -d
```

**Option B — edit by hand:**

```bash
cd ~/devsecops_paas_miscroservices/paas
cp frontend/docker-compose.env.example frontend/docker-compose.env
nano frontend/docker-compose.env   # or vim
```

Optional — Prisma from the **host** or one-off Node container: keep a normal `frontend/.env` (copy from `frontend/.env.example`) with a `DATABASE_URL` that reaches Postgres from the host (e.g. `postgresql://postgres:root@127.0.0.1:5433/paas?options=...` — Compose maps the DB to host port **5433** so it does not clash with a local Postgres on **5432**). Inside the `frontend` service, `docker-compose.yml` still **overrides** `DATABASE_URL` to use the hostname `postgres`.

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

**Recommended on the VM:** keep inline sync on (same as Compose default) so the Next.js server pushes `Jenkinsfile.paas-deploy` over the Jenkins REST API before each trigger (no Python, no separate script):

```env
JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=true
```

Ensure `PAAS_MONOREPO_ROOT=/monorepo` (or your mount) and the repo is mounted read-only so the app can read `paas/jenkins/Jenkinsfile.paas-deploy`. Rebuild the frontend image after pulling code so this logic is included.

**If you turn sync off** (`JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false`), update the Jenkins job manually after changing the shared Jenkinsfile (Jenkins UI → Pipeline script from `Jenkinsfile.paas-deploy`, or paste the file).

(Use the same Jenkins credentials as in `frontend/docker-compose.env`.)

**If you do not use Argo CD + GitOps on this install yet:**

```env
PAAS_STRICT_INTEGRATIONS=false
```

Otherwise set real `ARGOCD_*`, `GITOPS_*`, etc. The production Docker image runs with `NODE_ENV=production`; strict checks apply unless you relax them as above.

## 5. Database schema (Prisma)

Apply the schema **once** before or right after the first app start, using a `DATABASE_URL` that works **from where you run Prisma** (host → `127.0.0.1` / manager IP; not the in-compose hostname `postgres` unless you run Prisma inside the Compose network).

**Option A — On the VM with Node** (if installed):

```bash
cd ~/devsecops_paas_miscroservices/paas/frontend
# Requires frontend/.env with host-reachable DATABASE_URL (e.g. 127.0.0.1:5433 when using bundled Compose Postgres)
export $(grep -v '^#' .env | xargs -d '\n' -I {} echo {} | sed 's/^/export /')  # or: export DATABASE_URL=... manually
npm ci
npx prisma generate
npx prisma db push
```

**Option B — One-off Node container** (no local Node). Use a small `frontend/.env` (or `--env-file`) whose `DATABASE_URL` uses **`127.0.0.1`** (or `--network host` and the same URL), not the Compose hostname `postgres`:

```bash
cd ~/devsecops_paas_miscroservices/paas/frontend
docker run --rm -it \
  -v "$PWD:/app" -w /app \
  --network host \
  --env-file .env \
  node:20-bookworm-slim \
  bash -lc "npm ci && npx prisma generate && npx prisma db push"
```

## 6. Build and run with Docker Compose

Compose build context is **`paas/`** (not `frontend/`). A one-shot service **`db-push`** runs **`prisma db push`** after Postgres is healthy and before **`frontend`** starts, so tables such as **`User`** exist (you can skip manual step 5 when using bundled Postgres).

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

**Jenkins build triggers from the UI:** `docker-compose.yml` mounts the **monorepo** at `/monorepo`, sets **`PAAS_MONOREPO_ROOT`**, enables **`JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER`**, and forces **`JENKINS_BUILD_JOB_NAME=paas-deploy`** so the app syncs the inline job over REST before triggers. Rebuild the **`frontend`** image after pulling so that logic is included. Set **`JENKINS_BASE_URL` / `JENKINS_URL`** to the **same** URL as **Manage Jenkins → System → Jenkins URL** (e.g. `http://VM_IP:30090`). Using the Docker bridge gateway (e.g. `172.18.0.1`) when Jenkins thinks its URL is the VM IP often yields **HTTP 403** from inside the container because the **`Host`** header does not match.

**If `docker compose build` fails on Alpine** with `DNS: transient error` or `no such package` for `libc6-compat` / `openssl`, the CDN was not reached (VM DNS/firewall). Compose uses **`build.network: host`** on Linux so `apk` uses the host resolver; alternately set Docker daemon DNS (e.g. `"dns": ["8.8.8.8","1.1.1.1"]` in `/etc/docker/daemon.json`) and `sudo systemctl restart docker`, then rebuild.

**If you use Compose’s bundled Postgres**, keep the override in `docker-compose.yml` for `DATABASE_URL` inside the `frontend` service, or remove the `postgres` service and point everything at external Postgres only (then adjust `docker-compose.yml` accordingly).

### Compose-safe env (`frontend/docker-compose.env`)

Docker Compose’s `env_file` parser is **not** a full shell or dotenv implementation: each non-comment line must be `KEY=value`. **Multi-line PEM blocks** break parsing; a bare base64 line with `/` or `=` can trigger errors like `unexpected character "/" in variable name`.

**Fix (pick one):**

1. **Simplest:** leave **`COSIGN_PUBLIC_KEY`** / **`COSIGN_PRIVATE_KEY`** empty in `frontend/docker-compose.env` unless the app needs them in this container.
2. **Single-line PEM:** one line with escaped newlines, e.g. `COSIGN_PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\nMFkw...\n-----END PUBLIC KEY-----"` (quotes required). The app normalizes `\n` to real newlines at runtime (`pemFromEnv` in `env.ts`).
3. **Quote tokens** that contain `/`, `+`, or multiple `=` if Compose still complains: `TRIVY_AUTH_TOKEN="…"`.

On Linux VMs, set **`KUBE_CONFIG_PATH`** to a POSIX path (e.g. `/home/master/.kube/config`), not a Windows path.

## 7. Firewall / security

- Allow inbound **3000** (or whatever you map) to the VM.
- Do not commit `frontend/.env` or `frontend/docker-compose.env` with real secrets; back them up securely.
- For production, terminate TLS (reverse proxy, ingress, or Swarm ingress) in front of the app.

## 8. After it runs

- Register / log in (per your auth setup).
- In Jenkins, ensure job `paas-deploy` exists and matches `Jenkinsfile.paas-deploy` (use the Python script in step 4).
- Trigger a build from the UI; if parameters fail, compare env with `paas/jenkins/README.md`.

## Troubleshooting

| Symptom | Direction |
|--------|-----------|
| `build backend did not accept the build trigger` / Jenkins POST failed | Check **`docker-compose.env`** Jenkins URL and API token; rebuild **frontend** so sync can run (**python3** + **`..:/monorepo`** in compose). Compose sets **`JENKINS_BUILD_JOB_NAME=paas-deploy`** — that job must exist or sync must succeed. |
| Container exits immediately | `docker compose logs frontend` — often `prod env: ...` from `env.ts`; set missing vars or `PAAS_STRICT_INTEGRATIONS=false` / real GitOps+Argo. |
| Cannot reach Jenkins from container | Use IP/hostname reachable **from inside the container** (often host gateway or published manager IP, not only `localhost` if Jenkins is on another interface). |
| Prisma `relation "User" does not exist` (42P01) | Run `docker compose build && docker compose up -d` so **`db-push`** applies the schema, or manually `npx prisma db push` against this database. |
| Prisma errors / missing columns | Re-run `npx prisma db push` with correct `DATABASE_URL` or recreate with `docker compose up -d` after schema changes. |

## Relation to your home directory layout

If you already maintain `~/install-stack.sh` and Swarm/Kubernetes YAML next to this repo, treat the PaaS as **another workload**: same Docker host, env pointing at the stack’s published ports. You can later add a **Swarm stack** or **Kubernetes Deployment** that uses an image built from `paas/docker/frontend.Dockerfile` (build context **`paas/`**) and the same environment as `frontend/docker-compose.env` (or your orchestrator’s secret/config map).
