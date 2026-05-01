"""Apply food-delivery demo + Kyverno patch on cluster master (SSH)."""
import pathlib
import sys

import paramiko

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOST = "192.168.56.129"
USER = "master"
PASSWORD = "master"


def apply(ssh: paramiko.SSHClient, rel: str) -> tuple[int, str]:
    data = (ROOT / rel).read_text(encoding="utf-8")
    stdin, stdout, stderr = ssh.exec_command("kubectl apply -f -")
    stdin.write(data)
    stdin.channel.shutdown_write()
    out = stdout.read().decode() + stderr.read().decode()
    return stdout.channel.recv_exit_status(), out


def run(ssh: paramiko.SSHClient, cmd: str) -> str:
    _, stdout, stderr = ssh.exec_command(cmd)
    return stdout.read().decode() + stderr.read().decode()


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=45)
    try:
        c1, o1 = apply(ssh, "paas/k8s-manifests/kyverno/require-signed-images.yaml")
        print("kyverno apply:", c1, o1.strip()[:600])
        c2, o2 = apply(ssh, "paas/k8s-manifests/food-delivery-devsecops/demo-app.yaml")
        print("food apply:", c2, o2.strip()[:800])
        print(run(ssh, "kubectl rollout status deployment/food-delivery-app -n food-delivery-devsecops --timeout=120s"))
        print(run(ssh, "kubectl get pods,svc,ingress -n food-delivery-devsecops"))
        print(
            "curl:",
            run(
                ssh,
                'curl -s -o /dev/null -w "%{http_code}" -H "Host: food-delivery-devsecops.192.168.56.129.nip.io" http://127.0.0.1:31077/',
            ).strip(),
        )
        return 0 if c1 == 0 and c2 == 0 else 1
    finally:
        ssh.close()


if __name__ == "__main__":
    sys.exit(main())
