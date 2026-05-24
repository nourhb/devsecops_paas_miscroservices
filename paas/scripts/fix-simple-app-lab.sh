#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  CMD=pull
  TAG="${1}"
else
  CMD="${1:-}"
  TAG="${2:-}"
fi

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
NS="${NS:-simple-app}"
DEPLOY="${DEPLOY:-paas-simple-app-simple-app}"
GIT_REPO="${GIT_REPO:-https://github.com/nourhb/simple-app.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
APP_URL="http://simple-app.${NODE_IP}.nip.io:30659/"

cmd_pull() {
  local image="${HARBOR}/paas/simple-app:${TAG}"
  [[ -n "$TAG" && "$TAG" =~ ^[0-9]+$ ]] || die "usage: $0 pull <tag>"

  if ! kubectl get secret harbor-regcred -n "${NS}" >/dev/null 2>&1; then
    kubectl create secret docker-registry harbor-regcred \
      --docker-server="${HARBOR}" --docker-username="${HARBOR_USER}" \
      --docker-password="${HARBOR_PASS}" -n "${NS}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  obtain_image() {
    [[ "${LOCAL_BUILD:-}" == "1" ]] && return 1
    echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
    local i
    for i in 1 2 3; do
      docker pull "${image}" && return 0
      sleep 10
    done
    return 1
  }

  build_local() {
    local dir
    dir="$(mktemp -d /tmp/simple-app-build-XXXXXX)"
    trap 'rm -rf "${dir}"' RETURN
    git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${dir}"
    cd "${dir}"
    mkdir -p public
    local df="Dockerfile"
    if [[ -f package.json ]] && node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.next?0:1)" 2>/dev/null; then
      if ! grep -qE 'next build|npm run build' Dockerfile 2>/dev/null; then
        df="Dockerfile.paas-next"
        cat > "${df}" <<'DOCKERFILE'
FROM mirror.gcr.io/library/node:20-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm config set audit false && npm config set fund false \
  && if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
COPY . .
RUN mkdir -p public && npx next build
ENV NODE_ENV=production HOSTNAME=0.0.0.0 PORT=3000
EXPOSE 3000
CMD ["npm", "start"]
DOCKERFILE
      fi
    fi
    [[ -f "${df}" ]] || die "no Dockerfile in ${GIT_REPO}"
    docker build -f "${df}" -t "${image}" .
    if [[ "${PUSH_TO_HARBOR:-}" == "1" ]]; then
      echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
      docker push "${image}" || true
    fi
  }

  if obtain_image; then
    :
  elif [[ "${LOCAL_BUILD:-}" == "1" ]] || [[ "${AUTO_LOCAL_BUILD:-}" != "0" ]]; then
    build_local
  else
    die "pull failed for ${image}; try LOCAL_BUILD=1 $0 pull ${TAG}"
  fi

  local tmp="/tmp/simple-app-${TAG}-$$.tar"
  docker save "${image}" -o "${tmp}"
  sudo k3s ctr images import "${tmp}"
  rm -f "${tmp}"

  kubectl set image "deployment/${DEPLOY}" -n "${NS}" "simple-app=${image}" 2>/dev/null || \
    kubectl set image "deployment/${DEPLOY}" -n "${NS}" "*=${image}"
  kubectl patch "deployment/${DEPLOY}" -n "${NS}" --type=strategic -p "{
    \"spec\": {\"template\": {\"spec\": {
      \"imagePullSecrets\": [{\"name\": \"harbor-regcred\"}],
      \"nodeSelector\": {\"kubernetes.io/hostname\": \"master\"},
      \"containers\": [{\"name\": \"simple-app\", \"imagePullPolicy\": \"IfNotPresent\"}]
    }}}
  }" 2>/dev/null || true

  kubectl scale "deployment/${DEPLOY}" -n "${NS}" --replicas=0
  sleep 3
  kubectl delete pods -n "${NS}" -l app.kubernetes.io/name=simple-app --force --grace-period=0 2>/dev/null || true
  kubectl scale "deployment/${DEPLOY}" -n "${NS}" --replicas=1
  kubectl rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=600s || true

  kubectl get pods -n "${NS}" -o wide
  local http
  http="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || echo 000)"
  echo "${APP_URL} -> HTTP ${http}"
}

cmd_crashloop() {
  local gitops="${GITOPS:-${HOME}/gitops}"
  local repo_root chart_src dest http
  repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
  chart_src="${repo_root}/paas/gitops/apps/simple-app"
  TAG="${TAG:-117}"
  [[ "$TAG" =~ ^[0-9]+$ ]] || die "usage: $0 crashloop <tag>"

  kubectl logs -n "${NS}" "deploy/${DEPLOY}" --tail=40 2>/dev/null || true
  kubectl logs -n "${NS}" "deploy/${DEPLOY}" --previous --tail=40 2>/dev/null || true

  kubectl patch "deployment/${DEPLOY}" -n "${NS}" --type=strategic -p '{
    "spec": {"template": {"spec": {
      "securityContext": {"runAsNonRoot": false},
      "nodeSelector": {"kubernetes.io/hostname": "master"},
      "containers": [{
        "name": "simple-app",
        "securityContext": {"readOnlyRootFilesystem": false, "runAsNonRoot": false},
        "env": [{"name": "HOSTNAME", "value": "0.0.0.0"}, {"name": "PORT", "value": "3000"}]
      }]
    }}}
  }' 2>/dev/null || true

  kubectl rollout restart "deployment/${DEPLOY}" -n "${NS}"
  kubectl rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=300s || true

  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN required to push gitops chart"
  [[ -d "${chart_src}" ]] || die "missing ${chart_src}"
  [[ -d "${gitops}/.git" ]] || git clone https://github.com/nourhb/gitops.git "${gitops}"
  dest="${gitops}/apps/simple-app"
  mkdir -p "${dest}"
  rsync -a --delete "${chart_src}/" "${dest}/"
  sed -i "s/^  tag:.*/  tag: \"${TAG}\"/" "${dest}/values.yaml"
  cd "${gitops}"
  git add apps/simple-app
  git diff --cached --quiet || git commit -m "fix(simple-app): tag ${TAG}"
  git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
  command -v argocd >/dev/null && argocd app sync paas-simple-app --force || true

  sleep 10
  http="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || echo 000)"
  echo "${APP_URL} -> HTTP ${http}"
  [[ "$http" == "200" || "$http" == "304" ]] || echo "try: LOCAL_BUILD=1 $0 pull ${TAG}"
}

case "${CMD}" in
  pull|image) cmd_pull ;;
  crashloop|crash) cmd_crashloop ;;
  *)
    die "usage: $0 pull|crashloop <tag>   (or: $0 <tag> for pull)"
    ;;
esac
