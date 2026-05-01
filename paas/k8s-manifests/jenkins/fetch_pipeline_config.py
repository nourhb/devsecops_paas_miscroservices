"""One-off: fetch Jenkins pipeline job config from cluster (run from dev machine with paramiko)."""
import base64
import pathlib
import sys

import paramiko

ROOT = pathlib.Path(__file__).resolve().parent
HOST = "192.168.56.129"
USER = "master"
PASSWORD = "master"


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=15)
    try:
        stdin, stdout, stderr = ssh.exec_command(
            "kubectl get secret -n jenkins jenkins -o jsonpath={.data.jenkins-admin-password}"
        )
        pwd = base64.b64decode(stdout.read().decode().strip()).decode()
        safe = pwd.replace("'", "'\"'\"'")
        cmd = (
            "kubectl exec -n jenkins jenkins-0 -c jenkins -- "
            f"curl -sS -u admin:'{safe}' http://127.0.0.1:8080/job/pipeline/config.xml"
        )
        stdin, stdout, stderr = ssh.exec_command(cmd)
        xml = stdout.read().decode("utf-8", "ignore")
        err = stderr.read().decode("utf-8", "ignore")
        out = ROOT / "pipeline-job-config.xml"
        out.write_text(xml, encoding="utf-8")
        print(f"wrote {out} ({len(xml)} bytes)")
        if err.strip():
            print("stderr:", err[:500])
        return 0 if xml.strip() else 1
    finally:
        ssh.close()


if __name__ == "__main__":
    sys.exit(main())
