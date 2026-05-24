# Lab scripts

Postgres uses PVC `postgres-pvc` in namespace `paas` — users and projects survive pod restarts and reboots. The pod is **not** pinned to `hostname=master`; it must run on whichever node holds the volume (local-path).

If Postgres is `Pending` with PV node affinity errors: `bash paas/scripts/lab.sh postgres`

One-time on the VM (auto recover after boot, no re-seed):

```bash
sudo bash paas/scripts/install-paas-autostart-lab.sh
```

Entry point: `bash paas/scripts/lab.sh`

| Command | Action |
|---------|--------|
| `lab.sh start` | Postgres + schema + env after reboot |
| `lab.sh health` | Quick check |
| `lab.sh bootstrap` | First install |
| `lab.sh deploy N` | Deploy simple-app (needs `GITHUB_TOKEN`) |
| `lab.sh app pull N` | Fix image pull on cluster |
| `lab.sh jenkins` | Refresh `paas-deploy` job from Jenkinsfile |
| `lab.sh integrations` | K8s RBAC + in-cluster probe URLs for Platform hub |

Other scripts in this folder are for specific fixes (Harbor, Argo, Jenkins plugins, k3s API). Use only when needed.
