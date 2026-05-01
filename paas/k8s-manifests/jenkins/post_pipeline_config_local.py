"""POST pipeline config.xml to Jenkins (NodePort) with crumb + cookies (avoids 403)."""
import base64
import http.cookiejar
import pathlib
import sys
import urllib.error
import urllib.request

import paramiko

JENKINS = "http://192.168.56.129:30609"
ROOT = pathlib.Path(__file__).resolve().parent
HOST = "192.168.56.129"
SSH_USER = "master"
SSH_PASS = "master"


def get_admin_password() -> str:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=SSH_USER, password=SSH_PASS, timeout=20)
    try:
        stdin, stdout, stderr = ssh.exec_command(
            "kubectl get secret -n jenkins jenkins -o jsonpath={.data.jenkins-admin-password}"
        )
        return base64.b64decode(stdout.read().decode().strip()).decode()
    finally:
        ssh.close()


def main() -> int:
    pwd = get_admin_password()
    auth = base64.b64encode(f"admin:{pwd}".encode()).decode()
    xml = (ROOT / "pipeline-job-config.xml").read_bytes()

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    crumb_req = urllib.request.Request(
        f"{JENKINS}/crumbIssuer/api/json",
        headers={"Authorization": f"Basic {auth}"},
    )
    with opener.open(crumb_req, timeout=30) as r:
        import json

        data = json.loads(r.read().decode())
    crumb = data["crumb"]
    field = data["crumbRequestField"]

    post_req = urllib.request.Request(
        f"{JENKINS}/job/pipeline/config.xml",
        data=xml,
        method="POST",
        headers={
            "Authorization": f"Basic {auth}",
            field: crumb,
            "Content-Type": "application/xml",
        },
    )
    try:
        with opener.open(post_req, timeout=60) as r:
            print("POST status:", r.status)
            return 0
    except urllib.error.HTTPError as e:
        print("HTTPError", e.code, e.read()[:800].decode("utf-8", "ignore"))
        return 1


if __name__ == "__main__":
    sys.exit(main())
