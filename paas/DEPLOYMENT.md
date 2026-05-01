# Self-Hosted Deployment Guide

This repository is productionized for a self-hosted GitOps architecture:

- `Jenkins` handles CI only.
- `ArgoCD` handles CD only.
- `HAProxy` is the external gateway.
- `ingress-nginx` handles in-cluster HTTP routing.
- `Kubernetes` runs the control plane and workloads.
- `PostgreSQL` is external or operator-managed, not `docker-compose` in production.

## Topology

```text
Users -> HAProxy -> ingress-nginx -> Next.js control plane -> Jenkins / ArgoCD / Kubernetes / PostgreSQL
```

## Production entry points

- `paas.example.com` -> HAProxy `:443`
- `Jenkins` remains internal or on a separate admin hostname
- `ArgoCD` remains internal or admin-only

## Required production artifacts

- `k8s-manifests/ingress.yaml`
- `k8s-manifests/secret.yaml` as a `SealedSecret`
- `k8s-manifests/haproxy/haproxy.enterprise.cfg`
- `gitops/argocd/sample-app-application.yaml`
- `k8s-manifests/postgres/cloudnative-pg-cluster.example.yaml`

## Production rules

- Do not use `docker-compose.yml` beyond local development.
- Do not commit plaintext Kubernetes secrets.
- Do not deploy mutable `latest` images through GitOps.
- Do not let Jenkins call `argocd app sync`.

## Next step

Use `docs/SELF_HOSTED_PRODUCTION_RUNBOOK.md` as the copy-paste operator runbook for install, validation, backup, restore, and rollback.
