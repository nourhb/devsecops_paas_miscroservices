#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/frontend"

echo "== DevSecOps PaaS – frontend only =="
cd "${APP_DIR}"
npm install
npm run prisma:generate
npm run dev
