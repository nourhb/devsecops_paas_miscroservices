# Lab scripts

Entry point: `bash paas/scripts/lab.sh`

| Command | Action |
|---------|--------|
| `lab.sh start` | Postgres + schema + env after reboot |
| `lab.sh health` | Quick check |
| `lab.sh bootstrap` | First install |
| `lab.sh deploy N` | Deploy simple-app (needs `GITHUB_TOKEN`) |
| `lab.sh app pull N` | Fix image pull on cluster |
| `lab.sh jenkins` | Refresh `paas-deploy` job from Jenkinsfile |

Other scripts in this folder are for specific fixes (Harbor, Argo, Jenkins plugins, k3s API). Use only when needed.
