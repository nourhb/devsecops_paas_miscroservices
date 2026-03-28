# PAAS scripts

This folder contains small helper scripts used by CI/CD pipelines.

Install dependencies:

```bash
cd paas/scripts
npm ci
```

Main helper:
- `update-gitops.js` — clones a GitOps repo, updates a `values.yaml` file (via `js-yaml`), commits and pushes. Used by the Jenkins pipeline to update Helm chart image tags.

Usage example:

```bash
node update-gitops.js --repoUrl=git@github.com:ORG/GITOPS.git --branch=main --valuesPath=charts/app/values.yaml --imageKey=image.tag --imageTag=registry/repo:tag
```

The Jenkins pipeline will call this helper using an SSH deploy key credential (ID `gitops-ssh-key`) via `sshagent`.

Notes on SSH:
- Use SSH repo URLs (e.g. `git@github.com:ORG/gitops.git`) when running under `sshagent`.
- The pipeline uses `ssh-keyscan github.com >> ~/.ssh/known_hosts` to avoid interactive host verification.
