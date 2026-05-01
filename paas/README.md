# DevSecOps PaaS

This workspace contains a Next.js control plane that manages application onboarding, build orchestration, GitOps promotion, deployment status, security signals, and monitoring for a Kubernetes-based platform.

## Platform Direction

The platform now supports a provider-neutral build model:

- `BUILD_BACKEND=jenkins` keeps the existing Jenkins integration for backward compatibility.
- `BUILD_BACKEND=tekton` uses Kubernetes-native `PipelineRun` resources and platform-managed templates.
- Project state and deployment history are exposed in neutral terms: build provider, run ID, artifact image, and artifact digest.

The target production flow is:

`Git/Webhook -> PaaS API -> BuildPlanner -> Jenkins or Tekton -> Harbor artifact -> GitOps commit -> Argo CD sync -> Kubernetes`

## Main Components

- `paas/frontend` - Next.js app router UI and API.
- `paas/k8s-manifests/tekton` - starter Tekton tasks, pipelines, and secret examples.
- `paas/k8s-manifests` - platform Kubernetes manifests.
- `paas/docs` - architecture, workflow, and integration documents.

## Quickstart

1. Copy `paas/.env.example` or `paas/frontend/.env.example` to `.env`.
2. Set at minimum `DATABASE_URL` and `JWT_SECRET`.
3. For local demo mode, enable `DEVSECOPS_ALLOW_SIMULATION=true`.
4. For Jenkins mode, configure `JENKINS_*`.
5. For Tekton mode, set `BUILD_BACKEND=tekton`, `KUBERNETES_ENABLED=true`, and the `TEKTON_*` values.
6. Start the frontend from `paas/frontend`:

```bash
npm install
npm run prisma:generate
npm run dev
```

## Key Environment Variables

```bash
DATABASE_URL=postgresql://postgres:root@localhost:5432/paas
JWT_SECRET=change-this-to-a-strong-secret-at-least-32-chars-long

BUILD_BACKEND=tekton
BUILD_TEMPLATE_VERSION=v1
BUILD_REGISTRY_MIRROR=mirror.gcr.io
BUILD_ENFORCE_ARTIFACT_DIGEST=false

KUBERNETES_ENABLED=true
KUBE_CONFIG_PATH=
TEKTON_NAMESPACE=tekton-pipelines
TEKTON_SERVICE_ACCOUNT=paas-build-bot
TEKTON_NODE_PIPELINE_NAME=paas-node-build

HARBOR_BASE_URL=https://harbor.example.com
HARBOR_USERNAME=harbor-user
HARBOR_PASSWORD=harbor-password

ARGOCD_BASE_URL=https://argocd.example.com
ARGOCD_AUTH_TOKEN=argocd-token

GITOPS_REPO_URL=https://github.com/org/gitops-repo
GITOPS_REPO_TOKEN=github-token
```

Switch back to Jenkins by setting:

```bash
BUILD_BACKEND=jenkins
JENKINS_BASE_URL=https://jenkins.example.com
JENKINS_USERNAME=jenkins-user
JENKINS_API_TOKEN=jenkins-api-token
```

## Current Build/Deploy Behavior

- Project creation detects a build profile and chooses either a platform template or a custom Dockerfile contract.
- Build triggers return provider-neutral metadata and keep compatibility with current endpoints.
- Deployment monitoring records run metadata and artifact details in the deployment log stream.
- Promotion is artifact-driven: GitOps receives the produced image reference, and digest-aware promotion is supported.

## Verification

From `paas/frontend`:

```bash
npm run typecheck
npm test
```

See `paas/TESTING.md` for platform validation and `paas/docs/DEVSOPS_PAAS_ARCHITECTURE.md` for the enterprise target architecture.
