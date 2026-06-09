#!/usr/bin/env bash
set -euo pipefail


FIX=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: check.sh [--fix]

Checks Jenkins, Dependency-Track, SonarQube health on the current kube context.
With --fix, applies safe auto-heal actions (scale to 1, helm upgrade --install with required values).
EOF
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARN: $*" >&2; }
die() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need kubectl
need helm
need curl

AUTO_FIX=$FIX

NODE_IP="${NODE_IP:-}"
detect_node_ip() {
  if [[ -n "${NODE_IP}" ]]; then echo "$NODE_IP"; return; fi
  hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\n'
}

ns_exists() { kubectl get ns "$1" >/dev/null 2>&1; }
pods_count() { kubectl get pods -n "$1" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ready_pods_count() { kubectl get pods -n "$1" --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && $2==$2 {print $2}' | awk -F/ '$1==$2{c++} END{print c+0}'; }
svc_has_endpoints() {
  local ns="$1" svc="$2"
  kubectl get endpoints -n "$ns" "$svc" -o jsonpath='{.subsets}' 2>/dev/null | grep -q '\['
}

svc_url() {
  local ns="$1" svc="$2" node_ip="$3"
  local type ports host port0
  type="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  [[ -z "$type" ]] && return 0

  if [[ "$type" == "NodePort" ]]; then
    ports="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{range .spec.ports[*]}{.name}={.nodePort}/{.protocol}{" "}{end}' 2>/dev/null || true)"
    echo "http://${node_ip}:$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)  (NodePort)  ports: ${ports}"
    return 0
  fi

  if [[ "$type" == "LoadBalancer" ]]; then
    host="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -z "$host" ]] && host="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    port0="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    [[ -n "$host" && -n "$port0" ]] && echo "http://${host}:${port0}  (LoadBalancer)" || echo "(LoadBalancer pending)"
    return 0
  fi

  if [[ "$type" == "ClusterIP" ]]; then
    host="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    port0="$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    [[ -n "$host" && -n "$port0" ]] && echo "http://${host}:${port0}  (ClusterIP - in-cluster only)"
    return 0
  fi
}

print_ingress_urls() {
  local ns="$1"
  kubectl get ingress -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' 2>/dev/null || true
}

restart_unhealthy_pods() {
  print_section "AUTO_FIX: Restart unhealthy pods (CrashLoop/Error/ImagePull)"
  kubectl get pods -A --no-headers 2>/dev/null | awk '
    $4 ~ /CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerConfigError/ {print $1, $2}
  ' | while read -r ns pod; do
    echo "Restarting pod: $ns/$pod"
    kubectl delete pod -n "$ns" "$pod" --ignore-not-found >/dev/null 2>&1 || true
  done
}

clean_terminating() {
  print_section "AUTO_FIX: Force-delete stuck Terminating pods"
  kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating"{print $1, $2}' | while read -r ns pod; do
    echo "Force deleting: $ns/$pod"
    kubectl delete pod -n "$ns" "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  done
}

scale_if_exists() {
  local kind="$1" ns="$2" name="$3" replicas="$4"
  kubectl get "$kind" -n "$ns" "$name" >/dev/null 2>&1 || return 0
  kubectl scale "$kind" -n "$ns" "$name" --replicas="$replicas" >/dev/null 2>&1 || true
}

print_section() {
  echo
  echo "=============================="
  echo "$1"
  echo "=============================="
}

ensure_dependency_track() {
  local ns="dependency-track"
  local release="dtrack"
  local api_svc="dtrack-dependency-track-api-server"
  local fe_svc="dtrack-dependency-track-frontend"
  local node_ip="${NODE_IP:-$(detect_node_ip)}"
  local fe_np=31992
  local api_np=30353
  local api_base="http://${node_ip}:${api_np}"

  print_section "Dependency-Track"
  if ! ns_exists "$ns"; then
    warn "namespace '$ns' not found"
    if [ "$FIX" -eq 1 ]; then
      log "healing: install Dependency-Track (bash paas/scripts/install-dependency-track-lab.sh)"
      bash "${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}/install-dependency-track-lab.sh" || true
    else
      log "suggested fix: bash paas/scripts/install-dependency-track-lab.sh"
    fi
    return 0
  fi

  kubectl get svc -n "$ns" | sed -n '1,5p' || true
  local pods
  pods="$(pods_count "$ns")"
  log "pods: $pods (ready: $(ready_pods_count "$ns"))"

  if ! svc_has_endpoints "$ns" "$api_svc" || ! svc_has_endpoints "$ns" "$fe_svc"; then
    warn "services have no endpoints (likely scaled to 0 or pods missing)"
    if [ "$FIX" -eq 1 ]; then
      log "healing: helm upgrade --install $release (NodePort + API_BASE_URL)"
      helm repo add dependency-track https://dependencytrack.github.io/helm-charts >/dev/null 2>&1 || true
      helm repo update >/dev/null
      helm upgrade --install "$release" dependency-track/dependency-track -n "$ns" --create-namespace \
        --set frontend.service.type=NodePort \
        --set "frontend.service.nodePort=${fe_np}" \
        --set apiServer.service.type=NodePort \
        --set "apiServer.service.nodePort=${api_np}" \
        --set "frontend.apiBaseUrl=${api_base}" \
        --set apiServer.resources.requests.cpu=100m \
        --set apiServer.resources.requests.memory=512Mi \
        --set apiServer.resources.limits.memory=1536Mi
    else
      log "suggested fix: bash paas/scripts/install-dependency-track-lab.sh"
    fi
  else
    log "endpoints: OK"
  fi
}

ensure_sonarqube() {
  local ns="sonarqube"
  local release="sonarqube"
  local sts="sonarqube-sonarqube"

  local nodeport="30415"
  local passcode="ChangeMe-Strong-12345"
  local img_repo="mirror.gcr.io/sonarqube"
  local img_tag="26.3.0.120487-community"

  print_section "SonarQube"
  if ! ns_exists "$ns"; then
    warn "namespace '$ns' not found"
    return 0
  fi

  kubectl get svc -n "$ns" | sed -n '1,5p' || true
  local replicas
  replicas="$(kubectl get sts -n "$ns" "$sts" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
  if [ -n "$replicas" ]; then
    log "statefulset/$sts replicas: $replicas"
    if [ "$replicas" = "0" ]; then
      warn "sonarqube scaled to 0"
      if [ "$FIX" -eq 1 ]; then
        log "healing: scale sonarqube to 1"
        kubectl scale -n "$ns" "sts/$sts" --replicas=1
      fi
    fi
  else
    warn "statefulset/$sts not found"
  fi

  local pods
  pods="$(pods_count "$ns")"
  log "pods: $pods (ready: $(ready_pods_count "$ns"))"

  if [ "$pods" -eq 0 ]; then
    warn "no pods found (services may exist but workloads not running)"
    if [ "$FIX" -eq 1 ]; then
      log "healing: helm upgrade --install $release (community + required passcode + mirror image)"
      helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube >/dev/null 2>&1 || true
      helm repo update >/dev/null
      helm upgrade --install "$release" sonarqube/sonarqube -n "$ns" --create-namespace --reset-values \
        --set community.enabled=true \
        --set service.type=NodePort \
        --set service.nodePort="$nodeport" \
        --set postgresql.enabled=true \
        --set monitoringPasscode="$passcode" \
        --set image.repository="$img_repo" \
        --set image.tag="$img_tag"
    else
      log "suggested fix: run './paas/scripts/check.sh --fix'"
    fi
    return 0
  fi

  if [ "$(ready_pods_count "$ns")" -eq 0 ]; then
    warn "sonarqube pod not ready yet (first boot can take 5-15 min)"
    log "status (inside pod):"
    local pod
    pod="$(kubectl get pods -n "$ns" -l app=sonarqube,release=sonarqube -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$pod" ]; then
      kubectl exec -n "$ns" "$pod" -c sonarqube -- sh -lc "curl -s http://localhost:9000/api/system/status || true" || true
    fi
  else
    log "ready: OK"
  fi
}

ensure_jenkins() {
  local ns="jenkins"
  print_section "Jenkins"
  if ! ns_exists "$ns"; then
    warn "namespace '$ns' not found"
    return 0
  fi
  kubectl get pods -n "$ns" -o wide || true
  if kubectl get svc -n "$ns" jenkins >/dev/null 2>&1; then
    echo
    echo "UI URL: $(svc_url "$ns" jenkins "$NODE_IP_EFFECTIVE")"
    echo "Ingress (if any):"
    print_ingress_urls "$ns"
  fi
}

print_section "Cluster context"
kubectl config current-context || true
kubectl get nodes -o wide || true
NODE_IP_EFFECTIVE="$(detect_node_ip)"
echo "NODE_IP=$NODE_IP_EFFECTIVE"

print_section "Core (kube-system)"
kubectl get pods -n kube-system -o wide || true

print_section "Namespaces (quick pod overview)"
for ns in jenkins sonarqube dependency-track harbor argocd ingress-nginx monitoring cert-manager nexus artifactory; do
  echo "== namespace: $ns =="
  kubectl get pods -n "$ns" -o wide 2>/dev/null || echo "(not installed)"
done

print_section "UI URLs"
if ns_exists jenkins && kubectl get svc -n jenkins jenkins >/dev/null 2>&1; then
  echo "Jenkins UI            -> $(svc_url jenkins jenkins "$NODE_IP_EFFECTIVE")"
else
  echo "Jenkins UI            -> (not installed)"
fi

if ns_exists sonarqube && kubectl get svc -n sonarqube sonarqube-sonarqube >/dev/null 2>&1; then
  echo "SonarQube UI          -> $(svc_url sonarqube sonarqube-sonarqube "$NODE_IP_EFFECTIVE")"
else
  echo "SonarQube UI          -> (not installed)"
fi

if ns_exists dependency-track && kubectl get svc -n dependency-track dtrack-dependency-track-frontend >/dev/null 2>&1; then
  echo "Dependency-Track UI   -> $(svc_url dependency-track dtrack-dependency-track-frontend "$NODE_IP_EFFECTIVE")"
else
  echo "Dependency-Track UI   -> (not installed)"
fi
if ns_exists dependency-track && kubectl get svc -n dependency-track dtrack-dependency-track-api-server >/dev/null 2>&1; then
  echo "Dependency-Track API  -> $(svc_url dependency-track dtrack-dependency-track-api-server "$NODE_IP_EFFECTIVE")"
fi

if ns_exists harbor; then
  if kubectl get svc -n harbor harbor >/dev/null 2>&1; then
    echo "Harbor UI             -> $(svc_url harbor harbor "$NODE_IP_EFFECTIVE")"
  elif kubectl get svc -n harbor harbor-nginx >/dev/null 2>&1; then
    echo "Harbor UI             -> $(svc_url harbor harbor-nginx "$NODE_IP_EFFECTIVE")"
  else
    echo "Harbor UI             -> (installed, svc not found)"
  fi
else
  echo "Harbor UI             -> (not installed)"
fi

if ns_exists argocd && kubectl get svc -n argocd argocd-server >/dev/null 2>&1; then
  echo "Argo CD UI            -> $(svc_url argocd argocd-server "$NODE_IP_EFFECTIVE")"
else
  echo "Argo CD UI            -> (not installed)"
fi

ensure_jenkins
ensure_dependency_track
ensure_sonarqube

print_section "Health summary (unhealthy pods)"
kubectl get pods -A --no-headers 2>/dev/null | awk '
  $4 ~ /CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|OOMKilled|Pending|ContainerCreating|Init:/ {print}
' || true

if [ "$AUTO_FIX" -eq 1 ]; then
  clean_terminating
  restart_unhealthy_pods
fi

echo
log "Done. Use --fix to apply auto-heal actions."
