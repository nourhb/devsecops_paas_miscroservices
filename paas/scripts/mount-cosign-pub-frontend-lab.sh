#!/usr/bin/env bash
# Mount paas/.lab-cosign/cosign.pub into deployment/frontend at /etc/cosign/cosign.pub (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
PATCH_FILE="/tmp/paas-frontend-cosign-pub-patch-$$.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { rm -f "${PATCH_FILE}"; }
trap cleanup EXIT

[[ -f "${KEYDIR}/cosign.pub" ]] || die "Missing ${KEYDIR}/cosign.pub"
command -v kubectl >/dev/null 2>&1 || die "kubectl required"
kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1 || die "deployment/${DEPLOY_NAME} not in ${PAAS_NS}"

echo "==> Secret cosign-lab-pub (public key file, not PEM in env)"
kubectl create secret generic cosign-lab-pub \
  --from-file=cosign.pub="${KEYDIR}/cosign.pub" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Patch deployment/${DEPLOY_NAME} — volume + mount + COSIGN_PUBLIC_KEY_PATH"
cat > "${PATCH_FILE}" <<PATCH
spec:
  template:
    spec:
      volumes:
        - name: cosign-lab-pub
          secret:
            secretName: cosign-lab-pub
            defaultMode: 292
            items:
              - key: cosign.pub
                path: cosign.pub
      containers:
        - name: ${DEPLOY_NAME}
          env:
            - name: COSIGN_PUBLIC_KEY_PATH
              value: /etc/cosign/cosign.pub
            - name: COSIGN_ALLOW_INSECURE_REGISTRY
              value: "true"
          volumeMounts:
            - name: cosign-lab-pub
              mountPath: /etc/cosign
              readOnly: true
PATCH

kubectl patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic --patch-file="${PATCH_FILE}"
echo "OK: patched deployment/${DEPLOY_NAME} (cosign.pub → /etc/cosign/cosign.pub)"

kubectl rollout restart "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}"
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s

if kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- test -r /etc/cosign/cosign.pub; then
  echo "OK: /etc/cosign/cosign.pub readable in frontend pod"
else
  die "/etc/cosign/cosign.pub not readable after rollout"
fi
