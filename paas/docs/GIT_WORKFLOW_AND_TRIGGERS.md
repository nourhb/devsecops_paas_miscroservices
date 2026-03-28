# Git Workflow and Pipeline Triggers

## Git workflow (branch strategy)

- **main** (or **master**): Production-ready code; pipeline builds, scans, deploys to production (or staging) via GitOps.
- **develop** (optional): Integration branch; pipeline builds and deploys to dev namespace only.
- **feature/*** : Feature branches; pipeline runs build + test + SAST/SCA only; no deploy.

## Pipeline trigger explanation

1. **Developer** pushes to Git (GitLab or GitHub).
2. **Webhook** from Git targets the **PaaS control plane** (e.g. `POST /api/webhooks/git`) with payload (repo, branch, commit).
3. **PaaS API** identifies the project linked to that repo/branch, then calls **Jenkins API** to start the corresponding pipeline job (e.g. `POST /job/<job-name>/buildWithParameters` with `BRANCH=main`).
4. **Jenkins** runs the pipeline (checkout that branch, build, scan, push, update GitOps, etc.); no direct Jenkins access for the developer.
5. **Optional:** Jenkins can also use SCM polling instead of webhooks; PaaS still triggers “deploy” or “release” actions via API.

## GitLab webhook example

- URL: `https://paas.example.com/api/webhooks/gitlab`
- Events: Push events, Merge request events (optional)
- Secret: Shared secret for payload verification

## GitHub webhook example

- URL: `https://paas.example.com/api/webhooks/github`
- Content type: `application/json`
- Events: Push, Pull request (optional)
- Secret: Webhook secret for HMAC verification

## Black box behavior

- Developer sees: “Build started”, “Build passed/failed”, “Deployed to dev/prod”.
- Developer does **not** see: Jenkins UI, Jenkinsfile details, or infrastructure. All interaction is via PaaS UI and Git push.
