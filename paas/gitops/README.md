# GitOps

Helm charts consumed by Argo CD (`apps/*`). This tree is intended to live in a dedicated GitOps repository (for example `nourhb/gitops`).

Use `python paas/scripts/seed_gitops_repo.py` from the monorepo root to push this folder to GitHub using `GITOPS_REPO_TOKEN` in `paas/frontend/.env`.
