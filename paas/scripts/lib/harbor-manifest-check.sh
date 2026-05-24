
harbor_manifest_http_code() {
  local harbor="$1" repo="$2" ref="$3" user="${4:-admin}" pass="${5:-Harbor12345}"
  local accept code
  for accept in \
    "application/vnd.oci.image.index.v1+json" \
    "application/vnd.docker.distribution.manifest.list.v2+json" \
    "application/vnd.docker.distribution.manifest.v2+json" \
    "application/vnd.oci.image.manifest.v1+json"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -I -u "${user}:${pass}" \
      -H "Accept: ${accept}" \
      "http://${harbor}/v2/${repo}/manifests/${ref}" 2>/dev/null || echo "000")"
    if [[ "$code" == "200" || "$code" == "301" ]]; then
      echo "$code"
      return 0
    fi
  done
  echo "000"
  return 1
}

harbor_image_pullable() {
  local image="$1" user="${2:-admin}" pass="${3:-Harbor12345}"
  command -v docker >/dev/null || return 1
  echo "${pass}" | docker login "${image%%/*}" -u "${user}" --password-stdin >/dev/null 2>&1 || true
  docker pull "${image}" >/dev/null 2>&1
}

harbor_manifest_ok() {
  local harbor="$1" repo="$2" ref="$3" user="${4:-admin}" pass="${5:-Harbor12345}"
  local code
  code="$(harbor_manifest_http_code "$harbor" "$repo" "$ref" "$user" "$pass")"
  [[ "$code" == "200" || "$code" == "301" ]]
}
