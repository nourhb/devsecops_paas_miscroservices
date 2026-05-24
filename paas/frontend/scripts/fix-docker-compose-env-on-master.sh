#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${1:-$(dirname "$0")/../docker-compose.env}"
cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
sed -i \
  -e 's|^INTEGRATIONS_PROBE_HOST_REMAP=.*|INTEGRATIONS_PROBE_HOST_REMAP=|' \
  -e 's|^NEXT_PUBLIC_INGRESS_NGINX_URL=.*|NEXT_PUBLIC_INGRESS_NGINX_URL=http://192.168.56.129:30659|' \
  -e 's|^INGRESS_NGINX_PROBE_URL=.*|INGRESS_NGINX_PROBE_URL=http://host.docker.internal:30659|' \
  -e 's|^SONAR_BASE_URL=.*|SONAR_BASE_URL=http://192.168.56.129:30900|' \
  -e 's|^SONAR_PROBE_URL=.*|SONAR_PROBE_URL=http://host.docker.internal:30900|' \
  -e 's|^DEPENDENCY_TRACK_BASE_URL=.*|DEPENDENCY_TRACK_BASE_URL=http://192.168.56.129:32313|' \
  -e 's|^NEXT_PUBLIC_NEXUS_URL=.*|NEXT_PUBLIC_NEXUS_URL=http://192.168.56.129:31566|' \
  -e 's|^NEXUS_URL=.*|NEXUS_URL=http://192.168.56.129:31566|' \
  -e 's|^NEXT_PUBLIC_ARTIFACTORY_URL=.*|NEXT_PUBLIC_ARTIFACTORY_URL=http://192.168.56.129:31754|' \
  -e 's|^ARTIFACTORY_URL=.*|ARTIFACTORY_URL=http://192.168.56.129:31754|' \
  -e 's|^ARGOCD_BASE_URL=.*|ARGOCD_BASE_URL=https://192.168.56.129:30374|' \
  "$ENV_FILE"
for key in GRAFANA_PROBE_URL PROMETHEUS_PROBE_URL ALERTMANAGER_PROBE_URL PUSHGATEWAY_PROBE_URL \
  HARBOR_PROBE_URL TRIVY_PROBE_URL JENKINS_PROBE_URL; do
  sed -i "s|^${key}=http://192.168.56.129:|${key}=http://host.docker.internal:|" "$ENV_FILE" 2>/dev/null || true
done
grep -E 'INTEGRATIONS_PROBE_HOST_REMAP|INGRESS|SONAR_|NEXUS|ARTIFACTORY|ARGOCD_BASE|GRAFANA_PROBE' "$ENV_FILE" | head -20
echo "Restart: cd ~/devsecops_paas_miscroservices/paas && docker compose up -d --force-recreate frontend"
