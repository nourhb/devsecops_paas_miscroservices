# Final lab fix — simple-app

## A. PaaS frontend (namespace `paas`, deployment name `frontend`)

Wrong label: there is no `app.kubernetes.io/name=frontend` in this lab.

```bash
bash paas/scripts/recover-paas-lab.sh
# or manually:
kubectl get deploy,pods -n paas
kubectl set image deployment/frontend -n paas frontend=192.168.56.129:30002/paas/paas-frontend:latest
kubectl rollout restart deployment/frontend -n paas
kubectl rollout status deployment/frontend -n paas --timeout=600s
curl -sS -o /dev/null -w 'PaaS %{http_code}\n' http://192.168.56.129:30100/
```

## B. Jenkins — push image (required)

1. Jenkins → **paas-deploy** → Build (project **simple-app**).
2. Wait **SUCCESS**.
3. Note build number from: `PAAS_ARTIFACT_IMAGE=192.168.56.129:30002/paas/simple-app:NNN`

## C. Gate — manifest must exist (replace NNN)

```bash
TAG=103   # use your Jenkins NNN, not angle brackets
curl -sS -o /dev/null -w 'MAN %{http_code}\n' -I -u admin:Harbor12345 \
  "http://192.168.56.129:30002/v2/paas/simple-app/manifests/${TAG}"
```

Must be **200**. If **404**, run Jenkins again (registry has no blobs for that tag).

## D. Deploy app (replace 103 with your TAG)

```bash
cd ~/devsecops_paas_miscroservices
export GITHUB_TOKEN='ghp_YOUR_PAT'
bash paas/scripts/final-deploy-simple-app-lab.sh 103
```

**Wrong:** `bash ... <BUILD_NUMBER>`  
**Right:** `bash ... 103`

## E. Success

- `kubectl get pods -n simple-app` → `1/1 Running`
- `curl http://simple-app.192.168.56.129.nip.io:30659/` → **200**
