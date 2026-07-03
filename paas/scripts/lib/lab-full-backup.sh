#!/usr/bin/env bash
# Full disaster-recovery backup of the whole PaaS lab: git repo history, every
# Kubernetes resource in every namespace, every Helm release, Jenkins jobs/
# credentials/pipeline files, and the RAW persistent-volume data behind
# k3s local-path storage (Harbor registry images+DB, SonarQube DB,
# Dependency-Track DB, Postgres data, Jenkins home volume, ...).
#
# Run: bash paas/scripts/lab.sh backup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh" 2>/dev/null || true

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${PAAS_BACKUP_ROOT:-/var/backups/paas-lab}"
DEST="${BACKUP_ROOT}/${STAMP}"
LOCAL_PATH_DIR="${PAAS_LOCAL_PATH_STORAGE_DIR:-/var/lib/rancher/k3s/storage}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"

log() { echo "[full-backup] $*"; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }

mkdir -p "${DEST}/k8s" "${DEST}/helm" "${DEST}/git"

echo "=============================================="
echo " PaaS lab FULL backup — ${STAMP}"
echo " destination: ${DEST}"
echo "=============================================="

log "=== 0. Disk space (make sure there's room before we start) ==="
df -h / /var 2>/dev/null || true
echo ""

log "=== 1. Git repo bundle (full history — restorable even if GitHub is unreachable) ==="
if git -C "${REPO_ROOT}" bundle create "${DEST}/git/repo.bundle" --all 2>/dev/null; then
  ok "git bundle -> ${DEST}/git/repo.bundle"
else
  warn "git bundle failed — repo state still safe on GitHub if pushed"
fi
git -C "${REPO_ROOT}" status --short > "${DEST}/git/uncommitted-status.txt" 2>/dev/null || true
git -C "${REPO_ROOT}" log --oneline -30 > "${DEST}/git/recent-commits.txt" 2>/dev/null || true
if [[ -s "${DEST}/git/uncommitted-status.txt" ]]; then
  warn "you have UNCOMMITTED changes in the repo — see ${DEST}/git/uncommitted-status.txt"
else
  ok "working tree clean (nothing uncommitted)"
fi
echo ""

log "=== 2. Kubernetes resources — every namespace ==="
NAMESPACES="$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
ns_count=0
for ns in ${NAMESPACES}; do
  if kubectl get all,configmap,secret,pvc,ingress,serviceaccount,role,rolebinding,networkpolicy \
      -n "${ns}" -o yaml > "${DEST}/k8s/${ns}.yaml" 2>/dev/null; then
    ns_count=$((ns_count + 1))
  fi
done
kubectl get pv -o yaml > "${DEST}/k8s/_persistentvolumes.yaml" 2>/dev/null || true
kubectl get nodes -o yaml > "${DEST}/k8s/_nodes.yaml" 2>/dev/null || true
kubectl get storageclass -o yaml > "${DEST}/k8s/_storageclasses.yaml" 2>/dev/null || true
kubectl get clusterrole,clusterrolebinding -o yaml > "${DEST}/k8s/_cluster-rbac.yaml" 2>/dev/null || true
ok "k8s manifests for ${ns_count} namespace(s) -> ${DEST}/k8s/"
echo ""

log "=== 3. Helm releases (full manifest + values + hooks) ==="
if command -v helm >/dev/null 2>&1; then
  helm list -A > "${DEST}/helm/_release-list.txt" 2>/dev/null || true
  helm list -A -o json 2>/dev/null | python3 -c '
import json, sys
try:
    releases = json.load(sys.stdin)
except Exception:
    releases = []
for r in releases:
    print(r["name"] + "|" + r["namespace"])
' 2>/dev/null | while IFS='|' read -r rel ns; do
    [[ -z "${rel}" ]] && continue
    helm get all "${rel}" -n "${ns}" > "${DEST}/helm/${ns}_${rel}.yaml" 2>/dev/null \
      && ok "helm release ${ns}/${rel} -> helm/${ns}_${rel}.yaml" \
      || warn "helm get all failed for ${ns}/${rel}"
  done
else
  warn "helm not on PATH — skipped (k8s/*.yaml above still has the live objects)"
fi
echo ""

