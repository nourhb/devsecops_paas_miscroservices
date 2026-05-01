# Secrets Management

Production secrets are managed with Bitnami Sealed Secrets.

## Supported workflow

1. Install the Sealed Secrets controller in the target cluster.
2. Create a temporary local `Secret` manifest outside Git.
3. Seal it with `kubeseal` against the cluster certificate.
4. Commit only the resulting `SealedSecret`.

## Example

```bash
kubectl create secret generic paas-secrets \
  --namespace devsecops-paas \
  --from-literal=DATABASE_URL='postgresql://...' \
  --from-literal=JWT_SECRET='replace-with-strong-secret' \
  --dry-run=client -o yaml > paas-secrets.plain.yaml

kubeseal \
  --format yaml \
  --namespace devsecops-paas \
  --sealed-secret-file "paas/k8s-manifests/secret.yaml" \
  < paas-secrets.plain.yaml

Remove-Item paas-secrets.plain.yaml
```

## Rules

- Never commit plaintext Kubernetes `Secret` manifests.
- Rotate Jenkins, ArgoCD, Dependency-Track, and database credentials per environment.
- Keep production sealing keys in the cluster only.
