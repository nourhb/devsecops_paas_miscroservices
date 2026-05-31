#!/usr/bin/env bash
# Patch project Ingress resources stuck on ingressClassName=nginx while Traefik serves :30659.
set -euo pipefail

DESIRED_CLASS="${APPS_INGRESS_CLASS:-traefik}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/frontend/docker-compose.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  val="$(grep -E '^APPS_INGRESS_CLASS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '\r"' | xargs || true)"
  [[ -n "$val" ]] && DESIRED_CLASS="$val"
fi

echo "==> Patching Ingress ingressClassName -> $DESIRED_CLASS (skip paas namespace)"
count=0
while IFS=$'\t' read -r ns name current; do
  [[ -z "$ns" || -z "$name" ]] && continue
  if [[ "$current" == "$DESIRED_CLASS" ]]; then
    echo "OK   $ns/$name already $DESIRED_CLASS"
    continue
  fi
  kubectl patch ingress "$name" -n "$ns" --type=merge -p "{\"spec\":{\"ingressClassName\":\"$DESIRED_CLASS\"}}"
  echo "FIX  $ns/$name ($current -> $DESIRED_CLASS)"
  count=$((count + 1))
done < <(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.ingressClassName}{"\n"}{end}' \
  | grep -v '^paas	' || true)

echo "==> Done ($count patched). Probe example:"
echo "    curl -s -o /dev/null -w '%{http_code}\n' http://sanhome.192.168.56.129.nip.io:30659/"
