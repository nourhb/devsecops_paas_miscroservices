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
# OCI index (crane push): need Accept header or use the helper script
bash paas/scripts/diagnose-harbor-registry-lab.sh paas/simple-app "${TAG}"
# Or docker pull (best gate):
docker pull 192.168.56.129:30002/paas/simple-app:${TAG}
```

Must be pullable. Naive `curl -I` without `Accept: application/vnd.oci.image.index.v1+json` often returns **404** even when the image exists.

## D. Deploy app (replace 103 with your TAG)

```bash
cd ~/devsecops_paas_miscroservices
export GITHUB_TOKEN='ghp_YOUR_PAT'
bash paas/scripts/final-deploy-simple-app-lab.sh 103
```

**Important:** `export` and `bash` must be on one line with `;` or on two lines — not glued together:
`export GITHUB_TOKEN='...'; bash paas/scripts/final-deploy-simple-app-lab.sh 104`

**Wrong:** `export GITHUB_TOKEN='...'bash paas/scripts/...` (bash error: not a valid identifier)

**ImagePullBackOff / Harbor `short read: unexpected EOF`:** Harbor metadata exists but blobs are corrupt. Build on master and import:

```bash
LOCAL_BUILD=1 bash paas/scripts/fix-simple-app-imagepull-lab.sh 104
```

**Git push:** use a real PAT, not the literal text `ghp_NEW_TOKEN`:

```bash
export GITHUB_TOKEN='ghp_your_real_token_here'
bash paas/scripts/final-deploy-simple-app-lab.sh 104
```

**PaaS links show apps.local:** `bash paas/scripts/patch-paas-frontend-lab-urls.sh` then use  
`http://simple-app.192.168.56.129.nip.io:30659/` in the browser (not apps.local).

**Wrong:** `bash ... <BUILD_NUMBER>`  
**Right:** `bash ... 103`

## E. Success

- `kubectl get pods -n simple-app` → `1/1 Running`
- `curl http://simple-app.192.168.56.129.nip.io:30659/` → **200**
