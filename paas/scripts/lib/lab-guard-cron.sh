#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CRON_LINE="0 */6 * * * cd ${REPO_ROOT} && git pull -q && bash paas/scripts/lab.sh guard >>/var/log/paas-lab-guard.log 2>&1"

case "${1:-show}" in
  show)
    echo "Add this line to crontab (crontab -e) on the lab VM:"
    echo "${CRON_LINE}"
    ;;
  install)
    (crontab -l 2>/dev/null | grep -v 'paas/scripts/lab.sh guard' || true; echo "${CRON_LINE}") | crontab -
    echo "OK installed 6-hourly lab guard cron"
    crontab -l | grep 'lab.sh guard' || true
    ;;
  remove)
    crontab -l 2>/dev/null | grep -v 'paas/scripts/lab.sh guard' | crontab - || true
    echo "OK removed lab guard cron"
    ;;
  *)
    echo "usage: lab-guard-cron.sh [show|install|remove]" >&2
    exit 1
    ;;
esac
