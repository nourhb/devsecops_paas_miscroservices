#!/usr/bin/env bash
# Mark zombie WorkflowRuns (building=true after OOM/restart) as ABORTED on Jenkins PVC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JENKINS_NS="${JENKINS_NS:-cicd}"
JOB="${JOB_NAME:-paas-deploy}"
PVC="${JENKINS_PVC:-jenkins-pvc}"
NODE="${JENKINS_NODE:-master}"

echo "==> Scale Jenkins down (free RWO PVC)"
kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=0
kubectl wait --for=delete pod -l app=jenkins -n "${JENKINS_NS}" --timeout=180s 2>/dev/null || sleep 15

echo "==> Fix builds on ${PVC} (job ${JOB})"
kubectl run jenkins-zombie-fix --rm -i --restart=Never -n "${JENKINS_NS}" \
  --image=busybox:1.36 \
  --overrides="$(cat <<OV
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "${NODE}"},
    "containers": [{
      "name": "fix",
      "image": "busybox:1.36",
      "command": ["sh", "-c", "
        set -e
        JH=/jenkins_home/jobs/${JOB}/builds
        if [ ! -d \"\$JH\" ]; then
          echo \"WARN: no \$JH — job folder missing\"
          exit 0
        fi
        fixed=0
        for d in \"\$JH\"/*/; do
          [ -f \"\${d}build.xml\" ] || continue
          if grep -q '<building>true</building>' \"\${d}build.xml\" 2>/dev/null; then
            n=\$(basename \"\$d\")
            echo \"aborting zombie #\${n}\"
            sed -i 's/<building>true<\\/building>/<building>false<\\/building>/g' \"\${d}build.xml\"
            if grep -q '<result>' \"\${d}build.xml\"; then
              sed -i 's/<result>[^<]*<\\/result>/<result>ABORTED<\\/result>/g' \"\${d}build.xml\"
            else
              sed -i 's/<\\/build>/  <result>ABORTED<\\/result>\\n<\\/build>/' \"\${d}build.xml\"
            fi
            fixed=\$((fixed + 1))
          fi
        done
        rm -f /jenkins_home/queue.xml
        echo \"fixed \${fixed} build(s)\"
      "],
      "volumeMounts": [{"name": "jh", "mountPath": "/jenkins_home"}]
    }],
    "volumes": [{"name": "jh", "persistentVolumeClaim": {"claimName": "${PVC}"}}]
  }
}
OV
)" -- echo done

echo "==> Start Jenkins"
kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=1
kubectl rollout status deployment/jenkins -n "${JENKINS_NS}" --timeout=600s
echo "Wait 60s for Jenkins API…"
sleep 60

if [[ -f "${SCRIPT_DIR}/jenkins-status-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/jenkins-status-lab.sh" | grep -E 'building=True|Still building' || echo "OK: no building=True in recent list"
fi

echo ""
echo "Done. Trigger ONE new deploy from PaaS (do not restart Jenkins during the build)."
