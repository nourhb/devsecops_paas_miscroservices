#!/usr/bin/env python3
# Lab helper script for apply jenkins inline steps wrapper
"""POST CPS 7-file split wrapper to Jenkins LIVE (avoids MethodTooLarge monolith load)."""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request
import http.cookiejar
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from jenkins_merge_cps_wrapper import build_wrapper, live_wrapper_ok, merge_pipeline_script  # noqa: E402


def load_creds() -> tuple[str, str, str]:
    vals: dict[str, str] = {}
    env_path = Path("paas/frontend/docker-compose.env")
    if env_path.is_file():
        for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            vals[k.strip()] = v.strip().strip('"')
    base = (
        os.environ.get("JENKINS_PROBE_URL")
        or os.environ.get("JENKINS_BASE_URL")
        or vals.get("JENKINS_PROBE_URL")
        or vals.get("JENKINS_BASE_URL")
        or "http://192.168.56.129:30090"
    ).rstrip("/")
    user = os.environ.get("JENKINS_USERNAME") or vals.get("JENKINS_USERNAME") or vals.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or vals.get("JENKINS_API_TOKEN") or vals.get("JENKINS_TOKEN") or ""
    if not user or not token:
        sys.exit("FAIL: set JENKINS_USERNAME + JENKINS_API_TOKEN")
    return base, user, token


def main() -> int:
    base, user, token = load_creds()
    job = os.environ.get("JENKINS_JOB_NAME", "paas-deploy")
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
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    code, body = call(f"/job/{job}/config.xml")
    if code != 200:
        print(f"FAIL: GET HTTP {code}", file=sys.stderr)
        return 1
    merged = merge_pipeline_script(body, build_wrapper())
    extra: dict[str, str] = {}
    ccode, cbody = call("/crumbIssuer/api/json")
    if ccode == 200:
        crumb = json.loads(cbody)
        extra = {crumb["crumbRequestField"]: crumb["crumb"]}
    pcode, _ = call(f"/job/{job}/config.xml", "POST", merged.encode("utf-8"), extra)
    print(f"POST config.xml -> {pcode}")
    if pcode not in (200, 201):
        return 1
    _, live = call(f"/job/{job}/config.xml")
    bad = live_wrapper_ok(live)
    if bad:
        print("FAIL: LIVE verification:", file=sys.stderr)
        for b in bad:
            print(f"  - {b}", file=sys.stderr)
        return 1
    print("OK: Jenkins LIVE uses 7-file CPS load + runPaasDeploy()")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
