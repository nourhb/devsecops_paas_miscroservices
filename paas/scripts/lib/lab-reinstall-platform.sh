#!/usr/bin/env bash
# Reinstall DevSecOps platform after k3s etcd wipe (namespaces/helm releases gone; PVC dirs may remain on disk).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

NODE_IP="${NODE_IP:-192.168.56.129}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PAAS_FORCE_KYVERNO_UNBLOCK=1

log() { echo "[platform-reinstall] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: $1 required"; exit 1; }; }

lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
systemctl is-active k3s >/dev/null 2>&1 || { sudo systemctl start k3s; sleep 60; }
lab_k8s_api_wait || { log "k3s API not ready"; exit 1; }

need helm
need kubectl

log "disk $(df / | awk 'NR==2 {print $5}')"

# --- Harbor (registry :30002) ---
if ! curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30002/v2/" 2>/dev/null | grep -qE '200|401'; then
  log "install Harbor"
  helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
  helm repo update harbor
  kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install harbor harbor/harbor -n harbor \
    --set expose.type=nodePort \
    --set expose.tls.enabled=false \
    --set expose.nodePort.ports.http.nodePort=30002 \
    --set externalURL="http://${NODE_IP}:30002" \
    --set harborAdminPassword=Harbor12345 \
    --set persistence.persistentVolumeClaim.registry.storageClass=local-path \
    --set persistence.persistentVolumeClaim.jobservice.storageClass=local-path \
    --set persistence.persistentVolumeClaim.database.storageClass=local-path \
    --set persistence.persistentVolumeClaim.redis.storageClass=local-path \
    --set persistence.persistentVolumeClaim.trivy.storageClass=local-path \
    --timeout 10m || log "WARN: harbor helm returned non-zero — polling :30002"
  for i in $(seq 1 40); do
    h="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30002/v2/" 2>/dev/null || echo 000)"
    log "harbor http=${h} (${i}/40)"
    [[ "${h}" =~ ^(200|401)$ ]] && break
    sleep 15
  done
  bash "${SCRIPT_DIR}/lab-harbor.sh" configure || true
else
  log "Harbor already responding on :30002"
fi

# --- Jenkins (cicd :30090) ---
if ! curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30090/login" 2>/dev/null | grep -qE '200|403'; then
  log "install Jenkins in namespace cicd"
  bash "${SCRIPT_DIR}/lab-jenkins-helm-install.sh" install || log "WARN: Jenkins install failed — retry: bash paas/scripts/lab.sh jenkins-install"
else
  log "Jenkins already responding on :30090"
fi

# --- Argo CD ---
if ! kubectl get ns argocd >/dev/null 2>&1; then
  log "install Argo CD"
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}' 2>/dev/null || true
else
  log "namespace argocd exists"
  kubectl get deploy -n argocd 2>/dev/null | head -5 || \
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
fi

# --- SonarQube (:30900 in lab env) ---
if ! kubectl get ns sonarqube >/dev/null 2>&1; then
  log "install SonarQube (optional — may take 10+ min)"
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube
  kubectl create namespace sonarqube
  helm upgrade --install sonarqube sonarqube/sonarqube -n sonarqube \
    --set service.type=NodePort \
    --set service.nodePort=30900 \
    --set postgresql.enabled=true \
    --set community.enabled=true \
    --set monitoringPasscode=paas-lab-monitor \
    --set sonarProperties."sonar\\.web\\.javaOpts"="-Xmx512m -Xms256m" \
    --set sonarProperties."sonar\\.ce\\.javaOpts"="-Xmx512m -Xms256m" \
    --timeout 20m || log "WARN: Sonar helm install failed — continue"
fi

log "wait for core endpoints"
for i in $(seq 1 30); do
  j="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30090/login" 2>/dev/null || echo 000)"
  h="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30002/v2/" 2>/dev/null || echo 000)"
  log "jenkins=${j} harbor=${h} (${i}/30)"
  [[ "${j}" =~ ^(200|403)$ ]] && [[ "${h}" =~ ^(200|401)$ ]] && break
  sleep 15
done

log "sync PaaS env + Jenkins job from repo"
cd "${REPO_ROOT}"
bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh" 2>/dev/null || true
PAAS_SKIP_DT=1 PAAS_SKIP_ROLLOUT=1 bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
SKIP_FRONTEND_REBUILD=true LAB_DT_SKIP_HEAL=true \
  bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh" 2>/dev/null || \
  log "WARN: jenkins job sync failed — run: bash paas/scripts/lab.sh jenkins"

kubectl get pods -n harbor 2>/dev/null | head -8 || true
kubectl get pods -n cicd 2>/dev/null | head -5 || true
kubectl get pods -n argocd 2>/dev/null | head -5 || true

log "OK — verify:"
log "  Jenkins  http://${NODE_IP}:30090/login"
log "  Harbor   http://${NODE_IP}:30002"
log "  PaaS UI  http://${NODE_IP}:30100/login"
log "  bash paas/scripts/lab.sh pipeline-heal   (tokens + full 12-step)"
