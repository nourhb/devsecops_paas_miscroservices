#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WATCHDOG_LINE="*/10 * * * * cd ${REPO_ROOT} && git pull -q 2>/dev/null; bash paas/scripts/lab.sh watchdog >>/var/log/paas-lab-watchdog.log 2>&1"
GUARD_LINE="0 */6 * * * cd ${REPO_ROOT} && git pull -q && bash paas/scripts/lab.sh guard >>/var/log/paas-lab-guard.log 2>&1"

filter_cron() {
  crontab -l 2>/dev/null | grep -v 'paas/scripts/lab.sh guard' | grep -v 'paas/scripts/lab.sh watchdog' || true
}

case "${1:-show}" in
  show)
    echo "Add these lines to crontab (crontab -e) on the lab VM:"
    echo "${WATCHDOG_LINE}"
    echo "${GUARD_LINE}"
    ;;
  install)
    (filter_cron; echo "${WATCHDOG_LINE}"; echo "${GUARD_LINE}") | crontab -
    echo "OK installed PaaS lab auto-heal cron:"
    echo "  every 10 min — watchdog (disk, kyverno, postgres, frontend storm)"
    echo "  every 6 h    — full guard (images, prometheus, health)"
    crontab -l | grep -E 'lab.sh (watchdog|guard)' || true
    touch /var/log/paas-lab-watchdog.log /var/log/paas-lab-guard.log 2>/dev/null \
      || sudo touch /var/log/paas-lab-watchdog.log /var/log/paas-lab-guard.log 2>/dev/null || true
    ;;
  remove)
    filter_cron | crontab - || true
    echo "OK removed lab watchdog + guard cron"
    ;;
  *)
    echo "usage: lab-guard-cron.sh [show|install|remove]" >&2
    exit 1
    ;;
esac
