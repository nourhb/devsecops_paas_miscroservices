

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


Postgres data is stored on a **persistent volume** (`postgres-pvc`). You should **not** re-seed or recreate projects after every reboot.

```bash
cd ~/devsecops_paas_miscroservices
bash paas/scripts/lab.sh start
bash paas/scripts/lab.sh health
```

Auto-recover after VM reboot (once):

```bash
sudo bash paas/scripts/install-paas-autostart-lab.sh
```

- UI: http://192.168.56.129:30100/login
- After Jenkins build: `bash paas/scripts/lab.sh deploy <build_number>`

### Blue-green deployments

Set in `frontend/docker-compose.env` (then restart the PaaS frontend):

```env
PAAS_DEPLOYMENT_STRATEGY=BlueGreen
```

On each successful Jenkins build, PaaS will:

1. Update the **inactive** slot (`blue` / `green`) in GitOps `values.yaml`
2. Wait for Argo CD + that Deployment to become ready
3. Flip `activeSlot` so the Service sends traffic to the new version

Helm chart: two Deployments (`…-blue`, `…-green`) and one Service selector on `activeSlot`. Per-project override: `deploymentStrategy: BlueGreen` in `apps/<project>/values.yaml`.

Manual lab script (without UI): `bash paas/scripts/promote-paas-blue-green-lab.sh <project> <buildNumber>`

Details: `scripts/LAB.md`


```bash
cd paas
docker compose up -d
cd frontend && npm install && npm run dev
```

Env: copy `frontend/docker-compose.env.example` → `frontend/docker-compose.env`

### Securing environment files

| Rule | Why |
|------|-----|
| Never commit `docker-compose.env`, `.env`, or `paas/.env` | They hold JWT, GitHub, Jenkins, Sonar, Harbor tokens |
| `chmod 600` on env files (Unix lab VM) | Only your user can read secrets on disk |
| K8s lab uses `Secret/paas-frontend-env` | `sync-paas-frontend-env-k8s.sh` — not a ConfigMap |
| Use `*.example` templates only in git | Placeholders, no real PATs |

```bash
cp paas/frontend/docker-compose.env.example paas/frontend/docker-compose.env
chmod 600 paas/frontend/docker-compose.env
bash paas/scripts/secure-env-files.sh          # audit
bash paas/scripts/secure-env-files.sh --fix    # chmod 600
```

If a secret was ever committed: rotate the token, `git rm --cached <file>`, and force-push only after team agreement.
