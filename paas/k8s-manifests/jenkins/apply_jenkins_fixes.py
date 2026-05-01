"""Apply JCasC ConfigMap + pipeline job XML to cluster Jenkins (SSH to master)."""
import base64
import pathlib
import shlex
import sys

import paramiko

ROOT = pathlib.Path(__file__).resolve().parent
HOST = "192.168.56.129"
USER = "master"
PASSWORD = "master"
REMOTE_TMP = "/tmp/paas-pipeline-config.xml"


def ssh_run(ssh: paramiko.SSHClient, cmd: str) -> tuple[str, str, int]:
    stdin, stdout, stderr = ssh.exec_command(cmd)
    out = stdout.read().decode("utf-8", "ignore")
    err = stderr.read().decode("utf-8", "ignore")
    code = stdout.channel.recv_exit_status()
    return out, err, code


def main() -> int:
    cm_path = ROOT / "jcasc-configmap.fetched.yaml"
    text = cm_path.read_text(encoding="utf-8")
    lines = [ln for ln in text.splitlines() if "resourceVersion:" not in ln and "uid:" not in ln]
    text = "\n".join(lines) + "\n"

    job_xml_path = ROOT / "pipeline-job-config.xml"

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=25)
    try:
        stdin, stdout, stderr = ssh.exec_command("kubectl apply -f -")
        stdin.write(text)
        stdin.channel.shutdown_write()
        out = stdout.read().decode("utf-8", "ignore")
        err = stderr.read().decode("utf-8", "ignore")
        code = stdout.channel.recv_exit_status()
        print(out.strip())
        if err.strip():
            print(err.strip())
        if code != 0:
            return code

        stdin, stdout, stderr = ssh.exec_command(
            "kubectl get secret -n jenkins jenkins -o jsonpath={.data.jenkins-admin-password}"
        )
        admin_pass = base64.b64decode(stdout.read().decode().strip()).decode()

        sftp = ssh.open_sftp()
        try:
            sftp.put(str(job_xml_path), REMOTE_TMP)
        finally:
            sftp.close()

        out, err, code = ssh_run(
            ssh,
            f"kubectl cp {REMOTE_TMP} jenkins/jenkins-0:/tmp/pipeline.xml -c jenkins",
        )
        print(out.strip())
        if err.strip():
            print(err.strip())
        if code != 0:
            return code

        inner = (
            "CRUMB_JSON=$(curl -sS -u "
            + shlex.quote(f"admin:{admin_pass}")
            + " http://127.0.0.1:8080/crumbIssuer/api/json) && "
            "CRUMB=$(printf '%s' \"$CRUMB_JSON\" | sed -n 's/.*\"crumb\":\"\\([^\"]*\\)\".*/\\1/p') && "
            "FIELD=$(printf '%s' \"$CRUMB_JSON\" | sed -n 's/.*\"crumbRequestField\":\"\\([^\"]*\\)\".*/\\1/p') && "
            "curl -sS -f -X POST -u "
            + shlex.quote(f"admin:{admin_pass}")
            + " -H \"$FIELD: $CRUMB\" --data-binary @/tmp/pipeline.xml "
            "http://127.0.0.1:8080/job/pipeline/config.xml"
        )
        remote = "kubectl exec -n jenkins jenkins-0 -c jenkins -- bash -lc " + shlex.quote(inner)
        out, err, code = ssh_run(ssh, remote)
        print("job config update exit:", code)
        print(out[:500] if out else "(empty body)")
        if err.strip():
            print("stderr:", err[:1200])

        _, _, code = ssh_run(ssh, "kubectl rollout restart statefulset/jenkins -n jenkins")
        print("jenkins restart issued" if code == 0 else "jenkins restart failed")
        return 0 if code == 0 else code
    finally:
        ssh.close()


if __name__ == "__main__":
    sys.exit(main())
