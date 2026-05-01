import base64
import json
import os
import shlex
import sys

import paramiko

pw_ssh = os.environ.get("ARGOCD_REFRESH_SSH_PASSWORD", "")
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("192.168.56.129", username="master", password=pw_ssh, timeout=30)
_, o, _ = ssh.exec_command("kubectl get secret -n harbor harbor-core -o json", timeout=30)
data = json.loads(o.read().decode())
admin_pw = base64.b64decode(data["data"]["HARBOR_ADMIN_PASSWORD"]).decode("utf-8")
a = shlex.quote(f"admin:{admin_pw}")
_, o2, _ = ssh.exec_command(
    f"curl -sk -u {a} 'http://192.168.56.129:30002/api/v2.0/projects?page=1&page_size=100'",
    timeout=30,
)
print(o2.read().decode()[:8000])
ssh.close()
