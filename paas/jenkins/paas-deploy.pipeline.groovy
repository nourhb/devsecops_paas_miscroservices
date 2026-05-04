pipeline {
  agent {
    kubernetes {
      defaultContainer 'jnlp'
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    imagePullPolicy: IfNotPresent
    command:
    - /busybox/cat
    tty: true
    envFrom:
    - secretRef:
        name: paas-integrations
    resources:
      requests:
        memory: "2Gi"
        cpu: "1000m"
      limits:
        memory: "8Gi"
        cpu: "4000m"
    volumeMounts:
    - name: workspace-volume
      mountPath: /home/jenkins/agent
  - name: node
    image: mirror.gcr.io/library/node:20-alpine
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - while true; do sleep 30; done
    tty: true
    envFrom:
    - secretRef:
        name: paas-integrations
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
    volumeMounts:
    - name: workspace-volume
      mountPath: /home/jenkins/agent
  - name: dependency-check
    image: owasp/dependency-check:latest
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - while true; do sleep 30; done
    tty: true
    envFrom:
    - secretRef:
        name: paas-integrations
    resources:
      requests:
        memory: "512Mi"
        cpu: "200m"
    volumeMounts:
    - name: workspace-volume
      mountPath: /home/jenkins/agent
    - name: dependency-check-data
      mountPath: /usr/share/dependency-check/data
  - name: curl
    image: alpine:3.20
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true; while true; do sleep 30; done
    tty: true
    envFrom:
    - secretRef:
        name: paas-integrations
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
    volumeMounts:
    - name: workspace-volume
      mountPath: /home/jenkins/agent
  - name: sonar
    image: sonarsource/sonar-scanner-cli:latest
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - while true; do sleep 30; done
    tty: true
    envFrom:
    - secretRef:
        name: paas-integrations
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
    volumeMounts:
    - name: workspace-volume
      mountPath: /home/jenkins/agent
  volumes:
  - name: workspace-volume
    emptyDir: {}
  - name: dependency-check-data
    hostPath:
      path: /var/lib/jenkins/dependency-check-data
      type: DirectoryOrCreate
"""
    }
  }

  parameters {
    string(name: 'GIT_URL', defaultValue: '', trim: true)
    string(name: 'BRANCH', defaultValue: 'main', trim: true)
    string(name: 'IMAGE_NAME', defaultValue: '', trim: true)
    string(name: 'PROJECT_ID', defaultValue: '', trim: true)
    string(name: 'GIT_CREDENTIALS_ID', defaultValue: '', trim: true)
  }

  environment {
    HARBOR_REGISTRY = '192.168.56.129:30002'
    HARBOR_USERNAME = 'admin'
    HARBOR_PASSWORD = 'Harbor12345'
    DEPENDENCY_TRACK_BASE_URL = "${env.DEPENDENCY_TRACK_BASE_URL ?: ''}"
    DEPENDENCY_TRACK_API_KEY = "${env.DEPENDENCY_TRACK_API_KEY ?: ''}"
    SONAR_HOST_URL = "${env.SONAR_HOST_URL ?: ''}"
    SONAR_TOKEN = "${env.SONAR_TOKEN ?: ''}"
    NVD_API_KEY = "${env.NVD_API_KEY ?: ''}"
  }

  stages {
    stage('Clone') {
      steps {
        deleteDir()
        script {
          def cred = params.GIT_CREDENTIALS_ID?.trim()
          if (cred) {
            checkout([
              $class: 'GitSCM',
              branches: [[name: "*/${params.BRANCH}"]],
              extensions: [],
              userRemoteConfigs: [[url: params.GIT_URL, credentialsId: cred]]
            ])
          } else {
            git branch: params.BRANCH, url: params.GIT_URL
          }
        }
      }
    }

    stage('3. Tests de sécurité et conformité (SCA → CycloneDX → Dependency-Track)') {
      steps {
        sh 'mkdir -p "$WORKSPACE/sca"'

        container('dependency-check') {
          sh '''set -eu
if command -v dependency-check.sh >/dev/null 2>&1; then
  DC=dependency-check.sh
elif [ -x /usr/share/dependency-check/bin/dependency-check.sh ]; then
  DC=/usr/share/dependency-check/bin/dependency-check.sh
else
  echo "dependency-check not found in image" >&2
  exit 1
fi

# SCA: scan dependencies vs NVD (JSON report for audit)
NVD_ARG=""
if [ -n "${NVD_API_KEY:-}" ]; then
  NVD_ARG="--nvdApiKey ${NVD_API_KEY}"
else
  echo "[sca] NVD_API_KEY not set; scans will use local cached DB only."
  NVD_ARG="--noupdate"
fi

DATA_DIR="/usr/share/dependency-check/data"
DB_PRESENT="false"
if [ -f "$DATA_DIR/odc.mv.db" ] || [ -f "$DATA_DIR/odc.h2.db" ] || ls -1 "$DATA_DIR"/*.db >/dev/null 2>&1; then
  DB_PRESENT="true"
fi

# If DB is missing, bootstrap it once using update-only (persisted via hostPath mount).
if [ "$DB_PRESENT" != "true" ]; then
  echo "[sca] Dependency-Check DB missing; bootstrapping once with --updateonly (this can take time)."
  set +e
  "$DC" --updateonly ${NVD_ARG} >"$WORKSPACE/sca/dependency-check-update.log" 2>&1
  UPRC=$?
  set -e
  if [ "$UPRC" -ne 0 ]; then
    echo "[sca] Dependency-Check update-only failed with code $UPRC (continuing)."
    tail -n 80 "$WORKSPACE/sca/dependency-check-update.log" || true
  fi
fi

echo "[sca] Running Dependency-Check scan (always --noupdate)"
LOG="$WORKSPACE/sca/dependency-check.log"
set +e
"$DC" --scan "$WORKSPACE" --format JSON --out "$WORKSPACE/sca" --noupdate >"$LOG" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "[sca] Dependency-Check exited with code $RC (continuing)."
  echo "[sca] Last 60 lines of Dependency-Check output:"
  tail -n 60 "$LOG" || true
fi

# Hint if DB still missing after attempted bootstrap.
if grep -q "Autoupdate is disabled and the database does not exist" "$LOG" 2>/dev/null; then
  echo "[sca] Still no DB after bootstrap attempt. Best fix: set a valid NVD_API_KEY (faster updates), or pre-warm the DB on the node."
fi
'''
        }

        container('node') {
          sh '''set -eu
# SBOM: generate CycloneDX BOM for Node projects (Dependency-Track supported).
# Use cdxgen so it can read package-lock.json without requiring npm install.
if [ -f "$WORKSPACE/package.json" ]; then
  cd "$WORKSPACE"
  npx -y @cyclonedx/cdxgen@latest -r "$WORKSPACE" -o "$WORKSPACE/sca/bom.json" || true
else
  echo "[sca] No package.json; skipping CycloneDX npm BOM generation."
fi
'''
        }

        container('curl') {
          sh '''set -eu
if [ -z "${DEPENDENCY_TRACK_BASE_URL:-}" ] || [ -z "${DEPENDENCY_TRACK_API_KEY:-}" ]; then
  echo "[sca] Dependency-Track not configured; skipping upload."
  exit 0
fi
if [ ! -f "$WORKSPACE/sca/bom.json" ]; then
  echo "[sca] No SBOM (sca/bom.json) generated; skipping upload."
  exit 0
fi

BASE="${DEPENDENCY_TRACK_BASE_URL%/}"
VER="${BRANCH:-unknown}-${BUILD_NUMBER:-0}"
echo "[sca] Uploading SBOM to Dependency-Track: $BASE (project=${PROJECT_ID}, version=${VER})"

curl -sS --fail-with-body --connect-timeout 10 --max-time 60 -X POST "$BASE/api/v1/bom" \
  -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
  -F "autoCreate=true" \
  -F "projectName=${PROJECT_ID}" \
  -F "projectVersion=${VER}" \
  -F "bom=@$WORKSPACE/sca/bom.json"
'''
        }
      }
    }

    stage('4. Tests de sécurité statique (SAST) — SonarQube') {
      steps {
        container('sonar') {
          sh '''set -eu
if [ -z "${SONAR_HOST_URL:-}" ] || [ -z "${SONAR_TOKEN:-}" ]; then
  echo "[sonar] SONAR_HOST_URL / SONAR_TOKEN not set; skipping SonarQube analysis."
  exit 0
fi
cd "$WORKSPACE"
sonar-scanner \
  -Dsonar.host.url="${SONAR_HOST_URL}" \
  -Dsonar.token="${SONAR_TOKEN}" \
  -Dsonar.projectKey="${PROJECT_ID}" \
  -Dsonar.projectName="${PROJECT_ID}" \
  -Dsonar.projectVersion="${BRANCH}-${BUILD_NUMBER}" \
  -Dsonar.sources=. \
  -Dsonar.exclusions=**/node_modules/**,**/.next/**,**/dist/**,**/build/**,**/.git/** \
  -Dsonar.scm.provider=git
'''
        }

        // Enforce SonarQube Quality Gate (without relying on Jenkins SonarQube plugin).
        container('curl') {
          sh '''set -eu
if [ -z "${SONAR_HOST_URL:-}" ] || [ -z "${SONAR_TOKEN:-}" ]; then
  echo "[sonar] SONAR_HOST_URL / SONAR_TOKEN not set; skipping Quality Gate enforcement."
  exit 0
fi

REPORT_FILE="$WORKSPACE/.scannerwork/report-task.txt"
if [ ! -f "$REPORT_FILE" ]; then
  echo "[sonar] Missing $REPORT_FILE; cannot enforce Quality Gate."
  exit 1
fi

ceTaskUrl="$(grep -E '^ceTaskUrl=' "$REPORT_FILE" | cut -d= -f2- || true)"
if [ -z "$ceTaskUrl" ]; then
  # Fallback for older formats
  ceTaskId="$(grep -E '^ceTaskId=' "$REPORT_FILE" | cut -d= -f2- || true)"
  serverUrl="$(grep -E '^serverUrl=' "$REPORT_FILE" | cut -d= -f2- || true)"
  if [ -n "$ceTaskId" ] && [ -n "$serverUrl" ]; then
    ceTaskUrl="${serverUrl%/}/api/ce/task?id=$ceTaskId"
  fi
fi

if [ -z "$ceTaskUrl" ]; then
  echo "[sonar] Unable to find ceTaskUrl/ceTaskId in report-task.txt"
  sed -n '1,120p' "$REPORT_FILE" || true
  exit 1
fi

AUTH="$(printf '%s:' "$SONAR_TOKEN" | base64 | tr -d '\\n')"

echo "[sonar] Waiting for SonarQube background task to complete..."
analysisId=""
status=""
i=0
while [ "$i" -lt 90 ]; do
  i=$((i+1))
  json="$(curl -sS --connect-timeout 5 --max-time 20 -H "Authorization: Basic $AUTH" "$ceTaskUrl" || true)"
  status="$(printf '%s' "$json" | tr -d '\\n' | sed -n 's/.*\"status\":\"\\([A-Z_]*\\)\".*/\\1/p' | head -n 1)"
  analysisId="$(printf '%s' "$json" | tr -d '\\n' | sed -n 's/.*\"analysisId\":\"\\([^\"]*\\)\".*/\\1/p' | head -n 1)"

  if [ "$status" = "SUCCESS" ] && [ -n "$analysisId" ]; then
    break
  fi
  if [ "$status" = "FAILED" ] || [ "$status" = "CANCELED" ]; then
    echo "[sonar] Background task status=$status"
    echo "$json"
    exit 1
  fi
  sleep 5
done

if [ "$status" != "SUCCESS" ] || [ -z "$analysisId" ]; then
  echo "[sonar] Timed out waiting for background task. status=$status analysisId=$analysisId"
  exit 1
fi

QG_URL="${SONAR_HOST_URL%/}/api/qualitygates/project_status?analysisId=$analysisId"
qgJson="$(curl -sS --connect-timeout 5 --max-time 20 -H "Authorization: Basic $AUTH" "$QG_URL" || true)"
qgStatus="$(printf '%s' "$qgJson" | tr -d '\\n' | sed -n 's/.*\"projectStatus\":{[^}]*\"status\":\"\\([A-Z]*\\)\".*/\\1/p' | head -n 1)"

if [ -z "$qgStatus" ]; then
  echo "[sonar] Could not parse Quality Gate status."
  echo "$qgJson"
  exit 1
fi

echo "[sonar] Quality Gate status: $qgStatus"
if [ "$qgStatus" != "OK" ]; then
  echo "[sonar] Quality Gate failed; failing build."
  exit 1
fi
'''
        }
      }
    }

    stage('5. Construction de l\'application') {
      steps {
        container('node') {
          sh '''set -eu
mkdir -p "$WORKSPACE/artifacts"

if [ ! -f "$WORKSPACE/package.json" ]; then
  echo "[build] No package.json; skipping Node build artifact."
  exit 0
fi

cd "$WORKSPACE"

# Prefer deterministic installs when lockfile exists.
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi

if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)"; then
  npm run build
else
  echo "[build] No npm build script; skipping build step."
fi

# Package common build outputs (Next.js / React / generic Node builds).
OUTS=""
for d in .next out dist build; do
  if [ -d "$d" ]; then OUTS="$OUTS $d"; fi
done

if [ -z "$OUTS" ]; then
  echo "[build] No known build output folders found; packaging source snapshot instead."
  tar -czf "$WORKSPACE/artifacts/app-source.tgz" \
    --exclude-vcs \
    --exclude="node_modules" \
    --exclude=".next/cache" \
    .
else
  echo "[build] Packaging build outputs:$OUTS"
  tar -czf "$WORKSPACE/artifacts/app-build.tgz" $OUTS
fi

mkdir -p "$WORKSPACE/paas-artifacts"
{
  echo "# 5. Construction — manifeste d'artefacts intermédiaires (Node)"
  echo "STACK=node"
  echo "BRANCH=${BRANCH:-unknown}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-0}"
} > "$WORKSPACE/paas-artifacts/build-artifact-manifest.txt"
if ls "$WORKSPACE/artifacts"/*.tgz >/dev/null 2>&1; then
  for f in "$WORKSPACE/artifacts"/*.tgz; do
    echo "PACKAGED_ARCHIVE=$f" >> "$WORKSPACE/paas-artifacts/build-artifact-manifest.txt"
  done
fi
'''
        }

        archiveArtifacts artifacts: 'artifacts/*.tgz,paas-artifacts/build-artifact-manifest.txt', allowEmptyArchive: true, fingerprint: true
      }
    }

    stage('6. Création et publication de l\'image Docker (Harbor via Kaniko)') {
      steps {
        container('kaniko') {
          sh '''set -eu
# §6+§9 — Kaniko envoie l\'image au registre (Harbor) via --destination.
# Next.js : certains Dockerfiles copient `/app/public` même si le dépôt n'en a pas — créer `public/` évite l'échec Kaniko.
mkdir -p "$WORKSPACE/public"
mkdir -p /kaniko/.docker
DOCKERFILE_PATH="$WORKSPACE/Dockerfile"
if [ ! -f "$DOCKERFILE_PATH" ]; then
  cat > "$DOCKERFILE_PATH" <<'EOF'
FROM mirror.gcr.io/library/node:20-bookworm-slim
WORKDIR /app
COPY . .
RUN if [ -f package.json ]; then \
      npm config set audit false && \
      npm config set fund false && \
      npm config set fetch-retries 5 && \
      npm config set fetch-retry-factor 2 && \
      npm config set fetch-retry-mintimeout 20000 && \
      npm config set fetch-retry-maxtimeout 120000 && \
      npm config set fetch-timeout 1800000 && \
      npm config set maxsockets 1 && \
      if [ -f package-lock.json ]; then npm install --no-audit --no-fund --prefer-offline || npm install --no-audit --no-fund; else npm install --no-audit --no-fund --prefer-offline || npm install --no-audit --no-fund; fi && \
      if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)"; then npm run build; fi; \
    fi
EXPOSE 3000
CMD ["sh", "-c", "if [ -f package.json ]; then npm start; else node server.js; fi"]
EOF
fi
AUTH=$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 | tr -d '\n')
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$HARBOR_REGISTRY" "$AUTH" > /kaniko/.docker/config.json
if [ ! -f "$WORKSPACE/.dockerignore" ]; then
  cat > "$WORKSPACE/.dockerignore" <<'IGNORE'
.git
**/.git
.github
.vscode
.idea
*.md
IGNORE
fi
/kaniko/executor \
  --single-snapshot \
  --context "$WORKSPACE" \
  --dockerfile "$DOCKERFILE_PATH" \
  --destination "$IMAGE_NAME:$BUILD_NUMBER" \
  --skip-push-permission-check \
  --registry-mirror mirror.gcr.io \
  --insecure \
  --skip-tls-verify \
  --insecure-registry "$HARBOR_REGISTRY" \
  --cache=false
'''
        }
      }
    }
  }
}

