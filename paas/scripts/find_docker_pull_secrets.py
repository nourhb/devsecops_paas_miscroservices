"""Find dockerconfigjson secrets across namespaces (SSH)."""
import paramiko

s = paramiko.SSHClient()
s.set_missing_host_key_policy(paramiko.AutoAddPolicy())
s.connect("192.168.56.129", username="master", password="master", timeout=30)
_, o, e = s.exec_command(
    r"kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson "
    r"-o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>&1",
    timeout=60,
)
print((o.read() + e.read()).decode())
s.close()
