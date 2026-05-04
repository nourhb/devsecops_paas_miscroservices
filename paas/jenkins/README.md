# Jenkins pipeline for DevSecOps PaaS

The PaaS triggers this job with **`buildWithParameters`**: `GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID` (names must match your `.env` / defaults).

## Étapes du pipeline (résumé)

### §1 — Déclenchement depuis l’IHM (hors stages Jenkins)

Le PaaS **automatise** le déclenchement des builds : l’équipe peut lancer une construction depuis l’**interface** du portail (paramètres du projet / image / branche) ou via des flux liés au **dépôt**. Le backend envoie une requête **`buildWithParameters`** à l’**API Jenkins** avec `GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID`. Le job (**Pipeline script inline**, `Jenkinsfile.paas-deploy`) valide ces paramètres puis exécute le **checkout**.

### Ordre des stages dans `Jenkinsfile.paas-deploy`

- **§5 Construction** s’exécute **avant** **§3 SCA** et **§4 SAST** (dépendances et artefacts pour les analyses) — Blue Ocean peut afficher « 5 » avant « 3 » et « 4 ».
- Après **§6 Image Docker**, la suite suit le **mémoire** : **§7** Helm → **§8** Artifactory → **§9** Harbor → **§10** Cosign → **§11** charts Helm OCI → **§12** / **§13** Argo (documentaires, délégués PaaS) → **archivage** Jenkins.
- **Sans Docker**, **crane** au §6 peut **déjà pousser** l’image : le **§9** est un **no-op** ; Cosign reste possible. **Kaniko** (autre `Jenkinsfile`) peut fusionner build + push.

1. **Validation des paramètres** — `GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID` (§1 / PaaS).
2. **§2 — Checkout du code** — clone depuis **`GIT_URL`** / **`BRANCH`** ; **`GIT_CREDENTIALS_ID`** si dépôt privé ; `deleteDir()` puis `git`.
3. **§5 — Construction de l'application** — Maven / npm / Python / statique ; **`paas-artifacts/build-artifact-manifest.txt`** (*stage Jenkins « 5 », avant 3 et 4*).
4. **§3 — SCA** — OWASP Dependency-Check (NVD) → JSON ; **CycloneDX** `sca/bom.json` ; **Dependency-Track** si configuré.
5. **§4 — SAST** — **SonarQube** (non bloquant si absent).
6. **§6 — Création de l’image Docker** — `docker build` ou **crane** + push registry ; **`PAAS_ARTIFACT_IMAGE`**.
7. **§7 — Packaging du chart Helm** — `helm package` si `Chart.yaml` ; **`paas-artifacts/release-metadata.txt`** et **`paas-artifacts/helm/*.tgz`**.
8. **§8 — Publication dans Artifactory** — bundle `paas-artifacts` + `sca` (optionnel, non bloquant).
9. **§9 — Publication de l’image Docker (Harbor)** — `docker push` ; **no-op** si image déjà poussée (**crane** §6).
10. **§10 — Signature Cosign** — signature dans le registre (optionnel).
11. **§11 — Publication des charts Helm (Harbor)** — `helm push` OCI (optionnel).
12. **§12 — Déploiement avec Argo CD** — orchestration GitOps ; **délégué** au PaaS (stage documentaire).
13. **§13 — Récupération et synchronisation du chart Helm** — pull OCI Harbor côté Argo ; **délégué** au cluster (stage documentaire).
14. **Archivage Jenkins** — `sca/**`, `paas-artifacts/**`.

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
- **Helm OCI (charts in Harbor)** : même registre et identifiants ; projet cible `HELM_OCI_PROJECT` (défaut `paas`, paramètre du job **ou** variable d’agent). TLS atypique : `HELM_OCI_INSECURE=true` ; HTTP uniquement : `HELM_OCI_PLAIN_HTTP=true`. Nécessite **`helm` ≥ 3.8** sur l’agent.
- **Argo CD** : pas de credentials Argo dans ce Jenkinsfile — le **PaaS** (`ARGOCD_BASE_URL` / `ARGOCD_AUTH_TOKEN`, etc. dans **`paas/.env`**) déclenche sync / suit les Applications après le build. Pour **§13**, le **pull Helm OCI** depuis Harbor se configure sur le cluster (**`Repository` / secret** Argo CD pointant vers le même `HARBOR_REGISTRY` que la §11).
- **Cluster DNS**: agent pods must resolve **Git** (`github.com` or your mirror) and reach **registry** and **gcr.io** (Kaniko image) if you pull from Google.

## PaaS `.env`

Set `JENKINS_DEPLOY_JOB_NAME=paas-deploy` (or your job name) and the same parameter names as in `env.ts` defaults (`GIT_URL`, `BRANCH`, `IMAGE_NAME`, `PROJECT_ID`).

### Docker Swarm service ports (`my-stack`)

If Jenkins, Argo CD, SonarQube, Prometheus, Grafana, Nexus, Trivy, ZAP, etc. run as Swarm services with **published ports** on the manager, mirror those hostnames and ports in **`paas/frontend/.env`** (and root **`paas/.env`** if you use it). The Next server forwards integration settings to **`buildWithParameters`** (see **`appendRegistryParameters`** in `paas/frontend/src/server/integrations/devsecops-clients.ts`): e.g. **`SONAR_*`**, **`DEPENDENCY_TRACK_*`**, **`DOCKERHUB_*`**, **`HARBOR_*`**, **`ARTIFACTORY_*`**, **`HELM_OCI_*`**, **`NVD_API_KEY`**, credential IDs for Jenkins, etc.

**`JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER`** defaults to **`false`** in the app so dev triggers do not require Python; set **`true`** in **`paas/frontend/.env`** to run **`jenkins_create_paas_deploy_job.py`** before each trigger.

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
