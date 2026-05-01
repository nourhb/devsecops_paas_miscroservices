# Jenkins pipeline for DevSecOps PaaS

The PaaS triggers this job with **`buildWithParameters`**: `GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID` (names must match your `.env` / defaults).

## Install / repair job (recommended — fixes `Error cloning remote repo 'origin'`)

If the Jenkins job uses **Pipeline script from SCM**, Jenkins clones that repo **before** any pipeline stage; clone failures surface as **origin** errors and PaaS parameters are never applied.

Run this from the repo root (uses credentials in **`paas/frontend/.env`**: `JENKINS_BASE_URL`, `JENKINS_USERNAME`, `JENKINS_API_TOKEN`):

```bash
python paas/scripts/jenkins_create_paas_deploy_job.py
```

That creates or updates the **`paas-deploy`** job with an **inline** pipeline loaded from **`paas/jenkins/Jenkinsfile.paas-deploy`** (no Git clone for the job definition). Optional: `--dry-run` writes `paas/jenkins/paas-deploy-job.generated.xml` only; `--job-name OTHER` if your `.env` uses a different job name.

## Docker on the agent (fix: `docker not found` in **Check**)

The pipeline runs **Sonar, OWASP Dependency-Check, cdxgen, and Kaniko** via `docker`. On **Kubernetes** agents (Helm Jenkins), steps run in the **jnlp** container by default; the **Docker CLI** is usually in a sidecar named **`docker`** (see `k8s-manifests/jenkins/jcasc-configmap.fetched.yaml`). This repo wraps docker-using stages in **`container('docker') { ... }`** so `docker` resolves correctly.

If your agent is a **single VM with Docker on PATH** (no Kubernetes `container()` support), remove those `container('docker')` wrappers or switch to a pod template that exposes Docker in the default container.

Use label **`jenkins-jenkins-agent`** so builds don’t land on the built-in controller. After editing `Jenkinsfile.paas-deploy`, run `python paas/scripts/jenkins_create_paas_deploy_job.py`.

## Agent type (fix: `Invalid agent type "kubernetes"`)

If Jenkins reports **only** `[any, label, none]` for agents, the **Kubernetes** plugin is not installed (or not available to Declarative Pipeline). This repo’s default **`Jenkinsfile`** uses **`agent any`** and runs Kaniko via **`docker run`** on the agent (Docker CLI + daemon required).

- **Option A (this file):** Install **Docker** on the Jenkins node, ensure the `jenkins` user can run `docker`, then use this `Jenkinsfile`.
- **Option B:** Install the **Kubernetes** Jenkins plugin and configure a Kubernetes cloud, then you can switch back to `agent { kubernetes { ... } }` and `container('kaniko')` (see git history or ask for `Jenkinsfile.kubernetes`).

## Manual setup (if you do not use the script)

1. New Item → **Pipeline** → name e.g. `paas-deploy`.
2. Definition: **Pipeline script** → paste the contents of **`paas/jenkins/Jenkinsfile.paas-deploy`** (declarative `parameters {}` are inside the script — do **not** use Pipeline from SCM unless that SCM clone works).
3. Avoid a separate job **Git** SCM block; application source is cloned only in the **Checkout** stage using **`params.GIT_URL`** from PaaS.

## Required Jenkins configuration

- **Kubernetes** agent plugin + pod template (as in the `Jenkinsfile` `agent { kubernetes { yaml ... } }`).
- **Harbor** (or your registry): set job or global environment variables:
  - `HARBOR_REGISTRY` (host:port, e.g. `192.168.56.129:30002`)
  - `HARBOR_USERNAME`
  - `HARBOR_PASSWORD`
- **Cluster DNS**: agent pods must resolve **Git** (`github.com` or your mirror) and reach **registry** and **gcr.io** (Kaniko image) if you pull from Google.

## PaaS `.env`

Set `JENKINS_DEPLOY_JOB_NAME=paas-deploy` (or your job name) and the same parameter names as in `env.ts` defaults (`GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID`).

## Image tag

Pushed image: **`${IMAGE_NAME}:${BUILD_NUMBER}`** — the PaaS promotion logic expects that tag pattern for Jenkins builds.

## Troubleshooting: `Error cloning remote repo 'origin'`

That message is Git’s default remote name. It can refer to **two different clones**:

1. **Loading the pipeline (most common if you never see `[checkout]` or `Check` in the log)**  
   The job is **Pipeline script from SCM**. Jenkins clones **that** repository first to read the `Jenkinsfile`. If this clone fails, the build ends before any stage in the file runs.  
   **Fix:** In the job configuration, under **Pipeline → Definition**, either:
   - Use **Pipeline script** and paste the contents of `paas/jenkins/Jenkinsfile` (no SCM clone for the definition), **or**
   - Keep **from SCM** but set **Repository URL** + **Credentials** so Jenkins can always reach the repo that **stores** the Jenkinsfile (can be this monorepo or a small “ci” repo).

2. **Cloning the app repo (`params.GIT_URL`)**  
   You should see `[checkout] branch=… creds=yes|no` from the **Checkout** stage. If `creds=no` and the app repo is **private**, configure **Git credentials (Jenkins)** on the PaaS project (Jenkins credential ID with GitHub PAT as password).

**`cleanWs`** in the log comes from the **Workspace Cleanup** plugin or job options, not from the `Jenkinsfile` in this repo. It is unrelated to the root cause; focus on the first Git error line in the full console (often 401 / not found / DNS).
