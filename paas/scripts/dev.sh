#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${ROOT_DIR}/backend-next"
FRONTEND_DIR="${ROOT_DIR}/frontend"

echo "== DevSecOps PaaS bootstrap =="

required_env=(
  "DATABASE_URL"
  "JENKINS_URL"
  "JENKINS_USER"
  "JENKINS_TOKEN"
  "HARBOR_URL"
  "HARBOR_USERNAME"
  "HARBOR_PASSWORD"
  "ARGOCD_URL"
  "ARGOCD_TOKEN"
  "PROMETHEUS_URL"
)

missing=0
for var in "${required_env[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: environment variable '$var' is not set."
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "Please export the missing environment variables and re-run scripts/dev.sh"
  exit 1
fi

echo "Step 1: Install backend dependencies..."
cd "${BACKEND_DIR}"
npm install

echo "Step 2: Run backend Prisma migrations..."
npm run prisma:generate
npm run prisma:migrate

echo "Step 3: Start backend (port 4000)..."
npm run dev &
BACKEND_PID=$!
sleep 10

echo "Step 4: Install frontend dependencies..."
cd "${FRONTEND_DIR}"
npm install

if [ ! -f ".env" ] && [ -f ".env.example" ]; then
  cp .env.example .env
  echo "Created frontend/.env from .env.example"
fi

echo "Step 5: Start frontend (port 3000)..."
npm run dev &
FRONTEND_PID=$!
sleep 10

BASE_URL=${BASE_URL:-http://localhost:4000}

echo "Step 6: Health checks..."
health_endpoints=(
  "/api/health"
  "/api/jenkins/test"
  "/api/harbor/test"
  "/api/argocd/test"
  "/api/kubernetes/test"
)

for ep in "${health_endpoints[@]}"; do
  echo "Checking ${BASE_URL}${ep}..."
  if ! curl -fsS "${BASE_URL}${ep}" > /dev/null; then
    echo "ERROR: Health check failed for ${ep}"
    kill "$BACKEND_PID" "$FRONTEND_PID" || true
    exit 1
  fi
done

echo "Step 7: Run backend integration tests..."
cd "${BACKEND_DIR}"
npm run verify-all || {
  echo "ERROR: Backend integration tests failed."
  kill "$BACKEND_PID" "$FRONTEND_PID" || true
  exit 1
}

echo "All checks passed. Backend (port 4000) and frontend (port 3000) are running."
echo "Press Ctrl+C to stop."

wait

