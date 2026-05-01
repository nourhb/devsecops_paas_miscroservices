import paramiko

HOST = "192.168.56.129"
USER = "master"
PASSWORD = "master"


def main() -> None:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=25)
    try:

        def run(cmd: str) -> str:
            _, stdout, stderr = ssh.exec_command(cmd)
            return (stdout.read() + stderr.read()).decode("utf-8", "ignore")

        print(run("kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports}'"))
        print("--- curl https :32225 ---")
        print(run("curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:32225/healthz; echo"))
        print("--- curl http :32176 ---")
        print(run("curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:32176/healthz; echo"))
    finally:
        ssh.close()


if __name__ == "__main__":
    main()
