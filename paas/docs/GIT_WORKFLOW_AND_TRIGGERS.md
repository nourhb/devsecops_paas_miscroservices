# Git Workflow and Build Triggers

## Branch Strategy

- `main` is the primary promotion branch.
- optional feature branches can run validation-only builds.
- production deployment remains artifact-driven through GitOps.

## Trigger Flow

1. A developer pushes code or a webhook fires.
2. The PaaS control plane matches the repository and branch to a project.
3. `BuildPlanner` selects the managed profile and build mode.
4. The configured backend starts the build:
   - Jenkins adapter in compatibility mode
   - Tekton `PipelineRun` in Kubernetes-native mode
5. The produced artifact is promoted through the GitOps repository.
6. Argo CD syncs the new desired state into the cluster.

## Black-box Developer Experience

- Developers use the PaaS UI and Git only.
- They see build provider, run status, deployment logs, and resulting application URLs.
- They do not need direct access to Jenkins or Tekton internals.
