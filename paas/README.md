# PaaS

## Layout

| Folder | Purpose |
|--------|---------|
| `frontend/` | Next.js UI + API + Prisma |
| `jenkins/` | `Jenkinsfile.paas-deploy` (CI pipeline) |
| `gitops/` | Helm charts (`simple-app`, `test-app` template) |
| `k8s-manifests/lab/` | Lab cluster YAML (Postgres, frontend, Jenkins) |
| `k8s-manifests/` | Optional policies (Gatekeeper, Kyverno, Tekton examples) |
| `frontend/Dockerfile` | App image (compose + lab build) |
| `frontend/Dockerfile.db` | Prisma `db push` / seed on lab |
| `scripts/` | Lab ops — entry point: `scripts/lab.sh` |
| `terraform/` | Optional IaC examples (not required for demo) |

## Lab (VM `192.168.56.129`)

```bash
cd ~/devsecops_paas_miscroservices
bash paas/scripts/lab.sh start
bash paas/scripts/lab.sh health
```

- UI: http://192.168.56.129:30100/login
- After Jenkins build: `bash paas/scripts/lab.sh deploy <build_number>`

Details: `scripts/LAB.md`

## Local dev

```bash
cd paas
docker compose up -d
cd frontend && npm install && npm run dev
```

Env: copy `frontend/docker-compose.env.example` → `frontend/docker-compose.env`
