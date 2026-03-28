# paas/backend-next

Next.js-based backend (API-only) for the DevSecOps PAAS.

Features included in this scaffold:
- Typed Next.js API routes (TypeScript)
- JWT-based auth (register/login) using `jsonwebtoken`
- In-memory demo store for users and projects (replace with DB/prisma)
- Service stubs for Jenkins/Harbor/ArgoCD/Sonar/Prometheus
- Dockerfile and `.dockerignore`

Quick start (local):

```bash
cd paas/backend-next
npm install
npm run dev
```

Production build:

```bash
npm run build
npm run start
```

Environment variables (recommended):
- `JWT_SECRET` (min 32 chars)
- `JWT_EXPIRES_IN` (e.g. "2h")
- `JENKINS_URL`, `HARBOR_URL`, `ARGOCD_URL`, `SONAR_URL`, `PROMETHEUS_URL`

Replace the in-memory store in `src/lib/in-memory-db.ts` with a persistent datastore (Postgres + Prisma recommended) and implement integration logic in `src/lib/services/*`.
