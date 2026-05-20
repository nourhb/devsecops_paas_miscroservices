#!/usr/bin/env bash
# One-shot lab recovery: start Jenkins (emptyDir) + create paas-deploy job (--minimal).
# Copy this ONE file to the VM (do not paste large Python/XML into the terminal):
#   scp paas/scripts/bootstrap-jenkins-lab-vm.sh master@192.168.56.129:~/devsecops_paas_miscroservices/paas/scripts/
#   ssh master@192.168.56.129 'bash ~/devsecops_paas_miscroservices/paas/scripts/bootstrap-jenkins-lab-vm.sh'
set -euo pipefail

REPO="${REPO:-$HOME/devsecops_paas_miscroservices}"
ENV_FILE="${ENV_FILE:-$REPO/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_BASE_URL:-http://127.0.0.1:30090}"
NS=cicd

echo "==> 1. Ensure namespace $NS"
kubectl create namespace "$NS" 2>/dev/null || true

echo "==> 2. Deploy Jenkins (emptyDir on master, NodePort 30090)"
if [[ -f "$REPO/paas/k8s-manifests/lab/jenkins-cicd-emptydir.yaml" ]]; then
  kubectl apply -f "$REPO/paas/k8s-manifests/lab/jenkins-cicd-emptydir.yaml"
else
  kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: cicd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      nodeSelector:
        kubernetes.io/hostname: master
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: jenkins
          image: jenkins/jenkins:lts
          ports:
            - containerPort: 8080
          env:
            - name: JAVA_OPTS
              value: "-Xms256m -Xmx768m -Djenkins.install.runSetupWizard=false"
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 1Gi
          volumeMounts:
            - name: jenkins-storage
              mountPath: /var/jenkins_home
      volumes:
        - name: jenkins-storage
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins-service
  namespace: cicd
spec:
  type: NodePort
  selector:
    app: jenkins
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30090
EOF
fi

echo "==> 3. Wait for Jenkins pod Ready (up to 5m)"
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=300s
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$JENKINS_URL/login" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "Jenkins UI HTTP $code"
    break
  fi
  echo "waiting Jenkins login ($code)..."
  sleep 5
done

echo "==> 4. Wait for Pipeline plugins (fresh emptyDir installs plugins slowly)"
for i in $(seq 1 90); do
  if curl -s -m 5 "$JENKINS_URL/pluginManager/api/json?depth=1" 2>/dev/null \
    | grep -q 'workflow-job'; then
    echo "workflow-job plugin visible"
    break
  fi
  echo "waiting plugins ($i/90)..."
  sleep 10
done

echo "==> 5. Create paas-deploy job"
if [[ -f "$REPO/paas/scripts/create_jenkins_paas_deploy_job.py" ]]; then
  export JENKINS_BASE_URL="$JENKINS_URL"
  python3 "$REPO/paas/scripts/create_jenkins_paas_deploy_job.py" --minimal
else
  python3 - <<'PY'
import base64, json, os, sys, urllib.request, http.cookiejar, urllib.parse
from pathlib import Path

repo = Path(os.environ.get("REPO", os.path.expanduser("~/devsecops_paas_miscroservices")))
env_file = repo / "paas/frontend/docker-compose.env"
base = os.environ.get("JENKINS_BASE_URL", "http://127.0.0.1:30090").rstrip("/")
user = token = ""
for line in env_file.read_text(encoding="utf-8").splitlines():
    if line.startswith("JENKINS_USERNAME="):
        user = line.split("=", 1)[1].strip()
    if line.startswith("JENKINS_API_TOKEN="):
        token = line.split("=", 1)[1].strip()
if not user or not token:
    sys.exit("Set JENKINS_USERNAME and JENKINS_API_TOKEN in docker-compose.env")
job = "paas-deploy"
groovy = "node('built-in') { stage('PaaS placeholder') { echo 'paas-deploy OK' } }\n"

def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

params = [("GIT_URL",""),("BRANCH","main"),("IMAGE_NAME",""),("PROJECT_ID",""),("JENKINS_AGENT_LABEL","built-in")]
pxml = "".join(
    f'<hudson.model.StringParameterDefinition><name>{esc(n)}</name><description></description>'
    f'<defaultValue>{esc(d)}</defaultValue><trim>true</trim></hudson.model.StringParameterDefinition>'
    for n, d in params
)
inner = groovy.replace("]]>", "]]]]><![CDATA[>")
xml = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<flow-definition plugin="workflow-job">\n'
    '  <properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>\n'
    f'    {pxml}\n'
    '  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>\n'
    '  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">\n'
    f'    <script><![CDATA[{inner}]]></script>\n'
    '    <sandbox>true</sandbox>\n'
    '  </definition>\n'
    '  <triggers/><disabled>false</disabled>\n'
    '</flow-definition>\n'
).encode("utf-8")

auth = base64.b64encode(f"{user}:{token}".encode()).decode()
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def call(path, method="GET", data=None, extra=None):
    h = {"Authorization": f"Basic {auth}"}
    if data is not None:
        h["Content-Type"] = "application/xml; charset=UTF-8"
    if extra:
        h.update(extra)
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with opener.open(req, timeout=120) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

code, _ = call("/api/json")
print("GET /api/json ->", code)
if code != 200:
    sys.exit(1)
if call(f"/job/{urllib.parse.quote(job)}/api/json")[0] == 200:
    print("Job already exists:", f"{base}/job/{job}/")
    sys.exit(0)
crumb = {}
c, b = call("/crumbIssuer/api/json")
if c == 200:
    j = json.loads(b)
    crumb = {j["crumbRequestField"]: j["crumb"]}
    print("Crumb OK")
code, body = call(f"/createItem?name={urllib.parse.quote(job)}", "POST", xml, crumb)
print("POST createItem ->", code)
if code not in (200, 201, 302):
    print(body[:2000])
    sys.exit(1)
print("OK:", f"{base}/job/{job}/")
PY
fi

echo ""
echo "Done. Open: ${JENKINS_URL%/}/job/paas-deploy/"
echo "Set JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false after job exists."
echo "For full pipeline: git pull repo then: python3 paas/scripts/create_jenkins_paas_deploy_job.py"
