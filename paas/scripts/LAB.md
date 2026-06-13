# Lab commands

```bash
bash paas/scripts/lab.sh start
bash paas/scripts/lab.sh health
bash paas/scripts/lab.sh env
bash paas/scripts/lab.sh jenkins
bash paas/scripts/heal-project-deploy-lab.sh <project> <build> [port]
```

Kyverno blocks deploy when Harbor uses a raw IP in the cosign auth realm:

```bash
bash paas/scripts/fix-harbor-cosign-realm-lab.sh
bash paas/scripts/apply-kyverno-cosign-lab.sh
kubectl annotate application paas-<project> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

Set `HARBOR_BASE_URL=http://harbor.192.168.56.129.nip.io:30002` in `paas/frontend/docker-compose.env`, recreate frontend, re-deploy.

Local dev: `bash paas/scripts/dev.sh`

See `paas/README.md` for project layout.
