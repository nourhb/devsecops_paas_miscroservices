# ArgoCD and GitOps Deployment Workflow

## GitOps architecture

- **Single source of truth:** Git repository (GitOps repo) holds all Kubernetes manifests and Helm values.
- **ArgoCD** watches this repo and reconciles the cluster so that actual state matches Git.
- **Pipeline (Jenkins)** does not run `kubectl apply`; it only updates the GitOps repo (e.g. image tag in `values.yaml`). ArgoCD performs the deploy.

## ArgoCD deployment workflow

1. **Developer / PaaS** triggers pipeline; Jenkins builds image and pushes to Harbor.
2. **Jenkins** clones GitOps repo, updates `apps/<app-name>/values.yaml` (e.g. `image.tag: <build-number>`), commits and pushes.
3. **ArgoCD** detects the Git change (poll or webhook).
4. **ArgoCD** runs `helm template` or uses the Helm chart from the repo and applies the result to the cluster.
5. **Kubernetes** rolls out the new deployment; old pods are replaced.

## Example ArgoCD Application manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/gitops-repo.git
    path: apps/my-app
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## GitOps repo layout

```
gitops-repo/
├── apps/
│   ├── my-app/
│   │   ├── Chart.yaml
│   │   ├── values.yaml    # Updated by Jenkins (image.tag, etc.)
│   │   └── templates/
│   └── other-app/
└── base/                  # Optional Kustomize base
```

## Benefits

- **Auditability:** Every deploy is a Git commit.
- **Rollback:** Revert the Git commit; ArgoCD syncs back.
- **No direct cluster access** for the pipeline; only Git write and ArgoCD read.
