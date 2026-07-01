#!/usr/bin/env bash
# Fast k3s diagnosis — no kubectl (avoids hang when API is dead).
set -uo pipefail

echo "=== k3s diagnose $(date -Is 2>/dev/null || date) ==="
echo ""
echo "-- disk --"
df -h / /var/lib/rancher 2>/dev/null || df -h /
echo ""
echo "-- memory --"
free -h
echo ""
echo "-- swap --"
swapon --show 2>/dev/null || echo "(no swap)"
echo ""
echo "-- k3s service --"
systemctl is-active k3s 2>/dev/null || echo inactive
systemctl status k3s --no-pager 2>/dev/null | head -14 || true
echo ""
echo "-- k3s process --"
pgrep -a k3s 2>/dev/null | head -5 || echo "(no k3s process)"
echo ""
echo "-- port 6443 --"
ss -lntp 2>/dev/null | grep 6443 || echo "6443 NOT listening — API down"
echo ""
echo "-- recent OOM --"
dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -8 \
  || journalctl -k --no-pager 2>/dev/null | grep -iE 'oom|killed process' | tail -5 \
  || echo "(none found)"
echo ""
echo "-- k3s journal (last 20) --"
journalctl -u k3s -n 20 --no-pager 2>/dev/null || true
echo ""
echo "If 6443 not listening or OOM lines: sudo bash paas/scripts/lab.sh k3s-unstick"
echo "If disk >90%: bash paas/scripts/lab.sh disk-emergency"
