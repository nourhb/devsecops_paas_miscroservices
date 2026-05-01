# Self-Hosted Production Runbook

## 1. Target architecture

- External gateway: `HAProxy`
- Cluster router: `ingress-nginx`
- Control plane: `paas/frontend`
- CI: `Jenkins`
- CD: `ArgoCD`
- Runtime: `Kubernetes`
- Database: external PostgreSQL or CloudNativePG
- Artifact store: `Artifactory`
- Image registry: `Harbor`
- Supply chain controls: `Cosign` and `Kyverno`

## 2. VM and cluster roles

- `HAProxy VM`: public `80/443`, TLS termination, rate limiting, health checks
- `Kubernetes control plane`: ingress-nginx, ArgoCD, Kyverno, control plane workloads
- `Jenkins VM/service`: internal-only if possible
- `PostgreSQL`: managed external service or CloudNativePG cluster with backups

## 3. Secrets provisioning

1. Install Sealed Secrets.
2. Generate the plaintext secret locally.
3. Seal it.
4. Commit only the sealed output.

```bash
kubectl create namespace devsecops-paas --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic paas-secrets \
  --namespace devsecops-paas \
  --from-literal=DATABASE_URL='postgresql://paas:replace-me@postgres-rw.devsecops-paas.svc.cluster.local:5432/paas' \
  --from-literal=JWT_SECRET='replace-with-64-char-secret' \
  --from-literal=JENKINS_API_TOKEN='replace-me' \
  --from-literal=ARGOCD_AUTH_TOKEN='replace-me' \
  --dry-run=client -o yaml > paas-secrets.plain.yaml

kubeseal \
  --format yaml \
  --namespace devsecops-paas \
  --sealed-secret-file "paas/k8s-manifests/secret.yaml" \
  < paas-secrets.plain.yaml
```

## 4. Edge and ingress

1. Install `ingress-nginx`.
2. Put HAProxy in front of the ingress NodePort or LoadBalancer.
3. Use a single TLS model: HAProxy terminates TLS, then forwards HTTPS to ingress-nginx.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f paas/k8s-manifests/ingress/nginx-ingress-helm-values.example.yaml

kubectl apply -f paas/k8s-manifests/ingress.yaml
```

HAProxy config source:

- `k8s-manifests/haproxy/haproxy.enterprise.cfg`

## 5. Database topology

Preferred production choices:

- External PostgreSQL with backups managed outside the cluster
- Or `CloudNativePG` with three instances and object-store backups

Example operator manifest:

- `k8s-manifests/postgres/cloudnative-pg-cluster.example.yaml`

```bash
kubectl apply -f paas/k8s-manifests/postgres/cloudnative-pg-cluster.example.yaml
```

## 6. Platform controls

Install ArgoCD and Kyverno if not already installed:

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

helm repo add kyverno https://kyverno.github.io/kyverno/
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace

kubectl apply -f paas/k8s-manifests/kyverno/require-signed-images.yaml
kubectl apply -f paas/k8s-manifests/kyverno/require-non-root.yaml
```

## 7. ArgoCD application wiring

Apply the canonical application:

```bash
kubectl apply -f paas/gitops/argocd/sample-app-application.yaml
kubectl get applications -n argocd
```

Before applying, replace:

- `repoURL`
- `targetRevision`
- `path`

They must match the GitOps repository and path that Jenkins updates.

## 8. Jenkins credentials

Create these Jenkins credentials before enabling production builds:

- `harbor`
- `artifactory-creds`
- `cosign-key`
- `cosign-pub`
- `sonarqube`

Required environment variables:

- `HARBOR_URL`
- `HARBOR_PROJECT`
- `ARTIFACTORY_URL`
- `ARTIFACTORY_REPOSITORY`
- `GITOPS_REPO_URL`
- `GITOPS_BRANCH`

## 9. Deployment validation

Run these checks after each production rollout:

```bash
kubectl get applications -n argocd
kubectl get ingress -n devsecops-paas
kubectl get pods -n devsecops-paas
kubectl get clusterpolicy
kubectl describe clusterpolicy require-signed-images
kubectl describe clusterpolicy require-non-root
```

Control plane checks:

```bash
curl -k https://paas.example.com/api/health
curl -k https://paas.example.com/api/platform/deploy-readiness
```

## 10. Backup and restore

### PostgreSQL backup

```bash
pg_dump "$DATABASE_URL" --format=custom --file=paas-$(date +%F).dump
```

### PostgreSQL restore

```bash
pg_restore --clean --if-exists --dbname="$DATABASE_URL" paas-YYYY-MM-DD.dump
```

### GitOps rollback

```bash
git revert <gitops-commit-sha>
git push origin main
```

ArgoCD reconciles the reverted manifest automatically.

## 11. Enterprise demo path

1. Trigger Jenkins from the control plane.
2. Show Artifactory artifact upload.
3. Show Harbor image push.
4. Show Cosign verification on the immutable digest.
5. Show GitOps commit updating the digest in `values.yaml`.
6. Show ArgoCD syncing the `Application`.
7. Show the updated pod in Kubernetes.
8. Show Kyverno policies present and enforced.
9. Show the dashboard health, deployment, and security views.
