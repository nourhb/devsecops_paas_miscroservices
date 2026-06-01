
Postgres uses PVC `postgres-pvc` in namespace `paas` — users and projects survive pod restarts and reboots. The pod is **not** pinned to `hostname=master`; it must run on whichever node holds the volume (local-path).

If Postgres is `Pending` with PV node affinity errors: `bash paas/scripts/lab.sh postgres`

### Auto-start after VM reboot (recommended)

Prevents **“Can't reach database server at postgres.paas.svc.cluster.local”** on login when k3s/Postgres start slower than the PaaS UI.

**One-time** (from your clone, as user `master`):

```bash
cd ~/devsecops_paas_miscroservices
sudo bash paas/scripts/install-paas-autostart-lab.sh
sudo systemctl enable k3s
```

Test without reboot:

```bash
sudo systemctl start paas-lab-recover
journalctl -u paas-lab-recover -n 100 --no-pager
bash paas/scripts/check-paas-lab-health.sh
```

After every reboot: wait **2–5 minutes**, then open http://192.168.56.129:30100/login.

Manual recover (any time):

```bash
bash paas/scripts/recover-paas-after-k3s-restart.sh
```

If the unit was installed with wrong paths: `sudo bash paas/scripts/fix-paas-autostart-unit-lab.sh`

Entry point: `bash paas/scripts/lab.sh`

| Command | Action |
|---------|--------|
| `lab.sh start` | Postgres + schema + env after reboot |
| `deploy-paas-frontend-k8s.sh` | Builds frontend; runs `push-paas-schema-lab.sh` first unless `SKIP_SCHEMA=1` |
| `lab.sh health` | Quick check |
| `lab.sh bootstrap` | First install |
| `lab.sh deploy N` | Deploy simple-app (needs `GITHUB_TOKEN`) |
| `lab.sh app pull N` | Fix image pull on cluster |
| `lab.sh jenkins` | Refresh `paas-deploy` job from Jenkinsfile |
| `lab.sh integrations` | K8s RBAC + in-cluster probe URLs for Platform hub |
| `lab.sh security` | Full security fix: Sonar/DT/Cosign/Jenkins + sign deployed images (`fix-security-all-projects-lab.sh`) |
| `fix-security-all-projects-lab.sh` | Same as `lab.sh security`; set `REBUILD_FRONTEND=1` if Security UI still shows Trivy fetch failed |

Other scripts in this folder are for specific fixes (Harbor, Argo, Jenkins plugins, k3s API). Use only when needed.
