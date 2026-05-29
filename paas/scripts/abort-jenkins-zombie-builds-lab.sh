#!/usr/bin/env bash
# Mark zombie WorkflowRuns (building=true after OOM/restart) as ABORTED on Jenkins PVC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JENKINS_NS="${JENKINS_NS:-cicd}"
JOB="${JOB_NAME:-paas-deploy}"
PVC="${JENKINS_PVC:-jenkins-pvc}"
NODE="${JENKINS_NODE:-master}"
WORK="${TMPDIR:-/tmp}/jenkins-zombie-fix-$$"
POD_NAME="jenkins-zombie-fix"

cleanup() {
  kubectl delete pod "${POD_NAME}" -n "${JENKINS_NS}" --ignore-not-found --wait=false 2>/dev/null || true
  rm -rf "${WORK}"
  echo "==> Ensure Jenkins is running"
  kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=1 2>/dev/null || true
  kubectl rollout status deployment/jenkins -n "${JENKINS_NS}" --timeout=600s 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${WORK}"

cat > "${WORK}/fix.sh" <<SCRIPT
#!/bin/sh
set -eu
JH="/jenkins_home/jobs/${JOB}/builds"
CFG="/jenkins_home/config.xml"

echo "==> Force numExecutors=2 in config.xml"
if [ -f "\$CFG" ]; then
  if grep -q '<numExecutors>' "\$CFG"; then
    sed -i 's|<numExecutors>[0-9]*</numExecutors>|<numExecutors>2</numExecutors>|g' "\$CFG"
  fi
  echo "numExecutors: \$(grep -o '<numExecutors>[0-9]*</numExecutors>' "\$CFG" || echo missing)"
else
  echo "WARN: no \$CFG"
fi

if [ ! -d "\$JH" ]; then
  echo "WARN: no \$JH — job folder missing"
  exit 0
fi

fixed=0
MIN_ABORT="${MIN_BUILD_TO_ABORT:-80}"
for d in "\$JH"/*/; do
  [ -f "\${d}build.xml" ] || continue
  n=\$(basename "\$d")
  case "\$n" in *[!0-9]*) continue ;; esac
  [ "\$n" -lt "\$MIN_ABORT" ] 2>/dev/null && continue

  building=false
  grep -q '<building>true</building>' "\${d}build.xml" 2>/dev/null && building=true
  has_result=false
  grep -qE '<result>(SUCCESS|FAILURE|ABORTED|UNSTABLE)</result>' "\${d}build.xml" 2>/dev/null && has_result=true

  if [ "\$building" = true ] || [ "\$has_result" = false ]; then
    echo "aborting stale #\${n} (building=\$building has_result=\$has_result)"
    sed -i 's/<building>true<\\/building>/<building>false<\\/building>/g' "\${d}build.xml"
    if grep -q '<result>' "\${d}build.xml"; then
      sed -i 's/<result>[^<]*<\\/result>/<result>ABORTED<\\/result>/g' "\${d}build.xml"
    else
      sed -i 's/<\\/build>/  <result>ABORTED<\\/result>\\n<\\/build>/' "\${d}build.xml"
    fi
    fixed=\$((fixed + 1))
    rm -rf "\${d}workflow" 2>/dev/null || true
  fi
done

echo "==> Clear queue, locks, stale @2 workspaces"
rm -f /jenkins_home/queue.xml
find /jenkins_home -maxdepth 4 -name 'program.dat' -path '*/workflow/*' -delete 2>/dev/null || true
rm -rf /jenkins_home/workspace/${JOB}@tmp 2>/dev/null || true
for ws in /jenkins_home/workspace/${JOB}@*; do
  [ -d "\$ws" ] || continue
  case "\$ws" in */${JOB}) continue ;; esac
  echo "remove workspace \$ws"
  rm -rf "\$ws" 2>/dev/null || true
done

echo "fixed \${fixed} zombie build(s)"
SCRIPT
chmod +x "${WORK}/fix.sh"

cat > "${WORK}/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${JENKINS_NS}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  containers:
    - name: fix
      image: busybox:1.36
      command: ["/bin/sh", "/scripts/fix.sh"]
      volumeMounts:
        - name: jh
          mountPath: /jenkins_home
        - name: scripts
          mountPath: /scripts
  volumes:
    - name: jh
      persistentVolumeClaim:
        claimName: ${PVC}
    - name: scripts
      configMap:
        name: ${POD_NAME}-script
        defaultMode: 0755
YAML

echo "==> Scale Jenkins down (free RWO PVC)"
kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=0
kubectl wait --for=delete pod -l app=jenkins -n "${JENKINS_NS}" --timeout=180s 2>/dev/null || sleep 15

echo "==> Fix builds on ${PVC} (job ${JOB})"
kubectl delete configmap "${POD_NAME}-script" -n "${JENKINS_NS}" --ignore-not-found 2>/dev/null || true
kubectl create configmap "${POD_NAME}-script" -n "${JENKINS_NS}" --from-file=fix.sh="${WORK}/fix.sh"
kubectl delete pod "${POD_NAME}" -n "${JENKINS_NS}" --ignore-not-found --wait=true 2>/dev/null || true
kubectl apply -f "${WORK}/pod.yaml"
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${POD_NAME}" -n "${JENKINS_NS}" --timeout=300s; then
  echo "ERROR: fix pod did not succeed" >&2
  kubectl logs pod/"${POD_NAME}" -n "${JENKINS_NS}" 2>/dev/null || true
  kubectl describe pod/"${POD_NAME}" -n "${JENKINS_NS}" 2>/dev/null | tail -25 || true
  exit 1
fi
kubectl logs pod/"${POD_NAME}" -n "${JENKINS_NS}"
kubectl delete configmap "${POD_NAME}-script" -n "${JENKINS_NS}" --ignore-not-found 2>/dev/null || true

# shellcheck source=lib/wait-jenkins-api.sh
source "${SCRIPT_DIR}/lib/wait-jenkins-api.sh"
echo "==> Wait for Jenkins API (plugins can take 2–3 min after pod start)"
wait_jenkins_api "http://127.0.0.1:30090" 180 || wait_jenkins_api "${JENKINS_PROBE_URL:-http://192.168.56.129:30090}" 60 || true

if [[ -f "${SCRIPT_DIR}/jenkins-status-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/jenkins-status-lab.sh" | grep -E 'building=True|Still building' || echo "OK: no building=True in recent list"
fi

echo ""
echo "Done. Trigger ONE new deploy from PaaS (do not restart Jenkins during the build)."
