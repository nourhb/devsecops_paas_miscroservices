# DevSecOps PaaS
Control plane for building and deploying applications through a DevSecOps pipeline. The product includes a web UI: a Next.js app in `paas/frontend` that signs users in, manages projects, and drives build, security, GitOps, and cluster deployment.
## UI
The interface is **DevSecOps PaaS / Control Plane** (`paas-frontend`).
| Area | Route |
|------|--------|
| Sign in, register, password reset, email verification | `/login`, `/register`, `/forgot-password`, `/reset-password`, `/verify-email` |
| Dashboard | `/dashboard` |
| Platform hub | `/integrations` |
| Cluster status and namespaces | `/cluster`, `/cluster/namespaces` |
| Artifacts | `/artifacts` |
| Projects | `/projects`, `/projects/create` |
| Pipeline, Docker, deployments, security, monitoring | per-project pages under `/pipeline`, `/docker`, `/deployments`, `/security`, `/monitoring` |
| Account | `/account` |
Stack: Next.js 14, React 18, Tailwind CSS, Prisma, PostgreSQL.
## Repository layout
```
paas/
├── frontend/         Next.js UI and API
├── jenkins/          Jenkins pipeline for user-app deploys
├── gitops/           Helm chart bootstrap
├── k8s-manifests/    Hosted, lab, and Kyverno manifests
└── scripts/          Local VM lab helpers
```
Operational detail (cluster bootstrap, GitHub Actions secrets, and lab commands) is in [`paas/README.md`](paas/README.md).
## Local development
From `paas/frontend`, with `DATABASE_URL` and the rest of the app env in `paas/frontend/.env`:
```bash
cd paas/frontend
npm install
npm run dev
```
Other frontend scripts: `npm run build`, `npm run lint`, `npm run typecheck`, `npm run prisma:studio`, `npm run auth:seed-admin`.
## How a user app is deployed
The UI starts a Jenkins build. The pipeline publishes the image and commits GitOps changes. Argo CD syncs the result onto the cluster. Hosted production does not use the lab shell scripts. Pushing this repository’s `main` branch under `paas/` builds and rolls out the PaaS UI itself (`.github/workflows/paas-hosting.yml`).







<img width="1912" height="882" alt="image" src="https://github.com/user-attachments/assets/a25dcf7b-52cc-4ff4-ac2d-55637a81f5dc" />

[Nour el houda bouajila-pfe.pdf](https://github.com/user-attachments/files/32877275/Nour.el.houda.bouajila-pfe.pdf)

