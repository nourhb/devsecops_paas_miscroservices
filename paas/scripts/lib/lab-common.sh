
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
HARBOR_PORT="${HARBOR_PORT:-30002}"
HARBOR="${HARBOR:-${NODE_IP}:${HARBOR_PORT}}"
PAAS_NS="${PAAS_NS:-paas}"
PROJECT_ID="${PROJECT_ID:-179dcf7f-ad21-4421-9114-0171f3e9914c}"

lab_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd
}

lab_source_env() {
  local env_file="${1:-}"
  [[ -f "${env_file}" ]] || return 0
  set +u
  source "${env_file}" 2>/dev/null || true
  set -u
}

lab_jenkins_trigger_paas_deploy() {
  local env_file="${1:-}"
  local project_id="${2:-${PROJECT_ID}}"
  lab_source_env "${env_file}"
  local jenkins_url="${JENKINS_URL:-http://${NODE_IP}:30090}"
  if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
    echo "Set JENKINS_USERNAME and JENKINS_API_TOKEN in ${env_file} to auto-trigger Jenkins."
    return 0
  fi
  if [[ "${JENKINS_API_TOKEN}" == "your-jenkins-api-token" ]]; then
    echo "Replace placeholder JENKINS_API_TOKEN in ${env_file}."
    return 0
  fi
  local crumb_json field crumb
  crumb_json="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${jenkins_url}/crumbIssuer/api/json" 2>/dev/null || echo '{}')"
  crumb="$(echo "${crumb_json}" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
  field="$(echo "${crumb_json}" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')"
  local curl_crumb=()
  [[ -n "${crumb}" && -n "${field}" ]] && curl_crumb=(-H "${field}:${crumb}")
  curl -sS -X POST -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${curl_crumb[@]}" \
    "${jenkins_url}/job/paas-deploy/buildWithParameters?PROJECT_ID=${project_id}&BRANCH=main" \
    -o /dev/null -w "Jenkins trigger HTTP %{http_code}\n" || true
  echo "Console: ${jenkins_url}/job/paas-deploy/lastBuild/console"
}
