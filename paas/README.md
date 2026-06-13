# PaaS platform

```
paas/
├── scripts/          Lab operations (entry: lab.sh)
├── frontend/         Next.js UI and API
│   ├── src/app/      Routes and API handlers
│   ├── src/components/
│   ├── src/lib/      Client helpers
│   ├── src/server/   Backend services
│   ├── prisma/       Database schema
│   └── scripts/      Build and env helpers
├── jenkins/          Jenkinsfile.paas-deploy
├── gitops/           Helm chart bootstrap (simple-app)
└── k8s-manifests/    Postgres, RBAC, Kyverno policies
```

## Daily lab

```bash
bash paas/scripts/lab.sh start
bash paas/scripts/lab.sh health
bash paas/scripts/lab.sh env
bash paas/scripts/lab.sh jenkins
bash paas/scripts/heal-project-deploy-lab.sh <project> <build> [port]
```

Local frontend: `bash paas/scripts/dev.sh`

## One-time cluster setup

```bash
kubectl apply -f paas/k8s-manifests/lab/
kubectl apply -f paas/k8s-manifests/kyverno/
```

## Env

Edit `paas/frontend/.env`, then:

```bash
cd paas/frontend && npm run env:compose
bash paas/scripts/lab.sh env
```
