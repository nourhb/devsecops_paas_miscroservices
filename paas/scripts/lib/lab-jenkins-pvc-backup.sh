#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
BACKUP_ROOT="${JENKINS_BACKUP_ROOT:-/var/tmp/jenkins-pvc-backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${BACKUP_ROOT}/${STAMP}"

log() { echo "[jenkins-pvc-backup] $*"; }
ok() { echo "OK: $*"; }

mkdir -p "${DEST}"

log "=== Jenkins PVC / PV inventory ==="
kubectl get pvc,pv -A 2>/dev/null | grep -iE 'jenkins|NAME' || true
log ""
log "Released PVs (data may still exist on node disk):"
kubectl get pv -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,PATH:.spec.local.path,STORAGE:.spec.storageClassName 2>/dev/null \
  | grep -iE 'jenkins|Released|NAME' || true

if kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1; then
  phase="$(kubectl get pod -n "${JENKINS_NS}" "${JPOD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Running" ]]; then
    log "==> Tar Jenkins home essentials from ${JPOD}"
    kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=300s -- tar czf - \
      -C /var/jenkins_home \
      --ignore-failed-read \
      jobs plugins paas users secrets.xml config.xml credentials.xml 2>/dev/null \
      > "${DEST}/jenkins_home_essentials.tgz" || true
    if [[ -s "${DEST}/jenkins_home_essentials.tgz" ]]; then
      ok "wrote ${DEST}/jenkins_home_essentials.tgz ($(wc -c < "${DEST}/jenkins_home_essentials.tgz") bytes)"
    else
      log "WARN: empty essentials tarball (pod not ready?)"
      rm -f "${DEST}/jenkins_home_essentials.tgz"
    fi
    kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=60s -- \
      tar czf - -C /var/jenkins_home/paas . 2>/dev/null > "${DEST}/jenkins_paas_bundle.tgz" || true
    [[ -s "${DEST}/jenkins_paas_bundle.tgz" ]] && ok "wrote ${DEST}/jenkins_paas_bundle.tgz"
  else
    log "pod ${JPOD} phase=${phase} — skip live tar"
  fi
else
  log "no ${JPOD} pod — trying Released PV path on node"
fi

kubectl get pv -o json 2>/dev/null | python3 - "${DEST}/released-pvs.txt" <<'PY' || true
import json, sys
out = sys.argv[1]
pvs = json.load(sys.stdin).get("items", [])
lines = []
for pv in pvs:
    name = pv["metadata"]["name"]
    phase = pv.get("status", {}).get("phase", "")
    ref = pv.get("spec", {}).get("claimRef") or {}
    claim = f"{ref.get('namespace','')}/{ref.get('name','')}"
    path = (pv.get("spec", {}).get("local") or {}).get("path", "")
    if "jenkins" in name.lower() or "jenkins" in claim.lower() or phase == "Released":
        lines.append(f"{name}\t{phase}\t{claim}\t{path}")
Path(out).write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print(f"listed {len(lines)} jenkins/released PV rows -> {out}")
PY

cat > "${DEST}/README.txt" <<EOF
Jenkins backup ${STAMP}
Restore paas bundle: kubectl exec -i -n cicd jenkins-0 -c jenkins -- tar xzf - -C /var/jenkins_home/paas < jenkins_paas_bundle.tgz
Reinstall job from repo: bash paas/scripts/lib/restore-paas-deploy-working.sh
Old Released PV data: see released-pvs.txt — on k3s local-path, path is usually under /var/lib/rancher/k3s/storage/
EOF

ok "backup at ${DEST}"
echo "  ls -la ${DEST}"
