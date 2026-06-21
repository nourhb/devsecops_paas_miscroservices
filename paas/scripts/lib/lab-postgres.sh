#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MANIFEST="${PAAS_DIR}/k8s-manifests/lab/postgres-in-paas.yaml"
FRONTEND_DIR="${PAAS_DIR}/frontend"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
IMAGE="${IMAGE:-paas-db-push:local}"
DOCKERFILE_DB="${FRONTEND_DIR}/Dockerfile.db"

die() { echo "ERROR: $*" >&2; exit 1; }

postgres_deploy() {
  echo "=== Remove broken ExternalName / headless postgres Service (if any) ==="
  kubectl delete svc postgres -n "${PAAS_NS}" --ignore-not-found
  echo "=== Deploy Postgres in ${PAAS_NS} (PVC postgres-pvc keeps users/projects) ==="
  kubectl apply -f "${MANIFEST}"
  kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/postgres-pvc -n "${PAAS_NS}" --timeout=120s 2>/dev/null || true
  if ! kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=600s; then
    echo "=== Postgres rollout failed — diagnostics ==="
    kubectl get pods -n "${PAAS_NS}" -l app=postgres -o wide || true
    kubectl describe pod -n "${PAAS_NS}" -l app=postgres | tail -40 || true
    kubectl logs -n "${PAAS_NS}" -l app=postgres --tail=40 2>/dev/null || true
    echo "Common fix: PGDATA subdir (lost+found on local-path PVC). Re-run after git pull."
    exit 1
  fi
  kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s
  echo "=== Point frontend at postgres.paas (sync full env in bootstrap step 3) ==="
  kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null \
    || kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" || true
  kubectl get pods,svc,endpoints -n "${PAAS_NS}" | grep -E 'postgres|frontend|NAME' || true
  kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas
  echo "Postgres OK."
}

postgres_wait() {
  local timeout_sec="${TIMEOUT_SEC:-600}"
  local deadline=$((SECONDS + timeout_sec))
  echo "==> Waiting for Postgres (max ${timeout_sec}s)…"
  while (( SECONDS < deadline )); do
    if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
      if kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1; then
        echo "OK: Postgres ready"
        return 0
      fi
    fi
    echo "  …postgres not ready yet ($(date -u +%H:%M:%S) UTC)"
    sleep 5
  done
  echo "ERROR: Postgres not ready after ${timeout_sec}s" >&2
  kubectl get pods,svc -n "${PAAS_NS}" 2>/dev/null | grep -E 'postgres|NAME' || true
  return 1
}

postgres_push_schema() {
  kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s
  local pg_ip
  pg_ip="$(kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  [[ -n "${pg_ip}" ]] || die "No postgres endpoints — run: bash paas/scripts/lab.sh start"
  local db_url="postgresql://postgres:root@${pg_ip}:5432/paas?options=-c%20lc_messages%3DC"
  local schema_pushed=0
  push_via_node_image() {
    echo "=== prisma db push (node:20-alpine + mounted frontend) ==="
    [[ -f "${FRONTEND_DIR}/package.json" ]] || die "Missing ${FRONTEND_DIR}/package.json — git pull from repo root"
    [[ -d "${FRONTEND_DIR}/prisma" ]] || die "Missing ${FRONTEND_DIR}/prisma"
    docker run --rm \
      -v "${FRONTEND_DIR}:/app" \
      -w /app \
      -e DATABASE_URL="${db_url}" \
      node:20-alpine \
      sh -ec 'apk add --no-cache openssl libc6-compat && npm ci && npx prisma generate && npx prisma db push'
  }
  push_via_dockerfile() {
    echo "=== Build ${IMAGE} ==="
    docker build -f "${FRONTEND_DIR}/Dockerfile.db" -t "${IMAGE}" "${PAAS_DIR}"
    echo "=== prisma db push (docker → ${pg_ip}) ==="
    docker run --rm -e DATABASE_URL="${db_url}" "${IMAGE}"
  }
  if [[ -f "${DOCKERFILE_DB}" ]] && [[ "$(wc -c < "${DOCKERFILE_DB}")" -gt 80 ]]; then
    if push_via_dockerfile; then
      schema_pushed=1
    fi
  else
    echo "WARN: ${DOCKERFILE_DB} missing or empty — run: git checkout paas/frontend/Dockerfile.db"
  fi
  if [[ "${schema_pushed}" -eq 0 ]]; then
    push_via_node_image
  fi
  echo "=== Tables ==="
  kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -c '\dt' | head -20
  echo "OK: register/login at http://192.168.56.129:30100"
}

cmd="${1:-all}"
case "${cmd}" in
  deploy) postgres_deploy ;;
  wait) postgres_wait ;;
  schema) postgres_push_schema ;;
  all)
    postgres_deploy
    postgres_wait
    postgres_push_schema
    ;;
  *)
    echo "usage: lab-postgres.sh [deploy|wait|schema|all]" >&2
    exit 1 ;;
esac
