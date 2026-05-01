"""Run Argo CD refresh/sync via SSH to cluster master (kubectl)."""
import json
import sys

import paramiko

HOST = "192.168.56.129"
USER = "master"
PASSWORD = "master"
APP = "paas-sample-app"
NS = "argocd"


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    try:
        def run(cmd: str) -> tuple[str, str, int]:
            stdin, stdout, stderr = ssh.exec_command(cmd)
            out = stdout.read().decode("utf-8", "ignore")
            err = stderr.read().decode("utf-8", "ignore")
            code = stdout.channel.recv_exit_status()
            return out, err, code

        out, err, code = run(f"kubectl get applications -n {NS} -o wide")
        print(out)
        if err.strip():
            print(err, file=sys.stderr)

        patch = (
            '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
        )
        out, err, code = run(
            f"kubectl patch application {APP} -n {NS} --type merge -p '{patch}'"
        )
        print("patch refresh:", out.strip() or "(empty)", err.strip()[:500])

        # Optional: request sync operation via argocd app sync if binary exists
        out, err, _ = run("command -v argocd || true")
        if "argocd" in out:
            out2, err2, c2 = run(f"argocd app sync {APP} --server localhost:8080 2>&1")
            print("argocd cli:", out2[:2000], err2[:500], "exit", c2)

        out, err, code = run(
            f"kubectl get application {APP} -n {NS} -o json"
        )
        if code == 0 and out.strip():
            d = json.loads(out)
            st = d.get("status") or {}
            sync = st.get("sync") or {}
            health = st.get("health") or {}
            conds = st.get("conditions") or []
            print(
                "sync.status:",
                sync.get("status"),
                "| health:",
                health.get("status"),
            )
            for c in conds[:3]:
                print("condition:", c.get("type"), "-", (c.get("message") or "")[:200])
        else:
            print("get app failed:", err[:800])

        return 0
    finally:
        ssh.close()


if __name__ == "__main__":
    sys.exit(main())
