#!/usr/bin/env python3
"""Sync HARBOR_* default parameter values on paas-deploy Jenkins job from docker-compose.env."""
from __future__ import annotations

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
import http.cookiejar
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
ENV_FILE = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
DOT_ENV = REPO_ROOT / "paas" / "frontend" / ".env"

HARBOR_KEYS = (
    "HARBOR_REGISTRY",
    "HARBOR_USERNAME",
    "HARBOR_PASSWORD",
    "HARBOR_REGISTRY_PUSH",
    "HARBOR_FORCE_NODEPORT_PUSH",
)


def load_env() -> dict[str, str]:
    out: dict[str, str] = {}
    for path in (ENV_FILE, DOT_ENV):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip('"')
    for k, v in os.environ.items():
        if k.startswith("HARBOR_") or k in ("JENKINS_USERNAME", "JENKINS_API_TOKEN", "JENKINS_PROBE_URL", "JENKINS_JOB_NAME"):
            out[k] = v
    if not out.get("HARBOR_USERNAME") and out.get("HARBOR_USER"):
        out["HARBOR_USERNAME"] = out["HARBOR_USER"]
    if not out.get("HARBOR_PASSWORD") and out.get("HARBOR_PASS"):
        out["HARBOR_PASSWORD"] = out["HARBOR_PASS"]
    return out


def patch_param_defaults(xml: str, values: dict[str, str]) -> tuple[str, list[str]]:
    changed: list[str] = []
    out = xml
    for key in HARBOR_KEYS:
        val = values.get(key, "")
        if not val:
            continue
        pat = re.compile(
            rf"(<name>{re.escape(key)}</name>\s*<description>.*?</description>\s*<defaultValue>)(.*?)(</defaultValue>)",
            re.S,
        )
        m = pat.search(out)
        if not m:
            continue
        old = m.group(2)
        if old == val:
            continue
        out = out[: m.start(2)] + val + out[m.end(2) :]
        changed.append(key)
    return out, changed


def main() -> int:
    vals = load_env()
    base = (vals.get("JENKINS_PROBE_URL") or vals.get("JENKINS_BASE_URL") or "http://192.168.56.129:30090").rstrip("/")
    user = vals.get("JENKINS_USERNAME") or vals.get("JENKINS_USER") or ""
    token = vals.get("JENKINS_API_TOKEN") or vals.get("JENKINS_TOKEN") or ""
    job = vals.get("JENKINS_JOB_NAME") or "paas-deploy"
    if not user or not token:
        print("SKIP: JENKINS_USERNAME/JENKINS_API_TOKEN missing — cannot sync Harbor job params", file=sys.stderr)
        return 0

    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(path: str, method: str = "GET", data: bytes | None = None, extra: dict | None = None) -> tuple[int, str]:
        headers = {"Authorization": f"Basic {auth}"}
        if data is not None:
            headers["Content-Type"] = "application/xml; charset=UTF-8"
        if extra:
            headers.update(extra)
        req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
        try:
            with opener.open(req, timeout=120) as resp:
                return resp.status, resp.read().decode("utf-8", replace="backslashreplace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", replace="backslashreplace")

    code, body = call(f"/job/{job}/config.xml")
    if code == 404:
        print(f"SKIP: job {job} not found (HTTP 404)")
        return 0
    if code != 200:
        print(f"FAIL: GET config.xml HTTP {code}", file=sys.stderr)
        return 1

    merged, changed = patch_param_defaults(body, vals)
    if not changed:
        print("OK: Harbor job params already match env")
        return 0

    extra: dict[str, str] = {}
    ccode, cbody = call("/crumbIssuer/api/json")
    if ccode == 200:
        crumb = json.loads(cbody)
        extra = {crumb["crumbRequestField"]: crumb["crumb"]}
    pcode, pbody = call(f"/job/{job}/config.xml", "POST", merged.encode("utf-8"), extra)
    print(f"POST config.xml (Harbor params) -> {pcode}")
    if pcode not in (200, 201):
        print(pbody[:800], file=sys.stderr)
        return 1
    print(f"OK: updated job params: {', '.join(changed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
