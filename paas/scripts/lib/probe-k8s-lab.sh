#!/usr/bin/env bash
# Diagnose why PaaS UI shows "Kubernetes API not configured".
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"

echo "==> Kubernetes lab probe (PaaS frontend pod)"
if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: deployment/frontend not found in ${PAAS_NS}" >&2
  exit 1
fi

echo "-- env in pod"
kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c '
  for v in KUBERNETES_ENABLED KUBE_CONFIG_PATH KUBE_TLS_SKIP_VERIFY; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=$val"; else echo "$v=MISSING"; fi
  done
  if [ -n "$KUBERNETES_SERVICE_HOST" ]; then echo "KUBERNETES_SERVICE_HOST=set"; else echo "KUBERNETES_SERVICE_HOST=MISSING"; fi
  sa="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
  if [ -n "$sa" ]; then echo "serviceAccountNamespace=$sa"; else echo "serviceAccountNamespace=MISSING"; fi
  if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then echo "saToken=mounted"; else echo "saToken=MISSING"; fi
' 2>/dev/null || { echo "WARN: could not exec into frontend pod"; exit 1; }

echo "-- service account + RBAC"
kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='serviceAccountName={.spec.template.spec.serviceAccountName}{"\n"}' 2>/dev/null || true
kubectl auth can-i list pods --all-namespaces --as=system:serviceaccount:${PAAS_NS}:paas-frontend 2>/dev/null \
  && echo "RBAC: paas-frontend can list pods cluster-wide" \
  || echo "WARN: paas-frontend cannot list pods — apply paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"

echo "-- direct API from pod (service account token)"
if kubectl exec -n "${PAAS_NS}" deploy/frontend -- node -e "
const fs=require('fs');
const https=require('https');
const host=process.env.KUBERNETES_SERVICE_HOST;
const port=process.env.KUBERNETES_SERVICE_PORT||443;
if(!host){console.error('KUBERNETES_SERVICE_HOST missing');process.exit(2);}
const token=fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token','utf8').trim();
const req=https.get({
  hostname:host,port,
  path:'/api/v1/namespaces/paas/pods?labelSelector=app%3Dfrontend',
  headers:{Authorization:'Bearer '+token},
  rejectUnauthorized:false
},res=>{
  let d='';res.on('data',c=>d+=c);
  res.on('end',()=>{
    if(res.statusCode>=200&&res.statusCode<300&&d.includes('\"kind\":\"PodList\"')){
      console.log('OK list pods in paas (HTTP '+res.statusCode+')');
      process.exit(0);
    }
    console.error('HTTP '+res.statusCode+': '+d.slice(0,200));
    process.exit(1);
  });
});
req.on('error',e=>{console.error(e.message);process.exit(1);});
setTimeout(()=>process.exit(1),15000);
" 2>/dev/null; then
  echo "Cluster credentials work from the pod."
else
  echo "WARN: pod cannot list pods via Kubernetes API"
fi

echo "-- PaaS API (requires login cookie — open UI and check Network tab for /api/k8s/pods)"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:${PAAS_PORT}/api/k8s/pods" 2>/dev/null || echo 000)"
echo "GET /api/k8s/pods without auth: HTTP ${HTTP} (401/403 expected)"

echo ""
echo "If saToken=mounted and direct API OK but UI still says not configured:"
echo "  1. grep KUBE_CONFIG_PATH paas/frontend/docker-compose.env  # must be empty or absent"
echo "  2. bash paas/scripts/lab.sh env"
echo "  3. Rebuild frontend (kubernetes-client fix): bash paas/scripts/lab.sh frontend"
echo "     Or rollout only if image already rebuilt: bash paas/scripts/lab.sh frontend-rollout"