log "=== 4. Jenkins home essentials (jobs, plugin list, paas/ pipeline, credentials) ==="
if kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1; then
  phase="$(kubectl get pod -n "${JENKINS_NS}" "${JPOD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Running" ]]; then
    kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=300s -- tar czf - \
      -C /var/jenkins_home --ignore-failed-read \
      jobs plugins paas users secrets.xml config.xml credentials.xml 2>/dev/null \
      > "${DEST}/jenkins_home_essentials.tgz" || true
    if [[ -s "${DEST}/jenkins_home_essentials.tgz" ]]; then
      ok "jenkins essentials -> jenkins_home_essentials.tgz ($(du -h "${DEST}/jenkins_home_essentials.tgz" | awk '{print $1}'))"
    else
      warn "empty jenkins tarball"
      rm -f "${DEST}/jenkins_home_essentials.tgz"
    fi
  else
    warn "${JPOD} phase=${phase} — skip live tar (raw PV data in step 5 still has it)"
  fi
else
  warn "no ${JPOD} pod in ns=${JENKINS_NS} — skip (raw PV data in step 5 still has it)"
fi
echo ""

log "=== 5. RAW persistent-volume data (Harbor images+DB, SonarQube DB, Dependency-Track DB, Postgres, Jenkins home volume) ==="
if [[ -d "${LOCAL_PATH_DIR}" ]]; then
  SIZE_MB="$(du -sm "${LOCAL_PATH_DIR}" 2>/dev/null | awk '{print $1}')"
  log "local-path storage size ~${SIZE_MB:-?}MB at ${LOCAL_PATH_DIR} — this can take a few minutes"
  SUDO=""
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  if ${SUDO} tar czf "${DEST}/local-path-storage-pv-data.tgz" \
      --exclude='*/.jenkins-paas-cache/*' \
      --exclude='*/paas-artifacts/*' \
      -C "$(dirname "${LOCAL_PATH_DIR}")" "$(basename "${LOCAL_PATH_DIR}")" 2>/dev/null; then
    ${SUDO} chown "$(id -u):$(id -g)" "${DEST}/local-path-storage-pv-data.tgz" 2>/dev/null || true
    ok "PV data -> local-path-storage-pv-data.tgz ($(du -h "${DEST}/local-path-storage-pv-data.tgz" | awk '{print $1}'))"
  else
    warn "PV data tar failed (permissions?) — retry manually: sudo tar czf ${DEST}/local-path-storage-pv-data.tgz -C $(dirname "${LOCAL_PATH_DIR}") $(basename "${LOCAL_PATH_DIR}")"
  fi
else
  warn "${LOCAL_PATH_DIR} not found — check your k3s storage class path (kubectl get sc,pv)"
fi
echo ""

cat > "${DEST}/README.txt" <<EOF
PaaS lab FULL backup — ${STAMP}
================================
git/repo.bundle                        Full git history (restore: git clone repo.bundle restored-repo)
git/uncommitted-status.txt             Any uncommitted changes at backup time (should be empty)
k8s/<namespace>.yaml                   All resources (deploy/svc/cm/secret/pvc/ingress/rbac) per namespace
k8s/_persistentvolumes.yaml            All cluster PVs
k8s/_cluster-rbac.yaml                 ClusterRole/ClusterRoleBinding
helm/<ns>_<release>.yaml               Helm release manifest + values + hooks
jenkins_home_essentials.tgz            Jenkins jobs, plugin list, paas/ pipeline files, credentials.xml, secrets.xml
local-path-storage-pv-data.tgz         RAW PV data: Harbor registry+DB, SonarQube DB, Dependency-Track DB,
                                        Postgres data, Jenkins home volume (npm/node/next build caches excluded —
                                        disposable, rebuilt automatically by the pipeline)

RESTORE ON A NEW VM (disaster recovery):
  1. git clone repo.bundle devsecops_paas_miscroservices  (or use GitHub if reachable)
  2. Install k3s, then STOP before creating any PVCs
  3. Extract local-path-storage-pv-data.tgz into ${LOCAL_PATH_DIR} so local-path binds existing data:
       sudo tar xzf local-path-storage-pv-data.tgz -C $(dirname "${LOCAL_PATH_DIR}")
  4. bash paas/scripts/lab.sh fresh-cluster   (or reinstall-platform)
  5. Re-apply anything under k8s/*.yaml / helm/*.yaml that fresh-cluster didn't already recreate
  6. Restore Jenkins jobs/credentials:
       kubectl cp jenkins_home_essentials.tgz cicd/jenkins-0:/tmp/j.tgz -c jenkins
       kubectl exec -n cicd jenkins-0 -c jenkins -- tar xzf /tmp/j.tgz -C /var/jenkins_home
EOF

TOTAL_SIZE="$(du -sh "${DEST}" 2>/dev/null | awk '{print $1}')"
echo "=============================================="
ok "FULL BACKUP COMPLETE: ${DEST} (${TOTAL_SIZE})"
echo "=============================================="
echo ""
echo "IMPORTANT — a backup that stays on the same disk as the thing it backs up is not a real backup."
echo "Copy it OFF this VM now. From your Windows machine (PowerShell):"
echo ""
echo "  scp -r master@192.168.56.129:${DEST} \"\$env:USERPROFILE\\Desktop\\paas-lab-backup-${STAMP}\""
echo ""
echo "Or bundle it into one file on the VM first, then copy that single file:"
echo "  tar czf ${BACKUP_ROOT}/paas-lab-backup-${STAMP}.tar.gz -C ${BACKUP_ROOT} ${STAMP}"
echo "  scp master@192.168.56.129:${BACKUP_ROOT}/paas-lab-backup-${STAMP}.tar.gz \"\$env:USERPROFILE\\Desktop\\\""
